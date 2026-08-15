# @HOSTNAME@ — written by installer.sh from templates/host/default.nix.
#
# Everything in this file is a fact about THIS machine. Everything it runs is in
# ../../modules/nixos, which may not name a disk, a PCI address, a core count or
# a RAM size. The directory name is the hostname (see flake.nix).
{ ... }:
{
  imports = [
    ./hardware-configuration.nix
    ./disko.nix
  ];

  # ═══ What the shared modules need to know ══════════════════════════════
  # Detected at install time. If you add RAM, edit memoryGiB and nothing else —
  # max-jobs, cores, CARGO_BUILD_JOBS and the zram size all follow from it.
  # The placeholders are quoted so this template is still parseable Nix — it
  # formats and type-checks like any other file, and installer.sh substitutes
  # the quotes away along with the name.
  machine = {
    threads = "@THREADS@";
    memoryGiB = "@MEMORY_GIB@";
    hasDataDisk = "@HAS_DATA_DISK@";
  };

  # ═══ GPU ═══════════════════════════════════════════════════════════════
  # Nothing here means the machine uses whatever hardware-configuration.nix
  # detected — for Intel or AMD graphics that is correct and complete, since
  # modules/nixos/desktop.nix already enables hardware.graphics.
  #
  # An NVIDIA laptop needs a block here instead. Copy it from
  # hosts/nixos-machine/default.nix and fix the two bus IDs: `lspci | grep -E
  # 'VGA|3D'` reports hex, the options take decimal, so 01:00.0 -> "PCI:1:0:0"
  # and 65:00.0 -> "PCI:101:0:0".
}
