# Plasma's power settings, declared.
#
# Scope is deliberately narrow: only powerdevil. plasma-manager can declare the
# whole desktop, but `overrideConfig` is left at its default of false, so
# everything not named here — panels, shortcuts, theming — stays hand-editable
# in System Settings and is simply persisted like before. Widening this file is
# a decision to stop clicking those, and it is not made here.
{
  programs.plasma = {
    enable = true;

    # The three tabs of System Settings → Power Management, in order. They are
    # separate profiles, and that is the whole point of this file: setting only
    # the AC tab leaves battery and lowBattery on Plasma's defaults, which
    # suspend after ~5 and ~2 minutes of idle. Unplugging the laptop and walking
    # away was therefore enough to put it to sleep no matter what the AC tab
    # said.
    powerdevil =
      let
        # "Stay awake" — the same answer for all three profiles. Anything that
        # differs between them (screen timeouts) is spelled out per-profile
        # below rather than hidden in here.
        stayOn = {
          autoSuspend.action = "nothing";
          # No autoSuspend.idleTimeout: the module asserts that a timeout
          # cannot be set alongside the "nothing" action, and a timeout for an
          # action that does nothing would be meaningless anyway.
          whenLaptopLidClosed = "doNothing";
          powerButtonAction = "showLogoutScreen";
        };
      in
      {
        AC = stayOn // {
          dimDisplay.enable = false;
          # The display still sleeps — that is not the machine sleeping, and it
          # costs nothing to get back. 10 minutes unlocked, 1 minute once the
          # screen is locked, since at that point nobody is reading it.
          turnOffDisplay = {
            idleTimeout = 600;
            idleTimeoutWhenLocked = 60;
          };
        };

        battery = stayOn // {
          # Dimming is worth having on battery — it is reversible on the next
          # keypress, unlike a suspend, and the panel is the biggest draw here.
          dimDisplay.idleTimeout = 120;
          turnOffDisplay = {
            idleTimeout = 300;
            idleTimeoutWhenLocked = 60;
          };
        };

        lowBattery = stayOn // {
          dimDisplay.idleTimeout = 60;
          turnOffDisplay = {
            idleTimeout = 120;
            idleTimeoutWhenLocked = 60;
          };
        };

        # batteryLevels.criticalAction is deliberately left undeclared, so
        # Plasma's default stands. With auto-suspend off on every profile, an
        # unplugged laptop now runs the battery flat — and the critical action
        # is the difference between a clean stop at ~5% and the hard power cut
        # you get at 0%. Turning it off buys minutes and risks the filesystem.
      };
  };
}
