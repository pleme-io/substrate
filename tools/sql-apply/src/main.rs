//! sql-apply — typed SQL migration runner. Replaces the `writeShellScript`
//! bodies `lib/service/db-migration.nix` used to ship.
//!
//! Three subcommands, each parameterized so one binary serves every consumer
//! rather than a fresh shell block per chart:
//!
//!   sql-apply wait                                    retry until the server answers
//!   sql-apply wait-tables --sentinel db.table,...      poll until every table exists
//!   sql-apply apply --dir DIR [--files a.sql,b.sql]    apply, statement at a time
//!
//! The connection comes from --url or $DATABASE_URL, which is the same env
//! contract db-migration.nix's shell runner already used, so the swap is a
//! drop-in for its consumers. The scheme selects the driver (mysql:// or
//! postgres://), so $DATABASE_CLI is no longer needed — and neither is a
//! database CLI, nor a shell, in the image.

use std::path::PathBuf;
use std::time::Duration;

use clap::{Parser, Subcommand};
use sqlx::any::{install_default_drivers, AnyConnectOptions};
use sqlx::{AnyConnection, ConnectOptions, Connection, Executor, Row};

use sql_apply::{
    first_line, is_already_applied, parse_sentinels, resolve_files, split_statements, Sentinel,
};

#[derive(Parser)]
#[command(
    name = "sql-apply",
    about = "Typed SQL migration runner: wait / wait-tables / apply. No shell, no database CLI.",
    version
)]
struct Cli {
    /// Connection URL (mysql://… or postgres://…). Defaults to $DATABASE_URL.
    #[arg(long, global = true, env = "DATABASE_URL")]
    url: Option<String>,
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    /// Retry a trivial query until the server answers.
    Wait {
        #[arg(long, default_value_t = 60)]
        tries: u32,
        #[arg(long, default_value = "5s", value_parser = humantime::parse_duration)]
        interval: Duration,
    },
    /// Poll until every db.table sentinel exists.
    WaitTables {
        /// Comma-separated db.table pairs that must all exist.
        #[arg(long)]
        sentinel: String,
        #[arg(long, default_value_t = 90)]
        tries: u32,
        #[arg(long, default_value = "5s", value_parser = humantime::parse_duration)]
        interval: Duration,
    },
    /// Apply .sql files, one statement at a time.
    Apply {
        /// Directory the SQL is mounted at.
        #[arg(long, default_value = "/migrations")]
        dir: PathBuf,
        /// Ordered comma-separated filenames. Empty = every .sql in --dir, sorted.
        #[arg(long, default_value = "")]
        files: String,
        /// Continue past the already-exists error family. Replaces
        /// `mysql --force`, which continued past EVERY error and still exited 0.
        #[arg(long)]
        tolerate_already_applied: bool,
    },
}

fn main() -> std::process::ExitCode {
    match real_main() {
        Ok(()) => std::process::ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("sql-apply: {e}");
            std::process::ExitCode::FAILURE
        }
    }
}

#[tokio::main(flavor = "current_thread")]
async fn real_main() -> anyhow::Result<()> {
    install_default_drivers();
    let cli = Cli::parse();
    let url = cli
        .url
        .clone()
        .ok_or_else(|| anyhow::anyhow!("--url or $DATABASE_URL is required"))?;

    match &cli.cmd {
        Cmd::Wait { tries, interval } => wait(&url, *tries, *interval).await,
        Cmd::WaitTables {
            sentinel,
            tries,
            interval,
        } => {
            let sentinels = parse_sentinels(sentinel)?;
            wait_tables(&url, &sentinels, *tries, *interval).await
        }
        Cmd::Apply {
            dir,
            files,
            tolerate_already_applied,
        } => apply(&url, dir, files, *tolerate_already_applied).await,
    }
}

async fn connect(url: &str) -> anyhow::Result<AnyConnection> {
    let opts: AnyConnectOptions = url.parse()?;
    // The runner's own logging is the receipt; the driver's per-statement chatter
    // would bury it.
    Ok(opts.disable_statement_logging().connect().await?)
}

