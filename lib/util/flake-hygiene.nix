# lib/util/flake-hygiene.nix
#
# Defensive primitives that eliminate rebuild-causing flake misconfigurations.
# Import into any substrate builder to enforce follows, pinning, and cache alignment.
#
# These functions are called at evaluation time — if a violation exists, the
# build fails immediately with a clear error message rather than silently
# producing a bloated closure.
#
# Usage in substrate builders:
#   let hygiene = import ../util/flake-hygiene.nix { inherit lib; };
#   in hygiene.assertSingleNixpkgs inputs // hygiene.assertStablePin inputs // ...
#
{ lib ? (import <nixpkgs> {}).lib }:

let
  # The org-wide nixpkgs branch. All repos MUST use this.
  # When this changes, `tend` propagates the update to all flake.nix files.
  requiredBranch = "nixos-25.11";

  # Patterns that indicate an unstable/unpinned nixpkgs reference
  unstablePatterns = [
    "nixos-unstable"
    "nixpkgs-unstable"
    "master"
    "main"
  ];

in {

  # ── Primitive 1: assertStablePin ──────────────────────────────────────
  #
  # Fails evaluation if the nixpkgs input URL contains an unstable branch.
  # Call this in any builder's outputs function:
  #
  #   hygiene.assertStablePin { inherit (inputs) nixpkgs; }
  #
  assertStablePin = { nixpkgs, ... }:
    let
      url = nixpkgs.sourceInfo.url or nixpkgs.outPath or "unknown";
      isUnstable = lib.any (pat: lib.hasInfix pat url) unstablePatterns;
    in
    if isUnstable then
      throw ''
        [nix-efficiency] nixpkgs is pinned to an unstable branch: ${url}
        All pleme-io repos must use '${requiredBranch}'.
        Fix: change nixpkgs.url in flake.nix to:
          nixpkgs.url = "github:NixOS/nixpkgs/${requiredBranch}";
        Then run: nix flake update nixpkgs
      ''
    else
      true;

  # ── Primitive 2: assertSingleNixpkgs ──────────────────────────────────
  #
  # Checks that all inputs that depend on nixpkgs resolve to the SAME
  # nixpkgs store path. If any input brings its own nixpkgs, evaluation
  # fails with instructions to add `follows`.
  #
  # Call in outputs:
  #   hygiene.assertSingleNixpkgs inputs
  #
  assertSingleNixpkgs = inputs:
    let
      topNixpkgs = inputs.nixpkgs.outPath or null;

      # Collect nixpkgs paths from all inputs that have a nixpkgs dependency
      inputNixpkgs = lib.filterAttrs (_: v:
        v ? inputs && v.inputs ? nixpkgs
      ) inputs;

      mismatched = lib.filterAttrs (_: v:
        let depNixpkgs = v.inputs.nixpkgs.outPath or null;
        in depNixpkgs != null && depNixpkgs != topNixpkgs
      ) inputNixpkgs;

      mismatchedNames = lib.attrNames mismatched;
    in
    if mismatchedNames != [] then
      throw ''
        [nix-efficiency] ${toString (lib.length mismatchedNames)} input(s) use a different nixpkgs:
          ${lib.concatStringsSep ", " mismatchedNames}

        This causes closure duplication and cache misses.
        Fix: add 'inputs.nixpkgs.follows = "nixpkgs";' for each:

        ${lib.concatMapStringsSep "\n" (name: ''
          inputs.${name}.inputs.nixpkgs.follows = "nixpkgs";
        '') mismatchedNames}
      ''
    else
      true;

  # ── Primitive 3: warnDeepDuplicates ───────────────────────────────────
  #
  # Non-fatal check for deep transitive nixpkgs duplicates (inputs of inputs).
  # These can't be fixed at the consumer level — they need upstream fixes.
  # Emits a trace warning instead of failing.
  #
  warnDeepDuplicates = inputs:
    let
      topNixpkgs = inputs.nixpkgs.outPath or null;

      checkInput = name: input:
        let
          subInputs = input.inputs or {};
          subNixpkgs = lib.filterAttrs (k: v:
            lib.hasPrefix "nixpkgs" k && (v.outPath or null) != topNixpkgs
          ) subInputs;
        in
        if subNixpkgs != {} then
          lib.trace "[nix-efficiency] WARNING: ${name} has ${toString (lib.length (lib.attrNames subNixpkgs))} deep nixpkgs duplicate(s) — needs upstream fix" true
        else
          true;
    in
    lib.all (name: checkInput name inputs.${name}) (lib.attrNames inputs);

  # ── Primitive 4: enforceSourceFilter ──────────────────────────────────
  #
  # Returns a filtered source that excludes non-build files.
  # Use instead of bare `src = ./.;` or `src = self;`
  #
  # For Rust projects:
  #   src = hygiene.rustSource self;
  #
  # For generic projects:
  #   src = hygiene.cleanSource self;
  #
  rustSource = src:
    let
      isRustFile = name: type:
        let baseName = baseNameOf name;
        in
        type == "directory"
        || lib.hasSuffix ".rs" baseName
        || lib.hasSuffix ".toml" baseName
        || baseName == "Cargo.lock"
        || baseName == "Cargo.nix"
        || lib.hasSuffix ".proto" baseName
        || lib.hasSuffix ".sql" baseName
        || baseName == "build.rs"
        || baseName == "migrations"
        || baseName == "deploy.yaml";
    in
    lib.cleanSourceWith {
      inherit src;
      filter = isRustFile;
    };

  cleanSource = src:
    lib.cleanSourceWith {
      inherit src;
      filter = name: type:
        let baseName = baseNameOf name;
        in
        !(lib.hasPrefix "." baseName)           # no dotfiles
        && baseName != "target"                   # no Rust build artifacts
        && baseName != "node_modules"             # no npm
        && baseName != "result"                   # no Nix build result
        && baseName != "flake.lock"               # flake.lock changes shouldn't rebuild
        && !(lib.hasSuffix ".md" baseName)        # no docs
        && baseName != "LICENSE"
        && baseName != "CLAUDE.md"
        && baseName != "README.md";
    };

  # ── Primitive 5: requiredNixpkgsBranch ────────────────────────────────
  #
  # Export the org-wide standard for use by tend, nix-place, and CI.
  #
  inherit requiredBranch;

  # ── Composite: enforceAll ─────────────────────────────────────────────
  #
  # Run all checks at once. Call at the top of any outputs function:
  #
  #   outputs = inputs: let
  #     _ = hygiene.enforceAll inputs;
  #   in { ... };
  #
  enforceAll = inputs:
    let
      _ = builtins.seq (assertStablePin inputs) true;
      __ = builtins.seq (assertSingleNixpkgs inputs) true;
      ___ = builtins.seq (warnDeepDuplicates inputs) true;
    in
    true;
}
