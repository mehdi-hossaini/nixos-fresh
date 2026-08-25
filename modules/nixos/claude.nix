# Claude Code's *rules* — the editor guard, the deny list and the hooks — are
# configuration, so they are declared here rather than hand-written into the home
# directory. Claude Code reads /etc/claude-code/managed-settings.json ahead of
# ~/.claude/settings.json and wins on conflict, which is what makes this the right
# half of the split: settings.json stays writable for state (theme, dialogs) while
# the rules come from the repo and survive a reinstall.
#
# The instructions themselves (CLAUDE.md) and the convention checker are declared
# in modules/home — they belong to the user, not the system.
#
# The file is GENERATED from the attrset below rather than checked in as JSON.
# JSON cannot hold a comment, so for as long as this was a hand-written
# claude/managed-settings.json every "why" had to live over here, one file away
# from the rule it explained, and the two could drift. Three things follow from
# generating it: the reasoning sits beside the rule, hook scripts become real
# shell files with a shebang instead of \n-escaped strings, and — the point of
# the exercise — a rule can be DERIVED rather than restated. See agent-denies.nix.
{
  lib,
  pkgs,
  ...
}:
let
  # ── derived rules ───────────────────────────────────────────────────────────
  # The inventory already knows which tools hang a session with no terminal; it
  # said so in prose, and the deny list said it again in patterns. Two copies of
  # one fact is the shape every other part of this repo works to avoid, so the
  # patterns are built from tools[].agent_unsafe instead. Adding an interactive
  # tool to the inventory now denies it, the same way adding any tool already
  # extends check-conventions.sh. Reading the file is not IFD: it is a source
  # file in the flake, so fromJSON resolves at eval with nothing to realise.
  inventory = builtins.fromJSON (builtins.readFile ../../tools.json);
  agentUnsafe = lib.unique (lib.concatMap (t: t.agent_unsafe or [ ]) inventory.tools);
  denies = import ./agent-denies.nix { inherit lib agentUnsafe; };

  # ── hook scripts ────────────────────────────────────────────────────────────
  # jq and shellcheck are interpolated from the store; sed, printf and nix are
  # taken from PATH. The line is drawn at "would the hook fail silently without
  # it": dropping shellcheck from packages.nix must not quietly disable a gate,
  # whereas coreutils and the system nix are present on any NixOS host by
  # construction and cannot go missing on their own.
  jq = "${pkgs.jq}/bin/jq";

  # ── every guard is total ────────────────────────────────────────────────────
  # A guard that cannot understand its input used to `exit 0`, which reads as
  # "allow". Every one of these extracts `.cwd // empty` and then tests it, so a
  # payload without a cwd — a shape change upstream, a malformed line — produced an
  # empty string, matched no branch, and let the call through. It looked like a
  # wall and was a hole, and the hole was silent, which is the worst combination
  # because the wall is trusted.
  #
  # Exiting 0 is only honest when it means "this input is definitely not my
  # business". It is not honest when it means "I could not tell".
  #
  # The undecidable case escalates rather than denying. Denying would be the safe
  # reflex, but a payload shape change would then block every Bash call in the
  # session with no way through; escalating asks the user, which is the one answer
  # that is never silently wrong. PostToolUse has no such control — it reports
  # rather than blocks, and cannot allow anything by staying quiet — so the two
  # hooks below carry `set -u` and nothing more.
  escalateFn = ''
    escalate() {
      ${jq} -n --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"escalate",permissionDecisionReason:$r}}'
      exit 0
    }
  '';

  # The guards themselves live in ./agent-guards.nix, instantiated here as
  # Claude's. Nothing about them changed when they moved — this file's generated
  # managed-settings.json is byte-identical across the extraction, which is the
  # only claim worth making about a refactor of the enforcement layer.
  guards = import ./agent-guards.nix {
    inherit pkgs jq;
    a = {
      prefix = "claude";
      displayName = "Claude";
      rulesFile = "CLAUDE.md";
      rulesPath = "~/.claude/CLAUDE.md";
      conventionsScript = "~/.claude/check-conventions.sh";
      # The literal the harness puts in a spilled result path. Agent-specific:
      # Codex spills through a different shape entirely, so a guard keyed on this
      # one is inert there — see codex.nix.
      spillMatch = ''*"tool-results/"*'';
      inherit escalateFn;
    };
  };
  inherit (guards)
    publishGate
    colocatedCommitGuard
    sessionStartCheck
    recordBuild
    handoffOnStop
    shellcheckGate
    conventionsCheck
    commandShapeGuard
    untrackedNixGuard
    spillPaginationGuard
    ;

  # ── the notification hook ───────────────────────────────────────────────────
  # Not in agent-guards.nix, and not shared with Codex: this is neither a guard
  # nor cross-agent. It denies nothing, escalates nothing and cannot be wrong in
  # a way that costs anything — it is the one hook here that only reports. Codex
  # has its own `notify` key in config.toml and would not take this shape anyway.
  #
  # What it buys: a session in another zellij tab, or behind a browser window,
  # stops being invisible when it blocks. Claude Code already emits the event —
  # `notification_type` distinguishes an agent that finished from one waiting on
  # an answer — and Plasma 6 already runs a notification daemon on the session
  # bus. The only missing piece was notify-send, and it comes from the store
  # here rather than from PATH, so this cannot silently stop working if
  # libnotify is never added to packages.nix.
  #
  # The urgency split is the point rather than a flourish. Plasma auto-dismisses
  # a normal notification after a few seconds, which is fine for "this finished"
  # and useless for "this is blocked on you" — the second is precisely the one
  # you are away from the screen for. critical stays on screen until dismissed.
  notifySend = "${pkgs.libnotify}/bin/notify-send";
  notifyDesktop = pkgs.writeShellScript "claude-notify-desktop" ''
    set -u
    payload=$(cat)
    field() { ${jq} -r "$1" <<<"$payload"; }

    # The working directory names the session. With several agents running it is
    # the only thing in the payload that says WHICH one is asking.
    title=$(field '(.cwd // "") | split("/") | last | select(. != null and . != "") // "Claude Code"')
    body=$(field '.notification_content // "Claude Code needs you."')

    case $(field '.notification_type // ""') in
      permission_prompt | agent_needs_input | idle_prompt | elicitation_dialog) urgency=critical ;;
      *) urgency=normal ;;
    esac

    exec ${notifySend} -a "Claude Code" -u "$urgency" "$title" "$body"
  '';

  mkHook =
    {
      if_,
      command,
      timeout,
      statusMessage,
    }:
    {
      type = "command";
      "if" = if_;
      command = "${command}";
      inherit timeout statusMessage;
    };

  settings = {
    # Law 3. A forgotten -m now fails fast instead of hanging on a GUI window.
    # This does not reach jj's builtin DIFF editor; those forms are denied below.
    env = {
      JJ_EDITOR = "false";
      GIT_EDITOR = "false";
      EDITOR = "false";
      VISUAL = "false";
    };

    hooks = {
      PreToolUse = [
        {
          matcher = "Bash";
          hooks = [
            (mkHook {
              if_ = "Bash(git commit *)";
              command = colocatedCommitGuard;
              timeout = 10;
              statusMessage = "Checking for a colocated repo";
            })
            (mkHook {
              if_ = "Bash(jj commit *)";
              command = publishGate;
              timeout = 180;
              statusMessage = "Gating the commit on gitleaks + nix flake check";
            })
            (mkHook {
              if_ = "Bash(jj git push *)";
              command = publishGate;
              timeout = 180;
              statusMessage = "Gating the push on gitleaks + nix flake check";
            })
            (mkHook {
              if_ = "Bash(nh os build *)";
              command = untrackedNixGuard;
              timeout = 10;
              statusMessage = "Checking for untracked nix files";
            })
            (mkHook {
              if_ = "Bash(nix flake check *)";
              command = untrackedNixGuard;
              timeout = 10;
              statusMessage = "Checking for untracked nix files";
            })
            {
              type = "command";
              command = "${commandShapeGuard}";
              timeout = 10;
              statusMessage = "Checking the command shape";
            }
            {
              type = "command";
              command = "${spillPaginationGuard}";
              timeout = 10;
              statusMessage = "Checking for a paginated spill read";
            }
          ];
        }
      ];

      PostToolUse = [
        {
          matcher = "Write|Edit";
          hooks = [
            {
              type = "command";
              command = "${shellcheckGate}";
              timeout = 20;
              statusMessage = "Linting the shell file just written";
            }
          ];
        }
        {
          matcher = "Bash";
          hooks = [
            (mkHook {
              if_ = "Bash(nh *)";
              command = conventionsCheck;
              timeout = 30;
              statusMessage = "Checking machine conventions";
            })
            (mkHook {
              if_ = "Bash(nh os build *)";
              command = recordBuild;
              timeout = 60;
              statusMessage = "Recording the built generation";
            })
          ];
        }
      ];

      # No matcher: every way a session begins — startup, resume, clear, compact,
      # fork — begins on the same instructions, and any of them can begin on
      # instructions that went stale since the last one.
      SessionStart = [
        {
          hooks = [
            {
              type = "command";
              command = "${sessionStartCheck}";
              timeout = 30;
              statusMessage = "Checking machine conventions";
            }
          ];
        }
      ];

      # No matcher: Notification does not take one — it fires on every
      # notification Claude Code raises, which is the whole point. No
      # statusMessage either, unlike every hook above: those gate something and
      # the spinner says why the turn paused, whereas this one posts a popup and
      # returns. A spinner for that would be louder than the thing it announces.
      Notification = [
        {
          hooks = [
            {
              type = "command";
              command = "${notifyDesktop}";
              timeout = 10;
            }
          ];
        }
      ];

      Stop = [
        {
          hooks = [
            {
              type = "command";
              command = "${handoffOnStop}";
              timeout = 10;
              statusMessage = "Checking for an unswitched generation";
            }
          ];
        }
      ];
    };

    permissions = {
      # The reading half of the workflow. Sessions start in auto mode, where a
      # classifier reviews shell commands in place of a prompt; an allow rule
      # resolves before that runs, so this moves reading off the reviewed path
      # and leaves review for calls that change something. Derived rather than
      # imagined: `jq` over the Bash calls in ~/.claude/projects, split on shell
      # separators and counted by binary.
      #
      # What Claude Code already treats as read-only (ls, cat, head, tail, grep,
      # find, wc, diff, stat, and git's read-only forms) is deliberately absent —
      # a rule there would restate a decision made elsewhere.
      #
      # Three the counts argued for and safety did not. `sed -n` appeared ~700
      # times, but -n does not stop sed's `w` command writing a file.
      # `devenv shell --` was the single most common command in the transcripts,
      # and it runs whatever follows it, which Claude Code documents as unsafe to
      # allowlist. `awk` can redirect from inside its own program.
      #
      # Not included either: `Bash(* --version)` and `Bash(* --help *)`, which law
      # 6 would otherwise want. Auto mode drops leading-wildcard allow rules as
      # broad grants of execution, so they would be dead weight and misleading.
      allow = [
        "Bash(jj)"
        "Bash(jj st *)"
        "Bash(jj log *)"
        "Bash(jj diff *)"
        "Bash(jj show *)"
        "Bash(jj file list *)"
        "Bash(jj file show *)"
        "Bash(jj op log *)"
        "Bash(jj bookmark list *)"
        "Bash(rg *)"
        "Bash(fd *)"
        "Bash(jq *)"
        "Bash(nix eval *)"
        "Bash(nix flake check *)"
        "Bash(nix flake metadata *)"
        "Bash(nix flake show *)"
        "Bash(nh os build *)"
        "Bash(bash ~/.claude/check-conventions.sh)"
      ];

      # A smell to watch, not a rule to enforce: an allow rule that needs deny rules
      # to fence it was too wide to begin with. `Bash(fd *)` granted everything fd
      # can do, `-x` included, and six patterns below subtract that back out —
      # argument-position matching, which Claude Code's own docs call fragile. The
      # same shape is latent in `Bash(rg *)`, since `rg --pre` also executes. Both
      # are left as they are; the fence works and is tested. But prefer allowing the
      # specific invocations actually run over allowing a tool and subtracting from
      # it, because a contract is tight when it accepts the least it needs.
      #
      # Two categories deliberately absent from this list. It does not deny what
      # the machine already refuses: `command not found` is the wall for pip,
      # python3, node, cargo and wget, and a rule there would be a second copy of
      # a fact the machine states better (laws 2 and 6). And it does not deny
      # preferences — `rg` over `grep -r`, `fd` over `find`, `| sponge` over
      # `> tmp && mv` — because ignoring those costs a slower search and nothing
      # else. Observability is necessary and not sufficient: a wall is worth a
      # round trip only when the violation costs something you cannot get back.
      # The list itself is ./agent-denies.nix, shared with codex.nix — Claude takes
      # these patterns declaratively, Codex has no declarative deny at all and turns
      # the same list into a hook. The reasoning for each rule sits beside it there.
      deny = denies.claudeDeny;
    };
  };
in
{
  # One accepted cost of the deny patterns: `Bash(nvim *)` also blocks
  # `nvim --headless`, the one scriptable shape, and `nvim --version` with it,
  # which law 6 otherwise recommends. Deny beats allow, so no
  # exception can be carved back out, and a pattern cannot express "every
  # invocation except the informational flags". Versions for those come from
  # tools.json or `nix eval` instead.
  #
  # And the caveat that applies to the whole file: a deny rule matches what
  # Claude's own tools run. It does not follow `direnv exec`, `devbox run`, or a
  # script that calls the same command a level down. It narrows the way in, it
  # does not seal it.
  environment.etc."claude-code/managed-settings.json".source =
    (pkgs.formats.json { }).generate "managed-settings.json"
      settings;
}
