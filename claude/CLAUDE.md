# Global conventions (NixOS, single user)

Seven laws. Everything below is a consequence of them — when a situation is not covered,
derive it from here rather than guessing.

1. **Nothing is installed imperatively.** Persistent → `/etc/nixos`
   (`modules/nixos/packages.nix` for the system, `modules/home/default.nix` for the
   user), taken to a clean `nh os build` and then handed over — the switch itself is
   denied here and is the user's to run (law 3). One-off → `nix shell nixpkgs#<pkg>
   -c`. Per-project → `devenv.nix`.
2. **A missing tool is a decision, not a breakage.** `command not found` means the
   absence is deliberate — usually so a system copy cannot shadow a project's pinned
   toolchain. Look it up in the inventory, and `nix-locate bin/<name>` when it is not
   there — that says which package ships it, which is what you need to borrow it with
   `nix shell` rather than install around it.
3. **No prompt can be answered.** No terminal, no display: an editor, a password, a TUI
   or an askpass dialog fails or hangs rather than waiting. Known instances are `EDITOR`
   (pinned to `false`), `sudo` behind `nh os switch`, and git askpass on an HTTPS remote
   (use SSH remotes). Assume there are others. Work to the last step that needs no
   answer, then hand over.
4. **Rules are declared; state is not.** `~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md`
   and `check-conventions.sh` are read-only store symlinks — edit `/etc/nixos/claude/`
   and rebuild. AGENTS.md is generated from this file, so there is one source and not
   two. The editor guard, the deny rules and the hooks are *generated* too: the
   guards live in `modules/nixos/agent-guards.nix` and the deny list in
   `agent-denies.nix`, shared by both agents, and `claude.nix` / `codex.nix` attach
   them — into `/etc/claude-code/managed-settings.json` and
   `/etc/codex/requirements.toml` respectively. There is no JSON or TOML file to
   edit, and the reasoning for each rule sits beside it in the nix. Only
   `~/.claude/settings.json` is writable in place; it holds state (theme), not rules.
5. **Nothing survives unless declared.** Impermanence is on — only declared or persisted
   paths outlive a reboot, and `modules/nixos/impermanence.nix` is the list. Use the
   session scratchpad the harness names at startup, never the home root.
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

Two obligations follow from law 6. **A new assertion or guard is not finished until it
has been watched going red on purpose** — the `INVENTORY=` / `MANAGED=` / `SETTINGS=` /
`GUARDS=` overrides exist for that, or a doctored binary earlier on `PATH`. And **a law
that cannot be followed from its own text is incomplete**: say where the missing step
lives, or the gap gets filled by guessing.

## What is enforced, and what is only written down

A rule in prose is a handshake; a rule in the generated managed settings is a wall.
The walls are not listed here on purpose — each one denies with its own explanation
at the moment it is hit, so restating them would spend context in every session to
prevent what a hook already prevents. `modules/nixos/agent-denies.nix` is the list
and `agent-guards.nix` the guards — both shared by every agent here, and each rule
carries its reasoning beside it. **A deny from a hook is the guard working: read the
reason and comply rather than routing around it.**

Two consequences worth carrying in advance, because they change what you plan rather
than only what you type. `nh os switch` is denied, so take the work to a clean `nh os
build` and hand the switch over. And a `*.sh` or `*.bash` file written through Write
or Edit is shellchecked on the spot, so findings arrive at write time rather than at
the commit gate.

## Say the shape before doing the work

Before anything multi-step or irreversible, state these seven lines. Nothing at all
before a one-line edit.

```
DELIVERABLE   the noun that exists when this is done
PRECONDITION  what must already be true to start
POSTCONDITION what is true afterwards, stated so it can be checked
FAILURE       the named ways this ends badly, as outcomes not surprises
INVARIANT     what must be unchanged when it is over
VERIFY        the exact command whose result decides success
EFFECTS       which single step is irreversible, and where
```

`VERIFY` earns the most: naming the observable before starting is what stops three
probes that each tested something else.

Where a *new* rule belongs takes two questions. **What can a hook actually observe?**
Usually a slice, not the whole rule; the remainder stays a request rather than being
pretended into a wall. Then: **does violating it cost anything you cannot get back?**
`grep -r` and bare `find` are as visible as anything on the wall list and are
deliberately left in prose, because ignoring them costs a slower search and nothing
else.

## Instruction files and skills

Law 4 decides where each of these lives. "Declared" does not mean "in `/etc/nixos`" — it
means reproducible from *a* repo rather than hand-written into place.

**This file is the only home for a rule that holds everywhere.** A project's `CLAUDE.md`
says what is *different* in that directory and nothing else: no toolchain, no VCS, the
command that builds it, a convention its own files follow. It never restates a rule from
here. A copy cannot be corrected from here, and a stale one outranks nothing while
looking authoritative — `check-conventions.sh` fails any project file repeating more than
ten lines of this one, so a duplicated rule is caught rather than obeyed.

**Skills split the same way.** A global one is declared by this repo and reaches
`~/.claude/skills/` as a store symlink, either written into `/etc/nixos/claude/skills/`
or pulled from a flake input — `modules/home/skills.nix` does the latter for
`mattpocock/skills` and `ponytail`, and links the second into `~/.codex/skills/` as
well, because it carries a manifest for both agents. One that applies to a single
project lives in that project's `.claude/skills/`, committed there — declared, just
not by this one. Nothing under either skills directory is hand-written, and the check
asserts it for both — excepting `~/.codex/skills/.system/`, which Codex populates
with its own built-in skills. Those are state, not rules, and sit on the settings.json
side of law 4.

**A bundle carrying `.claude-plugin/plugin.json` is linked whole, never flattened.**
Such a directory loads as `<name>@skills-dir` and its skills are namespaced
(`/mattpocock-skills:code-review`). Unpacking it into one entry per skill throws the
namespace away and manufactures collisions with built-ins that the plugin form does
not have.

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
exception — filesets select non-interactively and no editor opens. Resolve conflicts
with `nix shell nixpkgs#mergiraf -c jj resolve --tool mergiraf` first — it auto-merges
what the syntax allows and exits 1 when real conflicts remain — then edit the still-
marked files directly and `jj squash` or `jj new`.

