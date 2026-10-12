{
  lib,
  iroha,
  kata,
}:
let
  base = {
    networking.hostName = "alpha";
  };
  seat = {
    services.seat.enable = true;
  };
  layers = {
    inherit base;
    seat = [ seat ];
    edge = [ { services.edge.enable = true; } ];
  };
  layersOf = l: l // { base = [ l.base ]; };

  sel = kata.selectNodeLayers {
    node = "alpha";
    layers = layersOf layers;
    selected = [
      "base"
      "seat"
    ];
  };
  published = (lib.evalModules { modules = [ (builtins.head sel) ]; }).config.kata.nodeLayers;

  custom = kata.selectNodeLayers {
    node = "alpha";
    layers = layersOf layers;
    selected = [ "base" ];
    optionPath = [
      "pleme"
      "nixos"
      "nodeLayers"
    ];
  };
  customPublished =
    (lib.evalModules { modules = [ (builtins.head custom) ]; }).config.pleme.nixos.nodeLayers;

  throws = v: !(builtins.tryEval (builtins.deepSeq v v)).success;
  selectThrows =
    l: s:
    throws (
      kata.selectNodeLayers {
        node = "alpha";
        layers = l;
        selected = s;
      }
    );

  blanks = {
    alpha = {
      class = "nixos";
      system = "x86_64-linux";
      tags = [ "server" ];
    };
    beta = {
      class = "darwin";
      system = "aarch64-darwin";
      tags = [ "workstation" ];
    };
  };
  universal = [ { universal = true; } ];
  declarer = kata.mkNodeDeclarer {
    inherit blanks universal;
    stacks = {
      fleet = { nodeDir, extraModules, ... }: [ "pleme" ] ++ [ nodeDir ] ++ extraModules;
      bare = { nodeDir, extraModules, ... }: extraModules ++ [ nodeDir ];
      hmProbe = { hm, profile, ... }: [ hm ] ++ lib.optional (profile != null) profile;
    };
    hmSelections = [
      "none"
      "dev"
    ];
  };
  alpha = declarer.mkNode {
    name = "alpha";
    hostname = "alpha.example.org";
    nodeDir = "nodes/alpha";
    extraModules = [ "extra" ];
  };
  mkThrows = args: throws (declarer.mkNode args);
  defaulted = kata.mkNodeDeclarer {
    inherit blanks;
    stacks.fleet = { hm, ... }: [ hm ];
    hmSelections = [ "dev" ];
    defaults = {
      hm = "dev";
      sshUser = "admin";
      deployable = false;
    };
  };
  defaultedAlpha = defaulted.mkNode {
    name = "alpha";
    hostname = "alpha";
    nodeDir = "nodes/alpha";
  };
  proofNodes = {
    alpha.class = "nixos";
    gamma.class = "nixos";
    beta.class = "darwin";
  };
  goodConfigs = {
    alpha.config = {
      networking.hostName = "alpha";
      kata.nodeLayers.selected = [ "base" ];
    };
    gamma.config = {
      networking.hostName = "gamma";
      kata.nodeLayers.selected = [
        "base"
        "seat"
      ];
    };
  };
  proof =
    configurations:
    kata.mkLayerProof {
      class = "nixos";
      nodes = proofNodes;
      inherit configurations;
    };
  failing = suite: builtins.attrNames (lib.filterAttrs (_: c: c.expr != c.expected) suite);
