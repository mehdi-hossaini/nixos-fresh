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
# Files this repo declares into ~/.claude. Each must end up a nix-store symlink;
# a plain file there means someone edited the copy instead of the source.
DECLARED=("$HOME/.claude/CLAUDE.md" "$HOME/.claude/check-conventions.sh")

pass=0; fail=0
ok()    { printf '  \033[32mok\033[0m   %s\n' "$1"; pass=$((pass+1)); }
bad()   { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }
note()  { printf '  \033[2mnote\033[0m %s\n' "$1"; }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# ── the inventory must be readable before anything can be derived from it ──────
head_ "Inventory"
if [ ! -f "$INVENTORY" ]; then
  bad "$INVENTORY missing — CLAUDE.md sends agents there first, and this check derives from it"
  printf '\n%d ok, %d failed\n' "$pass" "$fail"; exit 1
fi
if ! jq -e . "$INVENTORY" >/dev/null 2>&1; then
  bad "$INVENTORY is not valid JSON — nothing below can be derived"
  printf '\n%d ok, %d failed\n' "$pass" "$fail"; exit 1
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
  *--wait*|*code*) blocking_editor=yes ;;
  *)               blocking_editor=no  ;;
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
  [ "$all" = yes ] && { guard_src=$f; break; }
done
if [ -n "$guard_src" ]; then
  ok "JJ_EDITOR/GIT_EDITOR/EDITOR/VISUAL pinned for agent sessions (from $guard_src)"
elif [ "$blocking_editor" = yes ]; then
  bad "ui.editor is '$jj_ui_editor' (blocks on a GUI window) and neither $MANAGED nor $SETTINGS pins the editor variables — a forgotten -m will hang an agent shell"
else
  ok "no env guard, but ui.editor ('$jj_ui_editor') does not block"
fi
note "jj split/diffedit/resolve use the DIFF editor (builtin TUI) — still agent-unsafe regardless"

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
else
  bad "$MANAGED missing — the env guard and the nh hook are not declared"
fi

printf '\n%d ok, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
