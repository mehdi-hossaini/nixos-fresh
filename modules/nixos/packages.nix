{ config, pkgs, ... }:
{
  # ═══ Compile environment ═══════════════════════════════════════════════
  # Set globally so devenv shells inherit it — devenv has no sccache
  # integration of its own. A cache hit is zero compiles and zero RAM, which is
  # the only thing that beats a memory wall rather than merely surviving it.
  #
  # CARGO_BUILD_JOBS: nix's max-jobs/cores do NOT bound cargo. Left alone cargo
  # grabs every thread and OOMs on a Rust link. It tracks machine.buildCores so
  # a host with different hardware gets the right number without an edit here.
  #
  # mold is deliberately NOT here — it belongs in each project's devenv.nix as
  # `languages.rust.mold.enable = true`.
  environment.variables = {
    RUSTC_WRAPPER = "sccache";
    CARGO_BUILD_JOBS = toString config.machine.buildCores;
  };

  environment.systemPackages = with pkgs; [
    # Browser, terminal, editor
    brave-origin
    alacritty
    # Alacritty has no tabs by design, so the multiplexer is not optional here —
    # without it you get one OS window per task.
    zellij
    # The agent half of the same problem. zellij multiplexes panes; herdr
    # multiplexes *agents* — one rust binary that keeps their sessions alive as a
    # background server, marks every pane working / blocked / idle, and survives
    # the terminal that started it. That last part is what a zellij tab cannot
    # do: closing the window ends the agent with it.
    #
    # Packaged in nixpkgs, so law 1 is satisfiable without the `curl | sh` its
    # README leads with. 0.8.0 here against 0.8.2 upstream — the lag is nixpkgs',
    # not a pin, and nothing below depends on the difference.
    #
    # Its config and state land in ~/.config/herdr and ~/.local/state/herdr,
    # both already persisted wholesale. Its *worktrees* default to ~/.herdr,
    # which is the home root and is not — hence the entry in impermanence.nix.
    herdr
    # Notes. The vault is ordinary markdown on disk, so where it lives decides
    # whether it survives a reboot: put it under ~/Documents or ~/Projects,
    # which impermanence.nix persists. A vault in the home root does not.
    # Obsidian's own config sits in ~/.config/obsidian and rides along with the
    # wholesale .config entry there.
    obsidian
    prismlauncher

    claude-code
    # Second coding agent, same rules. Its instructions are ~/.codex/AGENTS.md,
    # generated in modules/home from claude/CLAUDE.md so the two agents read one
    # source rather than two copies that drift apart.
    #
    # The walls are modules/nixos/codex.nix, which generates
    # /etc/codex/requirements.toml from the same guards claude.nix uses — Codex
    # splits the admin layer in two and only that file is enforced, so nothing with
    # teeth goes in managed_config.toml beside it, which the user can change
    # mid-session. Read codex.nix before changing either: the guards are shared but
    # the way they attach is not, and one of them (shellcheck on write) does not
    # port at all.
    #
    # Bare `codex` opens a TUI and would hang a session with no terminal. It is
    # still kept out of tools.json's agent_unsafe: that list builds
    # `Bash(<prefix> *)` denies, and `codex *` would deny the safe `codex exec`
    # while very likely missing the bare invocation that actually hangs. An
    # inverted rule is worse than no rule.
    codex

    # VCS — git stays regardless: jj uses it as its backend and gh speaks it.
    git
    gh
    jujutsu

    # Dev environments. No rustc/cargo here on purpose: toolchains are
    # per-project via devenv's languages.rust (which uses rust-overlay
    # internally), so a system-wide rustc would only shadow them.
    devenv
    sccache

    # Agent toolbelt — the pre-commit checks worth having on PATH rather than
    # remembering to install.
    shellcheck
    gitleaks
    # The two survivors of a 2026-08-25 tool research pass that started from ~40
    # candidates: on a machine where no human reviews output, a PATH slot goes to
    # what lets an agent PROVE work rather than assert it, and only these two
    # earned one. typos spell-checks the prose this tree mostly is — its live
    # test found a real typo in agent-denies.nix with zero false positives, which
    # is what let it become a gate (flake.nix) rather than advice. hyperfine
    # turns "this is faster" into statistics with an exit code; `--style basic`,
    # because it ignores NO_COLOR. Everything else from the pass is documented in
    # tools.json's not_installed with its trigger, or was rejected.
    typos
    hyperfine
    # shfmt formats what shellcheck only complains about — the pair is worth
    # having together, since a lint-only setup leaves scripts unnormalised.
    shfmt
    # sponge is the reason for moreutils: `jq '…' f | sponge f` replaces
    # `jq '…' f > tmp && mv tmp f`, which is a redirect that truncates the file
    # before jq reads it if the temp step is ever dropped.
    moreutils
    # jq syntax over YAML, TOML and XML (yq/tomlq/xq). The python wrapper, not
    # yq-go: same query language as jq rather than a second one to learn.
    yq
    # Identify an unknown blob — a download, a screenshot, something with no
    # extension — before deciding what to do with it.
    file

    # Ad-hoc Python tooling with no venv sprawl. There is one pyproject.toml
    # project in Projects/ and uv is also how one-off Python CLIs get run.
    uv

    # Nix tooling. nixfmt formats, statix lints, deadnix finds bindings and
    # arguments nothing uses — three passes that do not overlap.
    nh
    nixd
    statix
    nixfmt
    deadnix

    # CLI
    ripgrep
    fd
    jq

    # The one-off half of law 1, in one step: `, <cmd>` resolves the command
    # through the same nix-index database nix-locate reads, fetches the package
    # and runs it, leaving nothing behind. No second database to build.
    comma
  ];
}
