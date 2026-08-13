{
  pkgs,
  user,
  fullName,
  email,
  ...
}:
{
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
      window = {
        padding = {
          x = 8;
          y = 8;
        };
        dynamic_padding = true;
      };
      scrolling.history = 50000;
      font.size = 11;
      # Alacritty has no tabs by design — Plasma's window management or tmux
      # covers it. `selection.save_to_clipboard` at least makes copy painless.
      selection.save_to_clipboard = true;
    };
  };

  programs.bat.enable = true;
  programs.fzf = {
    enable = true;
    enableFishIntegration = true;
  };

  home.sessionVariables = {
    EDITOR = "code --wait";
  };
}
