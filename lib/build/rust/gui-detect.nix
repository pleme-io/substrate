# Does this crate need a window system at RUNTIME? — derived, never declared.
#
# ★ WHY THIS EXISTS. substrate's `rust.tool` builds every linux artifact as a
# **static musl** binary (`mkLinuxStaticPkgs`, tool-release.nix). That is the
# right default for a deploy artifact and it is *structurally impossible* for a
# GUI app: winit/wgpu/smithay resolve `libwayland-client.so.0`,
# `libvulkan.so.1`, `libGL.so.1` and `libxkbcommon.so.0` through **`dlopen` at
# startup**, and a static binary has no dynamic loader to do it with. The
# library is present on the machine and the binary cannot reach it.
#
# The failure is a RUNTIME panic, not a build error, so nothing catches it:
#
#     failed to create event loop: WaylandError(Connection(NoWaylandLib))
#
# Measured 2026-08-21: `tobira` built clean for `x86_64-linux`, `file` reported
# "statically linked", and it died on that line on plo — while
# `libwayland-client.so.0` sat in the store the whole time.
#
# ★ WHY AUTODETECTION RATHER THAN A FLAG. The fix already existed and did not
# reach anybody. `eframe.nix::mkLinuxGuiWrapper` + `linuxRuntimeLibs` have been
# in substrate since 2026-08-18, and that file's own comment records the
# measurement: `mado` was the ONLY fleet GUI flake carrying such a wrap — hand
# -rolled, with a hand-copied duplicate of the library list — and *"every other
# pleme-io GUI app … could not run on Linux at all."* A fix that each repo must
# remember to apply is a fix that 12 repos did not apply. This makes the
# builder decide, so the next GUI app inherits the answer instead of
# rediscovering the panic.
#
# ★ WHAT IT READS, AND WHY THAT IS SOUND. `Cargo.lock` — the resolved
# dependency closure, IFD-free (`builtins.fromTOML` over a source path, no
# derivation is built to answer the question). Lock v3+ records a per-package
# `dependencies` array, so when the root crate is known the answer is a
# **reachability** question over that graph, not a whole-file grep: a workspace
# whose GUI member sits beside a headless CLI classifies each correctly.
#
# ★ **THE KNOWN LIMIT, AND IT IS NOT SMALL: `Cargo.lock` IS FEATURE-BLIND.**
# The lock records the union of every optional dependency any feature could
# turn on, not the set this build actually enables. A crate with a `nested`
# or `dev-gui` feature that pulls winit therefore reads as GUI even when the
# shipped binary is built without it.
#
# That is not hypothetical and it was caught by the first repo it hit. `omoya`
# carries a winit-backed `nested` backend for developing on a machine that
# already has a session; its SHIPPED binary links libc, libm and libgcc_s and
# nothing else — measured on rio with `ldd`, on the artifact rather than the
# wrapper. Wrapping it would drag five C libraries back into a closure that
# had deliberately shed them, which is the FALSE-POSITIVE direction of this
# detector doing real damage rather than merely being conservative.
#
# So a crate whose window-system dependency is feature-gated OFF in its
# shipped build sets `gui = false` and says why. There is no lock-only fix:
# feature resolution needs the metadata this file deliberately does not
# resolve, and guessing from feature NAMES would be worse than asking.
#
# ★ THE DENOMINATOR IS INSIDE THE VERDICT (`scanned`, `mode`). A detector that
# silently found nothing and a detector that found nothing to look at return
# the same `isGui = false`, and the first is a defect while the second is a
# fact. `mode = "absent"` says which. Callers that gate on this must read
# `scanned`, exactly as `go-cgo-contract-witness` and `go-directive-satisfiable`
# carry theirs (nix repo CLAUDE.md).
{ lib }:

