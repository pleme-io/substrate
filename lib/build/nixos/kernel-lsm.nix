# mkKernelWithLsms — build a Linux kernel package set with named LSMs compiled in.
#
# Generic, parameterized builder for "I want a NixOS kernel with LSM X enabled."
# Reusable across SELinux, Landlock, eBPF-LSM, future LSM stacking work.
#
# The default `pkgs.linux` ships AppArmor + Landlock + Lockdown + Capability +
# YAMA + BPF as the LSM stack. Anything else (SELinux, SMACK, TOMOYO) requires
# rebuilding the kernel with extra `CONFIG_SECURITY_*` options. This helper is
# the canonical pleme-io substrate primitive for that.
#
# ── Usage ──────────────────────────────────────────────────────────────
#
#   # In a downstream flake (e.g. blackmatter-selinux):
#   {
#     outputs = inputs@{ self, nixpkgs, substrate, ... }:
#       let
#         mkKernelWithLsms = import "${substrate}/lib/build/nixos/kernel-lsm.nix" {
#           inherit nixpkgs;
#         };
#         selinuxKernelOverlay = mkKernelWithLsms {
#           lsms = [ "selinux" ];
#           # base kernel is pkgs.linuxKernel.kernels.linux_6_12 by default
#         };
#       in {
#         overlays.default = selinuxKernelOverlay;
#         # Consumers: `boot.kernelPackages = pkgs.linuxPackages_selinux;`
#       };
#   }
#
# ── Outputs ────────────────────────────────────────────────────────────
#
# Returns a single Nixpkgs overlay that exposes:
#
#   pkgs.linux_<lsmTag>           — the augmented kernel package
#   pkgs.linuxPackages_<lsmTag>   — the matching package set (modules, headers, …)
#
# `lsmTag` is the LSMs joined by underscores (e.g. `selinux`, `selinux_smack`).
#
# ── Knobs ──────────────────────────────────────────────────────────────
#
# baseKernel           function (pkgs → kernel pkg). Default returns
#                      `pkgs.linuxKernel.kernels.linux_6_12`. Override to pin
#                      a specific kernel version (`linux_6_6` LTS, etc.).
# lsms                 list of strings. Currently supported:
#                        "selinux"   — SELinux + auditd hooks
#                        "smack"     — SMACK
#                        "tomoyo"    — TOMOYO
#                        "apparmor"  — AppArmor (already on by default; included
#                                      for explicitness when stacking)
# enforceByDefault     bool. If true, sets CONFIG_DEFAULT_SECURITY_<LSM>=y.
#                      Defaults to false — the safe stance is "compile in,
#                      let the bootloader cmdline pick".
# extraConfig          attrset of `CONFIG_*` to merge on top of the LSM
#                      additions. Use `nixpkgs.lib.kernel.{yes,no,module}`.
# lsmOrder             optional explicit override for `CONFIG_LSM=`. If null
#                      (default), derived from `lsms` + the existing default
#                      stack (capability,landlock,lockdown,yama,bpf,…).
#
# ── LSM order matters ──────────────────────────────────────────────────
#
# The kernel runs LSM hooks in the order they appear in `CONFIG_LSM=`.
# `capability` MUST come first (it's the foundation; the SELinux hooks
# explicitly call into capability for fallback). The "major" LSMs (selinux,
# smack, apparmor, tomoyo) are mutually exclusive at runtime by default —
# only one can be the default. Stacking is supported via `lsm=...` cmdline
# but not via `CONFIG_DEFAULT_SECURITY_*`.

{ nixpkgs }:

{
  baseKernel ? (pkgs: pkgs.linuxKernel.kernels.linux_6_12),
  lsms,
  enforceByDefault ? false,
  extraConfig ? {},
  lsmOrder ? null,
}:

