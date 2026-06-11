# mcp-server-datadog — hermetic build of @winor30/mcp-server-datadog.
#
# Replaces the impure `npx -y @winor30/mcp-server-datadog` exec in the
# datadog MCP kind (../mcp-helpers.nix mcpKinds). npx resolves from a
# mutable per-user cache at server startup — a corrupted cache or a
# registry outage breaks the MCP server at runtime with no nix-side
# remediation. This derivation pins the server in the store like the
# grafana (pkgs.mcp-grafana) and kubernetes (pkgs.mcp-k8s-go) kinds.
#
# Upstream is pnpm-locked (pnpm-lock.yaml, no package-lock.json), so this
# uses pnpm_10.fetchDeps + configHook rather than buildNpmPackage.
{ lib
, stdenv
, fetchFromGitHub
, nodejs
, pnpm_10
, makeWrapper
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "mcp-server-datadog";
  version = "1.7.0";

  src = fetchFromGitHub {
    owner = "winor30";
    repo = "mcp-server-datadog";
    rev = "v${finalAttrs.version}";
    hash = "sha256-Z8Robsnu8PvdgSbo9Hfk/IvTEkzoQtnRLxjWIM8vFWw=";
  };

  nativeBuildInputs = [
    nodejs
    pnpm_10.configHook
    makeWrapper
  ];

  pnpmDeps = pnpm_10.fetchDeps {
    inherit (finalAttrs) pname version src;
    fetcherVersion = 3;
    hash = "sha256-iDJ8VO4LwVmm0/5WJb8RMHY3WzB3omfDEgNfYnUE5k4=";
  };

  buildPhase = ''
    runHook preBuild
    pnpm build
    runHook postBuild
  '';

  # The tsup bundle keeps `dependencies` external, so the runtime needs
  # node_modules next to build/. pnpm's node_modules is a relative-symlink
  # forest into node_modules/.pnpm — copied as-is it stays self-contained.
  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin $out/lib/mcp-server-datadog
    cp -r build node_modules package.json $out/lib/mcp-server-datadog/
    makeWrapper ${lib.getExe nodejs} $out/bin/mcp-server-datadog \
      --add-flags $out/lib/mcp-server-datadog/build/index.js
    runHook postInstall
  '';

  meta = {
    description = "MCP server for the Datadog API (incidents, monitors, logs, metrics, traces)";
    homepage = "https://github.com/winor30/mcp-server-datadog";
    license = lib.licenses.asl20;
    mainProgram = "mcp-server-datadog";
  };
})
