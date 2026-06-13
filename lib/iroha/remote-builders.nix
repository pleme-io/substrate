# iroha.remote-builders — L2: a typed remote-build-machine fleet, projected
# onto nix.buildMachines + the ssh client wiring.
#
# The ~600-line pangea-builder consumer (modules/shared/pangea-builder.nix)
# hand-assembles three coupled surfaces from one list of build hosts:
# nix.buildMachines entries, programs.ssh client Host blocks (with a
# wake-aware SSM ProxyCommand on some), and known_hosts material. This
# letter is the typed source for the load-bearing core of that shape — a
# list of typed builderSpecs lowered to (a) a deterministic
# nix.buildMachines list (one entry per builder, sorted by name) and
# (b) the programs.ssh.extraConfig Host blocks (a ProxyCommand block is
# emitted only when proxyCommand is set; a plain UserKnownHostsFile-style
# block otherwise). It emits ONE class-tagged NixOS module — remote build
# dispatch is a system-level (nix-daemon, root) concern, never per-user
# home-manager — plus an enable + extras option surface and a meta summary.
#
# nix.buildMachines is a LIST; iteration order over an attrset is
# alphabetical by key in Nix, so mapping the builders attrset
# deterministically sorts entries by name — two evals of the same input
# produce byte-identical lists (no set-ordering nondeterminism).
#
# A builderSpec carries `system :: str` OR `systems :: [str]` (exactly one);
# the emitted entry always uses `systems = [...]` (the canonical
# nix.buildMachines field, a list). `supportedFeatures` / `mandatoryFeatures`
# default to [] and are carried verbatim. `publicHostKey` (base64) is
# carried onto the buildMachines entry when set (nix uses it to verify the
# builder's host key); `proxyCommand` (a wake-aware SSM ProxyCommand string,
# e.g. cordel builder-wake) drives the ssh Host block shape.
#
# COMPOSES iroha.mkOptionSurface for the enable + extraOptions skeleton
# (package = false, settings = null) and iroha.core.tag for class tagging.
#
# Exports (pure { lib }, zero pkgs — pkgs binds late as a module arg):
#
#   mkRemoteBuilders :: {
#     name        ? "remote-builders" — unit/option-path last segment;
#     namespace   ? "nix"             — dotted option root; lands at
#                                       <namespace>.<name>;
#     enable      ? true              — emit the `enable` option;
#     extraOptions ? { } | (lib -> attrs) — extra typed option declarations
#                                       merged under the option root;
#     builders    :: attrsOf builderSpec (required, non-empty) where
#       builderSpec = {
#         hostName  :: str (required) — ssh host / nix builder host;
#         system    :: str            — e.g. "x86_64-linux"; OR
#         systems   :: [str]          — exactly one of system / systems;
#         maxJobs   ? 1;
#         speedFactor ? 1;
#         sshUser   ? null (str);
#         sshKey    ? null (path str);
#         supportedFeatures ? [ ] (listOf str);
#         mandatoryFeatures ? [ ] (listOf str);
#         publicHostKey ? null (str — base64, for known_hosts/verification);
#         proxyCommand  ? null (str — wake-aware SSM ProxyCommand);
#         protocol  ? "ssh-ng";
#       };
#   } -> {
#     nixos :: class-tagged module (_class "nixos") —
#       options.<ns>.<name>.{ enable, …extraOptions };
#       config = mkIf cfg.enable {
#         nix.buildMachines = [ <one per builder, sorted by name:
#           { hostName; systems; maxJobs; speedFactor; protocol;
#             sshUser? sshKey? publicHostKey?;
#             supportedFeatures; mandatoryFeatures; } ];
#         nix.distributedBuilds = true;
#         programs.ssh.extraConfig = <Host blocks; ProxyCommand line only
#                                     when proxyCommand set>;
#       };
#     meta :: { name, builderCount, systems = unique [systems across builders],
#               kind = "remote-builders" };
#   }
#
# Throws (every message prefixed "iroha.remote-builders.mkRemoteBuilders: "):
#   - `builders` missing, not an attrset, or empty;
#   - a builderSpec missing `hostName`;
#   - a builderSpec with neither `system` nor `systems`, or with both;
#   - a builderSpec whose `systems` is not a list / `system` not a string.
{ lib }:
let
  core = import ./core.nix { inherit lib; };
  optionSurface = import ./option-surface.nix { inherit lib; };
  inherit (lib) optionalAttrs;

  err = msg: throw "iroha.remote-builders.mkRemoteBuilders: ${msg}";

  # builderSpec name -> spec -> normalized record (systems always a list).
  normalizeBuilder =
    bname: spec:
    let
      hostName =
        spec.hostName or (err "builder '${bname}' is missing `hostName` (str — the ssh / nix builder host).");
      hasSystem = spec ? system;
      hasSystems = spec ? systems;
      systems =
        if hasSystem && hasSystems then
          err "builder '${bname}' takes exactly one of `system` (str) or `systems` ([str]) — got both."
        else if hasSystems then
          if builtins.isList spec.systems then
            spec.systems
          else
            err "builder '${bname}' `systems` must be a list of system strings — got ${builtins.typeOf spec.systems}."
        else if hasSystem then
          if builtins.isString spec.system then
            [ spec.system ]
          else
            err "builder '${bname}' `system` must be a string (e.g. \"x86_64-linux\") — got ${builtins.typeOf spec.system}."
        else
          err "builder '${bname}' needs one of `system` (str) or `systems` ([str]).";
    in
    {
      inherit bname hostName systems;
      maxJobs = spec.maxJobs or 1;
      speedFactor = spec.speedFactor or 1;
      sshUser = spec.sshUser or null;
      sshKey = spec.sshKey or null;
      supportedFeatures = spec.supportedFeatures or [ ];
      mandatoryFeatures = spec.mandatoryFeatures or [ ];
      publicHostKey = spec.publicHostKey or null;
      proxyCommand = spec.proxyCommand or null;
      protocol = spec.protocol or "ssh-ng";
    };

  mkRemoteBuilders =
    args:
    let
      name = args.name or "remote-builders";
      namespace = args.namespace or "nix";
      enable = args.enable or true;
      extraOptions = args.extraOptions or { };

      builders =
        args.builders or (err "`builders` (attrsOf builderSpec, non-empty) is required.");
      _buildersChecked =
        if !(builtins.isAttrs builders) then
          err "`builders` must be an attrset of builderSpec — got ${builtins.typeOf builders}."
        else if builders == { } then
          err "`builders` must be non-empty — declare at least one remote build machine."
        else
          builders;

      # Sorted by name → deterministic list order. builtins.attrNames /
      # lib.mapAttrsToList iterate alphabetically, so the emitted
      # buildMachines list is byte-stable across evals.
      normalized = lib.mapAttrsToList normalizeBuilder _buildersChecked;

      # ── nix.buildMachines entry (one per builder) ───────────────────────
      mkBuildMachine =
        b:
        {
          inherit (b)
            hostName
            systems
            maxJobs
            speedFactor
            protocol
            supportedFeatures
            mandatoryFeatures
            ;
        }
        // optionalAttrs (b.sshUser != null) { inherit (b) sshUser; }
        // optionalAttrs (b.sshKey != null) { inherit (b) sshKey; }
        // optionalAttrs (b.publicHostKey != null) { inherit (b) publicHostKey; };

      buildMachines = map mkBuildMachine normalized;

      # ── programs.ssh.extraConfig Host blocks ────────────────────────────
      # One block per builder. A ProxyCommand line is emitted ONLY when
      # the builder declares proxyCommand (the wake-aware SSM path); a
      # UserKnownHostsFile-style block otherwise. Lines that are absent
      # (sshUser/sshKey/proxyCommand null) are simply not produced.
      mkHostBlock =
        b:
        let
          lines =
            [ "Host ${b.hostName}" ]
            ++ lib.optional (b.sshUser != null) "  User ${b.sshUser}"
            ++ lib.optional (b.sshKey != null) "  IdentityFile ${b.sshKey}"
            ++ lib.optional (b.proxyCommand != null) "  ProxyCommand ${b.proxyCommand}";
        in
        lib.concatStringsSep "\n" lines;

      sshExtraConfig = lib.concatStringsSep "\n\n" (map mkHostBlock normalized);

      # ── option surface (enable + extras; no package, no settings) ───────
      surface = optionSurface.mkOptionSurface {
        inherit
          name
          namespace
          enable
          ;
        description = "Typed remote build machines projected onto nix.buildMachines + ssh client config.";
        package = false;
        settings = null;
        extra = extraOptions;
      };

      optionPath = surface.optionPath;
      enablePath = surface.enablePath;

      nixosFragment =
        {
          config,
          ...
        }:
        let
          cfg = lib.getAttrFromPath optionPath config;
        in
        {
          config = lib.mkIf cfg.enable {
            nix.buildMachines = buildMachines;
            nix.distributedBuilds = true;
            programs.ssh.extraConfig = sshExtraConfig;
          };
        };

      nixos = core.tag core.classes.nixos {
        imports = [
          surface.module
          nixosFragment
        ];
      };

      meta = {
        inherit name optionPath enablePath;
        builderCount = builtins.length normalized;
        systems = lib.unique (lib.concatMap (b: b.systems) normalized);
        kind = "remote-builders";
      };
    in
    {
      inherit nixos meta;
    };
in
{
  inherit mkRemoteBuilders;
}
