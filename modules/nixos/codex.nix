# Codex's half of the enforcement layer, mirroring modules/nixos/claude.nix.
#
# The rules are the same rules and the guards are literally the same scripts —
# ./agent-guards.nix holds them and this file instantiates them as Codex's. What
# differs is everything about how they are ATTACHED, because Codex's model is not
# Claude's in three ways worth knowing before reading further.
#
# 1. There is no declarative deny list. Claude gets `permissions.deny` with
#    `Bash(<prefix> *)` patterns, generated from tools.json's agent_unsafe. Codex
#    has nothing equivalent: its requirements.toml `[rules]` is a network and
#    sandbox-executable policy, not a command matcher. So the TUI denies that are
#    declarative over there are a hook here — tuiGuard below, built from the same
#    tools.json field so the two agents cannot disagree about what is unsafe.
#
# 2. There is no per-hook `if`. Claude filters each guard with `if = "Bash(jj
#    commit *)"`; Codex has only `matcher`, a regex over the tool name. Every
#    guard therefore fires on every Bash call. That costs nothing and breaks
#    nothing, because each guard already re-establishes its own trigger from $cmd
#    — see the `requires` comment in agent-guards.nix. The defensive design that
#    existed because Claude's `if` could not be trusted is what makes the guards
#    portable to an agent that has no `if` at all.
#
# 3. There is no escalate. This is the one that matters; see escalateFn below.
#
# Two files, because Codex splits what Claude keeps in one. requirements.toml is
# enforced and the user cannot override it — that is the wall. managed_config.toml
# beside it is only a default the user may change mid-session, so nothing that
# needs teeth goes there.
{
  pkgs,
  lib,
  ...
}:
let
  jq = "${pkgs.jq}/bin/jq";

  # The same derivation claude.nix makes, from the same field, so a tool declared
  # interactive is interactive for both agents or for neither.
  inventory = builtins.fromJSON (builtins.readFile ../../tools.json);
  agentUnsafe = lib.unique (lib.concatMap (t: t.agent_unsafe or [ ]) inventory.tools);

  # How Codex says "I could not tell" — and the reason this file exists rather
  # than a symlink to Claude's settings.
  #
  # Claude escalates: it asks, and the user decides. That is the one answer that
  # is never silently wrong, which is why agent-guards.nix reaches for it on every
  # undecidable payload. Codex cannot do it. Its PreToolUse parses
  # permissionDecision "escalate" and "ask", marks the hook FAILED, and runs the
  # command anyway — verified against the published hook reference for 0.147.0.
  # Passing Claude's escalate through unchanged would therefore convert every
  # careful "ask" in every guard into a silent allow, leaving walls that read as
  # total and are holes.
  #
  # So it collapses to deny: fail closed. The reason says which it is, because a
  # deny the command did not earn should not read like one it did.
  escalateFn = ''
    escalate() {
      ${jq} -n --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:("This guard could not decide, and Codex has no way to ask — permissionDecision \"escalate\" is parsed, marked failed, and the command runs anyway, so asking would be the same as allowing. It denies instead. If the command was fine, this is the collapse showing, not a rule you broke: say so and it can be run another way.\n\n" + $r)}}'
      exit 0
    }
  '';

  guards = import ./agent-guards.nix {
    inherit pkgs jq;
    a = {
      prefix = "codex";
      displayName = "Codex";
      rulesFile = "AGENTS.md";
      rulesPath = "~/.codex/AGENTS.md";
      # The store path rather than ~/.claude/check-conventions.sh: the check is
      # about the machine, not about Claude, and reaching through the other
      # agent's home directory would make this depend on that symlink existing.
      conventionsScript = "${../../claude/check-conventions.sh}";
      inherit escalateFn;
    };
  };

  # tools.json's agent_unsafe, as a hook rather than as a deny list — see note 1
  # in the header. Matching is on a padded, separator-flattened probe so a verb is
  # found the same way whether it opens the command or follows a pipe, which is
  # the trick spillPaginationGuard already uses.
  tuiGuard = pkgs.writeShellScript "codex-guard-tui" ''
    ${guards.guardPreamble}
    probe=$(printf ' %s ' "$cmd" | tr ';|&()\n\t' '       ')
    case $probe in
    ${lib.concatMapStringsSep " | " (c: ''*" ${c} "*'') agentUnsafe})
      ${jq} -n '{
        hookSpecificOutput: {
          hookEventName: "PreToolUse",
          permissionDecision: "deny",
          permissionDecisionReason: "law 2 and law 3: this is an interactive TUI, and a session with no terminal cannot drive it — it will hang rather than fail. tools.json lists it under agent_unsafe, which is where both agents get this rule from. Its purpose note there names the scriptable form where one exists."
        }
      }'
      exit 0
      ;;
    esac
    exit 0
  '';

  # `matcher` is a regex over the tool name. "Bash" is correct and is not a
  # guess: Codex normalises its unified exec tool to that name for hook purposes,
  # so `exec_command` arrives as Bash with the command in tool_input.command —
  # which is the field agent-guards.nix already reads.
  #
  # shellcheckGate is deliberately NOT here. It keys on tool_input.file_path, and
  # Codex's file-editing tool (apply_patch) reports tool_input.command instead —
  # so it would find nothing and exit 0 on every call, which is the one failure
  # mode worse than an absent guard: a wall that is trusted and is not there.
  # Porting it needs a reader for apply_patch's command format first.
  mkHook = command: statusMessage: timeout: {
    type = "command";
    inherit command timeout statusMessage;
  };

  toml = pkgs.formats.toml { };

  requirements = toml.generate "codex-requirements.toml" {
    hooks.PreToolUse = [
      {
        matcher = "^Bash$";
        hooks = [
          (mkHook "${tuiGuard}" "Checking for an interactive TUI" 10)
          (mkHook "${guards.colocatedCommitGuard}" "Checking for a colocated repo" 10)
          (mkHook "${guards.publishGate}" "Gating on gitleaks + nix flake check" 180)
          (mkHook "${guards.untrackedNixGuard}" "Checking for untracked nix files" 10)
          (mkHook "${guards.commandShapeGuard}" "Checking the command shape" 10)
          (mkHook "${guards.spillPaginationGuard}" "Checking for a paginated spill read" 10)
        ];
      }
    ];
  };

  # Law 3, as far as this layer can carry it. The editor pins are environment,
  # and environment is not in requirements.toml's vocabulary — so they land in the
  # defaults file, which the user can change mid-session. That makes this the one
  # rule here that is a default rather than a wall, and it is worth saying rather
  # than leaving to be discovered.
  managedConfig = toml.generate "codex-managed-config.toml" {
    shell_environment_policy.set = {
      JJ_EDITOR = "false";
      GIT_EDITOR = "false";
      EDITOR = "false";
      VISUAL = "false";
    };
  };
in
{
  environment.etc."codex/requirements.toml".source = requirements;
  environment.etc."codex/managed_config.toml".source = managedConfig;
}
