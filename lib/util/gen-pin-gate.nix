{ lib }:
let
  root = ../..;
  pinPath = "lib/build/gen-pin.json";
  pinFile = root + "/${pinPath}";
  workflowDir = root + "/.github/workflows";

  pin = if builtins.pathExists pinFile then builtins.fromJSON (builtins.readFile pinFile) else null;

  semver = v: builtins.match "[0-9]+\\.[0-9]+\\.[0-9]+" v != null;

  shapeErrors =
    if pin == null then [ "${pinPath}: missing — it is the one gen pin" ]
    else
      (lib.optional (!(pin ? rev)) "${pinPath}: missing `rev`")
      ++ (lib.optional (!(pin ? sha256)) "${pinPath}: missing `sha256`")
      ++ (lib.optional (!(pin ? version)) "${pinPath}: missing `version` (gen's Cargo.toml version at `rev`; `gen --version` is compared to it)")
      ++ (lib.optional (pin ? rev && builtins.stringLength pin.rev != 40)
            "${pinPath}: `rev` is not a 40-char commit sha (got ${toString (builtins.stringLength pin.rev)} chars)")
      ++ (lib.optional (pin ? sha256 && !(lib.hasPrefix "sha256-" pin.sha256))
            "${pinPath}: `sha256` is not SRI-shaped (must start `sha256-`)")
      ++ (lib.optional (pin ? version && !(semver pin.version))
            "${pinPath}: `version` is not x.y.z (got ${pin.version})");

  ecosystems = builtins.attrNames
    (lib.filterAttrs (_: t: t == "directory") (builtins.readDir (root + "/lib/build")));

  strayPins = builtins.filter
    (eco: builtins.pathExists (root + "/lib/build/${eco}/gen-pin.json"))
    ecosystems;

  strayErrors = map
    (eco: "lib/build/${eco}/gen-pin.json: a second gen pin. Delete it; ${pinPath} is the only one")
    strayPins;

  workflows = builtins.attrNames
    (lib.filterAttrs (n: t: t == "regular" && (lib.hasSuffix ".yml" n || lib.hasSuffix ".yaml" n))
      (if builtins.pathExists workflowDir then builtins.readDir workflowDir else { }));

  unpinned = name:
    let
      lines = lib.splitString "\n" (builtins.readFile (workflowDir + "/${name}"));
      code = builtins.filter (l: !(lib.hasPrefix "#" (lib.trim l))) lines;
    in
    builtins.any (l: builtins.match ".*github:pleme-io/gen([^-a-zA-Z0-9_/].*)?" l != null) code;

  workflowErrors = map
    (name: ".github/workflows/${name}: runs `github:pleme-io/gen` (gen main). Run `github:pleme-io/substrate#gen`, the pin")
    (builtins.filter unpinned workflows);

  errors = shapeErrors ++ strayErrors ++ workflowErrors;
in
if errors != [ ] then
  throw ''
    gen-pin-gate: ${toString (builtins.length errors)} problem(s).

    ${builtins.concatStringsSep "\n    " errors}

    Bump gen by editing ${pinPath} only:
      nix flake prefetch --json github:pleme-io/gen/<rev>   # -> sha256
      git -C <gen> show <rev>:Cargo.toml                     # -> version
  ''
else
  { total = 1 + builtins.length ecosystems + builtins.length workflows; passed = 1 + builtins.length ecosystems + builtins.length workflows; }
