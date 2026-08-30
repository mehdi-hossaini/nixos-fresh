# Plasma's power settings and the panel's removal, declared.
#
# Scope is deliberately narrow: powerdevil, plus one desktop script.
# plasma-manager can declare the whole desktop, but `overrideConfig` is left at
# its default of false, so everything not named here — shortcuts, theming, the
# widget layout — stays hand-editable in System Settings and is simply persisted
# like before. Widening this file is a decision to stop clicking those, and it is
# made one entry at a time rather than by flipping overrideConfig.
#
# window-rules is where that split would leak, and none is declared here now —
# the one rule this file held kept sticky's notes above other windows, and went
# with sticky. Worth knowing before adding one back: declaring any rule writes
# General.count and General.rules into kwinrulesrc, and those are the index of
# *every* rule KWin has, so a rule added by hand in System Settings is orphaned
# at the next activation. Window rules are all-or-nothing — declaring one here
# takes ownership of the lot.
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

    # No panel. plasma-manager runs this through
    # `qdbus org.kde.plasmashell /PlasmaShell evaluateScript` at login
    # (its modules/startup.nix), which is the same call that removed the panel
    # by hand — so what is declared here is exactly what was done live.
    #
    # `programs.plasma.panels = [ ]` would be the obvious spelling and does
    # nothing: modules/panels.nix gates the whole module on
    # `anyPanelSet = (builtins.length cfg.panels) > 0`, so an empty list means
    # "panels unmanaged", not "no panels". A script is the only narrow way to
    # say it without taking ownership of the entire Plasma config.
    #
    # runAlways, because the alternative is worse in both directions: without
    # it the script runs only when its own text changes, so a fresh machine
    # that has never run it is fine but a panel added later survives forever.
    # The cost is the mirror image, and it is the thing to remember here — a
    # panel added by hand in System Settings is deleted at the next login, with
    # no message saying why. Delete this block to get panels back, not
    # `Add Panel`.
    startup.desktopScript."no-panel" = {
      text = "panels().forEach(panel => panel.remove())";
      runAlways = true;
    };

  };
}
