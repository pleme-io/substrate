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
{ pkgs }:
let
  lib = pkgs.lib;
  # Exclude local cargo output + docs from the build source.
  src = lib.cleanSourceWith {
    src = ../../tools/oci-push;
    filter = path: _type:
      let base = baseNameOf path;
      in base != "target" && base != "DESIGN.md" && base != "README.md";
  };
in
pkgs.rustPlatform.buildRustPackage {
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
