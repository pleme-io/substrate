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

  refuse = { where, field, expected, got, cause, fix }:
    tie.schemaViolation {
      subject = "delta-schema(go)";
      artifact = "Go.gen.lock";
      inherit where field adapter expected got cause fix;
    };

  # field :: schema -> attrs -> where -> name -> value | throw
  #
  # The ONLY way this reader reads a key. A required key that is absent
  # throws naming the field and the producer; an optional key that is absent
  # yields its documented default.
  field = schema: attrs: where: name:
    let spec = schema.${name} or null; in
    if spec == null then
      refuse {
        inherit where;
        field = name;
        expected = "a field declared in delta-schema.nix";
        got = "a read for an undeclared field";
        cause = ''
          This reader asked for a field the schema does not declare. That is a
          bug in the reader, not in the artifact: every read must be declared
          so that `closed` can tell producer additions from reader mistakes.'';
        fix = "add `${name}` to delta-schema.nix, or stop reading it";
      }
    else if attrs ? ${name} then attrs.${name}
    else if spec.required then
      refuse {
        inherit where;
        field = name;
        expected = "present (${spec.note})";
        got = "absent";
        cause = ''
          A required field is missing, which means the producer's shape and
          this reader's shape have diverged. Reconstructing anyway would
          produce a build spec that is silently missing part of itself while
          every other gate reports green.'';
        fix = "cd <that workspace> && gen build && git commit Go.gen.lock";
      }
    else spec.default;

  # closed :: schema -> attrs -> where -> label -> true | throw
  #
  # Refuses a key the schema does not declare. This is the half that catches
  # a PRODUCER addition — a new field gen starts emitting that this reader
  # would otherwise ignore forever.
  closed = schema: attrs: where: label:
    let
      declared = builtins.attrNames schema;
      present = builtins.attrNames attrs;
      unknown = builtins.filter (k: !(builtins.elem k declared)) present;
    in
    if unknown == [ ] then true
    else
      refuse {
        inherit where;
        field = builtins.concatStringsSep ", " unknown;
        expected = "only: ${builtins.concatStringsSep ", " declared}";
        got = "${label} carries undeclared key(s): ${builtins.concatStringsSep ", " unknown}";
        cause = ''
          The producer emits a field this reader does not know about. Ignoring
          it is how a contract drifts silently: the field exists, something
          upstream depends on it, and nothing here ever reads it.'';
        fix = "add the field to delta-schema.nix and consume it, or stop emitting it in gen-gomod";
      };

  # nonEmpty :: attrs -> where -> label -> true | throw
  #
  # A delta with an empty package set is not a module with no packages — it
  # is a delta that failed to describe its module. This is the specific
  # reconstruction the old `root_package = if packageKeys == [ ] then null`
  # branch produced, and deleting that branch is only safe because this
  # refuses first.
  nonEmpty = attrs: where: label:
    if attrs != { } then true
    else
      refuse {
        inherit where;
        field = label;
        expected = "at least one package";
        got = "an empty set";
        cause = ''
          An empty package set reconstructs to a build spec with no packages
          and a null root — which every downstream consumer accepts. There is
          no module for which this is the right answer, so it is refused here
          rather than propagated.'';
        fix = "cd <that workspace> && gen build && git commit Go.gen.lock";
      };
in
{
  inherit topLevel perPackage field closed nonEmpty adapter;
}
