{ lib, ... }:
{
  # networking.hostName is set by flake.nix from the host directory name.
  networking.networkmanager.enable = true;
  networking.firewall.enable = true;

  # mkDefault throughout: these follow the operator, not the machine, but a host
  # that lives somewhere else can say so without touching this file.
  time.timeZone = lib.mkDefault "Europe/Stockholm";
  i18n.defaultLocale = lib.mkDefault "en_US.UTF-8";
  i18n.extraLocaleSettings.LC_TIME = lib.mkDefault "sv_SE.UTF-8";
  console.keyMap = lib.mkDefault "sv-latin1";
}
