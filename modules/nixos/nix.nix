{ config, inputs, ... }:
{
  nixpkgs.overlays = [
    (import ../../overlays/prismlauncher-cracked.nix {
      prismlauncher-cracked = inputs.prismlauncher-cracked;
    })
  ];
  nixpkgs.config.allowUnfree = true;

  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    # These MULTIPLY: peak concurrency is max-jobs x cores, not max-jobs. Both
    # are derived from machine.threads and machine.memoryGiB so the product
    # saturates the host without oversubscribing it — see machine.nix.
    max-jobs = config.machine.buildJobs;
    cores = config.machine.buildCores;
    # Downloads use a separate pool the two above do not touch. The defaults are
    # tuned for hotel wifi; these cost RAM only in socket buffers.
    max-substitution-jobs = 32;
    http-connections = 50;
    use-xdg-base-directories = true;
    auto-optimise-store = false;

    substituters = [
      "https://devenv.cachix.org"
      "https://nix-community.cachix.org"
      "https://prismlauncher.cachix.org"
    ];
    trusted-public-keys = [
      "devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw="
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
      "prismlauncher.cachix.org-1:9/n/FGyABA2jLUVfY+DEp4hKds/rwO+SCOtbOkDzd+c="
    ];
  };

  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
  };
  nix.optimise = {
    automatic = true;
    dates = [ "weekly" ];
  };

  # `nh os switch` with no path argument. It resolves
  # nixosConfigurations.<hostname>, which flake.nix guarantees exists because
  # the hostname comes from the host directory name.
  environment.sessionVariables.NH_FLAKE = "/etc/nixos";
}
