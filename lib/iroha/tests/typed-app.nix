# Tests — iroha.typed-app (typed flake-app constructor; NO SHELL law).
{ lib, iroha }:
let
  inherit (iroha) mkTypedApp;

  # Stub pkgs: writeShellScript returns an inspectable attrset instead of a
  # derivation, keeping the suite pure-eval. mkTypedApp passes a
  # non-string-coercible result through uncoerced by design.
  pkgs = {
    writeShellScript = n: text: {
      stub = "writeShellScript";
      inherit n text;
    };
  };

  # Fake derivation: any outPath-coercible attrset — "${drv}" is "/store/d".
  drv = {
    outPath = "/store/d";
  };

  directStr = mkTypedApp {
    inherit pkgs;
    name = "tool";
    binary = "/store/x/bin/tool";
  };

  directDrv = mkTypedApp {
    inherit pkgs;
    name = "tool";
    binary = drv;
  };

  named = mkTypedApp {
    inherit pkgs;
    name = "serve";
    binary = drv;
    binaryName = "served";
  };

  wrapped = mkTypedApp {
    inherit pkgs;
    name = "serve";
    binary = "/bin/serve";
    argv = [
      "--port"
      "8080"
      "hello world"
    ];
    env = {
      MODE = "a b";
      URL = "http://localhost:6070";
    };
    description = "serve the fleet";
  };

  argvOnly = mkTypedApp {
    inherit pkgs;
    name = "echoer";
    binary = drv;
    argv = [ "hello world" ];
  };

  envOnly = mkTypedApp {
    inherit pkgs;
    name = "envy";
    binary = "/bin/envy";
    env.CACHE = "/tmp/c";
  };
in
{
  # ── zero-wrapper fast path ──────────────────────────────────────────
  direct-program-string-binary = {
    expr = directStr.program;
    expected = "/store/x/bin/tool";
  };
  direct-program-drv-binary = {
    expr = directDrv.program;
    expected = "/store/d/bin/tool";
  };
  binaryname-overrides-bin-entry = {
    expr = named.program;
    expected = "/store/d/bin/served";
  };
  type-is-app = {
    expr = directStr.type == "app" && wrapped.type == "app";
    expected = true;
  };

  # ── wrapper compilation ─────────────────────────────────────────────
  wrapper-engaged-by-argv = {
    expr = argvOnly.program.stub;
    expected = "writeShellScript";
  };
  wrapper-engaged-by-env = {
    expr = envOnly.program.stub;
    expected = "writeShellScript";
  };
  wrapper-derivation-name = {
    expr = wrapped.program.n;
    expected = "serve-app";
  };
  wrapper-text-exact = {
    # export lines (attr-name order) then ONE shebang-less exec line; spaces
    # single-quoted, safe words bare, trailing "$@" passes runtime args.
    expr = wrapped.program.text;
    expected = "export MODE='a b'\nexport URL=http://localhost:6070\nexec /bin/serve --port 8080 'hello world' \"$@\"";
  };
  wrapper-text-argv-only-exact = {
    # drv binary resolves to its bin path INSIDE the wrapper too.
    expr = argvOnly.program.text;
    expected = "exec /store/d/bin/echoer 'hello world' \"$@\"";
  };
  wrapper-text-env-only-exact = {
    expr = envOnly.program.text;
    expected = "export CACHE=/tmp/c\nexec /bin/envy \"$@\"";
  };
  wrapper-trailing-rest-args = {
    expr = lib.hasSuffix "\"$@\"" wrapped.program.text;
    expected = true;
  };
  wrapper-env-spaces-single-quoted = {
    expr = lib.hasInfix "export MODE='a b'" wrapped.program.text;
    expected = true;
  };

  # ── meta (typed source of truth, round-trippable) ───────────────────
  meta-round-trip = {
    expr = wrapped.meta;
    expected = {
      name = "serve";
      description = "serve the fleet";
      argv = [
        "--port"
        "8080"
        "hello world"
      ];
      env = {
        MODE = "a b";
        URL = "http://localhost:6070";
      };
    };
  };
  meta-description-defaults-to-name = {
    expr = directStr.meta.description;
    expected = "tool";
  };
  meta-defaults-empty-argv-env = {
    expr = directStr.meta.argv == [ ] && directStr.meta.env == { };
    expected = true;
  };

  # ── typed throws ────────────────────────────────────────────────────
  spec-not-attrset-throws = {
    expr = (builtins.tryEval (mkTypedApp 42).type).success;
    expected = false;
  };
  missing-pkgs-throws = {
    expr =
      (builtins.tryEval
        (mkTypedApp {
          name = "x";
          binary = "/x";
        }).type
      ).success;
    expected = false;
  };
  missing-or-non-string-name-throws = {
    expr =
      (builtins.tryEval
        (mkTypedApp {
          inherit pkgs;
          binary = "/x";
        }).type
      ).success
      || (builtins.tryEval
        (mkTypedApp {
          inherit pkgs;
          name = 42;
          binary = "/x";
        }).type
      ).success;
    expected = false;
  };
  missing-binary-throws = {
    expr =
      (builtins.tryEval
        (mkTypedApp {
          inherit pkgs;
          name = "x";
        }).type
      ).success;
    expected = false;
  };
  binary-attrset-without-outpath-throws = {
    expr =
      (builtins.tryEval
        (mkTypedApp {
          inherit pkgs;
          name = "x";
          binary = {
            drvPath = "/store/d.drv";
          };
        }).type
      ).success;
    expected = false;
  };
  binary-int-throws = {
    expr =
      (builtins.tryEval
        (mkTypedApp {
          inherit pkgs;
          name = "x";
          binary = 42;
        }).type
      ).success;
    expected = false;
  };
  env-non-string-value-throws = {
    expr =
      (builtins.tryEval
        (mkTypedApp {
          inherit pkgs;
          name = "x";
          binary = "/x";
          env.PORT = 8080;
        }).type
      ).success;
    expected = false;
  };
  env-invalid-key-throws = {
    # "BAD-KEY" is not a shell identifier — the compiled `export` line
    # would be broken bash, so the compile refuses instead.
    expr =
      (builtins.tryEval
        (mkTypedApp {
          inherit pkgs;
          name = "x";
          binary = "/x";
          env."BAD-KEY" = "v";
        }).type
      ).success;
    expected = false;
  };
  argv-non-string-entry-throws = {
    expr =
      (builtins.tryEval
        (mkTypedApp {
          inherit pkgs;
          name = "x";
          binary = "/x";
          argv = [ 8080 ];
        }).type
      ).success;
    expected = false;
  };
  argv-not-a-list-throws = {
    expr =
      (builtins.tryEval
        (mkTypedApp {
          inherit pkgs;
          name = "x";
          binary = "/x";
          argv = "--flag";
        }).type
      ).success;
    expected = false;
  };
}
