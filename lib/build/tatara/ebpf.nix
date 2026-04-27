# ============================================================================
# TATARA eBPF BUILDER — `(defbpf-program …)` → content-addressed `.bpf.o`
# ============================================================================
#
# Takes a `BpfProgramSpec` (declared in tatara-lisp via `(defbpf-program …)`,
# parsed by the host into JSON, handed to this builder as a Nix attrset)
# and produces a Nix derivation containing the compiled BPF object.
#
# The pipeline:
#
#   1. Resolve `source` per its shape (see `tatara-ebpf::codegen::SourceShape`):
#      - `*.rs`        → fed into a tiny aya-flavored cargo project that
#                        cross-compiles to bpfel-unknown-none.
#      - `*.bpf.o`     → fixed-output fetch / copy; verified by sha256.
#      - `*.tlisp:fn`  → routed through `tatara-domain-forge`'s codegen
#                        pass to produce `.rs`, then case 1.
#   2. Cross-compile with the rust-bpf toolchain pulled in via fenix.
#   3. Run `bpftool` against the output to confirm the program loads
#      symbolically (verifier check happens at runtime, not build).
#   4. Compute the BLAKE3 of the resulting object so the rest of the
#      tameshi attestation chain can pin it.
#
# This is the **substrate-side** of the eBPF surface. Author-side
# lives in `tatara-ebpf/`; arch-synthesizer wires them together at
# the IaC layer.
#
# ----------------------------------------------------------------------------
# USAGE — typical call site from a tatara-lisp program flake:
#
#   { inputs.substrate.url = "github:pleme-io/substrate";
#     outputs = { self, nixpkgs, substrate, ... }: let
#       system = "x86_64-linux";
#       pkgs = import nixpkgs { inherit system; };
#       buildBpf = import "${substrate}/lib/build/tatara/ebpf.nix" {
#         inherit pkgs;
#       };
#     in {
#       packages.${system}.drop-syn-flood = buildBpf {
#         spec = {
#           name = "drop_syn_flood";
#           kind = "xdp";
#           source = ./bpf/drop_syn.rs;
#           license = "GPL";
#         };
#       };
#     };
#   }
#
# ----------------------------------------------------------------------------
# STATUS — stub. Phase 1 lands the surface + content-addressing for
# precompiled-object sources. Phase 2 wires in the bpf-linker
# toolchain so `*.rs` sources compile in Nix without an external
# cargo run. Phase 3 adds the tatara-lisp → Rust codegen route. The
# typed surface here doesn't change — only the build-pass behavior.

{ pkgs, lib ? pkgs.lib }:

let
  # Resolve the source to a Nix store path. Pure — no I/O outside
  # the call to fetchurl when a URL is supplied.
  resolveSource = source:
    if builtins.isPath source then
      source
    else if builtins.isAttrs source && source ? url then
      pkgs.fetchurl {
        inherit (source) url sha256;
        name = source.name or "bpf-src";
      }
    else
      throw "tatara-ebpf: unsupported source shape — expected path or { url, sha256 }, got ${builtins.toJSON source}";

  classifyExt = path:
    let s = toString path; in
    if lib.hasSuffix ".rs" s then "rust"
    else if lib.hasSuffix ".bpf.o" s then "object"
    else if lib.hasSuffix ".o" s then "object"
    else throw "tatara-ebpf: unrecognized source extension `${s}`";

in

{
  # Spec mirrors `tatara_ebpf::BpfProgramSpec` 1-to-1. Keep field
  # names in sync — the synthesizer pipes JSON through this builder
  # without coercion.
  spec
}:

let
  resolved = resolveSource spec.source;
  shape = classifyExt resolved;
  drvName = "bpf-${spec.name}";
in

if shape == "object" then
  # Pre-compiled object — copy through, content-address.
  pkgs.runCommand drvName {} ''
    mkdir -p "$out"
    cp ${resolved} "$out/${spec.name}.bpf.o"
    # BLAKE3 fingerprint for the tameshi chain.
    ${pkgs.b3sum}/bin/b3sum "$out/${spec.name}.bpf.o" > "$out/${spec.name}.b3"
  ''
else
  # Rust source — Phase 2 will wire in bpf-linker + the rust-bpf
  # toolchain here. For now, produce a marker derivation that
  # documents the expected output path so consumers can build the
  # rest of their pipeline against a stable shape.
  pkgs.runCommand drvName {} ''
    mkdir -p "$out"
    cat > "$out/BUILD.md" <<EOF
    # tatara-ebpf builder — Phase 1 placeholder

    Spec: ${spec.name} (${spec.kind})
    Source: ${toString resolved}

    Phase 2 wiring (planned) cross-compiles via:

        cargo build \\
          --target bpfel-unknown-none \\
          --release \\
          -Z build-std=core

    The output will land at \`$out/${spec.name}.bpf.o\` with a
    sibling \`$out/${spec.name}.b3\` BLAKE3 fingerprint for the
    tameshi attestation chain.
    EOF
  ''
