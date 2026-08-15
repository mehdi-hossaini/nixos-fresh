{
  description = "Portable NixOS — KDE Plasma 6, impermanent root, full-disk encryption";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # No nixpkgs input to follow — impermanence is a pure module set.
    impermanence.url = "github:nix-community/impermanence";

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{
      nixpkgs,
      disko,
      impermanence,
      home-manager,
      ...
    }:
    let
      inherit (nixpkgs) lib;

      identity = import ./identity.nix;

      # Every directory under hosts/ is a host. Adding a machine is `mkdir
      # hosts/<name>` plus the three files installer.sh puts there — there is no
      # second list to keep in sync, and nothing here to edit.
      hostNames = lib.attrNames (
        lib.filterAttrs (_: type: type == "directory") (builtins.readDir ./hosts)
      );

      mkHost =
        hostName:
        lib.nixosSystem {
          # No `system` argument on purpose: hosts/<name>/hardware-configuration.nix
          # sets nixpkgs.hostPlatform, so an aarch64 machine needs no change here.
          specialArgs = {
            inherit inputs hostName;
          }
          // identity;
          modules = [
            disko.nixosModules.disko
            impermanence.nixosModules.impermanence
            home-manager.nixosModules.home-manager
            ./modules/nixos
            ./hosts/${hostName}
            # The directory name IS the hostname. mkDefault so a host can
            # disagree, but nothing does — `nh os switch` resolves
            # nixosConfigurations.<hostname>, and having those two drift is how
            # a renamed machine stops being able to rebuild itself.
            { networking.hostName = lib.mkDefault hostName; }
          ];
        };
    in
    {
      nixosConfigurations = lib.genAttrs hostNames mkHost;

      # `disko` reads this BEFORE nixosConfigurations can evaluate (there are no
      # filesystems yet, and on a fresh machine no hardware-configuration.nix
      # either). Same file as the host imports, no second source of truth.
      diskoConfigurations = lib.genAttrs hostNames (hostName: import ./hosts/${hostName}/disko.nix);
    };
}
