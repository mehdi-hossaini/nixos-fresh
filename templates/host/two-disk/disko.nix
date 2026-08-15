# Disk layout — TWO DISKS. Evaluates standalone so `disko` can read it before
# the system exists.
#
#   MAIN disk   2G      ESP, vfat ─────────────── /boot        (unencrypted — required)
#               rest    LUKS "cryptroot" ──────── btrfs
#                                                 ├── @root        /            (wiped every boot)
#                                                 ├── @nix         /nix
#                                                 └── @persistent  /persistent
#
#   DATA disk   @SWAP_SIZE@  random-key swap ──── swap         (new key every boot)
#               rest    LUKS "cryptdata" ──────── btrfs @data → /data
#
# ONE passphrase, total. cryptroot is unlocked by passphrase in the initrd;
# cryptdata is unlocked after switch-root from a keyfile that lives on the
# already-decrypted /persistent (see environment.etc.crypttab in
# modules/nixos/impermanence.nix). Swap needs no key at all — with hibernation
# off, its contents are worthless after power-off, so a fresh random key each
# boot is both simpler and strictly more secure than a stored one.
#
# The AT-delimited placeholders are filled in by installer.sh when it copies
# this template into hosts/<name>/, which then checks that none survived. It
# copies; it never edits a host's file in place.
#
# The names below are load-bearing, not cosmetic: the LUKS container MUST be
# `cryptroot`, the subvolumes MUST be @root/@nix/@persistent, and the data
# partition MUST be disk `data`, partition `cryptdata`. modules/nixos names all
# four — the initrd rollback unit and /etc/crypttab find them by those names.
#
# A host using this layout sets `machine.hasDataDisk = true`.
let
  btrfsMountOptions = [
    "noatime"
    "compress=zstd:1"
    "discard=async"
    "commit=120"
  ];
in
{
  disko.devices.disk = {
    main = {
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

    data = {
      type = "disk";
      device = "@DATA_DISK@";
      content = {
        type = "gpt";
        partitions = {
          swap = {
            priority = 1;
            size = "@SWAP_SIZE@";
            content = {
              type = "swap";
              randomEncryption = true;
              # Below zram (priority 100) — compressed RAM gets used first, and
              # this only takes the overflow.
              priority = 0;
              discardPolicy = "both";
            };
          };

          cryptdata = {
            size = "100%";
            content = {
              type = "luks";
              name = "cryptdata";
              # Used by disko at FORMAT time only; installer.sh generates it and
              # then copies it to /persistent/system/secrets/cryptdata.key.
              # Runtime unlock is /etc/crypttab, NOT the initrd — the real
              # keyfile lives on the encrypted root, which the initrd cannot read.
              settings.keyFile = "/tmp/cryptdata.key";
              settings.allowDiscards = true;
              initrdUnlock = false;
              content = {
                type = "btrfs";
                extraArgs = [
                  "-f"
                  "-L"
                  "data"
                ];
                subvolumes."@data" = {
                  mountpoint = "/data";
                  # nofail: a data disk that does not come up must not wedge boot.
                  mountOptions = btrfsMountOptions ++ [ "nofail" ];
                };
              };
            };
          };
        };
      };
    };
  };
}
