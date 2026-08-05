//! sql-apply — the typed core of substrate's SQL-migration primitive.
//!
//! Everything in this module is pure and DB-free so it can be unit-tested
//! without a server. `main.rs` adds the clap CLI and the sqlx connection work.
//!
//! WHY THIS EXISTS. `lib/service/db-migration.nix` shipped a `writeShellScript`
//! runner whose whole body was `for f in ${dir}/*.sql; do ${DATABASE_CLI:-psql}
//! "$DB_URL" < "$f"; done`. Because the runner *was* a shell script, its own
//! comment concluded a shell is "mandatory at RUNTIME regardless of type, ruling
//! out a shell-less distroless base outright" — so every consumer inherited a
//! busybox-carrying base. Replacing the runner with a typed binary removes that
//! constraint: the image needs neither a shell nor a database CLI.
//!
//! The shell version also could not tell the difference between "this migration
//! already ran" and "the table I need is missing", because piping a file to a
//! CLI yields one exit status for the whole file. This splits the file and
//! classifies each failure.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

/// A `db.table` pair that must exist before a dependent migration may run.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Sentinel {
    pub schema: String,
    pub table: String,
}

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("--sentinel is required (db.table[,db.table...])")]
    NoSentinels,
    #[error("{0:?} is not db.table")]
    BadSentinel(String),
    #[error("--files listed no usable filenames")]
    NoFiles,
    #[error("{0:?} must be a bare filename, not a path")]
    NotBareName(String),
    #[error("no .sql files in {0}")]
    EmptyDir(PathBuf),
    #[error("{0}: {1}")]
    Io(PathBuf, #[source] std::io::Error),
}

/// Parse `db.table,db.table` into sentinels.
///
/// `splitn(2)`, not `split`: a table name may itself contain a dot, and the
/// schema never does.
pub fn parse_sentinels(spec: &str) -> Result<Vec<Sentinel>, Error> {
    if spec.trim().is_empty() {
        return Err(Error::NoSentinels);
    }
    let mut out = Vec::new();
    for raw in spec.split(',') {
        let s = raw.trim();
        if s.is_empty() {
            continue;
        }
        let mut parts = s.splitn(2, '.');
        let schema = parts.next().unwrap_or_default();
        let table = parts.next().unwrap_or_default();
        if schema.is_empty() || table.is_empty() {
            return Err(Error::BadSentinel(s.to_string()));
        }
        out.push(Sentinel {
            schema: schema.to_string(),
            table: table.to_string(),
        });
    }
    if out.is_empty() {
        return Err(Error::NoSentinels);
    }
    Ok(out)
}

/// Resolve which files to apply, in the order they must be applied.
///
/// An explicit `--files` list is honoured VERBATIM, because apply order is
/// load-bearing: a dependent migration's sentinel check relies on the last file
/// proving the earlier ones ran. A bare directory scan is sorted, which is only
/// a safe default when the filenames themselves encode order.
pub fn resolve_files(dir: &Path, list: &str) -> Result<Vec<String>, Error> {
    if !list.trim().is_empty() {
        let mut out = Vec::new();
        for raw in list.split(',') {
            let n = raw.trim();
            if n.is_empty() {
                continue;
            }
            // Reject a path rather than silently basename it: these name entries
            // in a mounted ConfigMap, so anything else is a mistake worth surfacing.
            if Path::new(n).file_name().map(|f| f != n).unwrap_or(true) {
                return Err(Error::NotBareName(n.to_string()));
            }
            let p = dir.join(n);
            std::fs::metadata(&p).map_err(|e| Error::Io(p, e))?;
            out.push(n.to_string());
        }
        if out.is_empty() {
            return Err(Error::NoFiles);
        }
        return Ok(out);
    }
    let rd = std::fs::read_dir(dir).map_err(|e| Error::Io(dir.to_path_buf(), e))?;
    let mut out = BTreeSet::new();
    for entry in rd {
        let entry = entry.map_err(|e| Error::Io(dir.to_path_buf(), e))?;
        let name = entry.file_name().to_string_lossy().to_string();
        if name.ends_with(".sql") && entry.path().is_file() {
            out.insert(name);
        }
    }
    if out.is_empty() {
        return Err(Error::EmptyDir(dir.to_path_buf()));
    }
    Ok(out.into_iter().collect())
}

