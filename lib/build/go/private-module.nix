# goPrivateModuleBuilder — hermetic buildGoModule for PRIVATE org Go deps.
#
# THE GAP (borealis-pattern-registry §4f, Pri **highest**):
#   `buildGoModule`'s default vendor FOD reaches the PUBLIC Go module proxy
#   (`proxy.golang.org`) only. A repo that imports a PRIVATE pleme-io (or any
#   private org) module — `github.com/pleme-io/<private>` behind auth — cannot
#   resolve that import inside the network-restricted Nix sandbox: the vendor
#   FOD has no credential to authenticate to the private remote, and stuffing a
#   token in via `--impure` / `builtins.getEnv` poisons reproducibility and
#   breaks cartorio attestation. This builder closes that gap WITHOUT `--impure`.
#
# HERMETICITY MODEL (GSDS LAYOUT-12 / SEC-10):
#   The fleet resolves deps through the module proxy + committed `go.sum` +
#   a Nix `vendorHash` — never a committed `vendor/` tree, never `-mod=vendor`
#   authored in-repo. The vendor FOD is content-addressed: it is ALLOWED network
#   (that is the whole point of a fixed-output derivation) but its OUTPUT is
#   pinned by `vendorHash`, so the deploy-token only ever influences HOW the
#   bytes are fetched, never WHICH bytes land. Same token, different token, or
#   an Athens cache — the FOD output hash is identical or the build fails closed.
#   => deterministic, cartorio-attestable, no `--impure`.
#
# TWO TYPED FETCH SHAPES (`privateFetch.kind`):
#   "deploy-token"  — FOD vendor-fetch. A git `insteadOf` rewrite injects a
#                     read-only deploy token into the HTTPS remote for the
#                     private host(s) inside the vendor FOD's `GIT_CONFIG`.
#                     `GOPRIVATE`/`GONOSUMCHECK` exempt the private prefixes
#                     from the public sum DB + checksum proxy. The token is
#                     materialized from a Nix STORE PATH (a sops-decrypted or
#                     CI-provisioned file under /nix/store), never from the
#                     ambient environment — so eval stays pure.
#   "athens-goproxy"— route ALL module fetches (public + private) through a
#                     self-hosted Athens GOPROXY URL. Athens holds the private
#                     modules and proxies the public ones, so the vendor FOD
#                     needs no per-host git credential at all — `GOPROXY` points
#                     at the Athens base URL and `GONOSUMCHECK` covers the
#                     private prefixes. Best for fleets that already run Athens.
#
# Both shapes leave the public `buildGoModule` contract intact: pass the same
# `pname`/`version`/`src`/`vendorHash`/`subPackages` you would to `mkGoTool`,
# plus one `privateFetch = { … }` block. Everything else (ldflags, the from-
# source goToolchain version assert, meta.mainProgram) mirrors `tool.nix`.
#
# Usage (deploy-token):
#   substrateLib.mkGoPrivateModule {
#     pname = "tundra-foo"; version = "0.1.0"; src = ./.;
#     vendorHash = "sha256-…";          # pins the private+public closure
#     privateFetch = {
#       kind = "deploy-token";
#       privatePrefixes = [ "github.com/pleme-io" ];
#       host = "github.com";
#       # Store path to a 0600 file holding `x-access-token:<deploy-token>`
#       # (or `<user>:<token>`). Provisioned by sops/CI INTO the store —
#       # NEVER read from $GITHUB_TOKEN at eval time.
#       credentialFile = "/nix/store/…-deploy-token";
#     };
#   };
#
# Usage (athens-goproxy):
#   substrateLib.mkGoPrivateModule {
#     pname = "tundra-foo"; version = "0.1.0"; src = ./.;
#     vendorHash = "sha256-…";
#     privateFetch = {
#       kind = "athens-goproxy";
#       privatePrefixes = [ "github.com/pleme-io" ];
#       goproxy = "https://athens.internal.pleme.io";
#     };
#   };
{
  # Build a Go binary whose dependency closure includes PRIVATE org modules,
  # hermetically + reproducibly + without `--impure`.
  mkGoPrivateModule = pkgs: {
    pname,
    version,
    src,
    # vendorHash pins the COMBINED public+private dependency closure. Required
    # and non-null here: a private-dep module by definition has external deps,
    # so the FOD must be hash-pinned (unlike a dep-free in-tree module).
    vendorHash,
    privateFetch,
    subPackages ? null,
    ldflags ? null,
    versionLdflags ? {},
    tags ? [],
    modRoot ? null,
    doCheck ? false,
    extraBuildInputs ? [],
    extraPostInstall ? "",
    extraAttrs ? {},
    description ? "${pname} — pleme-io substrate-built Go binary (private deps)",
    homepage ? null,
    license ? pkgs.lib.licenses.mit,
    platforms ? pkgs.lib.platforms.all,
  }: let
    lib = pkgs.lib;
    check = import ../../types/assertions.nix;

    # ── Typed validation of the privateFetch block ────────────────────
    fetchKind = privateFetch.kind or null;
    privatePrefixes = privateFetch.privatePrefixes or [];
    _checks = check.all [
      (check.nonEmptyStr "pname" pname)
      (check.nonEmptyStr "version" version)
      (check.nonEmptyStr "vendorHash" vendorHash)
      (check.attrs "privateFetch" privateFetch)
      (check.enum "privateFetch.kind" [ "deploy-token" "athens-goproxy" ] fetchKind)
      (check.listOfStr "privateFetch.privatePrefixes" privatePrefixes)
      (check.list "tags" tags)
      (check.bool "doCheck" doCheck)
      (check.list "extraBuildInputs" extraBuildInputs)
      (check.str "extraPostInstall" extraPostInstall)
      (check.attrs "extraAttrs" extraAttrs)
      (check.attrs "versionLdflags" versionLdflags)
    ];
    # Fail-closed: a private-dep build with no declared private prefix is almost
    # certainly a misconfiguration (the public proxy already handles public
    # deps). Reject at eval time rather than fetch a closure that silently drops
    # the private module.
    _prefixCheck =
      if privatePrefixes == []
      then throw ("substrate.mkGoPrivateModule: ${pname} declares privateFetch "
        + "but `privatePrefixes` is empty. List the private module prefixes "
        + "(e.g. [ \"github.com/pleme-io\" ]) so GOPRIVATE/GONOSUMCHECK exempt them.")
      else null;

    goprivate = lib.concatStringsSep "," privatePrefixes;

    # ── GIT_CONFIG injection for the deploy-token shape ────────────────
    # `insteadOf` rewrites the HTTPS remote so git fetches the private host with
    # the deploy token. The token is read from a STORE PATH at FOD build time
    # (the FOD is allowed network + filesystem reads of its own inputs), not
    # from the ambient env — eval stays pure. We write a git credential helper
    # rather than embedding the token in a URL so it never appears in process
    # args / store paths.
    deployTokenPreBuild = let
      host = privateFetch.host or "github.com";
      # credentialFile is a store-path input — accept a string path, a Nix path,
      # or a derivation (e.g. `pkgs.writeText`/sops output). Coerced to its
      # store-path string here so the FOD reads the token bytes purely from a
      # realised input (no ambient env, no --impure).
      credentialFile = "${check.derivation "privateFetch.credentialFile"
        (privateFetch.credentialFile or (throw
          ("substrate.mkGoPrivateModule: ${pname} privateFetch.kind=deploy-token "
          + "requires `credentialFile` (a /nix/store path to a 0600 file holding "
          + "`x-access-token:<token>`).")))}";
    in ''
      # Hermetic per-host git credential for the private remote. The token
      # bytes come from a store input ($credentialFile), so the FOD output is
      # a pure function of (src, go.sum, token-content) — and since the token
      # is read-only deploy-scoped, ANY valid token yields the SAME module
      # bytes (pinned by vendorHash). No ambient env, no --impure.
      export GIT_CONFIG_COUNT=2
      export GIT_CONFIG_KEY_0="url.https://$(cat ${credentialFile})@${host}/.insteadOf"
      export GIT_CONFIG_VALUE_0="https://${host}/"
      export GIT_CONFIG_KEY_1="url.https://$(cat ${credentialFile})@${host}/.insteadOf"
      export GIT_CONFIG_VALUE_1="git@${host}:"
      export GOFLAGS="-mod=mod"
    '';

    # ── GOPROXY routing for the Athens shape ───────────────────────────
    # All fetches (public + private) flow through the Athens base URL; Athens
    # authenticates to the private remotes itself, so the vendor FOD needs no
    # per-host git credential. `direct` fallback keeps public-only builds working
    # if Athens is unreachable for a public module.
    athensPreBuild = let
      goproxy = check.nonEmptyStr "privateFetch.goproxy"
        (privateFetch.goproxy or (throw
          ("substrate.mkGoPrivateModule: ${pname} privateFetch.kind=athens-goproxy "
          + "requires `goproxy` (the Athens base URL).")));
    in ''
      export GOPROXY="${goproxy},direct"
    '';

    # Common env for both shapes: exempt the private prefixes from the public
    # sum DB + checksum proxy (GONOSUMCHECK / GONOSUMDB are honored by the Go
    # toolchain; GOPRIVATE is the umbrella that implies both GONOSUMDB+GONOSUMCHECK).
    commonPreBuild = ''
      export GOPRIVATE="${goprivate}"
      export GONOSUMCHECK="${goprivate}"
      export GONOSUMDB="${goprivate}"
      export GOFLAGS="''${GOFLAGS:-}"
    '';

    vendorPreBuild =
      commonPreBuild
      + (if fetchKind == "deploy-token" then deployTokenPreBuild else athensPreBuild);

    # ── Mirror tool.nix: ldflags + from-source goToolchain version assert ──
    effectiveLdflags =
      if ldflags != null then ldflags
      else if versionLdflags != {} then
        [ "-s" "-w" ] ++ (lib.mapAttrsToList (key: val: "-X ${key}=${val}") versionLdflags)
      else [ "-s" "-w" ];

    goVersionAssert =
      let
        gomodPath = "${src}/${lib.optionalString (modRoot != null) (modRoot + "/")}go.mod";
        read = builtins.tryEval (builtins.readFile gomodPath);
        goLine =
          if read.success
          then lib.findFirst (l: lib.hasPrefix "go " l) null (lib.splitString "\n" read.value)
          else null;
        req =
          if goLine == null then null
          else lib.head (lib.splitString " " (lib.removePrefix "go " goLine));
        tool = pkgs.go.version;
      in
        if req != null && builtins.compareVersions req tool > 0
        then throw ("substrate.mkGoPrivateModule: ${pname} go.mod requires 'go ${req}' but the "
          + "substrate goToolchain is ${tool}. Pin go.mod to the minor only "
          + "('go ${lib.versions.majorMinor tool}'), never a patch ahead of the builder.")
        else null;

  in builtins.seq goVersionAssert (builtins.seq _prefixCheck (pkgs.buildGoModule ({
    inherit pname version src doCheck tags vendorHash;

    # The vendor FOD env. buildGoModule threads `env` + the goModules
    # derivation's prebuild; we inject the private-fetch routing so the FOD's
    # `go mod download` reaches the private host (deploy-token) or Athens.
    # `proxyVendor = true` makes the FOD a module-proxy fetch (the shape Athens
    # speaks); for the deploy-token shape git `insteadOf` handles `direct`.
    proxyVendor = fetchKind == "athens-goproxy";

    # Apply the private-fetch routing to BOTH the vendor FOD (overridden below)
    # and the main build. `overrideModAttrs` is buildGoModule's typed seam for
    # influencing the goModules (vendor) FOD without breaking content-addressing.
    overrideModAttrs = _old: {
      preBuild = vendorPreBuild;
      # The deploy-token credentialFile (when present) is a store input of the
      # FOD, so it is realised before the FOD builds — making the fetch a pure
      # function of its inputs.
      nativeBuildInputs = (_old.nativeBuildInputs or []) ++ [ pkgs.git pkgs.cacert ];
    };

    nativeBuildInputs = extraBuildInputs;
    ldflags = effectiveLdflags;
    postInstall = extraPostInstall;

    meta = {
      inherit description license platforms;
      mainProgram = pname;
    } // lib.optionalAttrs (homepage != null) { inherit homepage; };
  }
  // lib.optionalAttrs (subPackages != null) { inherit subPackages; }
  // lib.optionalAttrs (modRoot != null) { inherit modRoot; }
  // extraAttrs)));

  # Overlay form — provide multiple private-dep Go binaries on `final`.
  mkGoPrivateModuleOverlay = defs: final: prev: let
    self = import ./private-module.nix;
  in builtins.mapAttrs (_name: def: self.mkGoPrivateModule final def) defs;
}
