---
name: fp-review
description: Review, audit or critique code and designs through functional-programming lenses — partial functions, nulls, thrown errors, escaped type contracts, hidden effects, mutation and global state. Use when asked to review code, check a design's types, look for edge cases, harden a signature, or critique a spec or set of instructions.
---

# fp-review

Reviews code through eight lenses drawn from *Functional Programming in Scala*
(Chiusano & Bjarnason). Not a style check and not a linter — it asks one question,
in eight shapes: **does the type tell the truth about what the code does?**

Language-agnostic. Verified against real trees in TypeScript, Rust, Python and Nix.

## Install

Copy this directory to either location — no build step, no dependencies beyond a
grep:

```bash
mkdir -p .claude/skills && cp -r <this-dir> .claude/skills/fp-review      # one repo
mkdir -p ~/.claude/skills && cp -r <this-dir> ~/.claude/skills/fp-review  # every repo
```

Needs **ripgrep** (`rg`), or falls back to **GNU grep**. Nothing else.

## Run

```bash
bash .claude/skills/fp-review/detect.sh                 # src/ if it exists, else .
bash .claude/skills/fp-review/detect.sh lib/ cmd/       # specific trees
bash .claude/skills/fp-review/detect.sh path/to/one.py  # a single file
bash .claude/skills/fp-review/detect.sh --with-tests    # include test files
bash .claude/skills/fp-review/detect.sh --self-test     # verify the lenses still work
```

Always exits 0 — every hit is a question, not a verdict, so it is safe to run in
CI without gating anything. Run it from the repo root.

Real numbers, so the output is not a surprise: a 55-file TypeScript service gives
536 sites, a Rust workspace 621, a mid-size Python package 405. A tree of Nix —
a pure functional language — gives **10**, which is the clearest evidence the
lenses measure what they claim to.

## The eight lenses

Each hit is a question, and the honest answer is often "yes, intended."

| Lens | Ask at each hit |
|---|---|
| `total-function` | Does this have an answer for *every* input? `int("x")` raises, `.pop()` on empty is undefined, `Atoi` fails. If it isn't total, does the return type admit it? |
| `option-not-null` | Is absence *modelled*, or is it a hole in the floor? An empty box you must open beats a value that might not be there. |
| `errors-as-values` | Is the failure in the signature, or does it travel invisibly up the stack? A caller cannot see `throw` / `raise` / `panic!`. |
| `types-are-contracts` | `any`, `interface{}`, `Object`, `# type: ignore`, `unsafe` — the contract was opted out of. What is the escape hiding? |
| `make-illegal-states-unrepresentable` | An assertion or a force-unwrap says you know something the type does not. Can the type be reshaped so the bad state cannot be written down? |
| `immutability` | Does anyone else hold this value? In-place mutation is action at a distance. |
| `side-effect` | Is the effect *described* or *performed*? Effects belong at the edges, description in the middle. |
| `local-reasoning` | Module-level mutable state means understanding one function needs the whole file's history. |

## How to review with it

1. Run the survey on the tree, the subdirectory, or the single file in question.
2. **Do not report every hit.** 536 hits is not 536 bugs. Look for *clusters*: one
   file carrying most of a lens is a design smell; hits spread evenly are usually
   just the language.
3. Read the actual code at the clustered sites. The survey finds candidates; only
   reading decides.
4. Report the few places where the type genuinely lies about the code, name the
   lens, and propose the signature that would not lie.

Step 3 is not optional. A review that reports grep hits is a worse linter, not a
better review.

### Reviewing a diff instead of a tree

The lenses apply to changed files, which is usually what a PR review wants:

```bash
git diff --name-only main... | xargs bash .claude/skills/fp-review/detect.sh
```

### Reviewing a spec, a design doc, or a set of instructions

There is nothing to grep, so run the lenses by hand as questions about the
described design. This works on an RFC, a ticket, an API sketch, or an
instructions file for an agent:

- **total-function** — for each operation described, what happens at the inputs
  the document does not mention? Empty, zero, absent, already-exists, twice.
- **option-not-null** — where the document says "optional" or "if available",
  does the shape say which fields go missing together, or does it leave four
  independent maybes and sixteen states?
- **errors-as-values** — the document lists a happy path. Where do the failures
  appear in the *interface*, rather than in a paragraph of prose?
