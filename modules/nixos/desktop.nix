{ lib, ... }:
{
  services.xserver.enable = true; # needed for videoDrivers; the session is Wayland
  services.xserver.xkb = {
    layout = lib.mkDefault "se,ir";
    options = lib.mkDefault "caps:escape,grp:alt_shift_toggle";
  };

  services.displayManager.sddm = {
    enable = true;
    wayland.enable = true;
  };
  services.desktopManager.plasma6.enable = true;

  # The base graphics stack. Which *driver* fills it is a host decision —
  # services.xserver.videoDrivers and hardware.nvidia live in hosts/<name>.
  hardware.graphics.enable = true;
  hardware.graphics.enable32Bit = true;
}
