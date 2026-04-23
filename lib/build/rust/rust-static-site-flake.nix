# ============================================================================
# RUST-STATIC-SITE-FLAKE — generic Rust → static HTML site generator pattern
# ============================================================================
#
# Wraps a Rust binary that, when run, fetches from a CMS (Hashnode, Ghost,
# WordPress REST, custom GraphQL) and writes a `dist/` directory of static
# HTML + assets suitable for Cloudflare Pages / Netlify / S3.
#
# Does NOT prescribe the Rust source — the consumer owns the sitegen binary
# (typically a `#[tokio::main] async fn` behind a feature flag). This flake
# provides the nix app wrapper, dev shell, and deploy app stubs.
#
# Typical pairing: this flake + `cloudflare-pages-deploy.nix` for upload.
#
# Usage:
#   outputs = { self, nixpkgs, substrate, fenix, ... }:
#     (import "${substrate}/lib/build/rust/rust-static-site-flake.nix" {
#       inherit nixpkgs substrate;
#     }) {
#       inherit self;
#       name = "my-blog";
#       sitegenBin = "my-blog-sitegen";     # bin target name
#       sitegenCrate = "my-blog-app";       # workspace member
#       sitegenFeatures = "sitegen";
#       outDir = "dist";
#     };
#
# Produces:
#   apps.generate          = build + run sitegen → outDir
#   apps.preview           = `python -m http.server` over outDir
#   apps.clean             = rm -rf outDir
#   devShells.default      = fenix + nodejs + wrangler
{
  nixpkgs,
  substrate ? null,
  fenix ? null,
  ...
}:
{
  self,
  name,
  sitegenBin,
  sitegenCrate,
  sitegenFeatures ? "sitegen",
  outDir ? "dist",
  systems ? [ "aarch64-darwin" "x86_64-linux" "aarch64-linux" ],
  # Optional hook: run before sitegen (e.g. `kamon render --target css …`)
  preGenerate ? "",
  # Optional hook: run after sitegen (e.g. copy extra assets)
  postGenerate ? "",
  ...
}:
let
  flakeWrapper = import ../../util/flake-wrapper.nix { inherit nixpkgs; };

  resolveFenix = system:
    if fenix != null then fenix.packages.${system}
    else if self ? inputs && self.inputs ? fenix then self.inputs.fenix.packages.${system}
    else throw "rust-static-site-flake: fenix input required";

  mkPerSystem = system: let
    pkgs = import nixpkgs { inherit system; };
    fenixPkgs = resolveFenix system;
    rust = fenixPkgs.combine [ fenixPkgs.latest.cargo fenixPkgs.latest.rustc ];
    devTools = [
      rust
      pkgs.pkg-config
      pkgs.openssl
      pkgs.nodejs_20
      pkgs.nodePackages.wrangler
      pkgs.python3
    ];
    binPath = pkgs.lib.makeBinPath devTools;

    mkApp = label: script: {
      type = "app";
      program = "${pkgs.writeShellScriptBin "${name}-${label}" ''
        set -euo pipefail
        export PATH=${binPath}:$PATH
        ${script}
      ''}/bin/${name}-${label}";
    };
  in {
    apps = {
      generate = mkApp "generate" ''
        ${preGenerate}
        cargo build --release --features ${sitegenFeatures} --bin ${sitegenBin} -p ${sitegenCrate}
        ./target/release/${sitegenBin} "''${1:-${outDir}}"
        ${postGenerate}
        echo "wrote ${outDir}/"
      '';
      preview = mkApp "preview" ''
        cd ${outDir} 2>/dev/null || { echo "no ${outDir}/ — run: nix run .#generate"; exit 1; }
        exec python3 -m http.server 8000
      '';
      clean = mkApp "clean" ''
        rm -rf ${outDir}
        echo "cleaned ${outDir}/"
      '';
    };
    devShells.default = pkgs.mkShellNoCC {
      buildInputs = devTools;
      shellHook = ''
        echo "${name} — static site generator dev shell"
        echo "  nix run .#generate   # build + fetch + render → ${outDir}/"
        echo "  nix run .#preview    # http.server over ${outDir}/"
      '';
    };
  };
in
  flakeWrapper.mkFlakeOutputs { inherit systems mkPerSystem; }
