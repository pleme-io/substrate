# Complete multi-system flake outputs for a Go multi-binary WORKSPACE.
# Wraps go-monorepo.nix + go-monorepo-binary.nix + eachSystem + overlays for
# zero-boilerplate consumer flakes — the Go peer of
# build/rust/workspace-release-flake.nix.
#
# Where build/go/tool-release-flake.nix builds ONE binary from a repo, this
# builds MANY binaries from a single Go module (one src, one vendorHash, many
# `cmd/<name>` subPackages — e.g. kubernetes/kubernetes → kubelet, kubeadm,
# kube-apiserver, …). Each binary becomes packages.<system>.<binName>; the
# first declared binary is packages.<system>.default.
#
# Usage in a flake:
#   outputs = { self, nixpkgs, substrate, forge, ... }:
#     (import "${substrate}/lib/build/go/workspace-release-flake.nix" {
#       inherit nixpkgs;
#       forge = forge or null;          # optional — enables the release apps
#     }) {
#       workspaceName = "k8s";
#       src           = self;
#       vendorHash    = "sha256-...";   # null = in-tree vendoring (vendor/)
#       binaries = [
#         { name = "kubelet"; subPackage = "cmd/kubelet"; description = "Kubernetes node agent"; }
#         { name = "kubeadm"; subPackage = "cmd/kubeadm"; description = "Kubernetes cluster bootstrapper";
#           completions = { install = true; command = "kubeadm"; }; }
#       ];
#       repo = "pleme-io/k8s";          # optional — enables release/bump apps
#     };
#
# `binaries` is a list of { name, subPackage, ... } (the rest is forwarded to
# mkGoMonorepoBinary: description, homepage, completions, nativeBuildInputs,
# postInstall, platforms). It may also be an attrset { <name> = { subPackage; … } }
# — keys become binary names. List form preserves declaration order, so
# `packages.default` is the FIRST binary; attrset form falls back to attr order.
#
# Release surface (mirrors the Go tool-release-flake): when `repo` is set,
# apps.{release,bump} delegate to the language-generic `forge tool <verb>
# --language go` (see util/release-helpers.nix) at the workspace granularity —
# one tag covers the whole module (Go's PULL model; proxy.golang.org fetches
# lazily). apps.{check-all,lock-platform} are always present.
#
# Module trio (NixOS + nix-darwin + home-manager): pass `module = { ... }` to
# auto-emit nixosModules.default / darwinModules.default / homeManagerModules.default.
# See substrate/lib/module-trio.nix for the spec shape. The module's packageAttr
# defaults to the first binary (which is also packages.default).
{
  nixpkgs,
  forge ? null,
}:
{
  workspaceName,
  src,
  binaries,
  vendorHash ? null,
  version ? "0.1.0",
  systems ? ["aarch64-darwin" "x86_64-darwin" "x86_64-linux" "aarch64-linux"],
  versionPackage ? null,
  extraLdflags ? [],
  module ? null,
  repo ? null,
  ...
}:
let
  flakeWrapper = import ../../util/flake-wrapper.nix { inherit nixpkgs; };
  pkgsLib = (import nixpkgs { system = "x86_64-linux"; }).lib;
  hygiene = import ../../util/flake-hygiene.nix {
    lib = pkgsLib;
  };
  # Enforce flake hygiene at evaluation time — fails fast on misconfiguration.
  # In workspace flakes, src = self, so src.inputs holds the flake inputs.
  _hygieneCheck =
    if src ? inputs then hygiene.enforceAll src.inputs
    else true;

  check = import ../../types/assertions.nix;
  _ = check.all [
    (check.nonEmptyStr "workspaceName" workspaceName)
    (check.strOrNull "repo" repo)
    (check.attrsOrNull "module" module)
    (check.list "extraLdflags" extraLdflags)
    (check.strOrNull "versionPackage" versionPackage)
  ];

  monoBinary = import ./monorepo-binary.nix;
  releaseHelpers = import ../../util/release-helpers.nix;

  # Normalise `binaries` into an ordered list of { name; spec; } pairs.
  # List form preserves declaration order (so packages.default = first binary);
  # attrset form maps keys → names and falls back to attribute order.
  binaryList =
    if builtins.isList binaries then
      builtins.map (b: {
        name = b.name;
        spec = builtins.removeAttrs b [ "name" ];
      }) binaries
    else
      pkgsLib.mapAttrsToList (name: spec: { inherit name spec; }) binaries;

  _binCheck = check.all (builtins.map
    (b: check.nonEmptyStr "binaries.<name>" b.name)
    binaryList);

  firstBinary =
    if binaryList == [] then throw "workspace-release-flake: `binaries` must declare at least one binary"
    else (builtins.head binaryList).name;

  mkPerSystem = system: let
    pkgs = import nixpkgs { inherit system; };
    lib = pkgs.lib;

    # Shared source + ldflags for the whole workspace, in the exact shape
    # mkGoMonorepoSource (build/go/monorepo.nix) emits: { version, src, ldflags }.
    # We assemble it directly rather than calling mkGoMonorepoSource because the
    # workspace src is the consumer's local tree (src = self), not a
    # fetchFromGitHub — the ldflag construction mirrors that primitive.
    monoSrc = {
      inherit version src;
      ldflags = ["-s" "-w"]
        ++ lib.optionals (versionPackage != null) [
          "-X ${versionPackage}.gitVersion=v${version}"
        ]
        ++ extraLdflags;
    };

    # Build one binary from the shared source via mkGoMonorepoBinary, threading
    # the workspace's vendorHash (the primitive defaults to in-tree null).
    mkBinary = { name, spec }:
      (monoBinary.mkGoMonorepoBinary pkgs monoSrc ({
        pname = name;
        subPackages = if spec ? subPackage then [ spec.subPackage ] else [ "cmd/${name}" ];
        description = spec.description or "${name} (${workspaceName} workspace binary)";
        platforms = spec.platforms or lib.platforms.all;
      } // (builtins.removeAttrs spec [ "subPackage" "description" "platforms" ])))
      .overrideAttrs (_: { inherit vendorHash; });

    builtBinaries = builtins.listToAttrs (builtins.map
      (b: { name = b.name; value = mkBinary b; })
      binaryList);

    # forge binary resolution: prefer the passed flake input, else PATH lookup.
    forgeCmd =
      if forge != null then "${forge.packages.${system}.default}/bin/forge"
      else "forge";
    # Release lifecycle apps — language-generic, parameterised with language="go".
    # Workspace granularity: toolName = workspaceName (one tag for the module).
    releaseArgs = { hostPkgs = pkgs; toolName = workspaceName; inherit forgeCmd; language = "go"; };

    binaryApps = builtins.listToAttrs (builtins.map
      (b: {
        name = b.name;
        value = {
          type = "app";
          program = "${builtBinaries.${b.name}}/bin/${b.name}";
        };
      })
      binaryList);
  in {
    packages = builtBinaries // {
      default = builtBinaries.${firstBinary};
    };
    devShells = {
      default = pkgs.mkShellNoCC {
        packages = with pkgs; [ go gopls gotools ];
      };
    };
    apps = binaryApps // {
      default = binaryApps.${firstBinary};
      check-all = releaseHelpers.mkCheckAllApp releaseArgs;
      lock-platform = releaseHelpers.mkLockPlatformApp releaseArgs;
    } // lib.optionalAttrs (repo != null) {
      # `repo` is required by `forge tool release` (the GitHub coordinate).
      release = releaseHelpers.mkReleaseApp (releaseArgs // { inherit repo; });
      bump = releaseHelpers.mkBumpApp releaseArgs;
    };
  };

  trio =
    if module == null then null
    else (import ../../module-trio.nix { lib = pkgsLib; }).mkModuleTrio (
      {
        name = module.name or workspaceName;
        description = module.description or "${workspaceName} workspace binary";
        packageAttr = module.packageAttr or firstBinary;
      } // (builtins.removeAttrs module [ "name" "description" "packageAttr" ])
    );

  moduleOutputs = if trio == null then {} else {
    homeManagerModules.default = trio.homeManagerModule;
    nixosModules.default = trio.nixosModule;
    darwinModules.default = trio.darwinModule;
  };
in
  flakeWrapper.mkFlakeOutputs {
    inherit systems mkPerSystem;
    extraOutputs = {
      # Expose every workspace binary on the overlay (final.<binName>). Unlike
      # packages, the overlay omits `default` — `pkgs.default` is not a thing.
      overlays.default = final: prev: let
        sysPkgs = (mkPerSystem final.stdenv.hostPlatform.system).packages;
      in builtins.removeAttrs sysPkgs [ "default" ];
    } // moduleOutputs;
  }
