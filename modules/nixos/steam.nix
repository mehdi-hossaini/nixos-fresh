# Steam. `programs.steam`, not `environment.systemPackages`, because the package
# alone does not work here: Steam ships prebuilt 32-bit binaries and downloads
# more, none of which can find libraries at the paths they were linked against
# on a machine with no /usr/lib. The module answers that with an FHS sandbox the
# bare package has no way to bring with it — the same shape as winboat.nix
# beside this file, where what the repo declares is the system state a package
# cannot carry itself.
#
# Two things this needs were already true and are deliberately NOT restated here.
# nixpkgs.config.allowUnfree (modules/nixos/nix.nix) covers the licence, and
# hardware.graphics.enable32Bit (modules/nixos/hardware.nix) covers the 32-bit
# GL that is the usual reason a fresh Steam install renders nothing. A copy of
# either line here would be a second place to keep them true.
#
# Reversing a recorded decision, which is worth naming rather than quietly
# doing: POST-INSTALL.md listed Steam under "Not installed, on purpose" from the
# beginning, and that entry is removed in the same commit as this file. A
# decision that changes should read as changed, not as though it never happened.
{
  programs.steam.enable = true;

  # What is NOT enabled, so the next person does not have to test each one to
  # find out it was considered:
  #
  #   remotePlay.openFirewall     opens 27031-27036 to the LAN. Off until
  #                               streaming to another machine is actually
  #                               wanted; the firewall is enabled here.
  #   dedicatedServer.openFirewall  same argument, for hosting.
  #   gamescopeSession.enable     replaces the Plasma session with a gamescope
  #                               one at login. This is a desktop, not a
  #                               handheld, and Plasma is the session.
  #   extraCompatPackages         Proton-GE and friends. Valve's own Proton
  #                               ships with the client and is chosen per game
  #                               in the UI; add here only when a specific
  #                               title needs a specific build.
  #
  # Steam's own state is in impermanence.nix, where the list lives.
}
