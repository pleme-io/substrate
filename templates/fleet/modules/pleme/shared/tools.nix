{ inputs, ... }:
{
  imports = [
    (inputs.substrate.moduleTrio.mkModuleTrio {
      kind = "package";
      namespace = "pleme";
      name = "tools";
      packageAttr = "jq";
      binaryName = "jq";
      description = "the fleet's JSON tool, installed and pinned through one typed surface";
    }).module
  ];
}
