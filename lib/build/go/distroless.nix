# Minimal "distroless" base for Go-service OCI images.
#
# Standard mkGoDockerImage includes `busybox` for runtime shell access.
# For FedRAMP-High / SR-3 / CM-7 (least functionality) postures, we want
# zero shell + zero coreutils in the image — only the static Go binary
# can run, no curl/wget/sh for an attacker to fall back to.
#
# Two preset bases:
#   minimal  — cacert + tini (PID 1) only. Use for static Go binaries
#              that need TLS + signal forwarding. ~3MB extra.
#   scratch  — cacert only. For static binaries that handle signals
#              themselves. ~1MB extra.
#
# Usage:
#   contents = mkDistrolessBase pkgs { withTini = true; };  # = minimal
#   contents = mkDistrolessBase pkgs { withTini = false; }; # = scratch
{
  mkDistrolessBase = pkgs: {
    withCacert ? true,
    withTini ? true,
  }: with pkgs;
    (if withCacert then [ cacert ] else [])
    ++ (if withTini then [ tini ] else []);

  # Aliases for documentation.
  minimalBase = pkgs: (import ./distroless.nix).mkDistrolessBase pkgs {
    withTini = true; withCacert = true;
  };

  scratchBase = pkgs: (import ./distroless.nix).mkDistrolessBase pkgs {
    withTini = false; withCacert = true;
  };
}
