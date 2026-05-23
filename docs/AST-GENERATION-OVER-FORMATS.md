# AST generation over `format!()` — the deepest pattern

> **Thesis.** The current 36-ecosystem caixa renderer uses
> string-template emission (`format!()` / push_str). This is the
> M3 fallback. The CORRECT shape per the typed-emission discipline
> ([`theory/TYPED-EMISSION.md`](https://github.com/pleme-io/theory/blob/main/TYPED-EMISSION.md)):
> **typed AST per target syntax + per-AST pretty-printer**.
>
> Per the prime directive: `format!()` of any target syntax is
> banned. Every output goes through a typed AST. The 36 string-
> template emitters are M3 stand-ins; M4 promotes each to AST-based
> emission.

## Why this matters

Hand-format string templates have three failure modes that typed
ASTs make IMPOSSIBLE:

1. **Quote escaping bugs**: a description with `"` inside gets
   silently mangled. Typed `JsonString::from(s).render()`
   handles escaping by construction.
2. **Indentation drift**: regenerated files have ad-hoc indent
   that breaks YAML / Python / S-expressions. Typed
   `TreeNode::pretty(indent_width)` enforces uniform indent.
3. **Combinatorial gaps**: any combination of optional fields
   creates a path the template author may not have tested. Typed
   structs prevent missing-field bugs at compile time.

## The 36 emitters → 36 target ASTs

Each ecosystem's manifest format has a canonical AST shape:

| Target format | Existing Rust crate | M4 typed AST module |
|---|---|---|
| TOML (Cargo, pyproject, Project.toml, fpm, alire, gleam) | `toml_edit` | `caixa_emit::toml_ast` |
| JSON (package.json, deno.json, composer.json, vcpkg.json) | `serde_json::Value` | `caixa_emit::json_ast` |
| YAML (Chart.yaml, shard.yml, pubspec.yaml, meta.yaml, gleam, fpm) | `serde_yaml::Value` | `caixa_emit::yaml_ast` |
| XML (pom.xml, .csproj) | `quick-xml` | `caixa_emit::xml_ast` |
| S-expr (dune-project, deps.edn, info.rkt, lakefile) | hand-built `Sexp` | `caixa_emit::sexp_ast` |
| INI (Pipfile, DESCRIPTION) | `rust-ini` | `caixa_emit::ini_ast` |
| Custom line-directives (go.mod, Nim nimble) | hand-built | `caixa_emit::lined_ast` |
| Code-as-manifest (Swift / Gradle KTS / mix.exs / Gemspec / NimScript / Zig / build.sbt) | host-language AST per file | `caixa_emit::<lang>_ast` |

Each AST module exposes:

```rust
pub enum Node {
    Leaf(String),
    String(JsonString),  // typed escape
    Table(BTreeMap<String, Node>),
    Array(Vec<Node>),
    ...
}

impl Node {
    pub fn render(&self, indent: u8) -> String { ... }
}
```

Renderer becomes:

```rust
fn render_rust_single(c: &Caixa, ...) -> Result<...> {
    let mut cargo = toml_ast::Document::new();
    cargo.table("package")
        .key("name", &c.package["name"])
        .key("version", &c.package["version"])
        ...;
    for dep in &c.dependencies.runtime {
        cargo.table("dependencies").key(&dep.name, &dep.version);
    }
    fs::write(path, cargo.render(2))?;
}
```

No `format!()`. No quote escaping. No indent drift. Combinatorial
correctness by construction.

## M4 migration roadmap

**M4.0 (this iteration — drafted)**: this doc names the target,
catalogs the 8 AST families, and identifies existing crates to
consume vs. hand-build.

**M4.1**: introduce `caixa_emit::toml_ast` (reuse `toml_edit`).
Migrate render_rust_single + render_rust_workspace + render_julia
+ render_fpm + render_alire + render_gleam + render_python.
**Single AST family covers 7 ecosystems.**

**M4.2**: introduce `caixa_emit::json_ast`. Migrate npm / composer /
deno / vcpkg / pnpm (workspace). 5 ecosystems.

**M4.3**: introduce `caixa_emit::yaml_ast`. Migrate helm / crystal /
dart / conda / racket-helper. 5 ecosystems.

**M4.4**: introduce `caixa_emit::xml_ast`. Migrate maven / csproj.
2 ecosystems.

**M4.5**: introduce `caixa_emit::sexp_ast`. Migrate dune / deps.edn /
info.rkt. 3 ecosystems.

**M4.6**: introduce `caixa_emit::ini_ast`. Migrate Pipfile /
DESCRIPTION. 2 ecosystems.

**M4.7**: introduce per-language code emitters for code-as-manifest
ecosystems (Swift / Gradle KTS / mix / gemspec / nimble / zig /
sbt). These are the hardest — each needs a typed AST of the
host language's manifest dialect. ~7 ecosystems.

**Total migration: 31 of 36 ecosystems become typed-AST-emitted.**
The remaining 5 (go.mod, nimble, racket-info, etc.) use simpler
line-directive ASTs that the hand-built `lined_ast` handles.

## After M4: the substrate is `format!()`-free at the emitter layer

Per the directive ban (CLAUDE.md ★★ Typed-Emission): every string
the substrate emits comes from a typed surface. The current 36
emitters violate this in M3; M4 closes the gap.

## Why this is the next compounding leap

The current emitters work — 15 snapshot tests pass. But they're
brittle:
- Adding a new field to a Cargo.toml emitter risks corrupting
  the existing fields.
- A description with embedded quotes can break the package.json.
- The s-expression renderer for dune-project has hand-tracked
  paren depth.

With typed ASTs, ALL these failure modes become compile-time
impossible. The substrate REINFORCES the prime directive at the
deepest layer.

## How M4 reuses existing typed-AST work in pleme-io

The substrate already ships typed AST builders for several
domains in `arch-synthesizer`:
- `NixValue` (Nix expressions)
- `GoNode` (Go source)
- `Action` (GitHub Action YAML)

The M4 caixa_emit AST families extend the same pattern to
manifest-target syntaxes. Same idiom; new domain. The 4 irreducible
patterns absorb yet another layer.

## Status

**M4 documented + queued.** M3 stand-in emitters keep working
in the meantime. Each M4.x milestone is a focused commit:
introduce the AST, migrate the per-ecosystem emitters, lock
contracts via existing snapshot tests, retire the string templates.

The compounding continues. The typed-AST discipline reaches the
deepest emitter layer. The prime directive holds at every depth.
