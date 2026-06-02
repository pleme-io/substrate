//! relver CLI — typed release-version primitive. See `lib.rs` for the core.
//!
//! Subcommands (closed-loop primitive composition — each does one thing,
//! `next` is the orchestration verb):
//!   relver next      — (a)+(b)+(c): compute next tag, gated on changed-globs,
//!                      optionally create+push. Emits skip/last/tag/changed/created.
//!   relver changed   — (a) only: skip/last/changed.
//!   relver compute   — (b) only, pure: tag from --last + --bump (seed if empty).
//!   relver tag       — (c) only: idempotent create+push of an explicit tag.
//!   relver parse     — parse a tag into components (debug).
//!
//! Output auto-detects: appends to `$GITHUB_OUTPUT` on a runner, else stdout.

use std::path::PathBuf;
use std::process::ExitCode;

use clap::{Parser, Subcommand};
use relver::{next, Bump, Discover, GhaOutput, Git, NextArgs, RelverError, SemverTag};

#[derive(Parser)]
#[command(name = "relver", about = "Typed release-version primitive (semver / changed-since-tag / idempotent tag)")]
struct Cli {
    /// Repository directory.
    #[arg(long, global = true, default_value = ".")]
    repo: PathBuf,
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    /// Compute the next tag from the last git tag, gated on a changed-globs
    /// diff; optionally create + push it. The a+b+c collapse.
    Next {
        #[arg(long, default_value = "patch")]
        bump: String,
        #[arg(long, default_value = "v0.*")]
        tag_glob: String,
        #[arg(long, default_value = "v")]
        prefix: String,
        /// list = `git tag -l --sort=-v:refname`; describe = `git describe`.
        #[arg(long, default_value = "list")]
        tag_discover: String,
        #[arg(long, num_args = 0.., value_delimiter = ' ')]
        changed_globs: Vec<String>,
        #[arg(long, default_value = "v0.1.0")]
        seed: String,
        #[arg(long)]
        create_tag: bool,
        #[arg(long)]
        push: bool,
        #[arg(long, default_value = "release: {tag}")]
        tag_message_template: String,
        #[arg(long, default_value = "github-actions[bot]")]
        identity_name: String,
        #[arg(long, default_value = "41898282+github-actions[bot]@users.noreply.github.com")]
        identity_email: String,
    },
    /// Shape (a) only: emit skip / last / changed.
    Changed {
        #[arg(long, default_value = "v0.*")]
        tag_glob: String,
        #[arg(long, default_value = "v")]
        prefix: String,
        #[arg(long, default_value = "list")]
        tag_discover: String,
        #[arg(long, num_args = 0.., value_delimiter = ' ')]
        changed_globs: Vec<String>,
    },
    /// Shape (b) only, pure (no git): emit tag from --last + --bump, or --seed
    /// when --last is absent.
    Compute {
        #[arg(long)]
        last: Option<String>,
        #[arg(long, default_value = "patch")]
        bump: String,
        #[arg(long, default_value = "v")]
        prefix: String,
        #[arg(long, default_value = "v0.1.0")]
        seed: String,
    },
    /// Shape (c) only: idempotent create + (optional) push of an explicit tag.
    Tag {
        #[arg(long)]
        tag: String,
        #[arg(long)]
        push: bool,
        #[arg(long, default_value = "release: {tag}")]
        tag_message_template: String,
        #[arg(long, default_value = "github-actions[bot]")]
        identity_name: String,
        #[arg(long, default_value = "41898282+github-actions[bot]@users.noreply.github.com")]
        identity_email: String,
    },
    /// Parse a semver tag into components (debug; prints JSON to stdout).
    Parse {
        tag: String,
        #[arg(long, default_value = "v")]
        prefix: String,
    },
}

fn discover(s: &str) -> Discover {
    match s {
        "describe" => Discover::Describe,
        _ => Discover::List,
    }
}

fn run() -> Result<(), RelverError> {
    let cli = Cli::parse();
    match cli.cmd {
        Cmd::Next {
            bump,
            tag_glob,
            prefix,
            tag_discover,
            changed_globs,
            seed,
            create_tag,
            push,
            tag_message_template,
            identity_name,
            identity_email,
        } => {
            let globs: Vec<&str> = changed_globs.iter().map(String::as_str).collect();
            let args = NextArgs {
                bump: Bump::parse_lenient(&bump),
                tag_glob: &tag_glob,
                prefix: &prefix,
                discover: discover(&tag_discover),
                changed_globs: globs,
                seed: &seed,
                create_tag,
                push,
                msg_template: &tag_message_template,
                identity_name: &identity_name,
                identity_email: &identity_email,
            };
            let out = next(&cli.repo, &args)?;
            out.commit()?;
        }
        Cmd::Changed {
            tag_glob,
            prefix,
            tag_discover,
            changed_globs,
        } => {
            let git = Git { repo: &cli.repo };
            let globs: Vec<&str> = changed_globs.iter().map(String::as_str).collect();
            let last = match discover(&tag_discover) {
                Discover::List => git.last_tag_list(&tag_glob, &prefix)?,
                Discover::Describe => git.last_tag_describe(&prefix)?,
            };
            let mut o = GhaOutput::default();
            match &last {
                None => {
                    o.kv("last", "");
                    o.flag("skip", false);
                    o.flag("changed", true);
                }
                Some(prev) => {
                    o.kv("last", &prev.to_string());
                    let changed = git.changed_since(prev, &globs)?;
                    o.flag("skip", !changed);
                    o.flag("changed", changed);
                }
            }
            o.commit()?;
        }
        Cmd::Compute {
            last,
            bump,
            prefix,
            seed,
        } => {
            let mut o = GhaOutput::default();
            let tag = match last.as_deref().filter(|s| !s.is_empty()) {
                Some(l) => SemverTag::parse(l, &prefix)?
                    .bumped(Bump::parse_lenient(&bump))
                    .to_string(),
                None => seed,
            };
            o.kv("tag", &tag);
            o.commit()?;
        }
        Cmd::Tag {
            tag,
            push,
            tag_message_template,
            identity_name,
            identity_email,
        } => {
            let git = Git { repo: &cli.repo };
            git.config_identity(&identity_name, &identity_email)?;
            let msg = tag_message_template.replace("{tag}", &tag);
            let created = git.create_tag(&tag, &msg)?;
            if push {
                git.push_tag(&tag)?;
            }
            let mut o = GhaOutput::default();
            o.kv("tag", &tag);
            o.flag("created", created);
            o.commit()?;
        }
        Cmd::Parse { tag, prefix } => {
            let v = SemverTag::parse(&tag, &prefix)?;
            // Debug JSON — println is the data-output surface (not format!()).
            println!(
                "{{\"prefix\":\"{}\",\"major\":{},\"minor\":{},\"patch\":{}}}",
                v.prefix, v.major, v.minor, v.patch
            );
        }
    }
    Ok(())
}

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("relver: {e}");
            ExitCode::FAILURE
        }
    }
}
