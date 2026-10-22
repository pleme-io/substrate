{ pkgs }:
let
  inherit (pkgs) lib;
in
rec {
  mkAdvisoryIndex =
    {
      advisoryDb,
      ecosystems ? [
        "npm"
        "crates.io"
        "Go"
      ],
    }:
    pkgs.runCommand "advisory-index" { nativeBuildInputs = [ pkgs.zip ]; } ''
      mkdir -p "$TMPDIR/z"
      cd ${advisoryDb}/advisories/github-reviewed
      zip -q -r "$TMPDIR/z/all.zip" .
      ${lib.concatMapStrings (e: ''
        mkdir -p "$out/osv-scanner/${e}"
        cp "$TMPDIR/z/all.zip" "$out/osv-scanner/${e}/all.zip"
      '') ecosystems}
    '';

  mkLockfileGate =
    {
      name,
      lockfile,
      index,
      parser ? "package-lock.json",
      osvScanner ? pkgs.osv-scanner,
    }:
    pkgs.runCommand "lockfile-gate-${name}"
      {
        nativeBuildInputs = [ osvScanner ];
        OSV_SCANNER_LOCAL_DB_CACHE_DIRECTORY = index;
      }
      ''
        export HOME="$TMPDIR"
        osv-scanner scan source --offline --lockfile "${parser}:${lockfile}"
        touch "$out"
      '';

  gated = gate: drv: drv.overrideAttrs (_: { lockfileGate = gate; });

  parserOf =
    file:
    {
      "package-lock.json" = "package-lock.json";
      "Cargo.lock" = "Cargo.lock";
      "go.sum" = "go.mod";
    }
    .${file};

  discoverLocks =
    root:
    let
      files = [
        "package-lock.json"
        "Cargo.lock"
      ];
      walk =
        dir: rel:
        lib.concatLists (
          lib.mapAttrsToList (
            n: t:
            if t == "directory" && n != ".git" && n != ".claude" && n != "node_modules" && n != "target" then
              walk (dir + "/${n}") (if rel == "" then n else "${rel}/${n}")
            else if t == "regular" && builtins.elem n files then
              [
                {
                  name = lib.replaceStrings [ "/" ] [ "-" ] (if rel == "" then n else "${rel}/${n}");
                  path = dir + "/${n}";
                  parser = parserOf n;
                }
              ]
            else
              [ ]
          ) (builtins.readDir dir)
        );
    in
    walk root "";

  mkLockfileGates =
    {
      root,
      index,
    }:
    map (
      l:
      mkLockfileGate {
        inherit (l) name parser;
        lockfile = l.path;
        inherit index;
      }
    ) (discoverLocks root);

  fixtureVulnerableNpmLock = pkgs.writeText "package-lock.json" (
    builtins.toJSON {
      name = "fixture";
      version = "0.0.0";
      lockfileVersion = 3;
      requires = true;
      packages = {
        "" = {
          name = "fixture";
          version = "0.0.0";
          dependencies = {
            axios = "1.19.0";
          };
        };
        "node_modules/axios" = {
          version = "1.19.0";
          resolved = "https://registry.npmjs.org/axios/-/axios-1.19.0.tgz";
        };
      };
    }
  );

  mkGateRejects =
    {
      index,
      lockfile ? fixtureVulnerableNpmLock,
      parser ? "package-lock.json",
    }:
    pkgs.testers.testBuildFailure (mkLockfileGate {
      name = "known-bad-fixture";
      inherit lockfile index parser;
    });
}
