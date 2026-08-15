{ pkgs, ... }:
{
  # Nothing was declared here before, so fontconfig fell back to Hack and there
  # were no icon glyphs on the system at all — eza --icons, btop, zellij and
  # jjui all draw tofu without a Nerd Font. Setting defaultFonts.monospace as
  # well means VS Code and Plasma agree with Alacritty instead of each picking
  # their own fallback.
  fonts = {
    packages = [ pkgs.nerd-fonts.jetbrains-mono ];
    fontconfig.defaultFonts.monospace = [ "JetBrainsMono Nerd Font Mono" ];
  };
}
