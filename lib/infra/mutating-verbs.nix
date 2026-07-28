# Typed retirement of mutating infrastructure verbs.
#
# ★★ MODULARIZE, DON'T DELETE — retirement is a typed flag, never a
# deletion. ★★ PLATFORM-MEDIATED INFRASTRUCTURE — a human's only two
# verbs are *declare* and *observe*; `plan` by hand, `apply`, `destroy`
# and friends belong to pangea-operator, which is the sole executor.
#
# THE SHAPE
#
#   mutatingVerbs.<verb> = {
#     enable    = false;                 # default: true  (see BACKWARD COMPAT)
#     retiredOn = "2026-07-27";          # required when enable = false
#     executes  = "pangea bulk apply …"; # required when enable = false
#     reason    = "…";                   # optional extra WHY prose
#     declaredIn = "flake.nix";          # optional; where the flag lives
#   };
#
# A disabled verb's app still EXISTS and still resolves — `nix run .#apply`
# is not "attribute missing", it is a refusal built FROM the declaration's
# own fields, naming the declare-and-observe replacement path. The
# declaration is the record that a decision was made; restoring the verb is
# flipping one field and committing.
#
# THE FLAG RESOLVES AT EVAL TIME. The retired app's `program` is a different
# store path — there is no runtime flag, env var or argument that can
# satisfy it, because the real program was never built.
#
# BACKWARD COMPAT — non-negotiable
#
#   Every verb defaults to `enable = true`. With no `mutatingVerbs` argument
#   (or one that enables everything), `retireApps` returns the app set it was
#   given, BY IDENTITY — it does not rebuild, rewrap or re-store-path a
#   single app, and it does not force `pkgs` at all. That is asserted
#   mechanically in `tests/mutating-verbs-test.nix` by passing
#   `pkgs = throw "…"` and requiring the result to still equal the input.
#
# LOUD OVER SILENT
#
#   A declaration is validated at eval time: an unknown field, a non-bool
#   `enable`, a disabled verb missing `retiredOn`/`executes`, or a disabled
#   verb naming a verb this builder does not produce, all `throw`. A silently
#   ignored typo (`aply.enable = false`) would be a retirement that retires
#   nothing while reading as green — the vacuous-guard failure mode.
#
# USAGE (builder side)
#
#   mutatingVerbsLib = import ./mutating-verbs.nix { inherit lib; };
#   apps = mutatingVerbsLib.retireApps {
#     inherit pkgs mutatingVerbs;
#     name  = name;                       # the project, for the notice header
#     verbs = [ "plan" "apply" "destroy" "init" ];   # what IS retireable here
#   } rawApps;
#
# COMPOSITION NOTE
#
#   Retire at the SOURCE app set, before any composed verb inlines another
#   verb's `program`. `gated-pangea-workspace.nix` retires the base workspace
#   apps for exactly this reason: its `deploy` splices `base.apply.program`,
#   so retiring only the returned `apply` would leave `deploy` a live hole.
{ lib }:

