{ }:
{
  asCheck = pkgs:
    let
      inherit (pkgs) lib;
      overrides = (import ../pleme-crate-overrides.nix) pkgs.stdenv.hostPlatform.rust.rustcTarget;
      crate = { pname, version, hash, edition ? null, dependencies ? [ ], features ? [ ], crateOverrides ? pkgs.defaultCrateOverrides }:
        (pkgs.buildRustCrate.override { defaultCrateOverrides = crateOverrides; }) {
          crateName = pname;
          inherit version edition dependencies features;
          src = pkgs.fetchCrate { inherit pname version hash; };
        };
      anyhow = crate { pname = "anyhow"; edition = "2018"; version = "1.0.98"; hash = "sha256-+du6qK1WA0S9u/emeaJ3hjpv9siu4gq+mrdaj2Pp8nU="; features = [ "std" ]; };
      idArena = crate { pname = "id-arena"; version = "2.2.1"; hash = "sha256-24grPz0zLFirzF+HLDn8wkhlq8wzyEvfs6DalcmEMvs="; features = [ "std" ]; };
      equivalent = crate { pname = "equivalent"; version = "1.0.2"; hash = "sha256-uTefUNYrF+m59vVl+AHTdkPVQ6x/qC2rCfMwrE/71VU="; };
      hashbrown = crate { pname = "hashbrown"; edition = "2021"; version = "0.15.2"; hash = "sha256-hXb2B/wO6tE78BMU33CEnjt8RPclrUqrDpuPZ9zUars="; };
      indexmap = crate { pname = "indexmap"; edition = "2021"; version = "2.7.1"; hash = "sha256-3ciXe7oRIz6C7+lZQnz3bNTBryF8Xmlvjf5KK/6xIeA="; features = [ "std" ]; dependencies = [ equivalent hashbrown ]; };
      log = crate { pname = "log"; edition = "2021"; version = "0.4.27"; hash = "sha256-4fIxuGEIkLd8ohKzqWcqixlmp5MP7nk2M3R1OmNHZZ0="; };
      semver = crate { pname = "semver"; edition = "2018"; version = "1.0.26"; hash = "sha256-nNWNjnnkjdJ6sOlUy5fyTfcoocOTG6ypPk7k9InJhmo="; };
      unicodeXid = crate { pname = "unicode-xid"; version = "0.2.6"; hash = "sha256-915w07Y91OmWx2Irp3gm3oMvYxwF5VNvyb/csgZocGc="; };
      witParser = crate {
        pname = "wit-parser";
        edition = "2021";
        version = "0.236.1";
        hash = "sha256-6AQWjL7Ttks9MmiljruQhfU4aWU6RxFCja8SQNAWH10=";
        dependencies = [ anyhow idArena indexmap log semver unicodeXid ];
        crateOverrides = pkgs.defaultCrateOverrides // { inherit (overrides) wit-parser; };
      };
      probe = pkgs.buildRustCrate {
        crateName = "wit_dir_order_probe";
        edition = "2021";
        version = "0.1.0";
        crateBin = [ { name = "wit_dir_order_probe"; path = "src/main.rs"; } ];
        src = pkgs.writeTextDir "src/main.rs" ''
          fn main() {
              let dir = std::env::args().nth(1).unwrap();
              let group = wit_parser::UnresolvedPackageGroup::parse_dir(&dir).unwrap();
              for path in group.source_map.source_files() {
                  println!("{}", path.file_stem().unwrap().to_str().unwrap());
              }
          }
        '';
        dependencies = [ witParser ];
      };
      names = map (n: "i${lib.fixedWidthNumber 2 n}") (lib.range 1 16);
      expected = lib.concatStringsSep "\n" names;
    in
    pkgs.runCommand "rust-wit-dir-order" { nativeBuildInputs = [ probe ]; } ''
      mkdir wit
      for n in ${lib.concatStringsSep " " (lib.reverseList names)}; do
        printf 'package test:order;\ninterface %s {}\n' "$n" > wit/$n.wit
      done
      raw=$(ls -f wit | grep '\.wit$' | sed 's/\.wit$//')
      if [ "$raw" = "${expected}" ]; then
        echo "this filesystem lists the fixture in sorted order, so the check cannot tell a sorted parser from an unsorted one" >&2
        exit 1
      fi
      got=$(wit_dir_order_probe wit)
      if [ "$got" != "${expected}" ]; then
        printf 'wit-parser read the directory in filesystem order:\n%s\n' "$got" >&2
        exit 1
      fi
      touch $out
    '';
}
