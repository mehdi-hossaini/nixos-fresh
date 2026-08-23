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

    # `nix fmt` did nothing here, and formatter settings were duplicated between
    # the checks output and each tool's flags. treefmt owns formatting now — one
    # config in treefmt.nix, reached as `nix fmt` and gated as checks.formatting.
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # The prebuilt index, not the nix-index package. `nix-index` builds its
    # database into ~/.cache/nix-index, which impermanence does not persist —
    # only .cache/{sccache,nix,mesa_shader_cache} survive — so a hand-built index
    # would evaporate on every reboot. This ships one and updates it weekly.
    nix-index-database = {
      url = "github:nix-community/nix-index-database";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Claude Code skills, MIT. `flake = false` because it is a content repo, not a
    # flake — `nix flake update` re-locks it, so there is no hand-written rev to go
    # stale. modules/home/skills.nix reads the curated list out of its
    # .claude-plugin/plugin.json rather than enumerating the directory, because the
    # repo also carries skills/deprecated/ that the manifest deliberately omits.
    mattpocock-skills = {
      url = "github:mattpocock/skills";
      flake = false;
    };

    # github.com/DietrichGebert/ponytail (MIT). Same `flake = false` reasoning as
    # the input above: a content repo, re-locked by `nix flake update`, with no
    # hand-written rev to go stale. modules/home/skills.nix links it for both
    # agents and explains the one thing that cannot be linked as-is.
    ponytail = {
      url = "github:DietrichGebert/ponytail";
      flake = false;
    };

    prismlauncher-cracked = {
      url = "github:Diegiwg/PrismLauncher-Cracked";
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
      treefmt-nix,
      ...
    }:
    let
      inherit (nixpkgs) lib;

      treefmtFor = system: treefmt-nix.lib.evalModule nixpkgs.legacyPackages.${system} ./treefmt.nix;

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

      # Systems come from the hosts themselves, like hostNames above — another
      # architecture extends the per-system outputs with no edit here.
      hostSystems = lib.unique (
        lib.mapAttrsToList (_: host: host.pkgs.stdenv.hostPlatform.system) self.nixosConfigurations
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

      # Systems come from the hosts themselves, same as everything else here —
      # adding an aarch64 machine extends this with no edit.
      formatter = lib.genAttrs hostSystems (system: (treefmtFor system).config.build.wrapper);

      # Two gates, split by what they are. Formatting is treefmt's, configured once
      # in treefmt.nix and applied by `nix fmt`; the linters below only report, so
      # they have nothing to duplicate. Keeping nixfmt and shfmt here as well would
      # mean two places deciding how this repo is formatted.
      checks = lib.genAttrs hostSystems (system: {
        formatting = (treefmtFor system).config.build.check self;

        # modules/home/palette.nix carries precise contrast figures in its comments
        # — "red 3.00:1", "6.20:1 red through 10.74:1 yellow", "7.53:1 instead of
        # 4.47:1". Every one was accurate when measured and nothing kept them that
        # way. A palette is exactly the kind of thing that gets a colour nudged and
        # nobody re-measures, and the failure is silent: text that is a little
        # harder to read is not an error anyone reports.
        #
        # This asserts the property those numbers exist to express — every ANSI
        # slot that carries TEXT clears WCAG AA, 4.5:1, against the window
        # background — rather than the numbers themselves, which would break on any
        # deliberate change. Reads palette.nix directly, so it costs an import
        # rather than a second nixosSystem evaluation.
        alacritty-contrast =
          let
            p = import ./modules/home/palette.nix;
            # The ANSI mapping from modules/home/default.nix. Backgrounds are absent
            # on purpose: base00, base02 and backgroundHard are grounds, and holding
            # a ground to a text ratio is a category error.
            text = with p; [
              themeBright.base08
              themeBright.base0B
              themeBright.base0A
              themeBright.base0D
              themeBright.base0E
              themeBright.base0C
              theme.base04
              themeVivid.base08
              themeVivid.base0B
              themeVivid.base0A
              themeVivid.base0D
              themeVivid.base0E
              themeVivid.base0C
              theme.base05
              theme.base07
            ];
          in
          nixpkgs.legacyPackages.${system}.runCommandLocal "alacritty-contrast" { } ''
            ${nixpkgs.legacyPackages.${system}.gawk}/bin/awk -v BG=${p.backgroundHard} '
              function chan(h,   c) { c = strtonum("0x" h) / 255
                return (c <= 0.03928) ? c / 12.92 : ((c + 0.055) / 1.055) ^ 2.4 }
              function lum(x) { return 0.2126 * chan(substr(x, 2, 2)) \
                                     + 0.7152 * chan(substr(x, 4, 2)) \
                                     + 0.0722 * chan(substr(x, 6, 2)) }
              function cr(a, b,   la, lb) { la = lum(a); lb = lum(b)
                return (la > lb) ? (la + 0.05) / (lb + 0.05) : (lb + 0.05) / (la + 0.05) }
              { v = cr($1, BG)
                printf "%-9s %5.2f:1 %s\n", $1, v, (v >= 4.5 ? "ok" : "FAILS AA")
                if (v < 4.5) bad++ }
              END { if (bad) { printf "\n%d colour(s) below 4.5:1 on %s.\n", bad, BG
                               print "Either raise the colour or move the ground; do not"
                               print "loosen this check, which is the only thing keeping"
                               print "the figures in palette.nix from becoming folklore."
                               exit 1 } }
            ' <<< '${lib.concatStringsSep "\n" text}'
            touch $out
          '';

        lint = git-hooks.lib.${system}.run {
          src = ./.;
          hooks = {
            # hosts/*/hardware-configuration.nix only — default.nix and disko.nix
            # beside it are hand-written and do get checked.
            deadnix = {
              enable = true;
              excludes = generatedNix;
            };
            shellcheck.enable = true;
            # statix went ungated for as long as the style disagreement was written
            # down instead of configured: it wanted boot.loader and boot.initrd
            # merged where this config writes flat paths with a comment above each.
            # statix.toml at the repo root now disables that rule and three other
            # house-style ones, which drops the tree to zero findings and makes
            # every OTHER lint it has enforceable — those were the real cost of
            # leaving it off. The excludes problem went with it: hardware-
            # configuration.nix was only ever flagged by repeated_keys, so with that
            # off it needs no exclusion. Verified 2026-08-22.
            statix.enable = true;
          };
        };
      });
    };
}
