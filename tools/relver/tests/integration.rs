//! Integration tests against a REAL `git` repo in a tempdir — git itself is the
//! (substitution-mockable) environment, so no network and no mocks-of-mocks.

use std::path::Path;
use std::process::Command;

use relver::{next, Bump, Discover, Git, NextArgs};

fn git(repo: &Path, args: &[&str]) {
    let s = Command::new("git")
        .arg("-C")
        .arg(repo)
        .args(args)
        .status()
        .unwrap();
    assert!(s.success(), "git {args:?} failed");
}

fn init_repo(d: &Path) {
    git(d, &["init", "-q"]);
    git(d, &["config", "user.email", "t@t"]);
    git(d, &["config", "user.name", "t"]);
    git(d, &["config", "commit.gpgsign", "false"]);
}

fn mk<'a>(globs: Vec<&'a str>, create: bool) -> NextArgs<'a> {
    NextArgs {
        bump: Bump::Patch,
        tag_glob: "v0.*",
        prefix: "v",
        discover: Discover::List,
        changed_globs: globs,
        seed: "v0.1.0",
        create_tag: create,
        push: false,
        msg_template: "release: {tag}",
        identity_name: "t",
        identity_email: "t@t",
    }
}

#[test]
fn changed_since_respects_globs() {
    let tmp = tempfile::tempdir().unwrap();
    let d = tmp.path();
    init_repo(d);
    std::fs::create_dir_all(d.join("lib")).unwrap();
    std::fs::write(d.join("lib/a.rs"), "x").unwrap();
    git(d, &["add", "-A"]);
    git(d, &["commit", "-qm", "init"]);
    git(d, &["tag", "-a", "v0.1.0", "-m", "v0.1.0"]);
    std::fs::write(d.join("lib/a.rs"), "y").unwrap();
    git(d, &["add", "-A"]);
    git(d, &["commit", "-qm", "touch lib"]);

    let g = Git { repo: d };
    let last = g.last_tag_list("v0.*", "v").unwrap().unwrap();
    assert_eq!(last.to_string(), "v0.1.0");
    assert!(g.changed_since(&last, &["lib/"]).unwrap());
    assert!(!g.changed_since(&last, &["docs/"]).unwrap());
}

#[test]
fn next_seeds_when_no_tag() {
    let tmp = tempfile::tempdir().unwrap();
    let d = tmp.path();
    init_repo(d);
    std::fs::write(d.join("f"), "x").unwrap();
    git(d, &["add", "-A"]);
    git(d, &["commit", "-qm", "init"]);

    let out = next(d, &mk(vec!["."], false)).unwrap();
    let s = out.rendered();
    assert!(s.contains("skip=false"), "{s}");
    assert!(s.contains("tag=v0.1.0"), "{s}");
}

#[test]
fn next_bumps_and_is_idempotent() {
    let tmp = tempfile::tempdir().unwrap();
    let d = tmp.path();
    init_repo(d);
    std::fs::create_dir_all(d.join("lib")).unwrap();
    std::fs::write(d.join("lib/a"), "1").unwrap();
    git(d, &["add", "-A"]);
    git(d, &["commit", "-qm", "init"]);
    git(d, &["tag", "-a", "v0.4.2", "-m", "v0.4.2"]);
    std::fs::write(d.join("lib/a"), "2").unwrap();
    git(d, &["add", "-A"]);
    git(d, &["commit", "-qm", "change"]);

    let out = next(d, &mk(vec!["lib/"], true)).unwrap();
    let s = out.rendered();
    assert!(s.contains("tag=v0.4.3"), "{s}");
    assert!(s.contains("created=true"), "{s}");

    // Second run on the same commit: tag already exists → created=false.
    let out2 = next(d, &mk(vec!["lib/"], true)).unwrap();
    assert!(out2.rendered().contains("created=false"), "{}", out2.rendered());
}

#[test]
fn next_skips_when_unchanged() {
    let tmp = tempfile::tempdir().unwrap();
    let d = tmp.path();
    init_repo(d);
    std::fs::create_dir_all(d.join("lib")).unwrap();
    std::fs::write(d.join("lib/a"), "1").unwrap();
    std::fs::write(d.join("README"), "r").unwrap();
    git(d, &["add", "-A"]);
    git(d, &["commit", "-qm", "init"]);
    git(d, &["tag", "-a", "v0.4.2", "-m", "v0.4.2"]);
    // change only README, not lib/
    std::fs::write(d.join("README"), "r2").unwrap();
    git(d, &["add", "-A"]);
    git(d, &["commit", "-qm", "docs only"]);

    let out = next(d, &mk(vec!["lib/"], false)).unwrap();
    assert!(out.rendered().contains("skip=true"), "{}", out.rendered());
}
