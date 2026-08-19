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

    # Plasma's settings live in ~/.config/*rc, which impermanence already
    # persists — so this is not about surviving a reboot. It is about surviving
    # an *install*: a fresh machine otherwise comes up with Plasma's defaults
    # and every power setting has to be re-clicked by hand.
    plasma-manager = {
      url = "github:nix-community/plasma-manager";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.home-manager.follows = "home-manager";
    };

    # tools.json's conventions list five checks to run before committing. Listing
    # them is not running them, so they are a `checks` output here and `nix flake
    # check` is what enforces them.
    #
    # Note this input's headline feature — installing a git pre-commit hook — does
    # nothing on this repo. jj has no hook support and bypasses .git/hooks entirely
    # (verified: a probe hook did not fire on `jj commit`). The checks derivation is
    # the half that works, and it works for any clone, hooks or not.
    git-hooks = {
      url = "github:cachix/git-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      disko,
      impermanence,
      home-manager,
      git-hooks,
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

      # nixos-generate-config writes this file and will overwrite it again. Every
      # nix linter must skip it: reformatting or de-linting it is an edit the file
      # forbids, and one the generator would undo.
      generatedNix = [ "^hosts/[^/]+/hardware-configuration\\.nix$" ];

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

      # Systems come from the hosts themselves, same as everything else here —
      # adding an aarch64 machine extends this with no edit.
      #
      # Every nix linter has to skip the one generated file. Not all of hosts/:
      # default.nix and disko.nix beside it are hand-written and want checking.
      checks =
        lib.genAttrs
          (lib.unique (
            lib.mapAttrsToList (_: host: host.pkgs.stdenv.hostPlatform.system) self.nixosConfigurations
          ))
          (system: {
            lint = git-hooks.lib.${system}.run {
              src = ./.;
              hooks = {
                nixfmt-rfc-style = {
                  enable = true;
                  excludes = generatedNix;
                };
                # statix is deliberately NOT in the gate, though the conventions
                # list it. It reports ~20 pre-existing findings, nearly all
                # `repeated_keys` — it wants boot.loader and boot.initrd merged
                # into one attrset, where this config writes flat paths with a
                # comment above each. That is a style disagreement, not a defect,
                # and gating on it would mean either rewriting twenty sites or
                # muting the lint. Run `statix check .` by hand and judge.
                # Its hook also ignores `excludes`, scanning repo-wide, so it
                # cannot skip the generated file either.
                deadnix = {
                  enable = true;
                  excludes = generatedNix;
                };
                shellcheck.enable = true;
                # Two spaces, matching the scripts already in claude/. shfmt defaults
                # to tabs, which would rewrite every line of them.
                shfmt = {
                  enable = true;
                  entry = lib.mkForce "${nixpkgs.legacyPackages.${system}.shfmt}/bin/shfmt -i 2 -d";
                  # installer.sh has never been shfmt'd — it needs 256 lines changed
                  # under any indent width. It partitions disks, writes an encryption
                  # keyfile and shreds it on every exit path; reformatting it wholesale
                  # as a side effect of adding a lint gate is a separate decision, and
                  # one to make deliberately. shellcheck still covers it.
                  excludes = [ "^installer\\.sh$" ];
                };
              };
            };
          });
    };
}
