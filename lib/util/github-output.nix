# github-output.nix — `$GITHUB_OUTPUT` as a typed value rendered once, never
# a string a caller concatenates.
#
# ── WHY THIS EXISTS ───────────────────────────────────────────────────────
#
# `$GITHUB_OUTPUT` is a WIRE FORMAT — `key=value`, newline-separated, parsed
# by the runner — and the fleet's ★★ TYPED EMISSION rule says a wire format is
# emitted from a typed surface, never assembled by hand. It had been assembled
# by hand here: `lib/util/test-env.nix` (2026-08-06) ended in
#
#     "installable=${installable}\ntier=${tier}\n"
#
# which is string-concatenating a protocol. That was written in the same
# session that removed a `run:` block for the same class of reason, which is
# the tell worth recording: the rule fires on shell and does not fire on a
# format string, even though the defect is identical.
#
# ── THE DEFECT THE HAND-ROLLED FORM CANNOT SEE ────────────────────────────
#
# A value containing a newline does not produce a malformed line — it produces
# EXTRA OUTPUTS. `x=a\nevil=1` writes two keys, and the second one is
# attacker-chosen if any part of the value came from outside. GitHub's own
# guidance is a random heredoc delimiter for exactly this reason. Concatenation
# has no place to put that check; a renderer does, and can make the bad state
# unreachable rather than merely discouraged.
#
# ── TIER, HONESTLY ────────────────────────────────────────────────────────
#
# This is PARSE-TIME-REJECTED, not truly-unrepresentable. A caller who builds
# the string themselves still can — nothing removes `+` from Nix. What this
# removes is the REASON to: the typed path is shorter than the hand-rolled one,
# and it throws on the inputs that would silently corrupt the protocol. Calling
# it unrepresentable would be rounding the tier up.
#
# ── USAGE ─────────────────────────────────────────────────────────────────
#
#   render { installable = ".#default"; tier = "declared-devshell"; }
#     => "installable=.#default\ntier=declared-devshell\n"
#
# In a workflow the caller redirects and does nothing else:
#
#   nix eval --raw --impure --expr '…' >> "$GITHUB_OUTPUT"
{ lib ? (import <nixpkgs> { }).lib }:
let
  # A key must be a plain identifier. GitHub does not document a grammar, so
  # this is deliberately NARROWER than whatever the runner tolerates: every key
  # the fleet actually emits is `[a-z][a-z0-9-]*`, and refusing the rest costs
  # nothing while removing the whole quoting question.
  keyOk = k: builtins.match "[a-z][a-z0-9-]*" k != null;

  # The injection check. A newline in a value is not a formatting problem, it
  # is a second key — see the header. `\r` is included because the runner
  # splits on it too on Windows runners, and a CR-only injection would slip a
  # `\n`-only test.
  valueOk = v: builtins.match ".*[\n\r].*" v == null;

  renderPair = k: v:
    if !(keyOk k) then
      throw ''
        github-output: ${builtins.toJSON k} is not a valid output key.

        Keys must match [a-z][a-z0-9-]* — lowercase, starting with a letter.
        This is narrower than the runner accepts, on purpose: every key the
        fleet emits already fits, and the restriction removes the quoting
        question entirely.
      ''
    else if !(builtins.isString v) then
      throw ''
        github-output: the value for ${builtins.toJSON k} is a ${builtins.typeOf v}, not a string.

        `$GITHUB_OUTPUT` is a text protocol; there is no typed encoding for a
        bool or an int, and Nix's own coercion rules differ from the runner's
        (`true` renders as `1`, which reads as a string "1" downstream).
        Render the value yourself so the wire shape is a decision, not a
        coincidence.
      ''
    else if !(valueOk v) then
      throw ''
        github-output: the value for ${builtins.toJSON k} contains a newline.

        This is not a formatting problem — it is an INJECTION. `$GITHUB_OUTPUT`
        is newline-separated, so a value carrying \n writes ADDITIONAL keys,
        chosen by whoever controls that value. GitHub's own guidance is a
        random heredoc delimiter for this exact case.

        Either strip the newline at the source, or if a multi-line value is
        genuinely needed, extend this file with the heredoc form and its own
        delimiter-collision check. Do not concatenate it by hand at the call
        site — that is the shape this file exists to remove.
      ''
    else
      "${k}=${v}";

  # Sorted by key, always. A renderer whose output depends on attrset
  # iteration order produces a diff that moves for no reason, and the byte-pin
  # test below could not be written at all.
  render = outputs:
    let
      pairs = lib.mapAttrsToList renderPair outputs;
    in
    if outputs == { } then
      throw ''
        github-output: refusing to render an empty output set.

        A step that writes nothing is indistinguishable from a step that ran
        and produced nothing, and the caller's `>>` would succeed either way.
        If a step genuinely has no outputs, do not call this.
      ''
    else
      lib.concatStringsSep "\n" (lib.sort (a: b: a < b) pairs) + "\n";
in
{
  inherit render keyOk valueOk;
}
