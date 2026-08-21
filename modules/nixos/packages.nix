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
    vscode
    prismlauncher

    claude-code

    # VCS — git stays regardless: jj uses it as its backend and gh speaks it.
    git
    gh
    jujutsu
    jjui

    # Dev environments. No rustc/cargo here on purpose: toolchains are
    # per-project via devenv's languages.rust (which uses rust-overlay
    # internally), so a system-wide rustc would only shadow them.
    devenv
    sccache

    # Agent toolbelt — the tools a coding agent reaches for via Bash. Structural
    # AST search beats regex grep for code patterns; the other two are the
    # pre-commit checks worth having on PATH rather than remembering to install.
    ast-grep
    shellcheck
    gitleaks
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
    eza
    bat
    fzf
    jq
    btop
  ];
}