let
  lib = nixpkgs.lib;

  # Validate inputs early — Nix's error messages from the kernel build deep
  # inside structuredExtraConfig are unreadable; surface problems here.
  validLsms = [ "selinux" "smack" "tomoyo" "apparmor" ];
  assertLsms = lib.assertMsg
    (lib.all (l: lib.elem l validLsms) lsms)
    "kernel-lsm.nix: lsms must be a subset of ${lib.concatStringsSep ", " validLsms}; got ${lib.concatStringsSep ", " lsms}";
  assertNonEmpty = lib.assertMsg
    (lsms != [])
    "kernel-lsm.nix: lsms must be non-empty";
  assertSingleMajor = lib.assertMsg
    (!enforceByDefault || (lib.length (lib.filter (l: lib.elem l [ "selinux" "smack" "tomoyo" "apparmor" ]) lsms) <= 1))
    "kernel-lsm.nix: enforceByDefault=true requires exactly one major LSM (selinux | smack | tomoyo | apparmor); got ${lib.concatStringsSep ", " lsms}";

  lsmTag = lib.concatStringsSep "_" lsms;

  # ── LSM → CONFIG_* mapping ─────────────────────────────────────────
  # Each entry returns the structured-config additions needed to compile
  # that LSM into the kernel. Built against linux 6.x option names; older
  # kernels may need adjustments (this is why baseKernel is parameterized).
  lsmConfig = lsm:
    let
      yes = nixpkgs.lib.kernel.yes;
      no = nixpkgs.lib.kernel.no;
    in
    {
      selinux = {
        SECURITY = yes;
        AUDIT = yes;
        AUDITSYSCALL = yes;
        SECURITY_NETWORK = yes;
        SECURITY_SELINUX = yes;
        SECURITY_SELINUX_BOOTPARAM = yes;
        SECURITY_SELINUX_DEVELOP = yes;
        SECURITY_SELINUX_AVC_STATS = yes;
        SECURITY_SELINUX_CHECKREQPROT_VALUE = no;  # cleaner default; legacy compat off
        SECURITY_SELINUX_SIDTAB_HASH_BITS = nixpkgs.lib.kernel.freeform "9";
        SECURITY_SELINUX_SID2STR_CACHE_SIZE = nixpkgs.lib.kernel.freeform "256";
        # Networking labels — needed for any meaningful network policy
        NETLABEL = yes;
        NETWORK_SECMARK = yes;
        # Tmpfs xattr support — needed for /tmp etc. labeling
        TMPFS_XATTR = yes;
        # Enable extended attributes on the FS layer
        EXT4_FS_SECURITY = yes;
        # Process integrity — pairs naturally with SELinux on enforcing hosts
        INTEGRITY = yes;
      };
      smack = {
        SECURITY = yes;
        SECURITY_SMACK = yes;
        SECURITY_SMACK_BRINGUP = no;
        SECURITY_SMACK_NETFILTER = yes;
        NETLABEL = yes;
      };
      tomoyo = {
        SECURITY = yes;
        SECURITY_TOMOYO = yes;
      };
      apparmor = {
        SECURITY = yes;
        SECURITY_APPARMOR = yes;
        # Already enabled in default nixpkgs kernel; including for explicit
        # stacking declarations.
      };
    }.${lsm};

  # Merge all selected LSM configs.
  mergedLsmConfig = lib.foldl' (acc: lsm: acc // (lsmConfig lsm)) {} lsms;

  # ── Default LSM stack order ────────────────────────────────────────
  # NixOS default: capability,landlock,lockdown,yama,integrity,apparmor,bpf
  # We prepend the requested LSMs after capability (which must be first)
  # and before the existing tail. Operators can override with `lsmOrder`.
  defaultStack = [ "capability" ] ++ lsms ++ [ "landlock" "lockdown" "yama" "integrity" "bpf" ];
  effectiveLsmOrder =
    if lsmOrder != null
    then lsmOrder
    else lib.unique defaultStack;

  lsmCmdlineConfig = {
    LSM = nixpkgs.lib.kernel.freeform (lib.concatStringsSep "," effectiveLsmOrder);
  };

  # ── Default-security setting (only when enforceByDefault) ──────────
  defaultSecurityConfig =
    if enforceByDefault then {
      DEFAULT_SECURITY_SELINUX = if lib.elem "selinux" lsms then nixpkgs.lib.kernel.yes else nixpkgs.lib.kernel.no;
      DEFAULT_SECURITY_SMACK = if lib.elem "smack" lsms then nixpkgs.lib.kernel.yes else nixpkgs.lib.kernel.no;
      DEFAULT_SECURITY_TOMOYO = if lib.elem "tomoyo" lsms then nixpkgs.lib.kernel.yes else nixpkgs.lib.kernel.no;
      DEFAULT_SECURITY_APPARMOR = if lib.elem "apparmor" lsms then nixpkgs.lib.kernel.yes else nixpkgs.lib.kernel.no;
      DEFAULT_SECURITY_DAC = nixpkgs.lib.kernel.no;
    } else {};

  finalStructuredConfig =
    mergedLsmConfig
    // lsmCmdlineConfig
    // defaultSecurityConfig
    // extraConfig;

in

# Force the assertions before producing the overlay.
assert assertNonEmpty;
assert assertLsms;
assert assertSingleMajor;

final: prev:
let
  baseKernelPkg = baseKernel prev;
  customKernel = baseKernelPkg.override {
    structuredExtraConfig = finalStructuredConfig;
    # Mark the kernel with a recognizable suffix so generations show it.
    extraMeta = (baseKernelPkg.meta.extraMeta or {}) // {
      description = "${baseKernelPkg.meta.description or "Linux kernel"} (with ${lib.concatStringsSep "+" lsms} LSM)";
    };
  };
in
{
  "linux_${lsmTag}" = customKernel;
  "linuxPackages_${lsmTag}" = prev.linuxPackagesFor customKernel;
}