/// Split a SQL script into individually-executable statements.
///
/// BYTE-PRESERVING: it decides only where to cut, never rewrites content. That
/// matters because mysqldump's `/*!40101 SET ... */` conditional comments are
/// executed by the server rather than ignored — stripping them (which a
/// classifier legitimately does) would change what the script means.
///
/// Single quotes, double quotes, backticks, backslash escapes, `/* */` blocks
/// and `--`/`#` line comments are tracked purely so a `;` inside any of them
/// does not split a statement.
///
/// LIMIT, stated rather than discovered: no `DELIMITER` support, so a script
/// carrying a trigger/procedure/function body is out of scope. Check for one
/// before pointing this at a dump.
pub fn split_statements(sql: &str) -> Vec<String> {
    let b = sql.as_bytes();
    let mut out = Vec::new();
    let mut cur = String::new();
    let (mut in_single, mut in_double, mut in_back) = (false, false, false);
    let (mut in_block, mut in_line) = (false, false);
    let mut i = 0usize;

    while i < b.len() {
        let c = b[i] as char;

        if in_line {
            cur.push(c);
            if c == '\n' {
                in_line = false;
            }
            i += 1;
            continue;
        }
        if in_block {
            cur.push(c);
            if c == '*' && i + 1 < b.len() && b[i + 1] == b'/' {
                cur.push('/');
                i += 2;
                in_block = false;
                continue;
            }
            i += 1;
            continue;
        }
        if in_single || in_double || in_back {
            cur.push(c);
            if c == '\\' && (in_single || in_double) && i + 1 < b.len() {
                cur.push(b[i + 1] as char);
                i += 2;
                continue;
            }
            if c == '\'' && in_single {
                // '' is an escaped quote, not a close.
                if i + 1 < b.len() && b[i + 1] == b'\'' {
                    cur.push('\'');
                    i += 2;
                    continue;
                }
                in_single = false;
            } else if c == '"' && in_double {
                in_double = false;
            } else if c == '`' && in_back {
                in_back = false;
            }
            i += 1;
            continue;
        }

        if c == '-'
            && i + 2 < b.len()
            && b[i + 1] == b'-'
            && (b[i + 2] == b' ' || b[i + 2] == b'\t')
        {
            in_line = true;
            cur.push(c);
        } else if c == '#' {
            in_line = true;
            cur.push(c);
        } else if c == '/' && i + 1 < b.len() && b[i + 1] == b'*' {
            in_block = true;
            cur.push_str("/*");
            i += 2;
            continue;
        } else if c == '\'' {
            in_single = true;
            cur.push(c);
        } else if c == '"' {
            in_double = true;
            cur.push(c);
        } else if c == '`' {
            in_back = true;
            cur.push(c);
        } else if c == ';' {
            push_statement(&mut out, &mut cur);
        } else {
            cur.push(c);
        }
        i += 1;
    }
    push_statement(&mut out, &mut cur);
    out
}

fn push_statement(out: &mut Vec<String>, cur: &mut String) {
    let s = cur.trim().to_string();
    cur.clear();
    if s.is_empty() || is_noop(&s) {
        return;
    }
    out.push(s);
}

/// Whether a fragment carries no executable SQL — only comments and whitespace.
/// A trailing comment block must not become a statement; the server rejects a
/// comment-only statement as a syntax error.
pub fn is_noop(s: &str) -> bool {
    let b = s.as_bytes();
    let mut i = 0usize;
    let (mut in_block, mut in_line) = (false, false);
    let mut body = String::new();
    while i < b.len() {
        let c = b[i] as char;
        if in_line {
            if c == '\n' {
                in_line = false;
            }
            i += 1;
            continue;
        }
        if in_block {
            if c == '*' && i + 1 < b.len() && b[i + 1] == b'/' {
                in_block = false;
                i += 2;
                continue;
            }
            i += 1;
            continue;
        }
        if c == '-'
            && i + 2 < b.len()
            && b[i + 1] == b'-'
            && (b[i + 2] == b' ' || b[i + 2] == b'\t')
        {
            in_line = true;
        } else if c == '#' {
            in_line = true;
        } else if c == '/' && i + 1 < b.len() && b[i + 1] == b'*' {
            // A conditional comment IS executable, so it is not a no-op.
            if i + 2 < b.len() && b[i + 2] == b'!' {
                return false;
            }
            in_block = true;
            i += 2;
            continue;
        } else {
            body.push(c);
        }
        i += 1;
    }
    body.trim().is_empty()
}

