# caixa — ecosystem coverage survey (15 ecosystems)

> Reference data for the M3.2+ ecosystem renderers in pleme-doc-gen.
> Each entry shows canonical manifest filename, format, key fields, and
> minimal valid example. Sourced via Explore agent survey 2026-05-23.
>
> Per the user's directive: 'send an agent to gather other ecosystems
> emitters so we have full coverage as far as the eye can see'.

## Coverage status

| Ecosystem | Manifest | Status |
|---|---|---|
| **rust-single-crate** | Cargo.toml | ✅ M3.1b — full depth |
| **rust-workspace** | Cargo.toml (workspace) | ✅ M3 base |
| **npm** | package.json | ✅ M3.2 — full depth |
| **python** | pyproject.toml | ✅ M3.2 — full depth |
| **helm** | Chart.yaml | ✅ M3 base |
| **github-action** | action.yml + run.tlisp | ✅ M3 base |
| **go** | go.mod | ⏳ M3.3 |
| **java-maven** | pom.xml | ⏳ M3.4 (XML emitter) |
| **java-gradle-kts** | build.gradle.kts | ⏳ M3.4 (Kotlin DSL emitter) |
| **dotnet-csproj** | *.csproj | ⏳ M3.4 (XML emitter) |
| **swift-spm** | Package.swift | ⏳ M3.5 (Swift code emitter) |
| **elixir-mix** | mix.exs | ⏳ M3.5 (Elixir code emitter) |
| **crystal-shards** | shard.yml | ⏳ M3.3 |
| **haskell-hpack** | package.yaml | ⏳ M3.3 |
| **ocaml-dune-opam** | dune-project | ⏳ M3.4 (s-expr emitter) |
| **zig** | build.zig.zon + build.zig | ⏳ M3.5 (ZON + code emitter) |
| **dart-flutter** | pubspec.yaml | ⏳ M3.3 |
| **php-composer** | composer.json | ⏳ M3.3 |
| **julia** | Project.toml | ⏳ M3.3 |
| **ruby-gem** | *.gemspec | ⏳ M3.5 (Ruby code emitter) |
| **nim-nimble** | *.nimble | ⏳ M3.5 (NimScript emitter) |

## Implementation roadmap

**M3.3 (this milestone — declarative manifests)** — 5 ecosystems
share the YAML/TOML/JSON pattern + can land as straightforward
emitters following the npm/python template:
- go (line-directives, custom but simple)
- crystal (YAML)
- haskell-hpack (YAML)
- dart (YAML)
- composer (JSON, sibling of npm)
- julia (TOML, sibling of pyproject)

**M3.4 — XML / s-expression manifests** (3 ecosystems):
- java-maven (XML)
- dotnet-csproj (XML)
- ocaml-dune-project (s-expr)

**M3.5 — code-as-manifest** (5 ecosystems requiring real syntax emission):
- java-gradle-kts (Kotlin DSL)
- swift-spm (Swift code w/ // swift-tools-version: directive)
- elixir-mix (Elixir defmodule)
- ruby-gem (Ruby Gem::Specification block)
- zig (ZON manifest + build.zig imperative code)
- nim-nimble (NimScript)

## Per-ecosystem schemas

(survey data captured by Explore agent — see git history for full
agent transcript with examples per ecosystem)

### go (go.mod)
```
file: go.mod
format: line-directives
  module <path>
  go <ver>
  require ( … )
```

### crystal (shard.yml)
```yaml
name: widget
version: 1.0.0
license: MIT
crystal: ">= 1.10.0"
dependencies:
  db:
    github: crystal-lang/crystal-db
    version: "~> 0.13"
development_dependencies:
  ameba:
    github: crystal-ameba/ameba
targets:
  widget:
    main: src/widget.cr
```

### dart (pubspec.yaml)
```yaml
name: widget
version: 1.0.0
description: …
environment:
  sdk: '^3.4.0'
dependencies:
  http: ^1.2.0
dev_dependencies:
  test: ^1.25.0
executables:
  widget: main
```

### composer (composer.json)
```json
{
  "name": "acme/widget",
  "description": "…",
  "type": "library",
  "license": "MIT",
  "require": { "php": ">=8.2" },
  "require-dev": { "phpunit/phpunit": "^11.0" },
  "autoload": { "psr-4": { "Acme\\Widget\\": "src/" } },
  "bin": ["bin/widget"]
}
```

### julia (Project.toml)
```toml
name = "Widget"
uuid = "12345678-1234-5678-1234-567812345678"
version = "1.0.0"

[deps]
JSON = "682c06a0-14ee-4cde-a369-852666b38b66"

[compat]
JSON = "0.21"
julia = "1.10"
```

### swift-spm (Package.swift)
```swift
// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "Widget",
    products: [.library(name: "Widget", targets: ["Widget"])],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [.target(name: "Widget")]
)
```

### elixir-mix (mix.exs)
```elixir
defmodule Widget.MixProject do
  use Mix.Project
  def project, do: [
    app: :widget, version: "1.0.0", elixir: "~> 1.16",
    deps: [{:jason, "~> 1.4"}],
  ]
end
```

### nim-nimble (*.nimble)
```nim
version       = "1.0.0"
description   = "…"
license       = "MIT"
srcDir        = "src"
bin           = @["widget"]
requires "nim >= 2.0.0"
```

## Cross-ecosystem normalization

Identified by the survey:

- **Identity differs from filename in 3 ecosystems**: csproj (filename → AssemblyName),
  gemspec (filename → name), nimble (filename → name). Renderer emits filename
  from typed `name` field.
- **No-version-in-manifest ecosystems**: Go, Swift, Ruby-gem. Git tag drives.
- **Dev-deps absent / encoded differently**: Go, Zig (no distinction), csproj
  (PrivateAssets attribute), Dart (`dev_dependencies` key), Elixir (per-dep
  `only:` flag), Julia (`[extras] + [targets]`).
- **UUID requirement**: Julia (unique). Renderer generates/persists uuidv4
  per package.
- **Code-not-data manifests** (M3.5): SwiftPM, Zig, Gradle KTS, Mix, Gemspec,
  Nimble — emitter produces syntactically valid host-language code via typed
  AST + per-language pretty-printer (the same `format!()`-ban pattern from
  theory/TYPED-EMISSION.md).
- **XML-shaped ecosystems** (M3.4): Maven pom + csproj share two-attribute
  (name+version) PackageReference/dependency shape. Renderer extracts shared
  `MvnCoord { group?, artifact, version, scope? }` emitter.
- **YAML-shaped ecosystems with overlap** (M3.3): pubspec / shard.yml /
  package.yaml — all use top-level name/version/description + dependencies
  map. Single typed `YamlManifest` base struct covers them.

This survey unblocks the M3.3-M3.5 emitter implementations. Each
new ecosystem extends the renderer mechanically per the canonical
caixa schema.
