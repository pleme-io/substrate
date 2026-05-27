# pleme-crate-overrides — fleet-wide buildRustCrate quirks.
#
# Layered on top of nixpkgs' `pkgs.defaultCrateOverrides` via attrset
# merge. Each entry follows the same `oldAttrs: newAttrs` shape nixpkgs
# uses, so consumers compose:
#
#   pkgs.defaultCrateOverrides // plemeCrateOverrides // userOverrides
#
# Adding a new fleet-wide quirk is a one-line edit here. No spec
# regeneration, no schema bump — the override mechanism is Nix-native.
{
  # rmcp 0.15 reads env!("CARGO_CRATE_NAME") at compile time
  # (src/model.rs:860). nixpkgs' buildRustCrate only exports
  # CARGO_PKG_* / CARGO_CFG_* / CARGO_MANIFEST_* — not a top-level
  # attr. `preBuild` runs in the same shell as buildCrate, so exporting
  # there reaches rustc.
  rmcp = _: { preBuild = "export CARGO_CRATE_NAME=rmcp"; };

  # alloc-no-stdlib / alloc-stdlib / brotli / brotli-decompressor
  # all ship example/CLI binaries under `src/bin/*.rs`. Previously
  # each was hand-listed here with `crateBin = []`. As of substrate
  # rev 2843381 the lockfile-builder suppresses bin auto-detection
  # for ALL transitive deps uniformly, making these entries
  # redundant. Kept commented as documentation of the bug class.
  # alloc-no-stdlib = _: { crateBin = []; };
  # alloc-stdlib = _: { crateBin = []; };
  # brotli = _: { crateBin = []; };
  # brotli-decompressor = _: { crateBin = []; };

  # ring 0.17.x's build.rs asserts that `CARGO_MANIFEST_LINKS`
  # matches the `[package] links = "ring_core_X_Y_Z_"` declared in
  # its Cargo.toml. nixpkgs' buildRustCrate already wires
  # `CARGO_MANIFEST_LINKS = crate.links` in its `configure-crate.nix`;
  # passing `links` as an override arg flows through.
  # Hardcoded value tracks ring's version — bump when ring bumps.
  # Gen-side proper fix: emit `links` into the build-spec so
  # lockfile-builder can pass it directly without an override.
  ring = _: { links = "ring_core_0_17_14_"; };

  # proc-macro-crate 3.5.0+ no longer has the literal
  # `env::var("CARGO")` string nixpkgs' default override tries to
  # substitute via `--replace-fail`. The substitution fails the
  # patchPhase. Override clears `postPatch` since v3.x's code path
  # no longer needs the cargo-binary inlining (it uses
  # `CARGO_MANIFEST_DIR` env-only). When proc-macro-crate updates
  # again, re-evaluate.
  proc-macro-crate = _: { postPatch = ""; };

  # wgpu-hal 25.0.2: build.rs uses `cfg_aliases` to compute a
  # `supports_64bit_atomics` cfg from `target_has_atomic = "64"`.
  # The build script's `cargo:rustc-cfg=supports_64bit_atomics`
  # output isn't being captured by buildRustCrate's build-script
  # runner, so the cfg never reaches the lib build. The `src/noop/
  # mod.rs` then falls back to the portable-atomic code path
  # (`#[cfg(not(supports_64bit_atomics))]`) which fails because
  # portable-atomic isn't in the dep graph. Set the cfg explicitly
  # via extraRustcOpts — every host where mado/namimado runs
  # (aarch64-darwin, x86_64-darwin/linux) has native 64-bit atomics.
  wgpu-hal = _: {
    extraRustcOpts = [ "--cfg" "supports_64bit_atomics" ];
  };
  wgpu-core = _: {
    extraRustcOpts = [ "--cfg" "supports_64bit_atomics" ];
  };
  wgpu = _: {
    extraRustcOpts = [ "--cfg" "supports_64bit_atomics" ];
  };
  wgpu-types = _: {
    extraRustcOpts = [ "--cfg" "supports_64bit_atomics" ];
  };

  # clang-sys 1.8.x's build script (build/static.rs, build/common.rs) imports
  # `glob` via 2021-edition `use glob::…` — no `extern crate`. glob is a
  # *build-dependency*. nixpkgs' buildRustCrate compiles build scripts with
  # only `-L dependency=target/buildDeps` (no `--extern`), and drops the
  # nested build-dep entirely when clang-sys is itself pulled as a build-dep
  # (via coreaudio-sys → bindgen), leaving buildDeps empty → error[E0432]
  # unresolved import `glob`. (Surfaced fleet-wide by the nixpkgs bump; hits
  # hibiki + any bindgen consumer.) Fix: fold the crate's normal deps (which
  # include the already-built glob) into buildDependencies so glob lands in
  # target/buildDeps, and inject `extern crate glob;` so `-L` discovery
  # resolves the `use` under edition 2021.
  clang-sys = attrs: {
    buildDependencies = (attrs.buildDependencies or [])
      ++ (attrs.dependencies or []);
    prePatch = (attrs.prePatch or "") + ''
      # Append (not prepend): build.rs opens with `//!` inner docs +
      # `#![allow(...)]` inner attrs, which must precede all items, so a
      # leading `extern crate` triggers E0753. `extern crate` is a crate-root
      # item whose position is irrelevant to name resolution — appending is
      # safe and brings glob into scope for the build/*.rs submodules.
      if [ -f build.rs ] && ! grep -q 'extern crate glob;' build.rs; then
        printf '\nextern crate glob;\n' >> build.rs
      fi
    '';
  };

  # openraft 0.9.24's src/metrics/wait.rs:231 uses `let got = ...collect();`
  # without a type annotation. When rkyv lands in the same project's
  # target/deps (e.g. via a workspace sibling crate's depgraph),
  # rustc sees TWO `BTreeSet: PartialEq` impls (`alloc` + `rkyv`'s
  # `ArchivedBTreeSet`) and rejects the inference. Patch the source to
  # disambiguate explicitly — upstream openraft 0.9.x has no fix yet.
  openraft = attrs: {
    prePatch = (attrs.prePatch or "") + ''
      if [ -f src/metrics/wait.rs ]; then
        substituteInPlace src/metrics/wait.rs \
          --replace-fail \
          "let got = m.membership_config.membership().voter_ids().collect();" \
          "let got: std::collections::BTreeSet<_> = m.membership_config.membership().voter_ids().collect();"
      fi
    '';
  };

  # document-features 0.2.12 ships with `[lib] path = "lib.rs"` (no `src/`
  # prefix). buildRustCrate's auto-detection walks `src/lib.rs` only,
  # so when the consumer's Cargo.build-spec.json lacks a typed
  # `lib_target` (older gen-cargo emitters), the lib build runs against
  # nothing, leaving the proc-macro `.dylib` unbuilt. Hard-pin libName
  # + libPath via override so the build path is correct regardless of
  # spec freshness; remove this entry once every fleet build-spec is
  # regenerated through gen ≥ 50623e4.
  document-features = _: {
    libName = "document_features";
    libPath = "lib.rs";
  };

  # mime_guess 2.0.x's build.rs does `extern crate unicase;` — unicase is a
  # *build-dependency*. Same nested-build-dep drop as clang-sys above: when
  # mime_guess is pulled as a transitive build-dep (e.g. via pleme-tend, fumi),
  # buildRustCrate leaves its buildDeps empty, so the build script can't find
  # the crates.io `unicase` and rustc loads the unstable copy from the toolchain
  # sysroot instead → error[E0658] (rustc_private / loaded-from-sysroot). Fold
  # the crate's normal deps (which include the built unicase) into
  # buildDependencies so it lands in target/buildDeps for `-L` discovery. The
  # build.rs already has `extern crate unicase;`, so no prePatch is needed.
  mime_guess = attrs: {
    buildDependencies = (attrs.buildDependencies or [])
      ++ (attrs.dependencies or []);
  };
}
