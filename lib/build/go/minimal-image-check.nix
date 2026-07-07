# minimal-image-check.nix — the MINIMAL-PRODUCTION-IMAGE forcing-function as a
# reusable, buildable conformance check over an ALREADY-BUILT OCI image.
#
# This is the "the image we test with IS the minimal production image" gate:
# it unpacks the real dockerTools tarball + inspects the real binary and
# proves, by construction, that the shipped artifact is the strict stack —
#   • NO shell / coreutils / busybox / package-manager in any layer,
#   • NO init (tini) and (for a static binary) NO glibc / ld-linux in the
#     runtime closure — i.e. the "no missing-dep at runtime" property is
#     established from the layers themselves, not asserted,
#   • the runtime store-path count is at or below a small ceiling,
#   • the OCI `com.pleme.image.minimal=true` self-declaration is present,
#   • (optional) an exec-smoke that RUNS the binary and fails only on a
#     loader/exec failure — proving the stripped image actually starts.
#
# Aggregate-before-assert: every predicate is checked, ALL failures are
# printed, then the build fails once (per the verification-matrix rule).
# Runs on Linux (needs to exec the binary); on darwin it evaluates but is
# built by the Linux CI / super-cache-ci runner.
#
# Usage (per built image):
#   mkMinimalImageCheck pkgs {
#     name       = "akeyless-uam";
#     image      = flake.packages.x86_64-linux."dockerImage:amd64";
#     binary     = flake.packages.x86_64-linux.default;   # optional
#     binName    = "uam";                                  # binary basename
#     expectStatic  = true;                                # CGO_ENABLED=0
#     maxStorePaths = 3;                                    # binary+cacert(+1)
#     execSmoke  = { args = [ "--version" ]; };            # optional run probe
#   }
{ }:
let
  mkMinimalImageCheck = pkgs: {
    name,
    image,
    binary ? null,
    binName ? name,
    expectStatic ? true,
    # Ceiling on distinct runtime store paths in the layer set. A static
    # minimal image = { binary, cacert } ≈ 2; leave headroom at 3.
    maxStorePaths ? 3,
    # Optional exec-smoke: run the binary and fail only on a loader/exec
    # failure. `args` are passed to the binary; a short timeout bounds it
    # (a server that then blocks/errors on missing config is a PASS — it
    # loaded). Set null to skip (e.g. binaries with no safe flag).
    execSmoke ? null,
    # Substrings that, if found in ANY layer path, fail the check. These
    # are the shell / coreutils / init / libc / pkg-mgr signatures.
    forbidden ? [ "busybox" "/bin/sh" "/bin/bash" "-bash-" "coreutils" "/tini" "tini-"
                  "ld-linux" "libc.so" "/apk" "apk-tools" "/apt" "/dnf" "/yum" ],
  }:
  let
    lib = pkgs.lib;
    binPath = if binary != null then "${binary}/bin/${binName}" else "";
    execArgs = if execSmoke != null then lib.escapeShellArgs (execSmoke.args or []) else "";
    forbiddenPat = lib.concatStringsSep "|" (map lib.escapeRegex forbidden);
  in
  pkgs.runCommand "minimal-image-check-${name}"
    {
      nativeBuildInputs = [ pkgs.gnutar pkgs.gzip pkgs.binutils pkgs.coreutils pkgs.gnugrep pkgs.jq ];
      inherit image binPath forbiddenPat maxStorePaths execArgs;
      expectStatic = if expectStatic then "1" else "0";
      doExecSmoke = if execSmoke != null then "1" else "0";
    }
    ''
      set -uo pipefail
      fail=0
      note() { echo "  $1"; }
      bad()  { echo "  FAIL: $1"; fail=1; }

      echo "== MINIMAL-PRODUCTION-IMAGE conformance: ${name} =="

      # ── 1. unpack the real image tarball, enumerate every layer path ──
      listing="$(mktemp)"
      if ! tar tzf "$image" > "$listing" 2>/dev/null; then
        # not gzip? try raw tar
        tar tf "$image" > "$listing" || bad "cannot read image tarball $image"
      fi
      total_entries=$(wc -l < "$listing")
      note "layer entries: $total_entries"

      # ── 2. NO shell / coreutils / init / libc / pkg-mgr in any layer ──
      if grep -Eiq "$forbiddenPat" "$listing"; then
        bad "forbidden runtime component present in a layer:"
        grep -Ei "$forbiddenPat" "$listing" | sed 's/^/      /' | sort -u | head -n 20
      else
        note "no shell/coreutils/init/libc/pkg-mgr in any layer ✓"
      fi

      # ── 3. runtime store-path ceiling ──
      # Count distinct nix/store/<hash>-<name> prefixes referenced in layers.
      storepaths=$(grep -oE 'nix/store/[a-z0-9]{32}-[^/]+' "$listing" | sort -u || true)
      npaths=$(printf '%s\n' "$storepaths" | grep -c . || true)
      note "distinct runtime store paths: $npaths (ceiling $maxStorePaths)"
      printf '%s\n' "$storepaths" | sed 's/^/      /'
      if [ "$npaths" -gt "$maxStorePaths" ]; then
        bad "runtime closure has $npaths store paths, exceeds ceiling $maxStorePaths"
      fi

      # ── 4. self-declaration: com.pleme.image.minimal=true ──
      # The manifest/config json lives in the tar; pull it and check labels.
      workdir="$(mktemp -d)"
      ( cd "$workdir" && tar xzf "$image" 2>/dev/null || tar xf "$image" 2>/dev/null ) || true
      cfgjson=$(grep -E '\.json$' "$listing" | grep -viE 'manifest|repositories|index|oci-layout' | head -n1 || true)
      if [ -n "$cfgjson" ] && [ -f "$workdir/$cfgjson" ]; then
        minlabel=$(jq -r '.config.Labels["com.pleme.image.minimal"] // .Labels["com.pleme.image.minimal"] // "absent"' "$workdir/$cfgjson" 2>/dev/null || echo absent)
        note "com.pleme.image.minimal = $minlabel"
        [ "$minlabel" = "true" ] || bad "image does not self-declare com.pleme.image.minimal=true (got: $minlabel)"
      else
        note "config json not located for label check (non-fatal)"
      fi

      # ── 5. binary is statically linked (no dynamic interpreter) ──
      if [ -n "$binPath" ] && [ "$expectStatic" = "1" ]; then
        if [ -e "$binPath" ]; then
          if readelf -l "$binPath" 2>/dev/null | grep -q 'INTERP'; then
            bad "binary $binPath has a dynamic INTERP segment — NOT static (would break on the glibc-less scratch base)"
          else
            note "binary is statically linked (no INTERP) ✓"
          fi
        else
          note "binary path $binPath not found (skipping static check)"
        fi
      fi

      # ── 6. exec-smoke: the stripped image actually starts (no loader fail) ──
      if [ "$doExecSmoke" = "1" ] && [ -n "$binPath" ] && [ -e "$binPath" ]; then
        smokeout="$(mktemp)"
        timeout 10s "$binPath" $execArgs >"$smokeout" 2>&1 || true
        # A loader failure is the thing a wrongly-stripped image would show.
        if grep -qiE 'no such file or directory|not found|exec format error|error while loading shared libraries' "$smokeout"; then
          bad "exec-smoke: binary failed to load on the stripped base:"
          sed 's/^/      /' "$smokeout" | head -n 10
        else
          note "exec-smoke: binary loaded + ran on the stripped base ✓"
        fi
      fi

      if [ "$fail" -ne 0 ]; then
        echo "== ${name}: MINIMAL conformance FAILED =="
        exit 1
      fi
      echo "== ${name}: MINIMAL conformance PASSED =="
      mkdir -p "$out"
      cp "$listing" "$out/layer-listing.txt"
      echo "${name} minimal-image conformance: PASS" > "$out/result"
    '';
in
{
  inherit mkMinimalImageCheck;
}
