#!/usr/bin/env bash
# fp-review — survey a codebase for the sites where the types stop telling the truth.
#
# A SURVEY, NOT A LINTER. Every hit is a question ("is this partiality intended?"),
# never a verdict, so it always exits 0 and is safe in CI without gating anything.
# The value is narrowing an unbounded "review this codebase" down to a few dozen
# line numbers grouped by the question they raise.
#
# LANGUAGE-AGNOSTIC BY UNION, NOT BY DISPATCH. One regex per lens, alternating over
# each language's spelling of the same idea — throw / raise / panic! / rescue are
# one question, not five. There is no per-language table to keep in sync, and a
# language nobody anticipated still matches whatever idiom it shares with the
# others. The cost is that a pattern must be unambiguous ACROSS languages: `let` is
# mutable in JavaScript and immutable in Rust, so it is anchored to module level,
# which is precisely where Rust cannot spell it. Every such trap is pinned by
# --self-test, which fails a lens that stops carrying to at least three languages.
#
# Usage:
#   ./detect.sh [path|file ...]   survey (default: src/ if it exists, else .)
#   ./detect.sh --with-tests      include test files (excluded by default)
#   ./detect.sh --self-test       verify every lens still fires in every language
#
# Requires ripgrep (rg), or GNU grep as a fallback.
set -euo pipefail

