# formatters — ONE typed per-language formatter registry for every face that
# formats: the CI canonical checks, blnvim's `ff`, escriba's format command.
#
# Receipt (2026-10-27): a .nix file passed local editing and then failed the
# nix repo's nix-canonical check. The editor ran alejandra from its own
# package list; CI ran `nixfmt --strict` from a second, hand-written list.
# Nothing compared the two. This file is the one list.
#
# ── SHAPE ───────────────────────────────────────────────────────────────
#
#   mkFormatters :: { pkgs, rustToolchain ? null, blue ? null, extra ? { } } -> attrsOf entry
#     extra adds languages (same declaration shape as below); a filetype
#     claimed by two languages is refused.
#     entry = {
#       language   — the registry key.
#       package    — the derivation the command lives in.
#       command    — absolute store path of the executable. Consumers run
#                    THIS, never a $PATH lookup, so "same tool" means the same
#                    store path, not the same name.
#       args       — the one argument list. With stdin = true the formatter
#                    reads the buffer on stdin and writes the result to stdout.
#                    With stdin = false, "$FILE" names a scratch copy that the
#                    formatter rewrites in place. "$FILE" in a stdin entry is a
#                    path hint only (prettier picks its parser from it).
#       stdin      — see args.
#       filetypes  — editor filetype names (Neovim and escriba share them).
#       suffixes   — file name suffixes the canonical check walks.
#       cargoEdition — null, or the edition to use when no Cargo.toml above
#                    the file names one. Non-null means the consumer appends
#                    `--edition <found>`, the way `cargo fmt` does per crate.
#     }
#
#   mkCanonicalCheck :: { pkgs, entry, root, name ?, minimumFiles ?, excludedDirs ? }
#     -> derivation. One leaf derivation per file; each leaf runs the entry's
#     editor command over the file and diffs the result against the file.
#     The CI verdict IS the editor's output, so the two cannot disagree on
#     anything but the store path, and the store path comes from here too.
#
#   view :: entry -> the JSON-safe subset consumers render (no derivation).
#
# Tier: one declaration, many renderings. A consumer that bypasses the
# registry (a $PATH name, a hand-written arg list) is not caught here; the
# agreement gate in the consumer's fleet repo catches that.
{ lib }:
let
  fields = [
    "package"
    "exe"
    "args"
    "stdin"
    "filetypes"
    "suffixes"
  ];

  mkEntry =
    language: decl:
    let
      missing = lib.filter (f: !(decl ? ${f})) fields;
      unknown = lib.subtractLists (fields ++ [ "cargoEdition" ]) (builtins.attrNames decl);
    in
    if missing != [ ] then
      throw "formatters.${language}: missing ${lib.concatStringsSep ", " missing}"
    else if unknown != [ ] then
      throw "formatters.${language}: unknown field ${lib.concatStringsSep ", " unknown}"
    else if decl.filetypes == [ ] || decl.suffixes == [ ] then
      throw "formatters.${language}: filetypes and suffixes must be non-empty"
    else if !decl.stdin && !(lib.elem "$FILE" decl.args) then
      throw "formatters.${language}: a file-mode entry (stdin = false) must pass $FILE"
    else
      {
        inherit language;
        inherit (decl)
          package
          args
          stdin
          filetypes
          suffixes
          ;
        command = "${decl.package}/bin/${decl.exe}";
        cargoEdition = decl.cargoEdition or null;
      };

  declarations =
    {
      pkgs,
      rustToolchain,
      blue,
    }:
    let
      prettier = pkgs.prettier;
      prettierEntry = filetypes: suffixes: {
        package = prettier;
        exe = "prettier";
        args = [
          "--stdin-filepath"
          "$FILE"
        ];
        stdin = true;
        inherit filetypes suffixes;
      };
    in
    {
      nix = {
        package = pkgs.nixfmt;
        exe = "nixfmt";
        args = [
          "--strict"
          "-"
        ];
        stdin = true;
        filetypes = [ "nix" ];
        suffixes = [ ".nix" ];
      };
      rust = {
        package = if rustToolchain != null then rustToolchain else pkgs.rustfmt;
        exe = "rustfmt";
        args = [ "--emit=stdout" ];
        stdin = true;
        filetypes = [ "rust" ];
        suffixes = [ ".rs" ];
        cargoEdition = "2015";
      };
      toml = {
        package = pkgs.taplo;
        exe = "taplo";
        args = [
          "format"
          "-"
        ];
        stdin = true;
        filetypes = [ "toml" ];
        suffixes = [ ".toml" ];
      };
      lua = {
        package = pkgs.stylua;
        exe = "stylua";
        args = [ "-" ];
        stdin = true;
        filetypes = [ "lua" ];
        suffixes = [ ".lua" ];
      };
      sh = {
        package = pkgs.shfmt;
        exe = "shfmt";
        args = [ ];
        stdin = true;
        filetypes = [
          "sh"
          "zsh"
        ];
        suffixes = [ ".sh" ];
      };
      python = {
        package = pkgs.black;
        exe = "black";
        args = [
          "--quiet"
          "-"
        ];
        stdin = true;
        filetypes = [ "python" ];
        suffixes = [ ".py" ];
      };
      go = {
        package = pkgs.gofumpt;
        exe = "gofumpt";
        args = [ ];
        stdin = true;
        filetypes = [ "go" ];
        suffixes = [ ".go" ];
      };
      javascript = prettierEntry [ "javascript" ] [ ".js" ];
      typescript = prettierEntry [ "typescript" ] [ ".ts" ];
      json = prettierEntry [ "json" ] [ ".json" ];
      yaml = prettierEntry [ "yaml" ] [ ".yaml" ".yml" ];
      markdown = prettierEntry [ "markdown" ] [ ".md" ];
      html = prettierEntry [ "html" ] [ ".html" ];
    }
    // lib.optionalAttrs (blue != null) {
      blue = {
        package = blue;
        exe = "blue";
        args = [
          "fmt"
          "--write"
          "$FILE"
        ];
        stdin = false;
        filetypes = [ "blue" ];
        suffixes = [ ".b" ];
      };
    };

  mkFormatters =
    {
      pkgs,
      rustToolchain ? null,
      blue ? null,
      extra ? { },
    }:
    let
      entries = lib.mapAttrs mkEntry (declarations { inherit pkgs rustToolchain blue; } // extra);
      owners = lib.concatMap (
        e:
        map (ft: {
          inherit ft;
          inherit (e) language;
        }) e.filetypes
      ) (builtins.attrValues entries);
      claimed = lib.groupBy (o: o.ft) owners;
      clashes = lib.filterAttrs (_: os: builtins.length os > 1) claimed;
    in
    if clashes != { } then
      throw "formatters: filetype claimed twice: ${lib.concatStringsSep ", " (builtins.attrNames clashes)}"
    else
      entries;

  view = entry: {
    inherit (entry)
      language
      command
      args
      stdin
      filetypes
      suffixes
      cargoEdition
      ;
  };

  substitute = file: map (a: if a == "$FILE" then file else a);

  formatScript =
    entry: src: out:
    let
      editionArgs = lib.optionals (entry.cargoEdition != null) [
        "--edition"
        entry.cargoEdition
      ];
    in
    if entry.stdin then
      "${
        lib.escapeShellArgs ([ entry.command ] ++ substitute (baseNameOf src) entry.args ++ editionArgs)
      } < ${src} > ${out}"
    else
      "install -m 644 ${src} ${out} && ${
        lib.escapeShellArgs ([ entry.command ] ++ substitute out entry.args)
      }";

  defaultExcludedDirs = [
    ".git"
    ".claude"
    ".direnv"
    "node_modules"
    "target"
    "vendor"
    "result"
  ];

  walk =
    {
      root,
      suffixes,
      excludedDirs,
    }:
    let
      go =
        dir:
        lib.concatLists (
          lib.mapAttrsToList (
            name: kind:
            let
              path = dir + "/${name}";
            in
            if kind == "directory" then
              if lib.elem name excludedDirs || lib.hasPrefix "result-" name then [ ] else go path
            else if kind == "regular" && lib.any (s: lib.hasSuffix s name) suffixes then
              [ path ]
            else
              [ ]
          ) (builtins.readDir dir)
        );
    in
    go root;

  mkCanonicalCheck =
    {
      pkgs,
      entry,
      root,
      name ? "${entry.language}-canonical",
      minimumFiles ? 1,
      excludedDirs ? defaultExcludedDirs,
    }:
    let
      files = walk {
        inherit root excludedDirs;
        inherit (entry) suffixes;
      };
      rel = path: lib.removePrefix (toString root + "/") (toString path);
      leaf =
        path:
        pkgs.runCommand "canonical-${lib.replaceStrings [ "/" ] [ "-" ] (rel path)}"
          {
            allowSubstitutes = false;
            preferLocalBuild = true;
          }
          ''
            export HOME=$TMPDIR
            ${formatScript entry path "$TMPDIR/${baseNameOf (toString path)}"}
            diff -u --label ${lib.escapeShellArg (rel path)} --label ${lib.escapeShellArg "${entry.language} formatter"} ${path} "$TMPDIR/${baseNameOf (toString path)}" && touch $out
          '';
    in
    assert lib.assertMsg (builtins.length files >= minimumFiles) ''
      ${name}: the walk found ${toString (builtins.length files)} file(s) under ${toString root}
      with suffix ${lib.concatStringsSep " " entry.suffixes}, expected at least ${toString minimumFiles}.
      A gate that scans nothing reports success having checked nothing.
    '';
    pkgs.runCommand name {
      leaves = map leaf files;
      passthru = {
        inherit files;
        count = builtins.length files;
      };
      allowSubstitutes = false;
      preferLocalBuild = true;
    } "touch $out";
in
{
  inherit
    mkEntry
    mkFormatters
    mkCanonicalCheck
    view
    formatScript
    ;
}
