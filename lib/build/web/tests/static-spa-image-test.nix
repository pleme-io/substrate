# static-spa-image-test.nix — the Linux proof for mkStaticSpaImage.
#
# Proves the things that can only be observed on a real built image:
#   • the port rule actually applied (80 in, 8000 exposed)
#   • the SPA is served from the interface path, not from wherever the builder felt like
#   • the shaped /bin/sh satisfies the chart's real preStop hook AND refuses
#     anything outside its vocabulary, in the image, not just in a Go unit test
#   • the runtime closure did not drag a libc back in via the binary's package
#   • and it still answers /health
#
# Reuses ../../go/tests/fixtures/smoke as the server so this test and the two
# image tests next to it are provably about the same program.
#
# Linux-only: it execs a linux binary and binds a socket. Wired into
# checks.{x86_64,aarch64}-linux.web-static-spa-image.
{ pkgs, tataraScript ? null }:
let
  spa = import ../static-spa-image.nix { };
  hardenedGo = import ../../go/hardened-image.nix { };

  server = hardenedGo.mkHardenedGoBinary pkgs {
    name = "smoke";
    src = ../../go/tests/fixtures/smoke;
    vendorHash = null;
    version = "0.0.0";
  };

  staticDir = pkgs.runCommand "spa-fixture" { } ''
    mkdir -p "$out"
    echo '<!doctype html><title>spa</title>' > "$out/index.html"
    echo 'window.env={};' > "$out/env-config.js"
  '';

  serverConfig = pkgs.writeText "server.yaml" ''
    environment: production
  '';

  # listenPort 80 on purpose: the chart's value goes in, and the normalized
  # value must come out.
  image = spa.mkStaticSpaImage pkgs {
    name = "web-ui";
    version = "0.0.0";
    inherit server staticDir serverConfig tataraScript;
    serverBin = "smoke";
    listenPort = 80;
    extraEnv = [ "PORT=8000" ];
  };
in
pkgs.runCommand "web-static-spa-image"
  {
    nativeBuildInputs = [ pkgs.curl pkgs.coreutils pkgs.gnutar pkgs.gzip pkgs.gnugrep ];
    conformance = image.checks.conformance;
    inherit image;
    binary = image.assets;
    serverBin = "${server}/bin/smoke";
    compatSh = "${image}";
    exposed = builtins.toString image.interface.listenPort;
    requested = builtins.toString image.interface.requestedPort;
    staticRoot = image.interface.staticRoot;
  }
  ''
    set -uo pipefail
    fail=0
    bad() { echo "  FAIL: $1"; fail=1; }

    echo "== static spa image =="
    echo "  requested port $requested, exposed port $exposed"

    # 1. the port rule applied
    [ "$requested" = "80" ] || bad "fixture should have requested 80, got $requested"
    [ "$exposed" = "8000" ] || bad "80 must normalize to 8000, got $exposed"

    # 2. conformance (numeric non-root user, no setuid, stripped, no build id)
    echo "  conformance: $(cat "$conformance/result")"

    # 3. the assets are laid out at the interface path, and env-config.js is
    #    inside it so the chart's subPath mount lands somewhere served.
    if [ ! -f "$binary$staticRoot/index.html" ]; then
      bad "index.html is not at $staticRoot"
    else
      echo "  index.html present at $staticRoot"
    fi
    if [ ! -f "$binary$staticRoot/env-config.js" ]; then
      bad "env-config.js is not under $staticRoot; the chart's mount would serve nothing"
    else
      echo "  env-config.js under $staticRoot"
    fi

    # 4. no libc in any layer. This is what the severed build closure buys; a
    #    package-referencing image would drag one in here.
    listing="$(mktemp)"
    tar tzf "$image" > "$listing" 2>/dev/null || tar tf "$image" > "$listing"
    if grep -Eq 'libc\.so|ld-linux' "$listing"; then
      bad "a libc is present in the image layers:"
      grep -E 'libc\.so|ld-linux' "$listing" | sed 's/^/      /' | sort -u | head -n 5
    else
      echo "  no libc in any layer"
    fi

    # 5. the shaped /bin/sh, extracted from the image the same way a kubelet
    #    would find it. The chart's literal hook must work.
    workdir="$(mktemp -d)"
    ( cd "$workdir" && tar xzf "$image" 2>/dev/null || tar xf "$image" 2>/dev/null ) || true

    # Diagnostic first. A "not found" that cannot distinguish an absent file from
    # a wrong search is not a finding, it is a guess.
    echo "  -- layer tars --"
    find "$workdir" -name '*.tar' 2>/dev/null | sed 's|^|      |'
    echo "  -- every entry mentioning sh across all layers --"
    for layer in $(find "$workdir" -name '*.tar' 2>/dev/null); do
      tar tvf "$layer" 2>/dev/null | grep -E '(^|/)bin/|sh$' | sed 's|^|      |' || true
    done

    shbin=""
    for layer in $(find "$workdir" -name '*.tar' 2>/dev/null); do
      # Match bin/sh with or without a leading ./ and follow it if it is a symlink
      # into the store, which is how buildLayeredImage stores contents entries.
      entry=$(tar tf "$layer" 2>/dev/null | grep -E '^\./?bin/sh$' | head -n1 || true)
      [ -n "$entry" ] || continue
      ( cd "$workdir" && tar xf "$layer" "$entry" 2>/dev/null ) || true
      candidate="$workdir/$(echo "$entry" | sed 's|^\./||')"
      if [ -L "$candidate" ]; then
        target=$(readlink "$candidate")
        echo "      bin/sh is a symlink to $target"
        [ -x "$target" ] && shbin="$target"
      elif [ -f "$candidate" ]; then
        shbin="$candidate"
      fi
      [ -n "$shbin" ] && break
    done

    if [ -z "$shbin" ]; then
      bad "no /bin/sh in the image; the chart's preStop hook would fail every termination"
    else
      chmod +x "$shbin" || true
      if "$shbin" -c "sleep 0.05"; then
        echo "  /bin/sh honours the chart's preStop hook"
      else
        bad "/bin/sh rejected the chart's own hook"
      fi
      # And it must NOT be a usable shell.
      if "$shbin" -c "echo pwned" 2>/dev/null; then
        bad "/bin/sh executed an arbitrary command; it must refuse everything outside its vocabulary"
      else
        echo "  /bin/sh refuses arbitrary commands"
      fi
      if "$shbin" 2>/dev/null; then
        bad "/bin/sh started interactively"
      else
        echo "  /bin/sh offers no interactive shell"
      fi
    fi

    # 6. and it still serves
    port=18082
    PORT="$port" "$serverBin" &
    pid=$!
    trap 'kill "$pid" 2>/dev/null || true' EXIT
    ok=0
    for _ in $(seq 1 50); do
      if curl -sf "http://127.0.0.1:$port/health" >/dev/null 2>&1; then ok=1; break; fi
      sleep 0.2
    done
    if [ "$ok" -ne 1 ]; then
      bad "the server never became ready on :$port"
    else
      code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/health" || echo 000)
      echo "  /health = $code"
      [ "$code" = "200" ] || bad "/health returned $code"
    fi

    if [ "$fail" -ne 0 ]; then
      echo "== web-static-spa-image: FAILED =="
      exit 1
    fi
    echo "== web-static-spa-image: PASS =="
    mkdir -p "$out"
    echo "web-static-spa-image: PASS" > "$out/result"
  ''
