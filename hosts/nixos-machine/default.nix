# nixos-machine — the laptop this config was first built on.
#
# Ryzen + RTX 4050 Max-Q, 14 GiB, two NVMe disks. Everything in this file is a
# fact about THIS hardware; everything else it runs is in ../../modules/nixos.
# The directory name is the hostname (see flake.nix).
{ config, ... }:
{
  imports = [
    ./hardware-configuration.nix
    ./disko.nix
  ];

  # ═══ What the shared modules need to know ══════════════════════════════
  machine = {
    threads = 12;
    # 2x8G SODIMM, both slots full, no upgrade planned. If that ever changes,
    # this is the only number to edit — max-jobs, cores, CARGO_BUILD_JOBS and
    # the zram size all follow from it.
    memoryGiB = 14;
    hasDataDisk = true;
  };

  # ═══ GPU: RTX 4050 Max-Q + Radeon 760M, PRIME offload ══════════════════
  # Offload, not sync: the iGPU drives everything and the dGPU stays powered
  # down until something asks for it. On a laptop, sync mode costs 15-25W idle
  # for no benefit. Run a game or a CUDA job with:  nvidia-offload <cmd>
  services.xserver.videoDrivers = [ "nvidia" ];

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
}
