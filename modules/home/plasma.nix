# Plasma's power settings and KWin window rules, declared.
#
# Scope is deliberately narrow: powerdevil and window rules, nothing else.
# plasma-manager can declare the whole desktop, but `overrideConfig` is left at
# its default of false, so everything not named here — panels, shortcuts,
# theming — stays hand-editable in System Settings and is simply persisted like
# before. Widening this file further is a decision to stop clicking those, and
# it is not made here.
#
# window-rules is the one entry where that split leaks, so it is worth knowing
# before adding a second one: declaring any rule writes General.count and
# General.rules into kwinrulesrc, and those are the index of *every* rule KWin
# has. A rule added by hand in System Settings is therefore orphaned on the next
# activation. Window rules are all-or-nothing — this file owns them now.
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

    # Wayland has no protocol for a client asking to be kept above other
    # windows, so an app's own "always on top" checkbox is a no-op — sticky's
    # calls GTK set_keep_above and is silently ignored. Only the compositor can
    # do it, which is what this rule is.
    #
    # `sticky.py` rather than `sticky`: KWin reports a GTK app's class from the
    # program name, and sticky is a python script, so the class carries the
    # extension. Confirmed against the live session rather than guessed —
    # `sticky` matches nothing. resourceName is `python3.14`, which would break
    # on the next interpreter bump, so match the class and not the name.
    #
    # substring with match-whole off, so a second window (sticky opens one pad
    # per note) is caught by the same rule. force, not initially, so toggling it
    # off in the window menu cannot outlive the next focus change.
    window-rules = [
      {
        description = "Keep sticky notes above other windows";
        match.window-class = {
          value = "sticky.py";
          type = "substring";
          match-whole = false;
        };
        apply.above = {
          value = true;
          apply = "force";
        };
      }
    ];
  };
}
