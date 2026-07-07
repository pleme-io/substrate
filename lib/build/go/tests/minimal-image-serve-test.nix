# minimal-image-serve-test.nix — the end-to-end "we test with the minimal
# production image" gate: build the smoke fixture through the SAME minimal
# builder the fleet ships services with, then (a) prove the image is the
# strict stack (mkMinimalImageCheck: no shell/coreutils/init/libc, static
# binary, self-declared) and (b) actually START it and curl /health for a
# 200 — a live proof that the stripped image serves with no missing runtime
# dependency.
#
# Linux-only (it execs a linux binary + binds a socket); wired into substrate
# `checks.{x86_64,aarch64}-linux.go-minimal-image-serves` so super-cache-ci /
# CI builds AND runs it. On darwin it evaluates but is not built.
{ pkgs }:
let
  goDocker = import ../docker.nix;
  minimalCheck = (import ../minimal-image-check.nix { }).mkMinimalImageCheck;

  # The fixture binary — CGO_ENABLED=0 static, built with the static Go tags,
  # exactly like a production minimal service.
  binary = pkgs.buildGoModule {
    pname = "smoke";
    version = "0.0.0";
    src = ./fixtures/smoke;
    vendorHash = null;                       # stdlib-only, no deps to vendor
    env = { CGO_ENABLED = "0"; };
    tags = [ "timetzdata" "netgo" "osusergo" ];
    meta.mainProgram = "smoke";
  };

  # The minimal (scratch-base) OCI image around it.
  image = goDocker.mkGoDockerImage pkgs {
    name = "smoke";
    inherit binary;
    minimal = true;
    ports = { http = 8080; };
  };

  # Static + no-shell + closure conformance over the real image tarball.
  conformance = minimalCheck pkgs {
    name = "smoke";
    inherit image binary;
    binName = "smoke";
    expectStatic = true;
    maxStorePaths = 3;                        # binary + cacert (+headroom)
    # No exec-smoke here — the SERVE step below is the live run.
  };
in
pkgs.runCommand "go-minimal-image-serves"
  {
    nativeBuildInputs = [ pkgs.curl pkgs.coreutils ];
    inherit binary conformance;
  }
  ''
    set -uo pipefail
    # Force the strict-stack conformance to have built (referencing it makes
    # this derivation depend on it — a conformance failure fails us too).
    echo "conformance: $(cat "$conformance/result")"

    port=18080
    PORT="$port" "$binary/bin/smoke" &
    pid=$!
    trap 'kill "$pid" 2>/dev/null || true' EXIT

    # Wait for readiness (the static binary must load on the sandbox with no
    # libc/loader present in its own closure beyond what it statically needs).
    ok=0
    for _ in $(seq 1 50); do
      if curl -sf "http://127.0.0.1:$port/health" >/dev/null 2>&1; then ok=1; break; fi
      sleep 0.2
    done
    if [ "$ok" -ne 1 ]; then
      echo "FAIL: minimal-image server never became ready on :$port"
      exit 1
    fi

    code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/health" || echo 000)
    if [ "$code" != "200" ]; then
      echo "FAIL: /health returned $code (expected 200)"
      exit 1
    fi

    echo "MINIMAL image serves: static scratch-base binary started + /health=200 ✓"
    mkdir -p "$out"
    echo "go-minimal-image serve: PASS (/health=200)" > "$out/result"
  ''
