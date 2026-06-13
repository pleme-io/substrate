# Tests — iroha.activation-hook (typed enable → idempotent OS activation
# step, NixOS rich { text; deps; } vs nix-darwin flat .text; script-fn
# receives cfg/pkgs/lib; static text form; exactly-one-of script/text;
# extraOptions land; always-on form; class tagging; meta; typed throws).
{ lib, iroha }:
let
  inherit (iroha) mkActivationHook mkModuleEvalCheck classes;

  # ── stub pkgs (zero real nixpkgs): just a marker the script fn can read
  stubPkgs = {
    coreutils = "COREUTILS_DRV";
  };

  # ── stub option universe: declare the activation-script root the
  # emitted modules write into, as freeform `attrsOf anything` so it
  # accepts BOTH the NixOS { text; deps; } submodule and the darwin flat
  # .text shape under one stub. Plus the extraOptions landing pads.
  universe =
    { lib, ... }:
    {
      options = {
        system.activationScripts = lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          default = { };
        };
      };
    };

  evalNixos =
    pkgs: modules:
    lib.evalModules {
      class = "nixos";
      modules = [
        universe
        { _module.args.pkgs = pkgs; }
      ]
      ++ modules;
    };
  evalDarwin =
    pkgs: modules:
    lib.evalModules {
      class = "darwin";
      modules = [
        universe
        { _module.args.pkgs = pkgs; }
      ]
      ++ modules;
    };

  # ── specs under test ─────────────────────────────────────────────────
  # Static-text hook with deps.
  staticHook = mkActivationHook {
    name = "disableDeterminate";
    description = "neutralize Determinate's nixd shim";
    text = "rm -f /etc/nix/nix.custom.conf";
    deps = [ "etc" ];
  };

  # Script-fn hook: body reads cfg (an extraOption) AND pkgs.
  fnHook = mkActivationHook {
    name = "adminUsers";
    description = "materialize admin user records";
    extraOptions = l: {
      users = l.mkOption {
        type = l.types.listOf l.types.str;
        default = [ ];
      };
    };
    script =
      {
        cfg,
        pkgs,
        lib,
      }:
      ''
        ${pkgs.coreutils}/bin/printf '%s\n' ${lib.concatStringsSep " " cfg.users} > /tmp/admins
      '';
  };

  # Custom namespace + always-on (enable = false ⇒ unconditional step).
  alwaysHook = mkActivationHook {
    name = "atticDefault";
    description = "seed the attic default cache server";
    namespace = "blackmatter.activation";
    enable = false;
    text = "echo attic >> /etc/attic.conf";
  };

  enAdmin = {
    system.adminUsers.enable = true;
    system.adminUsers.users = [
      "luis"
      "drzln"
    ];
  };
