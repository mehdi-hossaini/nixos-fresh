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
NIX_SOURCES=(/etc/nixos/modules/nixos/packages.nix /etc/nixos/modules/home/default.nix)
SETTINGS=${SETTINGS:-$HOME/.claude/settings.json}
MANAGED=${MANAGED:-/etc/claude-code/managed-settings.json}
IMPERMANENCE=${IMPERMANENCE:-/etc/nixos/modules/nixos/impermanence.nix}
REPO=${REPO:-/etc/nixos}
SKILLS=${SKILLS:-$HOME/.claude/skills}
# Files this repo declares into ~/.claude. Each must end up a nix-store symlink;
# a plain file there means someone edited the copy instead of the source.
DECLARED=("$HOME/.claude/CLAUDE.md" "$HOME/.claude/check-conventions.sh")
# Law 5. The whole harness lives in these two paths and survives a reboot only
# because impermanence.nix names them. Drop either and the machine comes back
# without its rules or without its Claude state — with no warning until then.
PERSISTED=("/etc/nixos" ".claude")

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
# modules/nixos/claude.nix maps this field to Bash deny patterns, so a malformed
# entry does not produce a bad rule — it produces no rule, and the wall it was
# meant to build is silently missing.
if jq -e '[.tools[] | select(has("agent_unsafe")) | select((.agent_unsafe | type) != "array" or (.agent_unsafe | length) == 0 or any(.agent_unsafe[]; type != "string"))] | length == 0' \
  "$INVENTORY" >/dev/null; then
  ok "every tools[].agent_unsafe is a non-empty array of strings where present"
else
  bad "a tools[].agent_unsafe is malformed — claude.nix would build no deny rule from it"
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
orphans=()
while read -r p; do
  grep -qw -- "$p" "${NIX_SOURCES[@]}" 2>/dev/null || orphans+=("$p")
done < <(jq -r '.tools[] | select(.package != null) | .package' "$INVENTORY" | sort -u)
if [ ${#orphans[@]} -eq 0 ]; then
  ok "every declared package appears in packages.nix or home/default.nix"
else
  for p in "${orphans[@]}"; do
    bad "package '$p' is advertised in tools.json but declared in neither nix file"
  done
fi

# ── traps that a rule in CLAUDE.md depends on staying true ────────────────────
head_ "Traps"
sg_path=$(command -v sg 2>/dev/null || true)
if [ -z "$sg_path" ]; then
  bad "sg resolves to nothing — the 'never call ast-grep as sg' warning is stale"
elif [ "$sg_path" = "$(command -v ast-grep 2>/dev/null || true)" ]; then
  bad "sg now IS ast-grep — the warning in CLAUDE.md is inverted"
else
  ok "sg is $sg_path, not ast-grep (warning still warranted)"
fi

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
*--wait* | *code*) blocking_editor=yes ;;
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
note "jj split/diffedit/resolve use the DIFF editor (builtin TUI) — still agent-unsafe regardless"

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
  undenied=()
  while read -r c; do
    [ -n "$c" ] || continue
    jq -e --arg r "Bash($c *)" '(.permissions.deny // []) | index($r)' "$MANAGED" >/dev/null ||
      undenied+=("$c")
  done < <(jq -r '[.tools[] | .agent_unsafe // empty | .[]] | unique[]' "$INVENTORY")
  if [ ${#undenied[@]} -eq 0 ]; then
    n=$(jq -r '[.tools[] | .agent_unsafe // empty | .[]] | unique | length' "$INVENTORY")
    ok "all $n agent_unsafe commands are denied in the active managed settings"
  else
    for c in "${undenied[@]}"; do
      bad "tools.json marks '$c' agent_unsafe but no Bash($c *) deny is active — run 'nh os switch /etc/nixos' if the config already has it"
    done
  fi
else
  bad "$MANAGED missing — the env guard and the nh hook are not declared"
fi

# Skills are rules, so law 4 applies to them too. A global one is declared in this repo
# and lands here as a store symlink; a project one belongs in that project's own
# .claude/skills/, committed there. Neither route leaves a hand-written file in this
# directory, so anything not resolving into the store is state pretending to be a rule.
if [ ! -d "$SKILLS" ]; then
  ok "no $SKILLS directory — nothing hand-written to drift"
else
  handwritten=()
  while read -r f; do
    [[ "$(readlink -f "$f")" == /nix/store/* ]] || handwritten+=("$f")
  done < <(fd -H -I -t f -t l . "$SKILLS" 2>/dev/null)
  n=$(fd -H -I -t f -t l . "$SKILLS" 2>/dev/null | wc -l)
  if [ ${#handwritten[@]} -ne 0 ]; then
    for f in "${handwritten[@]}"; do
      bad "$f is hand-written — a global skill goes in /etc/nixos/claude/skills/, a project one in that project's repo"
    done
  elif [ "$n" -eq 0 ]; then
    ok "$SKILLS is empty"
  else
    ok "all $n files under $SKILLS resolve into the store"
  fi
fi

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
