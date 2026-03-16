# OpenAPI Unified Forge
#
# Single entry point for ALL code generation from an OpenAPI 3.0 spec.
# Combines two generation backends:
#
# 1. iac-forge (Rust): OpenAPI → IaC providers (Terraform, Pulumi, Crossplane, Ansible, Pangea, Steampipe)
# 2. openapi-generator-cli (Java): OpenAPI → client SDKs, server stubs, schemas, docs (40+ languages)
#
# Usage:
#   mkOpenApiForge = import "${substrate}/lib/openapi-forge.nix";
#   generated = mkOpenApiForge {
#     inherit pkgs;
#     name = "myapi";
#     version = "1.0.0";
#     specFile = ./api/openapi.yaml;
#
#     # Select what to generate (all optional, defaults to nothing)
#     sdks = [ "go" "python" "typescript" "java" "rust" ];
#     servers = [ "go-server" "python-fastapi" "rust-axum" ];
#     iac = [ "terraform" "pulumi" "crossplane" "ansible" ];
#     schemas = [ "graphql-schema" "protobuf-schema" "postgresql-schema" ];
#     docs = [ "markdown" "html" ];
#
#     # IaC-specific config
#     iacResources = ./resources;      # TOML resource specs for iac-forge
#     iacProvider = ./provider.toml;   # Provider config for iac-forge
#
#     # Per-language overrides
#     sdkProperties = {
#       go = { isGoSubmodule = "true"; };
#       typescript = { npmName = "@myorg/myapi"; };
#     };
#   };
#
# Returns: {
#   sdks.go, sdks.python, ...        — SDK source derivations
#   servers.go-server, ...            — Server stub derivations
#   iac.terraform, iac.pulumi, ...    — IaC provider code derivations
#   schemas.graphql-schema, ...       — Schema derivations
#   docs.markdown, docs.html, ...    — Documentation derivations
#   all                               — Combined derivation with everything
# }
{
  pkgs,
  name,
  version ? "0.1.0",
  specFile,
  sdks ? [],
  servers ? [],
  iac ? [],
  schemas ? [],
  docs ? [],
  iacResources ? null,
  iacProvider ? null,
  iacForge ? null,
  sdkProperties ? {},
  license ? "MIT",
}:
let
  inherit (pkgs) lib;

  mkOpenApiSdk = import ./openapi-sdk.nix;

  # Generate SDKs and server stubs via openapi-generator-cli
  mkSdkOutputs = targets: lib.genAttrs targets (lang:
    mkOpenApiSdk {
      inherit pkgs name version specFile license;
      language = lang;
      additionalProperties = sdkProperties.${lang} or {};
    }
  );

  sdkOutputs = mkSdkOutputs sdks;
  serverOutputs = mkSdkOutputs servers;
  schemaOutputs = mkSdkOutputs schemas;
  docOutputs = mkSdkOutputs docs;

  # Generate IaC providers via iac-forge (Rust binary)
  iacOutputs = lib.optionalAttrs (iac != [] && iacResources != null) (
    lib.genAttrs iac (backend:
      let
        forgeCmd = if iacForge != null
          then "${iacForge}/bin/iac-forge"
          else "iac-forge";
      in
      pkgs.runCommand "${name}-iac-${backend}-${version}" {
        nativeBuildInputs = lib.optional (iacForge != null) [ iacForge ];
      } ''
        mkdir -p $out
        ${forgeCmd} generate \
          --backend ${backend} \
          --spec ${specFile} \
          --resources ${iacResources} \
          ${lib.optionalString (iacProvider != null) "--provider ${iacProvider}"} \
          --output $out
      ''
    )
  );

  # Combined output
  allOutputs = pkgs.runCommand "${name}-forge-all-${version}" {} ''
    mkdir -p $out/{sdks,servers,iac,schemas,docs}
    ${lib.concatStringsSep "\n" (lib.mapAttrsToList (lang: drv: "ln -s ${drv} $out/sdks/${lang}") sdkOutputs)}
    ${lib.concatStringsSep "\n" (lib.mapAttrsToList (lang: drv: "ln -s ${drv} $out/servers/${lang}") serverOutputs)}
    ${lib.concatStringsSep "\n" (lib.mapAttrsToList (lang: drv: "ln -s ${drv} $out/iac/${lang}") iacOutputs)}
    ${lib.concatStringsSep "\n" (lib.mapAttrsToList (lang: drv: "ln -s ${drv} $out/schemas/${lang}") schemaOutputs)}
    ${lib.concatStringsSep "\n" (lib.mapAttrsToList (lang: drv: "ln -s ${drv} $out/docs/${lang}") docOutputs)}
  '';

in {
  inherit sdkOutputs serverOutputs schemaOutputs docOutputs iacOutputs;
  sdks = sdkOutputs;
  servers = serverOutputs;
  schemas = schemaOutputs;
  docs = docOutputs;
  iac = iacOutputs;
  all = allOutputs;
}
