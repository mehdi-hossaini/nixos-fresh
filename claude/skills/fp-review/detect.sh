#!/usr/bin/env bash
# fp-review: find the code sites the FP-in-Scala notes have something to say about.
#
# This is a SURVEY, not a linter. Every hit is a question ("is this partiality
# intended?"), never a verdict, so it always exits 0. The value is narrowing an
# unbounded "review this codebase" to a few dozen line numbers grouped by the
# note that explains what is wrong with them.
#
#   detect.sh [path...]      survey (defaults to src/, else .)
#   detect.sh --self-test    assert every lens still fires against a fixture
set -euo pipefail

# note<TAB>what it means<TAB>extended regex
# Each regex is deliberately narrow: a lens nobody trusts gets ignored, and a
# lens that fires on every line is the same as no lens at all.
LENSES=$(
  cat <<'EOF'
total-function	partial operation — a function that has no answer for some inputs	(\.pop\(\)|\.shift\(\)|\bJSON\.parse\(|\bparseInt\(|\bNumber\()
option-not-null	null or undefined as a return value	(:\s*[A-Za-z<>\[\]]+\s*\|\s*(null|undefined)|return (null|undefined);)
errors-as-values	control flow by throwing instead of returning the failure	(\bthrow new |\} catch)
types-are-contracts	the contract opted out — any, cast, or a suppressed error	(\bas any\b|:\s*any\b|@ts-(ignore|expect-error)|\bas unknown as\b)
make-illegal-states-unrepresentable	non-null assertion — you know it is there, the type does not	[A-Za-z_)\]]!\.
immutability	in-place mutation of a value someone else may hold	(\.push\(|\.splice\(|Object\.assign\(|\.sort\(\)|\bdelete [a-z_$][\w$]*[.\[])
side-effect	an effect reached for directly, mid-computation	(console\.(log|error|warn)|Date\.now\(\)|Math\.random\(\)|process\.env\.)
local-reasoning	module-level mutable state — reading one page is no longer enough	^(export )?let 
EOF
)

targets=()
selftest=0
for a in "$@"; do
  case $a in
  --self-test) selftest=1 ;;
  *) targets+=("$a") ;;
  esac
done

survey() {
  local dirs=("$@") total=0
  printf '\n== fp-review survey: %s ==\n' "${dirs[*]}"
  while IFS=$'\t' read -r note meaning pat; do
    [ -n "${pat:-}" ] || continue
    local hits n
    hits=$(rg --no-heading --line-number --color never \
      --glob '!**/node_modules/**' --glob '!**/dist/**' --glob '!*.d.ts' \
      -e "$pat" "${dirs[@]}" 2>/dev/null || true)
    n=$(printf '%s' "$hits" | grep -c . || true)
    [ "$n" -eq 0 ] && continue
    total=$((total + n))
    printf '\n--- [[%s]] — %s  (%s hits)\n' "$note" "$meaning" "$n"
    printf '%s\n' "$hits" | head -6 | sed 's/^/    /'
    [ "$n" -gt 6 ] && printf '    … %s more\n' "$((n - 6))"
  done <<<"$LENSES"
  printf '\n%s sites to ask about. Read the note before judging any of them.\n' "$total"
}

self_test() {
  local d
  d=$(mktemp -d)
  # One fixture line per lens, in lens order. If a regex rots, its lens goes
  # silent and the survey quietly under-reports — this is what catches that.
  cat >"$d/fixture.ts" <<'EOF'
const a = xs.pop();
function f(): string | null { return null; }
if (bad) { throw new Error("nope"); }
const c = payload as any;
const d = user!.name;
list.push(item);
console.log("hi");
export let cache = {};
EOF
  local missed=0
  while IFS=$'\t' read -r note _ pat; do
    [ -n "${pat:-}" ] || continue
    if rg -q -e "$pat" "$d/fixture.ts"; then
      printf 'ok    %s\n' "$note"
    else
      printf 'FAIL  %s — regex matches nothing in the fixture\n' "$note"
      missed=$((missed + 1))
    fi
  done <<<"$LENSES"
  rm -rf "$d"
  [ "$missed" -eq 0 ] || {
    printf '\n%s lens(es) dead.\n' "$missed" >&2
    exit 1
  }
  printf '\nall lenses fire.\n'
}

if [ "$selftest" -eq 1 ]; then
  self_test
  exit 0
fi

if [ ${#targets[@]} -eq 0 ]; then
  [ -d src ] && targets=(src) || targets=(.)
fi
survey "${targets[@]}"
