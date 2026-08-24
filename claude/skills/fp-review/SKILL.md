---
name: fp-review
description: Review, audit, or critique code through functional-programming lenses — find partial functions, nulls, thrown errors, hidden effects, mutation, and escaped type contracts. Use when asked to review code, check types, look for edge cases, or improve a design's types and signatures.
---

# fp-review

Reviews a codebase through the eight lenses of *Functional Programming in Scala*
(Chiusano & Bjarnason). Not a style check — it asks one question per lens: **does
the type say what the code actually does?**

The driver is `detect.sh`. It surveys a tree with `rg` and groups every hit under
the lens that explains it, so a review starts from line numbers instead of vibes.

## Run

```bash
bash ~/.claude/skills/fp-review/detect.sh src      # survey a tree
bash ~/.claude/skills/fp-review/detect.sh --self-test
```

With no path it uses `src/` if it exists, else `.`. Always exits 0 — every hit is
a question, not a verdict. Run it from the **project root**, not a subdirectory.

Verified on a 55-file TypeScript tree: 344 sites across 7 lenses in about a second.

## The eight lenses

Each names a note in the vault at `~/Desktop/typescript/type-signature/` (Obsidian).
The one-line version here is enough to review with; the note is for depth.

| Lens | The question to ask at each hit |
|---|---|
| `total-function` | Does this have an answer for *every* input? `Number("x")` is `NaN`, `.pop()` on empty is `undefined`, `JSON.parse` throws. If not total, does the return type admit it? |
| `option-not-null` | Is this absence modelled, or is it a hole? An empty box you must open beats a value that might not be there. |
| `errors-as-values` | Is the failure in the signature, or does it travel invisibly up the stack? A caller cannot see `throw`. |
| `types-are-contracts` | `any`, `as unknown as`, `@ts-ignore` — the contract was opted out of. What is the escape hiding? |
| `make-illegal-states-unrepresentable` | `x!.y` says you know something the type does not. Can the type be reshaped so the bad state cannot be written? |
| `immutability` | Does someone else hold this value? In-place mutation is action at a distance. |
| `side-effect` | Is the effect described or performed? Effects at the edges, description in the middle. |
| `local-reasoning` | Module-level `let` means understanding this function needs the whole file's history. |

## How to review

1. Run the survey on the tree in question.
2. **Do not report every hit.** 219 `option-not-null` hits on a mid-size tree is
   normal and not 219 bugs — see Gotchas. Look for *clusters*: one file carrying
   most of a lens is a design smell; hits spread evenly are usually the language.
3. Read the actual code at the clustered sites before judging. The survey finds
   candidates; only reading decides.
4. Report the few sites where the type genuinely lies about the code, name the
   lens, and propose the signature that would not lie.

## Gotchas

- **`option-not-null` over-reports by design.** A regex cannot tell `: T | null`
  in a *type declaration* from a `| null` in a *return position*. Treat its count
  as a density signal, never a to-do list. The other seven lenses are precise.
- **`make-illegal-states-unrepresentable` firing zero is a good sign, not a broken
  lens.** `--self-test` is how you tell the two apart — it asserts every regex
  still matches its fixture line.
- **Patterns must anchor to syntax, not words.** An early `delete [a-z]` matched
  an English sentence inside a comment. Anything that can appear in prose needs a
  syntactic anchor (`[.\[]` after the identifier) or the survey reports comments.
- **The lens table is a tab-separated heredoc.** A lens whose regex wraps onto its
  own line parses as an empty pattern and *silently vanishes* from every survey —
  no error, just quietly fewer findings. This happened while writing it. Run
  `--self-test` after any edit to the table; that is the only thing that catches it.
- **`rg` honours `.gitignore`**, so `node_modules` is skipped for free — but a
  vendored directory that is *not* gitignored will flood the survey. Pass an
  explicit path when that happens.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `0 sites to ask about` on a real tree | You ran it from a subdirectory with no code, or the tree is gitignored. Pass an explicit path. |
| A lens prints `FAIL … regex matches nothing` | Its row in the heredoc lost its tab or its regex. Rejoin the row onto one line. |
| Survey floods with vendored code | `rg` only skips gitignored paths; name the real source dir explicitly. |
