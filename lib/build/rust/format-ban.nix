# pleme-io typed-emission enforcement substrate helper.
#
# Canonical: https://github.com/pleme-io/theory/blob/main/TYPED-EMISSION.md
# Pillar 12 operationalized at the Rust language level.
#
# Surface (call via `import ./format-ban.nix { inherit pkgs; }`):
#
#   clippyTomlPath    : path to the reference clippy.toml in this directory
#   clippyTomlSnippet : the canonical clippy.toml content as a string
#   withFormatBan src : RETIRED 2026-07-28 — see "TYPED RETIREMENT" below
#   auditFormatBan src: RETIRED 2026-07-28 — see "TYPED RETIREMENT" below
#
# The hard enforcement gate is `cargo clippy -- -D warnings` against a
# workspace that has the disallowed-macros entry in its clippy.toml.
# `clippyTomlPath` / `clippyTomlSnippet` are LIVE and are what the shipping
# route consumes: `lib/build/shared/cargo-release-app.nix` copies this file
# into a conf dir and exports `CLIPPY_CONF_DIR` at it inside `check-all`.
#
# ══ TYPED RETIREMENT ═══════════════════════════════════════════════════
#
# `withFormatBan` and `auditFormatBan` are retired, NOT deleted (★★
# MODULARIZE, DON'T DELETE). Both had zero call sites fleet-wide — all
# hits under `rg --no-ignore` were comments and doc mentions.
#
# WHY THEY ARE DEAD — SUPERSEDED, not "someone forgot to wire them".
# That distinction was checked before retiring, because wiring would have
# been the right answer if the mechanism still fit anything:
#
#   `withFormatBan` is a SOURCE TRANSFORM. It returns a nix-store copy of
#   `src` with clippy.toml injected. For that to enforce anything, some
#   DERIVATION has to run `cargo clippy` against the transformed store
#   path — and no substrate builder does. Enforcement lives in `check-all`,
#   a `writeShellScript` app the operator runs in their own checkout, so
#   clippy reads clippy.toml from CWD and never sees a store copy. The
#   `CLIPPY_CONF_DIR` route (cargo-release-app.nix:39-60) reaches the same
#   clippy, in that same app, without copying the tree or mutating the
#   repo — and cargo-release-app.nix:36-37 says in its own words that it is
#   "the substrate-side enforcement the `with-format-ban` helper was
#   designed for". Strictly better mechanism, same goal.
#
#   `auditFormatBan` counts `rg 'format!\('` hits. That counts PROSE ABOUT
#   the ban as instances of the ban — the exact measurement trap this
#   repo's own CLAUDE.md documents, and one that has already produced a
#   published wrong number (a doc claimed 5 `format!()` sites in
#   egaku-term; four of the five were doc-comments stating there is no
#   `format!()`, the true count was 1). The live replacement is
#   `pleme-io/format-ban`, which walks the syn AST via `syn::visit::Visit`
#   and tracks impl context, so it exempts Display/Debug bodies instead of
#   miscounting them.
#
# WHAT RETIRING THESE DOES **NOT** FIX — do not read this as "done here".
# Neither helper was ever capable of closing the real hole, and the hole
# is open. Measured 2026-07-28 over a local fleet checkout (vendored
# mirrors included; lower bounds, not org-wide percentages):
#
#   * `CLIPPY_CONF_DIR` occurs at exactly two substrate source sites, both
#     on the library path. `library.nix:165` is the only call site of
#     `mkCargoReleaseApps` and hardcodes `formatBan = true`, so all 16
#     `library.nix` consumers get the ban unconditionally — and nothing
#     else does.
#   * 9 flakes consume `rust-workspace-release-flake` (galho, kakureyado,
#     kurayami, magma, mamorigami, misogi, tatara-lisp, tear, zukai). They
#     are NOT ban-less for want of a `check-all`: `workspace-release.nix`
#     is a thin wrapper over `tool-release.nix`, whose `check-all`
#     (tool-release.nix:384) comes from a DIFFERENT helper,
#     `lib/util/release-helpers.nix:43`, which execs
#     `forge tool check --name X --language rust`. That lands in
#     `forge/cli/src/commands/tool.rs:205`, `cargo clippy -- -D warnings`
#     with no CLIPPY_CONF_DIR — so clippy runs with no config and
#     `disallowed_macros` is never populated.
#   * So the workspace gap is a MISSING CONFIG ON AN EXISTING CLIPPY RUN,
#     one repo boundary away (forge, or swapping which `mkCheckAllApp`
#     tool-release uses). `withFormatBan` could not have closed it: a
#     clippy.toml in a store path is invisible to a clippy that runs in
#     the operator's CWD.
#   * `library-workspace.nix` — whose own `mkCheckAllApp` (line 112) also
#     carries no `formatBan` — has ZERO consumers; its
#     `rust-library-workspace-flake` entry point is named only by a comment
#     in `hikari/flake.nix`. Real gap, empty population.
#
# Tracked as `pending-format-ban: workspace-path-clippy-conf`. Deliberately
# NOT fixed in the same change as this retirement: it crosses into forge
# and deserves its own diff.

{ pkgs, ... }:

let
  clippyTomlPath = ./format-ban.clippy.toml;
  clippyTomlSnippet = builtins.readFile clippyTomlPath;

  # ── The retirement declaration ────────────────────────────────────────
  #
  # Same grammar as `lib/infra/mutating-verbs.nix`: `enable` defaults true,
  # `enable = false` REQUIRES `retiredOn` + `supersededBy`, and the refusal
  # is derived from the declaration's own fields rather than hand-typed.
  # The implementations below are kept intact — restoring either helper is
  # flipping one field and committing, not recovering a deletion.
  #
  # THE FLAG RESOLVES AT EVAL TIME. A retired helper still EXISTS and still
  # resolves as an attribute; it is calling it that refuses. There is no
  # runtime flag, env var or argument that can satisfy it.
  retirement = {
    withFormatBan = {
      enable = false;
      retiredOn = "2026-07-28";
      supersededBy =
        "lib/build/shared/cargo-release-app.nix `mkCheckAllApp { formatBan = true; }`"
        + " → CLIPPY_CONF_DIR, reached from lib/build/rust/library.nix:165";
      reason =
        "A source transform cannot configure a clippy that runs in the"
        + " operator's CWD. CLIPPY_CONF_DIR reaches the same clippy without"
        + " copying the tree. Zero call sites fleet-wide at retirement.";
    };
    auditFormatBan = {
      enable = false;
      retiredOn = "2026-07-28";
      supersededBy = "github:pleme-io/format-ban (AST-aware, syn::visit::Visit)";
      reason =
        "A regex count of `format!\\(` counts doc-comments ABOUT the ban as"
        + " violations of it, and has already published a wrong number."
        + " Zero call sites fleet-wide at retirement.";
    };
  };

  # ── Validation: loud over silent ──────────────────────────────────────
  #
  # A retirement missing its date or its replacement is not a decision, it
  # is a hole — and a hole that reads as a decision is worse than none.
  normalize = fn: decl:
    let
      err = msg: throw "format-ban.nix: retirement.${fn}: ${msg}";
      nonEmptyStr = v: builtins.isString v && v != "";
    in
    if !(builtins.isBool decl.enable) then
      err "`enable` must be a bool, got ${builtins.typeOf decl.enable}."
    else if decl.enable then decl
    else if !(nonEmptyStr decl.retiredOn) then
      err "`enable = false` requires a non-empty `retiredOn` (e.g. \"2026-07-28\")."
    else if !(nonEmptyStr decl.supersededBy) then
      err ''
        `enable = false` requires a non-empty `supersededBy`. The refusal text
        is derived from it — without it the caller is told "no" and nothing
        else, which is how a retirement becomes an unexplained gap.''
    else decl;

  # ── The refusal ───────────────────────────────────────────────────────
  refusalFor = fn: decl: throw ''
    substrate: `${fn}` is RETIRED and refuses to run.

      retired on   : ${decl.retiredOn}
      superseded by: ${decl.supersededBy}
      declared in  : lib/build/rust/format-ban.nix  retirement.${fn}.enable = false

    WHY
      ${decl.reason}

    IF THIS HELPER IS GENUINELY NEEDED AGAIN
      It was retired, not deleted — the implementation is intact directly
      below the declaration. Set
          retirement.${fn}.enable = true;
      in lib/build/rust/format-ban.nix, and state in the commit what the
      superseding route cannot do. The flag resolves at EVAL time.
  '';

  # Wrap a single-argument helper in its declaration. Enabled → the real
  # implementation, BY IDENTITY. Disabled → a function of the same arity
  # that throws, so `import`ing this file stays lazy and free.
  retire = fn: impl:
    let decl = normalize fn retirement.${fn};
    in if decl.enable then impl else (_src: refusalFor fn decl);

  withFormatBanImpl = src:
    pkgs.runCommand "with-format-ban" { } ''
      cp -r ${src} $out
      chmod -R u+w $out
      if [ -f $out/clippy.toml ]; then
        if ! grep -q '"std::format"' $out/clippy.toml; then
          {
            echo ""
            echo "# Appended by substrate's withFormatBan (pleme-io/theory/TYPED-EMISSION.md)."
            cat ${clippyTomlPath}
          } >> $out/clippy.toml
        fi
      else
        cp ${clippyTomlPath} $out/clippy.toml
      fi
    '';

  auditFormatBanImpl = src:
    pkgs.runCommand "audit-format-ban" {
      nativeBuildInputs = [ pkgs.ripgrep ];
    } ''
      mkdir -p $out
      cd ${src}
      # Per-file count of format!() occurrences. --no-ignore so we still
      # see files inside .gitignore'd build outputs (target/, dist/, etc.)
      # — but exclude those explicitly via -g.
      rg --no-ignore -t rust -c 'format!\(' \
         -g '!target/' -g '!.git/' -g '!node_modules/' -g '!dist/' \
         . > $out/per-file-counts.txt 2>/dev/null || true
      sort -t: -k2 -rn $out/per-file-counts.txt > $out/per-file-counts.sorted.txt
      total=$(rg --no-ignore -t rust 'format!\(' \
                -g '!target/' -g '!.git/' -g '!node_modules/' -g '!dist/' \
                . 2>/dev/null | wc -l)
      files=$(wc -l < $out/per-file-counts.txt)
      {
        echo "format!() audit (pleme-io/theory/TYPED-EMISSION.md)"
        echo "  Total call sites: $total"
        echo "  Files with at least one format!(): $files"
        echo ""
        echo "Top 30 hotspot files:"
        head -30 $out/per-file-counts.sorted.txt
      } > $out/summary.txt
    '';
  withFormatBan = retire "withFormatBan" withFormatBanImpl;
  auditFormatBan = retire "auditFormatBan" auditFormatBanImpl;
in
{
  inherit clippyTomlPath clippyTomlSnippet withFormatBan auditFormatBan;

  # Exposed so a reader (or a future audit) can query the retirement
  # without parsing prose: `(import ./format-ban.nix { … }).retirement`.
  inherit retirement;
}