/// MySQL error numbers meaning "this already ran".
///
/// 1007 database exists · 1022 duplicate key · 1050 table exists ·
/// 1060 duplicate column · 1061 duplicate key name · 1062 duplicate entry ·
/// 1291 duplicate enum value · 1826 duplicate foreign key
const MYSQL_ALREADY_APPLIED: &[&str] = &[
    "1007", "1022", "1050", "1060", "1061", "1062", "1291", "1826",
];

/// PostgreSQL SQLSTATEs meaning "this already ran".
///
/// 42P07 duplicate_table · 42701 duplicate_column · 42P06 duplicate_schema ·
/// 42P16 invalid_table_definition(dup) · 23505 unique_violation ·
/// 42710 duplicate_object · 42P04 duplicate_database
const PG_ALREADY_APPLIED: &[&str] = &["42P07", "42701", "42P06", "23505", "42710", "42P04"];

/// Whether a driver error code means the statement was already applied.
///
/// This is what replaces `psql`/`mysql --force`. `--force` continued past EVERY
/// error and still exited 0, so a genuinely missing table (MySQL 1146) was
/// indistinguishable from a re-run. Only this family is tolerated; everything
/// else fails loudly.
pub fn is_already_applied(code: Option<&str>) -> bool {
    match code {
        None => false,
        Some(c) => MYSQL_ALREADY_APPLIED.contains(&c) || PG_ALREADY_APPLIED.contains(&c),
    }
}

