#!/usr/bin/env bash
# Replay every Bash command this machine has already run through a PreToolUse
# guard, and assert the guard's laws over that corpus.
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
# review and traps you at the moment you comply with it.
#
# Usage:
#   bash claude/replay-guards.sh                 # resolve the guard from the flake
#   GUARD=/path/to/script bash claude/replay-guards.sh   # a doctored copy, to watch it go red

set -uo pipefail

FLAKE=${FLAKE:-/etc/nixos}
HOST=${HOST:-nixos-machine}
PROJECTS=${PROJECTS:-$HOME/.claude/projects}
STATUS=${STATUS:-Checking for a paginated spill read}
TRIGGER=${TRIGGER:-tool-results/}
GUARD=${GUARD:-}

red=0

note() { printf '%s\n' "$*"; }
fail() {
  printf 'FAIL  %s\n' "$*"
  red=1
}
pass() { printf 'ok    %s\n' "$*"; }

# ── resolve the guard ────────────────────────────────────────────────────────
# Read it out of the built managed settings rather than the module, so the
# wiring is under test too: a guard that is written but never reached would
# otherwise pass every law here.
if [ -z "$GUARD" ]; then
  note "building managed settings from $FLAKE ..."
  # AGENT picks which side is replayed. Claude's guards are named in a JSON
  # settings file and Codex's in a TOML requirements file, but both identify a
  # guard by its statusMessage, so one lookup covers either once the file is
  # chosen. Defaulting to claude alone is how the Codex hooks went unreplayed: the
  # totality law below is exactly what the escalate-to-deny collapse changes, and
  # nothing was checking it over there.
  case "${AGENT:-claude}" in
  codex) attr='environment.etc."codex/requirements.toml".source' ;;
  *) attr='environment.etc."claude-code/managed-settings.json".source' ;;
  esac
  settings=$(nix build --no-link --print-out-paths \
    "$FLAKE#nixosConfigurations.$HOST.config.$attr" 2>/dev/null | tail -1)
  [ -n "$settings" ] && [ -e "$settings" ] ||
    {
      note "could not build ${AGENT:-claude} settings from $FLAKE"
      exit 2
    }
  # tomlq takes jq syntax over TOML, so the filter is the same either way.
  reader=jq
  [ "${AGENT:-claude}" = codex ] && reader=tomlq
  # shellcheck disable=SC2016  # $s is jq syntax; the reader is jq or tomlq, which share it
  GUARD=$("$reader" -r --arg s "$STATUS" \
    '.hooks.PreToolUse[].hooks[] | select(.statusMessage==$s) | .command' "$settings" | head -1)
  [ -n "$GUARD" ] ||
    {
      note "no hook in the built settings carries statusMessage: $STATUS"
      exit 2
    }
fi
[ -x "$GUARD" ] || {
  note "guard is not executable: $GUARD"
  exit 2
}
note "guard under test: $GUARD"

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
note "corpus: $total recorded Bash commands"

# Wrap each into a hook payload in a single jq pass rather than one fork each.
jq -c '{cwd: "/etc/nixos", tool_input: {command: .}}' <"$work/corpus.json" >"$work/payloads.json"

# ── run every payload once, record the verdicts ──────────────────────────────
# One JSON object per line. A recorded command routinely contains newlines and
# occasionally a null byte, so it never survives a line-oriented record intact:
# the first attempt used a TSV and awk counted every continuation line as its own
# verdict, reporting more violations than there were commands. The payload is
# already valid JSON and `decision` is one of six fixed words, so this needs no
# escaping and no extra jq fork per command.
: >"$work/verdicts.jsonl"
undecided=0
malformed=0
while IFS= read -r payload; do
  out=$(printf '%s' "$payload" | "$GUARD" 2>&1)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    decision=crash
    malformed=$((malformed + 1))
  elif [ -z "$out" ]; then
    decision=allow
  else
    decision=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
    case $decision in
    deny | escalate | allow) ;;
    *)
      decision=undecided
      undecided=$((undecided + 1))
      ;;
    esac
  fi
  printf '{"decision":"%s","payload":%s}\n' "$decision" "$payload" >>"$work/verdicts.jsonl"
