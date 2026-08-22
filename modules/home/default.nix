{
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

        # The ANSI normal slots take gruvbox's bright values, not its dark ones.
        # Measured against this background, the dark set fails where it is read
        # most: red 3.00:1, magenta 3.87, blue 3.88, all under the 4.5 needed to
        # read comfortably, and red is what errors and diff removals use. The
        # bright set clears it everywhere, 4.77:1 at worst. Saturation rises with
        # the contrast, which is the same change seen from the other side.
        #
        # white takes base04 rather than base03: 7.53:1 instead of 4.47:1, and
        # the grey ladder stays monotonic, base00 < base02 < base04 < base07.
        normal = {
          black = theme.base00;
          red = themeBright.base08;
          green = themeBright.base0B;
          yellow = themeBright.base0A;
          blue = themeBright.base0D;
          magenta = themeBright.base0E;
          cyan = themeBright.base0C;
          white = theme.base04;
        };

        bright = {
          black = theme.base02;
          red = themeVivid.base08;
          green = themeVivid.base0B;
          yellow = themeVivid.base0A;
          blue = themeVivid.base0D;
          magenta = themeVivid.base0E;
          cyan = themeVivid.base0C;
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

  # `nix-locate <binary>` answers which package ships a file, without guessing at
  # attribute names — the lookup step that "a missing tool is a decision" asks for.
  # The database comes prebuilt from nix-index-database (see home-manager.nix);
  # nothing indexes anything on this machine.
  programs.nix-index = {
    enable = true;
    enableFishIntegration = true;
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

  # Claude Code's instructions and the check that keeps them honest are rules, so
  # they are declared here and reach ~/.claude as store symlinks — a fresh machine
  # built from this repo gets them, and editing the copy is impossible rather than
  # merely discouraged. Everything else under ~/.claude is *state* (settings.json's
  # theme, .claude.json, projects/, credentials) and stays writable and undeclared;
  # it survives reboots via the persisted path in modules/nixos/impermanence.nix.
  #
  # The rules half of settings.json — the editor guard and the nh hook — cannot live
  # here, because Claude Code must be able to write that file. It is declared as
  # managed settings instead; see modules/nixos/claude.nix.
  home.file = {
    ".claude/CLAUDE.md".source = ../../claude/CLAUDE.md;
    ".claude/check-conventions.sh" = {
      source = ../../claude/check-conventions.sh;
      executable = true;
    };
    # No skills are declared. `unslop` (vendored from cursor/plugins) was the only
    # one and was dropped 2026-08-22: its own description claimed it must always
    # apply, so its ~6.6 KB body loaded on essentially every session that wrote
    # prose, which is a standing cost for a style guide. The split it illustrated
    # still holds — a global skill belongs here, a project one in that project's
    # own repo — and check-conventions.sh keeps asserting that nothing under
    # ~/.claude/skills is hand-written, so the rule outlives the example.
  };
}
