# The guards, shared by every agent this machine runs.
#
# They were written for Claude and still read as Claude's, but nothing in a guard
# BODY is Claude-specific — only a handful of names are. So they are parameterised
# here rather than copied into a second file free to drift: `a` carries the script
# prefix, the display name, where that agent's rules live, and the one parameter
# that is not cosmetic — how the agent says "I could not tell".
#
# That one decides whether a guard is a wall or a hole. Claude answers an
# undecidable payload with permissionDecision "ask" — the word matters, see
# escalateFn in claude.nix — which hands the call to the user and is the single
# answer that is never silently wrong. Codex has no such answer: its PreToolUse
# parses `escalate` and `ask`, marks them failed, and RUNS THE COMMAND ANYWAY.
# Handing Claude's ask to Codex unchanged would therefore turn every careful
# "ask" into an allow, leaving a guard that reads as total and is not.
# modules/nixos/codex.nix collapses it to a deny instead, and explains itself in
# the deny reason rather than failing silently.
#
# Imported as a plain function, not as a module: claude.nix and codex.nix each
# call it from their own `let`, so these bodies exist once and are instantiated
# twice.
{
  pkgs,
  jq,
  a,
}:
rec {
  guardPreamble = ''
    set -u
    ${a.escalateFn}
    input=$(cat)
    cwd=$(printf '%s' "$input" | ${jq} -r '.cwd // empty') ||
      escalate "guard could not parse the hook payload as JSON, so it cannot tell whether its rule applies. Asking rather than assuming: a guard that stays quiet when confused is a wall that is trusted and absent."
    [ -n "$cwd" ] ||
      escalate "the hook payload carried no cwd, so this guard cannot tell whether its rule applies here. Asking rather than assuming."
    cmd=$(printf '%s' "$input" | ${jq} -r '.tool_input.command // empty | if type == "array" then join(" ") else . end') ||
      escalate "guard could not read the command out of the hook payload."

    # One command in, one command per line out. Every guard that judges a command
    # judges it segment by segment, so `jj log && jj split` is caught on its second
    # half instead of sliding past — Claude Code splits compound commands itself
    # before applying permissions.deny, and this is the same job done where the
    # payload lands.
    #
    # It lives here, once, because it did not: `requires` below and codex.nix's
    # denyGuard each carried their own copy, and the copies were the parser — the
    # part that decides whether a deny fires at all. The bug that cost the most is
    # worth keeping written down, since it is the one a rewrite would reintroduce:
    # `tr` leaves a TRAILING space on every segment but the last, so trimming only
    # the leading side made `jj split && jj log` produce "jj split " and an exact
    # pattern never matched it. The deny held for `jj log && jj split` and not for
    # the reverse, which is the ordering that happened to get tested. Trim both
    # ends. Empty segments are dropped so a caller never has to check for them.
    segments() {
      printf '%s' "$cmd" | tr ';|&\n' '\n\n\n\n' |
        sed 's/^[[:space:]]*//; s/[[:space:]]*$//; /^$/d'
    }
  '';

  # An `if` filter is a precondition, and a precondition you do not check is one you
  # are guessing at. Measured 2026-08-22: when Claude Code cannot fully parse a Bash
  # command — a heredoc carrying awk ternaries was enough — it runs hooks whose `if`
  # would not otherwise match. That is the right call on its side, since a guard is
  # cheaper than a miss. But a guard reached that way has been handed a command it
  # was never written to judge, and `colocatedCommitGuard` denied it anyway, because
  # the only thing establishing "this is a git commit" lived outside the guard.
  #
  # So each guard re-establishes its own trigger from `$cmd` before acting. Narrowing
  # the input inside the function rather than assuming it outside is the same fix as
  # the totality one above, one level up.
  requires = pattern: ''
    # Anchored to the start of a SEGMENT, not a substring of the whole command —
    # `segments` in the preamble is what makes that available, and the trimming
    # this depends on is explained there. Unanchored, merely NAMING a guarded
    # phrase triggered the guard: under Codex, which has no per-hook `if` filter to
    # narrow the input first, an `rg` for one of these phrases in a file ran the
    # guard against a read-only command and could be denied by it, or paid a full
    # gitleaks + nix flake check first. Reading a file that quotes a rule is not
    # performing it.
    matched=0
    while IFS= read -r seg; do
      case "$seg" in
      ${pattern}) matched=1 ;;
      esac
    done <<REQUIRES_SEGMENTS
    $(segments)
    REQUIRES_SEGMENTS
    [ "$matched" -eq 1 ] || exit 0
  '';

  # ── the one wall that is not a rule ─────────────────────────────────────────
  # Borrowed from NousResearch/hermes-agent's agent/estop.py, whose semantics are
  # the part worth taking: a sentinel file pauses NEW work, in-flight work is
  # never killed, and the check is a single stat so it can afford to run on every
  # call.
  #
  # Why this machine wants one. Every other wall here is a RULE: it knows in
  # advance which commands it objects to, and it was written before the session
  # started. This one has no opinion about any command. It exists so a human can
  # stop every agent on the machine at once, from outside, mid-session — and that
  # gap was not theoretical. On 2026-08-26 a concurrent Codex session was editing
  # /etc/nixos while this one committed, and its work was swept into a commit
  # whose message never mentioned it. Ctrl-C ends the session you are looking at;
  # nothing ended the other one.
  #
  # ONE sentinel for every agent, deliberately not ${a.prefix}-scoped the way
  # builtMarker above is. A stop switch that stops one of the two agents running
  # is the wrong wall, and the shared name is what makes that true by
  # construction rather than by both files remembering to agree.
  #
  # Under XDG_RUNTIME_DIR, which is law 5 read backwards. This is the one piece of
  # state here that must NOT survive a reboot: an ESTOP that outlives the machine
  # it was set on is indistinguishable from a harness that is simply broken, and
  # the person who would recognise it is the one who set it hours earlier.
  estopSentinel = "\${XDG_RUNTIME_DIR:-/tmp}/agent-estop";

  estopGuard = pkgs.writeShellScript "${a.prefix}-guard-estop" ''
    set -u
    # Drained, not parsed. This is the only guard whose decision does not depend
    # on the payload at all, which makes it total by construction — there is no
    # shape it can be confused by, so the totality argument the rest of this file
    # has to make in prose is simply absent here. The read is still performed so
    # the harness is not writing into a closed pipe.
    cat >/dev/null 2>&1

    estop=${estopSentinel}
    [ -e "$estop" ] || exit 0

    # Fail-safe, and the ONLY guard here that is. The rule at the top of this file
    # says an undecidable input becomes a question, because denying on a payload
    # shape change would wall off a whole session for no reason. That reasoning
    # inverts for a switch: an unreadable sentinel is not an input this failed to
    # understand, it is evidence somebody reached for the switch. estop.py makes
    # the same call in the same words — "a corrupt or empty file still counts as
    # engaged (fail safe): the pause must hold even if the file was created by
    # touch". So the read below cannot change the decision, only the wording.
    reason=$(head -c 2000 "$estop" 2>/dev/null) || reason=""
    [ -n "$reason" ] || reason="none recorded in the sentinel"

    # This deny names no route out, and that is the design rather than an
    # oversight. claude/replay-guards.sh's L2 says a guard must never deny its own
    # remedy, and that holds for every wall the agent is expected to comply with
    # and then carry on past. An ESTOP is the exception the law needs: the remedy
    # is not the agent's to perform, because an agent that can clear its own stop
    # switch does not have one. So it hands over instead, the same shape law 3
    # uses for `nh os switch` and for the same reason.
    ${jq} -n --arg r "$reason" --arg p "$estop" '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: ("ESTOP is engaged, so every tool call is denied. This is a deliberate pause on new work, not a failure of the thing you just tried, and nothing in flight was killed — reason given: " + $r + "\n\nOnly the user can lift it, by removing " + $p + ". Stop and say so rather than looking for a way around it: there is no route out that this guard allows, by design.")
      }
    }'
  '';

  # The pre-commit gate jj cannot host: jj has no hook support and bypasses
  # .git/hooks, so both checks run from PreToolUse on `jj commit` and
  # `jj git push`. Only fires when the working directory is /etc/nixos.
  #
  # Two checks, cheapest first so a secret is caught before ten seconds of nix
  # evaluation rather than after.
  #
  # gitleaks was installed and inventoried all along — tools.json even said to run
  # it before pushing — and nothing ran it. check-conventions.sh scans with a
  # hand-written four-pattern regex aimed at the shapes that matter here (private
  # keys, age keys, $6$/$y$ hashes, quoted secret assignments); that stays, because
  # it is targeted at this repo's actual risk. gitleaks adds ~150 rules for the
  # cloud tokens and PATs a pasted example brings in. 0.08s over the whole tree,
  # measured 2026-08-22, so there is no reason for it not to sit here.
  #
  # It scans the working tree, not history: every commit passes through this gate
  # as a working tree first, so history stays clean by induction from a clean
  # start (`gitleaks git /etc/nixos` was clean when this landed). For a one-off
  # audit of history itself, run that command by hand.
  publishGate = pkgs.writeShellScript "${a.prefix}-gate-publish" ''
    ${guardPreamble}
    ${requires ''"jj commit"* | "jj git push"*''}
        case "$cwd" in
        /etc/nixos | /etc/nixos/*) ;;
        # Total, not a shrug: a cwd outside this repo is definitely not this
        # gate's business, and the preamble has already ruled out "cannot tell".
        *) exit 0 ;;
        esac
        deny() {
          ${jq} -n --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
          exit 0
        }

        if ! out=$(${pkgs.gitleaks}/bin/gitleaks dir /etc/nixos --no-banner 2>&1); then
          out=$(printf '%s\n' "$out" | sed 's/\x1b\[[0-9;]*m//g' | tail -n 30)
          deny "gitleaks found something that looks like a secret. Law 7: /etc/nixos is a public repo and every nix file is copied world-readable into /nix/store, so this cannot be fixed after the fact by deleting it. Move the value to machine.secretsDir and point at the path instead.
    $out"
        fi

        # Absolute, like the gitleaks call above it. Bare, this evaluated the HOOK
        # PROCESS's working directory rather than the $cwd just validated: from a
        # session whose cwd was not this repo it denied every commit with "does not
        # contain a flake.nix", blaming the tree rather than the guard.
        out=$(nix flake check /etc/nixos 2>&1) && exit 0
        out=$(printf '%s\n' "$out" | sed 's/\x1b\[[0-9;]*m//g' | tail -n 40)
        deny "\`nix flake check\` fails, so this would publish a tree the gate rejects. jj has no hook support and bypasses .git/hooks, so this hook is the pre-commit hook it cannot have. Fix the findings, then run the command again.
    $out"
  '';

  # `git commit` is correct in a git-only repo and only destructive in a
  # colocated one, so this cannot be a flat deny pattern. It looks for .jj in the
  # working directory and denies on that.
  colocatedCommitGuard = pkgs.writeShellScript "${a.prefix}-guard-git-commit" ''
    ${guardPreamble}
    ${requires ''"git commit"*''}
    # Total: .jj either is or is not there, and the preamble guaranteed a cwd.
    [ -d "$cwd/.jj" ] || exit 0
    ${jq} -n '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: "This repo is colocated (.jj is present), so a git commit is imported by jj without an operation-log entry and the change stops being undoable. Use `jj commit -m` or `jj describe -m` instead. Reading with git log / git show / git blame is unaffected."
      }
    }'
  '';

  # Same check as the nh hook below, at the other end of the session.
  #
  # check-conventions.sh decides whether ${a.rulesFile} and tools.json can be trusted,
  # and until now it only ran AFTER a rebuild. Everything that happens between
  # rebuilds was therefore invisible to it: a flake update, a tool that stopped
  # resolving, a claim that quietly stopped being true while nobody rebuilt. A
  # session could run for hours on instructions that had already gone stale, and
  # the mechanism that would have said so was waiting for a trigger that never
  # came.
  #
  # 0.29s measured 2026-08-22, which is what makes this affordable at every
  # startup rather than a thing to run when you remember. Quiet on success:
  # nothing is printed when 29 assertions hold, so the cost is the runtime and no
  # context at all.
  sessionStartCheck = pkgs.writeShellScript "${a.prefix}-session-start-check" ''
    set -u
    out=$(bash ${a.conventionsScript} 2>&1) && exit 0
    out=$(printf '%s\n' "$out" | sed 's/\x1b\[[0-9;]*m//g' | grep -E 'FAIL|failed$')
    # The script that just failed is the last SWITCHED generation's copy. When
    # the repo carries a newer one that passes, the machine is stale and the
    # instructions are fine — the opposite of what the message below claims,
    # and a session opened on exactly that misread on 2026-08-25: a red check,
    # an instruction to distrust CLAUDE.md, and a working tree that had already
    # fixed everything except the activation. Say which case it is.
    repo=/etc/nixos/claude/check-conventions.sh
    if [ -r "$repo" ] && ! cmp -s "$repo" ${a.conventionsScript} && bash "$repo" >/dev/null 2>&1; then
      ${jq} -n --arg o "$out" '{
        systemMessage: "Convention check failed, but the repo copy passes — a fix is waiting on nh os switch.",
        hookSpecificOutput: {
          hookEventName: "SessionStart",
          additionalContext: ("The installed check-conventions.sh (from the last switched generation) fails, but /etc/nixos/claude/check-conventions.sh passes: the repo already fixes this, and only the switch is behind — which belongs to the user (law 3). The instructions are current; read the failures below as the list of what flips green on activation.\n" + $o)
        }
      }'
      exit 0
    fi
    ${jq} -n --arg o "$out" '{
      systemMessage: "Convention check FAILED at session start — the machine no longer matches what tools.json and ${a.rulesFile} claim.",
      hookSpecificOutput: {
        hookEventName: "SessionStart",
        additionalContext: ("check-conventions.sh is failing before any work has been done, so this session began with instructions that are already wrong somewhere. Treat ${a.rulesFile} and tools.json as suspect until it is green, and fix it before trusting either.\n" + $o)
      }
    }'
  '';

  # Law 3 says work to the last step that needs no answer, then hand over. That
  # hand-over has been a thing the agent remembers to say, which means it is a
  # thing the agent can forget to say — and twice on 2026-08-22 a session went on
  # working against a live config that no longer matched what had been built,
  # because the switch was never mentioned and never happened.
  #
  # So it is recorded rather than remembered. The PostToolUse hook on `nh os
  # build` writes the toplevel it produced; this compares that against the system
  # actually running and reports the gap when the session ends. A readlink and a
  # file read, and it says WHAT is pending rather than nagging in general.
  builtMarker = "\${XDG_RUNTIME_DIR:-/tmp}/${a.prefix}-nixos-built";

  # The trigger is established HERE and not only by the caller's `if` filter, for
  # the same reason `requires` above gives: claude.nix can narrow this to
  # `Bash(nh os build*)` before the fork, and codex.nix has no per-hook `if` at
  # all. Ported unguarded, this would run on every Bash call Codex makes, and the
  # nix eval below is 6.2s on this machine (measured 2026-08-26) — seconds of
  # latency added to `ls`. Claude's filter stays where it is and becomes a cheap
  # prefilter rather than the only thing that makes this safe.
  #
  # No escalate and no guardPreamble, unlike the PreToolUse guards. Those decide
  # whether a command runs, so "cannot tell" has to become a question; this one
  # runs after the fact and can neither block nor allow anything. The worst case
  # of an unreadable payload is a marker that is not written, which handoffOnStop
  # and sessionStartContext both report as "nothing pending" — an omission, and
  # the honest answer for a hook with no way to ask.
  recordBuild = pkgs.writeShellScript "${a.prefix}-record-build" ''
    set -u
    cmd=$(${jq} -r '.tool_input.command // empty | if type == "array" then join(" ") else . end' 2>/dev/null) || exit 0
    case "$cmd" in
    *"nh os build"*) ;;
    *) exit 0 ;;
    esac
    p=$(nix eval --raw /etc/nixos#nixosConfigurations."$(hostname)".config.system.build.toplevel.outPath 2>/dev/null) || exit 0
    [ -n "$p" ] && printf '%s' "$p" > ${builtMarker}
    exit 0
  '';

  handoffOnStop = pkgs.writeShellScript "${a.prefix}-handoff-on-stop" ''
    set -u
    [ -r ${builtMarker} ] || exit 0
    built=$(cat ${builtMarker}) || exit 0
    running=$(readlink -f /run/current-system 2>/dev/null) || exit 0
    [ "$built" != "$running" ] || exit 0
    ${jq} -n --arg b "$built" '{
      systemMessage: ("A NixOS configuration was built this session and is not the one running. Activation escalates to sudo, which no ${a.displayName} session can answer (law 3), so it is yours:\n\n    nh os switch /etc/nixos\n\nbuilt: " + $b)
    }'
  '';

  # The other half of law 6, and the counterpart to autoMemoryEnabled = false in
  # claude.nix: if nothing here is known from memory, the answer is not to
  # remember harder but to probe at the start and say what was found.
  #
  # ${a.rulesFile} names three facts a session is told to establish for itself and
  # then spends a command on, every time, or skips and guesses at:
  #
  #   - which of the three version-control cases this directory is
  #     ("`ls -d .jj .git` answers it in one command" — so run it once, here)
  #   - whether the repo is carrying unresolved conflicts
  #   - whether direnv has fired, which in a non-interactive agent shell it has not
  #
  # The fourth is not in ${a.rulesFile} at all: handoffOnStop above reports an
  # unswitched build at the END of the session that built it, and says nothing to
  # the NEXT one. The marker outlives the session, so the same comparison at
  # startup closes that gap for free.
  #
  # Shape borrowed from langchain-ai/deepagents' LocalContextMiddleware, including
  # the reason this is a SessionStart hook and not a per-turn one. Their comment is
  # the argument: volatile sections "would otherwise churn the system prompt and
  # reduce provider prompt-cache hits across a conversation". Git status and
  # conflict state are exactly that, so this runs once and the injected prefix
  # stays byte-identical for the rest of the session. Their script fans eight
  # sections out into parallel subshells; four cheap ones do not earn a mktemp and
  # a wait, so this stays serial — 0.03s median over five runs in /etc/nixos, with
  # the jj conflicts query included, measured 2026-08-26.
  #
  # No guardPreamble and no escalate, unlike every guard above. Those decide
  # whether a command runs, so "cannot tell" has to become a question. This
  # decides nothing and returns no permissionDecision, so its undecidable case is
  # to say less: every probe that fails is dropped and the session starts on what
  # was learned. A context hook that can abort a session start is worse than one
  # that occasionally has nothing to add.
  sessionStartContext = pkgs.writeShellScript "${a.prefix}-session-start-context" ''
    set -u
    input=$(cat)
    cwd=$(printf '%s' "$input" | ${jq} -r '.cwd // empty' 2>/dev/null) || exit 0
    [ -n "$cwd" ] && [ -d "$cwd" ] || exit 0
    cd "$cwd" 2>/dev/null || exit 0

    out=""
    say() { out="$out$1"$'\n'; }

    # The repo root, not $cwd: .jj and .git sit at the top, and a session opened
    # in a subdirectory would otherwise be told "no version control" about a repo
    # it is standing inside. git resolves it for both colocated and git-only
    # cases; the fallback only matters for the two rows that have no .git.
    root=$(git rev-parse --show-toplevel 2>/dev/null) || root=""
    [ -n "$root" ] || root=$cwd
    if [ -d "$root/.jj" ] && [ -d "$root/.git" ]; then
      say "- Version control: colocated, root $root. jj for history; git commit is denied here."
    elif [ -d "$root/.git" ]; then
      say "- Version control: git-only, root $root. Plain git commit is correct and loses nothing."
    elif [ -d "$root/.jj" ]; then
      say "- Version control: .jj without .git, root $root. Not colocated, so coworkers and gh see nothing."
    else
      say "- Version control: none at or above $cwd. There is no undo — say so before editing anything."
    fi

    # --ignore-working-copy because a hook must not snapshot: without it this
    # writes an operation-log entry before the session has done anything, and
    # races the working copy the user is about to touch.
    if [ -d "$root/.jj" ] && command -v jj >/dev/null 2>&1; then
      conflicted=$(jj log --ignore-working-copy --no-graph -r 'conflicts()' \
        -T 'change_id.short() ++ " "' 2>/dev/null) || conflicted=""
      conflicted=''${conflicted% }
      [ -n "$conflicted" ] &&
        say "- Unresolved conflicts in: $conflicted. Repo-wide all-clear is an empty \`jj log -r 'conflicts()'\`; start with \`nix shell nixpkgs#mergiraf -c jj resolve --tool mergiraf\`."
    fi

    if [ -r ${builtMarker} ]; then
      built=$(cat ${builtMarker} 2>/dev/null) || built=""
      running=$(readlink -f /run/current-system 2>/dev/null) || running=""
      [ -n "$built" ] && [ -n "$running" ] && [ "$built" != "$running" ] &&
        say "- A NixOS configuration was built in an earlier session and never switched. Activation is the user's (law 3): nh os switch /etc/nixos"
    fi

    # DIRENV_DIR is set by the hook direnv installs in an interactive shell. An
    # agent shell is not one, so an unset value here is the normal case and the
    # whole point: the environment exists and has not been entered.
    if [ -e "$cwd/.envrc" ] || [ -e "$cwd/devenv.nix" ]; then
      [ -z "''${DIRENV_DIR:-}" ] &&
        say "- This directory declares a devenv/direnv environment that is NOT loaded in an agent shell. Prefix project tools: \`direnv exec . <cmd>\`."
    fi

    [ -n "$out" ] || exit 0
    ${jq} -n --arg o "$out" '{
      hookSpecificOutput: {
        hookEventName: "SessionStart",
        additionalContext: ("Machine state probed at session start rather than remembered (law 6):\n" + $o)
      }
    }'
  '';

  # The hookable slice of "shellcheck every non-trivial bash you write": a file
  # written through Write or Edit is visible to a hook, so it gets linted the
  # moment it lands. Bash typed inline into a Bash call is not, and stays
  # advisory. Severity is left at the default deliberately — the commit gate runs
  # shellcheck through git-hooks with its defaults, so a quieter setting here
  # would pass a file that fails ten minutes later. Verified 2026-08-22: both
  # tracked shell files are clean at default severity with -x.
  # exit 2 is what feeds the findings back into the conversation.
  shellcheckGate = pkgs.writeShellScript "${a.prefix}-gate-shellcheck" ''
    set -u
    f=$(${jq} -r '.tool_input.file_path // empty')
    case "$f" in
    *.sh | *.bash) ;;
    *) exit 0 ;;
    esac
    [ -f "$f" ] || exit 0
    out=$(${pkgs.shellcheck}/bin/shellcheck -x "$f" 2>&1) && exit 0
    printf 'shellcheck (write-time hook) on %s:\n%s\n' "$f" "$out" >&2
    exit 2
  '';

  # After a rebuild the machine may no longer match what the inventory and
  # ${a.rulesFile} claim. This is the only mechanism that notices, and it reports into
  # the conversation rather than into a log nobody reads.
  conventionsCheck = pkgs.writeShellScript "${a.prefix}-check-conventions" ''
    set -u
    out=$(bash ${a.conventionsScript} 2>&1); rc=$?
    [ $rc -eq 0 ] && exit 0
    out=$(printf '%s\n' "$out" | sed 's/\x1b\[[0-9;]*m//g' | grep -E 'FAIL|failed$')
    ${jq} -n --arg o "$out" '{
      systemMessage: "Convention check FAILED after a system rebuild — /etc/nixos/tools.json or ${a.rulesPath} is now stale.",
      hookSpecificOutput: {
        hookEventName: "PostToolUse",
        additionalContext: ("check-conventions.sh failed after `nh os`. The machine no longer matches what tools.json and ${a.rulesFile} claim; do not trust either until this is fixed.\n" + $o)
      }
    }'
  '';

  # ── the hookable slice of three prose rules ─────────────────────────────────
  # Each of these was written in ${a.rulesFile} as "never do X" and stayed advisory
  # until someone asked the better question: not "is this a hard error or a
  # preference", but "what part of it can a hook actually see". The second
  # question is necessary and not sufficient — `grep -r` and bare `find` are just
  # as visible and are deliberately NOT here, because violating those costs a
  # slower search and nothing else. A wall is worth a round trip only when the
  # violation costs something you cannot get back.
  #
  # There is no `if` filter, because one rule string cannot express three
  # unrelated shapes, so the prefilter below stands in for it. It is a literal
  # match on the raw payload before any fork. `>` is common enough that the
  # redirect arm pays a jq on many calls; measured at a few milliseconds against
  # a 5s timeout, which is the right trade for the one irreversible rule here.
  commandShapeGuard = pkgs.writeShellScript "${a.prefix}-guard-command-shape" ''
    set -u
    ${a.escalateFn}
    input=$(cat)
    # This arm is total rather than a shrug, and it is why this one guard does not
    # use guardPreamble: the test is a literal substring match on the raw payload,
    # which cannot fail to parse. A payload containing none of these literals
    # definitely does not contain a command this guard has an opinion about, so
    # allowing it is an answer, not a guess — and the jq fork is skipped on the
    # majority of Bash calls, which is the point of testing here first.
    case $input in
    *"nix profile"* | *"nix-env"* | *"bin/activate"* | *">"*) ;;
    *) exit 0 ;;
    esac
    # Two reads rather than one `@sh` line through `eval`. The eval was a real hole:
    # when .tool_input.command arrives as an ARRAY — which an argv-shaped exec tool
    # sends — @sh emitted three quoted words, eval ran the second one as a command,
    # and the guard then died on `set -u` with no decision emitted. That fails OPEN,
    # so the law-1 wall and the truncation wall both vanished for array payloads,
    # and a model-controlled argv element got executed inside the guard on the way.
    # `join(" ")` flattens the array case into the string the rest of this expects.
    cmd=$(printf '%s' "$input" | ${jq} -r '.tool_input.command // "" | if type == "array" then join(" ") else . end') ||
      escalate "guard could not parse a hook payload that looked like it contained a guarded command shape. Asking rather than assuming."
    cwd=$(printf '%s' "$input" | ${jq} -r '.cwd // ""') ||
      escalate "guard could not read the cwd out of a hook payload that looked like it contained a guarded command shape."
    [ -n "$cmd" ] ||
      escalate "the hook payload carried no command, so this guard cannot inspect its shape. Asking rather than assuming."
    deny() {
      ${jq} -n --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
      exit 0
    }

    # Law 1. `install` is the old spelling, `add` the current one; both are denied
    # so a command copied from older docs fails the same way.
    case $cmd in
    *"nix profile install"* | *"nix profile add"* | *"nix-env -i"* | *"nix-env --install"*)
      deny "law 1: nothing is installed imperatively, and this would write a profile nix does not own. Persistent → modules/nixos/packages.nix (system) or modules/home/default.nix (user), then hand the switch over. One-off → nix shell nixpkgs#<pkg> -c <cmd>. Per-project → devenv.nix." ;;
    esac

    # "never hand-activate a venv" — uv is the only route to an interpreter here.
    case $cmd in
    *"bin/activate"*)
      deny "law 1 for Python: activating a venv by hand puts an interpreter on PATH that nothing declares. Use uv run / uv run -m / uvx, or uv add and uv sync inside a project." ;;
    esac

    # "never `> tmp && mv tmp f`" — the half of that rule with teeth is the
    # narrower `cmd f > f`, where the shell truncates f before the reader opens
    # it and the contents are gone with no error. Detected by pulling the last
    # real `>` target (>> and 2>&1 do not match) and asking whether that same
    # word appears in the part of the command before it. Gated on the target
    # already existing: creating a new file destroys nothing, and the check would
    # rather miss than block a legitimate write.
    tgt=$(printf '%s' "$cmd" | sed -n 's/^.*[^>&]>[[:space:]]*\([^[:space:];|&<>]\{1,\}\).*$/\1/p')
    if [ -n "$tgt" ]; then
      bef=$(printf '%s' "$cmd" | sed -n 's/^\(.*[^>&]\)>[[:space:]]*[^[:space:];|&<>]\{1,\}.*$/\1/p')
      case " $bef " in
      *" $tgt "*)
        if [ -e "$tgt" ] || { [ -n "$cwd" ] && [ -e "$cwd/$tgt" ]; }; then
          deny "'$tgt' is both an input and the redirect target: the shell truncates it before the command reads it, so the file is emptied and the command sees nothing. Edit in place with | sponge instead."
        fi
        ;;
      esac
    fi
    exit 0
  '';

  # "New files must be `git add`ed first or the flake cannot see them." Verified
  # 2026-08-22: a referenced-but-untracked module fails with `error: Path '…' in
  # the repository "/etc/nixos" is not tracked by Git`. That message names the
  # file but not the fix, and the fix is non-obvious in a colocated repo, where
  # jj already considers the file tracked and only the git index is behind. So
  # this denies early and says the command to run.
  untrackedNixGuard = pkgs.writeShellScript "${a.prefix}-guard-untracked-nix" ''
    ${guardPreamble}
    ${requires ''"nh os build"* | "nix flake check"*''}
    case "$cwd" in
    /etc/nixos | /etc/nixos/*) ;;
    *) exit 0 ;;
    esac
    files=$(git -C /etc/nixos ls-files --others --exclude-standard -- '*.nix' 2>/dev/null)
    [ -n "$files" ] || exit 0
    ${jq} -n --arg f "$files" '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: ("the flake reads the git tree, so an untracked .nix is invisible to it and evaluation fails on the first module that imports one. Run `git add` on these first:\n" + $f)
      }
    }'
  '';

  # Context economy — the one rule here whose cost is paid in a resource that
  # cannot be topped up mid-session. When a Bash result is oversized the harness
  # writes it to <session>/tool-results/<id>.txt and shows only a head. That is a
  # saving already banked. Measured 2026-08-23 over session 38561f2e: 232 KB was
  # spilled that way, and seven later calls paginated 54 KB of it straight back in
  # with `sed -n '1,400p'`, spending exactly what the spill had saved. Bash was
  # 92% of that session's tool output, and 5% of its calls carried 38% of it.
  #
  # This is validation, not geometry. Output size is unknowable before a command
  # runs, so the wasteful state cannot be made unrepresentable the way an illegal
  # state can — only refused once it has been named. Saying so here is cheaper
  # than someone later mistaking this guard for a design.
  #
  # It is a separate guard rather than a fourth arm of commandShapeGuard because
  # that one answers for law 1 and for data loss, and this answers for context.
  # Keeping them apart is also what makes "the other guards are unaffected" true
  # by construction instead of by test — see claude/replay-guards.sh.
  #
  # The deny names BOTH exits on purpose. Naming only `grep` looks complete and is
  # not: when the whole file genuinely is the answer, grep cannot deliver it and
  # the wall becomes a trap. Re-running the original command in smaller batches is
  # the second exit, and it is the one that gets forgotten. A guard that denies its
  # own remedy is broken, which is why replay-guards.sh asserts that every route
  # this message names is a route this guard allows.
  spillPaginationGuard = pkgs.writeShellScript "${a.prefix}-guard-spill-pagination" ''
    set -u
    ${a.escalateFn}
    input=$(cat)
    # This runs on every Bash call, so the literal test comes before the jq fork,
    # for the same reason commandShapeGuard tests first and parses second. A
    # payload without this substring cannot be about a spill file, so allowing it
    # is an answer rather than a guess.
    case $input in
    ${a.spillMatch}) ;;
    *) exit 0 ;;
    esac
    cmd=$(printf '%s' "$input" | ${jq} -r '.tool_input.command // empty | if type == "array" then join(" ") else . end') ||
      escalate "guard could not parse a hook payload that named a spill file. Asking rather than assuming."
    [ -n "$cmd" ] ||
      escalate "the hook payload carried no command, so this guard cannot inspect its shape. Asking rather than assuming."
    deny() {
      ${jq} -n --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
      exit 0
    }

    # Pad and flatten separators so a verb is found the same way whether it opens
    # the command, follows a semicolon, or sits after a pipe. Without this, `cat f`
    # at position 0 has no leading space and slips past a " cat " test.
    probe=$(printf ' %s ' "$cmd" | tr ';|&()\n\t' '       ')

    # Order is the totality argument. Queries are allowed first, so `grep … | head`
    # is judged as the query it is rather than the pagination it contains. The
    # bulk-import verbs are refused second. The default arm is a decision, not a
    # fallthrough: `rm`, `ls`, `stat` on a spill file have nothing to do with
    # context economy, and this guard has no opinion about them.
    #
    # `sed -n '/anchor/,/anchor/p'` is deliberately on the deny side. It reads as a
    # query but routinely extracts most of the file, and it is the exact shape the
    # 54 KB was spent on. `grep -A/-B` covers the honest version of that intent.
    case $probe in
    *" grep "*|*" rg "*|*" jq "*|*" wc "*) exit 0 ;;
    *" sed "*|*" cat "*|*" head "*|*" tail "*|*" awk "*)
      deny "the harness spilled this result to a file to keep it out of context; paginating it back in spends exactly what the spill saved. Measured on this machine: 232 KB spilled, 54 KB pulled straight back. Two ways forward, and the second is the one that gets forgotten. (1) grep/rg the file, if you need a fact out of it. (2) If you genuinely need all of it, re-run the ORIGINAL command in smaller batches so each result lands in context directly. A spill means the read was sized wrong, not that the content is off limits." ;;
    *) exit 0 ;;
    esac
  '';
}
