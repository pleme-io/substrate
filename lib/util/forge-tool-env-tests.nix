# forge-tool-env-tests.nix — every provider that execs a forge subcommand needing
# a container tool must ALSO export that tool's env var.
#
# ── WHY THIS SUITE EXISTS ───────────────────────────────────────────────────
# The same defect was found and hand-fixed SEVEN times across two days
# (2026-07-31 → 2026-08-01): forge's push/image-release paths were converted from
# skopeo to doca, which changed the env var they resolve (SKOPEO_BIN → DOCA_BIN),
# and the providers that hand forge its environment were not all updated.
#
#   lib/service/image-release.nix        lib/build/rust/crate2nix-apps.nix
#   lib/build/shared/release-app.nix     lib/build/web/docker.nix
#   lib/build/ruby/build.nix             lib/service/platform-service.nix
#   (+ engenho-promessa-controllers' private-push wrapper, out of tree)
#
# WHY IT SURVIVED REVIEW EACH TIME. Before the conversion these resolved
# SKOPEO_BIN, else a bare `skopeo` — and skopeo is commonly ambient on a CI
# runner or in a devshell, so the missing export was invisible. `oci-push` is a
# pleme-io binary and is ambient NOWHERE, so the identical code path went from
# usually-working to always-failing without any line changing at the call site.
#
# The sharpest instance carried a CORRECT measurement and a CORRECT removal:
#
#   # skopeo dropped: SKOPEO_BIN had zero consumers (measured with a control).
#   ${mkRuntimeToolsEnv { tools = []; }}
#   exec ${forge}/bin/forge push ...
#
# forge really had stopped reading SKOPEO_BIN. Dropping it was right. The
# COUNTERPART — exporting DOCA_BIN — never landed, and a correct measurement plus
# a correct removal minus the addition they imply reads as a finished change.
# That is what this suite makes impossible to repeat quietly.
#
# ── WHAT IT CHECKS, AND WHAT IT DELIBERATELY DOES NOT ───────────────────────
# STATIC, over the .nix SOURCE — not over a rendered script. Rendering needs
# `pkgs` and this catalog is pure-`lib` by design. A source-level check is also
# the stronger one here: it fails at the file that forgot the export, naming it,
# rather than at whichever consumer happened to be built first.
#
# It does NOT verify the exported path is correct, that oci-push exists, or that
# forge reads it. Those are runtime facts; this is the wiring invariant only.
{ lib }:

