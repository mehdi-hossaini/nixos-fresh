# Skills declared rather than installed. Every entry below reaches ~/.claude/skills —
# and ~/.codex/skills where it has been checked against Codex rather than assumed — as
# a read-only nix-store symlink, so law 4 holds: nothing under either directory is
# hand-written, and check-conventions.sh asserts it for both. It also avoids `claude
# plugin install`, whose loader writes state into ~/.claude/plugins that Nix does not
# own.
{ inputs, pkgs, ... }:
let
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
  # Both agents — and the second only after being checked rather than assumed.
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
  # Generated above rather than authored: see herdrSkill. It loads flat as
  # /herdr and gates itself on HERDR_ENV=1, so it is inert in a session that
  # is not running inside a herdr pane — which is every session until you
  # start one.
  home.file.".claude/skills/herdr".source = herdrSkill;
  home.file.".codex/skills/herdr".source = herdrSkill;

  # github.com/anthropics/skills: the four document skills only, a deliberate
  # subset of the 19 upstream — adding another later is one more line here.
  # Linked one directory each, NOT as one whole link, because the
  # whole-bundle rule keys on .claude-plugin/plugin.json and this repo carries
  # only a marketplace.json: no plugin manifest, so a whole link would bury
  # every SKILL.md a level too deep (skills/<name>/SKILL.md) for flat
  # discovery. The four names collide with nothing in any current root
  # (checked against ~/.claude/skills and the built-in skill list, not
  # assumed). Claude only for now — none of the four has been verified
  # against Codex the way herdr was, so per that precedent the
  # ~/.codex/skills links wait for a `codex debug prompt-input` pass.
  #
  # Their bundled scripts expect python, node (+ the `docx` npm package),
  # pandoc, pdftoppm and soffice on PATH — true of Anthropic's cloud sandbox,
  # not of this machine. Nothing is installed for them on purpose (law 2):
  # the agent borrows per use, and a borrow that keeps recurring gets
  # promoted to packages.nix as its own decision.
  home.file.".claude/skills/docx".source = "${inputs.anthropic-skills}/skills/docx";
  home.file.".claude/skills/pdf".source = "${inputs.anthropic-skills}/skills/pdf";
  home.file.".claude/skills/pptx".source = "${inputs.anthropic-skills}/skills/pptx";
  home.file.".claude/skills/xlsx".source = "${inputs.anthropic-skills}/skills/xlsx";
}
