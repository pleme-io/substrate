# Shikumi config: the Nix side is generated

The rule lives in [CLAUDE.md](../CLAUDE.md), "Shikumi Pattern". This page holds the how.

**The Nix side of a shikumi config is GENERATED, not restated.** The Rust
struct derives `schemars::JsonSchema`; commit `schema_for!(Config)` as JSON
next to the module, and surface it with
`(import "${substrate}/lib/types" { inherit lib; }).jsonSchema`:
`optionsFromJsonSchema { inherit lib; schema = ./config.schema.json; }` (an
options set for an object root) or `fromJsonSchema { … }` (the root's type,
e.g. a tagged enum). Render with `jsonSchema.pruneNulls` so unset optional
fields stay missing, which serde reads as their default. Objects are closed,
serde enums become `attrTag` / `enum`, recursive `$ref`s are safe, and an
unmapped keyword throws naming its JSON pointer instead of widening to
`anything`. Mapping, refusals, nixpkgs notes: `lib/types/json-schema.nix`;
proof: `checks.<system>.json-schema-types` (real schemars 1.2.2 fixtures).
