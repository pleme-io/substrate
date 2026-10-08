{ }:
{
  asCheck = pkgs:
    let
      inherit (pkgs) lib;
      retention = import ../rlib-dep-retention.nix { inherit lib; };
      builderSrc = builtins.readFile ../lockfile-builder.nix;
      wired = lib.hasInfix "rlibDepRetention.postInstallFor (map depFor deps.runtime)" builderSrc;
      srcA = pkgs.writeTextDir "src/lib.rs" "pub fn a() -> u32 { 1 }\n";
      srcB = pkgs.writeTextDir "src/lib.rs" "pub fn b() -> u32 { retention_a::a() + 1 }\n";
      crateA = pkgs.buildRustCrate {
        crateName = "retention_a";
        version = "0.1.0";
        src = srcA;
      };
      crateB = pkgs.buildRustCrate {
        crateName = "retention_b";
        version = "0.1.0";
        src = srcB;
        dependencies = [ crateA ];
        postInstall = retention.postInstallFor [ crateA ];
      };
    in
    assert lib.assertMsg wired "lockfile-builder.nix no longer appends rlibDepRetention.postInstallFor to each crate's postInstall";
    pkgs.runCommand "rust-rlib-dep-retention"
      {
        exportReferencesGraph = [ "graph" crateB.lib ];
        libA = crateA.lib;
        libB = crateB.lib;
      } ''
      grep -qxF "$libA" "$libB/nix-support/${retention.fileName}"
      grep -qxF "$libA" graph
      touch $out
    '';
}