let
  # ── The catalog ────────────────────────────────────────────────────────
  # Two classes, kept apart because they answer different questions.
  #
  # WINDOW SYSTEM: the crate opens a window / owns a surface. Its presence is
  # what makes an artifact a GUI artifact.
  windowSystemCrates = [
    "winit"      # the fleet's window backend (mado, tobira, escriba, asobi…)
    "eframe"     # egui's app shell — winit + a renderer
    "glutin"     # GL context creation
    "sdl2"
    "tao"        # tauri's winit fork
    "iced"
    "slint"
    "smithay"    # the other direction: we ARE the compositor (omoya)
    "softbuffer" # a CPU surface still needs the window system to present it
    "gtk4"
  ];

  # RUNTIME DLOPEN: the crate does not open a window but *does* resolve a
  # driver `.so` at startup, which a static binary equally cannot do. Kept
  # separate so a future reader can see that including them was deliberate.
  #
  # Measured 2026-08-21 across 610 fleet `Cargo.lock` files: neither `ash` nor
  # `glow` EVER appears without a window-system crate, so today these arms add
  # nothing. They are here for the headless-GPU case (a compute-only wgpu/ash
  # consumer) which would otherwise hit the identical panic with no window in
  # sight.
  runtimeDlopenCrates = [
    "wgpu"       # dlopens libvulkan / libGL through its backends
    "ash"        # vulkan bindings — `dlopen("libvulkan.so.1")`
    "glow"       # GL bindings — dlopens libGL
  ];

  guiCrates = windowSystemCrates ++ runtimeDlopenCrates;

  # ★ DELIBERATELY NOT IN THE CATALOG — each of these is a false positive that
  # was measured, not imagined:
  #
  #   wayland-client / x11rb / x11-dl — a CLIPBOARD pulls these. Six fleet
  #   repos (hasami, hikidashi, kura, mirante, reedline, caixa-copypasta) carry
  #   `wayland-client` via `arboard`/`copypasta`/`wl-clipboard-rs` and open no
  #   window at all. Keying on them would have misclassified all six and taken
  #   their static-musl artifact away for nothing.
  #
  #   raw-window-handle — a types-only crate a headless library may depend on
  #   to *describe* a handle it never creates.

  # ── The lock ───────────────────────────────────────────────────────────
  readLock = src:
    let p = src + "/Cargo.lock";
    in if builtins.pathExists p
       then (builtins.fromTOML (builtins.readFile p)).package or [ ]
       else null;

  # `dependencies` entries are `"name"` or `"name version"`.
  depName = d: lib.head (lib.splitString " " d);

  # name -> the UNION of every version's dependency list.
  #
  # A lock may carry two versions of one crate. Keying by name alone would
  # keep whichever `listToAttrs` saw first and silently drop the other's edges;
  # unioning over-approximates instead, which is the safe direction for a
  # presence question — it can only ever find MORE, never miss.
  depIndex = packages:
    lib.foldl'
      (acc: p: acc // { ${p.name} = (acc.${p.name} or [ ]) ++ (p.dependencies or [ ]); })
      { }
      packages;

  # Every crate reachable from `root`.
  reachable = index: root:
    builtins.map (e: e.key) (builtins.genericClosure {
      startSet = [ { key = root; } ];
      operator = { key }: builtins.map (d: { key = depName d; }) (index.${key} or [ ]);
    });

  # A workspace-local package has no `source` (it is not from a registry).
  localPackages = packages: builtins.filter (p: !(p ? source)) packages;

in
rec {
  inherit windowSystemCrates runtimeDlopenCrates guiCrates;

  # detect :: { src, packageName ? null } -> verdict
  #
  # verdict = {
  #   isGui   : bool   — the answer
  #   matched : [str]  — WHICH crates decided it (empty when false)
  #   scanned : int    — the denominator; 0 means nothing was examined
  #   mode    : "closure" | "lock" | "absent"
  #   root    : str | null
  # }
  detect = { src, packageName ? null }:
    let
      packages = readLock src;
    in
    if packages == null || packages == [ ] then {
      isGui = false;
      matched = [ ];
      scanned = 0;
      mode = "absent";
      root = null;
    } else
      let
        index = depIndex packages;
        locals = localPackages packages;
        # A root is usable only if the lock actually contains it.
        namedRoot =
          if packageName != null && index ? ${packageName} then packageName
          else if packageName == null && builtins.length locals == 1
          then (builtins.head locals).name
          else null;
        names =
          if namedRoot != null
          then reachable index namedRoot
          else builtins.map (p: p.name) packages;
        matched = lib.sort (a: b: a < b)
          (builtins.filter (c: builtins.elem c names) guiCrates);
      in {
        isGui = matched != [ ];
        inherit matched;
        scanned = builtins.length names;
        mode = if namedRoot != null then "closure" else "lock";
        root = namedRoot;
      };

  # resolve :: { src, packageName ? null, gui ? null } -> verdict
  #
  # `gui` is the typed override, and it exists for exactly one honest reason:
  # in `lock` mode the verdict is a statement about the whole workspace, so a
  # headless CLI sharing a lock with a GUI member is classified GUI. That
  # misclassification is CONSERVATIVE — the binary still runs, it just loses
  # its static-musl artifact — but losing static-musl matters for a deploy
  # tool, and `gui = false` is how you say so in one place instead of forking
  # the builder.
  resolve = { src, packageName ? null, gui ? null }:
    if gui == null then detect { inherit src packageName; }
    else {
      isGui = gui;
      matched = [ ];
      scanned = 0;
      mode = "explicit";
      root = packageName;
    };

  # One line for a build log / an error message. Never a bare boolean: the
  # reader needs to know what was examined before believing the answer.
  explain = v:
    if v.mode == "absent"
    then "gui-detect: NO Cargo.lock was read (scanned 0) — treating as non-GUI"
    else if v.mode == "explicit"
    then "gui-detect: gui = ${if v.isGui then "true" else "false"} (set explicitly, not derived)"
    else if v.isGui
    then "gui-detect: GUI (${builtins.concatStringsSep ", " v.matched}) "
         + "over ${builtins.toString v.scanned} crates [${v.mode}"
         + lib.optionalString (v.root != null) " from ${v.root}" + "]"
    else "gui-detect: not a GUI crate — ${builtins.toString v.scanned} crates examined [${v.mode}]";
}
