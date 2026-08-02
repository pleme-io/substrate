# cargo-nix-tie.nix — the freshness tie for a committed crate2nix `Cargo.nix`.
#
# ── THE GAP THIS CLOSES ─────────────────────────────────────────────────
#
# `Cargo.gen.lock` has a tie (the D2 gate in ./lockfile-delta.nix) and it
# works. `Cargo.nix` had NONE, so it drifts silently and ships. Measured
# 2026-08-01 over a local fleet checkout: of the **136** committed
# `Cargo.nix` files with a sibling `Cargo.lock`, **107 disagree with that
# lock** — `aresta` builds its shipped FIPS sidecar from a resolution graph
# naming `aws-lc-fips-sys 0.13.14` while `Cargo.lock` says `0.13.16`.
# (Local checkout with vendored mirrors: a lower bound, not an org-wide
# percentage.)
#
# ── WHY THE TIE IS DERIVED AND NOT A RECORDED HASH ──────────────────────
#
# D2's shape is `recorded input hash == hashFile of the current input`.
# **crate2nix records no input hash** — its output header is a version
# banner and nothing else (checked across all 136 files: crate2nix 0.15.0
# / 0.14.1, no hash field in any of them). So the recorded half does not
# exist and cannot be conjured without inventing a sidecar stamp.
#
# A sidecar was deliberately rejected. A stamp only binds repos that opted
# in, so `aresta` — the repo that motivated this — would have been exactly
# the unprotected case, and the `--if-present` branch that tolerates its
# absence is the fourth defect in the freshness-tie header, not a fix for
# the first three.
#
# So the tie is DERIVED from the artifact itself: the set of
# `name-version` pairs crate2nix emitted must equal the package set of the
# `Cargo.lock` it was generated from. crate2nix writes one crate entry per
# `cargo metadata` package, which is exactly `Cargo.lock`'s package list —
# and the 29 repos whose `Cargo.nix` is current match theirs EXACTLY, in
# both directions, which is what makes equality the invariant rather than a
# heuristic.
#
# ── WHAT THE TIE DOES NOT COVER — do not round this up ───────────────────
#
# The tie is over the RESOLVED DEPENDENCY GRAPH. A `Cargo.toml` edit that
# does not move `Cargo.lock` — flipping a feature on a dependency already
# in the graph — changes the per-crate `features` lists inside `Cargo.nix`
# and no `name-version` pair, so this tie does not see it. Closing that
# would mean re-deriving cargo's feature resolution in Nix: a second,
# untested copy of the resolver, which is the near-miss trap Operating
# Principle #1 names. The honest statement is that the tie covers graph
# drift, which is the class that shipped in `aresta`, and not feature
# drift. `pending-cargo-nix-tie: feature-resolution`.
#
# ── FAIL-CLOSED, AND NEVER ON THE WRONG DIAGNOSIS ───────────────────────
#
# The parser counts `crateName` declarations independently of the pairs it
# extracts. A shortfall throws a PARSE error naming the file, so a crate2nix
# output shape this file cannot read is never reported as staleness. Silent
# under-extraction would read as drift and send an operator to regenerate an
# artifact that was already current.
#
# TIER: eval-rejected (a Nix `throw`) on every path substrate itself imports
# a `Cargo.nix` through. A consumer flake that writes `import ./Cargo.nix`
# by hand is outside substrate's reach and stays only-mitigated until it
# adopts `importFresh`; see CLAUDE.md.
{ }:

