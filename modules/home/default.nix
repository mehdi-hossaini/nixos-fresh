{
  pkgs,
  user,
  fullName,
  email,
  ...
}:
let
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
    base0F = "#f28534";
  };

  # Gruvbox's "hard" background, one step darker than base00. Used for the
  # window background *only* — ANSI color0 stays base00. Without this split the
  # two are the same value and black text renders invisible against the
  # background it is drawn on; the gap gives color0 somewhere to be seen.
  backgroundHard = "#1d2021";

  # One string, four styles. Change this to reface the terminal.
  terminalFont = "JetBrainsMono Nerd Font Mono";
in
{
  imports = [ ./plasma.nix ];

  home.username = user;
  home.homeDirectory = "/home/${user}";
  home.stateVersion = "26.05";

  programs.fish.enable = true;

  # devenv's workflow is `cd project && <shell loads>`. direnv is the piece that
  # makes that happen; without it every devenv shell is a manual command.
  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
    enableFishIntegration = true;
  };

  programs.git = {
    enable = true;
    settings = {
      user = {
        name = fullName;
        inherit email;
      };
      init.defaultBranch = "main";
      pull.rebase = true;
      # /etc/nixos is root-owned and this user is not root, so libgit2 refuses
      # to open it — which breaks `nh os switch`, since nh declines to run as
      # root. This is the declarative equivalent of `git config --global --add
      # safe.directory`, which cannot be run here: ~/.config/git/config is a
      # read-only store symlink.
      safe.directory = [ "/etc/nixos" ];
      push.autoSetupRemote = true;
      # jj writes its own operations through the git backend; this keeps the
      # colocated .git from re-packing constantly.
      gc.auto = 0;
    };
  };

  # jj does not replace git — it uses git repos as its backend, and `gh` talks
  # git. Both are installed; this just makes jj usable on day one.
  programs.jujutsu = {
    enable = true;
    settings = {
      user = {
        name = fullName;
        inherit email;
      };
      ui = {
        # Bare `jj` shows the log rather than the help text.
        default-command = "log";
        editor = "code --wait";
      };
      # Everything else is left at jj 0.44's defaults on purpose — `git.colocate`
      # and `git.track-default-bookmark-on-clone` are already true, and the
      # `git.auto-local-bookmark` you may have seen in older guides no longer
      # exists (checked against `jj util config-schema`, not from memory).
    };
  };

  # The operation log made visible. jj's model (no staging area, every change is
  # a commit, `jj undo` on anything) clicks far faster when you can see it.
  programs.jjui.enable = true;

  programs.alacritty = {
    enable = true;
    settings = {
      # ── Typography ──────────────────────────────────────────────────────
      # The Nerd Font *Mono* variant, not plain "Nerd Font": Mono forces icon
      # glyphs to single cell width. The proportional variants let icons bleed
      # into the next cell and shear the whole grid.
      font = {
        normal = {
          family = terminalFont;
          style = "Regular";
        };
        bold = {
          family = terminalFont;
          style = "Bold";
        };
        italic = {
          family = terminalFont;
          style = "Italic";
        };
        bold_italic = {
          family = terminalFont;
          style = "Bold Italic";
        };
        size = 12.5;
        # +2px of leading. Terminal output is unindented and left-aligned, so
        # the row is the only unit separating one line from the next — a little
        # air makes dense logs scannable without costing a font size.
        offset = {
          x = 0;
          y = 2;
        };
      };

      # ── Frame ───────────────────────────────────────────────────────────
      window = {
        # Asymmetric on purpose: the eye reads the left edge on every single
        # line, so horizontal margin does more work than vertical. Equal padding
        # looks correct in a screenshot and feels cramped in use.
        padding = {
          x = 14;
          y = 10;
        };
        dynamic_padding = true;
        # Deliberately opaque. Transparency puts a moving, arbitrary background
        # behind antialiased glyph edges, which is exactly where legibility is
        # decided — and Plasma's blur wakes the dGPU for the compositor.
        opacity = 1.0;
        blur = false;
        decorations = "Full";
        dynamic_title = true;
      };

      cursor = {
        style = {
          shape = "Block";
          # No blink. A blinking cursor is motion in the periphery, and it never
          # stops — it competes for attention with the output you are reading.
          blinking = "Off";
        };
        # Hollow when unfocused, so "which window has my keystrokes" is
        # answerable at a glance across several terminals.
        unfocused_hollow = true;
      };

      # ── Behaviour ───────────────────────────────────────────────────────
      scrolling = {
        history = 50000;
        multiplier = 3;
      };

      selection = {
        save_to_clipboard = true;
        # Default set minus '/' and '-', so double-click grabs a whole path or a
        # kebab-case flag instead of one fragment of it.
        semantic_escape_chars = ",│`|:\"' ()[]{}<>\t";
      };

      mouse.hide_when_typing = true;

      # Visual bell off. duration = 0 disables the flash entirely.
      bell.duration = 0;

      keyboard.bindings = [
        # Alacritty has no tabs by design, so a new window is the tab. This is
        # the one binding worth adding — CreateNewWindow reuses the running
        # process, unlike SpawnNewInstance which starts a second one.
        {
          key = "N";
          mods = "Control|Shift";
          action = "CreateNewWindow";
        }
      ];

      # ── Colour ──────────────────────────────────────────────────────────
      colors = {
        primary = {
          background = backgroundHard;
          foreground = theme.base05;
          dim_foreground = theme.base04;
          bright_foreground = theme.base07;
        };

        cursor = {
          text = theme.base00;
          cursor = theme.base05;
        };

        # Bright blue, so vi mode is unmistakably a different mode.
        vi_mode_cursor = {
          text = theme.base00;
          cursor = themeBright.base0D;
        };

        # Explicit selection foreground rather than CellForeground: selected
        # text keeping its own colour is unreadable when that colour is dark
        # against base02.
        selection = {
          background = theme.base02;
          text = theme.base07;
        };

        # The two oranges earn their keep here. Search needs "a match" and "the
        # match" to be distinct at a glance, and orange-vs-yellow separates
        # without introducing a colour foreign to the palette.
        search = {
          matches = {
            foreground = theme.base00;
            background = theme.base0A;
          };
          focused_match = {
            foreground = theme.base00;
            background = theme.base09;
          };
        };

        hints = {
          start = {
            foreground = theme.base00;
            background = theme.base0A;
          };
          end = {
            foreground = theme.base00;
            background = theme.base04;
          };
        };

        footer_bar = {
          foreground = theme.base05;
          background = theme.base01;
        };

        normal = {
          black = theme.base00;
          red = theme.base08;
          green = theme.base0B;
          yellow = theme.base0A;
          blue = theme.base0D;
          magenta = theme.base0E;
          cyan = theme.base0C;
          white = theme.base03;
        };

        bright = {
          black = theme.base02;
          red = themeBright.base08;
          green = themeBright.base0B;
          yellow = themeBright.base0A;
          blue = themeBright.base0D;
          magenta = themeBright.base0E;
          cyan = themeBright.base0C;
          white = theme.base07;
        };

        # `dim` is left underived on purpose: gruvbox's faded variants are far
        # too dark on this background, and Alacritty's automatic dimming beats
        # anything hand-picked here.

        # Gruvbox's own convention: the oranges live at 16 and 17, because ANSI
        # has no orange. Anything written for gruvbox reaches for these.
        indexed_colors = [
          {
            index = 16;
            color = theme.base09;
          }
          {
            index = 17;
            color = theme.base0F;
          }
        ];
      };
    };
  };

  programs.bat.enable = true;
  programs.fzf = {
    enable = true;
    enableFishIntegration = true;
  };

  home.sessionVariables = {
    EDITOR = "code --wait";
    # Relocates .claude.json into ~/.claude, which is a persisted directory
    # (modules/nixos/impermanence.nix). Left unset, it lives loose in the home root
    # and does not survive a reboot. Verified against claude-code 2.1.228:
    # with this set, the json is created inside the directory, not beside it.
    CLAUDE_CONFIG_DIR = "/home/${user}/.claude";
  };
}
