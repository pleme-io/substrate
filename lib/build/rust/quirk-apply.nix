# quirk-apply.nix — mechanical dispatch from typed `CrateQuirk`
# variants (emitted by gen-cargo at `spec.crates.<crate>.quirks`) to
# their class-helper apply functions.
#
# Source of truth for WHICH crates need WHICH quirks lives in
# `pleme-io/gen/crates/gen-cargo/src/quirks.rs::REGISTRY` (Rust).
# This file owns the rust-side apply layer — three class-helper
# functions, one per `CrateQuirk` variant. The dispatch + fold
# combinator is shared across every ecosystem via
# `../shared/mk-quirk-applier.nix`.
#
# Adding a new quirk class is one new variant in Rust + one new
# helpers entry here.
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
in
import ../shared/mk-quirk-applier.nix {
  inherit lib;
  helpers = {
    "force-cfg" = quirk: forceCfgApply quirk.cfg;
    "fold-normal-into-build" =
      quirk: foldNormalIntoBuildApply (quirk.extern_crate or null);
    "substitute-source" = quirk: substituteSourceApply {
      inherit (quirk) file from to;
    };
  };
}
