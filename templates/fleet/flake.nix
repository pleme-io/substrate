{
  description = "A kata-standard fleet repo — private configuration over the pleme-io Nix vocabulary";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    substrate = {
      url = "github:pleme-io/substrate";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nix-darwin = {
      url = "github:nix-darwin/nix-darwin/nix-darwin-25.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    home-manager = {
      url = "github:nix-community/home-manager/release-25.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      substrate,
      nix-darwin,
      ...
    }@inputs:
    let
      kata = substrate.kata;

      # THE BLANKS — every fleet-specific fact lives in fleet.nix
      # (validated against kata's strict schema; a typo fails eval).
      fleet = kata.mkFleet {
        config = import ./fleet.nix;
        inherit inputs;
        universes = {
          nixosSystem = nixpkgs.lib.nixosSystem;
          darwinSystem = nix-darwin.lib.darwinSystem;
        };
        # Profile table: node `profiles = [ "name" ]` entries resolve here.
        # Add behavior by IMPORTING vocabulary (blackmatter components,
        # kata/iroha letters) — never by hand-rolling modules in this repo.
        profiles = {
          server-base = ./profiles/server-base.nix;
        };
      };
    in
    {
      # ── THE GATE ────────────────────────────────────────────────────
      # `fleet.shipping` is `fleet.*` with the whole invariant suite
      # forced first. Nothing in a fleet workflow invokes `checks`:
      # `nixos-rebuild` never looks at it, and a private fleet repo runs
      # no CI — so a declared-but-uninvoked check is not a weak gate, it
      # is nothing. Selecting a node here forces the verdict and a red
      # fleet THROWS, naming every failing case, before one byte is
      # built. TIER: eval-rejected (a Nix `throw`, not a compile error).
      #
      # Taking these from `fleet` directly instead is the ungated shape —
      # it still works, and still proves nothing.
      inherit (fleet.shipping) nixosConfigurations darwinConfigurations;

      # Typed deploy data (feed deploy-rs / colmena at your edge). Gated
      # too — deploy DATA for a fleet that fails its own invariants is
      # exactly what must not leave the repo.
      fleetDeploy = fleet.shipping.deployRs;
      fleetRegistry = fleet.shipping.registry;

      # Composed letters — derived for free from the one mkFleet call.
      # `fleet.sshAliases` is shaped as blackmatter.components.ssh.extraHosts;
      # `fleet.sshAliasesFor "<node>"` skips self; `fleet.wireguard` is the
      # per-node WireGuard projection (null unless you declare `vpnLinks`).
      fleetSshAliases = fleet.sshAliases;
      fleetWireguard = fleet.wireguard;

      # One typed query over the whole fleet:
      #   nix eval .#fleetReport --json | jq
      # DELIBERATELY UNGATED, like `checks` below — when the gate is red
      # these are how you find out why. A gate that also blinds the
      # diagnostics is unusable rather than strict.
      fleetReport = fleet.report;

      checks = nixpkgs.lib.genAttrs [ "aarch64-darwin" "x86_64-linux" ] (
        system: fleet.checksFor (import nixpkgs { inherit system; })
      );
    };
}
