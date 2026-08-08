# cgo-contract.nix — which `CGO_ENABLED` contract does THIS nixpkgs use?
#
# ── WHY A PROBE AND NOT A RECORDED FACT ─────────────────────────────────
#
# `buildGoModule`'s CGO_ENABLED contract INVERTS between nixpkgs revisions:
# older revisions take it as a TOP-LEVEL attribute, newer ones only through
# `env`. Which one applies is a property of the RESOLVED nixpkgs, and that
# moves on every `nix flake update`. A per-consumer recorded fact is therefore
# a hand-list that rots on the next lock bump — the exact class the fleet
# forbids — so this measures instead.
#
# ── THE DOCUMENTED MECHANISM IS WRONG. MEASURED 2026-08-08 ──────────────
#
# `theory/GEN-GO.md` §VI.6 proposed `builtins.functionArgs pkgs.buildGoModule`.
# That ERRORS:
#
#     error: 'functionArgs' requires a function
#
# `buildGoModule` is a FUNCTOR SET, not a function — its attrs are
# `__functionArgs __functor constructDrv excludeDrvArgNames extendDrvArgs
# override overrideDerivation transformDrv`.
#
# The obvious repair — read `__functionArgs` directly and test for membership —
# does not work either. On this nixpkgs `__functionArgs` carries 14 names and
# **neither `CGO_ENABLED` nor `env` is among them**, so membership cannot
# discriminate. Both candidate signals are absent.
#
# ── WHAT ACTUALLY DISCRIMINATES ─────────────────────────────────────────
#
# Build a trivial derivation each way and ask which one's value REACHES
# `drvAttrs.CGO_ENABLED`. Measured on this nixpkgs:
#
#     env.CGO_ENABLED = 0   -> { success = true;  value = 0; }   <- the contract
#     CGO_ENABLED     = 0   -> { success = false; }
#
# This is an eval-time probe: it evaluates derivation attributes and builds
# nothing, so it is IFD-free and costs no fetch.
#
# ── THE THIRD ARM IS A THROW, NOT A DEFAULT ─────────────────────────────
#
# If NEITHER form reaches the derivation, the contract is one this file has
# never seen. Choosing a side there is how a silent-wrong-answer ships: the
# build would succeed with CGO_ENABLED never set, which for a Go binary means
# cgo silently ON and a libc dependency in an image that claims to be static.
# So an unrecognised shape throws.
#
# TIER: eval-rejected. The probe answers correctly or refuses; it never guesses.
{ lib }:
let
  # probe :: buildGoModule -> "env" | "top-level" | throw
  #
  # `mk` must produce something evaluable without network: `vendorHash = null`
  # and a local src are enough, because only `.drvAttrs` is read.
  probe = buildGoModule:
    let
      mk = attrs: buildGoModule ({
        pname = "cgo-contract-probe";
        version = "0";
        src = ./.;
        vendorHash = null;
      } // attrs);

      reaches = attrs:
        let r = builtins.tryEval ((mk attrs).drvAttrs.CGO_ENABLED or null);
        in r.success && r.value != null;

      viaEnv = reaches { env.CGO_ENABLED = 0; };
      viaTop = reaches { CGO_ENABLED = 0; };
    in
    if viaEnv && !viaTop then "env"
    else if viaTop && !viaEnv then "top-level"
    else
      throw ''
        cgo-contract: cannot determine this nixpkgs' CGO_ENABLED contract.
          env.CGO_ENABLED reaches the derivation  = ${lib.boolToString viaEnv}
          CGO_ENABLED     reaches the derivation  = ${lib.boolToString viaTop}

        Both-or-neither means buildGoModule's shape changed again. REFUSING
        rather than picking a side: guessing wrong sets nothing, and a Go build
        with CGO_ENABLED unset links cgo — a libc dependency inside an image
        that claims to be static, which no later gate in this repo would catch.

        Re-measure against the resolved nixpkgs and extend this probe:
          nix eval --impure --json --expr 'let p = import <nixpkgs> {}; in
            builtins.attrNames p.buildGoModule'
      '';

  # placeCgo :: contract -> int -> attrs
  #
  # The single place the contract is spent. Call sites pass a value and never
  # spell either form themselves, so a future inversion is one edit here rather
  # than N edits across the builders.
  placeCgo = contract: value:
    if contract == "env" then { env.CGO_ENABLED = value; }
    else if contract == "top-level" then { CGO_ENABLED = value; }
    else throw "cgo-contract: placeCgo given an unknown contract '${toString contract}'";
in
{
  inherit probe placeCgo;
}
