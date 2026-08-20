# Global conventions (NixOS, single user)

Seven laws. Everything below is a consequence of them — when a situation is not covered,
derive it from here rather than guessing.

1. **Nothing is installed imperatively.** Persistent → `/etc/nixos`, then `nh os
   switch`. One-off → `nix shell nixpkgs#<pkg> -c`. Per-project → `devenv.nix`.
2. **A missing tool is a decision, not a breakage.** `command not found` means the
   absence is deliberate — usually so a system copy cannot shadow a project's pinned
   toolchain. Look it up in the inventory; never install around it.
3. **No prompt can be answered.** No terminal, no display: an editor, a password, a TUI
   or an askpass dialog fails or hangs rather than waiting. Known instances are `EDITOR`
   (pinned to `false`), `sudo` behind `nh os switch`, and git askpass on an HTTPS remote
   (use SSH remotes). Assume there are others. Work to the last step that needs no
   answer, then hand over.
4. **Rules are declared; state is not.** `~/.claude/CLAUDE.md` and
   `check-conventions.sh` are read-only store symlinks — edit `/etc/nixos/claude/` and
   rebuild. The editor guard and the convention hook live in that directory's
   `managed-settings.json`, wired by `modules/nixos/claude.nix`. Only
   `~/.claude/settings.json` is writable in place; it holds state (theme), not rules.
5. **Nothing survives unless declared.** Impermanence is on — only declared or persisted
   paths outlive a reboot. Use the session scratchpad, never the home root.
6. **Nothing here is known from memory.** A version, a flag's argument order, whether a
   command opens a TUI, what a file already says — each is one command away, and the
   guess has been wrong often enough that checking is the cheaper habit. `<tool>
   --version`, `--help`, `jq` over the file, `nix eval` over the config. This file is
   included in that: it was true when it was written, and `check-conventions.sh` is what
   says which parts still are.
7. **Everything declared is public.** The other half of law 5. `/etc/nixos` is a public
   GitHub repo, and whatever a nix file contains is copied into `/nix/store`, which every
   process on this machine can read — two independent reasons a secret put here stops
   being one. Real secrets live in `machine.secretsDir` (`/persistent/system/secrets`,
   root-only, on the encrypted root), written there by `installer.sh`. A nix file may
   point at that path; it must never carry the value.

`/etc/nixos/tools.json` is the **inventory**; this file is the **rules**. Where the two
disagree the inventory wins, and `bash ~/.claude/check-conventions.sh` is what says so:
it derives its expectations from the inventory and verifies them against the live
machine.

## Instruction files and skills

Law 4 decides where each of these lives. "Declared" does not mean "in `/etc/nixos`" — it
means reproducible from *a* repo rather than hand-written into place.

**This file is the only home for a rule that holds everywhere.** A project's `CLAUDE.md`
says what is *different* in that directory and nothing else: no toolchain, no VCS, the
command that builds it, a convention its own files follow. It never restates a rule from
here. A copy cannot be corrected from here, and a stale one outranks nothing while
looking authoritative — `check-conventions.sh` fails any project file repeating more than
ten lines of this one, so a duplicated rule is caught rather than obeyed.

**Skills split the same way.** One that applies everywhere is declared in
`/etc/nixos/claude/skills/` and reaches `~/.claude/skills/` as a store symlink — `unslop`
is the only one. One that applies to a single project lives in that project's
`.claude/skills/`, committed to that project's repo: declared, just not by this one.
Nothing under `~/.claude/skills/` is hand-written, and the check asserts it.

## Version control: jj in front, git behind

Use **jj** (jujutsu) for local history. Colocated means `.jj` and `.git` in the same
directory sharing one object store, so coworkers, CI and GitHub see ordinary Git
commits.

**Check which case you are in before touching history** — `ls -d .jj .git` answers it
in one command, and the rules below apply to only one of the three:

| `.jj` | `.git` | what to do |
| --- | --- | --- |
| yes | yes | colocated. The table below applies; never `git commit` here |
| no | yes | git-only. Plain `git commit` is correct and loses nothing. Colocate with `jj git init --colocate` — it adopts in place and preserves history — but only for a repo that is yours |
| no | no | not under version control. Say so before editing anything; there is no undo |

`/etc/nixos` is colocated. A directory you were handed may be any of the three.

The model, which is what makes the command map read strangely at first:

- **No staging area.** The working copy *is* a commit (`@`). Saving a file has
  already amended `@`. There is nothing to `add`, and nothing is ever "unstaged".
- **Every operation is recorded.** `jj undo` rewinds the last operation — the whole
  repo state, not just `HEAD`. `jj op log` lists them; `jj op restore <id>` jumps to
  one. This makes rebases and history edits cheap to attempt.
- **Bookmarks, not branches.** Nothing auto-follows your commits; you move the
  bookmark before pushing.