/// Truncated first line of a statement, for error messages that name the
/// offender. `--force` printed a bare error with no indication which statement
/// produced it.
pub fn first_line(s: &str) -> String {
    let line = s.lines().next().unwrap_or("");
    if line.chars().count() > 160 {
        let t: String = line.chars().take(160).collect();
        format!("{t} ...")
    } else {
        line.to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn splits_plain_statements() {
        let got = split_statements("CREATE TABLE a (id int);\nCREATE TABLE b (id int);\n");
        assert_eq!(got.len(), 2, "{got:?}");
        assert!(got[0].starts_with("CREATE TABLE a"));
        assert!(got[1].starts_with("CREATE TABLE b"));
    }

    #[test]
    fn preserves_conditional_comments() {
        // The server executes /*!...*/; dropping it changes what the dump means.
        let got = split_statements(
            "/*!40101 SET @OLD_CHARACTER_SET_CLIENT=@@CHARACTER_SET_CLIENT */;\nCREATE TABLE a (id int);\n",
        );
        assert_eq!(got.len(), 2, "{got:?}");
        assert!(got[0].contains("/*!40101"), "{:?}", got[0]);
        assert!(got[0].contains("*/"), "{:?}", got[0]);
    }

    #[test]
    fn semicolon_inside_literal_does_not_split() {
        assert_eq!(split_statements("INSERT INTO t VALUES ('a;b');\n").len(), 1);
    }

    #[test]
    fn doubled_quote_escape_survives() {
        let got =
            split_statements("INSERT INTO t VALUES ('it''s; fine');\nCREATE TABLE b (id int);\n");
        assert_eq!(got.len(), 2, "{got:?}");
        assert!(got[0].contains("it''s; fine"));
    }

    #[test]
    fn backslash_escaped_quote_survives() {
        let got = split_statements("INSERT INTO t VALUES ('a\\'; still inside');\n");
        assert_eq!(got.len(), 1, "{got:?}");
    }

    #[test]
    fn semicolon_in_line_comment_does_not_split() {
        let got = split_statements("-- a comment; with a semicolon\nCREATE TABLE a (id int);\n");
        assert_eq!(got.len(), 1, "{got:?}");
        // Counting statements is NOT enough, and a mutation proved it: drop the
        // line-comment tracking and the `;` splits mid-comment into
        // ["-- a comment", "with a semicolon\nCREATE TABLE a (id int)"]. The first
        // is comment-only so is_noop drops it, leaving exactly ONE statement that
        // still contains "CREATE TABLE a" -- so len + contains("CREATE TABLE")
        // passes against mangled SQL. The discriminator is that the comment must
        // survive INTACT and attached, since the splitter is byte-preserving.
        assert!(
            got[0].starts_with("-- a comment; with a semicolon"),
            "the comment was split or lost: {:?}",
            got[0]
        );
        assert!(got[0].contains("CREATE TABLE a"), "{:?}", got[0]);
    }

    #[test]
    fn semicolon_in_block_comment_does_not_split() {
        let got = split_statements("/* a block; comment */\nCREATE TABLE a (id int);\n");
        assert_eq!(got.len(), 1, "{got:?}");
        // Same trap as the line-comment case: without block tracking the `;` splits
        // inside the comment and the surviving fragment starts at "comment */", so
        // assert the block survives whole rather than just counting statements.
        assert!(
            got[0].starts_with("/* a block; comment */"),
            "the block comment was split or lost: {:?}",
            got[0]
        );
    }

    #[test]
    fn comment_only_trailer_is_dropped() {
        // Sending a comment-only fragment to the server is a syntax error.
        assert_eq!(
            split_statements("CREATE TABLE a (id int);\n-- Dump completed\n").len(),
            1
        );
    }

    #[test]
    fn backticked_identifier_with_semicolon_survives() {
        assert_eq!(
            split_statements("CREATE TABLE `we;ird` (id int);\n").len(),
            1
        );
    }

    #[test]
    fn noop_classification() {
        for s in [
            "-- just a comment",
            "/* just a block */",
            "# hash",
            "",
            "  \n\t ",
        ] {
            assert!(is_noop(s), "{s:?} should be a no-op");
        }
        for s in [
            "/*!40101 SET x=1 */",
            "CREATE TABLE a (id int)",
            "-- lead\nCREATE TABLE a (b int)",
        ] {
            assert!(!is_noop(s), "{s:?} should NOT be a no-op");
        }
    }

    #[test]
    fn already_applied_covers_only_the_expected_family() {
        for c in [
            "1007", "1022", "1050", "1060", "1061", "1062", "1291", "1826",
        ] {
            assert!(is_already_applied(Some(c)), "mysql {c} should be tolerated");
        }
        for c in ["42P07", "42701", "42P06", "23505", "42710", "42P04"] {
            assert!(is_already_applied(Some(c)), "pg {c} should be tolerated");
        }
        // MySQL 1146 "Table doesn't exist" is the one --force swallowed while a
        // column silently never landed. It must fail.
        for c in ["1146", "1049", "1045", "1064", "1054", "42P01"] {
            assert!(!is_already_applied(Some(c)), "{c} must NOT be tolerated");
        }
        assert!(!is_already_applied(None));
    }

    #[test]
    fn sentinels_parse_and_reject() {
        let got = parse_sentinels("authdb.accesses, uamdb.roles_auth_methods_assoc").unwrap();
        assert_eq!(got.len(), 2);
        assert_eq!(got[0].schema, "authdb");
        assert_eq!(got[0].table, "accesses");
        for bad in ["", "   ", "nodot", "a.", ".b", ","] {
            assert!(parse_sentinels(bad).is_err(), "{bad:?} should be rejected");
        }
    }

    #[test]
    fn files_explicit_order_is_verbatim_and_validated() {
        let dir = tempfile::tempdir().unwrap();
        for n in ["b.sql", "a.sql", "notes.txt"] {
            std::fs::write(dir.path().join(n), "SELECT 1;").unwrap();
        }
        // Explicit order preserved — apply order is load-bearing.
        let got = resolve_files(dir.path(), "b.sql,a.sql").unwrap();
        assert_eq!(got, vec!["b.sql", "a.sql"]);
        // Scan is sorted and .sql-only.
        let got = resolve_files(dir.path(), "").unwrap();
        assert_eq!(got, vec!["a.sql", "b.sql"]);
        // A missing file fails loudly instead of being skipped.
        assert!(resolve_files(dir.path(), "absent.sql").is_err());
        // A path is rejected rather than silently basename'd.
        assert!(resolve_files(dir.path(), "../escape.sql").is_err());
        let empty = tempfile::tempdir().unwrap();
        assert!(resolve_files(empty.path(), "").is_err());
    }

    #[test]
    fn first_line_truncates() {
        assert_eq!(first_line("CREATE TABLE a\n(id int)"), "CREATE TABLE a");
        let long = "x".repeat(300);
        assert!(first_line(&long).ends_with(" ..."));
    }
}