in
{
  # ── static-text: NixOS rich shape (text + deps) ─────────────────────
  static-nixos-sets-text-and-deps = {
    expr =
      let
        c =
          (evalNixos stubPkgs [
            staticHook.nixos
            { system.disableDeterminate.enable = true; }
          ]).config;
      in
      c.system.activationScripts.disableDeterminate;
    expected = {
      text = "rm -f /etc/nix/nix.custom.conf";
      deps = [ "etc" ];
    };
  };

  # ── static-text: nix-darwin flat shape (.text only, no deps) ────────
  static-darwin-sets-flat-text-no-deps = {
    expr =
      let
        c =
          (evalDarwin stubPkgs [
            staticHook.darwin
            { system.disableDeterminate.enable = true; }
          ]).config;
        entry = c.system.activationScripts.disableDeterminate;
      in
      {
        text = entry.text;
        hasDeps = entry ? deps;
      };
    expected = {
      text = "rm -f /etc/nix/nix.custom.conf";
      hasDeps = false;
    };
  };

  # ── disabled ⇒ the activation step is absent entirely ───────────────
  disabled-omits-the-step = {
    expr = (evalNixos stubPkgs [ staticHook.nixos ]).config.system.activationScripts;
    expected = { };
  };
  disabled-omits-the-step-darwin = {
    expr = (evalDarwin stubPkgs [ staticHook.darwin ]).config.system.activationScripts;
    expected = { };
  };

  # ── script fn receives cfg / pkgs / lib; a value computed from cfg
  #    lands in the rendered body ─────────────────────────────────────
  script-fn-reads-cfg-and-pkgs = {
    expr =
      let
        body =
          (evalNixos stubPkgs [
            fnHook.nixos
            enAdmin
          ]).config.system.activationScripts.adminUsers.text;
      in
      {
        # cfg.users (an extraOption) flowed into the body
        hasUsers = lib.hasInfix "luis drzln" body;
        # pkgs.coreutils flowed into the body
        hasPkg = lib.hasInfix "COREUTILS_DRV/bin/printf" body;
      };
    expected = {
      hasUsers = true;
      hasPkg = true;
    };
  };

  # ── extraOptions declaration lands as a typed option ────────────────
  extra-options-typed-and-default = {
    expr =
      let
        c = (evalNixos stubPkgs [ fnHook.nixos ]).config;
      in
      c.system.adminUsers.users;
    expected = [ ];
  };
  extra-options-accept-values = {
    expr =
      (evalNixos stubPkgs [
        fnHook.nixos
        enAdmin
      ]).config.system.adminUsers.users;
    expected = [
      "luis"
      "drzln"
    ];
  };

  # ── always-on form (enable = false): unconditional step, no enable
  #    option, custom namespace ────────────────────────────────────────
  always-on-step-runs-without-enable = {
    expr =
      (evalNixos stubPkgs [
        alwaysHook.nixos
      ]).config.system.activationScripts.atticDefault.text;
    expected = "echo attic >> /etc/attic.conf";
  };
  always-on-has-no-enable-option = {
    # enable = false ⇒ no `enable` leaf is declared under the option root
    # (the step is unconditional). Eval the emitted options and check.
    expr =
      let
        opts =
          (lib.evalModules {
            class = "nixos";
            modules = [
              universe
              { _module.args.pkgs = stubPkgs; }
              alwaysHook.nixos
            ];
          }).options;
      in
      (lib.attrByPath [ "blackmatter" "activation" "atticDefault" ] { } opts) ? enable;
    expected = false;
  };

  # ── custom-namespace option path ────────────────────────────────────
  custom-namespace-option-path = {
    expr = alwaysHook.meta.optionPath;
    expected = [
      "blackmatter"
      "activation"
      "atticDefault"
    ];
  };

  # ── meta ────────────────────────────────────────────────────────────
  meta-fields = {
    expr = staticHook.meta;
    expected = {
      name = "disableDeterminate";
      optionPath = [
        "system"
        "disableDeterminate"
      ];
      enablePath = [
        "system"
        "disableDeterminate"
        "enable"
      ];
      kind = "activation-hook";
    };
  };

  # ── class tagging (parse-time rejection: a class-mismatched eval
  #    throws) ───────────────────────────────────────────────────────
  nixos-module-is-nixos-class = {
    expr = staticHook.nixos._class;
    expected = "nixos";
  };
  darwin-module-is-darwin-class = {
    expr = staticHook.darwin._class;
    expected = "darwin";
  };
  class-mismatch-rejected = {
    # the nixos-tagged module evaluated under class "darwin" throws.
    expr =
      (builtins.tryEval (
        builtins.seq
          (lib.evalModules {
            class = "darwin";
            modules = [
              universe
              { _module.args.pkgs = stubPkgs; }
              staticHook.nixos
            ];
          }).config.system.activationScripts
          true
      )).success;
    expected = false;
  };

  # ── typed throws (lazy — force the field that throws) ───────────────
  missing-name-throws = {
    expr = (builtins.tryEval (mkActivationHook { description = "d"; text = "x"; }).meta.name).success;
    expected = false;
  };
  description-missing-forced-throws = {
    # description is consumed lazily by mkEnableOption — force the option
    # block to surface the throw.
    expr =
      (builtins.tryEval (
        builtins.seq
          (lib.evalModules {
            class = "nixos";
            modules = [
              universe
              { _module.args.pkgs = stubPkgs; }
              (mkActivationHook {
                name = "x";
                text = "y";
              }).nixos
            ];
          }).options.system.x.enable.description
          true
      )).success;
    expected = false;
  };
  both-script-and-text-throws-on-body = {
    # the body (bodyFor) throws lazily inside mkIf — deepSeq forces the
    # `.text` value so the throw surfaces under tryEval.
    expr =
      (builtins.tryEval (
        builtins.deepSeq
          (evalNixos stubPkgs [
            (mkActivationHook {
              name = "x";
              description = "d";
              text = "y";
              script = _: "z";
            }).nixos
            { system.x.enable = true; }
          ]).config.system.activationScripts
          true
      )).success;
    expected = false;
  };
  neither-script-nor-text-throws = {
    expr =
      (builtins.tryEval (
        builtins.deepSeq
          (evalNixos stubPkgs [
            (mkActivationHook {
              name = "x";
              description = "d";
            }).nixos
            { system.x.enable = true; }
          ]).config.system.activationScripts
          true
      )).success;
    expected = false;
  };
  script-not-a-function-throws = {
    expr =
      (builtins.tryEval (
        builtins.deepSeq
          (evalNixos stubPkgs [
            (mkActivationHook {
              name = "x";
              description = "d";
              script = "not-a-fn";
            }).nixos
            { system.x.enable = true; }
          ]).config.system.activationScripts
          true
      )).success;
    expected = false;
  };
  deps-not-a-list-throws = {
    expr =
      (builtins.tryEval (
        builtins.deepSeq
          (evalNixos stubPkgs [
            (mkActivationHook {
              name = "x";
              description = "d";
              text = "y";
              deps = "etc";
            }).nixos
            { system.x.enable = true; }
          ]).config.system.activationScripts
          true
      )).success;
    expected = false;
  };
  extra-options-bad-shape-throws = {
    expr =
      (builtins.tryEval (
        builtins.attrNames
          (lib.evalModules {
            class = "nixos";
            modules = [
              universe
              { _module.args.pkgs = stubPkgs; }
              (mkActivationHook {
                name = "x";
                description = "d";
                text = "y";
                extraOptions = 42;
              }).nixos
            ];
          }).options.system
      )).success;
    expected = false;
  };
}
