# Disk layout — ONE DISK. Evaluates standalone so `disko` can read it before
# the system exists.
#
#   MAIN disk   2G           ESP, vfat ───────── /boot   (unencrypted — required)
#               @SWAP_SIZE@  random-key swap ─── swap    (new key every boot)
#               rest         LUKS "cryptroot" ── btrfs
#                                                 ├── @root        /  (wiped every boot)
#                                                 ├── @nix         /nix
#                                                 └── @persistent  /persistent
#
# The single-disk sibling of two-disk/disko.nix, and the layout to use on any
# machine that does not have a second NVMe to spare. Differences, both of them
# consequences of there being one disk:
#
#   - swap is a partition on the main disk instead of the data disk. Still
#     random-key encrypted, still below zram at priority 0. Sizing it is a real
#     decision here because it comes out of the same disk as /nix; with
#     hibernation off it does not need to exceed RAM.
#   - there is no /data and no `cryptdata`, so nothing to unlock after
#     switch-root. A host using this layout leaves `machine.hasDataDisk` false,
#     which is what drops the /etc/crypttab entry.
#
# Swap sits BEFORE cryptroot on purpose: exactly one partition can be "100%",
# and it has to be the last one.
#
# ONE passphrase, total — the initrd prompt for cryptroot.
#
# The AT-delimited placeholders are filled in by installer.sh when it copies
# this template into hosts/<name>/, which then checks that none survived. It
# copies; it never edits a host's file in place.
#
# The names below are load-bearing, not cosmetic: the LUKS container MUST be
# `cryptroot` and the subvolumes MUST be @root/@nix/@persistent — the initrd
# rollback unit in modules/nixos/impermanence.nix finds them by those names.
let
  btrfsMountOptions = [
    "noatime"
    "compress=zstd:1"
    "discard=async"
    "commit=120"
  ];
in
{
  disko.devices.disk.main = {
    type = "disk";
    device = "@MAIN_DISK@";
    content = {
      type = "gpt";
      partitions = {
        ESP = {
          priority = 1;
          size = "2G";
          type = "EF00";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot";
            mountOptions = [ "umask=0077" ];
          };
        };

        swap = {
          priority = 2;
          size = "@SWAP_SIZE@";
          content = {
            type = "swap";
            randomEncryption = true;
            priority = 0; # below zram (100)
            discardPolicy = "both";
          };
        };

        cryptroot = {
          size = "100%";
          content = {
            type = "luks";
            name = "cryptroot";
            askPassword = true;
            settings.allowDiscards = true;
            content = {
              type = "btrfs";
              extraArgs = [
                "-f"
                "-L"
                "nixos"
              ];
              subvolumes = {
                "@root" = {
                  mountpoint = "/";
                  mountOptions = btrfsMountOptions;
                };
                "@nix" = {
                  mountpoint = "/nix";
                  mountOptions = btrfsMountOptions;
                };
                "@persistent" = {
                  mountpoint = "/persistent";
                  mountOptions = btrfsMountOptions;
                };
              };
            };
          };
        };
      };
    };
  };
}
