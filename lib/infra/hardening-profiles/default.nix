# Substrate hardening-profile bundle.
#
# Exposes the reference yaml profiles both as raw strings (for splicing
# into provisioner scripts) and as in-store paths (for `nix run … --
# --profile <path>` invocations). Consumers pick the form they need.
#
#   profiles = import ./hardening-profiles { inherit pkgs; };
#   profiles.files.base       # /nix/store/…/base.yaml
#   profiles.text.hardened    # the yaml as a string
#   profiles.stack.ami-full   # [ files.base files.hardened files.ami-snapshot ]

{ pkgs }:

let
  yamlRead = name:
    builtins.readFile (./. + "/${name}.yaml");

  names = [ "base" "hardened" "ami-snapshot" "cis-level-1" ];

  files = builtins.listToAttrs (map (n: {
    name = n;
    value = pkgs.writeTextDir "${n}.yaml" (yamlRead n);
  }) names);

  text = builtins.listToAttrs (map (n: {
    name = n;
    value = yamlRead n;
  }) names);

in {
  inherit files text;

  # Convenience stacks — common compositions. Consumers pass
  # `stack.ami-full` directly as a list of profile paths.
  stack = {
    base = [ "${files.base}/base.yaml" ];
    hardened = [
      "${files.base}/base.yaml"
      "${files.hardened}/hardened.yaml"
    ];
    ami-full = [
      "${files.base}/base.yaml"
      "${files.hardened}/hardened.yaml"
      "${files.ami-snapshot}/ami-snapshot.yaml"
    ];
    cis-level-1 = [ "${files."cis-level-1"}/cis-level-1.yaml" ];
  };

  # Render a provisioner-script fragment that runs `kindling harden`
  # with a given stack. Consumers splice this into their provisioner
  # (typically after `kindling ami-build`).
  mkHardenStep = {
    stack,
    strict ? false,
    format ? "text",
  }: let
    profileArgs = pkgs.lib.concatMapStringsSep " "
      (p: "--profile ${p}") stack;
    strictArg = if strict then "--strict" else "";
  in [
    "echo '[hardening] applying ${toString (builtins.length stack)} profile(s)'"
    "nix --extra-experimental-features 'nix-command flakes' run github:pleme-io/kindling --accept-flake-config -- harden ${profileArgs} --format ${format} ${strictArg}"
  ];
}
