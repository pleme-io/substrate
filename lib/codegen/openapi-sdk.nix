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
# Supported generators (40+):
#
# Client SDKs:
#   go, python, javascript, typescript, java, ruby, csharp, rust,
#   kotlin, swift, dart, php, perl, elixir, scala, haskell, c, cpp,
#   lua, r, ocaml, clojure, elm, powershell, bash
#
# TypeScript variants:
#   typescript (fetch), typescript-axios, typescript-node, typescript-angular
#
# Server stubs:
#   go-server, python-fastapi, rust-axum, spring, kotlin-spring
#
# Schema generators:
#   graphql-schema, protobuf-schema, mysql-schema, postgresql-schema
#
# Documentation:
#   markdown, html, asciidoc, plantuml
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
  check = import ../types/assertions.nix;
  _ = check.all [
    (check.nonEmptyStr "name" name)
    (check.nonEmptyStr "version" version)
    (check.nonEmptyStr "language" language)
    (check.str "license" license)
  ];

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

    # ── Additional client languages ────────────────────────────────
    kotlin = {
      generator = "kotlin";
      properties = {
        groupId = "io.${packageName}";
        artifactId = packageName;
        artifactVersion = version;
        library = "jvm-okhttp4";
        dateLibrary = "java8";
      };
    };
    swift = {
      generator = "swift6";
      properties = {
        projectName = packageName;
        podVersion = version;
      };
    };
    dart = {
      generator = "dart";
      properties = {
        pubName = packageName;
        pubVersion = version;
      };
    };
    php = {
      generator = "php";
      properties = {
        packageName = packageName;
        artifactVersion = version;
        invokerPackage = packageName;
      };
    };
    perl = {
      generator = "perl";
      properties = {
        moduleName = packageName;
        moduleVersion = version;
      };
    };
    elixir = {
      generator = "elixir";
      properties = {
        packageName = packageName;
        invokerPackage = packageName;
      };
    };
    scala = {
      generator = "scala-sttp";
      properties = {
        groupId = "io.${packageName}";
        artifactId = packageName;
        artifactVersion = version;
      };
    };
    haskell = {
      generator = "haskell-http-client";
      properties = {
        cabalPackage = packageName;
        cabalVersion = version;
      };
    };
    c = {
      generator = "c";
      properties = {
        projectName = packageName;
      };
    };
    cpp = {
      generator = "cpp-restsdk";
      properties = {
        packageName = packageName;
        packageVersion = version;
      };
    };
    lua = {
      generator = "lua";
      properties = {
        packageName = packageName;
        packageVersion = version;
      };
    };
    r = {
      generator = "r";
      properties = {
        packageName = packageName;
        packageVersion = version;
      };
    };
    ocaml = {
      generator = "ocaml";
      properties = {
        packageName = packageName;
        packageVersion = version;
      };
    };
    clojure = {
      generator = "clojure";
      properties = {
        projectName = packageName;
        projectVersion = version;
      };
    };
    elm = {
      generator = "elm";
      properties = {
        elmPrefixCustomTypeVariants = "true";
      };
    };
    powershell = {
      generator = "powershell";
      properties = {
        packageName = packageName;
        packageVersion = version;
      };
    };
    bash = {
      generator = "bash";
      properties = {
        scriptName = packageName;
      };
    };

    # ── TypeScript variants ────────────────────────────────────────
    typescript-axios = {
      generator = "typescript-axios";
      properties = {
        npmName = packageName;
        npmVersion = version;
        supportsES6 = "true";
      };
    };
    typescript-node = {
      generator = "typescript-node";
      properties = {
        npmName = packageName;
        npmVersion = version;
      };
    };
    typescript-angular = {
      generator = "typescript-angular";
      properties = {
        npmName = packageName;
        npmVersion = version;
        ngVersion = "18";
      };
    };

    # ── Server generators ──────────────────────────────────────────
    go-server = {
      generator = "go-server";
      properties = {
        packageName = packageName;
        packageVersion = version;
      };
    };
    python-fastapi = {
      generator = "python-fastapi";
      properties = {
        packageName = packageName;
        packageVersion = version;
      };
    };
    rust-axum = {
      generator = "rust-axum";
      properties = {
        packageName = packageName;
        packageVersion = version;
      };
    };
    spring = {
      generator = "spring";
      properties = {
        groupId = "io.${packageName}";
        artifactId = packageName;
        artifactVersion = version;
        useSpringBoot3 = "true";
      };
    };
    kotlin-spring = {
      generator = "kotlin-spring";
      properties = {
        groupId = "io.${packageName}";
        artifactId = packageName;
        artifactVersion = version;
      };
    };

    # ── Schema generators ──────────────────────────────────────────
    graphql-schema = {
      generator = "graphql-schema";
      properties = {};
    };
    protobuf-schema = {
      generator = "protobuf-schema";
      properties = {};
    };
    mysql-schema = {
      generator = "mysql-schema";
      properties = {
        defaultDatabaseName = packageName;
      };
    };
    postgresql-schema = {
      generator = "postgresql-schema";
      properties = {
        defaultDatabaseName = packageName;
      };
    };

    # ── Documentation generators ───────────────────────────────────
    markdown = {
      generator = "markdown";
      properties = {};
    };
    html = {
      generator = "html2";
      properties = {};
    };
    asciidoc = {
      generator = "asciidoc";
      properties = {};
    };
    plantuml = {
      generator = "plantuml";
      properties = {};
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
