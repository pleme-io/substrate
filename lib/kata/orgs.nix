# kata.orgs — ONE typed declaration per code org → every face the fleet
# renders it into.
#
# A workstation knows an org in five independent places: tend's workspace
# list (does it get cloned and reconciled), the CLAUDE.md org table (does
# an agent know it exists), zoekt's sources (is it searchable), codesearch's
# sources (is it semantically searchable), and its `.envrc` (does entering
# the directory sync it). Before this letter each of those was written by
# hand, and the fleet had all three failure modes at once:
#
#   Aster-IDE      on disk, in NONE of the five — invisible to tend and to
#                  both indexes, discovered only by `ls`.
#   binti-family   in the CLAUDE.md table and both indexes, NOT a tend
#                  workspace — an org an agent is told about and tend never
#                  syncs.
#   drzln          declared identically in nodes/cid and nodes/ryn, ~30
#                  lines each, byte-for-byte.
#
# None of those is a typo. They are what a fan-out with no join looks like:
# five lists that must agree, no expression that says so, so they drift one
# careful edit at a time. The zoekt and codesearch source lists were the
# clearest tell — copy-pasted verbatim within each of three separate files,
# differing in nothing but the option path they were assigned to.
#
# ── ★ WHAT IS AND IS NOT MADE UNREPRESENTABLE ───────────────────────────
# Honest tier, stated up front because "one source of truth" invites
# rounding up:
#
#   TRULY UNREPRESENTABLE — an org that is a tend workspace but missing
#     from an index, or indexed by zoekt but not codesearch. Those faces
#     are `map`ped from one list; there is no second list to disagree with.
#     The binti-family and copy-paste classes are gone structurally, not
#     by a check.
#
#   A TYPED DECISION, NOT A GATE — `sync = false` / `index = false`. An org
#     may legitimately want one and not the other, so opting out stays
#     possible; what changed is that it is now one visible field at the
#     declaration instead of an absence nobody can see. An omission became
#     a statement.
#
#   NOT CAUGHT HERE AT ALL — a directory on disk that no one declared (the
#     Aster-IDE class). Nix cannot see ~/code at eval time, so no type can
#     reach it. That gap belongs to a runtime reconciler, and until one
#     scans for undeclared org directories this letter does not close it.
#     Adding Aster-IDE below fixes the instance; it does not fix the class.
#
# ── ★ WHY JSON AND NOT RENDERED YAML ────────────────────────────────────
# `tendConfig` is an attrset the caller serializes with `builtins.toJSON`.
# YAML 1.2 is a JSON superset and serde_yaml parses it, so the emitted file
# is valid tend config with no indentation logic anywhere — the same choice
# blackmatter-tend/nixos/default.nix:96 already made for the NixOS arm.
#
# It also decides the escape hatch's TYPE. The surface this replaces took
# per-org extras as `types.lines`, so `watch`, `flake_deps` and
# `file_watches` were indented YAML text spliced into a string. Here they
# are ordinary Nix attrsets: merged, overridable, and wrong-shape-visible
# at eval instead of at tend's parser. String concatenation is why an org
# could be in tend and nowhere else without anything failing.
#
# Exports (pure { lib }):
#
#   mkOrgs :: {
#     orgs :: attrsOf orgSpec (required, non-empty — typed throw);
#       orgSpec = {
#         description ? name   — the CLAUDE.md table cell; required in
#                        practice because an untyped org reads as a typo.
#         kind        ? "org"  — "org" | "user". GitHub's API distinguishes
#                        them and the indexers take it verbatim; `drzln` is
#                        a user, everything else here is an org.
#         cloneMethod ? "ssh"  — "ssh" | "https". https for orgs we do not
#                        own (the akeyless pair).
#         discover    ? true   — tend enumerates the org via the GitHub API.
#                        false = only what is already on disk plus
#                        `extraRepos`, which is what a personal account
#                        wants when most of its repos are not worth cloning.
#         sync        ? true   — participate in tend at all.
#         index       ? true   — participate in zoekt + codesearch. One
#                        field, both indexes: they cannot diverge.
#         exclude     ? [ ]    — repo names tend skips.
#         extraRepos  ? [ ]    — repos to clone that discovery misses.
#         skipForks   ? true
#         skipArchived? true
#         baseDir     ? "<codeRoot>/<name>"
#         watch       ? null   — tend's per-workspace watch block, as an
#                        attrset (flake_refresh, file_watches, matrix_file…).
#         flakeDeps   ? null   — attrsOf (listOf str), tend's propagation
#                        graph. Only pleme-io has one.
#         extraConfig ? { }    — merged last into the workspace attrs, for
#                        a tend key this letter does not model yet.
#       };
#     codeRoot ? "~/code/github";
#     service  ? "github";     — the tend provider + the CLAUDE.md service.
#   } -> {
#     tendConfig     :: attrs   — the WHOLE tend config; toJSON it.
#     tendWorkspaces :: list    — just the workspaces, for a caller merging.
#     orgEntries     :: attrs   — blackmatter…github.claudeMd.orgEntries.
#     indexSources   :: list    — assign to BOTH zoekt and codesearch.
#     envrcFiles     :: attrs   — home.file entries, path -> { text }.
#     declared       :: list    — org names, sorted. For gates + reports.
#   }
{ lib }:
let
  inherit (lib)
    mapAttrs
    attrNames
    filterAttrs
    sort
    optionalAttrs
    ;

  validKinds = [
    "org"
    "user"
  ];
  validCloneMethods = [
    "ssh"
    "https"
  ];

  # A typed throw beats a wrong-shaped render: an unknown `kind` would be
  # passed straight to the indexers, which would enumerate nothing and
  # report no error — an org that silently indexes empty.
  checkEnum =
    field: valid: orgName: value:
    if builtins.elem value valid then
      value
    else
      throw (
        "kata.orgs: org '${orgName}' has ${field} = ${builtins.toJSON value}; "
        + "expected one of ${builtins.toJSON valid}."
      );
  # ── ★ THE OPTION TYPE LIVES HERE, NOT IN THE CONSUMER ─────────────────
  # A home-manager module needs a `types.attrsOf <something>` for its orgs
  # option. Writing that submodule in the consumer would restate this
  # letter's schema in a second place — the exact fan-out `mkOrgs` exists
  # to remove — and the two would drift the first time a field is added.
  # Exported so the option type and the renderer are the same declaration.
  #
  # Deliberately loose where `mkOrgs` is strict: `kind`/`cloneMethod` are
  # plain `str` here and validated by the typed throws in `mkOrgs`, which
  # name the offending org. A `types.enum` would reject with the option
  # path and the bad value but not say which org — worse for an operator
  # reading a rebuild failure.
  orgType = lib.types.submodule (
    { name, ... }:
    {
      options = {
        description = lib.mkOption {
          type = lib.types.str;
          default = name;
          description = "The CLAUDE.md org-table cell. Defaults to the org name, which reads as a typo — set it.";
        };
        kind = lib.mkOption {
          type = lib.types.str;
          default = "org";
          description = "kind: org or user. GitHub's API distinguishes them and both indexers take it verbatim.";
        };
        cloneMethod = lib.mkOption {
          type = lib.types.str;
          default = "ssh";
          description = "cloneMethod: ssh or https. https for orgs we do not own.";
        };
        discover = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "tend enumerates the org via the GitHub API. false = only what is on disk plus extraRepos.";
        };
        sync = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Participate in tend. false makes an org searchable without being reconciled — a decision, not an omission.";
        };
        index = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Participate in zoekt AND codesearch. One field, both indexes: they cannot diverge.";
        };
        exclude = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = "Repo names tend skips.";
        };
        extraRepos = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = "Repos to clone that discovery misses.";
        };
        skipForks = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Indexers skip forks.";
        };
        skipArchived = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Indexers skip archived repos.";
        };
        baseDir = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Clone root. null derives <codeRoot>/<name>.";
        };
        watch = lib.mkOption {
          type = lib.types.nullOr (lib.types.attrsOf lib.types.anything);
          default = null;
          description = "tend's per-workspace watch block as an ATTRSET (flake_refresh, file_watches, matrix_file). Typed, not indented YAML spliced into a string.";
        };
        flakeDeps = lib.mkOption {
          type = lib.types.nullOr (lib.types.attrsOf (lib.types.listOf lib.types.str));
          default = null;
          description = "tend's flake propagation graph: repo -> the repos that must be bumped when it moves.";
        };
        extraConfig = lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          default = { };
          description = "Merged last into the workspace attrs, for a tend key this letter does not model yet.";
        };
      };
    }
  );
