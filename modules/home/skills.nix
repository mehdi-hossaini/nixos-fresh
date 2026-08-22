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
{ inputs, ... }:
{
  home.file.".claude/skills/mattpocock-skills".source = inputs.mattpocock-skills;
}
