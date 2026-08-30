#!/usr/bin/env bash
# Replay every Bash command this machine has already run through EVERY PreToolUse
# guard, and assert each guard's laws over that corpus.
#
# Why a corpus and not a single red run. Watching a guard go red once is
# example-based: it proves the guard fires on the case you thought of, which is
# the case you designed it for. The transcripts under ~/.claude/projects hold
# thousands of real commands nobody chose to be representative, which is exactly
# what makes them a generator worth replaying. The guard prints a decision and
# the harness performs it, so replaying the whole corpus is free of effects —
# nothing is denied for real, the JSON is just read.
#
# Three laws, and each one has caught something:
#
#   L1  totality       every payload yields exactly one decision, none falls through
#   L2  no self-block  every route a deny message names must itself be allowed
#   L3  non-interference  outside its trigger the guard is the identity function
#
# L2 is the reusable one. A wall that denies its own remedy looks correct in
# review and traps you at the moment you comply with it. It found the one in
# untrackedNixGuard: that deny says to run `git add`, and `git add new.nix && nh
# os build` — complying in a single line — was refused by the guard that said it.
#
# EVERY guard, which it did not used to be. This script resolved ONE script by
# its statusMessage, a spinner string, and carried one guard's routes hard-coded
# in its own body; pointing it elsewhere gave an honest L1 and L3 and a
# meaningless L2. So the laws moved to where the guards are: each declares its
# offTrigger and its routes beside its own deny text in
# modules/nixos/agent-guards.nix, claude.nix and codex.nix turn that into a
# manifest filtered by what each actually wires, and both fail the build on a
# PreToolUse hook that declares nothing. This script reads the manifest and holds
# every entry to all three laws.
#
# Reading the manifest keeps the property the statusMessage lookup had: it is
# generated from the same hook structure that becomes managed-settings.json or
# requirements.toml, so a guard that is written and never attached cannot appear
# here and pass three laws it is not subject to.
#
# Usage:
#   bash claude/replay-guards.sh                    # claude's guards
#   AGENT=codex bash claude/replay-guards.sh        # codex's, including its own two
#   ONLY=publishGate bash claude/replay-guards.sh   # one guard, while iterating
#   MANIFEST=/path/to.json bash claude/replay-guards.sh   # a doctored copy, to watch it go red
#
# Exit 0 = every law holds for every guard. 1 = at least one failed. 2 = the run
# could not be set up.

set -u

FLAKE=${FLAKE:-/etc/nixos}
HOST=${HOST:-nixos-machine}
AGENT=${AGENT:-claude}
PROJECTS=${PROJECTS:-$HOME/.claude/projects}
MANIFEST=${MANIFEST:-}
ONLY=${ONLY:-}
# The cwd every payload claims. Guards that scope themselves to this repo read
# it, so replaying from anywhere else would silently exercise their other arm.
CWD=${CWD:-/etc/nixos}

note() { printf '%s\n' "$*"; }

# ── resolve the manifest ─────────────────────────────────────────────────────
if [ -z "$MANIFEST" ]; then
  note "building $AGENT's replay manifest from $FLAKE ..."
  MANIFEST=$(nix build --no-link --print-out-paths \
    "$FLAKE#nixosConfigurations.$HOST.config.agents.replayManifest.$AGENT" 2>/dev/null | tail -1)
