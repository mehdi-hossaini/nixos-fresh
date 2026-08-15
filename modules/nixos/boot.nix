{ ... }:
{
  boot.loader.systemd-boot = {
    enable = true;
    # The ESP is 2G in every layout under templates/ and one generation costs
    # ~60-80 MiB. 10 generations fits with room spare.
    configurationLimit = 10;
  };
  boot.loader.efi.canTouchEfiVariables = true;

  # systemd in the initrd: required for the rollback unit in impermanence.nix to
  # order itself against systemd-cryptsetup@cryptroot.service, and the
  # better-supported path for LUKS generally.
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

  # /tmp on disk, NEVER tmpfs. A tmpfs /tmp on a memory-tight machine during a
  # Rust link is how you turn a slow build into an OOM.
  boot.tmp.useTmpfs = false;
  boot.tmp.cleanOnBoot = true;
}
