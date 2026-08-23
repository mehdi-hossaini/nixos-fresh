{ ... }:
{
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

  # For espanso (modules/home/default.nix). Wayland gives no application a way to
  # synthesise keystrokes into another window — that is the security model, not a
  # gap — so a text expander has to type through the kernel instead. This loads
  # the uinput module, creates the `uinput` group and adds the udev rule that
  # makes /dev/uinput group-writable; users.nix puts the user in that group.
  # Both halves are required, and neither announces itself when missing: espanso
  # starts, matches, and silently replaces nothing.
  hardware.uinput.enable = true;
}
