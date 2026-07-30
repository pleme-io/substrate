# cargo-audit-data.nix — make a shipped Rust binary SCANNABLE.
#
# THE PROBLEM THIS EXISTS TO CLOSE, measured 2026-07-30 on rio:
#
#   A Nix distroless image whose only content is a static Rust binary has NO
#   OS package DB and NO embedded dependency metadata. Trivy therefore emits
#   JSON with no `Results` key AT ALL and exits 0, and its table view prints
#
#       Target: -   Type: -   Vulnerabilities: -
#
#   whose own legend reads `'-': Not scanned`. Every gate downstream reads that
#   as clean. The gate passes BECAUSE IT INSPECTED NOTHING — the whole crate
#   tree (457 crates for hanabi, carrying 8 live advisories including four
#   rustls-webpki certificate-validation defects) is unscanned at every stage.
#
#   Proven by control: taking nixpkgs' `ripgrep` (which DOES carry `.dep-v0`)
#   and running `objcopy --remove-section .dep-v0` flips trivy from a real
#   `Target: rg / Type: rustbinary` row to `Results` absent + exit 0. The
#   absence of the section IS the vacuity, at the byte level.
#
# WHY cargo-auditable itself cannot do this here. `cargo auditable` works by
# wrapping `cargo build` and reading `cargo metadata`. substrate's Rust service
# path (gen/Cargo.gen.lock -> pkgs.buildRustCrate) drives `rustc` directly, per
# crate, and never invokes `cargo` — so there is no insertion point. This is not
# a flag someone forgot to flip. What cargo-auditable *produces*, though, is
# just a zlib-compressed JSON document in an ELF section, and every fact in it
# is already known at eval time: it IS the lockfile. So we synthesize it.
#
# WHAT IT DOES NOT PROVE (do not round this up). This is a CVE-database verdict
# against a RESOLVED DEPENDENCY GRAPH, keyed to the scanners' DBs at scan
# epoch. It is NOT a closure theorem. The complementary surface — which store
# paths ship, presence/absence — is `closureInfo` + vulnix, and that one can
# never see a crate advisory (hanabi's whole runtime closure is ONE derivation
# named `rust_hanabi-bff-1.0.5`, which NVD has no entry for). The two are
# complements; say which is which in every claim.
#
# FIDELITY, stated so nobody has to guess:
#   • EVERY lock-resident package is emitted, and none is marked `kind =
#     "build"`. Trivy skips build-kind packages, so marking them would let a
#     finding disappear. Emitting everything as runtime means this surface
#     never UNDER-reports — it reports exactly what `trivy fs` on the same
#     Cargo.lock reports, which is what every other scanner keys on too.
#   • Cargo.lock does not distinguish dev-dependencies or
#     not-in-default-feature deps, so a lock-resident-but-not-compiled-in crate
#     is reported. That is the same over-report every lockfile scanner makes,
#     and per the purify doctrine it is also the highest-leverage remediation
#     class: stripping such a dep takes the finding to 0 with an IDENTICAL
#     runtime binary.
#
# Section format, reverse-engineered from nixpkgs' own cargo-auditable-built
# ripgrep (`objcopy --dump-section .dep-v0`, zlib-inflate, 42 packages):
#
#   { "packages": [ { "name", "version", "source", "kind"?, "dependencies"?,
#                     "root"? } ] }
#
#   `dependencies` are INDICES into the same array. `source` is one of
#   "crates.io" | "git" | "registry" | "local". `kind` is omitted for runtime.
#   Exactly one entry carries `root: true`.
{ }:
let
  # ── the blob ───────────────────────────────────────────────────────────
  #
  # `lockFile` is a path to a real Cargo.lock — the universal artifact, present
  # on every Rust build path in the fleet (buildRustCrate, buildRustPackage,
  # crate2nix, naersk), which is why the surface keys on it rather than on any
  # one builder's internals.
  mkCargoAuditData = pkgs: {
    name,
    lockFile,
    # The workspace member the binary is built from, e.g. "hanabi-bff". Marked
    # `root: true` so the document is a faithful cargo-auditable blob rather
    # than an anonymous package bag.
    rootCrate ? null,
  }:
  let
    lib = pkgs.lib;
    lock = builtins.fromTOML (builtins.readFile lockFile);

    rawPackages =
      if lock ? package then lock.package
      else throw ''
        mkCargoAuditData: ${toString lockFile} has no [[package]] entries.

        That is not an empty dependency tree — it is the wrong file. A gate
        built on an empty package list would report a clean scan having
        analysed nothing, which is the exact defect this primitive exists to
        close, so it is a hard error instead.
      '';

    # cargo-auditable orders by (name, version); keeping that order makes the
    # emitted document diffable against a real one.
    ordered = lib.sort
      (a: b: if a.name != b.name then a.name < b.name else a.version < b.version)
      rawPackages;

    # Both keying forms Cargo.lock uses in a `dependencies` list: the
    # disambiguated "name version" and the bare "name" (which cargo only emits
    # when the name is unique in the lock, so the two can never disagree).
    indexOf = builtins.listToAttrs (
      (lib.imap0 (i: p: { name = "${p.name} ${p.version}"; value = i; }) ordered)
      ++ (lib.imap0 (i: p: { name = p.name; value = i; }) ordered)
    );

    sourceOf = p:
      let s = p.source or null; in
      if s == null then "local"
      else if s == "registry+https://github.com/rust-lang/crates.io-index" then "crates.io"
      else if lib.hasPrefix "git+" s then "git"
      else "registry";

    # A `dependencies` entry is "name", "name version", or
    # "name version (source)". Taking the first two whitespace fields covers
    # all three.
    depIndices = p:
      let
        resolve = d:
          let
            parts = lib.splitString " " d;
            key =
              if builtins.length parts >= 2
              then "${builtins.elemAt parts 0} ${builtins.elemAt parts 1}"
              else builtins.head parts;
          in
          indexOf.${key} or (indexOf.${builtins.head parts} or null);
        resolved = map resolve (p.dependencies or []);
      in
      lib.sort (a: b: a < b) (lib.unique (builtins.filter (x: x != null) resolved));

    entryOf = p:
      { inherit (p) name version; source = sourceOf p; }
      // (let d = depIndices p; in lib.optionalAttrs (d != [ ]) { dependencies = d; })
      // lib.optionalAttrs (rootCrate != null && p.name == rootCrate) { root = true; };

    packageCount = builtins.length ordered;

    rootMatches = builtins.length (builtins.filter (p: rootCrate != null && p.name == rootCrate) ordered);

    _rootOk =
      if rootCrate == null || rootMatches == 1 then true
      else throw ''
        mkCargoAuditData: rootCrate "${rootCrate}" matches ${toString rootMatches} packages in ${toString lockFile}.

        Exactly one is required. A wrong crate name silently produces a
        rootless document, which still scans but no longer says which package
        the binary IS — so it is rejected at eval rather than shipped.
      '';

    # builtins.toJSON, not an assembled string: the document is built as typed
    # Nix data and serialized once (★★ TYPED EMISSION at the JSON target).
    document = builtins.toJSON { packages = map entryOf ordered; };
    json = pkgs.writeText "${name}-dep-v0.json" document;
  in
  assert _rootOk;
  pkgs.runCommand "${name}-cargo-audit-data"
    {
      nativeBuildInputs = [ pkgs.qpdf ];
      passthru = { inherit json packageCount lockFile rootCrate; };
    }
    ''
      mkdir -p "$out"
      zlib-flate -compress=9 < ${json} > "$out/dep-v0.z"
      echo "${toString packageCount}" > "$out/package-count"
    '';

  # ── the injection ──────────────────────────────────────────────────────
  #
  # ONE canonical objcopy invocation, so no consumer re-derives the section
  # flags. `noload,readonly` keeps it a non-ALLOC note section: it never enters
  # the process image, so a scannable binary and a minimal one are the same
  # binary.
  #
  # ORDERING IS LOAD-BEARING: `.dep-v0` is non-ALLOC, which is exactly what
  # `strip --strip-all` removes. Splice this AFTER any strip, never before.
  #
  # `objcopy` is the command name, so a consumer using a prefixed toolchain
  # passes "${pkgs.stdenv.cc.targetPrefix}objcopy" rather than assuming the
  # native one is on PATH.
  injectCommand = { auditData, target, objcopy ? "objcopy" }:
    "${objcopy} --add-section .dep-v0=${auditData}/dep-v0.z --set-section-flags .dep-v0=noload,readonly ${target}";
in
{
  inherit mkCargoAuditData injectCommand;
}
