{ inputs, ... }:
{
  imports = [
    (inputs.substrate.moduleTrio.mkModuleTrio {
      name = "hello";
      namespace = "pleme";
      description = "an example tool on PATH, declared once for every arm";
    }).module
  ];
}
