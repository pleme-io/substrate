{ lib }:
let
  arms = [
    "nixos"
    "darwin"
    "homeManager"
  ];

  classOf = {
    nixos = "nixos";
    darwin = "darwin";
    homeManager = "homeManager";
  };

  reasons = {
    no-surface = "the platform has no option surface for what this concept renders";
    scope = "the concept runs at a privilege scope this arm does not host";
    unbuildable = "the concept's package does not build for this platform";
    owned-elsewhere = "another module renders this concept on this platform";
    unimplemented = "the renderer for this platform is not written yet";
  };

  renders = {
    verdict = "renders";
  };

  refuses =
    why: detail:
    if !(builtins.isString why) || !(reasons ? ${why}) then
      throw "module-trio: refusal reason '${toString why}' is not one of ${lib.concatStringsSep ", " (builtins.attrNames reasons)}."
    else if !(builtins.isString detail) || detail == "" then
      throw "module-trio: a refusal (${why}) carries a non-empty detail naming the fact."
    else
      {
        verdict = "refuses";
        inherit why detail;
      };

  check =
    where: arm: v:
    if !(builtins.isAttrs v) || !(v ? verdict) then
      throw "${where}: support.${arm} must be `renders` or `refuses <reason> <detail>` from the module-trio support lattice."
    else if v.verdict == "renders" then
      renders
    else if v.verdict == "refuses" then
      refuses (v.why or null) (v.detail or null)
    else
      throw "${where}: support.${arm} has verdict '${toString v.verdict}', which is neither renders nor refuses.";

  normalize =
    {
      where,
      defaults,
      given,
    }:
    let
      unknown = builtins.filter (k: !(builtins.elem k arms)) (builtins.attrNames given);
    in
    if !(builtins.isAttrs given) then
      throw "${where}: `support` must be an attrset over ${lib.concatStringsSep ", " arms}."
    else if unknown != [ ] then
      throw "${where}: support names unknown arm(s) ${lib.concatStringsSep ", " unknown}; the arms are ${lib.concatStringsSep ", " arms}."
    else
      lib.genAttrs arms (arm: check where arm (given.${arm} or defaults.${arm}));

  messageFor =
    {
      path,
      arm,
      verdict,
    }:
    "${lib.concatStringsSep "." path} is enabled on the ${arm} arm, which refuses it (${verdict.why}: ${reasons.${verdict.why}}): ${verdict.detail}";

  refusalModule =
    {
      enablePath,
      path,
      arm,
      verdict,
    }:
    { config, lib, ... }:
    {
      config = lib.mkMerge [
        (lib.setAttrByPath enablePath (lib.mkOverride 1400 false))
        {
          assertions = [
            {
              assertion = !(lib.attrByPath enablePath false config);
              message = messageFor { inherit path arm verdict; };
            }
          ];
        }
      ];
    };

  dispatch =
    {
      where,
      modules,
      schema ? null,
    }:
    { _class ? null, ... }:
    let
      arm = lib.findFirst (a: classOf.${a} == _class) null arms;
    in
    {
      imports = [
        (
          if arm != null then
            modules.${arm}
          else if _class == null && schema != null then
            schema
          else
            throw "${where}: imported into an evaluation of class '${toString _class}'; import nixosModule, darwinModule or homeManagerModule explicitly."
        )
      ];
    };

  allRender = lib.genAttrs arms (_: renders);
in
{
  inherit
    arms
    classOf
    reasons
    renders
    refuses
    normalize
    messageFor
    refusalModule
    dispatch
    allRender
    ;
}
