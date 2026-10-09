// The Rust that produced github-auth.schema.json and daemon-config.schema.json
// (schemars 1.2.2, serde 1, serde_json 1). Those two files are this program's
// output, byte for byte; the tests in lib/tests/json-schema-types-test.nix
// assert against them, so they stand for what schemars really emits.
//
// Regenerate (from a scratch crate with this file as src/main.rs and
//   [dependencies] schemars = "=1.2.2"
//                  serde = { version = "1", features = ["derive"] }
//                  serde_json = "1"):
//   cargo run -q -- auth   > github-auth.schema.json
//   cargo run -q -- daemon > daemon-config.schema.json
//
// GithubAuth / SecretSource / GithubApp are the stand-in for the shape shikumi
// is gaining; DaemonConfig adds the shapes they do not cover (plain and
// documented unit enums, an internally-tagged enum, a map, a set, f64, u16,
// i32, Option<recursive enum>).
use schemars::{schema_for, JsonSchema};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

/// How a secret value is obtained.
#[derive(Serialize, Deserialize, JsonSchema)]
#[serde(untagged)]
pub enum SecretSource {
    /// The secret itself, inline.
    Literal(String),
    /// Resolved from somewhere else at load time.
    Ref(SecretRef),
}

/// Where to read a secret from.
#[derive(Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum SecretRef {
    /// Read the file at this path.
    File(String),
    /// Read this environment variable.
    Env(String),
    /// Decrypt one key out of a SOPS file.
    Sops { file: String, key: String },
    /// Run this argv and take its stdout.
    Command(Vec<String>),
}

fn default_host() -> String { "github.com".into() }
fn default_api() -> String { "https://api.github.com".into() }
fn default_refresh() -> u64 { 300 }

/// A GitHub App installation.
#[derive(Serialize, Deserialize, JsonSchema)]
pub struct GithubApp {
    /// The App's numeric id.
    pub app_id: u64,
    /// PEM private key of the App.
    pub private_key: SecretSource,
    /// Installation id; discovered from `owner` when absent.
    pub installation_id: Option<u64>,
    /// Org or user the installation belongs to.
    pub owner: Option<String>,
    /// REST API base URL.
    #[serde(default = "default_api")]
    pub api_url: String,
    /// Refresh the installation token this many seconds before expiry.
    #[serde(default = "default_refresh")]
    pub refresh_before_secs: u64,
}

/// How to authenticate to GitHub.
#[derive(Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum GithubAuth {
    /// A token, from any secret source.
    Token(SecretSource),
    /// Borrow the gh CLI's stored credential.
    GhCli {
        #[serde(default = "default_host")]
        host: String,
    },
    /// Mint installation tokens as a GitHub App.
    App(GithubApp),
    /// Try each in order; the first that yields a token wins.
    Chain(Vec<GithubAuth>),
}

#[derive(Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum LogLevel { Error, Warn, Info, Debug }

#[derive(Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum Mode {
    /// Doc on a unit variant.
    Fast,
    /// Another.
    Slow,
}

#[derive(Serialize, Deserialize, JsonSchema)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Sink { Stdout, File { path: String }, Http { url: String, port: u16 } }

/// A shikumi-style daemon config.
#[derive(Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct DaemonConfig {
    /// GitHub credentials.
    pub github: GithubAuth,
    /// Log verbosity.
    #[serde(default)]
    pub log_level: Option<LogLevel>,
    pub mode: Mode,
    pub sinks: Vec<Sink>,
    pub labels: BTreeMap<String, String>,
    pub ratio: f64,
    pub enabled: bool,
    pub port: u16,
    pub offset: i32,
    pub tags: std::collections::BTreeSet<String>,
    pub fallback: Option<GithubAuth>,
}

fn main() {
    let which = std::env::args().nth(1).unwrap_or_default();
    let s = match which.as_str() {
        "auth" => schema_for!(GithubAuth),
        _ => schema_for!(DaemonConfig),
    };
    println!("{}", serde_json::to_string_pretty(&s).unwrap());
}
