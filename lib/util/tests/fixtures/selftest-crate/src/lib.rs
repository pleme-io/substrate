//! Fixture crate proving the `cargo-test` leg actually EXECUTES tests.
//!
//! The green half of `devshell-cargo-test-selftest.yml` asserts on this
//! test's own output line (`test result: ok. 1 passed`). Two distinct
//! properties ride on that one assertion, and both matter:
//!
//!   * the test target COMPILED  — a devShell missing rustc/cargo cannot
//!     get this far, so a green proves the shell was really entered;
//!   * the test target RAN       — `nix flake check` returned exit 0 over
//!     crates that were never compiled, which is the defect that produced
//!     this whole workflow family. A job that reports success without a
//!     `test result:` line is that same failure wearing a different hat.
//!
//! Keep this crate trivial. Its job is to be an unambiguous liveness
//! signal for the harness, not to test substrate.

/// Trivial pure function; exists only to give the test something real to
/// evaluate rather than asserting a literal against itself.
pub fn devshell_entered() -> &'static str {
    "substrate-devshell-selftest"
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_cargo_test_leg_actually_runs() {
        assert_eq!(devshell_entered(), "substrate-devshell-selftest");
    }
}
