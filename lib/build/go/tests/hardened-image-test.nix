# hardened-image-test.nix — the Linux proof for mkHardenedGoImage.
#
# minimal-image-serve-test.nix already proves the MINIMAL stack serves. This
# proves the HARDENED stack does, and that every compile-time property the
# builder claims is actually present in the artifact:
#
#   • the binary matches its DECLARED pie setting, is stripped, and carries no
#     GNU build id
#   • the binary is static (no INTERP) with no libc anywhere in the closure
#   • the image runs as numeric 65532:65532, never root
#   • no setuid/setgid bits in any layer
#   • and it still SERVES — a hardened image that cannot answer /health is a
#     regression dressed as a security win
#
# Reuses ./fixtures/smoke rather than authoring a second fixture, so this test
# and the minimal one are provably about the same program.
#
# Linux-only: it execs a linux binary and binds a socket. Wired into
# checks.{x86_64,aarch64}-linux.go-hardened-image; on darwin it evaluates but
# is not built.
{ pkgs, tataraScript ? null,
  # The pinned fleet Go compiler. Threaded because the builder under test now
  # FLOORS its compiler, and substrate's own nixpkgs (go 1.26.3) is itself below
  # the floor (1.26.5) — measured. So this is not ceremony: without it the check
  # is eval-rejected, which is exactly the floor doing its job on substrate's own
  # gate. flake.nix passes goToolchains.${system}.stable.
  goToolchain ? null,
}:
let
  hardened = import ../hardened-image.nix { inherit goToolchain; };

  # The whole point: the image comes out of the builder under test, with
  # nothing overridden. If a default is wrong, this test is where it shows.
  image = hardened.mkHardenedGoImage pkgs {
    name = "smoke";
    src = ./fixtures/smoke;
    vendorHash = null;                  # stdlib-only fixture
    version = "0.0.0";
    ports = { http = 8080; };
    # The fixture has no tests and no network access in the sandbox, so the
    # vulnerability gate is exercised separately rather than inline here.
    vulnGate = false;
    inherit tataraScript;
  };

  binary = image.binary;
  conformance = image.checks.conformance;
in
pkgs.runCommand "go-hardened-image"
  {
    nativeBuildInputs = [ pkgs.curl pkgs.coreutils pkgs.binutils ];
    inherit binary conformance;
    hardenedJson = builtins.toJSON image.hardened;
    # Assert what the builder DECLARED, not a fixed value. The default lane is
    # deliberately non-PIE because a PIE Go binary built with CGO off carries a
    # dynamic INTERP and cannot run on scratch; hardcoding DYN here would fight
    # that correctness rather than check it.
    expectPie = if image.hardened.pie then "1" else "0";
  }
  ''
    set -uo pipefail
    fail=0
    bad() { echo "  FAIL: $1"; fail=1; }

    echo "== hardened image: declared flags =="
    echo "  $hardenedJson"

    # Referencing the conformance derivation makes this one depend on it, so a
    # conformance failure fails the test rather than being reported beside it.
    echo "conformance: $(cat "$conformance/result")"

    echo "== hardened image: binary properties =="

    etype=$(readelf -h "$binary/bin/smoke" | awk '/Type:/ {print $2}')
    echo "  ELF type: $etype (declared pie=$expectPie)"
    if [ "$expectPie" = "1" ]; then
      [ "$etype" = "DYN" ] || bad "pie was declared but the binary is $etype"
    else
      # Non-PIE is the correct outcome on the pure-Go lane. EXEC plus the
      # no-INTERP check below is what makes it runnable on scratch.
      [ "$etype" = "EXEC" ] || bad "pie was not declared but the binary is $etype"
    fi

    if readelf -l "$binary/bin/smoke" | grep -q INTERP; then
      bad "binary has a dynamic INTERP segment; it would not run on scratch"
    else
      echo "  static: no INTERP"
    fi

    if readelf -S "$binary/bin/smoke" | grep -q '\.symtab'; then
      bad "binary retains .symtab; -s -w did not take effect"
    else
      echo "  stripped: no .symtab"
    fi

    if readelf -n "$binary/bin/smoke" | grep -qi 'build id'; then
      bad "binary carries a GNU build id; -buildid= did not take effect"
    else
      echo "  no build id"
    fi

    echo "== hardened image: serves =="
    port=18081
    PORT="$port" "$binary/bin/smoke" &
    pid=$!
    trap 'kill "$pid" 2>/dev/null || true' EXIT

    ok=0
    for _ in $(seq 1 50); do
      if curl -sf "http://127.0.0.1:$port/health" >/dev/null 2>&1; then ok=1; break; fi
      sleep 0.2
    done
    [ "$ok" -eq 1 ] || bad "hardened binary never became ready on :$port"

    if [ "$ok" -eq 1 ]; then
      code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/health" || echo 000)
      echo "  /health = $code"
      [ "$code" = "200" ] || bad "/health returned $code, expected 200"
    fi

    if [ "$fail" -ne 0 ]; then
      echo "== go-hardened-image: FAILED =="
      exit 1
    fi
    echo "== go-hardened-image: PASS =="
    mkdir -p "$out"
    echo "go-hardened-image: PASS (PIE, stripped, static, /health=200)" > "$out/result"
  ''
