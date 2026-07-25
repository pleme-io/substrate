# distroless-toolset.nix — the curated tool-bundle catalog for
# `mkDistrolessImage`'s `entrypointTools` (see ./hardened-base.nix).
#
# ═══════════════════════════════════════════════════════════════════════
# Why this exists (Pillar 8 — "distroless is the enforced default posture")
# ═══════════════════════════════════════════════════════════════════════
#
# Making an image distroless-but-functional is a *toolset-gathering*
# problem: the entrypoint bare-invokes a handful of external commands
# (`mkdir`, `sed`, `hostname`, `ps`, …) and a distroless base ships none
# of them, so the image needs exactly those tools on PATH — and NOTHING
# else (every extra package is closure the CVE scanner sees). The wrong
# answer is `base = wolfi` (distroless-glibc + the WHOLE of busybox, which
# carries a recurring CVE stream incl. CRITICAL CVE-2022-48174). The right
# answer is to DECLARE the minimal set.
#
# This catalog turns "declare the minimal set" from *authoring a raw
# nixpkgs package list at every call site* into *picking from a standard,
# named, reviewed set of concern-bundles*. A bundle is the MINIMAL nixpkgs
# packages for one concern (text processing, process inspection, …); an
# image declares the bundles its entrypoint actually needs and gets a
# reviewed-once closure, not a hand-rolled one.
#
# `mkDistrolessImage`'s `entrypointTools` accepts a heterogeneous list of
# EITHER a bundle name (a string, e.g. `"coreutils"`) OR a raw package
# derivation (e.g. `pkgs.barman-cloud`, an image-specific tool with no
# generic bundle). `resolveTools` below expands that mixed list to a flat
# package list. Raw packages pass through untouched, so this is fully
# backward-compatible with every existing `entrypointTools = [ pkgs.foo ]`
# call.
#
# ═══════════════════════════════════════════════════════════════════════
# Grounding — the bundles come from what fleet images actually bare-invoke
# ═══════════════════════════════════════════════════════════════════════
#
#   mysql   → coreutils          (mysqlEntrypoint bare-invokes `mkdir`)
#   rabbitmq→ coreutils, textproc(sed)  (rabbitmq-env's baked runtimePath)
#   neo4j   → shell + textproc(grep) + process(ps)  (bin/neo4j launcher)
#   cnpg    → coreutils + <barman-cloud>   (barman-cloud is image-specific
#                                           → a RAW package, not a bundle)
#
# Barman-cloud is exactly why `entrypointTools` must also take raw
# packages: not every tool a launcher needs is a generic concern.
#
# The command→bundle mapping (`mkdir` → `coreutils`, `sed` → `textproc`)
# lives in the sibling static enumerator (./entrypoint-enumerate.nix), the
# single source of that knowledge; this file owns only bundle→packages.
#
# Keep it a plain typed attrset — no framework, no over-engineering. A new
# bundle is one attribute; a new concern is one line.
{ pkgs }:

let
  inherit (pkgs) lib;

  # ── The bundles ──────────────────────────────────────────────────────
  # Each attr = the MINIMAL nixpkgs packages for one concern. Evaluated
  # LAZILY: a bundle a consumer never selects costs it nothing and never
  # forces its packages (so a channel that lacks one of these attrs only
  # breaks a consumer that actually selects that bundle).
  bundles = {
    # Core file/text utilities: mkdir, cat, ln, chmod, chown, cp, mv, rm,
    # ls, mktemp, id, dirname, basename, env, date, readlink, head, tail,
    # touch, tr, wc, sort, cut, tee, stat, sha256sum, base64, … The single
    # most-reached-for bundle — nearly every launcher touches one of these.
    coreutils = [ pkgs.coreutils ];

    # Stream text processing: sed, grep/egrep/fgrep, awk/gawk. The classic
    # launcher trio for editing config, matching state, extracting fields.
    textproc = [ pkgs.gnused pkgs.gnugrep pkgs.gawk ];

    # Process inspection / signalling: ps, free, top, pgrep, pkill, pidof,
    # sysctl, vmstat. Needed by runtimes that watermark their own memory
    # (rabbitmq) or supervise child PIDs (neo4j).
    process = [ pkgs.procps ];

    # Network identity + basics: hostname (many launchers run `hostname
    # -s` for the node name), ip (iproute2), ping (iputils).
    net = [ pkgs.hostname pkgs.iproute2 pkgs.iputils ];

    # Archive/compression: tar, gzip/gunzip/zcat, xz/unxz. Needed by
    # entrypoints that unpack a bundled asset (plugins, seed data) at boot.
    archive = [ pkgs.gnutar pkgs.gzip pkgs.xz ];

    # File discovery: find, xargs. Launchers that iterate a config
    # directory or a plugins tree.
    findutils = [ pkgs.findutils ];

    # `which` — a launcher that resolves a sibling binary by name. (Prefer
    # a shell's `command -v` builtin where possible; this bundle is for
    # scripts that literally invoke `which`.)
    which = [ pkgs.which ];

    # A shell binary ON PATH (dash — glibc-only, ~near-nil CVE surface).
    # NOTE: for a script whose SHEBANG is `#!/bin/sh`, prefer the
    # `shell = true` FLAG on mkDistrolessImage — that installs the
    # `/bin/sh` symlink the kernel execs by absolute path. This bundle
    # only puts `dash` (and `sh` via the flag's symlink is separate) on
    # PATH, for a script that invokes `sh`/`dash` by name mid-body.
    shell = [ pkgs.dash ];
  };

  bundleNames = lib.attrNames bundles;

  # ── The resolver ─────────────────────────────────────────────────────
  # resolveTools :: [ (string | derivation) ] -> [ derivation ]
  #
  # Each selection item is EITHER a bundle name (string → expands to the
  # bundle's package list) OR a raw package derivation (passed through as a
  # one-element list). Concat-maps to a flat, de-duplicated package list.
  # An unknown bundle name is a `nix eval`-time error naming the typo and
  # every valid bundle — never a silent empty expansion that would surface
  # as a mysterious "command not found" at container boot.
  resolveTools = sel:
    let
      expandOne = item:
        if lib.isString item then
          (bundles.${item} or (throw ''
            distroless-toolset: unknown bundle "${item}".
            Known bundles: ${lib.concatStringsSep ", " bundleNames}.
            (To add an image-specific tool with no generic bundle, pass the
            raw package derivation instead of a name string.)''))
        else if lib.isDerivation item then [ item ]
        # A non-derivation attrset (e.g. a runCommand-style content dir that
        # is still a valid buildLayeredImage `contents` entry) also passes
        # through — mkDistrolessImage's baseExtra accepts any contents value.
        else if lib.isAttrs item then [ item ]
        else throw ''
          distroless-toolset: each entrypointTools item must be a bundle
          name (string) or a package derivation; got ${builtins.typeOf item}.'';
    in
    lib.unique (lib.concatMap expandOne sel);

in {
  inherit bundles bundleNames resolveTools;
}