let
  tie = import ../shared/freshness-tie.nix { };

  # ── Projection A: the artifact ──────────────────────────────────────
  #
  # crate2nix emits `version` on the line directly after `crateName` —
  # 21890 of 21890 declarations across the 136 committed `Cargo.nix` files
  # in the org, maximum gap 1 line. One two-capture regex covers every
  # entry, in a single pass (builtins.split over the whole file: 860 crates
  # out of mado's 1 MB artifact in 0.35s user, versus 0.66s for a
  # splitString-per-line walk that also drags in `lib`).
  crateEntryRe = "crateName = \"([^\"]*)\";\n[ ]*version = \"([^\"]*)\";";
  crateDeclRe = "crateName = \"[^\"]*\";";

  captures =
    re: text:
    builtins.filter (x: builtins.isList x) (builtins.split re text);

  artifactCrates =
    cargoNix:
    let
      text = builtins.readFile cargoNix;
      pairs = captures crateEntryRe text;
      decls = builtins.length (captures crateDeclRe text);
      names = map (x: "${builtins.elemAt x 0}-${builtins.elemAt x 1}") pairs;
    in
    if builtins.length names == decls then
      names
    else
      throw ''
        cargo-nix-tie: cannot read ${toString cargoNix}.
          crateName declarations found = ${toString decls}
          name/version pairs extracted = ${toString (builtins.length names)}

        Every crate2nix release observed in this org emits `version` on the
        line directly after `crateName`; this file does not. Reporting the
        shortfall as DRIFT would send you to regenerate an artifact that may
        already be current, so it is reported as a parser gap instead.

        Fix the parser in lib/build/rust/cargo-nix-tie.nix — do not silence
        the tie.
      '';

  # ── Projection B: the source the artifact was generated from ────────
  lockCrates =
    cargoLock:
    let
      lock = builtins.fromTOML (builtins.readFile cargoLock);
      pkgs = lock.package or [ ];
    in
    map (p: "${p.name}-${p.version or "0.0.0"}") pkgs;

  # Is this a committed `Cargo.nix` FILE, rather than a directory or
  # nothing at all?
  #
  # The directory case is not hypothetical. crate2nix's
  # `tools.nix`.generatedCargoNix returns a DERIVATION whose output is a
  # store directory holding `default.nix`; `import` handles that, `readFile`
  # does not. Three builders (library, library-workspace, wasm) fall back to
  # it when no Cargo.nix is committed, and the first cut of this tie was
  # handed that fallback and would have read a directory on every repo whose
  # IFD generation SUCCEEDED — caught only because the one consumer tested
  # first had a pre-existing IFD build failure that masked it.
  #
  # Both halves of the fix are kept: the callers now name the committed path
  # (there is nothing to tie about a file crate2nix just generated from the
  # tree), AND the primitive refuses a non-file rather than trusting them.
  # A guard whose correctness depends on every call site getting it right is
  # the call sites' guard, not the primitive's.
  isCommittedFile =
    p: builtins.pathExists p && builtins.readFileType p == "regular";

  toSet = xs: builtins.listToAttrs (map (x: { name = x; value = true; }) xs);
  minus = xs: ys: let s = toSet ys; in builtins.filter (x: !(s ? ${x})) xs;

  # Bound the message: the interesting fact is WHICH WAY it drifted and by
  # how much, not a 241-line diff pasted into a nix trace.
  sample =
    xs:
    let
      n = builtins.length xs;
      shown = builtins.concatStringsSep ", " (
        if n <= 6 then xs else builtins.genList (i: builtins.elemAt xs i) 6
      );
    in
    if n == 0 then "none" else "${toString n} (${shown}${if n > 6 then ", …" else ""})";