**`nix flake check` gates every commit in `/etc/nixos`.** It runs nixfmt, deadnix,
shellcheck and shfmt over the tree. jj has no hook support and bypasses `.git/hooks`, so
a pre-commit hook can never fire there; a `PreToolUse` hook in `managed-settings.json`
does the job instead, running the check on `jj commit` and `jj git push` and denying the
call when it fails. It costs about ten seconds. Run it by hand earlier if you want the
finding sooner, and note that it only sees tracked files — a new file still has to be
`git add`ed before the flake can fail on it. See the inventory's conventions for what
the gate deliberately leaves out.

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
project's pinned version. There is no list of them here on purpose — a list in prose
rots, and this one is one command away and checked:

```
jq -r '.not_installed[].names[]' tools.json
```

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
`modules/home/default.nix`, then a clean `nh os build /etc/nixos` and the switch is
handed over (law 3) — the user runs `nh os switch` themselves, as the user, since
`nh` refuses to run as root.

**Editing needs no sudo; activating does.** `/etc/nixos` is user-owned, so change and
`nh os build /etc/nixos` freely — the build proves the config evaluates and prints the
generation diff, and it needs no password. `nh os switch` escalates internally to
activate, and an agent shell has no terminal to type a password into, so it fails with
`sudo: a terminal is required`. Take the work as far as a clean build, then hand the
switch to the user. New files must be `git add`ed first or the flake cannot see them.

## Shell

- Login shell is **fish**, which is not POSIX. Write scripts for bash and run them
  with `bash script.sh` rather than fighting `export`, arrays, or `$(...)` quirks.
- Prefer `rg` over `grep -r` and `fd` over `find`. No structural/AST search is on
  PATH: `, ast-grep …` fetches one for a single command on the rare occasion a
  regex genuinely cannot express the pattern.
- `curl` is present; `wget` is not.
- Edit a file in place with `| sponge`, never `> tmp && mv tmp f` — `> f` truncates
  before the reader runs, and a dropped `&&` leaves the edit unapplied and silent.
- `jq` for JSON; `yq` / `tomlq` / `xq` take the same syntax over YAML, TOML and XML.
  Reach for those over `sed` on structured files.
- Never guess at a NixOS option (law 6). `nix eval --raw
  /etc/nixos#nixosConfigurations.<host>.options.<path>.description` gives the docs and
  `…config.<path>` the live value; `nixos-option <path>` also works. `nix eval` is
  allow-listed, so neither prompts.
- Do not launch interactive TUIs from an agent shell — `nvim`, `jjui`, `fzf` and
  `zellij attach` among them; the inventory flags the rest in its `purpose` notes.
  `zellij action` / `zellij run` are scriptable.
- Persisted paths are listed in `modules/nixos/impermanence.nix` (law 5).
