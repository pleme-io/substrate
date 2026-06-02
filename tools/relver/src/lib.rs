//! relver — typed release-version primitive.
//!
//! Replaces three bash logic shapes hand-rolled across pleme-io auto-bump
//! workflows (substrate / actions / gem / ansible):
//!   (a) source-changed-since-tag — `git tag -l`/`git describe` + `git diff --quiet`
//!   (b) semver-compute-next      — parse `vX.Y.Z`, bump patch|minor|major
//!   (c) idempotent tag create+push
//!
//! git is driven via [`std::process::Command`] (NOT `git2`): byte-exact git
//! semantics (`--sort=-v:refname`, pathspec globs) and zero C-dependency
//! closure. The testability contract is satisfied by running against a real
//! `git` repo in a tempdir — git itself is the (mockable-by-substitution)
//! environment.
//!
//! TYPED-EMISSION: no `std::format!()`. `SemverTag`'s `Display` is the only
//! place a tag string is composed; `GhaOutput` emits via `writeln!` into a
//! buffer; the git argv is built via `Command::arg` from typed pieces.

use std::fmt::Write as _;
use std::path::Path;
use std::process::Command;

use thiserror::Error;

/// Typed failure modes.
#[derive(Debug, Error)]
pub enum RelverError {
    #[error("git {0} failed (exit {1}): {2}")]
    Git(&'static str, i32, String),
    #[error("cannot parse semver tag {0:?}: {1}")]
    Parse(String, &'static str),
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
}

/// Which component to bump. `parse_lenient` mirrors the bash `patch|*)` arm:
/// any unknown value falls through to `Patch`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Bump {
    Major,
    Minor,
    Patch,
}

impl Bump {
    #[must_use]
    pub fn parse_lenient(s: &str) -> Self {
        match s.trim() {
            "major" => Bump::Major,
            "minor" => Bump::Minor,
            _ => Bump::Patch,
        }
    }
}

/// How to discover the most recent tag.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Discover {
    /// `git tag -l <glob> --sort=-v:refname | head -1` (substrate/actions).
    List,
    /// `git describe --tags --abbrev=0` (gem/ansible).
    Describe,
}

/// A `vMAJOR.MINOR.PATCH` tag. `prefix` preserves the literal `v` so we
/// round-trip exactly (bash strips with `${last#v}` then re-adds `v${maj}…`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SemverTag {
    pub prefix: String,
    pub major: u64,
    pub minor: u64,
    pub patch: u64,
}

impl SemverTag {
    /// Parse `v0.4.2`. Equivalent to bash `IFS='.' read maj min pat <<<"${t#v}"`.
    pub fn parse(tag: &str, prefix: &str) -> Result<Self, RelverError> {
        let body = tag
            .strip_prefix(prefix)
            .ok_or_else(|| RelverError::Parse(tag.into(), "missing prefix"))?;
        let mut it = body.splitn(3, '.');
        let major = it
            .next()
            .and_then(|s| s.parse().ok())
            .ok_or_else(|| RelverError::Parse(tag.into(), "major"))?;
        let minor = it
            .next()
            .and_then(|s| s.parse().ok())
            .ok_or_else(|| RelverError::Parse(tag.into(), "minor"))?;
        let patch = it
            .next()
            .and_then(|s| s.parse().ok())
            .ok_or_else(|| RelverError::Parse(tag.into(), "patch"))?;
        Ok(SemverTag {
            prefix: prefix.into(),
            major,
            minor,
            patch,
        })
    }

    /// (b) semver-compute-next — byte-for-byte the bash `case` arms.
    #[must_use]
    pub fn bumped(&self, b: Bump) -> SemverTag {
        let (mut maj, mut min, mut pat) = (self.major, self.minor, self.patch);
        match b {
            Bump::Major => {
                maj += 1;
                min = 0;
                pat = 0;
            }
            Bump::Minor => {
                min += 1;
                pat = 0;
            }
            Bump::Patch => pat += 1,
        }
        SemverTag {
            prefix: self.prefix.clone(),
            major: maj,
            minor: min,
            patch: pat,
        }
    }
}

/// `Display` is the ONLY tag-string render surface (TYPED-EMISSION).
impl std::fmt::Display for SemverTag {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}{}.{}.{}", self.prefix, self.major, self.minor, self.patch)
    }
}