fi
[ -n "$MANIFEST" ] && [ -r "$MANIFEST" ] || {
  note "could not read a replay manifest for $AGENT"
  exit 2
}
count=$(jq 'length' "$MANIFEST" 2>/dev/null) || count=0
[ "$count" -gt 0 ] || {
  note "$AGENT's manifest lists no PreToolUse guards"
  exit 2
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# ── build the corpus ─────────────────────────────────────────────────────────
# One JSON string per line: the command text of every Bash tool call on record.
find "$PROJECTS" -type f -name '*.jsonl' -print0 2>/dev/null |
  while IFS= read -r -d '' f; do
    jq -c 'select(.type=="assistant")
                       | .message.content[]?
                       | select(.type=="tool_use" and .name=="Bash")
                       | .input.command // empty' "$f" 2>/dev/null
  done >"$work/corpus.json"

total=$(wc -l <"$work/corpus.json")
[ "$total" -gt 0 ] || {
  note "corpus is empty — no transcripts under $PROJECTS"
  exit 2
}
note "corpus: $total recorded Bash commands · $count guards · agent: $AGENT"
note ""

# ── one guard, all three laws ────────────────────────────────────────────────
# Runs in a background subshell: `red` cannot be propagated out of one, so the
# count lands in a file and the parent sums them.
run_guard() {
  local idx=$1
  local entry guard skip off log rt red=0

  entry=$(jq -c ".[$idx]" "$MANIFEST")
  guard=$(jq -r '.command' <<<"$entry")
  skip=$(jq -r '.skipOnTrigger // false' <<<"$entry")
  off=$(jq -c '.offTrigger' <<<"$entry")
  log=$work/log.$idx

  : >"$log"
  pass() {
    printf '  ok    %s\n' "$*" >>"$log"
    return 0
  }
  fail() {
    printf '  FAIL  %s\n' "$*" >>"$log"
    red=$((red + 1))
  }

  [ -x "$guard" ] || {
    printf '  FAIL  guard is not executable: %s\n' "$guard" >>"$log"
    echo 1 >"$work/red.$idx"
    return
  }

  # Every invocation gets its own scratch XDG_RUNTIME_DIR. estopGuard reads its
  # sentinel from there, so this both keeps the corpus replay disengaged and lets
  # a route engage the switch without touching the real one — engaging that would
  # stop every agent on the machine, the one side effect a replay must not have.
  rt=$work/rt.$idx
  mkdir -p "$rt"
  export XDG_RUNTIME_DIR=$rt

  # Split the corpus by this guard's own trigger: bind the command, then ask
  # whether any declared trigger is a substring of it. An empty offTrigger makes
  # every command off-trigger, which is the correct law for a guard that has no
  # trigger — while its switch is disengaged it must be the identity function
  # over everything.
  # $s is bound explicitly. Written as `select($c | contains(.))` the `.` rebinds
  # to $c inside the pipe, so every command matched every trigger and both L1 and
  # L3 silently ran over an empty set while reporting green.
  jq -c --argjson t "$off" --arg cwd "$CWD" \
    '. as $c
     | {on: ([$t[] as $s | select($c | contains($s))] | length > 0),
        payload: {cwd: $cwd, tool_input: {command: $c}}}' \
    <"$work/corpus.json" >"$work/split.$idx"

  local replayed=0 dropped=0
  : >"$work/verdicts.$idx"
  while IFS= read -r line; do
    local on payload out rc decision
    case $line in
    '{"on":true'*) on=true ;;
    *) on=false ;;
    esac
    if [ "$skip" = true ] && [ "$on" = true ]; then
      dropped=$((dropped + 1))
      continue
    fi
    payload=$(jq -c '.payload' <<<"$line")
    # stderr is kept OUT of the decision. Folding it in with 2>&1 made a guard
    # that merely chattered look like one that named no decision: GNU sed writes
    # "invalid or incomplete multibyte character" for some recorded commands, and
    # four payloads failed L1 for it while the guard was in fact allowing them
    # correctly. It is still worth seeing — a guard whose sed died lost that arm
    # silently — so it accumulates and is reported as a note below.
    out=$(printf '%s' "$payload" | "$guard" 2>>"$work/err.$idx")
    rc=$?
    if [ "$rc" -ne 0 ]; then
      decision=crash
    elif [ -z "$out" ]; then
      decision=allow
    else
      decision=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
      # "ask", not "escalate": claude-code's enum is allow/deny/ask/defer, and a
      # word outside it is exactly the vocabulary bug this set must not absorb —
      # an unknown decision counts as undecided and fails L1, by design.
      case $decision in
      deny | ask | allow) ;;
      *) decision=undecided ;;
      esac
    fi
    replayed=$((replayed + 1))
    printf '{"on":%s,"decision":"%s","payload":%s}\n' "$on" "$decision" "$payload" \
      >>"$work/verdicts.$idx"
  done <"$work/split.$idx"

  # ── L1 totality ────────────────────────────────────────────────────────────
  local bad
  bad=$(jq -s '[.[] | select(.decision=="crash" or .decision=="undecided")] | length' "$work/verdicts.$idx")
  if [ "$bad" -eq 0 ]; then
    pass "L1 totality — all $replayed payloads produced exactly one decision"
  else
    fail "L1 totality — $bad payloads crashed or named no decision"
    jq -r 'select(.decision=="crash" or .decision=="undecided")
             | "        " + .decision + ": " + ((.payload.tool_input.command // "") | gsub("\n"; " ⏎ ") | .[0:100])' \
      "$work/verdicts.$idx" | head -5 >>"$log"
  fi
  if [ "$dropped" -gt 0 ]; then
    printf '  note  %s on-trigger commands dropped (skipOnTrigger: the triggered path does real work)\n' \
      "$dropped" >>"$log"
  fi
  # ── L3 non-interference ────────────────────────────────────────────────────
  local off_total off_bad
  off_total=$(jq -s '[.[] | select(.on == false)] | length' "$work/verdicts.$idx")
  off_bad=$(jq -s '[.[] | select(.on == false and .decision != "allow")] | length' "$work/verdicts.$idx")
  if [ "$off_bad" -eq 0 ]; then
    pass "L3 non-interference — $off_total commands outside the trigger, all allowed"
  else
    fail "L3 non-interference — $off_bad commands outside the trigger were not allowed"
    jq -r 'select(.on == false and .decision != "allow")
             | "        " + .decision + ": " + ((.payload.tool_input.command // "") | gsub("\n"; " ⏎ ") | .[0:100])' \
      "$work/verdicts.$idx" | head -5 >>"$log"
  fi

  # ── L2 no self-block ───────────────────────────────────────────────────────
  # The declared routes: what the deny message names as the way out must be
  # allowed, and the shape the guard exists to refuse must be denied.
  local nroutes r cmd want estop out rc decision reason
  nroutes=$(jq '.routes | length' <<<"$entry")
  for ((r = 0; r < nroutes; r++)); do
    cmd=$(jq -r ".routes[$r].command" <<<"$entry")
    want=$(jq -r ".routes[$r].want" <<<"$entry")
    estop=$(jq -r ".routes[$r].estop // false" <<<"$entry")
    if [ "$estop" = true ]; then
      printf 'replay probe\n' >"$rt/agent-estop"
    fi
    # rc is read exactly like L1's: a route whose guard invocation crashes (any
    # non-zero exit) is a route failure regardless of what, if anything, reached
    # stdout — before this, empty stdout from a crash and empty stdout from a
    # genuine allow were the same "decision=allow", so a guard that died silently
    # on its own declared route passed as the law it was meant to demonstrate.
    # stderr is kept out of $out for the same reason L1 keeps it out at line
    # 163 above: folded in with 2>&1, a route's own benign stderr chatter reads
    # as an unparsable decision and fails a route that actually allowed
    # correctly.
    out=$(jq -nc --arg c "$cmd" --arg cwd "$CWD" '{cwd:$cwd, tool_input:{command:$c}}' | "$guard" 2>>"$work/err.$idx")
    rc=$?
    rm -f "$rt/agent-estop"
    if [ "$rc" -ne 0 ]; then
      decision=crash
    elif [ -z "$out" ]; then
      decision=allow
    else
      decision=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "undecided"' 2>/dev/null)
    fi
    if [ "$decision" = "$want" ]; then
      pass "L2 $(printf '%s' "$cmd" | tr '\n' ' ' | cut -c1-64) → $decision"
    else
      fail "L2 $(printf '%s' "$cmd" | tr '\n' ' ' | cut -c1-64) → $decision (wanted $want)"
      reason=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null)
      [ -n "$reason" ] && printf '        %s\n' "$(printf '%s' "$reason" | head -c 200)" >>"$log"
    fi
  done

  # Both loops above append the guard's stderr to this file, so the note has to
  # come after BOTH of them. It used to sit between L1 and L3, which meant every
  # byte L2 wrote was collected into a file nothing read again — a route whose
  # sed died lost that arm silently while still reporting the decision the route
  # wanted, which is the exact failure the L1 comment at the top of this function
  # says the file exists to surface.
  if [ -s "$work/err.$idx" ]; then
    printf '  note  the guard wrote to stderr on some payloads — not a decision, but an arm that died quietly:\n' >>"$log"
    sort -u "$work/err.$idx" | head -3 | sed 's/^/        /' >>"$log"
  fi

  # ── the deny set, for eyeballing ───────────────────────────────────────────
  local denied
  denied=$(jq -s '[.[] | select(.decision=="deny")] | length' "$work/verdicts.$idx")
  printf '  note  deny set over the corpus: %s of %s\n' "$denied" "$replayed" >>"$log"
  jq -r 'select(.decision=="deny")
           | "        " + ((.payload.tool_input.command // "") | gsub("\n"; " ⏎ ") | .[0:100])' \
    "$work/verdicts.$idx" | sort -u | head -8 >>"$log"

  echo "$red" >"$work/red.$idx"
}

# ── run the guards concurrently ──────────────────────────────────────────────
# In parallel across GUARDS, not across payloads: each guard keeps its own
# sequential loop and its own output file, so nothing interleaves and the wall
# clock is the slowest single guard rather than their sum.
for ((i = 0; i < count; i++)); do
  gname=$(jq -r ".[$i].name" "$MANIFEST")
  if [ -n "$ONLY" ] && [ "$gname" != "$ONLY" ]; then
    continue
  fi
  run_guard "$i" &
done
wait

# ── report, in manifest order ────────────────────────────────────────────────
red=0
ran=0
for ((i = 0; i < count; i++)); do
  [ -r "$work/red.$i" ] || continue
  ran=$((ran + 1))
  gname=$(jq -r ".[$i].name" "$MANIFEST")
  printf '\n\033[1m%s\033[0m\n' "$gname"
  cat "$work/log.$i"
  red=$((red + $(cat "$work/red.$i")))
done

note ""
if [ "$ran" -eq 0 ]; then
  note "no guard matched ONLY=$ONLY"
  exit 2
fi
if [ "$red" -eq 0 ]; then
  note "all laws hold for all $ran guards."
else
  note "$red law(s) failed across $ran guards."
fi
exit $((red > 0 ? 1 : 0))
