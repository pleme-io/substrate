// An integration test that compiles only if BOTH dev-dependencies resolved:
// the workspace-local dev-only member and the registry crate.

cfg_if::cfg_if! {
    if #[cfg(test)] {
        const LEG: &str = "dev-deps-resolved";
    } else {
        const LEG: &str = "unreachable";
    }
}

#[test]
fn dev_dependencies_resolve() {
    assert_eq!(LEG, "dev-deps-resolved");
    assert_eq!(wt_devonly::witness(), wt_core::answer());
}