/// Typed wrapper over the `git` argv — no raw `Command::new` scatter
/// (PRIME DIRECTIVE: a subprocess shape used ≥2 times becomes a typed fn).
pub struct Git<'a> {
    pub repo: &'a Path,
}

impl Git<'_> {
    fn run(&self, args: &[&str]) -> Result<std::process::Output, RelverError> {
        Ok(Command::new("git")
            .arg("-C")
            .arg(self.repo)
            .args(args)
            .output()?)
    }

    fn ok(&self, what: &'static str, args: &[&str]) -> Result<String, RelverError> {
        let out = self.run(args)?;
        if !out.status.success() {
            return Err(RelverError::Git(
                what,
                out.status.code().unwrap_or(-1),
                String::from_utf8_lossy(&out.stderr).into_owned(),
            ));
        }
        Ok(String::from_utf8_lossy(&out.stdout).trim().to_owned())
    }

    /// (a, list) `git tag -l <glob> --sort=-v:refname | head -1`. None if no match.
    pub fn last_tag_list(&self, glob: &str, prefix: &str) -> Result<Option<SemverTag>, RelverError> {
        let s = self.ok("tag -l", &["tag", "-l", glob, "--sort=-v:refname"])?;
        Ok(s.lines()
            .next()
            .and_then(|t| SemverTag::parse(t, prefix).ok()))
    }

    /// (a, describe) `git describe --tags --abbrev=0`. None on non-zero exit
    /// (matches the bash `|| echo ""`).
    pub fn last_tag_describe(&self, prefix: &str) -> Result<Option<SemverTag>, RelverError> {
        let out = self.run(&["describe", "--tags", "--abbrev=0"])?;
        if !out.status.success() {
            return Ok(None);
        }
        let t = String::from_utf8_lossy(&out.stdout).trim().to_owned();
        Ok(if t.is_empty() {
            None
        } else {
            SemverTag::parse(&t, prefix).ok()
        })
    }

    /// (a, diff) `git diff --quiet <last> HEAD -- <pathspecs>`. `--quiet` exits
    /// 1 iff there ARE changes, so `changed = !success`.
    pub fn changed_since(&self, last: &SemverTag, globs: &[&str]) -> Result<bool, RelverError> {
        let last_s = last.to_string();
        let mut args: Vec<&str> = vec!["diff", "--quiet", &last_s, "HEAD", "--"];
        args.extend_from_slice(globs);
        let out = self.run(&args)?;
        match out.status.code() {
            Some(0) => Ok(false),
            Some(1) => Ok(true),
            code => Err(RelverError::Git(
                "diff --quiet",
                code.unwrap_or(-1),
                String::from_utf8_lossy(&out.stderr).into_owned(),
            )),
        }
    }

    pub fn config_identity(&self, name: &str, email: &str) -> Result<(), RelverError> {
        self.ok("config name", &["config", "user.name", name])?;
        self.ok("config email", &["config", "user.email", email])?;
        Ok(())
    }

    fn tag_exists(&self, tag: &str) -> Result<bool, RelverError> {
        Ok(!self.ok("tag -l one", &["tag", "-l", tag])?.is_empty())
    }

    /// (c) idempotent annotated-tag create. Returns false if it already exists
    /// (an upgrade over the bash, which errors on a duplicate tag).
    pub fn create_tag(&self, tag: &str, msg: &str) -> Result<bool, RelverError> {
        if self.tag_exists(tag)? {
            return Ok(false);
        }
        self.ok("tag -a", &["tag", "-a", tag, "-m", msg])?;
        Ok(true)
    }

    /// (c) `git push origin <tag>`. Idempotent: already-on-remote ⇒ Ok.
    pub fn push_tag(&self, tag: &str) -> Result<(), RelverError> {
        let out = self.run(&["push", "origin", tag])?;
        if out.status.success() {
            return Ok(());
        }
        let err = String::from_utf8_lossy(&out.stderr);
        if err.contains("already exists") || err.contains("[up to date]") {
            return Ok(());
        }
        Err(RelverError::Git(
            "push",
            out.status.code().unwrap_or(-1),
            err.into_owned(),
        ))
    }
}

/// Typed `$GITHUB_OUTPUT` sink. Every line goes through `writeln!` into a
/// buffer (TYPED-EMISSION-allowed); committed atomically by append.
#[derive(Default)]
pub struct GhaOutput {
    buf: String,
}