done <"$work/payloads.json"

# Shared by the reports below: the command text, flattened to one line.
oneline='(.payload.tool_input.command // "") | gsub("\n"; " ⏎ ") | .[0:110]'

# ── L1 totality ──────────────────────────────────────────────────────────────
if [ "$malformed" -eq 0 ] && [ "$undecided" -eq 0 ]; then
  pass "L1 totality — all $total payloads produced exactly one decision"
else
  fail "L1 totality — $malformed crashed, $undecided produced output that named no decision"
  jq -r "select(.decision==\"crash\" or .decision==\"undecided\")
               | \"  \" + .decision + \": \" + ($oneline)" "$work/verdicts.jsonl" | head -5
fi

# ── L3 non-interference ──────────────────────────────────────────────────────
# Anything that never mentions the trigger must come back untouched.
# $t is a jq variable bound by --arg below, so the shell must NOT expand it.
# shellcheck disable=SC2016
offtrigger='(.payload.tool_input.command // "") | contains($t) | not'
offtrigger_total=$(jq -s --arg t "$TRIGGER" "[.[] | select($offtrigger)] | length" "$work/verdicts.jsonl")
offtrigger_denied=$(jq -s --arg t "$TRIGGER" \
  "[.[] | select($offtrigger) | select(.decision != \"allow\")] | length" "$work/verdicts.jsonl")
if [ "$offtrigger_denied" -eq 0 ]; then
  pass "L3 non-interference — $offtrigger_total commands outside the trigger, all allowed"
else
  fail "L3 non-interference — $offtrigger_denied commands outside the trigger were not allowed"
  jq -r --arg t "$TRIGGER" "select($offtrigger) | select(.decision != \"allow\")
               | \"  \" + .decision + \": \" + ($oneline)" "$work/verdicts.jsonl" | head -5
fi

# ── L2 no self-block ─────────────────────────────────────────────────────────
# The routes the deny message names, run against a spill path. Each must be
# allowed, or the guard walls off the very thing it just told you to do.
spill="$HOME/.claude/projects/-etc-nixos/SESSION/tool-results/abc123.txt"
probe() {
  local label=$1 cmd=$2 want=$3 out decision
  out=$(jq -nc --arg c "$cmd" '{cwd:"/etc/nixos", tool_input:{command:$c}}' | "$GUARD" 2>&1)
  if [ -z "$out" ]; then decision=allow; else
    decision=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "undecided"' 2>/dev/null)
  fi
  if [ "$decision" = "$want" ]; then
    pass "L2 $label → $decision"
  else
    fail "L2 $label → $decision (wanted $want)"
  fi
}
note "L2 — the exits the deny message names:"
probe "route 1, grep the spill file" "grep -n 'anchor' $spill" allow
probe "route 1, rg the spill file" "rg 'anchor' $spill" allow
probe "route 1, grep piped to head" "grep -n 'anchor' $spill | head -20" allow
# $f belongs to the command text being judged, not to this script — it must stay
# literal, which is the whole point of the probe.
# shellcheck disable=SC2016
probe "route 2, re-run the original smaller" 'for f in a.md b.md; do cat $f; done' allow
probe "unopinionated, rm a spill file" "rm $spill" allow
probe "unopinionated, wc a spill file" "wc -l $spill" allow
note "L2 — the shape the guard exists to refuse:"
probe "sed range over a spill file" "sed -n '1,400p' $spill" deny
probe "cat a spill file" "cat $spill" deny
probe "cat at position 0, no leading space" "cat $spill | tail -5" deny

# ── report the deny set ──────────────────────────────────────────────────────
denied=$(jq -s '[.[] | select(.decision=="deny")] | length' "$work/verdicts.jsonl")
note ""
note "deny set over the historical corpus: $denied of $total"
jq -r "select(.decision==\"deny\") | \"  \" + ($oneline)" "$work/verdicts.jsonl" | sort -u

if [ "$red" -eq 0 ]; then
  note ""
  note "all laws hold."
else
  note ""
  note "at least one law failed."
fi
exit "$red"
