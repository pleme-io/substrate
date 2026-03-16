# OpenAPI Multi-Language SDK Generator
#
# Generates typed API client libraries from an OpenAPI 3.0 spec for any
# supported language. Wraps openapi-generator-cli with language-specific
# conventions and packaging.
#
# Usage:
#   mkOpenApiSdk = import "${substrate}/lib/openapi-sdk.nix";
#
#   # Generate a Go SDK
#   goSdk = mkOpenApiSdk {
#     inherit pkgs;
#     name = "myapi";
#     version = "1.0.0";
#     specFile = ./api/openapi.yaml;
#     language = "go";
#   };
#
#   # Generate a Python SDK
#   pythonSdk = mkOpenApiSdk {
#     inherit pkgs;
#     name = "myapi";
#     version = "1.0.0";
#     specFile = ./api/openapi.yaml;
#     language = "python";
#   };
#
# Supported languages: go, python, javascript, java, ruby, csharp, rust, typescript
#
# Returns: a derivation containing the generated SDK source.
# For Rust specifically, use openapi-rust-sdk.nix which has deeper Cargo.toml integration.
{
  pkgs,
  name,
  version,
  specFile,
  language,
  packageName ? name,
  license ? "MIT",
  additionalProperties ? {},
  postGenerate ? "",
}:
let
  inherit (pkgs) lib;

  # Language-specific generator names and defaults
  generators = {
    go = {
      generator = "go";
      properties = {
        packageName = packageName;
        packageVersion = version;
        isGoSubmodule = "true";
        generateInterfaces = "true";
      };
    };
    python = {
      generator = "python";
      properties = {
        packageName = packageName;
        packageVersion = version;
        projectName = packageName;
      };
    };
    javascript = {
      generator = "javascript";
      properties = {
        projectName = packageName;
        projectVersion = version;
        usePromises = "true";
      };
    };
    typescript = {
      generator = "typescript-fetch";
      properties = {
        npmName = packageName;
        npmVersion = version;
        supportsES6 = "true";
        typescriptThreePlus = "true";
      };
    };
    java = {
      generator = "java";
      properties = {
        groupId = "io.${packageName}";
        artifactId = packageName;
        artifactVersion = version;
        library = "native";
        dateLibrary = "java8";
      };
    };
    ruby = {
      generator = "ruby";
      properties = {
        gemName = packageName;
        gemVersion = version;
        moduleName = lib.concatMapStrings (s: lib.toUpper (lib.substring 0 1 s) + lib.substring 1 (-1) s) (lib.splitString "-" packageName);
      };
    };
    csharp = {
      generator = "csharp";
      properties = {
        packageName = packageName;
        packageVersion = version;
        targetFramework = "net6.0";
        library = "httpclient";
      };
    };
    rust = {
      generator = "rust";
      properties = {
        packageName = packageName;
        packageVersion = version;
        library = "reqwest";
      };
    };
  };

  langConfig = generators.${language} or (throw "Unsupported language: ${language}. Supported: ${lib.concatStringsSep ", " (lib.attrNames generators)}");

  allProperties = langConfig.properties // additionalProperties;

  propertiesStr = lib.concatStringsSep "," (
    lib.mapAttrsToList (k: v: "${k}=${toString v}") allProperties
  );

  # Convert YAML to JSON if needed
  specJson = pkgs.runCommand "${name}-openapi-spec.json" {
    nativeBuildInputs = [ pkgs.python3Packages.pyyaml ];
  } ''
    python3 -c "
    import yaml, json
    def handler(obj): return str(obj)
    with open('${specFile}') as f:
      spec = yaml.safe_load(f)
    with open('$out', 'w') as f:
      json.dump(spec, f, indent=2, default=handler)
    "
  '';
in
pkgs.runCommand "${name}-${language}-${version}" {
  nativeBuildInputs = [ pkgs.openapi-generator-cli ];
} ''
  mkdir -p $out
  openapi-generator-cli generate \
    -i ${specJson} \
    -g ${langConfig.generator} \
    -o $out \
    --additional-properties=${propertiesStr}

  ${postGenerate}
''