let
  testHelpers = import ./test-helpers.nix { inherit lib; };

  root = ../.;

  # Recursively collect every .nix file under lib/, skipping this suite itself
  # (its own prose names both the command and the var, which would self-match).
  collect = dir:
    let
      entries = builtins.readDir dir;
      go = name: type:
        if type == "directory" then collect (dir + "/${name}")
        else if lib.hasSuffix ".nix" name && name != "forge-tool-env-tests.nix"
        then [ { path = dir + "/${name}"; label = "${toString dir}/${name}"; } ]
        else [ ];
    in lib.concatLists (lib.mapAttrsToList go entries);

  files = collect root;

  # A provider is a file that EXECS one of the forge subcommands whose tool
  # resolution moved to doca. Matching the exec form (not a bare mention) keeps
  # prose and catalog role-strings out of the subject set.
  # COMMENT LINES ARE NOT CALL SITES. The first run of this suite matched five
  # files on prose alone ("Release app -- invokes forge image-release with both
  # arch images") and on delegation to an already-fixed module. A gate whose
  # findings are 4/5 prose gets ignored, so the subject set is lines of CODE.
  #
  # Deliberately matches several spellings of the exec: `${forgeCmd} push`,
  # `${forgeTool}/bin/forge push`, `${forge}/bin/forge push`. Two rounds of hand
  # grepping used only the first and missed lib/service/helpers.nix entirely.
  codeLines = text:
    builtins.filter
      (l: let t = lib.removePrefix " " l; in
          !(lib.hasPrefix "#" (lib.trim l)))
      (lib.splitString "\n" text);

  execsForgePush = text:
    lib.any
      (l: lib.any (m: lib.hasInfix m l) [
            # `exec ${forgeCmd} push` renders here as the literal `forgeCmd} push`
            # -- it does NOT contain "forge push". Dropping this spelling while
            # tightening took the matcher from 6 providers to 2, and the
            # non-vacuity floor below is what caught it.
            "forgeCmd} push"
            "forgeCmd} image-release"
            "forge push"
            "forge image-release"
          ])
      (codeLines text);

  # ★ TIGHTENED 2026-08-01. Was `lib.hasInfix "DOCA_BIN" text` — a substring
  # test over the WHOLE file, comments included. The detector above was
  # deliberately hardened against comment lines (`codeLines`); this assertion
  # was not, and that asymmetry is the whole defect: a suite that reads code to
  # decide WHO must be checked, then reads prose to decide whether they PASS.
  #
  # Measured on the tree that introduced this fix: 11 files under lib/ contain
  # the string `DOCA_BIN`, but only 7 contain an actual `DOCA_BIN=` assignment.
  # So 4 files satisfied the old predicate on prose alone — and the worst case
  # was lib/service/image-release.nix, whose header paragraph EXPLAINS that
  # when `ociPush` is null the app runs without DOCA_BIN and forge fails. The
  # gate was satisfied by the documentation of its own violation. (Sharper
  # still: a comment naming DOCA_BIN added while documenting the REMOVAL of a
  # neighbouring export would have kept this green after deleting the real one.)
  #
  # Requiring `DOCA_BIN=` rather than `DOCA_BIN` is what makes prose unable to
  # pass: every real site is `export DOCA_BIN="…"`, while every prose mention
  # measured names the bare variable. Checked against all 7 exporters — no
  # legitimate spelling is excluded.
  # ★ EXTENDED 2026-08-01, same day: `mkDocaExport` counts, and counts as
  # STRONGER than a literal export — not as a loophole.
  #
  # A literal `export DOCA_BIN="…"` in a provider is, in every case measured
  # here, wrapped in `optionalString (ociPush != null)`. That text satisfies a
  # source-level predicate whether or not the branch ever renders, and
  # `ociPush ? null` is the default in all seven files — so "contains a real
  # assignment" was never the same claim as "exports it". The difference is not
  # in the file; it is in the ARGUMENT, so no regex over the text can see it.
  # (lib/service/platform-service.nix is the existence proof: it carried the
  # conditional export and is not passed ociPush by any constructor.)
  #
  # `util/doca-env.nix::mkDocaExport` removes the branch instead of describing
  # it — null throws at eval, naming the repair. So delegating to it is a
  # stronger guarantee than the literal line this predicate was written to find,
  # and the predicate accepts it on that basis rather than as an exemption.
  providesDoca = text:
    lib.any
      (l: lib.any (m: lib.hasInfix m l) [ "DOCA_BIN=" "mkDocaExport" ])
      (codeLines text);

  read = f: builtins.readFile f.path;

  providers = builtins.filter (f: execsForgePush (read f)) files;

  # One test per provider: it must export DOCA_BIN.
  perProvider = map
    (f: testHelpers.mkTest
      "forge-push-provider-exports-DOCA_BIN:${baseNameOf f.label}"
      (providesDoca (read f))
      ("${f.label} execs a forge push/image-release but never exports DOCA_BIN. "
       + "forge resolves DOCA_BIN, else a bare `oci-push` on PATH — and oci-push "
       + "is ambient nowhere, so this fails at runtime for every consumer. Thread "
       + "`ociPush ? null` into this file and export DOCA_BIN when non-null."))
    providers;

  # NON-VACUITY FLOOR. A suite whose subject set silently became empty reports
  # "all passed" over nothing — the exact class this whole campaign keeps
  # removing. 6 providers existed when this was written; the floor is set just
  # below so a legitimate consolidation does not wedge CI, while a filter that
  # stops matching does.
  floor = testHelpers.mkTest
    "at-least-4-forge-push-providers-were-examined"
    (builtins.length providers >= 4)
    ("only ${toString (builtins.length providers)} forge-push provider(s) matched "
     + "across ${toString (builtins.length files)} .nix file(s) under lib/. Six "
     + "existed on 2026-08-01, so a count this low means the MATCHER stopped "
     + "matching, not that the providers went away. A green over an empty "
     + "subject set is worth nothing.");

in
testHelpers.runTests (perProvider ++ [ floor ])
