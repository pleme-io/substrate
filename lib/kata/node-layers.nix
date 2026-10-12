{ lib }:
let
  selectNodeLayers =
    {
      node,
      layers,
      selected,
      optionPath ? [
        "kata"
        "nodeLayers"
      ],
    }:
    let
      names = builtins.attrNames layers;
      unknown = lib.filter (n: !(layers ? ${n})) selected;
      duplicated = lib.filter (n: lib.count (m: m == n) selected > 1) (lib.unique selected);
      parked = lib.filter (n: !(builtins.elem n selected)) names;
    in
    assert lib.assertMsg (layers ? base)
      "${node}: its layer catalogue has no `base` layer. `base` is the machine itself (hardware, network, users); every other layer is optional on top of it.";
    assert lib.assertMsg (builtins.elem "base" selected)
      "${node}: `base` is not selected. Parking a node's base layer leaves nothing that can boot. Selected: ${lib.concatStringsSep ", " selected}.";
    assert lib.assertMsg (unknown == [ ])
      "${node}: selected layer(s) ${lib.concatStringsSep ", " unknown} not in the catalogue (known: ${lib.concatStringsSep ", " names}).";
    assert lib.assertMsg (
      duplicated == [ ]
    ) "${node}: layer(s) ${lib.concatStringsSep ", " duplicated} selected more than once.";
    [
      {
        options = lib.setAttrByPath optionPath {
          selected = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            readOnly = true;
            description = "The node's layers that are imported into this configuration.";
          };
          parked = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            readOnly = true;
            description = "The node's catalogued layers that are NOT imported (kept on disk, one name away).";
          };
        };
        config = lib.setAttrByPath optionPath { inherit selected parked; };
      }
    ]
    ++ lib.concatMap (n: layers.${n}) selected;

  mkNodeDeclarer =
    {
      blanks,
      stacks,
      hmSelections ? [ "none" ],
      universal ? [ ],
      defaults ? { },
    }:
    let
      d = {
        sshUser = "root";
        stack = "fleet";
        hm = "none";
        profile = null;
        extraModules = [ ];
        deployable = true;
      }
      // defaults;
      known = lib.concatStringsSep ", ";
    in
    {
      mkNode =
        {
          name,
          hostname,
          nodeDir,
          sshUser ? d.sshUser,
          stack ? d.stack,
          hm ? d.hm,
          profile ? d.profile,
          extraModules ? d.extraModules,
          deployable ? d.deployable,
        }:
        assert lib.assertMsg (blanks ? ${name})
          "mkNode: '${name}' has no entry in fleet.nix. Every machine with a NixOS configuration needs one — it is where `system`, `tags` and liveness are declared, and without it the machine cannot be marked down. Add a `${name} = { class = \"nixos\"; system = …; tags = […]; profiles = [ \"node/${name}\" ]; deploy = { }; };` block to fleet.nix's `nodes`.";
        assert lib.assertMsg (blanks.${name}.class == "nixos")
          "mkNode: '${name}' is declared `class = \"${blanks.${name}.class}\"` in fleet.nix but is being built as a NixOS machine. The blank's class is the source of truth; darwin machines go through mkDarwinNode.";
        assert lib.assertMsg (
          stacks ? ${stack}
        ) "mkNode: unknown stack '${stack}' (known: ${known (builtins.attrNames stacks)})";
        assert lib.assertMsg (builtins.elem hm hmSelections)
          "mkNode: unknown hm selection '${hm}' (known: ${known hmSelections})";
        {
          inherit (blanks.${name}) system tags;
          inherit hostname sshUser deployable;
          modules =
            stacks.${stack} {
              inherit
                hm
                profile
                nodeDir
                extraModules
                ;
            }
            ++ universal;
        };

      mkDarwinNode =
        { name, nodeDir }:
        assert lib.assertMsg (blanks ? ${name})
          "mkDarwinNode: '${name}' has no entry in fleet.nix. Every machine needs one — it is where `system`, `tags` and liveness are declared.";
        assert lib.assertMsg (blanks.${name}.class == "darwin")
          "mkDarwinNode: '${name}' is declared `class = \"${blanks.${name}.class}\"` in fleet.nix but is being built as a darwin machine. NixOS machines go through mkNode.";
        {
          inherit (blanks.${name}) system tags;
          inherit nodeDir;
        };
    };

  mkLayerProof =
    {
      class,
      nodes,
      configurations,
      optionPath ? [
        "kata"
        "nodeLayers"
      ],
    }:
    lib.foldl' (
      acc: name:
      let
        cfg = configurations.${name}.config;
      in
      acc
      // {
        "${name}-has-a-configuration" = {
          expr = configurations ? ${name};
          expected = true;
        };
        "${name}-selects-base" = {
          expr = builtins.elem "base" (lib.getAttrFromPath optionPath cfg).selected;
          expected = true;
        };
        "${name}-hostname-is-the-node-name" = {
          expr = cfg.networking.hostName;
          expected = name;
        };
      }
    ) { } (builtins.attrNames (lib.filterAttrs (_: n: n.class == class) nodes));
in
{
  inherit selectNodeLayers mkNodeDeclarer mkLayerProof;
}