in
rec {
  inherit artifactCrates lockCrates;

  # status :: { cargoNix, cargoLock ? <sibling> } -> verdict
  #
  # `kind` is one of:
  #   "absent" — no committed Cargo.nix (or no sibling Cargo.lock to tie it
  #              to). NOT "fresh": there is nothing to have verified, and a
  #              guard that reports a tier it does not have over an empty
  #              subject set is exactly tier ⊥. Callers must be able to tell
  #              "verified current" from "nothing to verify".
  #   "fresh"  — the artifact's crate set equals the lock's, both ways.
  #   "stale"  — it does not.
  status =
    {
      cargoNix,
      cargoLock ? (builtins.dirOf cargoNix) + "/Cargo.lock",
    }:
    if !(isCommittedFile cargoNix && builtins.pathExists cargoLock) then
      {
        kind = "absent";
        missing = [ ];
        extra = [ ];
        lockCount = 0;
        artifactCount = 0;
      }
    else
      let
        a = artifactCrates cargoNix;
        l = lockCrates cargoLock;
        missing = minus l a;
        extra = minus a l;
      in
      {
        kind = if missing == [ ] && extra == [ ] then "fresh" else "stale";
        inherit missing extra;
        lockCount = builtins.length l;
        artifactCount = builtins.length a;
      };

  # assertFresh :: { cargoNix, cargoLock ? …, src ? … } -> a -> a
  #
  # `builtins.seq`s the tie in front of the value, so a stale artifact
  # throws BEFORE anything is built from it. Returns the value untouched
  # when the artifact is absent — a repo with no `Cargo.nix` evaluates
  # byte-identically to before this file existed.
  assertFresh =
    {
      cargoNix,
      cargoLock ? (builtins.dirOf cargoNix) + "/Cargo.lock",
      src ? builtins.dirOf cargoNix,
    }:
    value:
    let
      v = status { inherit cargoNix cargoLock; };
      held = tie.held {
        subject = "cargo-nix-tie";
        artifact = "Cargo.nix";
        where = tie.hint src;
        fresh = v.kind != "stale";
        sides = [
          "Cargo.lock packages           = ${toString v.lockCount}"
          "Cargo.nix crates              = ${toString v.artifactCount}"
          "in Cargo.lock, NOT in Cargo.nix = ${sample v.missing}"
          "in Cargo.nix, NOT in Cargo.lock = ${sample v.extra}"
        ];
        cause = ''
          The committed Cargo.nix was generated from a DIFFERENT Cargo.lock
          than the one in the tree, so anything built through it links a
          resolution graph the manifest disowns. This is a HARD EVAL FAILURE
          rather than a warning because the artifact is what SHIPS: aresta's
          FIPS sidecar carried aws-lc-fips-sys 0.13.14 against a lock that
          resolved 0.13.16, for thirteen days, with nothing to say so.'';
        fix = ''
          cd <that workspace> && crate2nix generate && git add Cargo.nix

          OR, if nothing imports this Cargo.nix, delete it — do not
          regenerate it. substrate's default Rust path is the
          lockfile-builder (Cargo.lock + Cargo.gen.lock) and needs no
          Cargo.nix at all, which is why 107 of the 136 committed ones in
          the org are stale: they are unread files nobody had a reason to
          refresh.
            cd <that workspace> && git rm Cargo.nix'';
        fleetFix = ''
          nix-instantiate --eval --strict --impure --expr \
            '(import "''${substrate}/lib/build/rust/cargo-nix-tie.nix" { }).audit [ ./a ./b … ]' '';
      };
    in
    builtins.seq held value;

  # audit :: [ path ] -> { <workspace> = kind; … }
  #
  # The many-workspaces view, for the operator who wants the whole backlog
  # rather than one eval failure at a time. Reports rather than throws on
  # purpose: a scan that dies on the first stale entry cannot enumerate the
  # rest, which is the job. `absent` is reported distinctly from `fresh` so
  # a workspace with nothing to tie is never counted as verified.
  audit =
    roots:
    builtins.listToAttrs (
      map (r: {
        name = toString r;
        value = (status { cargoNix = r + "/Cargo.nix"; }).kind;
      }) roots
    );

  # importFresh — the drop-in for `import ./Cargo.nix { … }`.
  #
  # Every site inside substrate that imports a Cargo.nix goes through this,
  # so the tie cannot be skipped by adding a tenth import site. A consumer
  # flake importing its own Cargo.nix directly (4 in the org: aresta,
  # pangea-operator/pangea-web, dev-tools/nix-cli, dev-tools/rust-init)
  # converts with one line:
  #
  #   import ./Cargo.nix ARGS
  #   -> (import "${substrate}/lib/build/rust/cargo-nix-tie.nix" { })
  #        .importFresh { cargoNix = ./Cargo.nix; args = ARGS; }
  importFresh =
    {
      cargoNix,
      args,
      cargoLock ? (builtins.dirOf cargoNix) + "/Cargo.lock",
      src ? builtins.dirOf cargoNix,
    }:
    assertFresh { inherit cargoNix cargoLock src; } (import cargoNix args);
}
