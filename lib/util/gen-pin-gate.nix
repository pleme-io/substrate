# gen-pin-gate.nix — every `lib/build/**/gen-pin.json` must be well-shaped, and
# two pins at DIFFERENT revs may not carry the SAME hash.
#
# ── THE DEFECT THIS EXISTS TO CATCH, measured 2026-08-08 ────────────────
#
#   lib/build/go/gen-pin.json    rev e8feaecf…  sha256-Iu1fjgg1v+ZsIxrGX…
#   lib/build/rust/gen-pin.json  rev bd36597c…  sha256-Iu1fjgg1v+ZsIxrGX…
#
# Two revs 13 days apart carrying a BYTE-IDENTICAL hash. That is impossible
# for content-addressed source unless one of them is simply wrong, and one
# was: measured with `nix flake prefetch`, `e8feaecf…` is really
# `sha256-9dySUYlj9sZKHBDQ1nSsbeLttlHohbDTorhTax4NDHY=`. The Go pin had been
# copied from the Rust pin with the rev edited and the hash left behind.
#
# Nothing caught it because nothing compared the two FILES. Each is
# individually well-formed, and each is only exercised when its own ecosystem
# takes the IFD path — which for Go is never (see build/go/lockfile-builder.nix).
# So the wrong pin sat correct-looking and unused, and would have failed with
# a hash mismatch the first time a Go IFD build ran.
#
# ── WHY CROSS-FILE, NOT PER-FILE ────────────────────────────────────────
#
# A per-file shape check passes both of the above. The information that
# something is wrong exists ONLY in the relationship between the two files,
# which is exactly the kind of invariant a hand-maintained set never holds.
# `readDir` discovers the pins rather than a hand-list, so a third ecosystem's
# pin is covered the day it lands, not the day someone remembers to add it.
#
# TIER: eval-rejected (a Nix `throw`). Not unrepresentable — nothing stops a
# human writing a wrong hash — but the wrong hash cannot survive an eval.
{ lib }:
let
  buildDir = ../build;

  # Discover, never hand-list.
  ecosystems = builtins.attrNames
    (lib.filterAttrs (_: t: t == "directory") (builtins.readDir buildDir));

  pinsFound = builtins.filter (p: p != null) (map
    (eco:
      let f = buildDir + "/${eco}/gen-pin.json";
      in if builtins.pathExists f
         then { name = eco; path = "lib/build/${eco}/gen-pin.json"; value = builtins.fromJSON (builtins.readFile f); }
         else null)
    ecosystems);

  # ── shape ────────────────────────────────────────────────────────────
  shapeErrors = builtins.concatMap
    (p:
      let v = p.value; in
      (lib.optional (!(v ? rev)) "${p.path}: missing `rev`")
      ++ (lib.optional (!(v ? sha256)) "${p.path}: missing `sha256`")
      ++ (lib.optional (v ? rev && builtins.stringLength v.rev != 40)
            "${p.path}: `rev` is not a 40-char commit sha (got ${toString (builtins.stringLength v.rev)} chars) — an abbreviated rev is not reproducible")
      ++ (lib.optional (v ? sha256 && !(lib.hasPrefix "sha256-" v.sha256))
            "${p.path}: `sha256` is not SRI-shaped (must start `sha256-`)"))
    pinsFound;

  # ── cross-file distinctness: the half that caught the real defect ────
  byHash = lib.groupBy (p: p.value.sha256 or "<none>") pinsFound;

  collisions = lib.filterAttrs
    (_: group:
      builtins.length group > 1
      && builtins.length (lib.unique (map (p: p.value.rev or "<none>") group)) > 1)
    byHash;

  collisionErrors = lib.mapAttrsToList
    (hash: group: ''
      the same hash is recorded for DIFFERENT revs — at most one can be right:
            hash = ${hash}
      ${builtins.concatStringsSep "\n" (map (p: "        ${p.path}  rev ${builtins.substring 0 12 (p.value.rev or "?")}") group)}
          Measure the truth, do not guess which one to keep:
            nix flake prefetch --json github:pleme-io/gen/<rev> | jq -r .hash'')
    collisions;

  errors = shapeErrors ++ collisionErrors;
in
if errors != [ ] then
  throw ''
    gen-pin-gate: ${toString (builtins.length errors)} problem(s) across ${toString (builtins.length pinsFound)} gen pin(s).

    ${builtins.concatStringsSep "\n\n    " errors}

    A gen pin names the exact gen revision an ecosystem's IFD path fetches.
    A wrong hash is not caught by anything else: each file is individually
    well-formed, and a pin is only exercised when its own ecosystem takes the
    IFD path — so a wrong one sits correct-looking until the first build that
    needs it.
  ''
else
  # Report shape shared with every other eval suite: `{ total; passed; }`, so
  # eval-suites.nix's `fromPassedTotal` reads it and its assertion floor
  # applies. One "assertion" per pin checked — a floor of 2 means a future
  # change that stops discovering a pin goes RED rather than trivially green,
  # which is the non-vacuity property that matters for a readDir-driven check.
  { total = builtins.length pinsFound; passed = builtins.length pinsFound; }
