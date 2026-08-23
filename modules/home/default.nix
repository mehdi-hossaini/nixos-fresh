{
  pkgs,
  user,
  fullName,
  email,
  ...
}:
let
  # The palette moved to ./palette.nix so flake.nix can assert its contrast figures
  # without evaluating the whole system. Same values, one import away.
  inherit (import ./palette.nix)
    theme
    themeBright
    themeVivid
    backgroundHard
    ;

  # One string, four styles. Change this to reface the terminal.
  terminalFont = "JetBrainsMono Nerd Font Mono";
in
{
  imports = [
    ./plasma.nix
    ./skills.nix
  ];

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
        # decorations = "Full" means the compositor draws a titlebar, and the
        # default here is "None", which means "whatever variant the system theme
        # is". A light titlebar above a #1d2021 terminal is the one seam in an
        # otherwise dark window, and it is decided by something outside this file.
        # Pin it, so the frame matches the thing it frames.
        decorations_theme_variant = "Dark";
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

      # Setting `hints.enabled` REPLACES Alacritty's built-in URL hint rather than
      # adding to it, so the default is restated verbatim below and the store-path
      # hint sits beside it. Drop the first entry and clicking a link stops working.
      #
      # The second is this machine's own: a /nix/store path is the single string
      # that appears most in a NixOS session and is the least typeable — 32 base32
      # characters nobody will retype correctly. Ctrl+Shift+P labels every one on
      # screen and copies the chosen one. Copy rather than open, because a store
      # path is usually wanted as an argument to the next command, not as a folder.
      # Ctrl+Shift+N is taken by CreateNewWindow below.
      hints.enabled = [
        {
          command = "xdg-open";
          hyperlinks = true;
          post_processing = true;
          persist = false;
          mouse.enabled = true;
          binding = {
            key = "O";
            mods = "Control|Shift";
          };
          regex = "(ipfs:|ipns:|magnet:|mailto:|gemini://|gopher://|https://|http://|news:|file:|git://|ssh:|ftp://)[^\\u0000-\\u001F\\u007F-\\u009F<>\"\\s{-}\\^⟨⟩`\\\\]+";
        }
        {
          # /nix/store/<32 base32 chars>-<name>, plus any path inside it.
          regex = "/nix/store/[0-9a-df-np-sv-z]{32}-[^\\s\"'`,;:()\\[\\]{}]+";
          action = "Copy";
          post_processing = false;
          persist = false;
          mouse.enabled = false;
          binding = {
            key = "P";
            mods = "Control|Shift";
          };
        }
      ];

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

  # Automated time tracker. Everything stays on this machine: aw-server binds
  # localhost:5600 and serves its own web UI there; nothing is sent anywhere.
  #
  # The watcher choice is forced by the session, and getting it wrong is silent.
  # Plasma 6 runs Wayland here, and ActivityWatch's own two watchers are both
  # blind to that: aw-watcher-window is X11-only (its Linux branch is `from .
  # import xlib`, there is no Wayland path at all) and aw-watcher-afk drives
  # pynput, which is the same story. aw-watcher-window-wayland exists for the
  # gap but needs wlr-foreign-toplevel-management, and its own README lists
  # KDE/KWin as unsupported. All three would start cleanly, connect to Xwayland,
  # and record nothing — the worst available failure, because the server and UI
  # still look healthy while the database stays empty.
  #
  # awatcher replaces both stock watchers with the one combination that can see
  # this session: a builtin KWin script for the active window, and the kde-idle
  # protocol for AFK. Its own config lives in ~/.config/awatcher rather than the
  # activitywatch/<name>/ path this module generates, so `settings` is left
  # unset on purpose — setting it would write a file nothing reads.
  #
  # Neither package goes on PATH; the units reference the store paths directly,
  # which is why both inventory entries carry "commands": []. Data lands in
  # ~/.local/share/activitywatch, persisted by the wholesale .local/share entry
  # in modules/nixos/impermanence.nix.
  services.activitywatch = {
    enable = true;
    package = pkgs.aw-server-rust;
    watchers.awatcher = {
      package = pkgs.awatcher;
      executable = "awatcher";
    };
  };

  # Text expander. The variant must match the session: espanso's own Linux docs
  # say an X11 build on Wayland "may install but silently fail to work", and
  # `loginctl show-session` reports Type=wayland Desktop=KDE here. So x11Support
  # is off — leaving both on makes the module wrap the two builds in a
  # $WAYLAND_DISPLAY dispatcher and carry an X11 closure this session never runs.
  #
  # Upstream calls Wayland support experimental, and it is why hardware.uinput is
  # enabled and the user is in the uinput group (modules/nixos/hardware.nix and
  # users.nix): with no compositor-level way to inject keystrokes, espanso types
  # through /dev/uinput. Missing either half fails silently, same as above.
  #
  # configs and matches become read-only store symlinks under ~/.config/espanso,
  # so triggers are declared here rather than edited in place — law 4. Adding one
  # is an edit here plus a switch, not a file written next to the running service.
  services.espanso = {
    enable = true;
    x11Support = false;
    matches = {
      base.matches = [
        {
          trigger = ":date";
          replace = "{{mydate}}";
        }
        {
          trigger = ":time";
          replace = "{{mytime}}";
        }
      ];
      global_vars.global_vars = [
        {
          name = "mydate";
          type = "date";
          params.format = "%Y-%m-%d";
        }
        {
          name = "mytime";
          type = "date";
          params.format = "%H:%M";
        }
      ];
    };
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
