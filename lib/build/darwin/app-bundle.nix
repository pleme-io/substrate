# mkDarwinAppBundle — typed macOS `.app` bundle builder (COMPOUNDING substrate helper)
#
# Every fleet GUI app (mado, namimado, escriba, hibiki, …) installs today as a
# bare CLI binary in PATH — invisible to Spotlight, no icon, no Launchpad entry.
# This helper turns any built binary + an SVG icon into a real, double-clickable,
# Spotlight-/Launchpad-/Dock-discoverable macOS `.app` bundle.
#
# Per the PRIME DIRECTIVE: this is the substrate-level pattern, NOT a per-app
# one-off. A consumer adds one `mkDarwinAppBundle { … }` call.
#
# Pipeline (proven on darwin / cid):
#   iconSvg --resvg--> 10 canonical iconset PNGs --png2icns--> <name>.icns
#   (png2icns from pkgs.libicns is the pure, sandbox-safe path; the system
#    `/usr/bin/iconutil` is NOT reachable from the nix store, so we never use
#    it. png2icns assembles a valid multi-resolution Mac OS X .icns directly.)
#
# Signature:
#   mkDarwinAppBundle {
#     pkgs;                  # darwin nixpkgs instance
#     name;                  # bundle display name, e.g. "Mado" → Mado.app
#     exe;                   # package whose bin/<exe-basename> is the binary,
#                            #   OR a "<pkg>/bin/<basename>" string path
#     iconSvg;               # path to the 1024×1024 source SVG
#     bundleId;              # CFBundleIdentifier, e.g. "io.pleme.mado"
#     version ? "0.1.0";     # CFBundleShortVersionString
#     exeName ? <derived>;   # basename of the binary in MacOS/ — defaults to
#                            #   lowercased name; override when the real binary
#                            #   name differs (e.g. name="Mado", exeName="mado")
#     minSystemVersion ? "11.0";
#     extraPlist ? {};       # merged into Info.plist (typed attrset → plist)
#   }
# → derivation producing <name>.app/Contents/{MacOS,Resources,Info.plist,PkgInfo}
{
  # The bundle builder. Pure where possible; the one impurity-adjacent reach is
  # the icns generation, which uses only store tools (resvg + png2icns) and is
  # therefore fully reproducible in-sandbox.
  mkDarwinAppBundle = {
    pkgs,
    name,
    exe,
    iconSvg,
    bundleId,
    version ? "0.1.0",
    exeName ? pkgs.lib.toLower name,
    minSystemVersion ? "11.0",
    extraPlist ? {},
  }: let
    lib = pkgs.lib;

    # Resolve the binary path inside the bundle. Accept either a package
    # derivation (use $pkg/bin/$exeName) or a literal path string.
    exeIsString = builtins.isString exe;
    binSource =
      if exeIsString
      then exe
      else "${exe}/bin/${exeName}";

    # ------------------------------------------------------------------------
    # Info.plist — typed attrset → plist via lib.generators.toPlist.
    # NO hand-strings: the plist is a value, rendered by the canonical
    # serializer (per the ★★ TYPED EMISSION rule — toPlist is the typed AST
    # renderer for the plist target syntax).
    # ------------------------------------------------------------------------
    plistAttrs =
      {
        CFBundleName = name;
        CFBundleDisplayName = name;
        CFBundleIdentifier = bundleId;
        CFBundleExecutable = exeName;
        CFBundleIconFile = "${name}.icns";
        CFBundlePackageType = "APPL";
        CFBundleShortVersionString = version;
        CFBundleVersion = version;
        CFBundleInfoDictionaryVersion = "6.0";
        NSHighResolutionCapable = true;
        LSMinimumSystemVersion = minSystemVersion;
      }
      // extraPlist;

    infoPlist = lib.generators.toPlist {escape = true;} plistAttrs;

    # The 10 standard macOS iconset slots. The "@2x" slots are the same pixel
    # dimension as the next size up — we render each distinct pixel size once
    # and reuse it. png2icns selects icns types by pixel size, so passing the
    # set of distinct sizes is sufficient + canonical.
    iconSizes = [16 32 64 128 256 512 1024];
  in
    pkgs.runCommandLocal "${name}.app" {
      nativeBuildInputs = [pkgs.resvg pkgs.libicns];
      inherit infoPlist;
      passAsFile = ["infoPlist"];
    } ''
      app="$out/${name}.app"
      contents="$app/Contents"
      mkdir -p "$contents/MacOS" "$contents/Resources"

      # --- binary ---
      cp ${binSource} "$contents/MacOS/${exeName}"
      chmod +x "$contents/MacOS/${exeName}"

      # --- icns from SVG (resvg → PNGs → png2icns) ---
      ${lib.concatMapStringsSep "\n" (sz: ''
        resvg -w ${toString sz} -h ${toString sz} ${iconSvg} "icon_${toString sz}.png"
      '') iconSizes}
      png2icns "$contents/Resources/${name}.icns" \
        ${lib.concatMapStringsSep " " (sz: "icon_${toString sz}.png") iconSizes}

      # --- Info.plist (typed → plist) ---
      cp "$infoPlistPath" "$contents/Info.plist"

      # --- PkgInfo ---
      printf 'APPL????' > "$contents/PkgInfo"
    '';
}
