# eframe / egui GUI-application build kit.
#
# The reusable native-dependency surface for a Rust GUI app built on
# eframe/egui (winit + wgpu / glow). Before this helper, substrate carried
# ZERO egui/wgpu/X11/wayland/vulkan knowledge — every GUI Rust app (fleet OR
# external) had to hand-list the window-system libraries in its own flake and
# get the (surprisingly fiddly) nixpkgs attribute names right. This is the one
# place that knowledge lives.
#
# Platform behaviour:
#   • macOS   — wgpu selects Metal; the Apple SDK (via util/darwin.nix
#               mkDarwinBuildInputs) is all that is required. No X11/wayland/
#               vulkan, no runtime dlopen dance.
#   • Linux   — winit/wgpu link X11 + wayland + vulkan + GL + fontconfig at
#               build time and dlopen libvulkan/libGL/libwayland at RUN time,
#               so the runtime libs are (a) put on LD_LIBRARY_PATH for the dev
#               shell and (b) rpath-stamped into the built binary via
#               autoPatchelfHook + runtimeDependencies.
#
# Attribute-name note: the X libraries use the TOP-LEVEL lowercase attrs
# (libx11, libxcb, libxcb-util, …). Recent nixpkgs promoted these out of the
# now-deprecated `xorg.*` set; the top-level names are the canonical,
# warning-free path and the only ones present under config.allowAliases=false.
# `xcbutil` in particular is only a deprecated alias for `libxcb-util`.
#
# Usage (standalone import — the external-repo / quick path):
#   eframe = import "${substrate}/lib/build/rust/eframe.nix" { inherit pkgs; };
#   packages.default   = eframe.mkPackage  { pname = "asteride"; src = ./.; };
#   devShells.default  = eframe.mkDevShell { extraPackages = [ pkgs.just ]; };
#
# Usage (via substrate.lib.${system}):
#   eframe = substrate.lib.${system}.eframe;
#
# TIER-HONESTY: mkPackage builds via nixpkgs `rustPlatform.buildRustPackage`
# (importCargoLock vendoring) — the reliable, gen-free path that works for any
# Cargo project and for external repos that do not carry a committed
# `Cargo.build-spec.json`. The crate2nix/gen (lockfile-builder) path remains
# the higher-leverage pleme-io-internal SDLC route for first-party GUI repos
# once a build-spec is committed; this helper deliberately trades that
# per-crate caching for zero-ceremony portability. Extend here (not per repo)
# when a new GUI native-dep class appears.
{ pkgs }:
let
  lib = pkgs.lib;
  inherit (pkgs.stdenv) isLinux isDarwin;

  inherit ((import ../../util/darwin.nix)) mkDarwinBuildInputs;

  # Linux X11 + wayland + vulkan + GL + font stack for winit/wgpu/glow.
  linuxRuntimeLibs = lib.optionals isLinux (with pkgs; [
    libGL
    vulkan-loader
    wayland
    libxkbcommon
    libx11
    libxcursor
    libxi
    libxrandr
    libxcb
    libxcb-util
    fontconfig
    freetype
    expat
  ]);

  # Libraries the GUI links (all platforms folded).
  eframeBuildInputs = mkDarwinBuildInputs pkgs ++ linuxRuntimeLibs;

  # pkg-config finds the x11/wayland/fontconfig `.pc` files on Linux; it is
  # cheap and harmless on darwin, so it is unconditional.
  eframeNativeBuildInputs = [ pkgs.pkg-config ];

  # The subset that must also be present at RUNTIME (dlopen'd on Linux).
  runtimeLibs = linuxRuntimeLibs;

  ldLibraryPath = lib.makeLibraryPath runtimeLibs;

  # ── The RUNTIME wrap ────────────────────────────────────────────────────
  # `mkPackage` sets `runtimeDependencies`, which is right for a package this
  # kit BUILDS. It does nothing for a binary built elsewhere — e.g. substrate's
  # `host-tool` variant, or any app whose flake predates this kit — and those
  # binaries dlopen libwayland/libvulkan/libxkbcommon at startup and die if they
  # cannot resolve them.
  #
  # That is not hypothetical. Measured 2026-08-18: `mado` was the ONLY GUI flake
  # in the fleet carrying such a wrap, hand-rolled, with a hand-copied duplicate
  # of `linuxRuntimeLibs` and a comment admitting the hazard — "keep the two in
  # step if that grows". Every other pleme-io GUI app (escriba, tobira, shirase,
  # tanken, shashin, hasami, kagi, fumi, hibiki, myaku, nami, namimado) had ZERO
  # hits for wrapProgram/vulkan-loader/libxkbcommon and therefore could not run
  # on Linux at all.
  #
  # So this exists to make the second copy unnecessary rather than to make it
  # tidy: it wraps against `ldLibraryPath` above, so there is exactly ONE list.
  # A no-op on darwin, where the libs are in the SDK and the wrap is meaningless.
  mkLinuxGuiWrapper =
    {
      package,
      name ? null,
      mainProgram ? null,
    }:
    if !isLinux then
      package
    else
      pkgs.symlinkJoin {
        name = if name != null then name else "${package.pname or package.name or "gui"}-linux-gui";
        paths = [ package ];
        nativeBuildInputs = [ pkgs.makeWrapper ];
        postBuild = ''
          for f in $out/bin/*; do
            [ -L "$f" ] || continue
            wrapProgram "$f" --prefix LD_LIBRARY_PATH : ${ldLibraryPath}
          done
        '';
        meta =
          (package.meta or { })
          // lib.optionalAttrs (mainProgram != null) { inherit mainProgram; };
      };

  # Read a version out of a Cargo.toml, supporting both a plain package and a
  # virtual-workspace root (`[workspace.package] version = …`).
  readCargoVersion = src:
    let t = builtins.fromTOML (builtins.readFile (src + "/Cargo.toml"));
    in t.package.version or (t.workspace.package.version or null);

  mkDevShell =
    { extraPackages ? [ ]
    , extraBuildInputs ? [ ]
    , toolchain ? [
        pkgs.cargo
        pkgs.rustc
        pkgs.rustfmt
        pkgs.clippy
        pkgs.rust-analyzer
      ]
    }:
    pkgs.mkShell {
      nativeBuildInputs = eframeNativeBuildInputs;
      buildInputs = eframeBuildInputs ++ toolchain ++ extraPackages ++ extraBuildInputs;
      # eframe/wgpu dlopen libvulkan/libGL/libwayland at runtime on Linux.
      LD_LIBRARY_PATH = ldLibraryPath;
    };

  mkPackage =
    { pname
    , src
    , version ? null
    , cargoLock ? { lockFile = src + "/Cargo.lock"; }
    , extraBuildInputs ? [ ]
    , extraNativeBuildInputs ? [ ]
    , cargoBuildFlags ? [ "-p" pname ]
    , doCheck ? false
    , meta ? { }
    , extraDrvAttrs ? { }
    }:
    let
      resolvedVersion =
        if version != null then version
        else
          let v = readCargoVersion src; in
          if v != null then v
          else throw "eframe.mkPackage: no version in ${toString src}/Cargo.toml; pass version = \"x.y.z\"";
    in
    pkgs.rustPlatform.buildRustPackage ({
      inherit pname src cargoLock doCheck cargoBuildFlags;
      version = resolvedVersion;
      buildInputs = eframeBuildInputs ++ extraBuildInputs;
      nativeBuildInputs = eframeNativeBuildInputs
        ++ extraNativeBuildInputs
        ++ lib.optionals isLinux [ pkgs.autoPatchelfHook ];
      # On Linux the loaders are dlopen'd, so the plain closure would miss
      # them; stamp them into the binary's rpath. Ignored on darwin.
      runtimeDependencies = runtimeLibs;
      meta = { platforms = lib.platforms.unix; } // meta;
    } // extraDrvAttrs);
in
{
  inherit
    eframeBuildInputs
    eframeNativeBuildInputs
    runtimeLibs
    linuxRuntimeLibs
    ldLibraryPath
    readCargoVersion
    mkDevShell
    mkPackage
    mkLinuxGuiWrapper;
}
