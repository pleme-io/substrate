# delta-contract.nix — the reader-side contract for a `gen` delta artifact.
#
# One validator, N languages. A delta reader declares a FIELD TABLE and gets
# `field` / `closed` / `nonEmpty`, which refuse rather than guess.
#
# ── ★ WHY THIS IS SHARED AND NOT COPIED ────────────────────────────────────
#
# The mechanism is language-agnostic: only the artifact name, the producing
# adapter and the regen command differ between Cargo and Go. The three
# refusal shapes — undeclared read, absent-required field, undeclared producer
# key — are identical, and so is the argument for them.
#
# It was extracted on the SECOND consumer rather than the third, because the
# two arrived at it independently and unequally. Measured 2026-08-17:
#
#   - `build/go/delta-schema.nix` had the strict contract: explicit
#     required/default per field, a closed unknown-key set, 4 bare `or`s —
#     and ZERO live consumers.
#   - `build/rust/lockfile-delta.nix` had 17 bare `or`s, no closed set, and
#     425 live consumers.
#
# So the hardened design was proven where nothing used it, while the
# permissive one ran the whole Rust fleet. That asymmetry is the reason to
# share rather than to reimplement: a second hand-rolled copy would have
# inherited whichever half its author happened to read.
#
# ── WHAT IT REFUSES, AND WHY EACH HALF IS NEEDED ───────────────────────────
#
# `freshness-tie.held` answers "is this artifact still describing its source?"
# It is structurally blind to "is this artifact the SHAPE the reader expects?"
# — and a reader that defaults an absent key silently answers YES to the
# second while the tie answers YES to the first, yielding a green verdict over
# a reconstruction that dropped everything. Measured on Go before this
# existed: fed the exact bytes gen-gomod emits, a 17-`or` reader returned
# `{ packages = { }; root_package = null; }` behind a GREEN tie.
#
# `field` catches a READER/producer divergence (a key the producer stopped
# emitting). `closed` catches the opposite (a key the producer STARTED
# emitting that the reader would ignore forever). Neither substitutes for the
# other, and the tie substitutes for neither.
#
# TIER: eval-rejected (a Nix `throw`). Not unrepresentable — gen can still
# emit any JSON it likes; this is the READER refusing to guess, which is the
# strongest tier available to the consumer half of a cross-repository
# contract. Do not round it up.
{ lib }:

# identity :: { subject, artifact, adapter, schemaPath, regenCommand }
#
#   subject      — names this reader in every refusal, e.g. "delta-schema(go)"
#   artifact     — the committed file, e.g. "Go.gen.lock"
#   adapter      — the PRODUCING crate + repo, e.g. "gen-gomod (pleme-io/gen)".
#                  Named because reader and writer live in different
#                  repositories; a message naming only the field sends the
#                  operator to the wrong one.
#   schemaPath   — where the field table lives, for the "declare it" fix
#   regenCommand — the shell line that regenerates + commits the artifact
{
  subject,
  artifact,
  adapter,
  schemaPath,
  regenCommand,
}:
let
  tie = import ./freshness-tie.nix { };

  refuse =
    {
      where,
      field,
      expected,
      got,
      cause,
      fix,
    }:
    tie.schemaViolation {
      inherit
        subject
        artifact
        where
        field
        adapter
        expected
        got
        cause
        fix
        ;
    };

  # field :: schema -> attrs -> where -> name -> value | throw
  #
  # The ONLY sanctioned way to read a key. A required key that is absent
  # throws naming the field and the producer; an optional key that is absent
  # yields its documented default. Reading a key the table does not declare is
  # itself a refusal, so `closed` can tell a producer addition from a reader
  # mistake.
  field =
    schema: attrs: where: name:
    let
      spec = schema.${name} or null;
    in
    if spec == null then
      refuse {
        inherit where;
        field = name;
        expected = "a field declared in ${schemaPath}";
        got = "a read for an undeclared field";
        cause = ''
          This reader asked for a field the schema does not declare. That is a
          bug in the reader, not in the artifact: every read must be declared
          so that `closed` can tell producer additions from reader mistakes.'';
        fix = "add `${name}` to ${schemaPath}, or stop reading it";
      }
    else if attrs ? ${name} then
      attrs.${name}
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
        fix = regenCommand;
      }
    else
      spec.default;

  # closed :: schema -> attrs -> where -> label -> true | throw
  #
  # Refuses a key the table does not declare. This is the half that catches a
  # PRODUCER addition — a new field gen starts emitting that this reader would
  # otherwise ignore forever.
  closed =
    schema: attrs: where: label:
    let
      declared = builtins.attrNames schema;
      present = builtins.attrNames attrs;
      unknown = builtins.filter (k: !(builtins.elem k declared)) present;
    in
    if unknown == [ ] then
      true
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
        fix = "add the field to ${schemaPath} and consume it, or stop emitting it in ${adapter}";
      };

  # nonEmpty :: attrs -> where -> label -> true | throw
  #
  # An empty payload is not "a project with nothing in it" — it is a delta
  # that failed to describe its project. Kept separate from `field` because a
  # PRESENT-but-empty value passes every presence check while being just as
  # wrong as an absent one.
  nonEmpty =
    attrs: where: label:
    if attrs != { } then
      true
    else
      refuse {
        inherit where;
        field = label;
        expected = "at least one entry";
        got = "an empty set";
        cause = ''
          An empty payload reconstructs to a build spec with nothing in it,
          which builds "successfully" while producing none of the project.
          Present-but-empty passes a presence check, so it needs its own
          refusal.'';
        fix = regenCommand;
      };
in
{
  inherit
    refuse
    field
    closed
    nonEmpty
    ;
}