let
  # ── The declaration ───────────────────────────────────────────────────
  #
  # `enable = true` is the whole backward-compatibility contract.
  defaultDecl = {
    enable = true;
    retiredOn = null;
    executes = null;
    reason = null;
    declaredIn = "flake.nix";
  };

  knownFields = builtins.attrNames defaultDecl;

  # Validate + fill one declaration. Throws on anything under-specified.
  normalize = ctx: verb: decl:
    let
      unknown = builtins.filter (f: !(builtins.elem f knownFields))
        (builtins.attrNames decl);
      d = defaultDecl // decl;
      err = msg: throw "${ctx}: mutatingVerbs.${verb}: ${msg}";
      nonEmptyStr = v: builtins.isString v && v != "";
    in
    if unknown != [] then
      err ''
        unknown field(s) ${builtins.concatStringsSep ", " unknown}.
        Known fields: ${builtins.concatStringsSep ", " knownFields}.''
    else if !(builtins.isBool d.enable) then
      err "`enable` must be a bool, got ${builtins.typeOf d.enable}."
    else if d.enable then
      d
    else if !(nonEmptyStr d.retiredOn) then
      err ''
        `enable = false` requires a non-empty `retiredOn` (e.g. "2026-07-27").
        A retirement with no date is not a decision, it is a hole.''
    else if !(nonEmptyStr d.executes) then
      err ''
        `enable = false` requires a non-empty `executes` describing what the
        verb WOULD have run. The refusal text is derived from it — without it
        the operator is told "no" and nothing else.''
    else if !(nonEmptyStr d.declaredIn) then
      err "`declaredIn` must be a non-empty string."
    else
      d;

  # ── The refusal notice ────────────────────────────────────────────────
  #
  # Derived from the declaration's own fields — not hand-typed per verb, and
  # never composed in shell.
  #
  # The optional `reason` is spliced in as an already-indented block so the
  # rendered text does not depend on Nix's per-string indentation stripping.
  retirementNotice = { name, verb, decl }:
    let
      reasonBlock = lib.optionalString (decl.reason != null)
        "\n  ${decl.reason}\n";
    in ''
    ${name}: `nix run .#${verb}` is RETIRED and refuses to run.

      retired on : ${decl.retiredOn}
      would have : ${decl.executes}
      retired by : ${decl.declaredIn}  mutatingVerbs.${verb}.enable = false

    WHY
      pangea-operator is the sole executor of pleme-io infrastructure
      (pleme-io/CLAUDE.md, "PLATFORM-MEDIATED INFRASTRUCTURE"). A human's
      only two verbs are DECLARE and OBSERVE — never plan by hand, never
      apply, never destroy. A hand-run `${verb}` drives an executor directly
      against state the operator cannot see, and races the reconciler on
      cloud resources it already owns.
    ${reasonBlock}
    DECLARE  (instead of running this)
      1. Author the change as a typed Pangea workspace under
         pleme-io/pangea-architectures (an existing workspace is usually the
         right home — extend it rather than adding a near-miss sibling).
      2. Point an InfrastructureTemplate CR at it under
         pleme-io/k8s/clusters/<cluster>/infrastructure/<name>/
         (source.gitRepository.url + .path, spec.templateName).
      3. git commit. FluxCD applies the CR; pangea-operator compiles it
         in-process and applies it via magma, writing state + receipt to
         Postgres in one transaction.

    OBSERVE  (instead of reading `${verb}` output)
      - the CR's `status.lastCycle` typed receipt
      - the Pangea-defined Grafana dashboards, via the grafana MCP

    IF THIS VERB IS GENUINELY NEEDED AGAIN
      It was retired, not deleted. Set
          mutatingVerbs.${verb}.enable = true;
      in ${decl.declaredIn}, state the typed reason in the commit, and add
      the matching `skip-platform-mediated:` waiver to the top of CLAUDE.md.
      The flag resolves at EVAL time — there is no runtime flag, env var or
      argument that re-enables it.
  '';

  # ── The refusal app ───────────────────────────────────────────────────
  mkRetiredApp = { pkgs, name, verb, decl }:
    let
      notice = pkgs.writeText "${name}-${verb}-retired.txt"
        (retirementNotice { inherit name verb decl; });
    in {
      type = "app";
      program = toString (pkgs.writeShellScript "${name}-${verb}-retired" ''
        cat ${notice} >&2
        exit 1
      '');
    };

  # ── The app-set transformer ───────────────────────────────────────────
  #
  # `verbs` is the builder's own list of retireable app names. A disabled
  # verb outside that list is a typo or a wrong-builder declaration, and
  # throws rather than silently doing nothing.
  retireApps =
    { pkgs
    , name
    , mutatingVerbs ? {}
    , verbs
    }: apps:
    let
      ctx = name;
      normalized = lib.mapAttrs (normalize ctx) mutatingVerbs;

      strayNames = builtins.filter (v: !(builtins.elem v verbs))
        (builtins.attrNames normalized);
      _strayCheck =
        if strayNames == [] then true
        else throw ''
          ${ctx}: mutatingVerbs declares verb(s) this builder does not
          produce: ${builtins.concatStringsSep ", " strayNames}.
          Retireable verbs here: ${builtins.concatStringsSep ", " verbs}.'';

      disabled = lib.filterAttrs (_verb: decl: !decl.enable)
        (builtins.seq _strayCheck normalized);

      retired = lib.mapAttrs
        (verb: decl: mkRetiredApp { inherit pkgs name verb decl; })
        disabled;
    in
    # Identity when nothing is retired: `apps` is returned as-is, `pkgs` is
    # never forced, no store path moves. This IS the backward-compat
    # guarantee, and it is asserted in tests/mutating-verbs-test.nix.
    if disabled == {} then apps else apps // retired;

in {
  inherit defaultDecl knownFields normalize retirementNotice mkRetiredApp retireApps;
}
