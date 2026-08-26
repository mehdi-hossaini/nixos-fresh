#!/usr/bin/env bash
# Verifies the factual claims that ~/.claude/CLAUDE.md rests on.
#
# The tool lists are NOT written here — they are derived from /etc/nixos/tools.json,
# which is itself cross-checked against the nix files it claims to summarise. Adding a
# package to the inventory extends this test automatically; that is the point.
#
#   bash ~/.claude/check-conventions.sh
#
# Exit 0 = every claim holds. Exit 1 = at least one rule or inventory entry is now wrong.

set -u

# Overridable so the check can be mutation-tested against a doctored copy:
#   INVENTORY=/tmp/broken.json bash check-conventions.sh   # must go red
INVENTORY=${INVENTORY:-/etc/nixos/tools.json}
# The nix files the inventory summarises. DISCOVERED, not listed, for the same
# reason GUARDS is below — and this one had already started to rot. It was the
# hard-coded pair (packages.nix, home/default.nix) up to the moment winboat.nix
# added a SECOND environment.systemPackages: a package declared there would have
# been reported as declared in neither nix file, which is a true-looking failure
# about a file the check had simply never been told about. Anything under modules
# that declares a package or a program is a source by definition.
# Space-separated, so the NIX_SOURCES= override still takes one path or many.
if [ -n "${NIX_SOURCES:-}" ]; then
  read -r -a NIX_SOURCES <<<"$NIX_SOURCES"
else
  mapfile -t NIX_SOURCES < <(
    grep -rlE 'environment\.systemPackages|home\.packages|programs\.[a-z]' \
      /etc/nixos/modules --include='*.nix' 2>/dev/null | sort
  )
fi
SETTINGS=${SETTINGS:-$HOME/.claude/settings.json}
MANAGED=${MANAGED:-/etc/claude-code/managed-settings.json}
IMPERMANENCE=${IMPERMANENCE:-/etc/nixos/modules/nixos/impermanence.nix}
REPO=${REPO:-/etc/nixos}
# Both agents' skills directories. ponytail is linked into each under the same rule,
# and a check covering only the first would assert less than the prose claims — the
# same way GUARDS did after the guards were factored out.
read -r -a SKILLS <<<"${SKILLS:-$HOME/.claude/skills $HOME/.codex/skills}"
# Every file that declares a guard, not just claude.nix. The citations moved when
# the guards were factored into agent-guards.nix and codex.nix was added, and a
# check still scanning one file would have gone on passing while silently
# asserting less — which is the failure this check exists to catch, turned on
# itself. Space-separated, so the GUARDS= override still takes one path or many.
# DISCOVERED, not listed. A hard-coded list went stale twice in one day: it named
# only claude.nix after the guards moved to agent-guards.nix, and then omitted
# agent-denies.nix on the very commit that fixed the first omission. Both times the
# check kept passing while asserting less, which is the failure it exists to catch.
# Anything under modules/nixos that cites a law is a guard file by definition.
if [ -n "${GUARDS:-}" ]; then
  read -r -a GUARDS <<<"$GUARDS"
else
  mapfile -t GUARDS < <(grep -rliE 'law [0-9]+' /etc/nixos/modules/nixos --include='*.nix' 2>/dev/null | sort)
fi
# Files this repo declares into ~/.claude. Each must end up a nix-store symlink;
# a plain file there means someone edited the copy instead of the source.
DECLARED=("$HOME/.claude/CLAUDE.md" "$HOME/.claude/check-conventions.sh" "$HOME/.codex/AGENTS.md")
# Law 5. The whole harness lives in these two paths and survives a reboot only
# because impermanence.nix names them. Drop either and the machine comes back
# without its rules or without its Claude state — with no warning until then.
PERSISTED=("/etc/nixos" ".claude" ".codex")

pass=0
fail=0
ok() {
  printf '  \033[32mok\033[0m   %s\n' "$1"
  pass=$((pass + 1))
}
bad() {
  printf '  \033[31mFAIL\033[0m %s\n' "$1"
  fail=$((fail + 1))
}
note() { printf '  \033[2mnote\033[0m %s\n' "$1"; }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# ── the inventory must be readable before anything can be derived from it ──────
head_ "Inventory"
if [ ! -f "$INVENTORY" ]; then
  bad "$INVENTORY missing — CLAUDE.md sends agents there first, and this check derives from it"
  printf '\n%d ok, %d failed\n' "$pass" "$fail"
  exit 1
