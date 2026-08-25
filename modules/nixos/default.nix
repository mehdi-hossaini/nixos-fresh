# Everything that is true on every machine. Nothing in this directory may name
# a disk, a PCI address, a core count or a RAM size — those are facts a host
# declares (see machine.nix) and these modules consume.
{
  imports = [
    ./machine.nix
    ./boot.nix
    ./impermanence.nix
    ./memory.nix
    ./nix.nix
    ./fonts.nix
    ./locale.nix
    ./users.nix
    ./desktop.nix
    ./hardware.nix
    ./packages.nix
    ./winboat.nix
    ./claude.nix
    ./codex.nix
    ./home-manager.nix
  ];

  system.stateVersion = "26.05";
}
