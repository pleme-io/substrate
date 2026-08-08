# directive.nix — the ONE projection of "is this module's `go` directive
# satisfiable against the fleet toolchain?".
#
# ── THE MEASURED FACT, and the precision that matters ───────────────────
#
# cmd/go orders a bare `1.N` STRICTLY BELOW `1.N.0`, and a module's `go`
# directive must be >= every module in its graph. So `go 1.25` against a
# dependency declaring `go 1.25.0` needs an update.
#
# But "bare-minor is unsatisfiable" — the framing this file replaces — is TOO
# STRONG, and the difference decides the remediation. Reproduced on go1.25.10
# with a two-module local `replace`:
#
#   GOFLAGS=-mod=mod       -> BUILDS, and go SILENTLY REWRITES `go 1.25`
#                             to `go 1.25.0` in go.mod
#   GOFLAGS=-mod=readonly  -> go: updates to go.mod needed, disabled by
#                             -mod=readonly; to update it: go mod tidy
#
# The failure is real and it is what every hermetic Nix build hits, because
# `-mod=readonly` and `-mod=vendor` are the sandboxed modes. It is NOT a
# universal build failure. 29 of 69 Nix-Go repos are bare-minor, so a blanket
# throw would break 29 repos in one commit to fix a class that self-heals on
# the loose path.
#
# CONSEQUENCE, adopted deliberately: `BareMinor` is a WARNING here, not a
# throw. Escalating it has a COUNTED done-predicate —
# `gen adopt-go --dry-run --all` reporting `bare-minor-directive == 0` — rather
# than a judgement call. Only `AboveFleetToolchain` throws, and it has 0 fleet
# offenders today, so the throw ships with nothing to break.
#
# ── WHY ONE FILE ────────────────────────────────────────────────────────
#
# The same predicate is needed by substrate (Nix, at build time) and by gen
# (Rust, in `adopt-go`). Two implementations of one ordering rule is how the
# producer and consumer of `Go.gen.lock` came to disagree on 12 of 13 fields.
# `directive-vectors.json` is the ONE committed table both sides read, so a
# single byte edit there must turn BOTH suites red. If only one goes red, the
# second copy that must not exist does exist.
#
# IFD-free: `compareVersions` and string ops only, no derivation is built.
{ lib }:
let
  # A directive is "bare minor" when it has exactly one dot: `1.25`, not
  # `1.25.0`. Measured above: cmd/go sorts that BELOW the patch form.
  dotCount = s: builtins.length (builtins.filter (x: x == ".") (lib.stringToCharacters s));

  parse = raw:
    let s = lib.trim raw; in
    if s == "" then { kind = "absent"; value = null; }
    else if dotCount s == 1 then { kind = "bare-minor"; value = s; }
    else if dotCount s == 2 then { kind = "patch"; value = s; }
    else { kind = "unparseable"; value = s; };

  # classify :: { directive, fleetGo } -> { verdict, directive, fleetGo, why }
  #
  # Verdict arms are CLOSED. Adding one means adding a vector row for it, which
  # `tests/directive-test.nix` asserts — an arm with no vector is the vacuity
  # this design exists to avoid.
  classify = { directive, fleetGo }:
    let p = parse directive; in
    if p.kind == "absent" then {
      verdict = "no-directive";
      inherit directive fleetGo;
      why = "go.mod declares no `go` directive; cmd/go assumes a very old language version";
    }
    else if p.kind == "unparseable" then {
      verdict = "unparseable";
      inherit directive fleetGo;
      why = "the `go` directive is not `1.N` or `1.N.P`";
    }
    # Above the fleet toolchain is a HARD failure: cmd/go refuses to build a
    # module that requires a newer language version than the toolchain running.
    else if builtins.compareVersions p.value fleetGo > 0 then {
      verdict = "above-fleet-toolchain";
      inherit directive fleetGo;
      why = "the module requires a newer Go than the fleet toolchain — cmd/go refuses to build it";
    }
    else if p.kind == "bare-minor" then {
      verdict = "bare-minor";
      inherit directive fleetGo;
      why = "cmd/go orders `1.N` below `1.N.0`, so a dependency declaring the patch form forces an update. "
          + "Builds under -mod=mod (go rewrites go.mod silently); FAILS under -mod=readonly/-mod=vendor, "
          + "which is every hermetic Nix build. Remediation is one line: `1.N` -> `1.N.0`.";
    }
    else {
      verdict = "satisfiable";
      inherit directive fleetGo;
      why = "patch-pinned and not above the fleet toolchain";
    };

  # The closed set. `tests/directive-test.nix` asserts every arm has >= 1 vector.
  verdictArms = [ "satisfiable" "bare-minor" "above-fleet-toolchain" "no-directive" "unparseable" ];

  # Read a module's directive out of go.mod, in pure Nix. `null` when the file
  # is unreadable — the caller decides what that means rather than this
  # silently reporting "absent", which is a different fact.
  directiveOf = goModPath:
    if !(builtins.pathExists goModPath) then null
    else
      let
        lines = lib.splitString "\n" (builtins.readFile goModPath);
        goLine = lib.findFirst (l: lib.hasPrefix "go " (lib.trim l)) null lines;
      in
      if goLine == null then "" else lib.trim (lib.removePrefix "go " (lib.trim goLine));
in
{
  inherit classify parse directiveOf verdictArms;
}
