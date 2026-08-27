{ pkgs, ... }:
{
  # Nothing was declared here before, so fontconfig fell back to Hack and there
  # were no icon glyphs on the system at all — eza --icons, btop, herdr and
  # jjui all draw tofu without a Nerd Font. Geist Mono is the face; it carries
  # no Nerd Font glyphs of its own, so JetBrainsMono stays installed and sits
  # second in the list purely as the icon fallback. Setting
  # defaultFonts.monospace means VS Code and Plasma agree with Alacritty
  # instead of each picking their own fallback.
  fonts = {
    packages = [
      pkgs.geist-font
      pkgs.nerd-fonts.jetbrains-mono
    ];
    fontconfig.defaultFonts.monospace = [
      "Geist Mono"
      "JetBrainsMono Nerd Font Mono"
    ];
  };
}
