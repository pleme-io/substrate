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
      inherit (fleet) nixosConfigurations darwinConfigurations;

      # Typed deploy data (feed deploy-rs / colmena at your edge).
      fleetDeploy = fleet.deployRs;
      fleetRegistry = fleet.registry;

      checks = nixpkgs.lib.genAttrs [ "aarch64-darwin" "x86_64-linux" ] (
        system: fleet.checksFor (import nixpkgs { inherit system; })
      );
    };
}
