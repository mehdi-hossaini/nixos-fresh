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
  lib,
  denies,
}:
rec {
  # `pkgs.writeShellScript` runs `stdenv.shellDryRun` and nothing else — `bash -n`,
  # a syntax check rather than a lint. So the guards below were the only shell in
  # this repo that never met shellcheck: the flake gate covers the tracked `*.sh`
  # files, `shellcheckGate` further down covers any `*.sh` an agent writes, and the
  # ~900 lines actually doing the enforcing fell between them. That is this repo's
  # own signature failure aimed at itself — a wall that is trusted and is not there
  # — and it lands harder here than anywhere else, because what shellcheck catches
  # in a guard (an unquoted expansion, a subshell that loses its variable) is the
  # class that makes one fail OPEN rather than loudly.
  #
  # `writeShellApplication` is the built-in that shellchecks, and it is the wrong
  # tool: it prepends `set -euo pipefail`, and several guards here are written
  # against its absence. `conventionsCheck` reads `rc=$?` from a command that is
  # expected to fail and `sessionStartCheck` carries on past one — under `set -e`
  # both exit before they decide anything, which turns a report into silence. So
  # this keeps writeShellScript's shape verbatim and only adds the lint to its
  # checkPhase, shellDryRun included rather than replaced.
  #
  # Default severity, for the reason `shellcheckGate` gives about its own: the
  # commit gate runs shellcheck with defaults, so a quieter setting here would pass
  # a script that fails the flake ten minutes later.
  #
  # This is a BUILD-time gate, which means `nh os build` is what fires it and `nix
  # flake check` is not — evaluation creates these derivations without realising
  # them. That is the right seam rather than a gap to close later: law 1 already
  # ends every change here at a clean `nh os build`, so a guard cannot reach the
  # hand-over unlinted, and a second copy of the check in `checks` would be a
  # second place deciding what "a guard is clean" means.
  writeGuard =
    name: text:
    pkgs.writeTextFile {
      inherit name;
      executable = true;
      text = ''
        #!${pkgs.runtimeShell}
        ${text}
      '';
      checkPhase = ''
        ${pkgs.stdenv.shellDryRun} "$target"
        # LC_ALL, because shellcheck prints the offending LINE and every deny
        # reason in this file is prose with em dashes in it. Under the sandbox's
        # default C locale that print fails — "commitBuffer: invalid argument
        # (cannot encode character '\8212')" — and the build dies with exit 2 and
        # a mangled half-message instead of the finding. Observed 2026-08-30 on a
        # real SC2221: the lint worked, and reporting it is what broke.
        LC_ALL=C.UTF-8 ${pkgs.shellcheck}/bin/shellcheck "$target"
      '';
    };

  # comma's picker, for a session with no terminal.
  #
  # Not a guard — agent ENVIRONMENT, and it is here for the same reason the
  # guards are: one definition, both agents, and shellchecked at build time by
  # the writer above. `, <cmd>` resolves a command through the nix-index
  # database; when more than one package provides it, comma pipes the candidate
  # names to $COMMA_PICKER on stdin and runs whichever one it reads back on
  # stdout (probed against comma 2.4.1 with a stub picker, 2026-08-30). The
  # default picker is fzy, which needs a tty: in an agent shell it dies with
  # "Failed to open tty" and comma exits 1 saying nothing useful, and in a shell
  # that HAS a pty it would hang — law 3, in a tool this repo now teaches.
  #
  # So: fail, but fail with the answer. Printing the candidates and the explicit
  # form to stderr turns a dead end into the next command to type, which is the
  # same standard the deny messages are held to. Exit 1 rather than picking the
  # first line, because picking silently would run a package nobody named.
  commaPicker = writeGuard "${a.prefix}-comma-picker" ''
    set -u
    candidates=$(cat)
    {
      printf 'comma: more than one package provides that command, and choosing between them needs a terminal this session does not have (law 3).\n'
      printf 'Candidates:\n'
      printf '%s\n' "$candidates" | sed 's/^/  - /'
      printf 'Run the one you mean explicitly:  nix shell nixpkgs#<pkg> -c <cmd>\n'
      printf 'That same list, without running anything:  , -p <cmd>\n'
    } >&2
    exit 1
  '';

  # Claude's permissions.deny, as a shell `case`: a `Bash(<glob>)` pattern and a
  # case pattern mean the same thing, so the translation is mechanical — quote
  # the literal runs and leave the `*`s outside, since a case pattern with a
  # bare space in it is a syntax error rather than a wide match. codex.nix's
  # denyGuard uses this to translate the whole deny list into a hook, since
  # Codex has no declarative equivalent; commandShapeGuard below uses it too,
  # for the slice of that same list a wrapped command would otherwise skip past
  # both agents' front door.
  toCasePattern =
    p:
    lib.concatStringsSep "*" (
      map (s: if s == "" then "" else lib.escapeShellArg s) (lib.splitString "*" p)
    );

  # The bashGroups/tuiGroups deny groups, as `case` arms, shared by codex.nix's
  # denyGuard and commandShapeGuard's backstop below — one translation, not two
  # copies free to drift the way this file's own comments elsewhere warn about.
  denyCaseArms = lib.concatMapStringsSep "\n    " (
    g:
    "${lib.concatMapStringsSep " | " toCasePattern g.patterns}) deny ${lib.escapeShellArg g.reason} ;;"
  ) (denies.bashGroups ++ denies.tuiGroups);

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
  #
  # One newline in SET2, not four: tr pads a short SET2 by repeating its last
  # character, so the two forms are identical (verified, not assumed). The
  # spelled-out version reads as clearer and is what shellcheck's SC2020 fires
  # on — it cannot tell deliberate padding from a set written by mistake, and
  # the guards are shellchecked at build time now (see writeGuard above).
  #
  # A segment can also be a WRAPPER around the command it is actually judging:
  # `bash -c 'git commit -m x'`, `env FOO=bar cmd`, and `nix shell nixpkgs#neovim
  # -c nvim` — law 1's own one-off-tool idiom — all run an inner command that
  # never matches a pattern anchored on the wrapped verb. Found live: `bash -c
  # 'git commit -m probe'` in a colocated /etc/nixos passed colocatedCommitGuard
  # silently while the bare form was denied. `unwrap` extracts the wrapped text
  # and `segments` emits it as an ADDITIONAL line, so every guard and denyGuard
  # built on this function gain the same depth once rather than each growing
  # its own wrapper list. Deliberately narrow — the idioms this repo actually
  # teaches or ships, not an attempt at a general shell parser: quoting a word
  # apart still defeats a downstream prefix match the same way it already
  # defeats every other segment-anchored pattern here (`git "commit"` beats
  # `"git commit"*` too), and that residual is accepted the same way everywhere,
  # not specific to this.
  #
  # A standalone value, not inlined into guardPreamble, because
  # commandShapeGuard needs it too and deliberately does not use guardPreamble
  # (see its own comment) — a second copy here would be exactly the duplicated
  # parser this comment already argues against.
  segmentsFn = ''
    raw_segments() {
      printf '%s' "$cmd" | tr ';|&\n' '\n' |
        sed 's/^[[:space:]]*//; s/[[:space:]]*$//; /^$/d'
    }
    # Sets `unwrapped` instead of printing it, because `inner=$(unwrap "$seg")`
    # is a FORK PER SEGMENT and this runs over every segment of every guarded
    # command. Same reason the assignment strip below is gated on a `case`
    # instead of running unconditionally, and the same reason commandShapeGuard's
    # own loops now test before they `sed`.
    #
    # Measured, not assumed — against the largest payload in the recorded corpus
    # (41K, 667 segments) on a 10s hook timeout: 4.2s before this change-set,
    # 6.8s with the fixpoint added naively, 0.2s once the per-segment forks came
    # out. The naive middle is the number worth keeping: recursing over wrappers
    # made the guard SLOWER than the hole it closed, and a guard that times out
    # is a guard that is not there.
    unwrap() {
      s=$1
      inner=""
      unwrapped=""
      # A leading `VAR=val` run is the environment a verb runs in, not the verb.
      # Stripped before the arms below, which is what lets them be ANCHORED —
      # and anchoring is the whole difference between running a shape and naming
      # one. Unanchored, `*"nix shell "*" -c "*` matched a read-only `grep -n
      # "nix shell nixpkgs#neovim -c nvim --version" claude/CLAUDE.md`, pulled
      # the quoted text out of the middle of it and denied the grep: this repo
      # refusing to be searched for the rules it defines. Same false-positive
      # class the law-1 arm below already records fixing, and it reached Codex
      # too, whose denyGuard shares this function through guardPreamble.
      case "''${s%%[[:space:]]*}" in
      [A-Za-z_]*=*)
        s=$(printf '%s' "$s" | sed -E 's/^([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)+//')
        ;;
      esac
      case "$s" in
      "bash -c "* | "sh -c "*)
        inner=$(printf '%s' "$s" | sed -E 's/^(bash|sh)[[:space:]]+-c[[:space:]]+//')
        ;;
      "env "*)
        inner=$(printf '%s' "$s" |
          sed -E 's/^env[[:space:]]+//; s/^([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*//')
        ;;
      # `timeout <dur>` is this repo's own idiom for a command that might hang,
      # and it is what keeps the anchoring above from costing coverage: with it
      # `timeout 60 nix shell nixpkgs#docker -c docker ps` reaches the docker
      # deny through two unwraps instead of through one greedy match. A bare
      # `timeout 60 nvim` is caught too, but by the prefilter carrying the deny
      # list's own prefixes rather than by anything here — this arm only makes
      # the segment legible once the guard has decided to look at it.
      "timeout "*)
        inner=$(printf '%s' "$s" |
          sed -E 's/^timeout[[:space:]]+(-[^[:space:]]+[[:space:]]+)*[0-9]+[smhd]?[[:space:]]+//')
        ;;
      # The other three wrappers this repo teaches by name. `, <cmd>` resolves a
      # command through nix-index and runs it — law 1's one-off route in one
      # step — and `devenv shell -- <cmd>` / `direnv exec <dir> <cmd>` run one
      # inside a project's environment. Each is a spelling of "run this thing"
      # that the deny list, matching on the verb, cannot see through. Promoting
      # comma in CLAUDE.md without this arm would have handed the TUI wall a
      # spelling it does not read: `, nvim` is `nvim`.
      #
      # Flags before the command defeat the comma arm (`, --cache-level 0 nvim`
      # leaves the flags in `inner`). Accepted and not chased: the flag worth
      # walling is `-i`, which installs, and commandShapeGuard's law-1 arm denies
      # that by name rather than by unwrapping it.
      ", "* | "comma "*)
        inner=''${s#* }
        ;;
      "devenv shell --"*)
        inner=''${s#*-- }
        ;;
      "direnv exec "*)
        inner=$(printf '%s' "$s" |
          sed -E 's/^direnv[[:space:]]+exec[[:space:]]+[^[:space:]]+[[:space:]]+//')
        ;;
      # The FIRST ` -c `, not the last. The greedy `s/^.*[[:space:]]-c…` this
      # replaces extracted after the last one, so `nix shell nixpkgs#git -c git
      # commit -m "use -c to pick a config"` unwrapped to `to pick a config"`
      # and every guard built on `segments` — the commit guard included — saw
      # nothing at all. A ` -c ` inside the wrapped command's own arguments
      # belongs to that command, not to the wrapper that ran it.
      "nix shell "*" -c "* | "nix run "*" -c "*)
        inner=''${s#* -c }
        ;;
      "nix shell "*" --command "* | "nix run "*" --command "*)
        inner=''${s#* --command }
        ;;
      esac
      # No arm matched, but the assignment strip changed the segment: the verb
      # it left behind is still worth judging, so `S=/tmp/x nix shell … -c
      # docker ps` unwraps the whole way down. Compared against the ORIGINAL
      # argument rather than the stripped one, so a segment nothing touched
      # unwraps to nothing rather than to itself — which is also what gives the
      # recursion in `unwrapped_of` its fixed point.
      #
      # `FOO=1 nvim` is judged too, but only because "nvim" is itself in
      # commandShapeGuard's prefilter now — an assignment run has no fixed
      # literal to trigger on, so this arm reaches it through the denied verb
      # rather than through the wrapper.
      [ -n "$inner" ] || inner=$s
      [ "$inner" = "$1" ] && inner=""
      [ -n "$inner" ] || return 0
      # One layer of matching outer quotes, since the wrapper's own argument
      # syntax is what put them there — not full shell unquoting.
      case "$inner" in
      "'"*"'")
        inner=''${inner#\'}
        inner=''${inner%\'}
        ;;
      \"*\")
        inner=''${inner#\"}
        inner=''${inner%\"}
        ;;
      esac
      unwrapped=$inner
    }
    # What a wrapper was hiding, split the same way a raw segment is — and then
    # the same question asked of THAT, because wrappers nest. One level was the
    # first spelling and it left the hole this backstop exists to close one
    # `bash -c` wide: `bash -c 'nix shell nixpkgs#neovim -c nvim'` unwrapped to
    # `nix shell nixpkgs#neovim -c nvim`, which matches no deny pattern, while
    # the bare form was refused. `env FOO=1 nix shell … -c nvim` the same.
    #
    # Terminates on its own: every arm of `unwrap` returns a strict SUFFIX of
    # what it was given, and a segment nothing unwraps returns nothing rather
    # than itself. The depth cap is therefore a belt, not the brace — it bounds
    # a pathological payload's fork count rather than the recursion.
    unwrapped_of() {
      local seg=$1 depth=''${2:-0} out
      [ "$depth" -lt 4 ] || return 0
      unwrap "$seg"
      out=$unwrapped
      [ -n "$out" ] || return 0
      printf '%s\n' "$out" | tr ';|&\n' '\n' |
        sed 's/^[[:space:]]*//; s/[[:space:]]*$//; /^$/d' |
        while IFS= read -r nested; do
          printf '%s\n' "$nested"
          unwrapped_of "$nested" "$((depth + 1))"
        done
    }
    segments() {
      raw_segments | while IFS= read -r seg || [ -n "$seg" ]; do
        printf '%s\n' "$seg"
        unwrapped_of "$seg"
      done
    }
  '';

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

    ${segmentsFn}
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

  # ── what a session loses when a guard is not wired for it ───────────────────
  # One line per guard, and every guard needs one.
  #
  # The two agents do not run the same set: claude.nix attaches all twelve of
  # these, codex.nix eight. A Codex session is told about that gap in
  # ~/.codex/AGENTS.md, and until now that sentence was hand-written prose in
  # modules/home/default.nix, derived from nothing and checked by nothing. It had
  # already gone wrong — it said nothing runs at session start for Codex, three
  # commits after sessionStartContext was wired there, in the file that agent
  # reads as its rules.
  #
  # So the NAMES are derived: each of the two modules reads back the guards it
  # actually attached, and modules/home/default.nix subtracts. Only the WORDING
  # lives here, beside the guards it is about. Wiring a guard now documents it.
  #
  # A guard with no entry throws at eval rather than rendering a shorter list: a
  # wall that is absent AND unmentioned is the exact failure this file is written
  # against.
  #
  # Written from the reader's side — what to do now that the wall is not there,
  # not what the wall would have done.
  absenceNotes = {
    estopGuard = "There is no shared stop switch, so nothing outside your session can pause it mid-run.";
    publishGate = "Nothing is gated on gitleaks or `nix flake check`: not `jj commit` and `jj git push`, and not the verbs that make working-copy content permanent (`jj new`, `jj squash`, `jj split <paths>`). Run both yourself before publishing, and remember a secret reaches `@-` the moment one of those runs, not at push.";
    colocatedCommitGuard = "`git commit` in a colocated repo is not caught for you; `ls -d .jj .git` is the check to run first.";
    untrackedNixGuard = "A referenced-but-untracked `.nix` file is not caught before the flake fails on it — `git add` a new file yourself.";
    commandShapeGuard = "The law-1 command shapes, the truncation trap, fd's bundled -x, and the wrapped-command backstop for the shared deny list are not refused for you.";
    spillPaginationGuard = "Paginating a spilled tool result back into the context is not refused.";
    shellcheckGate = "A `*.sh` you write is NOT shellchecked when it lands — that gate keys on a field Claude's edit tool sets and `apply_patch` does not, so run `shellcheck -x` yourself before calling a shell script finished.";
    conventionsCheck = "Nothing re-runs check-conventions.sh after `nh os`, so a rebuild that invalidates a rule in these instructions passes unremarked.";
    sessionStartCheck = "Nothing checks the conventions when a session begins, so these instructions may already be stale — `bash /etc/nixos/claude/check-conventions.sh` is what says whether they are.";
    sessionStartContext = "Nothing probes the machine when a session begins: which version-control case this directory is, whether it carries unresolved conflicts, and whether direnv has fired are all yours to establish.";
    recordBuild = "An `nh os build` leaves no marker, so nothing can later tell you a generation is built and waiting to be switched.";
    handoffOnStop = "Nothing reminds you when a session ends that a built configuration is still waiting for `nh os switch`.";
  };

  # ── the laws each PreToolUse guard is held to, as data beside the guard ─────
  # claude/replay-guards.sh replays every Bash command this machine has on record
  # through a guard and asserts three laws over the verdicts:
  #
  #   L1  totality         every payload yields exactly one decision
  #   L2  no self-block    every route a deny message names is itself allowed
  #   L3  non-interference outside its trigger the guard is the identity function
  #
  # The laws were written as universal and enforced on ONE guard: the harness
  # resolved a single script by its statusMessage — a spinner string — and carried
  # spillPaginationGuard's routes hard-coded in its own body, so pointing it at
  # another guard gave an honest L1 and L3 and a meaningless L2. Eleven of the
  # twelve guards here, and both of Codex's own, were never replayed.
  #
  # So each guard declares what the harness needs instead, beside the deny text
  # the routes have to match:
  #
  #   offTrigger    substrings. A recorded command containing NONE of them is
  #                 outside this guard's concern and must come back allowed (L3).
  #                 An empty list means the whole corpus is its L3 set.
  #   skipOnTrigger optional. Drop the on-trigger commands from the replay,
  #                 for a guard whose triggered path does real work. The harness
  #                 prints what it dropped — a partial replay must not read as a
  #                 total one.
  #   routes        { command; want; estop? } probes. `want` is allow or deny.
  #                 `estop` puts a sentinel in the harness's scratch
  #                 XDG_RUNTIME_DIR for that probe alone.
  #
  # claude.nix and codex.nix each turn this into a manifest, filtered by what they
  # actually wire, and fail the build on a PreToolUse hook that declares nothing —
  # a guard added without laws is a guard nothing replays.
  #
  # Only PreToolUse guards appear here. The other six decide nothing: a PostToolUse
  # or SessionStart hook cannot block a command, so totality and self-block have
  # nothing to say about it.
  probeSpillFile = "/home/probe/.claude/projects/-etc-nixos/PROBE/tool-results/probe.txt";

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

  estopGuard = writeGuard "${a.prefix}-guard-estop" ''
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

  # No trigger at all, which is the right law for the one wall that is not a
  # rule: while the sentinel is absent this guard must be the identity function
  # over everything, so an empty list makes the whole corpus its L3 set.
  replay.estopGuard = {
    offTrigger = [ ];
    routes = [
      # The harness points XDG_RUNTIME_DIR at a scratch directory for every probe,
      # so `estop` creates a sentinel THERE. Engaging the real switch to test it
      # would stop every agent on the machine, which is the one side effect a
      # replay must not have.
      {
        command = "ls";
        want = "deny";
        estop = true;
      }
      {
        command = "ls";
        want = "allow";
      }
    ];
  };

  # The pre-commit gate jj cannot host: jj has no hook support and bypasses
  # .git/hooks, so both checks run from PreToolUse. Only fires when the working
  # directory is /etc/nixos.
  #
  # TWO TIERS, and the split is the whole design. The cheap check runs on every
  # verb that makes working-copy content permanent; the ten-second one runs only
  # on the two that publish.
  #
  # The induction this gate rests on used to be stated and false. The claim was
  # "every commit passes through this gate as a working tree first, so history
  # stays clean by induction from a clean start" — true only if every route from
  # working copy to permanent commit is gated, and only two were. In jj the
  # working copy IS a commit, so a verb does not CREATE one: it stops `@` from
  # being amended further and leaves the content behind as `@-`. `jj new`,
  # `jj squash` and `jj split <paths>` all do that, and all three were outside the
  # trigger. The escape needs no cleverness: write a secret, `jj new`, delete the
  # secret, push — and the push-time `gitleaks dir` scans a working tree the
  # secret is no longer in, while `@-` carries it upstream. `jj commit` was denied
  # at step two all along; `jj new` was not, and it is the verb the workflow types
  # most.
  #
  # Fixed at the induction rather than at `jj new`. Adding one verb to the trigger
  # would leave `jj squash` and `jj split` doing the same thing, and the next verb
  # after those — the rule is "this makes working-copy content permanent", so the
  # trigger names that set rather than the symptom that exposed it.
  #
  # Scanning history at push time was the other candidate and is worse here.
  # `--all --not --remotes` looked precise and is not: a colocated repo carries a
  # git commit for every jj operation — ~250 of them against 125 real ones on this
  # machine — none of which `jj git push` publishes, since it pushes bookmarks.
  # Scanning them means going red over content that cannot reach the remote, which
  # is a gate nobody can clear rather than a wall.
  #
  # gitleaks was installed and inventoried all along — tools.json even said to run
  # it before pushing — and nothing ran it. check-conventions.sh scans with a
  # hand-written four-pattern regex aimed at the shapes that matter here (private
  # keys, age keys, $6$/$y$ hashes, quoted secret assignments); that stays, because
  # it is targeted at this repo's actual risk. gitleaks adds ~150 rules for the
  # cloud tokens and PATs a pasted example brings in. 0.22s over the whole tree,
  # measured 2026-08-26 as the median of three — the 0.08s this comment claimed
  # before was measured on a smaller tree and never re-taken, which is the rot the
  # palette contrast check exists to prevent and prose does not get. Still far
  # below the flake check, which is what makes it affordable on `jj new`.
  #
  # For a one-off audit of history itself, `gitleaks git /etc/nixos` — 0.21s over
  # all 125 commits, and clean when this landed.
  publishGate = writeGuard "${a.prefix}-gate-publish" ''
    ${guardPreamble}
    ${requires ''"jj commit"* | "jj git push"* | "jj new"* | "jj squash"* | "jj split"*''}
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

        # Tier two. `requires` again, with the narrower pattern: everything above
        # ran for all five verbs, and what follows is for the two that publish.
        # Calling it twice rather than hand-rolling a second matcher keeps ONE
        # segment-anchored matcher in this file — the copies of that parser are
        # exactly what the guardPreamble comment records as the bug that cost the
        # most. `jj new` and its siblings exit here, having paid 0.22s.
    ${requires ''"jj commit"* | "jj git push"*''}
        # Absolute, like the gitleaks call above it. Bare, this evaluated the HOOK
        # PROCESS's working directory rather than the $cwd just validated: from a
        # session whose cwd was not this repo it denied every commit with "does not
        # contain a flake.nix", blaming the tree rather than the guard.
        out=$(nix flake check /etc/nixos 2>&1) && exit 0
        out=$(printf '%s\n' "$out" | sed 's/\x1b\[[0-9;]*m//g' | tail -n 40)
        deny "\`nix flake check\` fails, so this would publish a tree the gate rejects. jj has no hook support and bypasses .git/hooks, so this hook is the pre-commit hook it cannot have. Fix the findings, then run the command again.
    $out"
  '';

  replay.publishGate = {
    offTrigger = [
      "jj commit"
      "jj git push"
      "jj new"
      "jj squash"
      "jj split"
    ];
    # Recorded commands opening a segment with one of those would run gitleaks —
    # and, for the two publishing verbs, a full `nix flake check` — for real, which
    # is half an hour to assert what the routes below assert in seconds. The
    # off-trigger remainder still runs, and the harness prints the count it dropped
    # rather than leaving a partial replay looking total. No count is written here:
    # it was 369 when only two verbs triggered, and a number in a comment that
    # nothing derives is the rot this file spends its length arguing against.
    skipOnTrigger = true;
    routes = [
      # The anchoring regression: merely NAMING the phrase is not performing it.
      # Unanchored, an `rg` for the rule paid a full gate before being allowed.
      {
        command = "rg 'jj commit' claude/CLAUDE.md";
        want = "allow";
      }
      {
        command = "jj log";
        want = "allow";
      }
      # The gate must let a clean tree through, or the only way to commit is
      # around it. State-dependent by design: where `nix flake check` fails these
      # come back deny, and that is the gate working rather than the law breaking.
      {
        command = "jj commit -m probe";
        want = "allow";
      }
      {
        command = "jj git push";
        want = "allow";
      }
      # The three verbs the induction was missing. They must be ALLOWED on a clean
      # tree — the point is that they now pay gitleaks, not that they are refused —
      # and each is the working-copy-to-permanent route that `jj commit` was
      # already gated on.
      {
        command = "jj new";
        want = "allow";
      }
      {
        command = "jj squash";
        want = "allow";
      }
      {
        command = "jj split flake.nix";
        want = "allow";
      }
    ];
  };

  # `git commit` is correct in a git-only repo and only destructive in a
  # colocated one, so this cannot be a flat deny pattern. It looks for .jj in the
  # working directory and denies on that.
  colocatedCommitGuard = writeGuard "${a.prefix}-guard-git-commit" ''
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

  replay.colocatedCommitGuard = {
    offTrigger = [ "git commit" ];
    routes = [
      {
        command = "git commit -m probe";
        want = "deny";
      }
      # The two remedies this deny names, and the reads it promises are unaffected.
      {
        command = "jj commit -m probe";
        want = "allow";
      }
      {
        command = "jj describe -m probe";
        want = "allow";
      }
      {
        command = "git log --oneline -3";
        want = "allow";
      }
      {
        command = "git show HEAD";
        want = "allow";
      }
      {
        command = "git blame flake.nix";
        want = "allow";
      }
      {
        command = "rg 'git commit' claude/CLAUDE.md";
        want = "allow";
      }
    ];
  };

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
  # 0.47s, which is what makes this affordable at every startup rather than a
  # thing to run when you remember. Quiet on success: nothing is printed when the
  # assertions hold, so the cost is the runtime and no context at all.
  #
  #   hyperfine -N 'bash /etc/nixos/claude/check-conventions.sh'
  #
  # The command is written down because the number without it was not
  # reproducible: this said 0.29s over 29 assertions, measured 2026-08-22, and by
  # 2026-08-26 it was 0.47s over 37 — the script had grown eight assertions and
  # nothing re-took the figure. Neither number was ever load-bearing (both are far
  # under a second), but "0.29s" read as current when it was a fossil, and the
  # count read as a fact when it was a snapshot. Re-run the line above rather than
  # trusting either; the assertion count is deliberately no longer written here,
  # since `check-conventions.sh` prints it and a second copy is what went stale.
  sessionStartCheck = writeGuard "${a.prefix}-session-start-check" ''
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
  # nix eval below is 6.4s on this machine (hyperfine -N, 2026-08-26) — seconds of
  # latency added to `ls`. Claude's filter stays where it is and becomes a cheap
  # prefilter rather than the only thing that makes this safe.
  #
  # No escalate and no guardPreamble, unlike the PreToolUse guards. Those decide
  # whether a command runs, so "cannot tell" has to become a question; this one
  # runs after the fact and can neither block nor allow anything. The worst case
  # of an unreadable payload is a marker that is not written, which handoffOnStop
  # and sessionStartContext both report as "nothing pending" — an omission, and
  # the honest answer for a hook with no way to ask.
  recordBuild = writeGuard "${a.prefix}-record-build" ''
    set -u
    cmd=$(${jq} -r '.tool_input.command // empty | if type == "array" then join(" ") else . end' 2>/dev/null) || exit 0
    case "$cmd" in
    *"nh os build"*) ;;
    *) exit 0 ;;
    esac
    p=$(nix eval --raw /etc/nixos#nixosConfigurations."$(hostname)".config.system.build.toplevel.outPath 2>/dev/null) || exit 0
    [ -n "$p" ] && printf '%s' "$p" > "${builtMarker}"
    exit 0
  '';

  handoffOnStop = writeGuard "${a.prefix}-handoff-on-stop" ''
    set -u
    [ -r "${builtMarker}" ] || exit 0
    built=$(cat "${builtMarker}") || exit 0
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
  # a wait, so this stays serial — 33ms in /etc/nixos with the jj conflicts query
  # included, hyperfine -N over 20 runs, re-taken 2026-08-26 and unchanged from
  # the 0.03s first recorded. The one figure in this file that was still true when
  # the others were audited.
  #
  # No guardPreamble and no escalate, unlike every guard above. Those decide
  # whether a command runs, so "cannot tell" has to become a question. This
  # decides nothing and returns no permissionDecision, so its undecidable case is
  # to say less: every probe that fails is dropped and the session starts on what
  # was learned. A context hook that can abort a session start is worse than one
  # that occasionally has nothing to add.
  sessionStartContext = writeGuard "${a.prefix}-session-start-context" ''
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

    if [ -r "${builtMarker}" ]; then
      built=$(cat "${builtMarker}" 2>/dev/null) || built=""
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
  shellcheckGate = writeGuard "${a.prefix}-gate-shellcheck" ''
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
  conventionsCheck = writeGuard "${a.prefix}-check-conventions" ''
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

  # ── the hookable slice of three prose rules, plus two segment-level backstops ─
  # Each of the first three was written in ${a.rulesFile} as "never do X" and
  # stayed advisory until someone asked the better question: not "is this a hard
  # error or a preference", but "what part of it can a hook actually see". The
  # second question is necessary and not sufficient — `grep -r` and bare `find`
  # are just as visible and are deliberately NOT here, because violating those
  # costs a slower search and nothing else. A wall is worth a round trip only
  # when the violation costs something you cannot get back.
  #
  # There is no `if` filter, because one rule string cannot express five
  # unrelated shapes, so the prefilter below stands in for it. It is a literal
  # match on the raw payload before any fork. `>` is common enough that the
  # redirect arm pays a jq on many calls: 17ms for a payload carrying one against
  # 6ms for one that does not, so the fork costs ~11ms — against a 5s timeout,
  # which is the right trade for the one irreversible rule here. ("A few
  # milliseconds" is what this said before it was measured rather than estimated;
  # the trade is the same, but the number now comes from hyperfine -N over 20 runs
  # of the built guard against a payload file, 2026-08-26.)
  # The literal prefilter for commandShapeGuard, as data — and the same list it
  # declares as its replay offTrigger, so the two cannot disagree about what the
  # guard is even about. It used to be a `case` in the body and a list in the
  # replay block, which is the shape the spillTriggers comment in claude.nix
  # already warns against.
  #
  # The first ten are the shapes the guard's own arms look for. `denyPrefixes` is
  # what the backstop needs, and adding it is what closed the wrapper leaks:
  # `timeout 60 nvim`, `FOO=1 nvim` and `, nvim` all unwrap to a denied verb, and
  # the guard used to exit before unwrapping anything, because none of them
  # contains a literal from the hand-written half. A prefilter derived from the
  # deny list cannot fall behind the deny list.
  #
  # The cost is real and was measured before taking it: this widens the guard to
  # most Bash calls, and the arms behind it now run over the corpus's worst
  # payload (41K, 667 segments) in 0.23s against a 10s timeout. The check that
  # this widening changed no decision it should not have is not L3 — which goes
  # vacuous as the off-trigger set collapses — but the corpus decision diff
  # between the old guard and the new one.
  #
  # Reduced to the literals that are not already implied by a shorter one. A
  # substring test asks "does the payload contain any of these", so a literal
  # that CONTAINS another can never decide anything the shorter one did not
  # already decide: `*'fd -x'*` is dead weight beside `*'fd'*`, and
  # `*'devenv shell'*` beside `*'env '*`. shellcheck is what makes this
  # mandatory rather than tidy — SC2221/SC2222 fail the guard's build on a case
  # arm that another arm subsumes, which is a lint worth having on a list that
  # is now generated from two sources and could quietly grow overlaps.
  commandShapeTriggers =
    let
      raw = [
        "nix profile"
        "nix-env"
        "bin/activate"
        ">"
        "nix shell"
        "nix run"
        "bash -c"
        "sh -c"
        "env "
        "fd "
        "timeout "
        ", "
        "comma "
        "devenv shell"
        "direnv exec"
      ]
      ++ denies.denyPrefixes;
    in
    lib.filter (t: !(lib.any (u: u != t && lib.hasInfix u t) raw)) (lib.unique raw);

  commandShapeGuard = writeGuard "${a.prefix}-guard-command-shape" ''
    set -u
    ${a.escalateFn}
    input=$(cat)
    # This arm is total rather than a shrug, and it is why this one guard does not
    # use guardPreamble's cmd/cwd extraction: the test is a literal substring match
    # on the raw payload, which cannot fail to parse. A payload containing none of
    # these literals definitely does not contain a command this guard has an
    # opinion about, so allowing it is an answer, not a guess — and the jq fork is
    # skipped on the majority of Bash calls, which is the point of testing here
    # first. The wrapper idioms and `fd ` joined the original four once the checks
    # below grew segment-and-wrapper depth (see segmentsFn's own comment) —
    # otherwise the very payloads that motivated that depth would exit here first.
    # The list is commandShapeTriggers, generated: see its comment for why the
    # deny list's own prefixes are in it.
    case $input in
    ${lib.concatMapStringsSep " \\\n      | " (t: "*${lib.escapeShellArg t}*") commandShapeTriggers}) ;;
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
    ${segmentsFn}

    # Computed ONCE, and the arms below read the variable. Each of them used to
    # call `segments` again, so one payload paid for four identical passes over
    # the same command against a 10s hook timeout — and the prefilter that gates
    # this guard passes most Bash calls, since a bare `>` is in it.
    segs=$(segments)

    # Law 1. `install` is the old spelling, `add` the current one; both are denied
    # so a command copied from older docs fails the same way. Segment-anchored and
    # whitespace-collapsed, not a substring of the whole command: unanchored, a
    # read-only `grep -n "nix profile install" file` was denied as though it were
    # performing the install it merely quoted, and `nix  profile  install` (one
    # extra space) defeated the exact-text match the other way. `segments`
    # includes `bash -c`/wrapped forms, so `bash -c 'nix profile install x'` is
    # still caught. Residual and accepted, not fixed here: `nix "profile" install`
    # still defeats a prefix match, the same way `git "commit"` defeats every
    # other segment-anchored pattern in this file — see segmentsFn's comment.
    law1_hit=0
    while IFS= read -r seg || [ -n "$seg" ]; do
      # The whitespace-collapsing `sed` is a fork, and this loop runs once per
      # segment of every guarded command — 667 of them in the largest payload on
      # record. Every pattern below starts with "nix", so a segment that does
      # not cannot match, and a `case` test costs nothing.
      case "$seg" in
      nix* | ,* | comma*) ;;
      *) continue ;;
      esac
      seg_norm=$(printf '%s' "$seg" | sed -E 's/[[:space:]]+/ /g')
      case "$seg_norm" in
      "nix profile install"* | "nix profile add"* | "nix-env -i"* | "nix-env --install"* \
        | ", -i"* | ", --install"* | "comma -i"* | "comma --install"*)
        law1_hit=1 ;;
      esac
    done <<CMDSEG_LAW1
    $segs
    CMDSEG_LAW1
    if [ "$law1_hit" -eq 1 ]; then
      deny "law 1: nothing is installed imperatively, and this would write a profile nix does not own. Persistent → modules/nixos/packages.nix (system) or modules/home/default.nix (user), then hand the switch over. One-off → \`, <cmd>\` or nix shell nixpkgs#<pkg> -c <cmd> — comma without -i runs the program and leaves nothing behind, which is the whole point of it. Per-project → devenv.nix."
    fi

    # "never hand-activate a venv" — uv is the only route to an interpreter here.
    # By the segment's first word (after stripping a `source`/`.` prefix), not a
    # substring of the whole command: the real idiom is `source .venv/bin/activate`
    # or `. .venv/bin/activate`, where "bin/activate" is never the start of the
    # segment, so a prefix match would miss it — but a substring match denied a
    # `grep -n "bin/activate" file` for merely quoting the path.
    venv_hit=0
    while IFS= read -r seg || [ -n "$seg" ]; do
      # Same reason as the loop above: the `sed` that extracts the first word is
      # a fork per segment, and a segment that does not contain the path at all
      # cannot have it as its first word. The substring test is the cheap half
      # of the check; the expensive half still decides.
      case "$seg" in
      *bin/activate*) ;;
      *) continue ;;
      esac
      first=$(printf '%s' "$seg" | sed -E 's/^(source|\.)[[:space:]]+//; s/^([^[:space:]]+).*$/\1/')
      case "$first" in
      bin/activate | */bin/activate) venv_hit=1 ;;
      esac
    done <<CMDSEG_VENV
    $segs
    CMDSEG_VENV
    if [ "$venv_hit" -eq 1 ]; then
      deny "law 1 for Python: activating a venv by hand puts an interpreter on PATH that nothing declares. Use uv run / uv run -m / uvx, or uv add and uv sync inside a project."
    fi

    # "never `> tmp && mv tmp f`" — the half of that rule with teeth is the
    # narrower `cmd f > f`, where the shell truncates f before the reader opens
    # it and the contents are gone with no error. Detected by pulling the last
    # real `>` target (>> and 2>&1 do not match) and asking whether that same
    # word appears in the part of the command before it. Gated on the target
    # already existing: creating a new file destroys nothing, and the check would
    # rather miss than block a legitimate write.
    #
    # A REGULAR file, not merely an existing path. The premise is that the shell
    # empties the target before the reader opens it, and only a regular file can
    # be emptied — writing to `/dev/null` truncates nothing, and a directory
    # cannot be a redirect target at all. With `-e` this arm was the largest
    # false-positive source left on the machine: `echo a > /dev/null && echo b >
    # /dev/null` denied itself, because the last `>` target is `/dev/null` and
    # the text before it contains `/dev/null` too. Measured over the recorded
    # corpus 2026-08-30: 15 denies in 14,068 commands, of which 4 were this —
    # three `/dev/null` pairs and one `/data`, which is a directory.
    tgt=$(printf '%s' "$cmd" | sed -n 's/^.*[^>&]>[[:space:]]*\([^[:space:];|&<>]\{1,\}\).*$/\1/p')
    if [ -n "$tgt" ]; then
      bef=$(printf '%s' "$cmd" | sed -n 's/^\(.*[^>&]\)>[[:space:]]*[^[:space:];|&<>]\{1,\}.*$/\1/p')
      case " $bef " in
      *" $tgt "*)
        if [ -f "$tgt" ] || { [ -n "$cwd" ] && [ -f "$cwd/$tgt" ]; }; then
          deny "'$tgt' is both an input and the redirect target: the shell truncates it before the command reads it, so the file is emptied and the command sees nothing. Edit in place with | sponge instead."
        fi
        ;;
      esac
    fi

    # `fd -x/-X/--exec` runs an arbitrary command per result — agent-denies.nix
    # already says so, but its patterns need "-x"/"-X" as an isolated token, and
    # fd's clap parser bundles short flags: `fd -ix` is `-i` (case-insensitive) +
    # `-x` (exec), invisible to a pattern looking for a lone "-x". A case glob
    # cannot tell that apart from `--regex` or `--fixed-strings`, both of which
    # contain an "x" too, without false-positiving on the common case — so this
    # word-splits instead. `set -f` before the unquoted `set --` turns off
    # globbing first, so a result like `*.txt` in the command is never expanded
    # against the real filesystem; nothing here is executed, only classified.
    #
    # The cluster is read LEFT TO RIGHT and stops at the first short flag that
    # takes a value, because clap accepts the value attached: `fd -exml` is `-e
    # xml`, and asking only whether an "x" appears anywhere in the word denied
    # it as an exec — every `-e<ext>` whose extension carries an x, plus `-ox`
    # and `-Cx…`, went with it. Observed on this machine 2026-08-30, refusing an
    # extension search over this repo. The value-taking set is `fd --help` on
    # the installed binary, not memory: d E t e S o c j C (x and X take one too,
    # but they are the thing being caught, so they are tested before the break).
    fdx_hit=0
    while IFS= read -r seg || [ -n "$seg" ]; do
      case "$seg" in
      "fd "*)
        bundled=$(
          set -f
          # shellcheck disable=SC2086
          set -- $seg
          shift
          for w in "$@"; do
            case "$w" in
            --*) ;;
            -*)
              rest=''${w#-}
              while [ -n "$rest" ]; do
                ch=''${rest:0:1}
                rest=''${rest:1}
                case "$ch" in
                x | X)
                  printf hit
                  break
                  ;;
                d | E | t | e | S | o | c | j | C) break ;;
                esac
              done
              ;;
            esac
          done
        )
        [ -n "$bundled" ] && fdx_hit=1
        ;;
      esac
    done <<CMDSEG_FDX
    $segs
    CMDSEG_FDX
    if [ "$fdx_hit" -eq 1 ]; then
      deny "\`fd -x/-X/--exec\` runs an arbitrary command per result — bundled into another short flag (\`fd -ix\`) is still that flag. Run the command yourself over the results instead."
    fi

    ${lib.optionalString a.needsWrappedDenyBackstop ''
      # The backstop for the other agent-denies.nix groups (docker, the TUI list,
      # jj's diff editor, sudo's switch, sg). For this agent they are enforced
      # DECLARATIVELY, and a declarative pattern reads `$cmd` itself: it does not
      # follow `bash -c`, `env`, `timeout` or `nix shell … -c`. Found live: `nix
      # shell nixpkgs#neovim -c nvim` passed untouched, the exact TUI hang that
      # wall exists to prevent, because law 1's own one-off-tool idiom is
      # indistinguishable at the text-matching layer from a deliberate bypass.
      #
      # Emitted only for the agent that needs it. Codex enforces the same list
      # through codex.nix's denyGuard, which is a hook over `segments` — raw
      # forms AND unwrapped ones, on every Bash call, with no prefilter — so for
      # Codex this block would be a second evaluation of the same arms over a
      # subset of the same input. One list, one translation (denyCaseArms), and
      # now one evaluation per agent rather than two for the one that already
      # had a hook.
      #
      # `wrapped_segments` and not `segments`: the raw forms are what the
      # declarative deny already judges, so re-judging them here buys no coverage
      # and does cost a false-positive class. `raw_segments` splits on \n, so
      # every LINE OF A HEREDOC BODY is a segment, and writing a file whose text
      # contained `vi notes.txt` was denied as though it had launched vim — with
      # every `cat > f <<EOF` in scope, since a bare `>` is in the prefilter.
      # File content is not a command, and a wall that cannot be described inside
      # a heredoc is one whose documentation cannot be written on the machine it
      # guards. Observed 2026-08-30, refusing a plain scratchpad note.
      #
      # Residual, stated rather than fixed: Codex's denyGuard still judges raw
      # segments, heredoc bodies included, because it is Codex's only deny and
      # skipping bodies would open `bash <<EOF` — where the body IS the command.
      #
      # Local to this guard rather than beside `segments` in segmentsFn: it is
      # the only caller, and shared code that only one of six guards invokes is
      # what SC2329 fires on — correctly, since the others would carry a function
      # nothing there calls.
      wrapped_segments() {
        raw_segments | while IFS= read -r seg || [ -n "$seg" ]; do
          unwrapped_of "$seg"
        done
      }
      while IFS= read -r seg || [ -n "$seg" ]; do
        # shellcheck disable=SC2016
        case "$seg" in
        ${denyCaseArms}
        esac
      done <<CMDSEG_BACKSTOP
      $(wrapped_segments)
      CMDSEG_BACKSTOP
    ''}
    exit 0
  '';

  replay.commandShapeGuard = {
    # The guard's own literal prefilter, as data: a payload carrying none of
    # these is one it exits on before it parses anything. The SAME value the body
    # builds its `case` from, not a copy of it — see commandShapeTriggers.
    #
    # Since it gained denyPrefixes this set matches most Bash calls, which makes
    # L3 non-interference a weaker statement than it reads as: the off-trigger
    # corpus it quantifies over has mostly collapsed into the on-trigger one.
    # What actually covers the widened surface is replaying the corpus through
    # the old guard and the new one and diffing the decisions — every change
    # accounted for, no unexplained allow→deny. That is a harness step, not a
    # law, and it is written down here because the law it partly replaces is not
    # the one to read for this guard any more.
    offTrigger = commandShapeTriggers;
    routes = [
      {
        command = "nix profile install hello";
        want = "deny";
      }
      {
        command = "nix profile add hello";
        want = "deny";
      }
      {
        command = "nix-env -i hello";
        want = "deny";
      }
      {
        command = "source .venv/bin/activate";
        want = "deny";
      }
      # The three remedies the three denies name. Each has to be allowed, or the
      # wall refuses the thing it just told you to do.
      {
        command = "nix shell nixpkgs#hello -c hello";
        want = "allow";
      }
      {
        command = "uv run script.py";
        want = "allow";
      }
      {
        command = "sort flake.nix | sponge flake.nix";
        want = "allow";
      }
      # The false-positive class: reading or quoting a guarded phrase is not
      # performing it, the same law `requires`'s own comment already states for
      # every other guard in this file.
      {
        command = "grep -n \"nix profile install\" claude/CLAUDE.md";
        want = "allow";
      }
      {
        command = "grep -n \"bin/activate\" claude/CLAUDE.md";
        want = "allow";
      }
      # The bypass class: a wrapper around the same guarded verb, and the extra-
      # whitespace variant that used to defeat the exact-text match.
      {
        command = "bash -c 'nix profile install hello'";
        want = "deny";
      }
      {
        command = "nix profile  install  hello";
        want = "deny";
      }
      # The wrapper class, allow side. Law 1's own remedy for an UNRELATED tool
      # must still be allowed, the documented mergiraf remedy for jj's diff
      # editor must stay open, and QUOTING a wrapped shape is not running it —
      # the last two were denied until `unwrap`'s arms were anchored and the
      # backstop narrowed to wrapped segments, which between them are what let
      # this repo be searched and documented on the machine it configures.
      #
      # Asserted for BOTH agents. The deny side is emitted only for the agent
      # that carries the backstop (see it in the guard body), but a false
      # positive is a false positive in either.
      {
        command = "nix shell nixpkgs#mergiraf -c jj resolve --tool mergiraf";
        want = "allow";
      }
      {
        command = "grep -n \"nix shell nixpkgs#neovim -c nvim --version\" claude/CLAUDE.md";
        want = "allow";
      }
      {
        command = "cat > /tmp/note.txt <<'NOTE'\nvi notes.txt\ndocker ps\nNOTE";
        want = "allow";
      }
      # fd's bundled short flags: `-ix` is `-i` + `-x`, invisible to a pattern
      # anchored on a lone "-x" token. `-e py` alone, and a long `--regex`
      # argument that happens to contain the letter x, must both stay allowed —
      # the check is on bundled SHORT flags, not on the letter appearing anywhere.
      {
        command = "fd -ix true .";
        want = "deny";
      }
      {
        command = "fd -e py file.txt";
        want = "allow";
      }
      {
        command = "fd --regex ax somefile";
        want = "allow";
      }
      # clap takes a short flag's value attached, so the "x" here is data, not a
      # flag. `-ix` above must stay denied with this allowed, which is the whole
      # reason the cluster is parsed left to right instead of searched.
      {
        command = "fd -exml . claude";
        want = "allow";
      }
      # The truncation arm is gated on the target already existing, so the probe
      # names a file this repo always has.
      {
        command = "sort flake.nix > flake.nix";
        want = "deny";
      }
      {
        command = "sort flake.nix > /tmp/sorted.nix";
        want = "allow";
      }
      # …and the arm's premise stated as a route: only a REGULAR file can be
      # emptied by the shell before the reader opens it. Two redirects to the
      # same device made the last-target/text-before test fire on itself.
      {
        command = "echo a > /dev/null && echo b > /dev/null";
        want = "allow";
      }
      # Law 1 has a second spelling now that comma is taught rather than merely
      # present: `-i` installs into a profile nix does not own, which is the
      # thing law 1 is about, in the tool whose whole point is not doing that.
      {
        command = ", -i ripgrep";
        want = "deny";
      }
      {
        command = ", typos --format brief .";
        want = "allow";
      }
    ]
    # The deny side of the wrapper class, for the agent whose deny list is
    # declarative and therefore stops at the wrapper. The other agent asserts
    # the same shapes against codex.nix's denyGuard, where its own copy of the
    # rule actually lives — a route on a guard that does not carry the arm would
    # be green for the wrong reason, which is the failure this harness exists to
    # make impossible.
    #
    # Each one walked straight through while its bare form was refused. The
    # first needs the unwrap to RECURSE (one level left `bash -c 'nix shell …
    # -c nvim'` looking like an unremarkable `nix shell` line), the second needs
    # `timeout` to count as a wrapper at all, the third needs the extraction to
    # take the FIRST ` -c ` — greedy, the guard saw `"set nowrap"` and nothing
    # else — and the fourth is the spelling that needs no `-c`, keyed on the
    # package attr in agent-denies.nix and carried through the wrapper by the
    # backstop.
    ++ lib.optionals a.needsWrappedDenyBackstop [
      {
        command = "nix shell nixpkgs#neovim -c nvim --version";
        want = "deny";
      }
      {
        command = "nix shell nixpkgs#docker -c docker ps";
        want = "deny";
      }
      {
        command = "bash -c 'nix shell nixpkgs#neovim -c nvim'";
        want = "deny";
      }
      {
        command = "timeout 60 nix shell nixpkgs#docker -c docker ps";
        want = "deny";
      }
      {
        command = "nix shell nixpkgs#neovim -c nvim -c \"set nowrap\"";
        want = "deny";
      }
      {
        command = "bash -c 'nix run nixpkgs#neovim'";
        want = "deny";
      }
      # The wrapper leaks. None of these contains a literal from the prefilter's
      # hand-written half, so until it carried the deny list's own prefixes the
      # guard exited before unwrapping anything and all four ran the TUI.
      {
        command = ", nvim";
        want = "deny";
      }
      {
        command = "timeout 60 nvim";
        want = "deny";
      }
      {
        command = "FOO=1 nvim";
        want = "deny";
      }
      {
        command = "devenv shell -- nvim";
        want = "deny";
      }
      {
        command = "direnv exec . nvim";
        want = "deny";
      }
    ];
  };

  # "New files must be `git add`ed first or the flake cannot see them." Verified
  # 2026-08-22: a referenced-but-untracked module fails with `error: Path '…' in
  # the repository "/etc/nixos" is not tracked by Git`. That message names the
  # file but not the fix, and the fix is non-obvious in a colocated repo, where
  # jj already considers the file tracked and only the git index is behind. So
  # this denies early and says the command to run.
  untrackedNixGuard = writeGuard "${a.prefix}-guard-untracked-nix" ''
    ${guardPreamble}
    ${requires ''"nh os build"* | "nix flake check"*''}
    case "$cwd" in
    /etc/nixos | /etc/nixos/*) ;;
    *) exit 0 ;;
    esac
    # L2, no self-block. This deny names `git add` as the remedy, and complying
    # with it in one line — `git add new.nix && nh os build` — was denied by this
    # guard, because it judged the compound before the add inside it had run. A
    # wall that refuses its own remedy is a trap sprung at the moment you obey it,
    # and claude/replay-guards.sh now asserts that it is not one.
    #
    # So a command that adds first is let through. Nothing is lost: if it named
    # the right file the build works, and if it did not, the flake fails with the
    # message this guard exists to pre-empt — which is exactly where the command
    # would have landed with no wall at all.
    while IFS= read -r seg; do
      case "$seg" in
      "git add"*) exit 0 ;;
      esac
    done <<ADD_SEGMENTS
    $(segments)
    ADD_SEGMENTS
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

  replay.untrackedNixGuard = {
    offTrigger = [
      "nh os build"
      "nix flake check"
    ];
    routes = [
      # The remedy this deny names, and the one-line form of complying with it —
      # which this guard used to refuse. See the L2 note in the body above.
      {
        command = "git add modules/nixos/probe.nix";
        want = "allow";
      }
      {
        command = "git add modules/nixos/probe.nix && nh os build /etc/nixos";
        want = "allow";
      }
      {
        command = "rg 'nh os build' claude/CLAUDE.md";
        want = "allow";
      }
      # State-dependent in the same way publishGate's routes are: this is deny on
      # a tree that really does carry an untracked .nix, which is the guard
      # working rather than the law breaking.
      {
        command = "nh os build /etc/nixos";
        want = "allow";
      }
    ];
  };

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
  spillPaginationGuard = writeGuard "${a.prefix}-guard-spill-pagination" ''
    set -u
    ${a.escalateFn}
    input=$(cat)
    # This runs on every Bash call, so the literal test comes before the jq fork,
    # for the same reason commandShapeGuard tests first and parses second. A
    # payload without this substring cannot be about a spill file, so allowing it
    # is an answer rather than a guess.
    case $input in
    ${pkgs.lib.concatMapStringsSep " | " (t: "*\"${t}\"*") a.spillTriggers}) ;;
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

  replay.spillPaginationGuard = {
    # The same list the prefilter above is built from, so the law and the guard
    # cannot disagree about what this one is even about.
    offTrigger = a.spillTriggers;
    routes = [
      # Route 1 of the two the deny names: query the file instead of reading it.
      {
        command = "grep -n anchor ${probeSpillFile}";
        want = "allow";
      }
      {
        command = "rg anchor ${probeSpillFile}";
        want = "allow";
      }
      {
        command = "grep -n anchor ${probeSpillFile} | head -20";
        want = "allow";
      }
      # Route 2, the one that gets forgotten: re-run the original in batches.
      {
        command = "for f in a.md b.md; do cat $f; done";
        want = "allow";
      }
      # Verbs this guard has no opinion about. One that grew an opinion here
      # would be interfering rather than guarding.
      {
        command = "rm ${probeSpillFile}";
        want = "allow";
      }
      {
        command = "wc -l ${probeSpillFile}";
        want = "allow";
      }
      # The shape it exists to refuse, including the position-0 case that has no
      # leading space for a naive " cat " test to find.
      {
        command = "sed -n '1,400p' ${probeSpillFile}";
        want = "deny";
      }
      {
        command = "cat ${probeSpillFile}";
        want = "deny";
      }
      {
        command = "cat ${probeSpillFile} | tail -5";
        want = "deny";
      }
    ];
  };
}
