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
   rebuild. The editor guard, the deny rules and the hooks are *generated* by
   `modules/nixos/claude.nix` into `/etc/claude-code/managed-settings.json`; there is
   no JSON file to edit, and the reasoning for each rule sits beside it in the nix.
   Only `~/.claude/settings.json` is writable in place; it holds state (theme), not
   rules.
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

## What is enforced, and what is only written down

A rule in prose is a handshake; a rule in the generated managed settings is a wall.
Both are here, and the difference decides how carefully a line needs reading. The
walls, as `permissions.deny` entries and hooks:

- **TUIs that would hang the session.** Not a list — `jq -r '[.tools[] |
  .agent_unsafe // empty | .[]] | unique[]' tools.json` is the list, and
  `modules/nixos/claude.nix` builds a `Bash(<prefix> *)` deny from each. Marking a
  tool interactive in the inventory is what denies it.
- **jj's diff editor** — bare `jj split`, bare `jj resolve`, `jj diffedit`, and any
  `jj … -i` / `--interactive`. Subcommand shapes, not inventory facts, so these stay
  literal.
- **`sg`**, which here is util-linux's setgid wrapper and not ast-grep.
- **`nh os switch`**, whose sudo prompt no Claude session can answer (law 3).
- **`git commit` in a colocated repo**, decided by looking for `.jj` in the working
  directory, so a git-only repo is left alone.
- **`jj commit` and `jj git push` in `/etc/nixos`**, gated on `nix flake check`.
- **`nix profile add` / `install` and `nix-env -i`** — law 1's hookable slice.
- **Activating a venv by hand** (anything naming `bin/activate`), law 1 for Python.
- **`cmd f > f`**, where the shell empties `f` before the command reads it. Only when
  `f` already exists; creating a new file destroys nothing.
- **`nh os build` and `nix flake check` with an untracked `.nix` present** — the flake
  reads the git tree, so it cannot see the file, and the deny names the ones to add.
- **Editing `hosts/*/hardware-configuration.nix`**.

One hook reports rather than blocks: a `*.sh` or `*.bash` file written through Write
or Edit is shellchecked on the spot, at the same severity the commit gate uses, and
the findings come back immediately. Bash typed inline into a Bash call is invisible to
a hook and stays advisory.

That split is the method. For any rule here, two questions decide where it lives.
**What can a hook actually observe?** — usually a slice, not the whole rule, and the
remainder stays a request rather than being pretended into a wall. Then: **does
violating it cost anything you cannot get back?** `grep -r` and bare `find` are every
bit as visible as the denials above and are deliberately left in prose, because
ignoring them costs a slower search and nothing else. A wall is worth a round trip
only for the rules where it is not.

`permissions.allow` is the same argument pointed the other way. Sessions start in auto
mode, where a classifier reviews shell commands in place of a prompt; an allow rule
resolves before that runs. The reading half of the workflow is on the list — `rg`, `fd`,
`jq`, `jj st`/`log`/`diff`/`show`/`file list`/`op log`/`bookmark list`, `nix eval`, `nix
flake check`, `nh os build`, and `check-conventions.sh` — so what still gets reviewed is
the half that changes something, and a refusal there means something.

Three you might expect and will not find. `sed -n` still prompts, because `-n` does not
stop sed's `w` command writing a file. `devenv shell --` still prompts, because it runs
whatever follows it. `awk` still prompts, because it can redirect from inside its own
program. And `<tool> --version` is not allowlisted despite law 6: auto mode drops
leading-wildcard rules, so the entry would not survive.

Two things the deny list deliberately leaves out. It does not deny what is already absent:
`command not found` is the wall for `pip`, `python3`, `node`, `cargo` and `wget`
already, and a rule there would be a second copy of a fact the machine states better
(laws 2 and 6). And it does not deny preferences — `rg` over `grep -r`, `| sponge` over
`> tmp && mv`, `fd` over `find` — because those are about cost, not about a call that
cannot work.

The walls are not airtight either. A deny rule matches the command Claude's own tools
run; it does not follow `direnv exec`, `devbox run`, or a shell script that calls the
same thing one level down. It narrows the way in, it does not seal it.

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
