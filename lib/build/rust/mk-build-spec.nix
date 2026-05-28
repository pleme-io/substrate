# mkBuildSpec — derive Cargo.build-spec.json on demand via gen (IFD).
#
# Substrate's gen-driven build path. The consumer's repository no
# longer needs to commit `Cargo.build-spec.json`; substrate's build
# wrappers invoke `gen build <src>` via IFD (Import-From-Derivation)
# inside the nix sandbox, then consume the JSON immediately. Every
# `nix flake update gen` propagates the latest gen-cargo behavior
# to the entire fleet — no per-repo regen toil ever again.
#
# ## Inputs
#
# - `pkgs`     — nixpkgs instance (passed by the build pipeline).
# - `gen`      — substrate-bound gen package
#                (`substrate.packages.${system}.gen`).
# - `src`      — consumer's workspace root (path).
#
# ## Output
#
# A derivation whose output `$out/Cargo.build-spec.json` is the
# typed build-spec ready to feed into `lockfile-builder.mkProject`.
# Substrate's wrappers do this transparently — consumers never see
# the IFD machinery.
#
# ## Hermetic contract
#
# `gen build` MUST run without network access — this whole derivation
# is built inside the nix sandbox. v1 gen-cargo calls `cargo-metadata`
# (which needs network); when a consumer hits the missing-network
# error, fall back to committed `Cargo.build-spec.json`. The
# hermetic gen-cargo rewrite retires that fallback.
{
  pkgs,
  gen,
  src,
  # Optional: target triple for cross-spec emission (defaults to host).
  target ? null,
}:

let
  # cargoSrc must be self-contained for IFD: only the manifest +
  # lockfile + workspace member tree matter. We could narrow the
  # filter further, but `src` is typically already the workspace
  # root — additional filtering buys little.
  targetArg = if target == null then "" else "--filter-platform=${target}";

  # The IFD always runs on the HOST during eval, regardless of which
  # target the consumer is being built for. When `pkgs` is a pkgsStatic
  # (or other cross/target pkgs), `pkgs.runCommand` would re-stage gen +
  # cargo + rustc against the TARGET stdenv — causing a recursive
  # cascade of rebuilding gen for x86_64-unknown-linux-musl when the
  # consumer is a linux-musl build. `pkgs.buildPackages` is the host's
  # native pkgs (for native builds it's the same as pkgs; for cross it
  # is the builder), so the IFD always lands on host-native tooling.
  hostPkgs = pkgs.buildPackages;
in
hostPkgs.runCommand "cargo-build-spec" {
  # `gen build` invokes `cargo metadata` under the hood (v1 gen-cargo
  # path; replaced by Rust-native digestion in the upcoming hermetic
  # rewrite). cargo + rustc must be on PATH inside the IFD sandbox;
  # cacert provides the CA bundle cargo needs to fetch the crates.io
  # index over TLS (the sandbox lacks /etc/ssl by default).
  nativeBuildInputs = [ gen hostPkgs.cargo hostPkgs.rustc hostPkgs.cacert ];
  SSL_CERT_FILE = "${hostPkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
  NIX_SSL_CERT_FILE = "${hostPkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
  # gen reads Cargo.toml + Cargo.lock + walks workspace members.
  # Substrate's gen v1 still calls cargo-metadata (non-hermetic);
  # __noChroot lets it reach the network for the cargo registry index
  # walk. The hermetic gen-cargo rewrite retires this.
  __noChroot = true;
  src = src;
  # The output hash isn't predictable for a deterministic FOD —
  # rely on input-addressed evaluation cache instead.
} ''
  cp -r $src/* .
  chmod -R u+w .
  mkdir -p $out
  # cargo needs a writable HOME for its registry cache; the sandbox's
  # default /homeless-shelter is read-only.
  export CARGO_HOME=$PWD/.cargo
  export HOME=$PWD
  gen build . ${targetArg} > /dev/null
  if [ ! -f Cargo.build-spec.json ]; then
    echo "mkBuildSpec: gen build did not produce Cargo.build-spec.json" >&2
    exit 1
  fi
  cp Cargo.build-spec.json $out/
''
