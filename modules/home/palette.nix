# The gruvbox palette, as data. Not a home-manager module — a plain attrset,
# imported by modules/home/default.nix for the terminal and by flake.nix for the
# contrast check. It sits on its own so that check costs one `import` rather than a
# full module-system evaluation, and so the palette is a thing you can point at.
#
# Every contrast figure in the comments below is asserted by
# `checks.alacritty-contrast`. They were accurate when measured and they are checked
# now, which is the difference between a note and a guarantee.
{
  # Gruvbox dark. Supplied palette, used verbatim.
  #
  # base03 is pinned to ANSI color7 rather than the usual #a89984, which pushes
  # the grays up one step — so color8 (bright black) takes base02 to keep the
  # luminance ladder intact: color0 < color8 < color7 < color15.
  theme = {
    base00 = "#282828"; # bg / ANSI color0
    base01 = "#3c3836"; # footer bar
    base02 = "#504945"; # selection bg / ANSI color8
    base03 = "#928374"; # comments / ANSI color7 — NOT base16-gruvbox's #665c54
    base04 = "#bdae93"; # dim foreground
    base05 = "#ebdbb2"; # body text — upstream gruvbox fg1, not base16's dimmer fg2
    base06 = "#ebdbb2";
    base07 = "#fbf1c7"; # ANSI color15
    base08 = "#cc241d";
    base09 = "#fe8019"; # orange — no ANSI slot, see indexed_colors
    base0A = "#d79921";
    base0B = "#98971a";
    base0C = "#689d5a";
    base0D = "#458588";
    base0E = "#b16286";
    base0F = "#d65d0e"; # orange, dark — no ANSI slot, see indexed_colors
  };

  themeBright = {
    base08 = "#fb4934";
    base09 = "#fe8019";
    base0A = "#fabd2f";
    base0B = "#b8bb26";
    base0C = "#8ec07c";
    base0D = "#7daea3";
    base0E = "#d3869b";
    # No ANSI slot, like its dark twin, and nothing reads it today — index 17
    # resolves to orangeDark below. Kept so this attrset stays a complete
    # base16 palette, and listed in checks.alacritty-contrast anyway (6.39:1),
    # because a foreground value a consumer could start reading tomorrow is not
    # one to leave unmeasured.
    base0F = "#f28534";
  };

  # A third tier, needed because themeBright moved down into the ANSI normal
  # slots. Each value is its themeBright counterpart mixed 28% toward base07, so
  # the hue is unchanged and only the luminance moves. That keeps normal and
  # bright visibly different, which programs rely on for emphasis, without
  # inventing colours that are foreign to gruvbox.
  #
  # Measured against the window background: 6.20:1 red through 10.74:1 yellow.
  themeVivid = {
    base08 = "#fb785d";
    base0A = "#facb59";
    base0B = "#caca53";
    base0C = "#accd91";
    base0D = "#a0c0ad";
    base0E = "#dea3a7";
  };

  # 256-colour index 17, gruvbox's darker orange, raised until it clears AA.
  #
  # ANSI has no orange slot, so gruvbox parks two at indexes 16 and 17, and both
  # are FOREGROUND — programs written for gruvbox reach for them the way they
  # reach for red or blue. Index 16 is theme.base09 and clears at 6.49:1. Index
  # 17's supplied value does not: base0F #d65d0e measures 4.24:1 on
  # backgroundHard, under the 4.5 every other text slot here is held to. It sat
  # that way unnoticed because checks.alacritty-contrast did not list either
  # index — the same "the dark set fails where it is read most" finding that put
  # themeBright into the ANSI normal slots, reaching two slots the mapping
  # happened not to cover.
  #
  # This is base0F with its HSV value raised 8% and hue and saturation held
  # (#d65d0e x 1.08). Mixing toward base07, the way themeVivid is built, reaches
  # the same ratio at 10% — but it desaturates on the way, and a pale orange
  # stops reading as the darker of the pair, which is the only reason index 17
  # exists beside 16. Holding saturation is what keeps it a burnt orange.
  #
  # 4.86:1, and the step down from index 16 narrows from 1.53:1 to 1.34:1. That
  # narrowing is the price of AA on a #1d2021 ground and is written down rather
  # than hidden: there is not much room between 4.5 and base09's 6.49, so a pair
  # of oranges that both clear cannot be as far apart as gruvbox's own.
  #
  # theme.base0F above keeps the supplied #d65d0e so that attrset stays what it
  # says it is. Nothing reads it now; this is what indexed_colors 17 resolves to.
  orangeDark = "#e7640f";

  # Gruvbox's "hard" background, one step darker than base00. Used for the
  # window background *only* — ANSI color0 stays base00. Without this split the
  # two are the same value and black text renders invisible against the
  # background it is drawn on; the gap gives color0 somewhere to be seen.
  #
  # Measured 2026-08-22: that gap is 1.11:1. It is a separation, not a contrast —
  # enough to place an edge, not enough to read across. Which is the correct
  # ambition for two backgrounds, and the reason no text colour resolves to either.
  backgroundHard = "#1d2021";
}
