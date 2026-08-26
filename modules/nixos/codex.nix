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
#    declarative over there are folded into the same deny hook here, generated from
#    the same tools.json field, so neither agent can disagree about what is unsafe.
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
  # Claude asks, and the user decides. That is the one answer that is never
  # silently wrong, which is why agent-guards.nix reaches for it on every
  # undecidable payload. Codex cannot do it. Its PreToolUse parses
  # permissionDecision "escalate" and "ask", marks the hook FAILED, and runs the
  # command anyway — verified against the published hook reference for 0.147.0.
  # Passing Claude's ask through unchanged would therefore convert every
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
      # Codex has no `tool-results` path — 0 occurrences in the 0.147.0 binary,
      # against 60 for `output_spill`. Both are matched so the guard is not simply
      # inert, but the second has NOT been seen in a real payload, which is why
      # AGENTS.md calls this rule best-effort rather than enforced.
      spillMatch = ''*"tool-results/"* | *"output_spill"*'';
      inherit escalateFn;
    };
  };

  denies = import ./agent-denies.nix { inherit lib agentUnsafe; };

  # Claude's permissions.deny, as a hook — because Codex has none. A `Bash(<glob>)`
  # pattern and a shell `case` glob mean the same thing, so the translation is
  # mechanical: quote the literal runs and leave the `*`s outside, since a case
  # pattern with a bare space in it is a syntax error rather than a wide match.
  toCasePattern =
    p:
    lib.concatStringsSep "*" (
      map (s: if s == "" then "" else lib.escapeShellArg s) (lib.splitString "*" p)
    );

  denyGuard = pkgs.writeShellScript "codex-guard-denies" ''
    ${guards.guardPreamble}
    deny() {
      ${jq} -n --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
      exit 0
    }
    # Segmented rather than matched whole, so `jj log && jj split` is caught on its
    # second half instead of sliding past. `segments` is agent-guards.nix's, out of
    # guardPreamble above — this loop used to carry its own copy of the splitter,
    # which meant the code deciding whether a deny fires existed twice and could be
    # corrected in one place only. The trimming rule and the bug behind it are
    # written down there.
    while IFS= read -r seg; do
      case "$seg" in
      ${lib.concatMapStringsSep "\n      " (
        g:
        "${lib.concatMapStringsSep " | " toCasePattern g.patterns}) deny ${lib.escapeShellArg g.reason} ;;"
      ) (denies.bashGroups ++ denies.tuiGroups)}
      esac
    done <<SEGMENTS
    $(segments)
    SEGMENTS
    exit 0
  '';

  # The file rule. Claude states it once as `Edit(path)` and that governs every
  # file tool it has; Codex has no file permission at all, so the same rule has to
  # read apply_patch's own command text. Broader than the path glob deliberately —
  # see agent-denies.nix.
  applyPatchGuard = pkgs.writeShellScript "codex-guard-apply-patch" ''
    set -u
    ${escalateFn}
    input=$(cat)
    cmd=$(printf '%s' "$input" | ${jq} -r '.tool_input.command // empty') ||
      escalate "guard could not read the patch out of the hook payload."
    # Total, like every other guard here. It used to fall through to `exit 0` when
    # the command was empty, which made it a silent allow on any payload shaped
    # differently from apply_patch's — the failure this file rejects shellcheckGate
    # for, five entries below. An empty command means "cannot tell", not "fine".
    [ -n "$cmd" ] ||
      escalate "the hook payload carried no command, so this guard cannot tell which file is being written."
    case "$cmd" in
    ${denies.fileRule.codexMatch}) ;;
    *) exit 0 ;;
    esac
    ${jq} -n --arg r ${lib.escapeShellArg denies.fileRule.reason} '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: $r
      }
    }'
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
      # First, and with NO matcher, so it covers apply_patch and anything else
      # Codex grows as well as the exec aliases below. Every other guard here
      # objects to a particular command; this one objects to the session
      # continuing at all, so a file edit has to hit it too.
      #
      # Omitted rather than "*": ConfiguredHookMatcherGroup types the field as
      # `matcher: string | null`, so an absent key is the match-all this schema
      # actually documents. claude.nix spells the same intent "*" because its
      # matcher is an exact string unless it contains regex characters — same
      # wall, two vocabularies, each verified against its own agent.
      {
        hooks = [
          (mkHook "${guards.estopGuard}" "Checking the stop switch" 5)
        ];
      }
      {
        matcher = "^(Bash|exec_command|shell_command|unified_exec|local_shell)$";
        hooks = [
          (mkHook "${denyGuard}" "Checking the deny list" 10)
          (mkHook "${guards.colocatedCommitGuard}" "Checking for a colocated repo" 10)
          (mkHook "${guards.publishGate}" "Gating on gitleaks + nix flake check" 180)
          (mkHook "${guards.untrackedNixGuard}" "Checking for untracked nix files" 10)
          (mkHook "${guards.commandShapeGuard}" "Checking the command shape" 10)
          (mkHook "${guards.spillPaginationGuard}" "Checking for a paginated spill read" 10)
        ];
      }
      {
        # apply_patch is what Codex reports for a file edit; the docs allow Edit
        # and Write as matcher aliases, so all three are named rather than betting
        # on which one a future version sends.
        matcher = "^(apply_patch|Edit|Write)$";
        hooks = [
          (mkHook "${applyPatchGuard}" "Checking the file rule" 10)
        ];
      }
    ];

    # The first non-PreToolUse event wired here, and the spelling was verified
    # rather than assumed — an unknown key in this file is ignored SILENTLY, which
    # is the same failure that keeps the memories switch out of feature_requirements
    # below. Codex's wire enum spells the event `sessionStart` (camelCase, in
    # HookEventName.ts), and this file has always written PreToolUse in PascalCase,
    # so the two spellings had to be told apart by something other than preference.
    #
    # Three local routes could not do it, which is worth recording so the next
    # person does not re-walk them: `codex doctor --json` does not report hooks at
    # all, `codex debug prompt-input` never executes the hook process (a probe
    # writing a sentinel file proved it, so its silence says nothing about the
    # spelling), and `debug app-server send-message-v2` takes a prompt and needs a
    # live session. One `codex exec` against codex-cli 0.149.0 settled all three
    # questions at once on 2026-08-26: PascalCase is the config key — Codex logged
    # `hook: SessionStart` and `hook: SessionStart Completed`; the payload carries
    # `cwd`, which is the one field this guard reads; and additionalContext reaches
    # the model, which replied with the sentinel word the injected context asked
    # for. A hook that reads as wired and is inert is the outcome that test exists
    # to rule out.
    #
    # No matcher: `source` ("startup") is this event's matcher field, and every way
    # a session begins begins on the same instructions.
    #
    # sessionStartContext is the one guard that ports here unchanged. The others
    # are shaped by the escalate-to-deny collapse at the top of this file, because
    # they decide whether a command runs; this one returns no permissionDecision at
    # all, so there is nothing for that collapse to act on.
    #
    # All four of its sections are live here; the PostToolUse block below is what
    # makes the fourth one work, and the reason it had to exist is written there.
    hooks.SessionStart = [
      {
        hooks = [
          (mkHook "${guards.sessionStartContext}" "Probing machine state" 15)
        ];
      }
    ];

    # Writes codex-nixos-built, which is what makes sessionStartContext's
    # unswitched-build section report anything on this side. Before this, only
    # claude.nix wired recordBuild, so Codex's marker was never written and that
    # section was silently skipped — an omission that reads as "nothing pending".
    #
    # The port needed a change in agent-guards.nix rather than just a line here.
    # claude.nix narrows recordBuild with `if = Bash(nh os build*)` before the hook
    # forks; requirements.toml has no per-hook `if`, so this matcher is as narrow as
    # this file can be, and every Bash call reaches the script. recordBuild now
    # re-establishes its own trigger from tool_input.command — the same fix the
    # `requires` comment in agent-guards.nix argues for, and not a stylistic one:
    # the nix eval it guards is 6.2s on this machine, which unguarded is 6.2s added
    # to every `ls` Codex runs.
    #
    # Same tool-name matcher as PreToolUse above, for the same reason: Codex
    # normalises its exec tool to Bash for hook purposes, and the aliases are named
    # rather than betting on which one a future version sends.
    #
    # conventionsCheck, the other hook claude.nix runs on PostToolUse, is
    # deliberately not here yet. It is gated on `Bash(nh *)` over there and carries
    # no internal trigger, so porting it needs the same treatment recordBuild just
    # got — worth doing, but it is a second change and not this one.
    hooks.PostToolUse = [
      {
        matcher = "^(Bash|exec_command|shell_command|unified_exec|local_shell)$";
        hooks = [
          (mkHook "${guards.recordBuild}" "Recording the built generation" 60)
        ];
      }
    ];
  };

  # Law 3, as far as this layer can carry it. The editor pins are environment,
  # and environment is not in requirements.toml's vocabulary — so they land in the
  # defaults file, which the user can change mid-session. That makes them defaults
  # rather than walls, and it is worth saying rather than leaving to be discovered.
  # The memories switch below is the second, and lands here for its own reason.
  managedConfig = toml.generate "codex-managed-config.toml" {
    # The mirror of claude.nix's autoMemoryEnabled = false. Codex spells it as a
    # feature: `codex features list` reports `memories` and its effective state, and
    # `[features] memories = false` beats a default-on — verified by flipping
    # fast_mode, which IS on by default, in a scratch CODEX_HOME. It reads false
    # today without this line, but that is the shipped default rather than a
    # decision, and a default is exactly the thing that can change under a rebuild.
    #
    # Not in requirements.toml, which does have a `feature_requirements` table that
    # would make this a wall. That table is read only from /etc/codex, so its value
    # vocabulary cannot be exercised from a scratch CODEX_HOME, and an unknown
    # feature key is ignored SILENTLY — a guessed spelling would read as enforced
    # while doing nothing, and could not be watched going red on purpose. A default
    # that is known to work beats a wall that might not. Move it if that changes.
    features.memories = false;

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
