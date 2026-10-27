# formatters — the registry's own gate.
#
# Two halves:
#
#   eval  — the registry refuses a malformed entry, a filetype owned twice,
#           and a file-mode entry with no $FILE; every command is the
#           entry's own package.
#
#   round-trip, one derivation per language — a deliberately unformatted
#           sample goes through the EDITOR command (formatScript, the exact
#           argv blnvim and escriba render). The result must be a fixed
#           point of the same command, which is precisely what
#           mkCanonicalCheck's leaf accepts. Non-vacuity: the sample must
#           change on the first pass, so a formatter that echoes its input
#           cannot pass.
{
  pkgs,
  lib ? pkgs.lib,
  rustToolchain ? null,
}:
let
  fmt = import ../formatters.nix { inherit lib; };
  iroha = import ../iroha { inherit lib; };
  registry = fmt.mkFormatters { inherit pkgs rustToolchain; };

  throws = v: !(builtins.tryEval (builtins.seq v true)).success;

  stub = pkgs.runCommand "stub" { } "mkdir -p $out/bin";

  samples = {
    nix = "{ a = 1;  b = [1 2]; }";
    rust = "fn main( ) { let x=1 ; println!(\"{}\",x) ; }\n";
    toml = "a   =  1\n[t]\nb= \"x\"\n";
    lua = "local x   =  { 1,2 }\nreturn x\n";
    sh = "if true;  then\necho   hi\nfi\n";
    python = "x = { 'a':1 }\nprint( x )\n";
    go = "package main\nfunc main( ) {  println(1) }\n";
    javascript = "const x = {a:1}\n";
    typescript = "const x : number = 1\n";
    json = ''{"a":1,"b":[1,2]}'';
    yaml = "a:   1\nb:\n    - x\n";
    markdown = "# T\n* a\n* b\n";
    html = "<div>\n        <p>x</p></div>\n";
  };

  roundTrip =
    language: entry:
    let
      suffix = builtins.head entry.suffixes;
      sample = pkgs.writeText "sample${suffix}" samples.${language};
    in
    pkgs.runCommand "formatters-round-trip-${language}" { } ''
      export HOME=$TMPDIR
      mkdir -p $TMPDIR/a $TMPDIR/b
      ${fmt.formatScript entry sample "$TMPDIR/a/once${suffix}"}
      ${fmt.formatScript entry "$TMPDIR/a/once${suffix}" "$TMPDIR/b/twice${suffix}"}
      if cmp -s ${sample} $TMPDIR/a/once${suffix}; then echo "${language}: the sample was already canonical, the test proves nothing"; exit 1; fi
      diff -u $TMPDIR/a/once${suffix} $TMPDIR/b/twice${suffix}
      cp $TMPDIR/a/once${suffix} $out
    '';

  suite = iroha.mkEvalChecks {
    name = "formatters";
    tests = {
      every-sampled-language-is-registered = {
        expr = lib.subtractLists (builtins.attrNames registry) (builtins.attrNames samples);
        expected = [ ];
      };
      every-registered-language-is-sampled = {
        expr = lib.subtractLists (builtins.attrNames samples) (builtins.attrNames registry);
        expected = [ ];
      };
      commands-live-in-their-package = {
        expr = lib.all (e: lib.hasPrefix "${e.package}/bin/" e.command) (builtins.attrValues registry);
        expected = true;
      };
      nix-is-nixfmt-strict = {
        expr = {
          inherit (registry.nix) args stdin;
          exe = baseNameOf registry.nix.command;
        };
        expected = {
          args = [
            "--strict"
            "-"
          ];
          stdin = true;
          exe = "nixfmt";
        };
      };
      rust-takes-the-edition-from-cargo = {
        expr = registry.rust.cargoEdition;
        expected = "2015";
      };
      blue-only-when-given = {
        expr = [
          (registry ? blue)
          (
            (fmt.mkFormatters {
              inherit pkgs;
              blue = stub;
            }) ? blue
          )
        ];
        expected = [
          false
          true
        ];
      };
      view-holds-no-derivation = {
        expr = lib.all (v: !(v ? package)) (map fmt.view (builtins.attrValues registry));
        expected = true;
      };
      view-is-json = {
        expr = builtins.isString (builtins.toJSON (lib.mapAttrs (_: fmt.view) registry));
        expected = true;
      };
    };
  };

  decl = {
    package = stub;
    exe = "x";
    args = [ ];
    stdin = true;
    filetypes = [ "x" ];
    suffixes = [ ".x" ];
  };

  refusals = iroha.mkEvalChecks {
    name = "formatters-refusals";
    tests = {
      a-well-formed-entry-is-accepted = {
        expr = throws (fmt.mkEntry "x" decl);
        expected = false;
      };
      a-missing-field-is-refused = {
        expr = throws (fmt.mkEntry "x" (removeAttrs decl [ "args" ]));
        expected = true;
      };
      an-unknown-field-is-refused = {
        expr = throws (fmt.mkEntry "x" (decl // { flags = [ ]; }));
        expected = true;
      };
      file-mode-without-file-is-refused = {
        expr = throws (fmt.mkEntry "x" (decl // { stdin = false; }));
        expected = true;
      };
      file-mode-with-file-is-accepted = {
        expr = throws (
          fmt.mkEntry "x" (
            decl
            // {
              stdin = false;
              args = [ "$FILE" ];
            }
          )
        );
        expected = false;
      };
      a-filetype-owned-twice-is-refused = {
        expr = throws (
          fmt.mkFormatters {
            inherit pkgs;
            extra.alejandra = decl // {
              filetypes = [ "nix" ];
            };
          }
        );
        expected = true;
      };
      extra-adds-a-language = {
        expr =
          (fmt.mkFormatters {
            inherit pkgs;
            extra.x = decl;
          }) ? x;
        expected = true;
      };
    };
  };
in
pkgs.linkFarm "formatters" (
  [
    {
      name = "eval";
      path = suite.asCheck pkgs;
    }
    {
      name = "refusals";
      path = refusals.asCheck pkgs;
    }
  ]
  ++ lib.mapAttrsToList (language: entry: {
    name = "round-trip-${language}";
    path = roundTrip language entry;
  }) registry
)
