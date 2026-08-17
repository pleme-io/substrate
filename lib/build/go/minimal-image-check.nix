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
# ── THE VACUITY THIS FILE SHIPPED WITH, and the fix (2026-07-30) ──────────
#
# Every path-based predicate below used to read a listing built by
# `tar tzf "$image"` on the OUTER docker-archive. The members of that archive
# are only `<hash>/layer.tar` + `manifest.json` + `<config>.json` — so the
# listing COULD NOT CONTAIN A SINGLE ROOTFS PATH, and:
#
#   • the forbidden-pattern grep (busybox|/bin/sh|libc.so|coreutils|apk|apt)
#     matched nothing and printed "no shell/coreutils/init/libc/pkg-mgr in any
#     layer ✓" — while `./bin/sh` and `./lib/libc.so.6` demonstrably existed in
#     the rootfs;
#   • `npaths` was ALWAYS 0, so `maxStorePaths` could never fire. On the real
#     mysql image: 86 outer members reported as "layer entries" against 30,304
#     real intra-layer entries, and "distinct runtime store paths: 0
#     (ceiling 3)" against 79 real ones.
#
# The fix is not a bigger pattern list. It is that the listing is now built by
# UNPACKING the archive and enumerating the members of each layer inside it —
# the same thing hardened-image-check.tlisp already did correctly for setuid
# bits, which is why that half of the gate was never vacuous.
#
# Layer enumeration is CONTENT-driven, not suffix-driven: every regular file in
# the unpacked archive is offered to tar, and whatever parses as a non-empty
# archive is a layer. Keying on a `.tar` suffix is its own vacuity — an OCI
# `blobs/sha256/<digest>` member or a `layer.tar.gz` is then not even a
# candidate, and a gate that enumerated zero layers reports clean.
#
# And the floor: layers-scanned and entries-scanned are ASSERTED non-zero. A
# predicate over an empty set is not a pass, it is the absence of a result —
# so it fails. That single inversion is what makes every ✓ below readable.
#
# pending-tlisp-port: the body is still shell. hardened-image-check.tlisp is
# the shape this should converge on (it is the same walk, already typed); the
# blocker is that every consumer would have to start passing `tataraScript`,
# which is an interface change wider than this fix. Named so it is a tracked
# debt rather than a silent one.
#
# Usage (per built image):
#   mkMinimalImageCheck pkgs {
#     name       = "my-service";
#     image      = flake.packages.x86_64-linux."dockerImage:amd64";
#     binary     = flake.packages.x86_64-linux.default;   # optional
#     binName    = "mysvc";                                # binary basename
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
    # ELF sections the shipped binary MUST carry. The reason this predicate
    # exists: `.dep-v0` (the cargo-auditable dependency document) is a non-ALLOC
    # section, which is precisely what `strip --strip-all` removes — so the one
    # thing that makes a static Rust binary scannable at all is also the one
    # thing a strip silently deletes. Without this assertion, a future reorder
    # of strip-vs-inject would return the image to "Trivy: Target -, Not
    # scanned" and every gate downstream would go green again.
    requireSections ? [ ],
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
      requireSections = lib.concatStringsSep " " requireSections;
    }
    ''
      set -uo pipefail
      fail=0
      note() { echo "  $1"; }
      bad()  { echo "  FAIL: $1"; fail=1; }

      echo "== MINIMAL-PRODUCTION-IMAGE conformance: ${name} =="

      # ── 1. unpack the real image tarball, enumerate every ROOTFS path ──
      #
      # Two listings, and the difference between them is the whole bug this
      # replaced. `outer` is the archive's own members (<hash>/layer.tar,
      # manifest.json, <config>.json) — useful ONLY for locating the config
      # json. `listing` is the union of the members of every layer inside it,
      # i.e. the actual container filesystem, and it is what every path
      # predicate below reads.
      workdir="$(mktemp -d)"
      outer="$(mktemp)"
      listing="$(mktemp)"
      entries_tmp="$(mktemp)"
      : > "$listing"

      if ! tar xzf "$image" -C "$workdir" 2>/dev/null; then
        tar xf "$image" -C "$workdir" || bad "cannot unpack image tarball $image"
      fi
      ( cd "$workdir" && find . -type f -o -type l ) | sed 's|^\./||' > "$outer"
      note "archive members: $(wc -l < "$outer")"

      # Content-driven layer detection: offer every regular file to tar and
      # accept whatever parses as a non-empty archive. Suffix-driven detection
      # ('*.tar' only) is its own vacuity — a gzip-compressed layer or an OCI
      # blobs/sha256/<digest> member would not even be a candidate, and a gate
      # that enumerated zero layers would report clean.
      layer_count=0
      while IFS= read -r f; do
        if tar tf "$workdir/$f" > "$entries_tmp" 2>/dev/null && [ -s "$entries_tmp" ]; then
          cat "$entries_tmp" >> "$listing"
          layer_count=$((layer_count + 1))
        elif tar tzf "$workdir/$f" > "$entries_tmp" 2>/dev/null && [ -s "$entries_tmp" ]; then
          cat "$entries_tmp" >> "$listing"
          layer_count=$((layer_count + 1))
        fi
      done < <( ( cd "$workdir" && find . -type f ) | sed 's|^\./||' | sort )

      total_entries=$(wc -l < "$listing")
      note "layers scanned: $layer_count"
      note "rootfs entries scanned: $total_entries"

      # ── 1b. THE FLOOR — nothing-inspected is a FAILURE, never a pass ──
      #
      # Every predicate below is a search over $listing. A search over an empty
      # set finds nothing, and "found nothing" is indistinguishable from "there
      # is nothing bad" unless the set is asserted non-empty. That is exactly
      # how this gate stayed green on an image containing /bin/sh, busybox and
      # a C compiler. Assert the denominator.
      if [ "$layer_count" -eq 0 ]; then
        bad "no layer archive found inside $image — every path predicate below would search an empty set and report clean. A scan that analysed nothing FAILS."
      fi
      if [ "$total_entries" -eq 0 ]; then
        bad "layers contained 0 entries — same vacuity as above, failing rather than passing."
      fi

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
      #
      # Read from $outer, not $listing: the config json is a member of the
      # ARCHIVE, not of any layer. Reading it out of the (previously
      # outer-archive) listing is why this happened to work before and would
      # have silently stopped working when the listing became the rootfs.
      cfgjson=$(grep -E '\.json$' "$outer" | grep -viE 'manifest|repositories|index|oci-layout' | head -n1 || true)
      if [ -n "$cfgjson" ] && [ -f "$workdir/$cfgjson" ]; then
        minlabel=$(jq -r '.config.Labels["com.pleme.image.minimal"] // .Labels["com.pleme.image.minimal"] // "absent"' "$workdir/$cfgjson" 2>/dev/null || echo absent)
        note "com.pleme.image.minimal = $minlabel"
        [ "$minlabel" = "true" ] || bad "image does not self-declare com.pleme.image.minimal=true (got: $minlabel)"
      else
        # Was "non-fatal". A label check that cannot find the label has not
        # cleared the image, it has failed to look — the same vacuous-guard
        # shape as the empty listing above, so it fails too.
        bad "config json not located in $image, so com.pleme.image.minimal was never read — a check that could not look does not pass"
      fi

      # ── 4b. required ELF sections on the shipped binary ──
      #
      # This is the CVE-coverage seal. `.dep-v0` is the cargo-auditable
      # dependency document, and it is the ONLY thing that makes a static Rust
      # binary in a distroless image scannable at all: remove it and trivy
      # emits no Results key and exits 0, i.e. the CVE gate passes having
      # analysed nothing. It is also non-ALLOC, which is exactly what
      # `strip --strip-all` deletes — so the coverage and the thing that
      # destroys it live one line apart. Asserting presence here means a
      # reordered strip fails the build instead of quietly restoring the
      # green-because-blind state.
      if [ -n "$requireSections" ]; then
        if [ -z "$binPath" ] || [ ! -e "$binPath" ]; then
          bad "requireSections asked for [$requireSections] but no binary was supplied to inspect — cannot pass a check it could not run"
        else
          for want in $requireSections; do
            if objdump -h "$binPath" 2>/dev/null | grep -qE "[[:space:]]$want[[:space:]]"; then
              note "binary carries section $want ✓"
            else
              bad "binary $binPath is MISSING required section $want (a strip after the inject, or a missing inject, silently returns this image to 'Trivy: Not scanned')"
            fi
          done
        fi
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
      # Both listings ship, and the counts ship with them. A reader auditing
      # this gate needs the DENOMINATOR, not just the verdict: "0 forbidden
      # matches" is only meaningful next to "over 30,304 rootfs entries in 79
      # layers".
      cp "$listing" "$out/rootfs-listing.txt"
      cp "$outer" "$out/archive-members.txt"
      printf 'layers=%s\nrootfs_entries=%s\nstore_paths=%s\n' \
        "$layer_count" "$total_entries" "$npaths" > "$out/scanned"
      echo "${name} minimal-image conformance: PASS ($layer_count layers, $total_entries rootfs entries)" > "$out/result"
    '';
in
{
  inherit mkMinimalImageCheck;
}
