{ nixpkgs }:

{
  toolName,
  repo,
  binaries,
  linuxAbi,
  architectures ? [ "amd64" "arm64" ],
  image ? { },
}:
let
  inherit (nixpkgs) lib;

  systemOf = {
    amd64 = "x86_64-linux";
    arm64 = "aarch64-linux";
  };
  cpuOf = {
    amd64 = "x86_64";
    arm64 = "aarch64";
  };

  unknown = lib.subtractLists (builtins.attrNames systemOf) architectures;

  service = builtins.replaceStrings [ "_" ] [ "-" ] (lib.toLower toolName);

  sourceRepo =
    let r = builtins.tryEval repo;
    in if r.success && builtins.isString r.value && r.value != "" then r.value else "pleme-io/${service}";

  semverOf = drv:
    let v = drv.version or "";
    in if builtins.match "[0-9]+\\.[0-9]+\\.[0-9]+" v != null then v else "0.0.0";

  mkImage = arch:
    let
      system = systemOf.${arch};
      pkgs = import nixpkgs { inherit system; };
      substrateLib = import ../../default.nix { inherit pkgs system; };
      binary = binaries."${cpuOf.${arch}}-unknown-linux-${linuxAbi}";
      set = substrateLib.mkHardenedImageSet {
        sourceUrl = "https://github.com/${sourceRepo}";
        images.${service} = {
          inherit service;
          package = binary;
          base = if linuxAbi == "musl" then "distroless-static" else "distroless-glibc";
          publishName = "ghcr.io/pleme-io/${service}";
          publishTag = semverOf binary;
          entrypoint = [ "${binary}/bin/${toolName}" ];
          upstreamImage = "nix-built:${sourceRepo}";
          hardeningRationale = "substrate.rust.service image: the ${linuxAbi} ${toolName} binary on ${if linuxAbi == "musl" then "distroless-static" else "distroless-glibc"}, nonroot";
          trivyAnalysableTargets = [ ];
          hardeningTarget = true;
        } // image;
      };
    in
    set.packages."${service}Image";
in
if unknown != [ ] then
  throw ''
    substrate.rust.service: ${toolName} declares unknown image architecture(s)
    ${builtins.concatStringsSep ", " unknown}. Known: ${builtins.concatStringsSep ", " (builtins.attrNames systemOf)}.
    `architectures = [ ];` turns the image outputs off.
  ''
else
  builtins.listToAttrs (map (arch: {
    name = "dockerImage-${arch}";
    value = mkImage arch;
  }) architectures)
