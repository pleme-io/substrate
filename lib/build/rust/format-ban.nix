# pleme-io typed-emission enforcement substrate helper.
#
# Canonical: https://github.com/pleme-io/theory/blob/main/TYPED-EMISSION.md
# Pillar 12 operationalized at the Rust language level.
#
# Surface (call via `import ./format-ban.nix { inherit pkgs; }`):
#
#   clippyTomlPath    : path to the reference clippy.toml in this directory
#   clippyTomlSnippet : the canonical clippy.toml content as a string
#   withFormatBan src : copies src and ensures clippy.toml at the workspace
#                       root carries the disallowed-macros entry; appends
#                       to existing clippy.toml when one is present
#   auditFormatBan src: ripgrep-based audit derivation; produces
#                       $out/per-file-counts.txt and $out/summary.txt
#                       reporting format!() call sites per file
#
# The hard enforcement gate is `cargo clippy -- -D warnings` against a
# workspace that has the disallowed-macros entry in its clippy.toml.
# `withFormatBan` is the substrate-side way to ensure the entry is
# present without each repo committing the same clippy.toml by hand.
# `auditFormatBan` produces the migration map for in-flight rollout.

{ pkgs, ... }:

let
  clippyTomlPath = ./format-ban.clippy.toml;
  clippyTomlSnippet = builtins.readFile clippyTomlPath;

  withFormatBan = src:
    pkgs.runCommand "with-format-ban" { } ''
      cp -r ${src} $out
      chmod -R u+w $out
      if [ -f $out/clippy.toml ]; then
        if ! grep -q '"std::format"' $out/clippy.toml; then
          {
            echo ""
            echo "# Appended by substrate's withFormatBan (pleme-io/theory/TYPED-EMISSION.md)."
            cat ${clippyTomlPath}
          } >> $out/clippy.toml
        fi
      else
        cp ${clippyTomlPath} $out/clippy.toml
      fi
    '';

  auditFormatBan = src:
    pkgs.runCommand "audit-format-ban" {
      nativeBuildInputs = [ pkgs.ripgrep ];
    } ''
      mkdir -p $out
      cd ${src}
      # Per-file count of format!() occurrences. --no-ignore so we still
      # see files inside .gitignore'd build outputs (target/, dist/, etc.)
      # — but exclude those explicitly via -g.
      rg --no-ignore -t rust -c 'format!\(' \
         -g '!target/' -g '!.git/' -g '!node_modules/' -g '!dist/' \
         . > $out/per-file-counts.txt 2>/dev/null || true
      sort -t: -k2 -rn $out/per-file-counts.txt > $out/per-file-counts.sorted.txt
      total=$(rg --no-ignore -t rust 'format!\(' \
                -g '!target/' -g '!.git/' -g '!node_modules/' -g '!dist/' \
                . 2>/dev/null | wc -l)
      files=$(wc -l < $out/per-file-counts.txt)
      {
        echo "format!() audit (pleme-io/theory/TYPED-EMISSION.md)"
        echo "  Total call sites: $total"
        echo "  Files with at least one format!(): $files"
        echo ""
        echo "Top 30 hotspot files:"
        head -30 $out/per-file-counts.sorted.txt
      } > $out/summary.txt
    '';
in
{
  inherit clippyTomlPath clippyTomlSnippet withFormatBan auditFormatBan;
}
