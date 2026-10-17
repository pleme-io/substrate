{ lib
, pkgs
, system
, substrateLib
, images
, sourceUrl
, docaPkg
, vulnixPkg
, grypePkg
, tataraScript
, claimReconcileTlisp ? ./cve-claim-reconcile.tlisp
, sourceRevision ? "unknown"
, releaseVersion ? null
, claimRoot ? null
, modules ? [ ]
, catalogExtra ? (_cfg: { })
, undeclaredDenominatorBaseline ? [ ]
, ociOverrides ? { }
, staticBinaryOnly ? { }
}:

let
  archSuffix = if system == "aarch64-linux" then "-arm64" else "";

  hardenedImageModule = import ./module.nix { inherit lib; };

  evalOne = name: spec:
    let
      evaluated = lib.evalModules {
        modules = [ hardenedImageModule ] ++ modules ++ [ { config = spec; } ];
      };
      cfg =
        if evaluated.config.cveClaims.enable then evaluated.config
        else evaluated.config // { vulnixWhitelist = null; grypeIgnoreFile = null; };

      blindWithNoSecondGate =
        cfg.trivyAnalysableTargets == [ ] && !cfg.hardeningTarget;

      newUndeclaredDenominator =
        cfg.trivyAnalysableTargets == null
        && !(builtins.elem name undeclaredDenominatorBaseline);

      nixBuiltMissingPackage =
        cfg.provenance == "nix-built" && cfg.package == null;
      rewrapMissingPins =
        cfg.provenance == "vendor-rewrap"
        && (cfg.upstreamDigest == null || cfg.upstreamSha256 == null || cfg.binaryPath == null);
      rewrapWithPackage =
        cfg.provenance == "vendor-rewrap" && cfg.package != null;
    in
    if cfg.base == "wolfi"
       && (cfg.wolfiRationale == null || cfg.wolfiRationale == "") then
      throw ''
        mkHardenedImageSet: image `${name}` sets base = "wolfi" with no
        `wolfiRationale`. wolfi ships busybox and its CVE stream, so the
        exception states its reason. For a shell or a few tools use
        `shell = true;` or `entrypointTools = [ "coreutils" ];`, which give
        the same functionality without busybox. Otherwise name the structural
        need, e.g.
          wolfiRationale = "upstream entrypoint execs busybox applets by name";
      ''
    else if lib.hasPrefix "0:" cfg.user
       && (cfg.rootRationale == null || cfg.rootRationale == "") then
      throw ''
        mkHardenedImageSet: image `${name}` sets user = "${cfg.user}" (ROOT) with no
        `rootRationale`. Name the structural need, e.g.
          rootRationale = "single-user-mode Nix must own /nix/store to add paths at runtime";
        or drop the `user` override; the default is non-root 65532:65532.
      ''
    else if cfg.grypeIgnoreFile != null
            && builtins.length (grypeClaimsOf cfg) < 0 then
      throw "unreachable"
    else if nixBuiltMissingPackage then
      throw ''
        mkHardenedImageSet: image `${name}` is `provenance = "nix-built"` (the
        default) but declares no `package`. A nix-built image IS its package's
        closure -- there is nothing to ship without one.
        Either set `package`, or set `provenance = "vendor-rewrap"` and supply
        `upstreamDigest` + `upstreamSha256` + `binaryPath`.
      ''
    else if rewrapMissingPins then
      throw ''
        mkHardenedImageSet: image `${name}` is `provenance = "vendor-rewrap"` but
        is missing one of `upstreamDigest` / `upstreamSha256` / `binaryPath`.
        A rewrap with no pinned digest hardens whatever the tag points at
        TODAY, which is not a reproducible claim about any artifact -- the
        digest is the only thing that makes "we hardened X" mean one X.
      ''
    else if rewrapWithPackage then
      throw ''
        mkHardenedImageSet: image `${name}` is `provenance = "vendor-rewrap"` and
        ALSO declares a `package`. Only one of them can be the shipped bytes,
        and a row that names both leaves a reader unable to tell which claim
        the image is making -- rebuilt-from-source, or vendor-binary-preserved.
        Drop the `package`, or switch to `provenance = "nix-built"`.
      ''
    else if newUndeclaredDenominator then
      throw ''
        mkHardenedImageSet: image `${name}` sets no `trivyAnalysableTargets`, so
        trivy's denominator for it is unmeasured, and it is not in the caller's
        `undeclaredDenominatorBaseline`. Measure it and declare the target
        types (or `[ ]` if it presents none, which then requires
        `hardeningTarget = true`). The baseline only shrinks.
      ''
    else if blindWithNoSecondGate then
      throw ''
        mkHardenedImageSet: image `${name}` declares `trivyAnalysableTargets = [ ]`
        -- trivy analyses NOTHING on it -- while `hardeningTarget = false` keeps
        vulnix from running. Every gate this image has would then be a scanner
        with a denominator of zero, whose exit 0 means "I inspected nothing",
        not "clean".
        Either set `hardeningTarget = true` (so `vulnix-scan:${cfg.service}` is
        generated and scans the delivered closure), or delete the
        `trivyAnalysableTargets` declaration if the blindness was never measured.
      ''
    else cfg // { _name = name; };

  evaluatedImages = lib.mapAttrs evalOne images;

  ociFor = name:
    if ociOverrides ? ${name}
    then { inherit (ociOverrides.${name}) mkPackageImage mkDistrolessImage bases; }
    else {
      inherit (substrateLib) mkPackageImage mkDistrolessImage mkVendorRewrap;
      bases = substrateLib.hardenedBases;
    };

  contentFor = name: cfg:
    if staticBinaryOnly ? ${name}
    then pkgs.runCommand "${cfg.package.pname or cfg.service}-static-binary" { } ''
      install -Dm0555 ${cfg.package}/bin/${staticBinaryOnly.${name}} \
        $out/bin/${staticBinaryOnly.${name}}
    ''
    else cfg.package;

  packageLabels = cfg: {
    "io.pleme.rebuild.package" = cfg.package.pname or cfg.service;
    "io.pleme.rebuild.version" = cfg.package.version or "unknown";
  };

  versionLabels = cfg: {
    "org.opencontainers.image.version" =
      if releaseVersion != null then releaseVersion else cfg.publishTag;
  }
  // {
    "org.opencontainers.image.revision" =
      if releaseVersion != null && sourceRevision == "unknown"
      then throw ''
        mkHardenedImageSet: refusing to build a RELEASE image with no source
        revision. `org.opencontainers.image.revision` would be "unknown", so the
        published artifact could not say which commit produced it. Build from a
        git checkout (pass `self.rev or self.dirtyRev`), or drop
        `releaseVersion` if this is not a release.
      ''
      else sourceRevision;
    "org.opencontainers.image.source" = sourceUrl;
    "io.pleme.provenance" = cfg.provenance;
  };

  mkImageFor = name: cfg:
    let
      oci = ociFor name;
      package = contentFor name cfg;
    in
    if cfg.provenance == "vendor-rewrap"
    then oci.mkVendorRewrap {
      inherit (cfg) service publishName publishTag cmd
        exposedPorts volumes env extraContents writablePaths user
        upstreamDigest upstreamSha256 binaryPath
        extraBinaryPaths extraRootfsPaths
        srcCredsEnv srcCredsUser;
      upstream = builtins.head (lib.splitString ":" cfg.upstreamImage);
      base = oci.bases.${cfg.base};
      labels = versionLabels cfg // {
        "io.pleme.provenance" = "vendor-rewrap";
        "io.pleme.rewrap.upstream.image" = cfg.upstreamImage;
      };
    }
    else if cfg.shell || cfg.entrypointTools != [ ]
    then oci.mkDistrolessImage {
      inherit package;
      inherit (cfg) service publishName publishTag entrypoint cmd
        exposedPorts volumes env extraContents writablePaths
        shell entrypointTools user maxLayers;
      labels = versionLabels cfg // packageLabels cfg;
    }
    else oci.mkPackageImage {
      inherit package;
      inherit (cfg) service publishName publishTag entrypoint cmd
        exposedPorts volumes env extraContents writablePaths user;
      base = oci.bases.${cfg.base};
      labels = versionLabels cfg // packageLabels cfg;
    };

  images_ = lib.mapAttrs mkImageFor evaluatedImages;

  closureInfos = lib.mapAttrs (_name: image: image.closureInfo) images_;

  cryptoBinRootFor = name: cfg:
    if cfg.package != null
    then cfg.package
    else images_.${name}.extractedBinary
      or (throw ("hardened-images: `${name}` declares bundledCryptoFloor but has "
               + "neither `package` nor an `extractedBinary` passthru. Set "
               + "`package`; a gate with no subject refuses rather than skips."));

  bundledCryptoGates = lib.mapAttrs
    (name: cfg: pkgs.runCommand "${name}-bundled-crypto-gate"
      { nativeBuildInputs = [ pkgs.binutils ]; }
      ''
        set -euo pipefail
        floor='${cfg.bundledCryptoFloor}'
        found=""
        for b in ${cryptoBinRootFor name cfg}/bin/*; do
          [ -f "$b" ] || continue
          v="$(strings -n 10 "$b" \
                | grep -aoE 'OpenSSL [0-9]+\.[0-9]+\.[0-9]+' \
                | sed 's/^OpenSSL //' | sort -V | tail -1 || true)"
          if [ -n "$v" ]; then found="$v"; break; fi
        done

        if [ -z "$found" ]; then
          echo "FAIL ${name}: bundledCryptoFloor = $floor is declared, but NO" >&2
          echo "  'OpenSSL X.Y.Z' string was found in any binary under" >&2
          echo "  ${cryptoBinRootFor name cfg}/bin. Either this image does not" >&2
          echo "  bundle OpenSSL" >&2
          echo "  (drop the floor), or the probe stopped working (fix it)." >&2
          echo "  Passing here would report coverage this gate does not have." >&2
          exit 1
        fi

        lowest="$(printf '%s\n%s\n' "$found" "$floor" | sort -V | head -1)"
        if [ "$lowest" != "$floor" ] && [ "$found" != "$floor" ]; then
          echo "FAIL ${name}: bundled OpenSSL $found is BELOW the declared" >&2
          echo "  floor $floor. A crypto downgrade is invisible to vulnix here:" >&2
          echo "  the library is statically linked and has no store path." >&2
          exit 1
        fi

        echo "$found" > $out
        echo "ok ${name}: bundled OpenSSL $found (floor $floor)"
      '')
    (lib.filterAttrs (_n: c: (c.bundledCryptoFloor or null) != null) evaluatedImages);

  mkPushApp = serviceSlug: image:
    let
      refParts = lib.splitString "/" image.imageName;
      pushRegistry = builtins.head refParts;
      pushRepo = lib.concatStringsSep "/" (builtins.tail refParts);
      wantsAlias = releaseVersion != null && releaseVersion != image.imageTag;
      pushArgs =
        [
          "push"
          "--backend" "native"
          "--registry" pushRegistry
          "--image" pushRepo
          "--tag" "${image.imageTag}${archSuffix}"
          "--tarball" "${image}"
        ]
        ++ lib.optionals wantsAlias [ "--additional-tags" "${releaseVersion}${archSuffix}" ];
    in
    {
      type = "app";
      program = toString (pkgs.writeShellScript "release-${serviceSlug}" ''
        set -euo pipefail
        exec ${docaPkg}/bin/oci-push ${lib.escapeShellArgs pushArgs}
      '');
    };

  pushApps = lib.mapAttrs'
    (name: cfg: lib.nameValuePair cfg.service (mkPushApp cfg.service images_.${name}))
    evaluatedImages;

  vulnixMergedOf = cfg:
    let
      files0 = cfg.vulnixWhitelist;
      files =
        if files0 == null then null
        else if builtins.isList files0 then files0
        else [ files0 ];
      mergeOne = acc: file:
        let parsed = builtins.fromTOML (builtins.readFile file);
        in acc // lib.mapAttrs
          (pkgKey: entry:
            let prior = acc.${pkgKey} or null; in
            if prior == null then entry
            else
              let dupes = lib.intersectLists (prior.cve or [ ]) (entry.cve or [ ]);
              in
              if dupes != [ ]
              then throw ''
                vulnix whitelist conflict for package `${pkgKey}` in image `${cfg.service}`:
                the same CVE id(s) ${builtins.concatStringsSep ", " dupes} are claimed by more
                than one whitelist file (last read: ${toString file}).
                One file asserts a FALSE POSITIVE, another asserts an ACCEPTED REAL RISK --
                those cannot both be true. Decide which it is and remove the other entry.
              ''
              else entry // {
                cve = (prior.cve or [ ]) ++ (entry.cve or [ ]);
                until =
                  let a = prior.until or null; b = entry.until or null; in
                  if a == null then b else if b == null then a
                  else if a < b then a else b;
              })
          parsed;
    in
    if files == null then { } else lib.foldl' mergeOne { } files;

  vulnixClaimsOf = cfg:
    let
      files0 = cfg.vulnixWhitelist;
      files =
        if files0 == null then [ ]
        else if builtins.isList files0 then files0
        else [ files0 ];
      ofFile = file:
        let parsed = builtins.fromTOML (builtins.readFile file); in
        lib.concatLists (lib.mapAttrsToList
          (pkgKey: e: map
            (cve: {
              inherit cve file;
              key = "${pkgKey}|${cve}";
              until = e.until or null;
            })
            (e.cve or [ ]))
          parsed);
    in
    lib.concatMap ofFile files;

  mergeVulnixWhitelists = cfg:
    let
      files = cfg.vulnixWhitelist;
      merged = vulnixMergedOf cfg;
      renderEntry = pkgKey: e: ''
        ["${pkgKey}"]
        cve = [ ${lib.concatMapStringsSep ", " (c: ''"${c}"'') (e.cve or [ ])} ]${
          lib.optionalString (e ? until) ''

            until = "${e.until}"''}
      '';
    in
    if files == null then null
    else if !(builtins.isList files) then files
    else if files == [ ] then null
    else if builtins.length files == 1 then builtins.head files
    else pkgs.writeText "vulnix-whitelist-${cfg.service}.toml" (''
      # GENERATED by mkHardenedImageSet: per-key union of
      ${lib.concatMapStringsSep "\n" (f: "#   ${toString f}") files}
    '' + "\n" + lib.concatStringsSep "\n" (lib.mapAttrsToList renderEntry merged));

  grypeClaimsOf = cfg:
    let
      files0 = cfg.grypeIgnoreFile;
      files =
        if files0 == null then null
        else if builtins.isList files0 then files0
        else [ files0 ];

      flakeText =
        if claimRoot == null then ""
        else builtins.readFile (claimRoot + "/flake.nix");

      containsLiteral = infix: content:
        builtins.stringLength (builtins.replaceStrings [ infix ] [ "" ] content)
          != builtins.stringLength content;

      readClaims = file:
        let
          parsed = builtins.fromTOML (builtins.readFile file);
          class = parsed.class or (throw ''
            grype claim file ${toString file} has no `class`.
            Every claim file declares which of the three classes it belongs to:
              class = "fixed-at-cause"   the code was removed -- name the patch
              class = "accepted-floor"   the code is present -- accept the risk
            An unclassed file cannot state which obligation it carries.
          '');
          until = parsed.until or null;
          entries = parsed.ignore or [ ];

          checkEntry = e:
            let
              cve = e.cve or (throw "grype claim file ${toString file}: an entry has no `cve`.");
              hasPatch = e ? patch;
              hasAnchor = e ? postpatch_anchor;
            in
            if class == "fixed-at-cause" then
              (if !hasPatch && !hasAnchor then throw ''
                grype claim ${cve} in ${toString file} names NO removal site.
                A fixed-at-cause claim asserts "the vulnerable code is gone", and the
                whole difference between that claim and a suppression is that the
                evidence is checkable. Give it exactly one of:
                  patch            = "patches/<area>/<file>.patch"   (a real patch,
                                     in the real patch list, applied at -F0)
                  postpatch_anchor = "<string>"                      (a guarded
                                     substituteInPlace in flake.nix that fails the
                                     build if its anchor moves)
                If neither exists, this CVE is not fixed at cause. Move it to the
                accepted-floor file, or fix it.
              '' else if hasPatch && hasAnchor then throw ''
                grype claim ${cve} in ${toString file} names TWO removal sites
                (`patch` and `postpatch_anchor`). Exactly one is the evidence; a
                claim pointing at two places is a claim nobody can check.
              '' else if hasPatch && claimRoot != null
                        && !(builtins.pathExists (claimRoot + ("/" + e.patch))) then throw ''
                grype claim ${cve} in ${toString file} names a patch that DOES NOT EXIST:
                  ${e.patch}
                The claim asserts this repo removed the vulnerable code at cause. The
                file that would prove it is not in the tree, so the claim is
                unbacked -- which is precisely the suppression this class exists not
                to be. Restore the patch, correct the path, or delete the claim.
              '' else if hasAnchor && e.postpatch_anchor == "" then throw ''
                grype claim ${cve} in ${toString file} has an EMPTY `postpatch_anchor`.
                An empty anchor is contained in every file trivially, so it would
                assert a build-enforced guard while checking nothing -- a
                suppression wearing a fixed-at-cause label. Name the real guard
                string from flake.nix.
              '' else if hasAnchor && claimRoot != null
                        && !(containsLiteral e.postpatch_anchor flakeText) then throw ''
                grype claim ${cve} in ${toString file} names a postPatch anchor that is
                NOT PRESENT in flake.nix:
                  ${e.postpatch_anchor}
                The guard that made this claim build-enforced is gone, so nothing now
                fails the build if the fix stops landing. Restore the guard or delete
                the claim.
              '' else e)
            else if class == "accepted-floor" then
              (if hasPatch || hasAnchor then throw ''
                accepted-floor claim ${cve} in ${toString file} names a removal site.
                An accepted-floor entry states the vulnerable code IS PRESENT and the
                risk is accepted. If a patch removes it, this is a fixed-at-cause
                claim and belongs in the fixed-at-cause file -- those two statements
                cannot both be true of the same advisory.
              '' else if !(e ? reason) then throw ''
                accepted-floor claim ${cve} in ${toString file} has no `reason`.
                A risk acceptance with no written justification is an undocumented
                suppression.
              '' else e)
            else throw ''
              grype claim file ${toString file} declares unknown class `${class}`.
              Known classes: "fixed-at-cause", "accepted-floor".
            '';

          renderReason = e:
            if class == "accepted-floor" then e.reason
            else if e ? patch
            then "FIXED AT CAUSE by ${e.patch} (applied at -p1 -F0). ${e.removes or ""}"
            else "FIXED AT CAUSE by flake.nix postPatch, build-guarded on anchor `${e.postpatch_anchor}`. ${e.removes or ""}";
        in
        map (e0: let e = checkEntry e0; in {
          inherit (e) cve;
          inherit file class until;
          name = e.name or (throw "grype claim ${e.cve} in ${toString file}: no `name` (the package name grype reports).");
          version = e.version or (throw "grype claim ${e.cve} in ${toString file}: no `version` (the package version grype reports).");
          reason = renderReason e;
        }) entries;

      allClaims = lib.concatMap readClaims (if files == null then [ ] else files);

      dupeCheck =
        let
          byCve = lib.groupBy (c: c.cve) allClaims;
          dupes = lib.filterAttrs (_cve: cs: builtins.length cs > 1) byCve;
        in
        if dupes == { } then allClaims
        else throw ''
          grype claim conflict in image `${cfg.service}`: the same CVE id(s) are claimed
          by more than one claim file --
          ${lib.concatStringsSep "\n" (lib.mapAttrsToList
            (cve: cs: "  ${cve}: ${lib.concatStringsSep ", " (map (c: "${toString c.file} (${c.class})") cs)}")
            dupes)}
          One file asserts the vulnerable code was REMOVED, another asserts it is
          PRESENT and accepted. Those cannot both be true. Decide which it is and
          remove the other entry.
        '';

    in
    if files == null then [ ] else dupeCheck;

  mergeGrypeIgnoreFiles = cfg:
    let
      files0 = cfg.grypeIgnoreFile;
      files =
        if files0 == null then null
        else if builtins.isList files0 then files0
        else [ files0 ];

      claims = grypeClaimsOf cfg;

      q = s: "'" + (lib.replaceStrings [ "'" ] [ "''" ] s) + "'";

      renderRule = c: ''
          - vulnerability: ${q c.cve}
            reason: ${q c.reason}
            package:
              name: ${q c.name}
              version: ${q c.version}'';
    in
    if files == null || files == [ ] then null
    else pkgs.writeText "grype-ignore-${cfg.service}.yaml" (''
      # GENERATED by mkHardenedImageSet from
      ${lib.concatMapStringsSep "\n" (f: "#   ${toString f}") files}
      ignore:
    '' + lib.concatStringsSep "\n" (map renderRule claims) + "\n");

  claimReconcileClaimsJson = { scanner, service, claims }:
    builtins.toJSON (map
      (c: {
        inherit (c) cve;
        file = baseNameOf (toString c.file);
        until = c.until or "";
        inherit (c) key;
      })
      claims);

  mkClaimReconcileScript = { scanner, service, claims }:
    let
      claimsFile = pkgs.writeText "cve-claims-${service}-${scanner}.json"
        (claimReconcileClaimsJson { inherit scanner service claims; });
    in
    pkgs.writeShellScript "cve-claim-reconcile-${service}-${scanner}" ''
      exec ${tataraScript}/bin/tatara-script ${claimReconcileTlisp} \
        ${claimsFile} "$1" ${lib.escapeShellArg service} ${lib.escapeShellArg scanner}
    '';

  mkVulnixScanApp = name: cfg:
    let
      whitelist = mergeVulnixWhitelists cfg;
      claims = vulnixClaimsOf cfg;
      hasClaims = claims != [ ];
      scanRoot = closureInfos.${name};
    in {
      type = "app";
      program = toString (pkgs.writeShellScript "vulnix-scan-${cfg.service}" (
        lib.optionalString hasClaims ''
          set -euo pipefail
          _found="$(${pkgs.coreutils}/bin/mktemp)"
          _report="$(${pkgs.coreutils}/bin/mktemp)"
          trap '${pkgs.coreutils}/bin/rm -f "$_found" "$_report"' EXIT
          ${vulnixPkg}/bin/vulnix \
            --cache-dir "''${VULNIX_CACHE_DIR:-$HOME/.cache/vulnix}" \
            -C --json --show-whitelisted \
            ${lib.optionalString (whitelist != null) "-w ${whitelist}"} \
            ${scanRoot} > "$_report" || true
          ${pkgs.jq}/bin/jq -e 'type == "array"' "$_report" > /dev/null || {
            echo "vulnix --json did not produce a JSON array -- refusing to reconcile claims against an unreadable report" >&2
            exit 1
          }
          ${pkgs.jq}/bin/jq -r '.[] | .name as $n
            | ((.affected_by // []) + (.whitelisted // []))[]
            | "\($n)|\(.)"' "$_report" | LC_ALL=C ${pkgs.coreutils}/bin/sort -u > "$_found"
          ${mkClaimReconcileScript { scanner = "vulnix"; service = cfg.service; inherit claims; }} "$_found"
          trap - EXIT
          ${pkgs.coreutils}/bin/rm -f "$_found" "$_report"
        '' + ''
        set -euo pipefail
        exec ${vulnixPkg}/bin/vulnix \
          --cache-dir "''${VULNIX_CACHE_DIR:-$HOME/.cache/vulnix}" \
          -C \
          ${lib.optionalString (whitelist != null) "-w ${whitelist}"} \
          "$@" \
          ${scanRoot}
      ''));
    };

  vulnixScanApps = lib.mapAttrs'
    (name: cfg: lib.nameValuePair cfg.service (mkVulnixScanApp name cfg))
    (lib.filterAttrs (_name: cfg: cfg.hardeningTarget) evaluatedImages);

  mkGrypeScanApp = name: cfg:
    let
      gate = substrateLib.mkCveGateApp {
        imagePath = images_.${name};
        scanner = "grype";
        failOn = [ "Negligible" ];
        failOnAny = true;
        ignoreFile = mergeGrypeIgnoreFiles cfg;
        inherit grypePkg;
      };
      claims = map (c: c // { key = "${c.name}|${c.version}|${c.cve}"; })
        (grypeClaimsOf cfg);
      hasClaims = claims != [ ];
    in {
      type = "app";
      program =
        if !hasClaims then toString gate
        else toString (pkgs.writeShellScript "grype-scan-${cfg.service}" ''
          set -euo pipefail

          export PATH="${grypePkg}/bin:$PATH"
          _report="$(${pkgs.coreutils}/bin/mktemp)"
          _found="$(${pkgs.coreutils}/bin/mktemp)"
          _plain=""
          trap '${pkgs.coreutils}/bin/rm -f "$_report" "$_found" "$_plain"' EXIT

          _target="${images_.${name}}"
          if ${pkgs.gzip}/bin/gzip -t "${images_.${name}}" 2>/dev/null; then
            _plain="$(${pkgs.coreutils}/bin/mktemp)"
            ${pkgs.gzip}/bin/gzip -dc "${images_.${name}}" > "$_plain"
            _target="$_plain"
          fi

          grype "docker-archive:$_target" -o "json=$_report" --quiet

          ${pkgs.jq}/bin/jq -e 'has("matches")' "$_report" > /dev/null || {
            echo "grype -o json produced no 'matches' key -- refusing to reconcile claims against an unreadable report" >&2
            exit 1
          }
          ${pkgs.jq}/bin/jq -r '.matches[] | .artifact.name as $n | .artifact.version as $v
            | ([.vulnerability.id] + [ (.relatedVulnerabilities // [])[].id ])[]
            | "\($n)|\($v)|\(.)"' "$_report" \
            | LC_ALL=C ${pkgs.coreutils}/bin/sort -u > "$_found"

          ${mkClaimReconcileScript { scanner = "grype"; service = cfg.service; inherit claims; }} "$_found"

          ${pkgs.coreutils}/bin/rm -f "$_report" "$_found" "$_plain"
          trap - EXIT

          exec ${gate}
        '');
    };

  grypeScanApps = lib.mapAttrs'
    (name: cfg: lib.nameValuePair cfg.service (mkGrypeScanApp name cfg))
    evaluatedImages;

  mkSbomAttestApp = name: cfg: {
    type = "app";
    program = toString (substrateLib.mkSbomAttestApp {
      imageRef = "${cfg.publishName}:${cfg.publishTag}";
      imagePath = images_.${name};
      format = "spdx-json";
    });
  };

  sbomAttestApps = lib.mapAttrs'
    (name: cfg: lib.nameValuePair cfg.service (mkSbomAttestApp name cfg))
    evaluatedImages;

  mkCosignSignApp = name: cfg: {
    type = "app";
    program = toString (substrateLib.mkCosignSignApp {
      imageRef = "${cfg.publishName}:${cfg.publishTag}";
      keyless = true;
    });
  };

  cosignSignApps = lib.mapAttrs'
    (name: cfg: lib.nameValuePair cfg.service (mkCosignSignApp name cfg))
    evaluatedImages;

  releaseAllApp = {
    type = "app";
    program = toString (pkgs.writeShellScript "release-all" ''
      set -euo pipefail
      ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: app: app.program) pushApps)}
    '');
  };

  catalog = lib.mapAttrs
    (name: cfg: {
      inherit (cfg) service upstreamImage hardeningRationale publishName
        publishTag hardeningTarget vulnixWhitelist grypeIgnoreFile
        trivyAnalysableTargets;
      pushTag = "${cfg.publishTag}${archSuffix}";
      cveClaims = {
        grype = map (c: { inherit (c) cve class until; file = baseNameOf (toString c.file);
                          package = "${c.name}-${c.version}"; })
          (grypeClaimsOf cfg);
        vulnix = map (c: { inherit (c) cve until; file = baseNameOf (toString c.file);
                           package = lib.head (lib.splitString "|" c.key); })
          (vulnixClaimsOf cfg);
      };
      cveClaimFiles =
        let norm = f: if f == null then [ ] else if builtins.isList f then f else [ f ];
        in map (p: baseNameOf (toString p))
          (norm cfg.vulnixWhitelist ++ norm cfg.grypeIgnoreFile);
      cveClaimReconcileClaims = {
        grype = claimReconcileClaimsJson {
          scanner = "grype"; service = cfg.service;
          claims = map (c: c // { key = "${c.name}|${c.version}|${c.cve}"; })
            (grypeClaimsOf cfg);
        };
        vulnix = claimReconcileClaimsJson {
          scanner = "vulnix"; service = cfg.service; claims = vulnixClaimsOf cfg;
        };
      };
    } // catalogExtra cfg)
    evaluatedImages;

in
{
  packages = (lib.mapAttrs' (name: image: lib.nameValuePair "${name}Image" image) images_)
    // (lib.mapAttrs' (name: ci: lib.nameValuePair "${name}ClosureInfo" ci) closureInfos)
    // (lib.mapAttrs' (name: g: lib.nameValuePair "${name}BundledCryptoGate" g) bundledCryptoGates);

  apps = (lib.mapAttrs' (name: app: lib.nameValuePair "release:${name}" app) pushApps)
    // (lib.mapAttrs' (name: app: lib.nameValuePair "vulnix-scan:${name}" app) vulnixScanApps)
    // (lib.mapAttrs' (name: app: lib.nameValuePair "grype-scan:${name}" app) grypeScanApps)
    // (lib.mapAttrs' (name: app: lib.nameValuePair "sbom-attest:${name}" app) sbomAttestApps)
    // (lib.mapAttrs' (name: app: lib.nameValuePair "cosign-sign:${name}" app) cosignSignApps)
    // { release = releaseAllApp; };

  inherit catalog;
}
