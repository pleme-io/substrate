# quirk-apply.nix — mechanical dispatch from typed
# `CrateQuirk` variants (emitted by gen-cargo at
# `spec.crates.<crate>.quirks`) to their class-helper apply
# functions.
#
# Source of truth for WHICH crates need WHICH quirks lives in
# `pleme-io/gen/crates/gen-cargo/src/quirks.rs::REGISTRY` (Rust). This
# file owns the apply layer — three class-helper functions, one per
# `CrateQuirk` variant, plus a left-fold combinator. Adding a new
# quirk class is one new variant in Rust + one new dispatch arm here.
#
# Returns: `{ applyQuirks }`. Consumed by lockfile-builder.nix in the
# `built` mapAttrs step.
{ lib }:
let
  # CLASS-HELPER: force a `--cfg <name>` for the lib compile.
  # See `gen-cargo::quirks::CrateQuirk::ForceCfg`.
  forceCfgApply = cfg: attrs: {
    extraRustcOpts = (attrs.extraRustcOpts or []) ++ [ "--cfg" cfg ];
  };

  # CLASS-HELPER: fold the crate's normal deps into buildDependencies
  # so its build.rs can resolve them. Optional `externCrate` injects
  # `extern crate <name>;` into build.rs for edition-2021+ crates.
  # See `gen-cargo::quirks::CrateQuirk::FoldNormalIntoBuild`.
  foldNormalIntoBuildApply = externCrate: attrs:
    let
      base = {
        buildDependencies = (attrs.buildDependencies or [])
          ++ (attrs.dependencies or []);
      };
      patch = if externCrate == null then {} else {
        prePatch = (attrs.prePatch or "") + ''
          if [ -f build.rs ] && ! grep -q 'extern crate ${externCrate};' build.rs; then
            printf '\nextern crate ${externCrate};\n' >> build.rs
          fi
        '';
      };
    in base // patch;

  # CLASS-HELPER: one-line source substitution. Upstream-bug patch.
  # See `gen-cargo::quirks::CrateQuirk::SubstituteSource`.
  substituteSourceApply = { file, from, to }: attrs: {
    prePatch = (attrs.prePatch or "") + ''
      if [ -f ${file} ]; then
        substituteInPlace ${file} \
          --replace-fail ${builtins.toJSON from} ${builtins.toJSON to}
      fi
    '';
  };

  # Dispatch table: typed `CrateQuirk` variants → class-helper apply
  # functions. Variant `kind` is the serde tag emitted by Rust
  # (`#[serde(tag = "kind", rename_all = "kebab-case")]`).
  applyQuirk = quirk: attrs:
    if quirk.kind == "force-cfg" then
      forceCfgApply quirk.cfg attrs
    else if quirk.kind == "fold-normal-into-build" then
      foldNormalIntoBuildApply (quirk.extern_crate or null) attrs
    else if quirk.kind == "substitute-source" then
      substituteSourceApply {
        inherit (quirk) file from to;
      } attrs
    else
      throw "quirk-apply: unknown CrateQuirk kind '${quirk.kind}'. Add a dispatch arm here when adding a new variant to gen-cargo::quirks::CrateQuirk.";
in {
  # Apply a list of quirks left-to-right against base attrs; each
  # quirk gets the running attrs and contributes additional override
  # fields that get merged in.
  applyQuirks = quirks: attrs:
    builtins.foldl' (acc: quirk: acc // (applyQuirk quirk attrs)) {} quirks;
}
