# github.com/mattpocock/skills (MIT), declared rather than installed.
#
# Linked as ONE directory, not as 25 loose skills, because the repo is a Claude
# Code *plugin* — it carries .claude-plugin/plugin.json — and that changes how the
# skills are named. Any folder under a skills directory containing that manifest
# loads as `<name>@skills-dir`, discovered in place with no marketplace and no
# install step, and its skills are namespaced: `/mattpocock-skills:code-review`,
# not `/code-review`.
#
# That namespace is the whole point. Flattening the bundle into 25 entries under
# ~/.claude/skills/ strips it, and upstream's `code-review` then collides with the
# Claude Code built-in of the same name. The collision is manufactured by the
# flattening, not by upstream's naming — Anthropic's own plugin documentation uses
# `skills/code-review/SKILL.md` as its worked example, because inside a plugin the
# name cannot clash with anything. Linking the plugin whole keeps every skill,
# including that one.
#
# Law 4 still holds: this is a read-only store symlink, so nothing under
# ~/.claude/skills is hand-written and check-conventions.sh stays satisfied. It also
# avoids `claude plugin install`, whose loader writes state into ~/.claude/plugins
# that Nix does not own. `flake = false`, so `nix flake update` re-locks it and
# upstream's own manifest decides which skills exist — nothing to edit here when it
# changes.
{ inputs, pkgs, ... }:
let
  # The literal ${CLAUDE_PLUGIN_ROOT}, spelled as a nix value because a bare '' collides
  # with nix's own escape for a literal '' inside an indented string.
  pluginRootVar = "\${CLAUDE_PLUGIN_ROOT}";
  # ponytail carries BOTH .claude-plugin/plugin.json and .codex-plugin/plugin.json,
  # so the rule above applies to it twice: linked whole, once per agent, and its
  # six skills stay namespaced rather than colliding. Codex discovering them from
  # $CODEX_HOME/skills was verified against 0.147.0 rather than assumed — all six
  # showed up in `codex debug prompt-input`.
  #
  # The one thing that cannot be linked as-is is its hooks. All three shell out to
  # `node`, and node is deliberately absent from PATH here — tools.json lists it
  # under not_installed so that a system copy cannot shadow a project's pinned
  # toolchain (law 2). An ABSOLUTE store path shadows nothing, so the hook command
  # is rewritten to one instead of installing node: the assertion that `node` does
  # not resolve on PATH stays true, and the hooks still run. --replace-fail rather
  # than --replace, so an upstream rewrite that drops the literal breaks the build
  # here instead of silently producing hooks that cannot start.
  ponytail = pkgs.runCommand "ponytail" { } ''
    cp -r ${inputs.ponytail} $out
    chmod -R u+w $out
    substituteInPlace $out/hooks/claude-codex-hooks.json \
      --replace-fail '"command": "node ' '"command": "${pkgs.nodejs}/bin/node ' \
      --replace-fail '${pluginRootVar}' "$out"
    # Neither literal may survive: node would not resolve, and CLAUDE_PLUGIN_ROOT is
    # a Claude-only variable that Codex never sets, so under Codex the path expanded
    # empty and all three hooks failed every turn. Asserted rather than assumed,
    # because --replace-fail only guarantees at least one substitution, not that
    # every occurrence went.
    if grep -qF -e '"command": "node ' -e '${pluginRootVar}' $out/hooks/claude-codex-hooks.json; then
      echo "ponytail: an unrewritten node or CLAUDE_PLUGIN_ROOT survived the patch" >&2
      exit 1
    fi
  '';
in
{
  home.file.".claude/skills/mattpocock-skills".source = inputs.mattpocock-skills;
  home.file.".claude/skills/ponytail".source = ponytail;
  home.file.".codex/skills/ponytail".source = ponytail;
}
