# Skills declared rather than installed. Every entry below reaches ~/.claude/skills —
# and ~/.codex/skills where it has been checked against Codex rather than assumed — as
# a read-only nix-store symlink, so law 4 holds: nothing under either directory is
# hand-written, and check-conventions.sh asserts it for both. It also avoids `claude
# plugin install`, whose loader writes state into ~/.claude/plugins that Nix does not
# own.
{ pkgs, ... }:
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
  # /herdr and checks HERDR_ENV=1 before it will touch anything — but that
  # gate excludes far less than it reads like it does. Since 2026-08-27
  # herdr is Alacritty's shell (modules/home/default.nix), so every terminal
  # window arrives already inside a pane with the variable set, this session
  # included. It still catches what is not a terminal at all — a cron run, a
  # cloud agent — which is why it is left in place rather than argued away,
  # but it is not what keeps the skill from firing unasked.
  #
  # That job belongs to the description herdr --skill writes, which says to
  # use the skill only when Herdr is explicitly named. The description is
  # therefore the standing cost: it sits in every session's prompt whether
  # or not the skill is ever invoked, and only the body is deferred until it
  # is. Roughly ninety tokens a session, which is the number to weigh if
  # dropping the skill is ever on the table.
  home.file.".claude/skills/herdr".source = herdrSkill;
  home.file.".codex/skills/herdr".source = herdrSkill;
}
