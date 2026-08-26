# The seam between the two agent modules and the instructions they generate.
#
# claude.nix and codex.nix each attach the shared guards from agent-guards.nix, so
# each already knows which of them it wires. What had no home was the DIFFERENCE:
# ~/.codex/AGENTS.md tells a Codex session which of the walls its body describes
# are not there for it, and that sentence lived in modules/home/default.nix as
# hand-written prose, derived from nothing and checked by nothing. It went stale
# within three commits — see the absenceNotes comment in agent-guards.nix.
#
# So the two sides publish what they wired and the home module subtracts. Options
# rather than a shared data file on purpose: a data file would be a third place
# naming guards, and the point is that nothing names them twice. Both values below
# are DERIVED — from each side's own generated hook structure, and from the notes
# written beside the guards — so a guard becomes documented by being wired.
{ lib, ... }:
{
  options.agents = {
    wiredGuards = lib.mkOption {
      type = lib.types.attrsOf (lib.types.listOf lib.types.str);
      default = { };
      description = ''
        Per agent, the attribute names from agent-guards.nix that agent's module
        actually attaches to a hook. Set by claude.nix and codex.nix by reading
        back the hook structures they generate — never written by hand, which
        would be the second copy of the wiring this option exists to remove.
      '';
    };

    guardNotes = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = ''
        Per guard, one line saying what a session loses when that guard is not
        wired for it. Written beside the guards in agent-guards.nix and published
        here by claude.nix, which wires every one of them and therefore holds the
        complete set — two modules setting one option would conflict.
      '';
    };

    replayManifest = lib.mkOption {
      type = lib.types.attrsOf lib.types.path;
      default = { };
      description = ''
        Per agent, a generated JSON file listing every PreToolUse hook that agent
        attaches, each paired with the laws its guard declares in
        agent-guards.nix: offTrigger, skipOnTrigger and routes. This is the input
        claude/replay-guards.sh runs on — it replays the recorded command corpus
        through each and asserts totality, no-self-block and non-interference.

        Generated from the same hook structure that becomes managed-settings.json
        or requirements.toml, so the wiring is under test too: a guard that is
        written and never attached cannot appear here and pass three laws it is
        not subject to.
      '';
    };
  };
}