# name<TAB>the question to ask at each hit<TAB>extended regex
#
# Narrow beats complete. A lens that fires on every line is the same as no lens,
# and a lens nobody trusts gets ignored — so each pattern is deliberately partial,
# picking idioms that are strong evidence rather than every possible spelling.
LENSES=$(
  cat <<'EOF'
total-function	partial operation — no answer for some inputs	(\.pop\(\)|\.shift\(\)|\.unwrap\(\)|\.expect\(|JSON\.parse\(|\bparseInt\(|\bNumber\(|\bint\(|\bfloat\(|strconv\.Ato|Integer\.parse|\.popitem\(|\.fetchone\()
option-not-null	absence as a hole in the floor, not a box you must open	(\|\s*(null|undefined)\b|\breturn (null|nil|None)\b|\bis None\b|\?\s*:|Nullable<|= (None|nil|null)\b)
errors-as-values	failure travelling invisibly instead of in the signature	(\bthrow new |\braise \b|\bpanic\(|panic!\(|\} catch|\bcatch \(|\bexcept [A-Z]|\brescue\b|if err != nil)
types-are-contracts	the contract opted out of — a cast, an escape hatch, a suppression	(\bas any\b|:\s*any\b|@ts-(ignore|expect-error)|\bas unknown as\b|#\s*type:\s*ignore|:\s*Any\b|interface\{\}|\bunsafe\b|\(Object\)|@SuppressWarnings|\breflect\.|getattr\()
make-illegal-states-unrepresentable	you know something the type does not	([A-Za-z_)\]]!\.|\bassert\b|assert!\(|\bassert_|Optional\.get\(\)|\bas!\s|!!)
immutability	in-place mutation of a value someone else may hold	(\.push\(|\.append\(|\.splice\(|\.extend\(|Object\.assign\(|\.sort\(\)|\.sort_by|&mut |\bmut [a-z_]|\bdelete [a-z_$][A-Za-z0-9_$]*[.\[]|\.insert\(|\.setdefault\()
side-effect	an effect performed mid-computation instead of described	(console\.(log|error|warn)|System\.out\.|\bprintln!?\(|\bprint\(|\bputs \b|fmt\.Print|Date\.now\(\)|time\.Now\(\)|datetime\.now\(|Math\.random\(\)|\brandom\.|rand::|process\.env\.|os\.environ|std::env::var|System\.getenv)
local-reasoning	module-level mutable state — one page is no longer enough	(^(export )?let |^(export )?var |^\s*static mut |^\s*global [a-z_]|lazy_static!|^[A-Z][A-Z_]+ = )
EOF
)

# Build artefacts and vendored code, which nobody is reviewing.
PRUNE_DIRS="fp-review node_modules dist build target vendor .venv venv .git __pycache__ .next coverage"
# Test files are excluded by DEFAULT, and this is the single most important
# calibration in the script. Assertions, thrown errors and mutation are correct
# usage in a test — including tests roughly doubles the assertion lens on a
# typical repo and buries the production sites the review is actually about.
PRUNE_TESTS="test tests spec __tests__ e2e benches"

targets=()
selftest=0
with_tests=0
for a in "$@"; do
  case $a in
  --self-test) selftest=1 ;;
  --with-tests) with_tests=1 ;;
  -h | --help)
    sed -n '2,20p' "$0"
    exit 0
    ;;
  *) targets+=("$a") ;;
  esac
done

# One search function, chosen once. ripgrep is preferred (fast, honours
# .gitignore); GNU grep is the fallback so the skill still runs on a machine where
# installing anything is not on the table.
if command -v rg >/dev/null 2>&1; then
  ENGINE=ripgrep
  excl=()
  for d in $PRUNE_DIRS; do excl+=(--glob "!**/$d/**"); done
  if [ "$with_tests" -eq 0 ]; then
    for d in $PRUNE_TESTS; do excl+=(--glob "!**/$d/**"); done
    excl+=(--glob '!**/*[._-]test.*' --glob '!**/test_*' --glob '!**/*[._-]spec.*')
  fi
  excl+=(--glob '!*.d.ts' --glob '!*.min.*' --glob '!*.lock')
  scan() {
    local pat=$1
    shift
    rg --no-heading --line-number --color never "${excl[@]}" -e "$pat" "$@" 2>/dev/null || true
  }
elif grep --version 2>/dev/null | grep -q GNU; then
  ENGINE="GNU grep"
  excl=()
  for d in $PRUNE_DIRS; do excl+=(--exclude-dir="$d"); done
  if [ "$with_tests" -eq 0 ]; then
    for d in $PRUNE_TESTS; do excl+=(--exclude-dir="$d"); done
    excl+=(--exclude='*[._-]test.*' --exclude='test_*' --exclude='*[._-]spec.*')
  fi
  excl+=(--exclude='*.d.ts' --exclude='*.min.*' --exclude='*.lock')
  scan() {
    local pat=$1
    shift
    grep -rEn "${excl[@]}" -e "$pat" "$@" 2>/dev/null || true
  }
else
  echo "fp-review needs ripgrep (preferred) or GNU grep on PATH." >&2
  exit 1
fi

survey() {
  local total=0 note meaning pat hits n
  printf '\n== fp-review: %s  (%s' "$*" "$ENGINE"
  [ "$with_tests" -eq 1 ] && printf ', tests included'
  printf ') ==\n'
  while IFS=$'\t' read -r note meaning pat; do
    [ -n "${pat:-}" ] || continue
    hits=$(scan "$pat" "$@")
    n=$(printf '%s' "$hits" | grep -c . || true)
    [ "$n" -eq 0 ] && continue
    total=$((total + n))
    printf '\n--- %s — %s  (%s)\n' "$note" "$meaning" "$n"
    printf '%s\n' "$hits" | head -6 | sed 's/^/    /'
    [ "$n" -gt 6 ] && printf '    ... %s more\n' "$((n - 6))"
  done <<<"$LENSES"
  printf '\n%s sites to ask about. Read the code before judging any of them.\n' "$total"
}

# One fixture per language, each line that language's spelling of one lens.
# A lens that quietly stops matching a language produces a smaller survey, not an
# error — nothing else in this script would notice. Requiring every lens to carry
# to three or more languages is what keeps a single-language regex from being
# readmitted as if it were universal.
self_test() {
  local d
  d=$(mktemp -d)
  cat >"$d/f.ts" <<'EOF'
const a = xs.pop();
function f(): string | null { return null; }
if (bad) { throw new Error("nope"); }
const c = payload as any;
const d = user!.name;
list.push(item);
console.log("hi");
export let cache = {};
EOF
  cat >"$d/f.py" <<'EOF'
n = int(raw)
def f(): return None
except ValueError:
def g(x: Any): pass
assert x is not None
items.append(x)
print("hi")
global cache
EOF
  cat >"$d/f.rs" <<'EOF'
let a = xs.unwrap();
let b: Option<u8> = None;
panic!("nope");
unsafe { ptr.read() }
assert!(x > 0);
fn f(v: &mut Vec<u8>) {}
println!("hi");
    static mut COUNT: u32 = 0;
EOF
  cat >"$d/f.go" <<'EOF'
n, _ := strconv.Atoi(raw)
return nil
if err != nil { return err }
func f(v interface{}) {}
assert(x)
xs = append(xs, y)
fmt.Println("hi")
var cache = map[string]int{}
EOF
  cat >"$d/f.java" <<'EOF'
int n = Integer.parseInt(raw);
String s = null;
throw new IllegalStateException();
@SuppressWarnings("unchecked")
Optional.get()
list.sort()
System.out.println("hi");
STATIC_CACHE = new HashMap<>();
EOF
  local missed=0 note pat lang hit
  printf 'engine: %s\n\n' "$ENGINE"
  while IFS=$'\t' read -r note _ pat; do
    [ -n "${pat:-}" ] || continue
    hit=""
    for lang in ts py rs go java; do
      if scan "$pat" "$d/f.$lang" | grep -q .; then hit="$hit $lang"; fi
    done
    if [ "$(printf '%s' "$hit" | wc -w)" -ge 3 ]; then
      printf 'ok    %-38s%s\n' "$note" "$hit"
    else
      printf 'FAIL  %-38s%s <- must carry to 3+ languages\n' "$note" "${hit:- none}"
      missed=$((missed + 1))
    fi
  done <<<"$LENSES"
  rm -rf "$d"
  if [ "$missed" -ne 0 ]; then
    printf '\n%s lens(es) too language-specific.\n' "$missed" >&2
    exit 1
  fi
  printf '\nevery lens carries across languages.\n'
}

if [ "$selftest" -eq 1 ]; then
  self_test
  exit 0
fi

if [ ${#targets[@]} -eq 0 ]; then
  if [ -d src ]; then targets=(src); else targets=(.); fi
fi
survey "${targets[@]}"
