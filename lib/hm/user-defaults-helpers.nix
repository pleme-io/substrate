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
    optionalAttrs (settings != { }) {
      home.activation.${name} =
        let
          plist = "${homeDirectory}/Library/Preferences/${domain}.plist";
          json = builtins.toJSON settings;
        in
        # Inlined `lib.hm.dag.entryAfter runAfter data` rather than calling it:
        # that function only exists on home-manager's lib-extended `lib`
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
        };
    };
}
