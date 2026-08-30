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
  # The undecidable case asks rather than denying. Denying would be the safe
  # reflex, but a payload shape change would then block every Bash call in the
  # session with no way through; "ask" hands the call to the user, which is the
  # one answer that is never silently wrong.
  #
  # The VALUE is "ask", and the word is load-bearing. This function said
  # "escalate" from the day it was written, and claude-code does not accept that
  # word: 2.1.234 validates permissionDecision against allow/deny/ask/defer at
  # the schema layer — still exactly that set on 2.1.238, re-read 2026-08-26 —
  # and downgrades output that fails it to plain text — no
  # decision at all. Every "could not tell" was therefore a silent fall-through
  # to the ordinary permission flow, which is the exact hole this function
  # exists to close, in the one path built to be never silently wrong. Found
  # 2026-08-25 by reading the enum out of the installed binary rather than the
  # docs; check-conventions.sh now asserts every decision a guard emits against
  # that same binary, so the vocabulary cannot drift silently again. The
  # function keeps its name — escalation is what it does; "ask" is how the
  # harness spells it.
  #
  # PostToolUse has no such control — it reports rather than blocks, and cannot
  # allow anything by staying quiet — so the two hooks below carry `set -u` and
  # nothing more.
  escalateFn = ''
    escalate() {
      ${jq} -n --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"ask",permissionDecisionReason:$r}}'
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
      # The literals the harness puts in a spilled result path. Agent-specific:
      # Codex spills through a different shape entirely, so a guard keyed on this
      # one is inert there — see codex.nix. A list rather than a case pattern,
      # because agent-guards.nix builds the pattern from it AND declares it as the
      # guard's offTrigger, and those two must not be able to disagree.
      spillTriggers = [ "tool-results/" ];
      inherit escalateFn;
    };
  };
  inherit (guards)
    estopGuard
    publishGate
    colocatedCommitGuard
    sessionStartCheck
    sessionStartContext
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
  # What it buys: a session in another herdr tab, or behind a browser window,
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
  notifyDesktop = guards.writeGuard "claude-notify-desktop" ''
    set -u
    payload=$(cat)

    # A payload this cannot read must SAY so, rather than posting an empty popup.
    # Before this guard, unreadable input and "the agent had nothing to say"
    # produced the same notify-send call: jq failed to stderr, which nobody
    # reads, and what reached the screen looked like a Claude Code bug rather
    # than a hook one. Same argument the guards above make for themselves —
    # silence is honest when it means "not my business", never when it means
    # "could not tell".
    #
    # `type == "object"` rather than a bare parse check, because it is one
    # condition for every way this can go wrong. Verified against jq 1.8.2:
    # invalid JSON exits 5, empty stdin 4, and valid-but-wrong-shape (null,
    # false, a string, an array) exits 1. Only a real object exits 0.
    #
    # critical, because a notification hook that has stopped understanding its
    # input is worth interrupting for — it means every notification after this
    # one is also wrong, and nothing else would say so.
    if ! ${jq} -e 'type == "object"' >/dev/null 2>&1 <<<"$payload"; then
      exec ${notifySend} -a "Claude Code" -u critical "Claude Code" \
        "Notification hook received an unreadable payload — the shape may have changed."
    fi

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

  # One guard, every spelling of its trigger. `if` runs through the permission
  # -rule matcher — verified against 2.1.234 and still present on 2.1.238, whose
  # if-predicate is built from the same preparePermissionMatcher the permission
  # rules use — so a trailing
  # " *" does NOT match the bare command, the exact finding agent-denies.nix
  # records for the deny patterns. That finding was applied to the denies on
  # 2026-08-24 and not here: bare `jj git push` — the form CLAUDE.md's own
  # table teaches — published without the gitleaks + flake gate, and bare
  # `nh os build` (valid, NH_FLAKE is set) left no marker for the hand-off
  # reminder. Every hook below lists the bare form beside the starred one
  # wherever the bare form does something; `git commit` and `jj commit` bare
  # fail on the editor pin before anything commits, so only their starred
  # forms are real.
  mkHooks =
    {
      ifs,
      command,
      timeout,
      statusMessage,
    }:
    map (i: {
      type = "command";
      "if" = i;
      command = "${command}";
      inherit timeout statusMessage;
    }) ifs;

  # Which guards this file actually attaches, read back out of `settings.hooks`
  # rather than listed beside it. A hand-written list would be a second copy of
  # the wiring, and a second copy of the wiring is the thing being removed — see
  # agent-wiring.nix. Every `command` in that structure is a store path string
  # (mkHooks and the inline entries both interpolate the derivation), so matching
  # on it is what makes "wired" mean attached rather than merely defined.
  #
  # isDerivation because `guards` also carries guardPreamble, the `requires`
  # function and two path strings, none of which is a guard.
  hookCommands = lib.concatMap (
    event: lib.concatMap (matcher: map (h: h.command) matcher.hooks) event
  ) (lib.attrValues settings.hooks);

  wiredGuards = lib.attrNames (
    lib.filterAttrs (_: v: lib.isDerivation v && lib.elem "${v}" hookCommands) guards
  );

  # Every PreToolUse hook this file attaches, paired with the laws its guard
  # declares beside itself in agent-guards.nix. This is what
  # claude/replay-guards.sh runs on.
  #
  # Built from settings.hooks.PreToolUse rather than from a list, for the same
  # reason wiredGuards above is: a guard that is written and never attached must
  # not be able to appear here and pass three laws it is not actually subject to.
  preToolUseHooks = lib.concatMap (m: m.hooks) settings.hooks.PreToolUse;
  preToolUseCommands = map (h: h.command) preToolUseHooks;

  # Every `if` this file attaches to a given guard, so the guard's own declared
  # offTrigger can be checked against them. null rather than [ ] for a hook with
  # no `if`: the two mean opposite things here — "everything reaches this guard"
  # and "nothing does" — and collapsing them is how the check below would come
  # back green on the one case it exists to catch.
  #
  # A guard attached under several matcher groups (publishGate is, under three)
  # is reachable through the UNION of their `if`s, so this collects across the
  # flattened list rather than per group.
  ifsFor =
    command:
    let
      attached = lib.filter (h: h.command == command) preToolUseHooks;
    in
    if lib.any (h: !(h ? "if")) attached then null else map (h: h."if") attached;

  replayEntries = map (
    name:
    guards.replay.${name}
    // {
      inherit name;
      command = "${guards.${name}}";
      ifs = ifsFor "${guards.${name}}";
    }
  ) (lib.filter (n: lib.elem "${guards.${n}}" preToolUseCommands) (lib.attrNames guards.replay));

  # A PreToolUse hook whose guard declares no laws is a guard nothing replays —
  # which is the state eleven of the twelve were in. The assertion below turns
  # that into a build failure rather than a green run over a smaller set than it
  # appears to cover.
  undeclaredHooks = lib.subtractLists (map (e: e.command) replayEntries) preToolUseCommands;

  # The other half of that, and the half that had actually gone wrong. A guard
  # declares the substrings it has an opinion about; Claude filters each hook with
  # an `if` BEFORE the guard forks, so a verb with no matching `if` never reaches
  # the guard that judges it — and claude/replay-guards.sh cannot see that, because
  # it feeds the script directly and never learns what was filtering it.
  #
  # publishGate spent from 2026-08-26 in exactly that state. agent-guards.nix
  # widened its trigger to `jj new`, `jj squash` and `jj split` — the verbs that
  # make working-copy content permanent as `@-`, which is the whole point of the
  # widening — while this file went on attaching it to `jj commit` and
  # `jj git push` alone. The three verbs the fix was FOR paid no gitleaks scan,
  # and the replay reported green over all three because the guard itself was
  # right. Codex was never affected: requirements.toml has no per-hook `if`, so
  # its copy of the same guard fired on every Bash call.
  #
  # `if` is a hard filter, read out of the installed binary rather than the docs
  # (law 6): claude-code 2.1.245 logs "Skipping hook due to if condition … not
  # matching" and drops the hook.
  #
  # The test is a PREFIX one, and deliberately weaker than it could be: an `if`
  # matches from the start of a command segment while an offTrigger is a
  # substring the harness looks for anywhere, so this proves a verb HAS a filter
  # rather than that the filter is exactly right. That is the failure that
  # happened; a cleverer check would be asserting something nothing has gone
  # wrong at yet.
  unreachableTriggers = lib.concatMap (
    e:
    if e.ifs == null then
      [ ]
    else
      let
        # `Bash(jj new *)` → `jj new *`. An `if` in some other vocabulary is left
        # as it is, so it fails the prefix test and fails the build — loud is the
        # right direction for a filter this cannot read.
        inner = map (i: lib.removeSuffix ")" (lib.removePrefix "Bash(" i)) e.ifs;
      in
      map (t: "${e.name}: \"${t}\" is matched by none of ${lib.concatStringsSep ", " e.ifs}") (
        lib.filter (t: !(lib.any (p: lib.hasPrefix t p) inner)) e.offTrigger
      )
  ) replayEntries;

  settings = {
    # Anthropic's built-in Concise style: leads with the result, drops preamble and
    # narration, keeps error output, security findings and destructive-action
    # confirmations whole. Needs claude-code >= 2.1.237; the assertion below says so
    # rather than letting an older nixpkgs silently ignore the key.
    #
    # Declared here rather than written into ~/.claude/settings.json because it is a
    # rule about how every response is shaped, and law 4 puts rules in the repo. The
    # cost of the managed tier is that it is the top of the precedence stack: /config
    # cannot change it and no project can override it. That is the intended trade —
    # if per-project styles are ever wanted, this moves back to settings.json.
    outputStyle = "Concise";

    # Auto-memory keeps notes under ~/.claude/projects/<slug>/memory/ and reads them
    # back into every session. It is off here rather than in ~/.claude/settings.json
    # for the same reason as outputStyle above: it decides what reaches the context on
    # every turn, which makes it a rule and not state, and law 4 puts rules in the
    # repo. False means Claude neither reads nor writes that directory. The merged
    # getter takes the policy tier's value ahead of the user's, so /config's own
    # toggle cannot turn it back on.
    autoMemoryEnabled = false;

    # Compaction is the most destructive operation on this machine, so which of the
    # two triggers is armed should be a decision rather than whatever shipped.
    # Measured over 182 transcripts (.scratch/context-window/measure.sh): a
    # compaction destroys 97.8% of context — 703,258 tokens in, 15,158 out, mean of
    # 14 events — and independent work puts safety-rule survival at 53% after one
    # round and 10% after five. That is survivable here only because this repo's
    # rules are hooks rather than prose: a summary cannot weaken a deny. Anything
    # that later moves a rule out of a hook and into the prompt forfeits that.
    #
    # TRUE, and the value is the whole point of writing the line. This was very
    # nearly set to false on the reasoning that compaction here "is already
    # manual" — all 14 recorded events carry trigger "manual" and none carry
    # "auto", and one session reached 99.9% of a 1M window without auto firing.
    # Every one of those facts is true and the conclusion drawn from them was
    # wrong: `sp("autoCompactEnabled", !0)` in claude-code 2.1.238 defaults the key
    # to TRUE, so auto-compaction is armed and has simply never been reached — the
    # user compacts first. "Never fired" and "not enabled" look identical in the
    # transcripts and are opposite facts about the machine.
    #
    # So this declares the backstop rather than removing it. Disabling it would
    # trade a compaction nobody has needed for a session that hits the hard
    # `context limit: N + N > N` path with no way out, and the policy tier is
    # exactly where that could not be overridden mid-session. autoCompactWindow is
    # deliberately left unset: a threshold that fires mid-task is worse than one the
    # user picks, and the user picking it is what the record shows happening.
    autoCompactEnabled = true;

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
        # First, and matching every tool rather than only Bash. Every other guard
        # here objects to a particular command; this one objects to the session
        # continuing at all, so a Write or a WebFetch has to hit it too — a stop
        # switch that leaves the file-editing tools open is not one.
        #
        # "*" is the documented spelling and not a guess: the matcher is an exact
        # string (or `|`-separated list) while it contains only word characters,
        # and a regex once it does not, so the "Bash" below is exact and "*" is
        # the wildcard the docs name alongside "" and omitting the field.
        # codex.nix omits it instead — its schema types the field as
        # `string | null`, so null is the match-all there.
        {
          matcher = "*";
          hooks = [
            {
              type = "command";
              command = "${estopGuard}";
              timeout = 5;
              statusMessage = "Checking the stop switch";
            }
          ];
        }
        {
          matcher = "Bash";
          hooks =
            mkHooks {
              ifs = [ "Bash(git commit *)" ];
              command = colocatedCommitGuard;
              timeout = 10;
              statusMessage = "Checking for a colocated repo";
            }
            ++ mkHooks {
              ifs = [ "Bash(jj commit *)" ];
              command = publishGate;
              timeout = 180;
              statusMessage = "Gating the commit on gitleaks + nix flake check";
            }
            ++ mkHooks {
              ifs = [
                "Bash(jj git push)"
                "Bash(jj git push *)"
              ];
              command = publishGate;
              timeout = 180;
              statusMessage = "Gating the push on gitleaks + nix flake check";
            }
            # The three verbs that make working-copy content permanent without
            # publishing it. In jj the working copy IS a commit, so these do not
            # CREATE one — they stop `@` from being amended further and leave the
            # content behind as `@-`, which is the moment a secret stops being
            # recoverable by amendment. publishGate's own trigger has named them
            # since 2026-08-26 and this file did not, so the guard ran only for
            # `jj commit` and `jj git push` and the escape it was widened to close
            # — write a secret, `jj new`, delete it, push — stayed open on this
            # agent. unreachableTriggers above is what makes that unrepresentable
            # rather than a thing to notice twice.
            #
            # Only tier one runs here: the guard's second `requires` narrows the
            # flake check to the two publishing verbs, so these pay ~0.22s of
            # gitleaks and exit. The timeout is still 180 to match the groups
            # above — a compound like `jj new && jj commit -m x` matches an `if`
            # in both groups, and a shorter ceiling here would abort the shared
            # script mid-flake-check on the very command that needs it most.
            #
            # Bare beside starred wherever the bare form does something, the same
            # rule the rest of this file follows: bare `jj new` and bare
            # `jj squash` both act and neither needs an editor to do it, so the
            # editor pin does not cover them the way it covers bare `git commit`.
            # `jj split` gets only the starred form — bare, it opens the diff
            # editor and agent-denies.nix already refuses it.
            ++ mkHooks {
              ifs = [
                "Bash(jj new)"
                "Bash(jj new *)"
                "Bash(jj squash)"
                "Bash(jj squash *)"
                "Bash(jj split *)"
              ];
              command = publishGate;
              timeout = 180;
              statusMessage = "Scanning for secrets before this content becomes permanent";
            }
            ++ mkHooks {
              ifs = [
                "Bash(nh os build)"
                "Bash(nh os build *)"
                "Bash(nix flake check)"
                "Bash(nix flake check *)"
              ];
              command = untrackedNixGuard;
              timeout = 10;
              statusMessage = "Checking for untracked nix files";
            }
            ++ [
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
          hooks =
            mkHooks {
              ifs = [ "Bash(nh *)" ];
              command = conventionsCheck;
              timeout = 30;
              statusMessage = "Checking machine conventions";
            }
            ++ mkHooks {
              ifs = [
                "Bash(nh os build)"
                "Bash(nh os build *)"
              ];
              command = recordBuild;
              timeout = 60;
              statusMessage = "Recording the built generation";
            };
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
            # A second hook rather than a branch inside the first, for the reason
            # spillPaginationGuard is not a fourth arm of commandShapeGuard: that
            # one answers "are the instructions still true", this one answers
            # "what is true here that they cannot state". Claude Code runs every
            # matching SessionStart hook and concatenates their additionalContext,
            # so keeping them apart also makes each one's failure its own — a
            # broken probe cannot swallow a stale-conventions warning.
            {
              type = "command";
              command = "${sessionStartContext}";
              timeout = 15;
              statusMessage = "Probing machine state";
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
      # Bare forms are listed beside their starred ones because the matcher
      # treats them as different commands — a trailing " *" does not match the
      # argument-less invocation (same finding as the deny list and the hook
      # `if`s) — and `jj st`, `jj log`, `nix flake check` are typed bare more
      # often than not, so the starred rules alone left the most common reads
      # on the reviewed path this list exists to take them off. Only forms that
      # do something bare are listed; a bare `rg` or `jj file show` just errors.
      allow = [
        "Bash(jj)"
        "Bash(jj st)"
        "Bash(jj st *)"
        "Bash(jj log)"
        "Bash(jj log *)"
        "Bash(jj diff)"
        "Bash(jj diff *)"
        "Bash(jj show)"
        "Bash(jj show *)"
        "Bash(jj file list)"
        "Bash(jj file list *)"
        "Bash(jj file show *)"
        "Bash(jj op log)"
        "Bash(jj op log *)"
        "Bash(jj bookmark list)"
        "Bash(jj bookmark list *)"
        "Bash(rg *)"
        "Bash(fd *)"
        "Bash(jq *)"
        "Bash(nix eval *)"
        "Bash(nix flake check)"
        "Bash(nix flake check *)"
        "Bash(nix flake metadata)"
        "Bash(nix flake metadata *)"
        "Bash(nix flake show)"
        "Bash(nix flake show *)"
        "Bash(nh os build)"
        "Bash(nh os build *)"
        "Bash(bash ~/.claude/check-conventions.sh)"
        # Process and socket inspection, added 2026-08-27 on a re-count of the same
        # corpus: 12,737 Bash calls across 193 transcripts. `ps` 126, `pgrep` 108 —
        # both earned their place. `ss` 18, which is thin, and it is here anyway
        # because the argument for it is not the count: none of the three can write
        # anything, take a command to run, or reach the network. There is no wide
        # grant to fence afterwards, which is the shape the note below asks for.
        # Bare `ps` and bare `ss` list something; bare `pgrep` errors, so it gets
        # the starred form only.
        "Bash(ps)"
        "Bash(ps *)"
        "Bash(pgrep *)"
        "Bash(ss)"
        "Bash(ss *)"
      ];

      # What the same re-count argued AGAINST, recorded so the next pass does not
      # re-derive it. The four commands that would buy the most reviewed-path
      # relief are all unsafe to allowlist by construction, not by oversight:
      #
      #   timeout      400 calls, and it runs whatever follows it
      #   nix shell    119, the law-1 borrow verb — arbitrary code, by design
      #   curl          73, network, and -o writes
      #   nix fmt       62, formats in place
      #
      # `nix build --no-link` (36) is the near miss: it changes no system state,
      # but unlike `nh os build` it takes any flake ref, so it builds arbitrary
      # remote code. `gh` reads (`gh auth status`, `gh repo view`) are genuinely
      # read-only but total under 20 calls, and `gh api` sits in the same command
      # with -X POST available, so no `gh` rule is worth its fence yet.
      #
      # The finding worth carrying: this list already covers the machine's real
      # exploration surface. What still meets the classifier is the set that
      # cannot be pre-approved without granting execution, so the remaining
      # friction is the design working rather than a gap to close.

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
  # Two settings above name behaviour an older claude-code does not have: outputStyle
  # = "Concise" is a built-in added in 2.1.237, and autoMemoryEnabled was read out of
  # 2.1.238's own binary. An older release ignores an unknown setting silently, so the
  # style would fall back to Default and auto-memory would come back on, both while
  # still looking applied. Fail the build instead. 2.1.238 is the version the keys were
  # verified against, not necessarily the first that had them — the floor is allowed to
  # be one patch pessimistic, since being wrong the other way is the silent failure.
  assertions = [
    {
      assertion = undeclaredHooks == [ ];
      message =
        "claude.nix attaches PreToolUse hooks with no replay laws declared beside "
        + "their guard in agent-guards.nix:\n  "
        + lib.concatStringsSep "\n  " undeclaredHooks
        + "\nDeclare offTrigger and routes for each, or claude/replay-guards.sh "
        + "reports green over a set that does not include them.";
    }
    {
      assertion = unreachableTriggers == [ ];
      message =
        "claude.nix attaches guards behind `if` filters that cannot reach some of "
        + "the offTriggers those guards declare in agent-guards.nix:\n  "
        + lib.concatStringsSep "\n  " unreachableTriggers
        + "\nThe guard would judge these commands correctly and never be handed one: "
        + "claude-code drops a hook whose `if` does not match, before the script "
        + "forks. Add the missing `if` (bare beside starred where the bare form "
        + "does something), or narrow the guard's offTrigger to what it is "
        + "actually wired for. claude/replay-guards.sh cannot catch this — it "
        + "feeds the script directly.";
    }
    {
      assertion = lib.versionAtLeast pkgs.claude-code.version "2.1.238";
      message =
        "claude.nix sets outputStyle = \"Concise\" and autoMemoryEnabled = false, "
        + "both verified against claude-code 2.1.238, but nixpkgs has "
        + "${pkgs.claude-code.version}. Update the nixpkgs input, or drop the "
        + "settings until they land.";
    }
  ];

  # Published for modules/home/default.nix, which subtracts Codex's set from this
  # one to say which walls a Codex session does not have. See agent-wiring.nix.
  agents.wiredGuards.claude = wiredGuards;

  # The notes come from here rather than from codex.nix because this file wires
  # every guard there is, so its instantiation carries the complete set. Two
  # modules setting one option would conflict.
  agents.guardNotes = guards.absenceNotes;

  # The laws, for claude/replay-guards.sh. Generated from the same hook structure
  # as managed-settings.json, so the wiring is under test alongside the guards.
  agents.replayManifest.claude = (pkgs.formats.json { }).generate "claude-replay.json" replayEntries;

  environment.etc."claude-code/managed-settings.json".source =
    (pkgs.formats.json { }).generate "managed-settings.json"
      settings;
}
