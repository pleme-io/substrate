# oci-push (→ doca) — typed OCI manager binary, exposed as a substrate flake
# package so pipelines call `nix run github:pleme-io/substrate#oci-push -- …`
# instead of inline skopeo bash.
#
# Built with `buildRustPackage` + the committed `Cargo.lock` (vendored as
# fixed-output derivations — ring/rustls, no aws-lc/openssl/cmake, so the
# closure is C-light and sandbox-clean). `skopeo` is wrapped onto PATH for the
# `--backend skopeo` fallback; the default `native` backend needs no binary.
#
# NOTE (standardization follow-up): this uses plain buildRustPackage rather
# than the gen/crate2nix fleet path. Acceptable for a substrate-internal build
# helper with no committed build-spec; revisit if doca graduates to its own
# published repo.
#
# fenix-backed rustPlatform (2026-07-22) -- oci-push's real dependency tree
# (e.g. rand_pcg 0.10.2, pulled in transitively) declares `edition =
# "2024"` in its own Cargo.toml. edition2024 is a genuine cargo/rustc MSRV
# requirement, not a lockfile-format artifact: a consumer pinned to an
# older primary nixpkgs (confirmed live incident, pleme-io/hardened-images
# on nixos-24.05/cargo 1.77.2) cannot build this package AT ALL, regardless
# of Cargo.lock version -- a lockfile-version-only downgrade (v4->v3)
# bypasses the PARSE error but still hits "the package requires the Cargo
# feature called `edition2024`, but that feature is not stabilized in this
# version of Cargo" the moment a real build (not just `cargo metadata`)
# resolves rand_pcg (confirmed via a direct local `cargo build --locked`
# against the exact pinned cargo). `fenix` is ALREADY a substrate flake
# input (see flake.nix + lib/build/rust/overlay.nix's `mkRustOverlay`,
# whose own doc comment names this exact class of problem: "Configures
# buildRustCrate to use fenix's rustc (critical for edition 2024)") --
# this reuses that same fenix stable toolchain shape, scoped to ONLY this
# one derivation via `pkgs.makeRustPlatform` (never overlaying the
# consumer's own `pkgs.rustc`/`pkgs.cargo` globally, which would risk
# other packages built from that same primary nixpkgs -- e.g. rabbitmq/
# mysql/neo4j/node-exporter/clickhouse on hardened-images, whose own
# version-exact rationale is pinned against their consumer's chosen
# primary nixpkgs deliberately). Falls back to plain `pkgs.rustPlatform`
# when `fenix`/`system` aren't passed, preserving the original behavior
# for any consumer not yet threading them through.
{ pkgs, fenix ? null, system ? null }:
let
  lib = pkgs.lib;
  # Exclude local cargo output + docs from the build source.
  src = lib.cleanSourceWith {
    src = ../../tools/oci-push;
    filter = path: _type:
      let base = baseNameOf path;
      in base != "target" && base != "DESIGN.md" && base != "README.md";
  };
  # NOTE: `fenix` here is the ALREADY-PER-SYSTEM-INDEXED packages set
  # (fenix.packages.${system}, e.g. `fenix.stable`/`fenix.combine`
  # directly work), matching lib/default.nix's own established
  # convention for this param -- confirmed against wasm/build.nix and
  # leptos-build.nix, both of which receive the SAME already-indexed
  # shape from lib/default.nix and call `fenix.combine`/`fenix.latest…`
  # directly with no further `.packages.${system}` indexing. The
  # top-level flake.nix `oci-push` package (the direct
  # `nix run …#oci-push` entry point) passes the ALREADY-INDEXED
  # `fenix.packages.${system}` for exactly this reason -- see its own
  # call site's comment.
  rustPlatform =
    if fenix != null && system != null
    then
      let
        toolchain = fenix.stable.withComponents [
          "rustc" "cargo" "rust-src" "clippy" "rustfmt"
        ];
      in pkgs.makeRustPlatform { cargo = toolchain; rustc = toolchain; }
    else pkgs.rustPlatform;
in
rustPlatform.buildRustPackage {
  pname = "oci-push";
  version = "0.1.0";
  inherit src;
  cargoLock.lockFile = ../../tools/oci-push/Cargo.lock;
  nativeBuildInputs = [ pkgs.makeWrapper ];
  postInstall = ''
    wrapProgram $out/bin/oci-push \
      --prefix PATH : ${lib.makeBinPath [ pkgs.skopeo ]}
  '';
  meta = {
    description = "Typed OCI manager — native (pure-Rust oci-client) + skopeo backends";
    mainProgram = "oci-push";
  };
}
