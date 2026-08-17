# delta-schema.nix — the CLOSED schema of `Go.gen.lock`, and the only door
# through which `build/go/lockfile-delta.nix` may read it.
#
# ── WHY ─────────────────────────────────────────────────────────────────
#
# `lockfile-delta.nix` read the delta with 17 bare `or` defaults. Measured
# 2026-08-08 against the literal bytes gen-gomod emits today —
# `{schema_version, go_sum_sha256, source_hashes}`, carrying no `per_package`
# — the reader returned a ZERO-PACKAGE build spec with `root_package = null`
# behind a GREEN D2 freshness tie. No throw, no warning.
#
# The D2 tie was working correctly the whole time. It answers "does this
# artifact still describe its source?", and it did. The unanswered question
# was "is this artifact the SHAPE I was written against?" — and 17 `or`s
# answered YES to that by construction, for every possible input.
#
# `gen-gomod::write_gen_delta` has ZERO call sites today (verified), so this
# is a dormant hazard, not a live outage: `reconstruct` returns null unless a
# `Go.gen.lock` exists, and there are 0 fleet-wide against a 425-file
# `Cargo.gen.lock` control. But it is exactly one added call from being a
# silent fleet-wide wrong answer, and an agent wiring that call would see a
# green gate confirming the work.
#
# ── THE RULE ────────────────────────────────────────────────────────────
#
# A field is either REQUIRED — absent means the producer and this reader
# disagree, and the only correct action is to refuse — or it carries an
# EXPLICIT, DOCUMENTED default that is a real part of the contract. There is
# no third category, and in particular there is no "default it and hope".
#
# Every entry below states which it is and why. Adding a field to the
# producer without adding it here is caught by `closed`, in the same
# evaluation, rather than by a consumer noticing months later that a value
# it depends on has quietly been `[ ]` all along.
#
# TIER: eval-rejected (Nix `throw`). Not unrepresentable — gen can still emit
# any JSON. This is the READER refusing to guess, which is the strongest tier
# available to the consumer half of a cross-repository contract.
{ lib }:
let
  tie = import ../shared/freshness-tie.nix { };

  # The producing adapter, named in every refusal. The reader and the writer
  # live in different repositories; a message naming only the field sends the
  # operator to the wrong one.
  adapter = "gen-gomod (pleme-io/gen)";

  # ── Top-level keys ────────────────────────────────────────────────────
  #
  # `source_hashes` is listed as KNOWN-BUT-UNUSED on purpose. It is what gen
  # emits today, this reader does not consume it, and leaving it out of the
  # closed set would make the current producer output fail the unknown-key
  # check for the wrong reason — reporting a shape mismatch where the real
  # defect is a missing `per_package`. Naming it keeps the refusal pointed at
  # the field that actually matters.
  topLevel = {
    schema_version = { required = false; default = 1; note = "delta format version; 1 is the only shipped value"; };
    go_sum_sha256  = { required = true;  note = "the D2 tie subject — without it there is no freshness check at all"; };
    per_package    = { required = true;  note = "the payload: absent means every package silently disappears"; };
    source_hashes  = { required = false; default = { }; note = "KNOWN-BUT-UNUSED: emitted by gen today, not consumed here"; };
  };

  # ── Per-package fields ────────────────────────────────────────────────
  #
  # `pname` and `version` default because gen legitimately omits them for the
  # single-module case, where the key and the module path already carry the
  # information. The list/attr fields default EMPTY because empty is a real,
  # meaningful value for them — a module with no build tags has no build tags.
  # `vendor_hash` is the one whose absence is meaningful in the other
  # direction: absent means "no external deps", which the reader turns into
  # `has_external_deps = false`, so it must not be required.
  perPackage = {
    module              = { required = true;  note = "the module path; without it the package cannot be identified"; };
    pname               = { required = false; default = null; note = "falls back to the delta key"; };
    version             = { required = false; default = "0.0.0"; note = "gen omits it for unversioned modules"; };
    vendor_hash         = { required = false; default = null; note = "ABSENT IS MEANINGFUL: no external deps"; };
    proxy_vendor        = { required = false; default = null; note = "absent = nixpkgs default"; };
    do_check            = { required = false; default = null; note = "absent = nixpkgs default"; };
    tags                = { required = false; default = [ ]; note = "empty is a real value"; };
    ldflags             = { required = false; default = [ ]; note = "empty is a real value"; };
    sub_packages        = { required = false; default = [ ]; note = "empty is a real value"; };
    env                 = { required = false; default = { }; note = "empty is a real value"; };
    native_build_inputs = { required = false; default = [ ]; note = "empty is a real value"; };
    build_inputs        = { required = false; default = [ ]; note = "empty is a real value"; };
    quirks              = { required = false; default = [ ]; note = "empty is a real value"; };
  };

  # ── The mechanism is SHARED, not local ────────────────────────────────
  #
  # `refuse` / `field` / `closed` / `nonEmpty` used to live here in full. They
  # are language-agnostic — only the artifact name, the producing adapter and
  # the regen command differ — so they moved to ../shared/delta-contract.nix
  # and Rust's reader now consumes the SAME validator instead of a second
  # hand-rolled copy. What stays here is this language's FIELD TABLE, which is
  # the only genuinely Go-specific half.
  #
  # Extracted 2026-08-17 on the second consumer, and the asymmetry is why:
  # this reader was the strict one with zero live consumers, while Rust's had
  # 17 bare `or`s and 425. A third hand-rolled copy would have inherited
  # whichever half its author happened to read first.
  contract = import ../shared/delta-contract.nix { inherit lib; } {
    subject = "delta-schema(go)";
    artifact = "Go.gen.lock";
    inherit adapter;
    schemaPath = "delta-schema.nix";
    regenCommand = "cd <that workspace> && gen build && git commit Go.gen.lock";
  };

  inherit (contract) refuse field closed nonEmpty;

in
{
  inherit topLevel perPackage field closed nonEmpty adapter;
}
