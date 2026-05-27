# pleme-crate-overrides — fleet-wide buildRustCrate quirks.
#
# This file holds only the residual third-party crate quirks that
# can't be subsumed at higher layers. Five entry classes are now
# eliminated via the layered abstractions below — each kept as a
# documented comment so the bug class is discoverable when the next
# crate of the same shape lands.
#
#   ELIMINATED (no per-crate entries needed):
#
#   1. ENV-VAR-AT-COMPILE-TIME (was: rmcp)
#      gen-cargo emits `preBuild = "export CARGO_CRATE_NAME=<rustc-name>"`
#      universally into `build_rust_crate_args`. Any crate reading
#      `env!("CARGO_CRATE_NAME")` at proc-macro expansion Just Works.
#
#   2. NATIVE LINKS (was: ring, all `*-sys`)
#      gen-cargo emits `links` from `[package].links` into the spec.
#      lockfile-builder threads it through buildRustCrate. Version
#      bumps no longer need a manual override.
#
#   3. NON-DEFAULT [lib] LAYOUT (was: document-features)
#      gen-cargo emits `lib_target = { name, path }` whenever the
#      crate's `[lib].name` or `[lib].path` deviates from defaults.
#      lockfile-builder threads `libName`/`libPath` through.
#
#   4. WORKSPACE-MEMBER BIN AUTO-DETECTION (was: alloc-no-stdlib,
#      alloc-stdlib, brotli, brotli-decompressor)
#      lockfile-builder's `binsFor` suppresses bin auto-detection for
#      all transitive deps uniformly.
#
#   5. SHAPE-MAPPING IN NIX (was: 16-line `extraFor` conditional ladder)
#      gen-cargo emits `build_rust_crate_args` already shaped for
#      buildRustCrate's mkArgs. lockfile-builder spreads it verbatim;
#      no per-field `if-then-else` salad in Nix.
#
#   The entries below address THREE residual classes that genuinely
#   need per-crate identification because the fix is content-specific:
#
#   - BUILD-SCRIPT CFG NOT PROPAGATED  →  `forceCfg`
#   - NESTED BUILD-DEP DROPPED         →  `foldNormalIntoBuild`
#   - UPSTREAM SOURCE BUG              →  bespoke prePatch
#
# Composition: `pkgs.defaultCrateOverrides // plemeCrateOverrides //
# userOverrides`. Override functions take `attrs → newAttrs`.
let
  # CLASS-HELPER: force a `--cfg foo` for the lib compile.
  #
  # Use when a crate's build.rs computes `cargo:rustc-cfg=foo` (often
  # via `cfg_aliases::cfg_aliases!`) but nixpkgs' buildRustCrate
  # doesn't propagate it to the LIB compile. The fleet-wide platform
  # (aarch64-darwin / x86_64-darwin / aarch64-linux / x86_64-linux)
  # always satisfies the source check, so forcing is safe.
  forceCfg = name: _: { extraRustcOpts = [ "--cfg" name ]; };

  # CLASS-HELPER: fold the crate's normal deps into its
  # buildDependencies so the build.rs can resolve them.
  #
  # Use when a crate has a build.rs that uses normal deps via `use
  # X::*` (edition 2021+) or `extern crate X`, AND the crate is
  # itself sometimes pulled as a transitive build-dep. nixpkgs'
  # buildRustCrate drops the inner build-dep tree in that path,
  # leaving target/buildDeps empty → unresolved-import errors. Optional
  # `externCrate` injects `extern crate <name>;` into build.rs for
  # edition 2021+ crates whose build.rs writes `use X::…` without an
  # explicit `extern crate` declaration.
  foldNormalIntoBuild = { externCrate ? null }: attrs: {
    buildDependencies = (attrs.buildDependencies or [])
      ++ (attrs.dependencies or []);
  } // (if externCrate != null then {
    prePatch = (attrs.prePatch or "") + ''
      # `extern crate` is a crate-root item; appending after inner
      # attrs is the safe placement (a leading occurrence would
      # trigger E0753 against `#![allow(...)]` at the top of build.rs).
      if [ -f build.rs ] && ! grep -q 'extern crate ${externCrate};' build.rs; then
        printf '\nextern crate ${externCrate};\n' >> build.rs
      fi
    '';
  } else {});

  # CLASS-HELPER: substitute one substring in a source file.
  # Use for upstream source bugs whose patch is a one-line fix.
  substituteSource = file: from: to: attrs: {
    prePatch = (attrs.prePatch or "") + ''
      if [ -f ${file} ]; then
        substituteInPlace ${file} \
          --replace-fail ${builtins.toJSON from} ${builtins.toJSON to}
      fi
    '';
  };
in {
  # nixpkgs' default override for proc-macro-crate v3.5.0+ tries to
  # `--replace-fail` a literal string that no longer exists. Clearing
  # postPatch defeats the obsolete substitution; the runtime code path
  # is env-only (`CARGO_MANIFEST_DIR`) so the inlining isn't needed.
  proc-macro-crate = _: { postPatch = ""; };

  # CLASS: build-script cfg not propagated. wgpu-* compute
  # `supports_64bit_atomics` via `cfg_aliases::cfg_aliases!`; the
  # `cargo:rustc-cfg=` output doesn't reach the LIB build. Force it.
  wgpu-hal   = forceCfg "supports_64bit_atomics";
  wgpu-core  = forceCfg "supports_64bit_atomics";
  wgpu       = forceCfg "supports_64bit_atomics";
  wgpu-types = forceCfg "supports_64bit_atomics";

  # CLASS: nested build-dep dropped. clang-sys 1.8.x's build.rs writes
  # `use glob::…` (edition 2021) and gets dropped when pulled as a
  # transitive build-dep via coreaudio-sys → bindgen. mime_guess does
  # the same with `extern crate unicase` (no extern-crate injection
  # needed — it's already in the build.rs source).
  clang-sys  = foldNormalIntoBuild { externCrate = "glob"; };
  mime_guess = foldNormalIntoBuild { };

  # CLASS: upstream source bug. openraft 0.9.24's
  # `src/metrics/wait.rs:231` does `let got = …collect();` without a
  # type annotation; when rkyv is also in target/deps (workspace
  # siblings pull it in), rustc sees two `BTreeSet: PartialEq` impls
  # and rejects inference. Patch the source. Drop this entry once
  # openraft 0.9.25+ lands with the annotation.
  openraft = substituteSource
    "src/metrics/wait.rs"
    "let got = m.membership_config.membership().voter_ids().collect();"
    "let got: std::collections::BTreeSet<_> = m.membership_config.membership().voter_ids().collect();";
}