| Intent | Command |
| --- | --- |
| Status / log | `jj st` · `jj log` (bare `jj` is aliased to log) |
| Diff | `jj diff` · `jj diff -r <rev>` |
| Describe current work | `jj describe -m "msg"` |
| Finish and start the next change | `jj commit -m "msg"` |
| Start a change on top | `jj new` · `jj new <rev>` |
| Amend into the parent | `jj squash` |
| Move work into a specific commit | `jj squash --into <rev>` |
| Discard a change | `jj abandon <rev>` |
| Reorder / restack | `jj rebase -r <rev> -d <dest>` |
| Sync with the remote | `jj git fetch` |
| Publish | `jj bookmark set <name> -r @-` then `jj git push` |
| Publish an unnamed change | `jj git push -c @-` (names a bookmark from the change id) |
| Back out of anything | `jj undo` · `jj op log` |

**Never trigger an editor.** Agent sessions pin `JJ_EDITOR` / `GIT_EDITOR` / `EDITOR` /
`VISUAL` to `false`, so a forgotten `-m` now fails fast instead of hanging on a GUI
window. That guard does not reach the **diff** editor: bare `jj split`, `jj diffedit`,
`jj resolve`, and any `-i` / `--interactive` / `--editor` flag open jj's builtin TUI,
which an agent shell cannot drive. Stay away from those. `jj split <paths>` is the
exception — filesets select non-interactively and no editor opens. Resolve conflicts by
editing the marked files directly, then `jj squash` or `jj new`.

**Run `nix flake check` before committing in `/etc/nixos`.** It gates nixfmt, deadnix,
shellcheck and shfmt over the tree. Nothing runs it for you: jj has no hook support and
bypasses `.git/hooks`, so a pre-commit hook would never fire. See the inventory's
conventions for what the gate deliberately leaves out.

**Commit as you go.** `jj split <paths>` separates concerns that live in different
files and is safe — it takes filesets and only opens the diff editor with `-i` or with
no arguments at all. Two concerns inside *one* file cannot be separated without that
editor, so commit each piece as you finish it rather than batching to the end.

**Do not launch `jjui`** — it is a TUI and needs a terminal a subagent does not have.

Keep **git** for what it is still best at: reading (`git log`, `git show`, `git
blame`), and as the backend gh talks to. Do not create commits with `git commit` in a
colocated repo — jj will import it, but you lose the operation log entry that makes
the change undoable.

Use **gh** for PRs, issues, and `gh api`. Auth is per-user state: check `gh auth
status` before assuming a session exists.

## Python: uv only

There is no system `python3`. `uv` is the only route to an interpreter, and it will
resolve or download one on a machine that has none.

- `uv run script.py` · `uv run -m module` · `uv run pytest`
- `uv run --with requests script.py` for a one-off dependency, no project needed
- `uvx <cli>` to run a Python CLI without installing it
- `uv add` / `uv sync` inside a project; `uv python install <ver>` for a bare interpreter

Never `pip install`, never hand-activate a venv, never assume `python` resolves.

## Project toolchains: devenv + direnv

Language toolchains are **deliberately absent system-wide** so they cannot shadow a
project's pinned version — Rust, Node and the C toolchain among them. Do not treat the
examples as the list; `not_installed` in the inventory is the list, and it is checked.
Toolchains live in per-project `devenv.nix` (`languages.rust`, `languages.javascript`, …).

An agent shell is non-interactive, so direnv's hook may not have fired and project
tools will look missing. Prefix instead of debugging:

```
direnv exec . <cmd>          # run <cmd> in this project's environment
devenv shell -- <cmd>        # equivalent, without direnv
```

A new project needs `devenv.nix`, an `.envrc` containing `use devenv`, and one
`direnv allow`.

For a tool needed once, and nowhere else: `nix shell nixpkgs#<pkg> -c <cmd>` — it
leaves nothing behind.

Law 1 in practice: system packages go in `modules/nixos/packages.nix`, user ones in
`modules/home/default.nix`, then `nh os switch /etc/nixos` as the user — `nh` refuses
to run as root.

**Editing needs no sudo; activating does.** `/etc/nixos` is user-owned, so change and
`nh os build /etc/nixos` freely — the build proves the config evaluates and prints the
generation diff, and it needs no password. `nh os switch` escalates internally to
activate, and an agent shell has no terminal to type a password into, so it fails with
`sudo: a terminal is required`. Take the work as far as a clean build, then hand the
switch to the user. New files must be `git add`ed first or the flake cannot see them.

## Shell

- Login shell is **fish**, which is not POSIX. Write scripts for bash and run them
  with `bash script.sh` rather than fighting `export`, arrays, or `$(...)` quirks.
- Prefer `rg` over `grep -r` and `fd` over `find`. For code patterns that regex
  handles badly, use `ast-grep` — invoked by that name, never as `sg`, which here is
  util-linux's setgid wrapper.
- `curl` is present; `wget` is not.
- Edit a file in place with `| sponge`, never `> tmp && mv tmp f` — `> f` truncates
  before the reader runs, and a dropped `&&` leaves the edit unapplied and silent.
- `jq` for JSON; `yq` / `tomlq` / `xq` take the same syntax over YAML, TOML and XML.
  Reach for those over `sed` on structured files.
- Do not launch interactive TUIs from an agent shell — `jjui`, `btop`, `fzf` and
  `zellij attach` among them; the inventory flags the rest in its `purpose` notes.
  `zellij action` / `zellij run` are scriptable.
- Persisted paths are listed in `modules/nixos/impermanence.nix` (law 5).
