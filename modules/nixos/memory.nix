{ config, ... }:
{
  zramSwap = {
    enable = true;
    algorithm = "zstd";
    # Derived from machine.memoryGiB — see machine.nix for why it targets a
    # fixed ~8 GiB rather than a fixed fraction.
    memoryPercent = config.machine.zramPercent;
    priority = 100; # above disk swap (priority 0)
  };

  # Without this, an OOM freezes the desktop for minutes before the kernel acts.
  # The two lists are the whole point: kill the compiler, spare the session.
  # Both thresholds are percentages, so they need no per-host adjustment.
  services.earlyoom = {
    enable = true;
    freeMemThreshold = 5;
    freeSwapThreshold = 10;
    extraArgs = [
      "--avoid"
      "^(sddm|sddm-greeter|plasmashell|kwin_wayland|systemd|dbus-daemon|Xwayland)$"
      "--prefer"
      "^(cargo|rustc|cc1plus|cc1|collect2|ld|lld|mold|node|go|link)$"
    ];
  };
}
