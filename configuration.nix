{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
let
  user = "mehti";
  fullName = "mehti";
  email = "littlemehti@gmail.com";

  # The password hash and the data-disk keyfile both live here rather than in
  # git or the Nix store. installer.sh writes them; nothing else recreates them.
  secretsDir = "/persistent/system/secrets";
  passwordHashFile = "${secretsDir}/user-password";
in
{
  # ═══ Boot ══════════════════════════════════════════════════════════════
  boot.loader.systemd-boot = {
    enable = true;
    # The ESP is 2G and one generation costs ~60-80 MiB here (no NVIDIA modules
    # in initrd — offload loads them late). 10 generations fits with room spare.
    configurationLimit = 10;
  };
  boot.loader.efi.canTouchEfiVariables = true;

  # systemd in the initrd: required for the rollback unit below to order itself
  # against systemd-cryptsetup@cryptroot.service, and the better-supported path
  # for LUKS generally.
  boot.initrd.systemd.enable = true;
  boot.supportedFilesystems = [
    "btrfs"
    "vfat"
  ];
  boot.kernelParams = [
    "quiet"
    "loglevel=3"
    "nowatchdog"
  ];

  # /tmp on disk, NEVER tmpfs. A tmpfs /tmp on 14G of RAM during a Rust link is
  # how you turn a slow build into an OOM.
  boot.tmp.useTmpfs = false;
  boot.tmp.cleanOnBoot = true;

  # ═══ Impermanence ══════════════════════════════════════════════════════
  # @root is deleted and recreated from @root-blank on every boot. Anything not
  # listed under environment.persistence below does not survive a reboot.
  #
  # The outgoing root is moved to old_roots/<timestamp> and kept for 7 days.
  # That week is the difference between "impermanence ate my file" being
  # recoverable and being permanent — worth ~10 lines.
  boot.initrd.systemd.services.rollback = {
    description = "Roll @root back to a blank snapshot";
    wantedBy = [ "initrd.target" ];
    after = [ "systemd-cryptsetup@cryptroot.service" ];
    before = [ "sysroot.mount" ];
    unitConfig.DefaultDependencies = "no";
    serviceConfig.Type = "oneshot";
    script = ''
      mkdir -p /btrfs_tmp
      mount -o subvolid=5 /dev/mapper/cryptroot /btrfs_tmp

      if [ -e /btrfs_tmp/@root ]; then
        mkdir -p /btrfs_tmp/old_roots
        mv /btrfs_tmp/@root "/btrfs_tmp/old_roots/$(date +%Y-%m-%d_%H%M%S)"
      fi

      # A subvolume with children cannot be deleted, and systemd/podman create
      # nested ones under /var — so recurse, deepest first.
      delete_recursively() {
        for sub in $(btrfs subvolume list -o "$1" | cut -f9 -d' '); do
          delete_recursively "/btrfs_tmp/$sub"
        done
        btrfs subvolume delete "$1"
      }

      for old in $(find /btrfs_tmp/old_roots/ -mindepth 1 -maxdepth 1 -mtime +7 2>/dev/null); do
        delete_recursively "$old"
      done

      btrfs subvolume snapshot /btrfs_tmp/@root-blank /btrfs_tmp/@root
      umount /btrfs_tmp
    '';
  };

  # btrfs-progs and find are not in the stock systemd initrd.
  boot.initrd.systemd.initrdBin = [
    pkgs.btrfs-progs
    pkgs.findutils
  ];

  # Both must be mounted before the rest of the system: /persistent holds the
  # password hash and the data keyfile, /nix holds everything else.
  fileSystems."/persistent".neededForBoot = true;
  fileSystems."/nix".neededForBoot = true;

  systemd.tmpfiles.rules = [
    "d /persistent/system/secrets 0700 root root -"
  ];

  environment.persistence."/persistent/system" = {
    hideMounts = true;
    directories = [
      "/etc/nixos"
      "/etc/NetworkManager/system-connections"
      "/etc/ssh"
      "/var/log"
      "/var/lib/nixos"
      "/var/lib/bluetooth"
      "/var/lib/systemd/coredump"
      "/var/lib/fwupd"
      "/var/lib/AccountsService"
      "/var/db/sudo"
    ];
    files = [ "/etc/machine-id" ];
  };

  environment.persistence."/persistent/userdata".users.${user}.directories = [
    "Projects"
    "Documents"
    "Downloads"
    "Pictures"
    "Videos"
    "Music"
    "Desktop"
    ".ssh"
    ".gnupg"
    # Wholesale, deliberately: Plasma owns its own config and we are not
    # declaring it. ~/.config/jj rides along here too.
    ".config"
    ".local/share"
    ".local/state"
    # "compiling a lot" — these two are pure rebuild cost. Losing them means
    # recompiling every dependency of every Rust project from scratch.
    ".cargo"
    ".cache/sccache"
  ];

  # ═══ Second disk: unlocked AFTER switch-root, not in the initrd ═════════
  # The keyfile lives on the encrypted root, so the initrd cannot read it —
  # which is the point: there is no key on the unencrypted ESP to steal.
  # systemd-cryptsetup-generator adds RequiresMountsFor= on the keyfile path
  # automatically, so the ordering against /persistent is handled for us.
  environment.etc.crypttab.text = ''
    cryptdata  /dev/disk/by-partlabel/disk-data-cryptdata  ${secretsDir}/cryptdata.key  luks,nofail,discard
  '';

  # ═══ Memory ════════════════════════════════════════════════════════════
  # 14G of RAM, permanent (2x8G SODIMM, both slots full, no upgrade planned).
  zramSwap = {
    enable = true;
    algorithm = "zstd";
    memoryPercent = 57; # ~8G of 14G
    priority = 100; # above the 64G disk swap (priority 0)
  };

  # Without this, an OOM freezes the desktop for minutes before the kernel acts.
  # The two lists are the whole point: kill the compiler, spare the session.
  services.earlyoom = {
    enable = true;
    freeMemThreshold = 5;
    freeSwapThreshold = 10;
    extraArgs = [
      "--avoid"
      "^(sddm|sddm-greeter|plasmashell|kwin_wayland|systemd|dbus-daemon|Xwayland)$"
      "--prefer"
      "^(cargo|rustc|cc1plus|cc1|collect2|ld|lld|mold|node|go|link)$"
    ];
  };

  # ═══ Nix ═══════════════════════════════════════════════════════════════
  nixpkgs.config.allowUnfree = true;

  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    # These MULTIPLY: peak concurrency is max-jobs x cores, not max-jobs. The
    # product is nproc (12) — saturated, never oversubscribed. 2x6 rather than
    # 3x4 or 4x3 because with a hard 14G ceiling the number of SIMULTANEOUS
    # derivations sets peak RAM, and 2 peaks lower than 3 for the same 12 cores.
    # Raise the product only if RAM ever stops being the binding constraint.
    max-jobs = 2;
    cores = 6;
    # Downloads use a separate pool the two above do not touch. The defaults are
    # tuned for hotel wifi; these cost RAM only in socket buffers.
    max-substitution-jobs = 32;
    http-connections = 50;
    use-xdg-base-directories = true;
    auto-optimise-store = false;

    substituters = [
      "https://devenv.cachix.org"
      "https://nix-community.cachix.org"
    ];
    trusted-public-keys = [
      "devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw="
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
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

  # ═══ Fonts ═════════════════════════════════════════════════════════════
  # Nothing was declared here before, so fontconfig fell back to Hack and there
  # were no icon glyphs on the system at all — eza --icons, btop, zellij and
  # jjui all draw tofu without a Nerd Font. Setting defaultFonts.monospace as
  # well means VS Code and Plasma agree with Alacritty instead of each picking
  # their own fallback.
  fonts = {
    packages = [ pkgs.nerd-fonts.jetbrains-mono ];
    fontconfig.defaultFonts.monospace = [ "JetBrainsMono Nerd Font Mono" ];
  };

  # ═══ Networking / locale ═══════════════════════════════════════════════
  networking.hostName = "nixos-machine";
  networking.networkmanager.enable = true;
  networking.firewall.enable = true;

  time.timeZone = "Europe/Stockholm";
  i18n.defaultLocale = "en_US.UTF-8";
  i18n.extraLocaleSettings.LC_TIME = "sv_SE.UTF-8";
  console.keyMap = "sv-latin1";

  # ═══ Users ═════════════════════════════════════════════════════════════
  users.mutableUsers = false;
  users.users.${user} = {
    isNormalUser = true;
    description = fullName;
    extraGroups = [
      "wheel"
      "networkmanager"
      "video"
      "audio"
      "input"
    ];
    hashedPasswordFile = passwordHashFile;
    shell = pkgs.fish;
  };
  programs.fish.enable = true;

  # mutableUsers = false and no root password means a missing hash file leaves
  # NO usable account and nothing to recover from. update-users-groups.pl only
  # warns; an empty file is worse than a missing one (empty = no password
  # required, not locked). The path is on /persistent so eval cannot check it —
  # this has to happen at activation.
  system.activationScripts.checkPasswordHash.text = ''
    if [ ! -s ${lib.escapeShellArg passwordHashFile} ]; then
      echo "ERROR: ${passwordHashFile} is missing or empty." >&2
      echo "       Every account on this host would be unusable. Fix before reboot:" >&2
      echo "         sudo install -d -m 0700 ${secretsDir}" >&2
      echo "         sudo sh -c 'mkpasswd -m sha-512 > ${passwordHashFile}'" >&2
      echo "         sudo chmod 600 ${passwordHashFile}" >&2
      false
    fi
  '';
  system.activationScripts.users.deps = [ "checkPasswordHash" ];

  # ═══ Desktop ═══════════════════════════════════════════════════════════
  services.xserver.enable = true; # needed for videoDrivers; the session is Wayland
  services.xserver.xkb = {
    layout = "se,ir";
    options = "caps:escape,grp:alt_shift_toggle";
  };

  services.displayManager.sddm = {
    enable = true;
    wayland.enable = true;
  };
  services.desktopManager.plasma6.enable = true;

  # ═══ GPU: RTX 4050 Max-Q + Radeon 760M, PRIME offload ══════════════════
  # Offload, not sync: the iGPU drives everything and the dGPU stays powered
  # down until something asks for it. On a laptop, sync mode costs 15-25W idle
  # for no benefit. Run a game or a CUDA job with:  nvidia-offload <cmd>
  services.xserver.videoDrivers = [ "nvidia" ];
  hardware.graphics.enable = true;
  hardware.graphics.enable32Bit = true;

  hardware.nvidia = {
    package = config.boot.kernelPackages.nvidiaPackages.stable;
    open = false; # proprietary, as decided
    modesetting.enable = true;
    nvidiaSettings = true;
    powerManagement.enable = true;
    # finegrained is what actually powers the dGPU down between offloads.
    # It requires prime.offload.enable, which is set below.
    powerManagement.finegrained = true;
    prime = {
      offload = {
        enable = true;
        enableOffloadCmd = true; # provides `nvidia-offload`
      };
      # lspci reports hex, this option takes decimal: 01:00.0 -> 1, 65:00.0 -> 101
      nvidiaBusId = "PCI:1:0:0";
      amdgpuBusId = "PCI:101:0:0";
    };
  };

  # ═══ Audio / hardware services ═════════════════════════════════════════
  security.rtkit.enable = true;
  services.pulseaudio.enable = false;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };

  hardware.bluetooth.enable = true;
  services.fwupd.enable = true;

  # ═══ Compile environment ═══════════════════════════════════════════════
  # Set globally so devenv shells inherit it — devenv has no sccache
  # integration of its own. A cache hit is zero compiles and zero RAM, which is
  # the only thing that beats a memory wall rather than merely surviving it.
  #
  # CARGO_BUILD_JOBS: nix's max-jobs/cores above do NOT bound cargo. Left alone
  # cargo grabs all 12 threads and OOMs on a Rust link at 14G.
  #
  # mold is deliberately NOT here — it belongs in each project's devenv.nix as
  # `languages.rust.mold.enable = true`.
  environment.variables = {
    RUSTC_WRAPPER = "sccache";
    CARGO_BUILD_JOBS = "6";
  };

  # ═══ Packages ══════════════════════════════════════════════════════════
  environment.systemPackages = with pkgs; [
    # Browser, terminal, editor
    brave-origin
    alacritty
    # Alacritty has no tabs by design, so the multiplexer is not optional here —
    # without it you get one OS window per task.
    zellij
    vscode

    claude-code

    # VCS — git stays regardless: jj uses it as its backend and gh speaks it.
    git
    gh
    jujutsu
    jjui

    # Dev environments. No rustc/cargo here on purpose: toolchains are
    # per-project via devenv's languages.rust (which uses rust-overlay
    # internally), so a system-wide rustc would only shadow them.
    devenv
    secretspec
    sccache

    # Agent toolbelt — the tools a coding agent reaches for via Bash. Structural
    # AST search beats regex grep for code patterns; the other two are the
    # pre-commit checks worth having on PATH rather than remembering to install.
    ast-grep
    shellcheck
    gitleaks

    # Ad-hoc Python tooling with no venv sprawl. There is one pyproject.toml
    # project in Projects/ and uv is also how one-off Python CLIs get run.
    uv

    # Nix tooling
    nh
    nixd
    statix
    nixfmt

    # CLI
    ripgrep
    fd
    eza
    bat
    fzf
    jq
    btop
  ];

  # `nh os switch` with no path argument.
  environment.sessionVariables.NH_FLAKE = "/etc/nixos";

  # ═══ Home Manager ══════════════════════════════════════════════════════
  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    backupFileExtension = "hm-bak";
    extraSpecialArgs = { inherit inputs user fullName email; };
    users.${user} = import ./home.nix;
  };

  system.stateVersion = "26.05";
}
