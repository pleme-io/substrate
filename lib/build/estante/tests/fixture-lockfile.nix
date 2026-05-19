# fixture-lockfile.nix — synthetic shellpkg.lock.nix shape for
# lockfile-loader-test.nix. Mirrors what `estante export --format
# nix` emits, but without host-specific paths so the fixture stays
# portable across machines.
{
  schemaVersion = 1;
  packages = [
    {
      name = "alpha";
      source = "github:org/alpha";
      rev = "abcdef0123456789abcdef0123456789abcdef01";
      narHash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
      blake3 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
      materializedPath = "/nix/store/aaaaaaaa-alpha-1.0.0/";
      entrypoint = "rc.lisp";
      placement = "nix";
    }
    {
      name = "beta";
      source = "local:/abs/path/to/beta";
      rev = "deadbeefcafef00d";
      blake3 = "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210";
      materializedPath = "/home/op/.cache/estante/store/beta-deadbeefcafef00d/";
      entrypoint = "rc.lisp";
      placement = "cache";
    }
  ];
}
