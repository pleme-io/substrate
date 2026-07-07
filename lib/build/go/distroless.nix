# Minimal base contents for Go-service OCI images — the MINIMAL-PRODUCTION-IMAGE
# standard's base-selection primitive (see docs/MINIMAL-PRODUCTION-IMAGE.md).
#
# Standard mkGoDockerImage includes `busybox` for runtime shell access.
# For a production posture (FedRAMP-High / SR-3 / CM-7 least-functionality,
# and a clean CVE verdict by construction) we want zero shell + zero
# coreutils in the image — only the static Go binary can run, no
# curl/wget/sh for an attacker to fall back to.
#
# Two preset bases:
#   scratch  — cacert ONLY. THE minimal production base (industry
#              `distroless/static` / Wolfi-static equivalent). Correct for a
#              statically-linked (CGO_ENABLED=0) Go binary that handles its
#              own signals. Non-binary closure ≈ the cert bundle (~0.65 MB).
#   minimal  — cacert + tini (PID 1). Adds an init reaper — but tini is
#              DYNAMICALLY linked, so it silently drags the ENTIRE glibc
#              subtree (glibc + libidn2 + libunistring + libgcc) into a
#              container whose only real process is a static binary that
#              needs none of it. MEASURED cost: ~32.6 MB uncompressed +
#              4 OS packages (incl. glibc — the single largest container-CVE
#              generator) + tini itself. Use ONLY when the workload is
#              genuinely multi-process and needs zombie-reaping.
#
# Tier-honesty: earlier revisions of this file + docker.nix claimed the tini
# base was "~3 MB extra". Measured reality is ~37 MB extra because tini is
# dynamically linked against glibc. The doc was ~12× optimistic; corrected
# 2026-07-07 from the built-tarball measurement.
#
# A static Go binary needs NEITHER glibc NOR tini. Prefer `scratch`
# (the `minimal: true` default in docker.nix / service-flake.nix).
#
# Usage:
#   contents = mkDistrolessBase pkgs { withTini = false; }; # = scratch (MINIMAL)
#   contents = mkDistrolessBase pkgs { withTini = true; };  # = +tini (+glibc)
{
  mkDistrolessBase = pkgs: {
    withCacert ? true,
    withTini ? true,
  }: with pkgs;
    (if withCacert then [ cacert ] else [])
    ++ (if withTini then [ tini ] else []);

  # Aliases for documentation + direct consumption.

  # scratch — THE minimal production base. cacert only; no init, no libc,
  # no shell. For a static binary this is the whole non-binary closure.
  scratchBase = pkgs: (import ./distroless.nix).mkDistrolessBase pkgs {
    withTini = false; withCacert = true;
  };

  # minimal — cacert + tini. Init reaper for genuinely multi-process
  # containers; drags glibc (~32.6 MB / 4 pkgs). NOT the default.
  minimalBase = pkgs: (import ./distroless.nix).mkDistrolessBase pkgs {
    withTini = true; withCacert = true;
  };
}
