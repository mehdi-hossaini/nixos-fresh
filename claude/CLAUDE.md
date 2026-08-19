# Global conventions (NixOS, single user)

**A missing tool is a decision, not a breakage.** `command not found` on this machine
almost always means the absence is deliberate — usually to stop a system copy shadowing
a project's pinned toolchain. Do not try to install your way out of it. Look the tool up
in `/etc/nixos/tools.json`, which carries every tool, its traps, and — under
`not_installed` — what to use instead.

That file is the **inventory**; this one is the **rules**. Where the two disagree the
inventory wins, and `bash ~/.claude/check-conventions.sh` is what says so: it derives
its expectations from the inventory and verifies them against the live machine. Never
transcribe version numbers from either — run `<tool> --version`.

**This file is declared, not hand-written.** `~/.claude/CLAUDE.md` and
`~/.claude/check-conventions.sh` are read-only symlinks into the nix store; writing to
them fails. Edit the source in `/etc/nixos/claude/`, then rebuild. The same holds for
the agent-session editor guard and the convention hook, which live in
`/etc/nixos/claude/managed-settings.json` and reach Claude Code as managed settings via
`modules/nixos/claude.nix`. Only `~/.claude/settings.json` is yours to edit in place —
it carries state (theme), not rules.

**No prompt can be answered.** An agent shell has no terminal and no display, so
anything that stops to ask — an editor, a password, a TUI, an askpass dialog — fails or
hangs instead of waiting. The known instances: `EDITOR` (pinned to `false`, see below),
`sudo` behind `nh os switch`, and git's askpass on an HTTPS remote (avoided by using SSH
remotes — `gh auth status` reports ssh as the configured protocol). Assume there are
others not yet found. Take the work to the last step that needs no answer, then hand
over: a clean build, a staged commit, a command the user can paste.

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
window. That guard does not reach the **diff** editor: `jj split`, `jj diffedit`,
`jj resolve`, and any `-i` / `--interactive` / `--editor` flag open jj's builtin TUI,
which an agent shell cannot drive. Stay away from those. Resolve conflicts by editing
the marked files directly, then `jj squash` or `jj new`.

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

Software is never installed imperatively on this machine. Anything that should
persist goes in `/etc/nixos` (`modules/nixos/packages.nix` for system,
`modules/home/default.nix` for user) followed by `nh os switch /etc/nixos`, run as
the user — `nh` refuses to run as root.

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
- Do not launch interactive TUIs from an agent shell — `jjui`, `btop`, `fzf` and
  `zellij attach` among them; the inventory flags the rest in its `purpose` notes.
  `zellij action` / `zellij run` are scriptable.
- **Impermanence is on.** Only declared or persisted paths survive a reboot. Do not
  leave state loose in the home directory; use the session scratchpad.