- **types-are-contracts** — which words are doing work no type will enforce?
  "valid", "sanitised", "already checked". Those are the load-bearing lies.
- **make-illegal-states-unrepresentable** — what combination is described as
  "shouldn't happen"? Can the shape be changed so it cannot be expressed?
- **immutability** — who else can see this thing while it is being changed?
- **side-effect** — does the document separate deciding from doing, or does one
  step both compute and commit?
- **local-reasoning** — how much of the rest of the system must be held in mind
  to check that one step is correct?

## Calibration by language

The lenses are universal; their *density* is not. Read the counts with this:

- **Rust** — `immutability` fires on `mut` / `&mut`, which are explicit and
  compiler-checked, i.e. the discipline the lens asks for. Read that lens as a map
  of where mutation lives, not a list of problems. `unwrap()` / `expect()` under
  `total-function` are the real signal.
- **Go** — `errors-as-values` fires on `if err != nil`, which *is* the value-based
  handling the lens wants. The signal in Go is `panic(` and `interface{}`.
- **Python / TypeScript** — highest yield. Absence, failure and effects are all
  invisible in the type by default, so hits are usually genuine questions.
- **Java / C#** — `option-not-null` and `errors-as-values` dominate, because
  `null` and unchecked exceptions are the defaults.
- **Functional languages** (Haskell, Nix, Elm, F#) — near-silent by construction.
  A high count here is a genuine finding.

## Gotchas

- **`option-not-null` over-reports by design.** No regex can tell `| null` in a
  *type declaration* from one in a *return position*. Treat its count as a density
  signal, never a to-do list. The other seven are precise.
- **Test files are excluded by default, and this is the most important switch in
  the script.** Assertions, thrown errors and mutation are *correct* in a test;
  including them roughly doubles the assertion lens and buries the production
  sites. Use `--with-tests` when you actually want them (measured on one Rust
  workspace: 234 assertion sites became 452).
- **The skill matches itself.** `detect.sh` and this file spell out every idiom the
  lenses look for, so surveying a tree that contains the skill added ~60 phantom
  hits. Any directory named `fp-review` is pruned for that reason — rename the
  directory and the phantom hits come back.
- **A lens firing zero is information, not a bug.** `--self-test` is how you tell a
  quiet lens from a broken one: it asserts every regex still matches its fixture
  line in at least three of five languages.
- **Patterns must anchor to syntax, not words.** Two false positives were found
  this way and fixed: `delete [a-z]` matched an English sentence in a comment, and
  `global [a-z_]` matched the phrase "the global half comes out". Anything that can
  occur in prose needs a syntactic anchor. If you add a lens, check it against a
  comment-heavy file before trusting it.
- **The two engines differ slightly.** POSIX bracket expressions treat backslash as
  literal, so `[A-Za-z_)\]]` means different sets to ripgrep and to GNU grep, and
  one lens loses one language under the fallback. Counts are comparable between
  engines but not identical. `--self-test` prints which engine ran.
- **The lens table is a tab-separated heredoc.** A row whose regex wraps onto its
  own line parses as an empty pattern and the lens *silently disappears* from every
  survey — no error, just quietly fewer findings. This happened while writing it.
  Run `--self-test` after any edit to the table; nothing else catches it.
- **ripgrep honours `.gitignore`; GNU grep does not.** A generated directory that
  is gitignored but not in the prune list appears under the fallback and not under
  ripgrep.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `needs ripgrep or GNU grep on PATH` | Install ripgrep, or run where GNU grep is available. BSD/macOS grep is not enough — its ERE lacks `\b` and `\s`. |
| `0 sites` on a real tree | You are in a subdirectory with no code, the tree is gitignored, or it all sits under a pruned directory name (`build`, `dist`, `target`, `spec`). Pass the path explicitly. |
| A lens prints `FAIL … must carry to 3+ languages` | Its heredoc row lost a tab, or its regex wrapped onto the next line. Rejoin the row. |
| Survey floods with vendored code | Add the directory to `PRUNE_DIRS` at the top of `detect.sh`. |
| Counts changed after moving machines | Different engine. Check the header line of the output. |

## Credit

The lenses are a compression of ideas from *Functional Programming in Scala* by
Paul Chiusano and Rúnar Bjarnason. The book is the reasoning; this is a way to find
where it applies.