in
{
  layer-proof-covers-every-node-of-the-class = {
    expr = builtins.attrNames (proof goodConfigs);
    expected = [
      "alpha-has-a-configuration"
      "alpha-hostname-is-the-node-name"
      "alpha-selects-base"
      "gamma-has-a-configuration"
      "gamma-hostname-is-the-node-name"
      "gamma-selects-base"
    ];
  };
  layer-proof-passes-a-square-fleet = {
    expr = failing (proof goodConfigs);
    expected = [ ];
  };
  layer-proof-fails-a-node-without-base = {
    expr = failing (
      proof (
        goodConfigs
        // {
          gamma.config = goodConfigs.gamma.config // {
            kata.nodeLayers.selected = [ "seat" ];
          };
        }
      )
    );
    expected = [ "gamma-selects-base" ];
  };
  layer-proof-fails-a-misnamed-node = {
    expr = failing (
      proof (
        goodConfigs
        // {
          alpha.config = goodConfigs.alpha.config // {
            networking.hostName = "beta";
          };
        }
      )
    );
    expected = [ "alpha-hostname-is-the-node-name" ];
  };
  selection-imports-selected-layers-in-order = {
    expr = builtins.tail sel;
    expected = [
      base
      seat
    ];
  };
  selection-publishes-selected-and-parked = {
    expr = published;
    expected = {
      selected = [
        "base"
        "seat"
      ];
      parked = [ "edge" ];
    };
  };
  selection-option-path-is-a-parameter = {
    expr = customPublished.parked;
    expected = [
      "edge"
      "seat"
    ];
  };
  selection-rejects-missing-base-layer = {
    expr = selectThrows { seat = [ seat ]; } [ "seat" ];
    expected = true;
  };
  selection-rejects-unselected-base = {
    expr = selectThrows (layersOf layers) [ "seat" ];
    expected = true;
  };
  selection-rejects-unknown-layer = {
    expr = selectThrows (layersOf layers) [
      "base"
      "nope"
    ];
    expected = true;
  };
  selection-rejects-duplicate-layer = {
    expr = selectThrows (layersOf layers) [
      "base"
      "seat"
      "seat"
    ];
    expected = true;
  };
  mknode-reads-identity-from-the-blank = {
    expr = {
      inherit (alpha)
        system
        tags
        hostname
        sshUser
        deployable
        ;
    };
    expected = {
      system = "x86_64-linux";
      tags = [ "server" ];
      hostname = "alpha.example.org";
      sshUser = "root";
      deployable = true;
    };
  };
  mknode-composes-stack-then-universal = {
    expr = alpha.modules;
    expected = [
      "pleme"
      "nodes/alpha"
      "extra"
    ]
    ++ universal;
  };
  mknode-passes-hm-and-profile-to-the-stack = {
    expr =
      (declarer.mkNode {
        name = "alpha";
        hostname = "alpha";
        nodeDir = "nodes/alpha";
        stack = "hmProbe";
        hm = "dev";
        profile = "k3s";
      }).modules;
    expected = [
      "dev"
      "k3s"
    ]
    ++ universal;
  };
  mknode-defaults-are-a-parameter = {
    expr = { inherit (defaultedAlpha) sshUser deployable modules; };
    expected = {
      sshUser = "admin";
      deployable = false;
      modules = [ "dev" ];
    };
  };
  mknode-rejects-a-node-without-a-blank = {
    expr = mkThrows {
      name = "gamma";
      hostname = "gamma";
      nodeDir = "nodes/gamma";
    };
    expected = true;
  };
  mknode-rejects-a-darwin-blank = {
    expr = mkThrows {
      name = "beta";
      hostname = "beta";
      nodeDir = "nodes/beta";
    };
    expected = true;
  };
  mknode-rejects-an-unknown-stack = {
    expr = mkThrows {
      name = "alpha";
      hostname = "alpha";
      nodeDir = "nodes/alpha";
      stack = "nope";
    };
    expected = true;
  };
  mknode-rejects-an-unknown-hm-selection = {
    expr = mkThrows {
      name = "alpha";
      hostname = "alpha";
      nodeDir = "nodes/alpha";
      hm = "base";
    };
    expected = true;
  };
  mkdarwinnode-reads-identity-from-the-blank = {
    expr = declarer.mkDarwinNode {
      name = "beta";
      nodeDir = "nodes/beta";
    };
    expected = {
      system = "aarch64-darwin";
      tags = [ "workstation" ];
      nodeDir = "nodes/beta";
    };
  };
  mkdarwinnode-rejects-a-nixos-blank = {
    expr = throws (
      declarer.mkDarwinNode {
        name = "alpha";
        nodeDir = "nodes/alpha";
      }
    );
    expected = true;
  };
}