async fn wait(url: &str, tries: u32, interval: Duration) -> anyhow::Result<()> {
    println!("== waiting for the database ==");
    let mut last: Option<String> = None;
    for i in 1..=tries {
        match connect(url).await {
            Ok(mut c) => {
                if let Err(e) = c.execute("SELECT 1").await {
                    last = Some(e.to_string());
                } else {
                    let _ = c.close().await;
                    println!("== database ready after {i} tries ==");
                    return Ok(());
                }
            }
            Err(e) => last = Some(e.to_string()),
        }
        if i < tries {
            tokio::time::sleep(interval).await;
        }
    }
    // The shell printed only "did not become ready"; the real error is what says
    // whether this is DNS, auth, or a cold server.
    anyhow::bail!(
        "not ready after {tries} tries: {}",
        last.unwrap_or_else(|| "no error recorded".into())
    )
}

async fn wait_tables(
    url: &str,
    sentinels: &[Sentinel],
    tries: u32,
    interval: Duration,
) -> anyhow::Result<()> {
    println!("== waiting for {} sentinel tables ==", sentinels.len());
    let mut missing: Vec<String> = Vec::new();
    for i in 1..=tries {
        match missing_tables(url, sentinels).await {
            Ok(m) if m.is_empty() => {
                println!("== all sentinel tables present after {i} tries ==");
                return Ok(());
            }
            Ok(m) => {
                println!("-- try {i}/{tries} still missing: {}", m.join(" "));
                missing = m;
            }
            Err(e) => println!("-- try {i}/{tries}: {e}"),
        }
        if i < tries {
            tokio::time::sleep(interval).await;
        }
    }
    anyhow::bail!(
        "still missing {} after {tries} tries -- the migration this depends on may not have completed",
        missing.join(" ")
    )
}

async fn missing_tables(url: &str, sentinels: &[Sentinel]) -> anyhow::Result<Vec<String>> {
    let mut c = connect(url).await?;
    let mut missing = Vec::new();
    for s in sentinels {
        // information_schema is ANSI and present on both backends, so one query
        // serves mysql and postgres alike.
        let row = sqlx::query(
            "SELECT COUNT(*) FROM information_schema.tables \
             WHERE table_schema = ? AND table_name = ?",
        )
        .bind(&s.schema)
        .bind(&s.table)
        .fetch_one(&mut c)
        .await?;
        let n: i64 = row.try_get::<i64, _>(0).or_else(|_| {
            // MySQL returns BIGINT UNSIGNED for COUNT(*); Postgres returns int8.
            row.try_get::<i32, _>(0).map(i64::from)
        })?;
        if n == 0 {
            missing.push(format!("{}.{}", s.schema, s.table));
        }
    }
    let _ = c.close().await;
    Ok(missing)
}

async fn apply(url: &str, dir: &PathBuf, files: &str, tolerate: bool) -> anyhow::Result<()> {
    let names = resolve_files(dir, files)?;
    let mut c = connect(url).await?;
    println!(
        "== applying {} files from {} ==",
        names.len(),
        dir.display()
    );
    let mut total_tolerated = 0usize;
    for name in &names {
        let path = dir.join(name);
        let body = std::fs::read_to_string(&path)
            .map_err(|e| anyhow::anyhow!("{}: {e}", path.display()))?;
        let stmts = split_statements(&body);
        println!("-- {name}: {} statements", stmts.len());
        let mut applied = 0usize;
        let mut tolerated = 0usize;
        for (i, s) in stmts.iter().enumerate() {
            if let Err(e) = c.execute(s.as_str()).await {
                let code = match &e {
                    sqlx::Error::Database(db) => db.code().map(|c| c.to_string()),
                    _ => None,
                };
                if tolerate && is_already_applied(code.as_deref()) {
                    tolerated += 1;
                    continue;
                }
                // Name the statement. `--force` printed a bare error with no
                // indication of which statement produced it.
                anyhow::bail!(
                    "{name}: statement {}/{} failed: {e}\n    {}",
                    i + 1,
                    stmts.len(),
                    first_line(s)
                );
            }
            applied += 1;
        }
        total_tolerated += tolerated;
        println!("   {name}: {applied} applied, {tolerated} already present");
    }
    let _ = c.close().await;
    println!("== all files applied ({total_tolerated} statements already present) ==");
    Ok(())
}
