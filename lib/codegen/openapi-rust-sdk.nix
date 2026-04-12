# OpenAPI Rust SDK Generator
#
# Generates a Rust crate from an OpenAPI 3.0 spec using openapi-generator-cli.
# The generated crate is a fully typed async client with serde models and
# reqwest-based HTTP client methods.
#
# Usage (in a flake.nix):
#   let
#     mkOpenApiRustSdk = import "${substrate}/lib/openapi-rust-sdk.nix";
#   in
#   mkOpenApiRustSdk {
#     inherit pkgs;
#     name = "akeyless-api";
#     version = "0.1.0";
#     specFile = ./api/openapi.yaml;  # or .json
#     # Optional:
#     # library = "reqwest";           # default
#     # tls = "rustls-tls";            # default, or "native-tls"
#     # additionalProperties = {};     # extra openapi-generator options
#   }
#
# Returns: a derivation containing the generated Rust crate source.
# The output can be used as `src` for rustPlatform.buildRustPackage or
# as a git dependency in Cargo.toml.
#
# Pinned to: openapi-generator-cli 7.18.0
# Tested with: Akeyless API spec (604 endpoints, 1334 types, OpenAPI 3.0.0)
#
# Known limitations:
# - progenitor (Oxide's Rust-native generator) panics on specs with
#   multiple response types per endpoint. openapi-generator handles these.
# - YAML specs with datetime values need JSON conversion (handled automatically)
# - Generated code uses edition 2021 (openapi-generator default)
{
  pkgs,
  name,
  version,
  specFile,
  library ? "reqwest",
  tls ? "rustls-tls",
  license ? "MIT",
  additionalProperties ? {},
}: let
  check = import ../types/assertions.nix;
  _ = check.all [
    (check.nonEmptyStr "name" name)
    (check.nonEmptyStr "version" version)
    (check.str "library" library)
    (check.str "tls" tls)
    (check.str "license" license)
  ];
  inherit (pkgs) lib;

  # Merge user properties with defaults
  allProperties = {
    packageName = name;
    packageVersion = version;
    inherit library;
  } // additionalProperties;

  propertiesStr = lib.concatStringsSep "," (
    lib.mapAttrsToList (k: v: "${k}=${v}") allProperties
  );

  # Convert YAML to JSON if needed (handles datetime edge cases)
  specJson = pkgs.runCommand "${name}-openapi-spec.json" {
    nativeBuildInputs = [ pkgs.python3Packages.pyyaml ];
  } ''
    python3 -c "
    import yaml, json, sys
    def handler(obj): return str(obj)
    with open('${specFile}') as f:
      spec = yaml.safe_load(f)
    with open('$out', 'w') as f:
      json.dump(spec, f, indent=2, default=handler)
    "
  '';
in
pkgs.runCommand "${name}-${version}-generated" {
  nativeBuildInputs = [ pkgs.openapi-generator-cli ];
} ''
  mkdir -p $out
  openapi-generator-cli generate \
    -i ${specJson} \
    -g rust \
    -o $out \
    --additional-properties=${propertiesStr}

  # Fix up Cargo.toml for pleme-io conventions
  cat > $out/Cargo.toml << 'CARGO'
  [package]
  name = "${name}"
  version = "${version}"
  edition = "2021"
  description = "Auto-generated Rust SDK from OpenAPI spec"
  license = "${license}"
  authors = ["Pleme Team <team@pleme.io>"]

  [dependencies]
  serde = { version = "^1.0", features = ["derive"] }
  serde_with = { version = "^3.8", default-features = false, features = ["base64", "std", "macros"] }
  serde_json = "^1.0"
  serde_repr = "^0.1"
  url = "^2.5"
  reqwest = { version = "^0.12", default-features = false, features = ["json", "multipart"] }

  [features]
  default = ["${tls}"]
  native-tls = ["reqwest/native-tls"]
  rustls-tls = ["reqwest/rustls-tls"]

  [profile.release]
  opt-level = "z"
  lto = true
  codegen-units = 1
  strip = true
  CARGO
''