in
{
  inherit orgType;

  mkOrgs =
    {
      orgs,
      codeRoot ? "~/code/github",
      service ? "github",
    }:
    let
      # ── ★ THE EMPTINESS CHECK GUARDS `norm`, IT IS NOT A LOOSE BINDING ──
      # Written first as `_ = if orgs == {} then throw ... else null;`,
      # which never fired: nothing referenced `_`, so Nix never forced it.
      # The suite caught it — the case asserting a throw got a clean value
      # back. Guarding `norm` means any face touching an org forces this.
      norm =
        if orgs == { } then
          throw "kata.orgs: `orgs` is empty. A fleet with no declared org renders an empty tend config, an empty CLAUDE.md table and two empty indexes — four artifacts that each look like a healthy machine."
        else
          mapAttrs (
            name: o:
            let
              kind = checkEnum "kind" validKinds name (o.kind or "org");
              cloneMethod = checkEnum "cloneMethod" validCloneMethods name (o.cloneMethod or "ssh");
            in
            {
              inherit name kind cloneMethod;
              description = o.description or name;
              discover = o.discover or true;
              sync = o.sync or true;
              index = o.index or true;
              exclude = o.exclude or [ ];
              extraRepos = o.extraRepos or [ ];
              skipForks = o.skipForks or true;
              skipArchived = o.skipArchived or true;
              baseDir = if (o.baseDir or null) == null then "${codeRoot}/${name}" else o.baseDir;
              watch = o.watch or null;
              flakeDeps = o.flakeDeps or null;
              extraConfig = o.extraConfig or { };
            }
          ) orgs;

      all = lib.attrValues norm;
      synced = builtins.filter (o: o.sync) all;
      indexed = builtins.filter (o: o.index) all;

      toWorkspace =
        o:
        {
          name = o.name;
          provider = service;
          base_dir = o.baseDir;
          clone_method = o.cloneMethod;
          discover = o.discover;
          org = o.name;
          exclude = o.exclude;
          extra_repos = o.extraRepos;
        }
        // optionalAttrs (o.flakeDeps != null) { flake_deps = o.flakeDeps; }
        // optionalAttrs (o.watch != null) { watch = o.watch; }
        // o.extraConfig;

      # ── ★ ONE SOURCE FOR BOTH INDEXES ─────────────────────────────────
      # Returned as a single list precisely so the caller assigns the same
      # value twice. The three copy-pasted zoekt/codesearch pairs this
      # replaces were identical in every case — the duplication carried no
      # information, only the opportunity to update one and not the other.
      toSource = o: {
        owner = o.name;
        kind = o.kind;
        cloneBase = o.baseDir;
        skipArchived = o.skipArchived;
        skipForks = o.skipForks;
      };
    in
    {
      tendConfig = {
        workspaces = map toWorkspace synced;
      };
      tendWorkspaces = map toWorkspace synced;

      orgEntries = mapAttrs (_: o: {
        inherit (o) description cloneMethod;
      }) norm;

      indexSources = map toSource indexed;

      # `use_tend` on entry. Emitted for synced orgs only: an .envrc that
      # syncs a workspace tend does not know about would fail on every cd.
      envrcFiles = builtins.listToAttrs (
        map (o: {
          name = "code/${service}/${o.name}/.envrc";
          value = {
            text = "use_tend\n";
          };
        }) synced
      );

      declared = sort (a: b: a < b) (attrNames norm);

      # Reported rather than thrown: opting out is legitimate, but a
      # consumer writing a doctor surface should be able to say which orgs
      # are deliberately partial without re-deriving the rule.
      partial = attrNames (filterAttrs (_: o: !o.sync || !o.index) norm);
    };
}
