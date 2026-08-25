# github.com/mattpocock/skills (MIT), declared rather than installed.
#
# Linked as ONE directory, not as 25 loose skills, because the repo is a Claude
# Code *plugin* â it carries .claude-plugin/plugin.json â and that changes how the
# skills are named. Any folder under a skills directory containing that manifest
# loads as `<name>@skills-dir`, discovered in place with no marketplace and no
# install step, and its skills are namespaced: `/mattpocock-skills:code-review`,
# not `/code-review`.
#
# That namespace is the whole point. Flattening the bundle into 25 entries under
# ~/.claude/skills/ strips it, and upstream's `code-review` then collides with the
# Claude Code built-in of the same name. The collision is manufactured by the
# flattening, not by upstream's naming â Anthropic's own plugin documentation uses
# `skills/code-review/SKILL.md` as its worked example, because inside a plugin the
# name cannot clash with anything. Linking the plugin whole keeps every skill,
# including that one.
#
# Law 4 still holds: this is a read-only store symlink, so nothing under
# ~/.claude/skills is hand-written and check-conventions.sh stays satisfied. It also
# avoids `claude plugin install`, whose loader writes state into ~/.claude/plugins
# that Nix does not own. `flake = false`, so `nix flake update` re-locks it and
# upstream's own manifest decides which skills exist â nothing to edit here when it
# changes.
{ inputs, pkgs, ... }:
let
  # The literal ${CLAUDE_PLUGIN_ROOT}, spelled as a nix value because a bare '' collides
  # with nix's own escape for a literal '' inside an indented string.
  pluginRootVar = "\${CLAUDE_PLUGIN_ROOT}";
  # ponytail carries BOTH .claude-plugin/plugin.json and .codex-plugin/plugin.json,
  # so the rule above applies to it twice: linked whole, once per agent, and its
  # six skills stay namespaced rather than colliding. Codex discovering them from
  # $CODEX_HOME/skills was verified against 0.147.0 rather than assumed â all six
  # showed up in `codex debug prompt-input`.
  #
  # The one thing that cannot be linked as-is is its hooks. All three shell out to
  # `node`, and node is deliberately absent from PATH here â tools.json lists it
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

  # herdr ships its skill inside the binary rather than as a file — `herdr
  # --skill` prints it — so "declared" here means generated at build time from
  # the very binary that will execute the commands it documents. That is the
  # stronger form of law 4, not a workaround for it: there is one source, and a
  # herdr upgrade rewrites the skill in the same rebuild that moves the binary.
  # A vendored copy could drift from the CLI it describes; this cannot.
  #
  # Checked before it is linked: --skill is not a stable public interface, and
  # a future release that drops the flag or renames the skill would otherwise
  # leave a valid-looking SKILL.md holding an error message or nothing at all.
  # The grep makes that a failed build instead. Watched going red on purpose by
  # inverting the pattern, per the obligation in CLAUDE.md.
  #
  # Both agents — and the second only after the same check ponytail's entry got.
  # `CODEX_HOME=<throwaway> codex debug prompt-input`, with this SKILL.md dropped
  # in, against codex-cli 0.147.0: herdr appeared in the skills block with its
  # description intact, read from the one file. No Codex-specific variant, and
  # nothing in the frontmatter needed translating.
  #
  # Done in a throwaway CODEX_HOME rather than after switching, because that
  # answers "will Codex see this" while the link still does not exist — so the
  # line below is added knowing rather than hoping.
  herdrSkill = pkgs.runCommand "herdr-skill" { } ''
    mkdir -p $out
    ${pkgs.herdr}/bin/herdr --skill > $out/SKILL.md
    if ! grep -qx 'name: herdr' $out/SKILL.md; then
      echo "herdr --skill no longer prints a skill naming itself 'herdr' —" >&2
      echo "the flag changed or was dropped; check 'herdr --help' before relinking." >&2
      exit 1
    fi
  '';
in
{
  home.file.".claude/skills/mattpocock-skills".source = inputs.mattpocock-skills;
  home.file.".claude/skills/ponytail".source = ponytail;
  home.file.".codex/skills/ponytail".source = ponytail;

  # Generated above rather than authored: see herdrSkill. It loads flat as
  # /herdr and gates itself on HERDR_ENV=1, so it is inert in a session that
  # is not running inside a herdr pane — which is every session until you
  # start one.
  home.file.".claude/skills/herdr".source = herdrSkill;
  home.file.".codex/skills/herdr".source = herdrSkill;
}
