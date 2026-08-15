# @root is deleted and recreated from @root-blank on every boot. Anything not
# listed below does not survive a reboot.
#
# This is shared across hosts because it depends on the *shape* of the layout,
# not on the disks: every disko template names the root LUKS container
# `cryptroot` and the subvolumes @root / @nix / @persistent. That naming is the
# contract between this file and templates/host/*/disko.nix — a host that
# renames them boots to a system that never rolls back.
{
  config,
  lib,
  pkgs,
  user,
  ...
}:
let
  cfg = config.machine;
in
{
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

  # /persistent is the one mount hideMounts below cannot reach — it comes from
  # disko, not impermanence. Set here rather than in the host's disko.nix
  # because the mountOptions there are shared with @root and @nix. fileSystems
  # options are a list, so module merging appends this to disko's rather than
  # replacing them.
  fileSystems."/persistent".options = [ "x-gvfs-hide" ];

  systemd.tmpfiles.rules = [
    "d ${cfg.secretsDir} 0700 root root -"
    # /etc/nixos is a bind mount of this path, and nixos-install leaves it
    # root-owned. That is a per-machine chore rather than a security boundary:
    # `nh os switch` refuses to run as root, and every commit here is yours, so
    # root ownership means either a manual chown on each new machine or
    # `sudo git -c user.name=... ` forever. Declaring it means a fresh install
    # comes up already usable. The tradeoff is the one POST-INSTALL always
    # described — anything running as you can edit the system config without a
    # password — and it was already being made by hand.
    #
    # Mode column is `-`: recurse ownership, leave permissions alone, so the
    # 0600s inside .git stay 0600.
    "Z /persistent/system/etc/nixos - ${user} ${config.users.users.${user}.group} -"
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
      # The whole tree rather than a list of subdirectories: timers, backlight,
      # rfkill, timesync, random-seed and coredump all live here and all want to
      # survive a boot. timers/ is the load-bearing one — nix-gc, nix-optimise
      # and fwupd-refresh are Persistent=yes, so wiping their last-run stamps
      # makes every boot look like a missed weekly run and fires a GC and a
      # store optimise minutes later. On a laptop backlight/ is the one you
      # notice: without it screen brightness resets on every boot.
      # Everything else under here (catalog, ephemeral-trees) is regenerated.
      "/var/lib/systemd"
      # /etc/NetworkManager/system-connections above is the config half; this is
      # the runtime half — secret_key, seen-bssids, timestamps, DHCP leases.
      # Unpersisted, NM mints a fresh secret_key every boot and forgets which
      # network you last used, which is what orders autoconnect.
      "/var/lib/NetworkManager"
      "/var/lib/fwupd"
      "/var/lib/AccountsService"
      "/var/db/sudo"
    ];
    files = [ "/etc/machine-id" ];
  };

  # Set as its own statement rather than nesting the list one level deeper: it
  # keeps the diff to a line. Without it every entry below shows up as a device
  # in Dolphin's sidebar, and the list is long enough now to bury the real ones.
  environment.persistence."/persistent/userdata".hideMounts = true;

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
    # Claude Code: credentials, session history and per-project memory. Not
    # under .config — it keeps its own tree, and .claude.json normally sits
    # loose in the home root where only a file-level bind mount could catch
    # it. That mount breaks the first time the app rewrites the file via
    # temp+rename, so CLAUDE_CONFIG_DIR (modules/home) moves the json in here
    # instead and one directory covers everything.
    ".claude"
    # VS Code puts *extensions* here, not in ~/.config/Code — that half holds
    # only settings and workspace state. Without this, every reboot is a full
    # extension reinstall.
    ".vscode"
    # Wholesale, deliberately: Plasma owns its own config and we declare only
    # the power settings (modules/home/plasma.nix) — everything else it writes
    # here is yours and unmanaged. ~/.config/jj rides along too.
    ".config"
    ".local/share"
    ".local/state"
    # "compiling a lot" — these two are pure rebuild cost. Losing them means
    # recompiling every dependency of every Rust project from scratch.
    ".cargo"
    ".cache/sccache"
    # Same argument as the two above — pure rebuild cost, no data. nix is the
    # eval cache, so without it every `nh os switch` re-evaluates this flake
    # cold. The two shader caches are why the first run of anything on the GPU
    # after a reboot stutters: the driver recompiles pipelines it already had.
    ".cache/nix"
    ".cache/mesa_shader_cache"
    ".cache/nvidia"
  ];

  # hideMounts already puts x-gvfs-hide on every impermanence mount unit, but
  # that option is userspace-only: it lives in /run/mount/utab, not in the
  # kernel mount table. These three are mounted too early for the utab write to
  # stick — journald pulls /var/log in before local-fs.target, /var/lib/nixos
  # rides along with it, and /etc/machine-id is bind-mounted by an activation
  # script that has no unit at all. So they alone stay visible in Dolphin.
  # Re-applying the option once /run/mount is usable is enough; remount,bind
  # touches only the userspace half and leaves the kernel flags as they are.
  systemd.services.hide-early-mounts = {
    description = "Re-apply x-gvfs-hide to mounts made before utab was writable";
    wantedBy = [ "multi-user.target" ];
    after = [ "local-fs.target" ];
    path = [ pkgs.util-linux ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      for m in /var/log /var/lib/nixos /etc/machine-id; do
        mount -o remount,bind,x-gvfs-hide "$m" || true
      done
    '';
  };

  # ═══ Second disk: unlocked AFTER switch-root, not in the initrd ═════════
  # The keyfile lives on the encrypted root, so the initrd cannot read it —
  # which is the point: there is no key on the unencrypted ESP to steal.
  # systemd-cryptsetup-generator adds RequiresMountsFor= on the keyfile path
  # automatically, so the ordering against /persistent is handled for us.
  environment.etc.crypttab = lib.mkIf cfg.hasDataDisk {
    text = ''
      cryptdata  /dev/disk/by-partlabel/disk-data-cryptdata  ${cfg.secretsDir}/cryptdata.key  luks,nofail,discard
    '';
  };
}