impl GhaOutput {
    pub fn kv(&mut self, key: &str, val: &str) {
        let _ = writeln!(self.buf, "{key}={val}");
    }
    pub fn flag(&mut self, key: &str, v: bool) {
        self.kv(key, if v { "true" } else { "false" });
    }
    /// The raw buffer (for `--output json`/stdout local runs + tests).
    #[must_use]
    pub fn rendered(&self) -> &str {
        &self.buf
    }
    /// Append to `$GITHUB_OUTPUT` (runner) or print to stdout (local/test).
    pub fn commit(self) -> std::io::Result<()> {
        match std::env::var_os("GITHUB_OUTPUT") {
            Some(p) => {
                use std::io::Write;
                let mut f = std::fs::OpenOptions::new().create(true).append(true).open(p)?;
                f.write_all(self.buf.as_bytes())
            }
            None => {
                print!("{}", self.buf);
                Ok(())
            }
        }
    }
}

/// Args for [`next`] — the headline a+b+c collapse.
pub struct NextArgs<'a> {
    pub bump: Bump,
    pub tag_glob: &'a str,
    pub prefix: &'a str,
    pub discover: Discover,
    pub changed_globs: Vec<&'a str>,
    pub seed: &'a str,
    pub create_tag: bool,
    pub push: bool,
    pub msg_template: &'a str,
    pub identity_name: &'a str,
    pub identity_email: &'a str,
}

/// (a)+(b)+(c) in one shot. Emits `skip` / `last` / `tag` / `changed` /
/// `created` — the exact GITHUB_OUTPUT contract the workflows consume.
pub fn next(repo: &Path, a: &NextArgs<'_>) -> Result<GhaOutput, RelverError> {
    let git = Git { repo };
    let mut o = GhaOutput::default();

    let last = match a.discover {
        Discover::List => git.last_tag_list(a.tag_glob, a.prefix)?,
        Discover::Describe => git.last_tag_describe(a.prefix)?,
    };

    let (skip, tag) = match &last {
        None => {
            // No prior tag — bump (seed). (substrate L40-43)
            o.kv("last", "");
            (false, a.seed.to_owned())
        }
        Some(prev) => {
            o.kv("last", &prev.to_string());
            let changed = git.changed_since(prev, &a.changed_globs)?;
            (!changed, prev.bumped(a.bump).to_string())
        }
    };

    o.flag("skip", skip);
    o.flag("changed", !skip);
    o.kv("tag", &tag);

    let mut created = false;
    if !skip && (a.create_tag || a.push) {
        git.config_identity(a.identity_name, a.identity_email)?;
        let msg = a.msg_template.replace("{tag}", &tag);
        created = git.create_tag(&tag, &msg)?;
        if a.push {
            git.push_tag(&tag)?;
        }
    }
    o.flag("created", created);
    Ok(o)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bump_arms() {
        let v = SemverTag::parse("v0.4.2", "v").unwrap();
        assert_eq!(v.bumped(Bump::Patch).to_string(), "v0.4.3");
        assert_eq!(v.bumped(Bump::Minor).to_string(), "v0.5.0");
        assert_eq!(v.bumped(Bump::Major).to_string(), "v1.0.0");
    }

    #[test]
    fn bump_lenient_wildcard() {
        assert_eq!(Bump::parse_lenient("garbage"), Bump::Patch);
        assert_eq!(Bump::parse_lenient("patch"), Bump::Patch);
        assert_eq!(Bump::parse_lenient("major"), Bump::Major);
    }

    #[test]
    fn parse_roundtrip() {
        let v = SemverTag::parse("v12.3.45", "v").unwrap();
        assert_eq!((v.major, v.minor, v.patch), (12, 3, 45));
        assert_eq!(v.to_string(), "v12.3.45");
        assert!(SemverTag::parse("0.1.0", "v").is_err()); // missing prefix
        assert!(SemverTag::parse("vX.Y.Z", "v").is_err());
    }

    #[test]
    fn gha_output_lines() {
        let mut o = GhaOutput::default();
        o.kv("last", "v0.4.2");
        o.flag("skip", false);
        o.kv("tag", "v0.4.3");
        assert_eq!(o.rendered(), "last=v0.4.2\nskip=false\ntag=v0.4.3\n");
    }
}
