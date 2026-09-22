# Home-manager helper: declaratively control an arbitrary macOS app's
# NSUserDefaults domain (~/Library/Preferences/<domain>.plist) from Nix.
#
# Fills a real gap. nix-darwin's `system.defaults.CustomUserPreferences`
# covers this at SYSTEM-activation time for `system.primaryUser`, but every
# blackmatter-<vendor-app> component (blackmatter-claude, and this one's
# reason for existing — blackmatter-gemini) ships a homeManagerModule, and a
# home-manager module cannot reach into `system.defaults` at all (`osConfig`
# is read-only from HM's side; there is no write path back to a darwinModule
# option). This is the HM-side equivalent: typed attrs in, a `home.activation`
# DAG entry out, keyed by domain — the same shape `darwin-service-helpers.nix`
# wraps for the system layer, one level down the stack.
#
# Independently reached for twice before this file existed: blackmatter-claude
# hand-rolls a JSON-file merge for Claude Desktop's config (a different SHAPE
# — a JSON file the app owns, not NSUserDefaults, so it stays its own thing);
# blackmatter-desktop's chrome module has a commented-out, abandoned attempt
# at exactly this for Chrome's `Preferences` file. Two independent asks for
# "merge typed settings into a macOS app's own preference store" is the
# extract-on-second-derivation bar (org CLAUDE.md, Convergent Evidence).
#
# The merge is NON-destructive: only the keys present in `settings` are
# written; anything the app itself writes at runtime (window position, auth
# tokens, feature flags, first-run state) is left alone. Implemented via
# `PlistBuddy -c Merge` at the plist ROOT, never `defaults import` (which
# replaces the whole domain) and never `defaults write` per-key (which loses
# nested structure without per-key type flags).
#
# Usage (in flake.nix):
#   modules.homeManager = import ./module {
#     userDefaultsHelpers = import "${substrate}/lib/hm-user-defaults-helpers.nix" { inherit lib; };
#   };
#
# Usage (in module/default.nix):
#   { userDefaultsHelpers }: { config, lib, pkgs, ... }:
#   let inherit (userDefaultsHelpers) mkUserDefaultsActivation; in
#   {
#     config = mkIf cfg.enable (mkUserDefaultsActivation {
#       name = "gemini-desktop";
#       domain = "com.google.GeminiMacOS";
#       homeDirectory = config.home.homeDirectory;
#       settings = cfg.preferences;
#     });
#   }
{ lib }:
with lib;
{
  # ─── NSUserDefaults domain merge (per-user, HM-activation-time) ───────
  # Returns: { home.activation.<name> = <dag entry>; } or {} when settings
  # is empty (no activation entry for a component with nothing to write).
  mkUserDefaultsActivation =
    {
      name,
      domain,
      homeDirectory,
      settings,
      runAfter ? [ "writeBoundary" ],
    }:
    let
      plist = "${homeDirectory}/Library/Preferences/${domain}.plist";
      json = builtins.toJSON settings;
    in
    {
      # ★ mkIf on the LEAF VALUE, never on the OUTER SHAPE (was
      # `optionalAttrs (settings != {}) { home.activation.${name} = {...}; }`
      # until 2026-09-22). That made the whole RETURNED ATTRSET's shape --
      # whether the `home` key exists at all -- conditional on `settings`.
      #
      # Every consumer of this file passes `settings = cfg.<something>`, an
      # option from the SAME module this return value becomes `config` for
      # (see this file's own usage doc above). The module system's
      # `pushDownProperties` (lib/modules.nix) has to inspect the SHAPE of a
      # module's `config` value to distribute it across option leaves, and
      # doing that for a shape-conditional value forces `settings != {}` --
      # i.e. forces `cfg.preferences`'s OWN merged value -- from INSIDE the
      # very merge pass that is computing it. Nix's blackhole detector
      # catches the self-reference: "infinite recursion encountered".
      #
      # Measured 2026-09-22, blackmatter-gemini's home.nix, exactly the
      # documented usage pattern: `nix eval` on a real fleet config throws
      # infinite recursion the instant `settings = cfg.preferences` is used
      # in `config = mkIf cfg.enable (mkUserDefaultsActivation {...})`.
      # `domain` (referenced identically) never triggered it -- it sits
      # inside the `then`-branch string that Nix's laziness never touched
      # once `settings != {}` short-circuited to false, so nothing about
      # this file's own PURE tests (which call the function directly, never
      # through `lib.evalModules`) could have caught it.
      #
      # The fix keeps the SAME "empty settings -> no activation entry"
      # guarantee (`mkIf false` contributes zero definitions to the option,
      # so an all-mkIf-false leaf is indistinguishable from never having
      # been set) while making the outer shape -- `home.activation.${name}`
      # existing as a key -- unconditional, so pushDownProperties never
      # needs `settings`'s value just to see that shape.
      home.activation.${name} = mkIf (settings != { }) (
        # Inlined `lib.hm.dag.entryAfter runAfter data` rather than calling
        # it: that function only exists on home-manager's lib-extended `lib`
        # (`modules/lib/stdlib-extended.nix`), not plain `nixpkgs.lib` — and
        # this file is deliberately pure-testable with plain `nixpkgs.lib`
        # (see hm/tests.nix). Home-manager's activation DAG resolver accepts
        # this `{ after; before; data; }` shape directly; it's what
        # `entryAfter` itself constructs.
        {
          after = runAfter;
          before = [ ];
          data = ''
            run mkdir -p "$(dirname "${plist}")"
            [ -f "${plist}" ] || /usr/bin/plutil -create xml1 "${plist}"
            managedJson="$(mktemp)"
            managedPlist="$managedJson.plist"
            printf '%s' ${escapeShellArg json} > "$managedJson"
            /usr/bin/plutil -convert xml1 -o "$managedPlist" "$managedJson"
            run /usr/libexec/PlistBuddy -c "Merge $managedPlist" "${plist}"
            rm -f "$managedJson" "$managedPlist"
            /usr/bin/killall cfprefsd >/dev/null 2>&1 || true
          '';
        }
      );
    };
}
