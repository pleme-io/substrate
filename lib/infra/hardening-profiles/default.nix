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
  # with a stack of profiles INLINED as heredocs.
  #
  # The stack argument accepts either raw /nix/store paths (for local
  # in-nix composition where the paths are reachable) OR the names of
  # bundled profiles ("base", "hardened", "ami-snapshot",
  # "cis-level-1"). Profiles are emitted to /tmp on the target host
  # via heredoc so the `--profile` paths resolve on the REMOTE box,
  # not the orchestrator.
  #
  # Why heredoc-inline: /nix/store paths produced here live on the
  # orchestrator only. Passing them to `--profile` on a remote Packer
  # instance gives `ENOENT`. Inlining avoids needing a file upload
  # step and keeps the Packer provisioner a single inline shell.
  mkHardenStep = {
    stack ? [],
    stackNames ? [],
    strict ? false,
    format ? "text",
  }: let
    # Resolve either `stack` (store paths) or `stackNames` (bundled
    # profile names) into a list of (filename, yaml-content) pairs.
    # Inlining the yaml content means the remote host writes it and
    # then feeds it to `kindling harden`.
    byName = name: { filename = "${name}.yaml"; content = yamlRead name; };
    resolved =
      if stackNames != []
      then map byName stackNames
      else if stack != []
      then builtins.throw "mkHardenStep: use stackNames = [ \"base\" \"hardened\" ... ] so content can be inlined on the remote host; passing /nix/store paths via `stack` is local-only"
      else builtins.throw "mkHardenStep: need stackNames (or stack)";

    strictArg = if strict then "--strict" else "";
    emit = p: [
      "mkdir -p /tmp/kindling-harden"
      "cat > /tmp/kindling-harden/${p.filename} <<'HARDEN_PROFILE_EOF'"
      p.content
      "HARDEN_PROFILE_EOF"
    ];
    emitAll = pkgs.lib.concatMap emit resolved;
    profileArgs = pkgs.lib.concatMapStringsSep " "
      (p: "--profile /tmp/kindling-harden/${p.filename}") resolved;
  in
    [ "echo '[hardening] inlining ${toString (builtins.length resolved)} profile(s) + applying'" ]
    ++ emitAll
    ++ [
      "nix --extra-experimental-features 'nix-command flakes' run github:pleme-io/kindling --accept-flake-config -- harden ${profileArgs} --format ${format} ${strictArg}"
      "rm -rf /tmp/kindling-harden"
    ];
}
