/// The value every leg of the fixture agrees on.
///
/// ```
/// assert_eq!(wt_core::answer(), 42);
/// ```
pub fn answer() -> u32 {
    42
}

#[cfg(test)]
mod tests {
    // Passes only when cargo read the workspace's `[profile.dev]`
    // (`debug-assertions = false`, inherited by the test profile). A runner
    // that forced its own profile, or a builder that never reads Cargo
    // profiles at all, compiles this with debug assertions ON and fails.
    #[test]
    fn profile_is_honoured() {
        assert!(!cfg!(debug_assertions));
    }

    // The negative control's lever: the same fixture, run with
    // WT_FIXTURE_MUST_FAIL set, must turn the check red.
    #[test]
    fn negative_control_lever_is_unset() {
        assert!(std::env::var_os("WT_FIXTURE_MUST_FAIL").is_none());
    }

    #[test]
    fn answer_is_42() {
        assert_eq!(super::answer(), 42);
    }
}