fi
if ! jq -e . "$INVENTORY" >/dev/null 2>&1; then
  bad "$INVENTORY is not valid JSON — nothing below can be derived"
  printf '\n%d ok, %d failed\n' "$pass" "$fail"
  exit 1
fi
ok "$INVENTORY exists and parses"

# ── schema contracts the derivation depends on ────────────────────────────────
if jq -e '[.not_installed[] | select((.names | type) != "array" or (.names | length) == 0)] | length == 0' \
  "$INVENTORY" >/dev/null; then
  ok "every not_installed entry has a non-empty names array"
else
  bad "some not_installed entry is missing names[] — see \$schema_notes in $INVENTORY"
fi
if jq -e '[.not_installed[] | select(has("name"))] | length == 0' "$INVENTORY" >/dev/null; then
  ok "no legacy .name survives in not_installed (single source, cannot drift)"
else
  bad "a not_installed entry still carries .name alongside .names — two copies of one fact"
fi
if jq -e '[.tools[] | select(has("commands") and (.commands | type) != "array")] | length == 0' \
  "$INVENTORY" >/dev/null; then
  ok "every tools[].commands is an array where present"
else
  bad "a tools[].commands is not an array"
fi
# Each entry is {command, forms}: a bad `forms` is the dangerous case, because an
# unrecognised value matches neither branch of the generator and silently emits no
# pattern at all — the same "no rule rather than a bad rule" failure this block has
# always guarded, one field deeper.
if jq -e '[.tools[] | select(has("agent_unsafe"))
           | select((.agent_unsafe | type) != "array"
                    or (.agent_unsafe | length) == 0
                    or any(.agent_unsafe[];
                           type != "object"
                           or (.command | type) != "string"
                           or (.command | length) == 0
                           or ((.forms // "") | IN("all", "bare") | not)))] | length == 0' \
  "$INVENTORY" >/dev/null; then
  ok "every tools[].agent_unsafe entry is {command, forms: all|bare}"
else
  bad "a tools[].agent_unsafe entry is malformed — the generator would build no deny rule from it"
fi

# Law 6 is about how to work, so most of it cannot be asserted — but the inventory's jj
# note makes four claims about jj's own configuration, and every one is a command away.
#
# This block used to compare the "0.44" in that note against `jj --version`, on the
# theory that an upgrade might leave the claims describing an older jj. It went red on
# every upgrade instead, whether or not anything it described had moved — and a check
# that cries wolf is a check that gets muted, which would have hidden a real drift
# behind an expected one. Asserting the claims themselves fires only when one of them
# stops being true, which is the thing the note actually promises. The note is the
# prose; this is its test. Change one and change the other.
schema=$(jj util config-schema 2>/dev/null)
if [ -z "$schema" ]; then
  bad "jj util config-schema returned nothing — the inventory's jj claims cannot be checked"
else
  default_cmd=$(jj config get ui.default-command 2>/dev/null)
  if [ "$default_cmd" = log ]; then
    ok "bare jj runs log (ui.default-command)"
  else
    bad "ui.default-command is '${default_cmd:-unset}', not 'log' — the inventory says bare jj shows the log"
  fi
  for k in colocate track-default-bookmark-on-clone; do
    if jq -e --arg k "$k" '.properties.git.properties[$k].default == true' <<<"$schema" >/dev/null; then
      ok "git.$k still defaults to true"
    else
      bad "git.$k no longer defaults to true — rewrite jj's note in $INVENTORY"
    fi
  done
  if jq -e '.properties.git.properties | has("auto-local-bookmark") | not' <<<"$schema" >/dev/null; then
    ok "git.auto-local-bookmark is still absent"
  else
    bad "git.auto-local-bookmark exists again — jj's note in $INVENTORY says it does not"
  fi
fi

# ── derived: what the inventory says is on PATH ────────────────────────────────
head_ "Commands the inventory promises"
missing=()
while read -r c; do
  command -v "$c" >/dev/null 2>&1 || missing+=("$c")
done < <(jq -r '[.tools[] | (.commands // [.name])[]] | unique[]' "$INVENTORY")
if [ ${#missing[@]} -eq 0 ]; then
  n=$(jq -r '[.tools[] | (.commands // [.name])[]] | unique | length' "$INVENTORY")
  ok "all $n promised commands resolve"
else
  for c in "${missing[@]}"; do bad "$c is promised by tools.json but not on PATH"; done
fi

# ── derived: what the inventory says is deliberately absent ────────────────────
head_ "Absences the inventory declares deliberate"
present=()
while read -r c; do
  command -v "$c" >/dev/null 2>&1 && present+=("$c")
done < <(jq -r '[.not_installed[].names[]] | unique[]' "$INVENTORY")
if [ ${#present[@]} -eq 0 ]; then
  n=$(jq -r '[.not_installed[].names[]] | unique | length' "$INVENTORY")
  ok "all $n declared absences hold"
else
  for c in "${present[@]}"; do
    bad "$c is PRESENT at $(command -v "$c") — tools.json calls it deliberately absent"
  done
fi

# ── the hop nobody else checks: inventory vs. its own stated source of truth ───
head_ "Inventory vs. the nix files it summarises"
# Comments are stripped before the word-search, because discovery widened
# NIX_SOURCES to files whose comments name packages freely — "winboat" appears
# in prose all over the tree, and a package removed from its list but still
# discussed above it would have counted as declared. A name only survives this
# grep if it exists in code.
orphans=()
stripped=$(sed 's/#.*//' "${NIX_SOURCES[@]}" 2>/dev/null)
while read -r p; do
  grep -qw -- "$p" <<<"$stripped" || orphans+=("$p")
done < <(jq -r '.tools[] | select(.package != null) | .package' "$INVENTORY" | sort -u)
if [ ${#orphans[@]} -eq 0 ]; then
  ok "every advertised package appears in one of the ${#NIX_SOURCES[@]} nix files that declare packages"
else
  for p in "${orphans[@]}"; do
    bad "package '$p' is advertised in tools.json but declared in no nix file under modules/"
  done
fi

# The other direction, which nothing checked until now. The walk above only proves
# the inventory does not advertise a package that is gone; it says nothing about a
# package that is DECLARED and missing from the inventory. That asymmetry matters
# because law 2 sends every agent to the inventory first, so a tool with no entry
# does not read as an oversight — it reads as a deliberate absence. winboat was
# exactly that for a while: installed, on PATH, and invisible here.
#
# environment.systemPackages only, and the message says so. Those lists are bare
# nixpkgs attribute names, so the comparison is exact. The home side declares tools
# as programs.<name>.enable, whose name is a home-manager module rather than a
# nixpkgs attribute — plasma-manager's programs.plasma is not a tool and has no
# entry to find — so covering it would need an exemption list, which is the shape
# this whole section is trying to get rid of.
# An .override argument set is not a package list. The flat tokeniser this
# started as read commandLineArgs as a package, and worse, the `];` closing the
# override's own list ended the scan — every package below it silently stopped
# being checked while the line still printed ok. Track brace depth: emit at
# depth 0, end the list only on a `];` seen there.
declared=$(awk '
  /^[[:space:]]*environment\.systemPackages[[:space:]]*=/ { inlist = 1 }
  inlist {
    line = $0
    sub(/#.*/, "", line)
    sub(/.*environment\.systemPackages[[:space:]]*=/, "", line)
    gsub(/with[[:space:]]+pkgs[[:space:]]*;/, "", line)
    gsub(/pkgs\./, "", line)
    gsub(/[][;]/, " ", line)
    gsub(/[{}]/, " & ", line)
    gsub(/[()]/, " ", line)
    gsub(/\.override(Attrs)?/, "", line)
    n = split(line, a, /[[:space:]]+/)
    for (i = 1; i <= n; i++) {
      if (a[i] == "{") { depth++; continue }
      if (a[i] == "}") { if (depth > 0) depth--; continue }
      if (depth == 0 && a[i] ~ /^[A-Za-z][A-Za-z0-9_-]*$/) print a[i]
    }
    if (depth == 0 && $0 ~ /\];/) inlist = 0
  }
' "${NIX_SOURCES[@]}" 2>/dev/null | sort -u)
mapfile -t uninventoried < <(
  comm -23 <(printf '%s\n' "$declared") \
    <(jq -r '.tools[].package | select(. != null)' "$INVENTORY" | sort -u)
)
if [ -z "$declared" ]; then
  bad "no environment.systemPackages entry could be read out of ${#NIX_SOURCES[@]} nix source(s) — the reverse check is asserting nothing"
elif [ ${#uninventoried[@]} -eq 0 ]; then
  n=$(printf '%s\n' "$declared" | grep -c .)
  ok "all $n packages in environment.systemPackages have an inventory entry"
else
  for p in "${uninventoried[@]}"; do
    bad "'$p' is in environment.systemPackages but has no tools.json entry — law 2 reads a missing entry as a deliberate absence"
  done
fi

# ── the machine block: facts an agent plans builds around ─────────────────────
# hostname, arch, cpu_threads and ram_gb duplicate what machine.nix and the
# hardware already know, which is the shape that drifts: each was copied in by
# hand and nothing compared any of them against the machine, so a RAM upgrade or
# a rename would leave an agent sizing builds from the old numbers. Every one is
# one command away (law 6). ram_gb follows machine.nix's own definition — what
# `free -g` prints as total.
head_ "Machine block"
mfact() {
  want=$(jq -r ".machine.$1" "$INVENTORY")
  if [ "$want" = "$2" ]; then
    ok "machine.$1 ($want) matches the machine"
  else
    bad "machine.$1 says '$want' but the machine says '$2' — an agent reading the inventory plans around the wrong number"
  fi
}
mfact hostname "$(hostname)"
mfact cpu_threads "$(nproc)"
mfact ram_gb "$(free -g | awk 'NR==2{print $2}')"
mfact arch "$(uname -m)-linux"

# ── traps that a rule in CLAUDE.md depends on staying true ────────────────────
head_ "Traps"

# the passwd entry and the PATH lookup are different symlinks to the same fish
login_shell=$(getent passwd "$USER" | cut -d: -f7)
if [ "$(basename "$login_shell")" = fish ]; then
  ok "login shell is fish (write scripts for bash, run with 'bash script.sh')"
else
  bad "login shell is $login_shell, not fish — the shell section is stale"
fi

# ── the GUI hang must be unreachable, not merely discouraged ──────────────────
head_ "Editor guard"
jj_ui_editor=$(jj config get ui.editor 2>/dev/null || true)
case "$jj_ui_editor" in
*--wait* | *code* | *vim* | *vi) blocking_editor=yes ;;
*) blocking_editor=no ;;
esac
# the guard may come from managed settings (declared, in the repo) or from user
# settings.json (hand-written) — either satisfies it, managed is the declared one
guard_src=""
for f in "$MANAGED" "$SETTINGS"; do
  [ -f "$f" ] || continue
  all=yes
  for v in JJ_EDITOR GIT_EDITOR EDITOR VISUAL; do
    jq -e --arg v "$v" '.env[$v] // empty' "$f" >/dev/null 2>&1 || all=no
  done
  [ "$all" = yes ] && {
    guard_src=$f
    break
  }
done
if [ -n "$guard_src" ]; then
  ok "JJ_EDITOR/GIT_EDITOR/EDITOR/VISUAL pinned for agent sessions (from $guard_src)"
elif [ "$blocking_editor" = yes ]; then
  bad "ui.editor is '$jj_ui_editor' (blocks on a GUI window) and neither $MANAGED nor $SETTINGS pins the editor variables — a forgotten -m will hang an agent shell"
else
  ok "no env guard, but ui.editor ('$jj_ui_editor') does not block"
fi
note "jj's DIFF editor (bare jj split, jj diffedit, jj resolve without --list or --tool mergiraf) is a builtin TUI — still agent-unsafe regardless"

# The other two instances of law 3. Both were found by hitting them, and both are
# assertable, unlike the law itself.
if sudo -n true 2>/dev/null; then
  bad "sudo does not ask for a password — passwordless sudo appeared, so 'activating needs a hand-off' is now stale"
else
  ok "sudo still requires a password, so activation is still a hand-off"
fi
origin_url=$(git -C "$REPO" remote get-url origin 2>/dev/null || true)
case "$origin_url" in
git@* | ssh://*) ok "$REPO pushes over SSH — git's askpass never runs" ;;
"") bad "$REPO has no origin remote" ;;
*) bad "$REPO origin is '$origin_url' — an HTTPS remote makes git call ksshaskpass, which an agent shell cannot answer" ;;
esac

# ── a mechanism and the rule it implements must stay connected ────────────────
# Guards cite the law they serve, in the comment and in the deny message the agent
# reads: "law 1: nothing is installed imperatively…", "(law 3)". That citation is
# the only thread from a mechanism back to the rule it enforces — nothing else
# links prose to the hook implementing a slice of it, so renumbering or retiring a
# law leaves the citations pointing at nothing while still looking authoritative.
head_ "Law citations"
missing_guards=()
for g in "${GUARDS[@]}"; do
  [ -f "$g" ] || missing_guards+=("$g")
done
nlaws=$(grep -cE '^[0-9]+\. \*\*' "$HOME/.claude/CLAUDE.md")
if [ "$nlaws" -eq 0 ]; then
  bad "no numbered laws found in $HOME/.claude/CLAUDE.md — every citation in ${GUARDS[*]} points at nothing"
elif [ ${#missing_guards[@]} -gt 0 ]; then
  for g in "${missing_guards[@]}"; do
    bad "$g missing — the guards it declares are what the citations live in"
  done
else
  dangling=()
  cited=0
  while read -r n; do
    cited=$((cited + 1))
    { [ "$n" -ge 1 ] && [ "$n" -le "$nlaws" ]; } || dangling+=("$n")
  done < <(grep -hoiE 'law [0-9]+' "${GUARDS[@]}" | grep -oE '[0-9]+' | sort -un)
  if [ ${#dangling[@]} -eq 0 ]; then
    ok "all $cited laws cited by a guard exist among the $nlaws in CLAUDE.md"
  else
    for d in "${dangling[@]}"; do
      bad "a guard in ${GUARDS[*]} cites 'law $d', but CLAUDE.md declares only $nlaws laws"
    done
  fi
fi

# ── law 5: the harness only survives a reboot because these are declared ──────
head_ "Persistence"
if [ ! -f "$IMPERMANENCE" ]; then
  bad "$IMPERMANENCE missing — nothing declares what survives a reboot"
else
  for p in "${PERSISTED[@]}"; do
    if grep -qF "\"$p\"" "$IMPERMANENCE"; then
      ok "$p is declared persistent"
    else
      bad "$p is NOT in $IMPERMANENCE — it will be gone after the next reboot, silently"
    fi
  done
fi

# ── law 7: the repo is public, and the store is readable by everyone anyway ────
# Two separate leaks with one shape, so one scan covers both. The path is read out of
# machine.nix rather than written here — change the option and this follows it.
head_ "Secrets"
MACHINE=${MACHINE:-$REPO/modules/nixos/machine.nix}
secrets_dir=$(sed -n '/secretsDir = lib.mkOption/,/^    };/p' "$MACHINE" 2>/dev/null |
  sed -n 's/.*default = "\(.*\)";.*/\1/p' | head -1)
if [ -z "$secrets_dir" ]; then
  bad "cannot read machine.secretsDir out of $MACHINE — the rest of this section has nothing to check"
else
  case "$secrets_dir" in
  "$REPO"/*) bad "secretsDir is $secrets_dir, inside the repo — it would be committed and published" ;;
  *) ok "secretsDir ($secrets_dir) is outside $REPO" ;;
  esac
  if [ ! -d "$secrets_dir" ]; then
    bad "$secrets_dir does not exist — activation reads the password hash from there and fails without it"
  else
    perm=$(stat -c '%a %U' "$secrets_dir")
    if [ "$perm" = "700 root" ]; then
      ok "$secrets_dir is 0700 root — unreadable by this user, unlike anything in the store"
    else
      bad "$secrets_dir is '$perm', not '700 root' — the one place secrets are allowed is not protecting them"
    fi
  fi
fi

# Content, not location. A secret pasted into a nix file is public twice over: pushed to
# a public remote, and copied world-readable into /nix/store on every build. flake.lock is
# excluded because its narHashes match nothing here but are noise worth not re-reading.
# shellcheck disable=SC2016  # the $ and $( here are regex, not expansion — single quotes are exactly right
leak_re='(BEGIN [A-Z ]*PRIVATE KEY|AGE-SECRET-KEY-[01]|\$(6|y|2[aby])\$[./A-Za-z0-9]{8,}|(password|passwd|secret|api[_-]?key|token)[[:space:]]*=[[:space:]]*"[^"]{12,}")'
leaks=$(rg -l -i "$leak_re" -g '!flake.lock' "$REPO" 2>/dev/null)
if [ -z "$leaks" ]; then
  ok "no private key, password hash or long literal secret anywhere in $REPO"
else
  while read -r f; do
    bad "$f looks like it carries secret material — $REPO is a public repo and the store is world-readable"
  done <<<"$leaks"
fi

# ── the rules must be declared, not hand-written copies ───────────────────────
head_ "Declared configuration"
for f in "${DECLARED[@]}"; do
  if [ -L "$f" ] && [[ "$(readlink -f "$f")" == /nix/store/* ]]; then
    ok "$(basename "$f") is a store symlink — reproducible from the repo"
  elif [ -e "$f" ]; then
    bad "$(basename "$f") is a plain file, not a store symlink — edit /etc/nixos/claude/ and rebuild, or the change is lost on reinstall"
  else
    bad "$(basename "$f") is missing entirely"
  fi
done
if [ -f "$MANAGED" ]; then
  ok "managed-settings.json is present (declared via environment.etc)"
  # The last hop of the derivation: tools.json marks a tool agent_unsafe,
  # claude.nix turns that into a deny pattern, and this asserts the pattern
  # reached the ACTIVE file. Red between editing the inventory and switching is
  # correct, not noise — the same property the "promised commands resolve" check
  # already has, and for the same reason.
  # The pattern to look for depends on the form, which is the whole point of the
  # field: "all" promises `Bash(<cmd> *)`, "bare" promises `Bash(<cmd>)` and
  # promises that `Bash(<cmd> *)` is ABSENT. That second half matters more than it
  # looks — a bare entry whose ` *` pattern leaked would deny the scriptable
  # subcommands the entry exists to protect, and it would do so invisibly, since
  # over-denying never fails loudly.
  undenied=()
  while IFS=$'\t' read -r c f; do
    [ -n "$c" ] || continue
    if [ "$f" = bare ]; then
      jq -e --arg r "Bash($c)" '(.permissions.deny // []) | index($r)' "$MANAGED" >/dev/null ||
        undenied+=("$c (bare, missing Bash($c))")
      jq -e --arg r "Bash($c *)" '(.permissions.deny // []) | index($r)' "$MANAGED" >/dev/null &&
        undenied+=("$c (bare, but Bash($c *) leaked and denies its subcommands)")
    else
      jq -e --arg r "Bash($c *)" '(.permissions.deny // []) | index($r)' "$MANAGED" >/dev/null ||
        undenied+=("$c (all, missing Bash($c *))")
    fi
  done < <(jq -r '[.tools[] | .agent_unsafe // empty | .[]] | unique[] | "\(.command)\t\(.forms)"' "$INVENTORY")
  if [ ${#undenied[@]} -eq 0 ]; then
    n=$(jq -r '[.tools[] | .agent_unsafe // empty | .[]] | unique | length' "$INVENTORY")
    ok "all $n agent_unsafe entries are denied in the active managed settings, in the form they ask for"
  else
    for c in "${undenied[@]}"; do
      bad "agent_unsafe mismatch: $c — run 'nh os switch /etc/nixos' if the config already has it"
    done
  fi
else
  bad "$MANAGED missing — the env guard and the nh hook are not declared"
fi

# ── the guards must speak a vocabulary the harness accepts ────────────────────
# permissionDecision is an enum claude-code validates at the schema layer, and
# output that fails it is downgraded to plain text — no deny, no ask, nothing.
# That failure shipped: every guard answered "could not tell" with "escalate", a
# word no claude-code accepts, so the one answer designed to never be silently
# wrong was exactly that, from the day the guards were written until 2026-08-25.
# The valid set is deliberately NOT written here — it is read out of the
# installed binary's own validation error ("Valid types are: …"), so an upgrade
# that changes the enum moves this check with it instead of leaving it asserting
# a remembered list (law 6). Claude only: Codex's hook layer names no such enum
# to read, and its guards collapse everything undecidable to deny anyway.
if [ -f "$MANAGED" ]; then
  claude_bin=$(readlink -f "$(command -v claude 2>/dev/null)" 2>/dev/null || true)
  vocab=""
  if [ -n "$claude_bin" ]; then
    # The nixpkgs package is a wrapper beside the real binary; scan whichever of
    # the two carries the string. grep for "allow" picks the permissionDecision
    # enum out of the several "Valid types are:" strings the binary holds.
    vocab=$(rg -ao --no-filename --no-line-number 'Valid types are: [a-z, ]+' \
      "$claude_bin" "$(dirname "$claude_bin")/.claude-wrapped" 2>/dev/null |
      grep -m1 'allow' | sed 's/Valid types are: //; s/,/ /g' | tr -s ' ') || true
  fi
  if [ -z "$vocab" ]; then
    bad "cannot read the permissionDecision enum out of the claude binary — the guard-vocabulary check is asserting nothing"
  else
    unknown_words=()
    while read -r w; do
      [ -n "$w" ] || continue
      case " $vocab " in
      *" $w "*) ;;
      *) unknown_words+=("$w") ;;
      esac
    done < <(jq -r '[.hooks[][] | .hooks[]?.command] | unique | .[]' "$MANAGED" 2>/dev/null |
      xargs -r rg -ao --no-filename --no-line-number 'permissionDecision:"[a-z]+"' 2>/dev/null |
      sed 's/.*"\([a-z]*\)"/\1/' | sort -u)
    if [ ${#unknown_words[@]} -eq 0 ]; then
      ok "every decision the hooks emit is in the claude binary's accepted set ($(echo "$vocab" | tr -s ' '))"
    else
      for w in "${unknown_words[@]}"; do
        bad "a hook emits permissionDecision \"$w\", which the claude binary does not list in '$vocab' — the harness downgrades it to plain text and the guard decides nothing"
      done
    fi
  fi
fi

# Skills are rules, so law 4 applies to them too. A global one is declared in this repo
# and lands here as a store symlink; a project one belongs in that project's own
# .claude/skills/, committed there. Neither route leaves a hand-written file in this
# directory, so anything not resolving into the store is state pretending to be a rule.
# .system is excluded because Codex ships its OWN skills into ~/.codex/skills/.system
# — imagegen, skill-creator and four more, written there by the agent rather than by
# anyone here. They are state, not rules, so law 4 puts them on the same side of the
# line as ~/.claude/settings.json. Claude has no equivalent, which is why this
# exclusion only started mattering when the check learned about the second directory.
for skdir in "${SKILLS[@]}"; do
  if [ ! -d "$skdir" ]; then
    ok "no $skdir directory — nothing hand-written to drift"
    continue
  fi
  # The exclusion is scoped to the codex directory, not applied to both. Codex
  # ships its own skills into ~/.codex/skills/.system; Claude has no equivalent, so
  # excluding .system there would only blind the check to a hand-written rule
  # hidden in a dot-directory — a hole this assertion did not previously have.
  ex=()
  case "$skdir" in
  *.codex/skills) ex=(-E .system) ;;
  esac
  handwritten=()
  while read -r f; do
    [[ "$(readlink -f "$f")" == /nix/store/* ]] || handwritten+=("$f")
  done < <(fd -H -I -t f -t l . "$skdir" "${ex[@]}" 2>/dev/null)
  n=$(fd -H -I -t f -t l . "$skdir" "${ex[@]}" 2>/dev/null | wc -l)
  if [ ${#handwritten[@]} -ne 0 ]; then
    for f in "${handwritten[@]}"; do
      bad "$f is hand-written — a global skill goes in /etc/nixos/claude/skills/, a project one in that project's repo"
    done
  elif [ "$n" -eq 0 ]; then
    ok "$skdir is empty"
  else
    ok "all $n files under $skdir resolve into the store"
  fi
done

# ── a project CLAUDE.md narrows; it must not restate this one ────────────────
# A copy cannot be corrected from here, and a stale copy outranks nothing while
# looking authoritative. Found one at 64/104 lines, asserting a jj workflow for a
# directory with no .jj — hence this check.
head_ "Project instruction files"
GLOBAL="$HOME/.claude/CLAUDE.md"
dupes=0
while read -r p; do
  [ "$(readlink -f "$p")" = "$(readlink -f "$GLOBAL")" ] && continue
  case "$p" in *"/.Trash"*) continue ;; esac
  n=$(grep -Fxf "$GLOBAL" "$p" 2>/dev/null | grep -c '[^[:space:]]' || true)
  t=$(grep -c '[^[:space:]]' "$p" 2>/dev/null || echo 1)
  if [ "$n" -gt 10 ]; then
    bad "$p repeats $n/$t lines of the global file — it should narrow, not restate"
    dupes=$((dupes + 1))
  fi
done < <(fd -H -t f '^CLAUDE\.md$' "$HOME" 2>/dev/null)
[ "$dupes" -eq 0 ] && ok "no project CLAUDE.md restates the global one"

printf '\n%d ok, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
