# Claude Code's *rules* — the editor guard, the deny list and the hooks — are
# configuration, so they are declared here rather than hand-written into the home
# directory. Claude Code reads /etc/claude-code/managed-settings.json ahead of
# ~/.claude/settings.json and wins on conflict, which is what makes this the right
# half of the split: settings.json stays writable for state (theme, dialogs) while
# the rules come from the repo and survive a reinstall.
#
# The instructions themselves (CLAUDE.md) and the convention checker are declared
# in modules/home — they belong to the user, not the system.
#
# The file is GENERATED from the attrset below rather than checked in as JSON.
# JSON cannot hold a comment, so for as long as this was a hand-written
# claude/managed-settings.json every "why" had to live over here, one file away
# from the rule it explained, and the two could drift. Three things follow from
# generating it: the reasoning sits beside the rule, hook scripts become real
# shell files with a shebang instead of \n-escaped strings, and — the point of
# the exercise — a rule can be DERIVED rather than restated. See tuiDenies.
{
  lib,
  pkgs,
  ...
}:
let
  # ── derived rules ───────────────────────────────────────────────────────────
  # The inventory already knows which tools hang a session with no terminal; it
  # said so in prose, and the deny list said it again in patterns. Two copies of
  # one fact is the shape every other part of this repo works to avoid, so the
  # patterns are built from tools[].agent_unsafe instead. Adding an interactive
  # tool to the inventory now denies it, the same way adding any tool already
  # extends check-conventions.sh. Reading the file is not IFD: it is a source
  # file in the flake, so fromJSON resolves at eval with nothing to realise.
  inventory = builtins.fromJSON (builtins.readFile ../../tools.json);
  agentUnsafe = lib.unique (lib.concatMap (t: t.agent_unsafe or [ ]) inventory.tools);
  tuiDenies = map (c: "Bash(${c} *)") (lib.naturalSort agentUnsafe);

  # ── hook scripts ────────────────────────────────────────────────────────────
  # jq and shellcheck are interpolated from the store; sed, printf and nix are
  # taken from PATH. The line is drawn at "would the hook fail silently without
  # it": dropping shellcheck from packages.nix must not quietly disable a gate,
  # whereas coreutils and the system nix are present on any NixOS host by
  # construction and cannot go missing on their own.
  jq = "${pkgs.jq}/bin/jq";

  # ── every guard is total ────────────────────────────────────────────────────
  # A guard that cannot understand its input used to `exit 0`, which reads as
  # "allow". Every one of these extracts `.cwd // empty` and then tests it, so a
  # payload without a cwd — a shape change upstream, a malformed line — produced an
  # empty string, matched no branch, and let the call through. It looked like a
  # wall and was a hole, and the hole was silent, which is the worst combination
  # because the wall is trusted.
  #
  # Exiting 0 is only honest when it means "this input is definitely not my
  # business". It is not honest when it means "I could not tell".
  #
  # The undecidable case escalates rather than denying. Denying would be the safe
  # reflex, but a payload shape change would then block every Bash call in the
  # session with no way through; escalating asks the user, which is the one answer
  # that is never silently wrong. PostToolUse has no such control — it reports
  # rather than blocks, and cannot allow anything by staying quiet — so the two
  # hooks below carry `set -u` and nothing more.
  escalateFn = ''
    escalate() {
      ${jq} -n --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"escalate",permissionDecisionReason:$r}}'
      exit 0
    }
  '';

  guardPreamble = ''
    set -u
    ${escalateFn}
    input=$(cat)
    cwd=$(printf '%s' "$input" | ${jq} -r '.cwd // empty') ||
      escalate "guard could not parse the hook payload as JSON, so it cannot tell whether its rule applies. Asking rather than assuming: a guard that stays quiet when confused is a wall that is trusted and absent."
    [ -n "$cwd" ] ||
      escalate "the hook payload carried no cwd, so this guard cannot tell whether its rule applies here. Asking rather than assuming."
  '';

  # The pre-commit gate jj cannot host: jj has no hook support and bypasses
  # .git/hooks, so both checks run from PreToolUse on `jj commit` and
  # `jj git push`. Only fires when the working directory is /etc/nixos.
  #
  # Two checks, cheapest first so a secret is caught before ten seconds of nix
  # evaluation rather than after.
  #
  # gitleaks was installed and inventoried all along — tools.json even said to run
  # it before pushing — and nothing ran it. check-conventions.sh scans with a
  # hand-written four-pattern regex aimed at the shapes that matter here (private
  # keys, age keys, $6$/$y$ hashes, quoted secret assignments); that stays, because
  # it is targeted at this repo's actual risk. gitleaks adds ~150 rules for the
  # cloud tokens and PATs a pasted example brings in. 0.08s over the whole tree,
  # measured 2026-08-22, so there is no reason for it not to sit here.
  #
  # It scans the working tree, not history: every commit passes through this gate
  # as a working tree first, so history stays clean by induction from a clean
  # start (`gitleaks git /etc/nixos` was clean when this landed). For a one-off
  # audit of history itself, run that command by hand.
  publishGate = pkgs.writeShellScript "claude-gate-publish" ''
    ${guardPreamble}
        case "$cwd" in
        /etc/nixos | /etc/nixos/*) ;;
        # Total, not a shrug: a cwd outside this repo is definitely not this
        # gate's business, and the preamble has already ruled out "cannot tell".
        *) exit 0 ;;
        esac
        deny() {
          ${jq} -n --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
          exit 0
        }

        if ! out=$(${pkgs.gitleaks}/bin/gitleaks dir /etc/nixos --no-banner 2>&1); then
          out=$(printf '%s\n' "$out" | sed 's/\x1b\[[0-9;]*m//g' | tail -n 30)
          deny "gitleaks found something that looks like a secret. Law 7: /etc/nixos is a public repo and every nix file is copied world-readable into /nix/store, so this cannot be fixed after the fact by deleting it. Move the value to machine.secretsDir and point at the path instead.
    $out"
        fi

        out=$(nix flake check 2>&1) && exit 0
        out=$(printf '%s\n' "$out" | sed 's/\x1b\[[0-9;]*m//g' | tail -n 40)
        deny "\`nix flake check\` fails, so this would publish a tree the gate rejects. jj has no hook support and bypasses .git/hooks, so this hook is the pre-commit hook it cannot have. Fix the findings, then run the command again.
    $out"
  '';

  # `git commit` is correct in a git-only repo and only destructive in a
  # colocated one, so this cannot be a flat deny pattern. It looks for .jj in the
  # working directory and denies on that.
  colocatedCommitGuard = pkgs.writeShellScript "claude-guard-git-commit" ''
    ${guardPreamble}
    # Total: .jj either is or is not there, and the preamble guaranteed a cwd.
    [ -d "$cwd/.jj" ] || exit 0
    ${jq} -n '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: "This repo is colocated (.jj is present), so a git commit is imported by jj without an operation-log entry and the change stops being undoable. Use `jj commit -m` or `jj describe -m` instead. Reading with git log / git show / git blame is unaffected."
      }
    }'
  '';

  # The hookable slice of "shellcheck every non-trivial bash you write": a file
  # written through Write or Edit is visible to a hook, so it gets linted the
  # moment it lands. Bash typed inline into a Bash call is not, and stays
  # advisory. Severity is left at the default deliberately — the commit gate runs
  # shellcheck through git-hooks with its defaults, so a quieter setting here
  # would pass a file that fails ten minutes later. Verified 2026-08-22: both
  # tracked shell files are clean at default severity with -x.
  # exit 2 is what feeds the findings back into the conversation.
  shellcheckGate = pkgs.writeShellScript "claude-gate-shellcheck" ''
    set -u
    f=$(${jq} -r '.tool_input.file_path // empty')
    case "$f" in
    *.sh | *.bash) ;;
    *) exit 0 ;;
    esac
    [ -f "$f" ] || exit 0
    out=$(${pkgs.shellcheck}/bin/shellcheck -x "$f" 2>&1) && exit 0
    printf 'shellcheck (write-time hook) on %s:\n%s\n' "$f" "$out" >&2
    exit 2
  '';

  # After a rebuild the machine may no longer match what the inventory and
  # CLAUDE.md claim. This is the only mechanism that notices, and it reports into
  # the conversation rather than into a log nobody reads.
  conventionsCheck = pkgs.writeShellScript "claude-check-conventions" ''
    set -u
    out=$(bash ~/.claude/check-conventions.sh 2>&1); rc=$?
    [ $rc -eq 0 ] && exit 0
    out=$(printf '%s\n' "$out" | sed 's/\x1b\[[0-9;]*m//g' | grep -E 'FAIL|failed$')
    ${jq} -n --arg o "$out" '{
      systemMessage: "Convention check FAILED after a system rebuild — /etc/nixos/tools.json or ~/.claude/CLAUDE.md is now stale.",
      hookSpecificOutput: {
        hookEventName: "PostToolUse",
        additionalContext: ("check-conventions.sh failed after `nh os`. The machine no longer matches what tools.json and CLAUDE.md claim; do not trust either until this is fixed.\n" + $o)
      }
    }'
  '';

  # ── the hookable slice of three prose rules ─────────────────────────────────
  # Each of these was written in CLAUDE.md as "never do X" and stayed advisory
  # until someone asked the better question: not "is this a hard error or a
  # preference", but "what part of it can a hook actually see". The second
  # question is necessary and not sufficient — `grep -r` and bare `find` are just
  # as visible and are deliberately NOT here, because violating those costs a
  # slower search and nothing else. A wall is worth a round trip only when the
  # violation costs something you cannot get back.
  #
  # There is no `if` filter, because one rule string cannot express three
  # unrelated shapes, so the prefilter below stands in for it. It is a literal
  # match on the raw payload before any fork. `>` is common enough that the
  # redirect arm pays a jq on many calls; measured at a few milliseconds against
  # a 5s timeout, which is the right trade for the one irreversible rule here.
  commandShapeGuard = pkgs.writeShellScript "claude-guard-command-shape" ''
    set -u
    ${escalateFn}
    input=$(cat)
    # This arm is total rather than a shrug, and it is why this one guard does not
    # use guardPreamble: the test is a literal substring match on the raw payload,
    # which cannot fail to parse. A payload containing none of these literals
    # definitely does not contain a command this guard has an opinion about, so
    # allowing it is an answer, not a guess — and the jq fork is skipped on the
    # majority of Bash calls, which is the point of testing here first.
    case $input in
    *"nix profile"* | *"nix-env"* | *"bin/activate"* | *">"*) ;;
    *) exit 0 ;;
    esac
    parsed=$(printf '%s' "$input" | ${jq} -r '@sh "cmd=\(.tool_input.command // "") cwd=\(.cwd // "")"') ||
      escalate "guard could not parse a hook payload that looked like it contained a guarded command shape. Asking rather than assuming."
    eval "$parsed"
    [ -n "$cmd" ] ||
      escalate "the hook payload carried no command, so this guard cannot inspect its shape. Asking rather than assuming."
    deny() {
      ${jq} -n --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
      exit 0
    }

    # Law 1. `install` is the old spelling, `add` the current one; both are denied
    # so a command copied from older docs fails the same way.
    case $cmd in
    *"nix profile install"* | *"nix profile add"* | *"nix-env -i"* | *"nix-env --install"*)
      deny "law 1: nothing is installed imperatively, and this would write a profile nix does not own. Persistent → modules/nixos/packages.nix (system) or modules/home/default.nix (user), then hand the switch over. One-off → nix shell nixpkgs#<pkg> -c <cmd>. Per-project → devenv.nix." ;;
    esac

    # "never hand-activate a venv" — uv is the only route to an interpreter here.
    case $cmd in
    *"bin/activate"*)
      deny "law 1 for Python: activating a venv by hand puts an interpreter on PATH that nothing declares. Use uv run / uv run -m / uvx, or uv add and uv sync inside a project." ;;
    esac

    # "never `> tmp && mv tmp f`" — the half of that rule with teeth is the
    # narrower `cmd f > f`, where the shell truncates f before the reader opens
    # it and the contents are gone with no error. Detected by pulling the last
    # real `>` target (>> and 2>&1 do not match) and asking whether that same
    # word appears in the part of the command before it. Gated on the target
    # already existing: creating a new file destroys nothing, and the check would
    # rather miss than block a legitimate write.
    tgt=$(printf '%s' "$cmd" | sed -n 's/^.*[^>&]>[[:space:]]*\([^[:space:];|&<>]\{1,\}\).*$/\1/p')
    if [ -n "$tgt" ]; then
      bef=$(printf '%s' "$cmd" | sed -n 's/^\(.*[^>&]\)>[[:space:]]*[^[:space:];|&<>]\{1,\}.*$/\1/p')
      case " $bef " in
      *" $tgt "*)
        if [ -e "$tgt" ] || { [ -n "$cwd" ] && [ -e "$cwd/$tgt" ]; }; then
          deny "'$tgt' is both an input and the redirect target: the shell truncates it before the command reads it, so the file is emptied and the command sees nothing. Edit in place with | sponge instead."
        fi
        ;;
      esac
    fi
    exit 0
  '';

  # "New files must be `git add`ed first or the flake cannot see them." Verified
  # 2026-08-22: a referenced-but-untracked module fails with `error: Path '…' in
  # the repository "/etc/nixos" is not tracked by Git`. That message names the
  # file but not the fix, and the fix is non-obvious in a colocated repo, where
  # jj already considers the file tracked and only the git index is behind. So
  # this denies early and says the command to run.
  untrackedNixGuard = pkgs.writeShellScript "claude-guard-untracked-nix" ''
    ${guardPreamble}
    case "$cwd" in
    /etc/nixos | /etc/nixos/*) ;;
    *) exit 0 ;;
    esac
    files=$(git -C /etc/nixos ls-files --others --exclude-standard -- '*.nix' 2>/dev/null)
    [ -n "$files" ] || exit 0
    ${jq} -n --arg f "$files" '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: ("the flake reads the git tree, so an untracked .nix is invisible to it and evaluation fails on the first module that imports one. Run `git add` on these first:\n" + $f)
      }
    }'
  '';

  mkHook =
    {
      if_,
      command,
      timeout,
      statusMessage,
    }:
    {
      type = "command";
      "if" = if_;
      command = "${command}";
      inherit timeout statusMessage;
    };

  settings = {
    # Law 3. A forgotten -m now fails fast instead of hanging on a GUI window.
    # This does not reach jj's builtin DIFF editor; those forms are denied below.
    env = {
      JJ_EDITOR = "false";
      GIT_EDITOR = "false";
      EDITOR = "false";
      VISUAL = "false";
    };

    hooks = {
      PreToolUse = [
        {
          matcher = "Bash";
          hooks = [
            (mkHook {
              if_ = "Bash(git commit *)";
              command = colocatedCommitGuard;
              timeout = 10;
              statusMessage = "Checking for a colocated repo";
            })
            (mkHook {
              if_ = "Bash(jj commit *)";
              command = publishGate;
              timeout = 180;
              statusMessage = "Gating the commit on gitleaks + nix flake check";
            })
            (mkHook {
              if_ = "Bash(jj git push *)";
              command = publishGate;
              timeout = 180;
              statusMessage = "Gating the push on gitleaks + nix flake check";
            })
            (mkHook {
              if_ = "Bash(nh os build *)";
              command = untrackedNixGuard;
              timeout = 10;
              statusMessage = "Checking for untracked nix files";
            })
            (mkHook {
              if_ = "Bash(nix flake check *)";
              command = untrackedNixGuard;
              timeout = 10;
              statusMessage = "Checking for untracked nix files";
            })
            {
              type = "command";
              command = "${commandShapeGuard}";
              timeout = 10;
              statusMessage = "Checking the command shape";
            }
          ];
        }
      ];

      PostToolUse = [
        {
          matcher = "Write|Edit";
          hooks = [
            {
              type = "command";
              command = "${shellcheckGate}";
              timeout = 20;
              statusMessage = "Linting the shell file just written";
            }
          ];
        }
        {
          matcher = "Bash";
          hooks = [
            (mkHook {
              if_ = "Bash(nh *)";
              command = conventionsCheck;
              timeout = 30;
              statusMessage = "Checking machine conventions";
            })
          ];
        }
      ];
    };

    permissions = {
      # The reading half of the workflow. Sessions start in auto mode, where a
      # classifier reviews shell commands in place of a prompt; an allow rule
      # resolves before that runs, so this moves reading off the reviewed path
      # and leaves review for calls that change something. Derived rather than
      # imagined: `jq` over the Bash calls in ~/.claude/projects, split on shell
      # separators and counted by binary.
      #
      # What Claude Code already treats as read-only (ls, cat, head, tail, grep,
      # find, wc, diff, stat, and git's read-only forms) is deliberately absent —
      # a rule there would restate a decision made elsewhere.
      #
      # Three the counts argued for and safety did not. `sed -n` appeared ~700
      # times, but -n does not stop sed's `w` command writing a file.
      # `devenv shell --` was the single most common command in the transcripts,
      # and it runs whatever follows it, which Claude Code documents as unsafe to
      # allowlist. `awk` can redirect from inside its own program.
      #
      # Not included either: `Bash(* --version)` and `Bash(* --help *)`, which law
      # 6 would otherwise want. Auto mode drops leading-wildcard allow rules as
      # broad grants of execution, so they would be dead weight and misleading.
      allow = [
        "Bash(jj)"
        "Bash(jj st *)"
        "Bash(jj log *)"
        "Bash(jj diff *)"
        "Bash(jj show *)"
        "Bash(jj file list *)"
        "Bash(jj file show *)"
        "Bash(jj op log *)"
        "Bash(jj bookmark list *)"
        "Bash(rg *)"
        "Bash(fd *)"
        "Bash(jq *)"
        "Bash(nix eval *)"
        "Bash(nix flake check *)"
        "Bash(nix flake metadata *)"
        "Bash(nix flake show *)"
        "Bash(nh os build *)"
        "Bash(bash ~/.claude/check-conventions.sh)"
      ];

      # A smell to watch, not a rule to enforce: an allow rule that needs deny rules
      # to fence it was too wide to begin with. `Bash(fd *)` granted everything fd
      # can do, `-x` included, and six patterns below subtract that back out —
      # argument-position matching, which Claude Code's own docs call fragile. The
      # same shape is latent in `Bash(rg *)`, since `rg --pre` also executes. Both
      # are left as they are; the fence works and is tested. But prefer allowing the
      # specific invocations actually run over allowing a tool and subtracting from
      # it, because a contract is tight when it accepts the least it needs.
      #
      # Two categories deliberately absent from this list. It does not deny what
      # the machine already refuses: `command not found` is the wall for pip,
      # python3, node, cargo and wget, and a rule there would be a second copy of
      # a fact the machine states better (laws 2 and 6). And it does not deny
      # preferences — `rg` over `grep -r`, `fd` over `find`, `| sponge` over
      # `> tmp && mv` — because ignoring those costs a slower search and nothing
      # else. Observability is necessary and not sufficient: a wall is worth a
      # round trip only when the violation costs something you cannot get back.
      deny = [
        # hosts/*/hardware-configuration.nix is generated by
        # nixos-generate-config, and tools.json has said "never hand-edited" all
        # along — but prose does not stop tooling: a `deadnix --edit` pass
        # stripped an unused argument from it twice within ten minutes
        # (2026-08). Note what this does and does not do. It blocks Claude's
        # file tools; it does not block `sed -i` from a shell, and it does not
        # block an editor extension. default.nix and disko.nix beside it are
        # hand-written and must stay editable, hence the exact filename rather
        # than the directory.
        "Edit(//etc/nixos/hosts/*/hardware-configuration.nix)"
      ]
      # Everything the inventory marks interactive. Four rules today; the list
      # is whatever tools.json says it is.
      ++ tuiDenies
      ++ [
        # `fd -x/-X` runs arbitrary commands and is idiomatic enough to type by
        # accident; `nix eval --write-to` writes a directory. Both tools are
        # allow-listed above and deny beats allow, so the pair composes. Two
        # position variants each, because a trailing ` *` will not match a flag
        # sitting immediately after the command name.
        "Bash(fd -x *)"
        "Bash(fd -X *)"
        "Bash(fd --exec*)"
        "Bash(fd * -x *)"
        "Bash(fd * -X *)"
        "Bash(fd * --exec*)"
        "Bash(nix eval --write-to*)"
        "Bash(nix eval * --write-to*)"

        # jj's DIFF editor, which the env guard above does not reach. Bare
        # `jj split` and bare `jj resolve` open it; `jj split <paths>` and
        # `jj resolve --list` are non-interactive and stay available, hence the
        # exact-match form for those two.
        "Bash(jj split)"
        "Bash(jj resolve)"
        "Bash(jj diffedit *)"
        "Bash(jj * -i *)"
        "Bash(jj * --interactive *)"

        # `sg` here is util-linux's setgid wrapper, not ast-grep. It exists, it
        # runs, and it does something entirely different — the worst shape a
        # typo can have.
        "Bash(sg *)"

        # Reaches a sudo prompt no Claude session can answer (law 3). Denying it
        # turns a confusing `sudo: a terminal is required` after a full build
        # into an immediate hand-off.
        "Bash(nh os switch *)"
      ];
    };
  };
in
{
  # One accepted cost of the deny patterns: `Bash(btop *)` also blocks
  # `btop --version`, which law 6 otherwise recommends. Deny beats allow, so no
  # exception can be carved back out, and a pattern cannot express "every
  # invocation except the informational flags". Versions for those come from
  # tools.json or `nix eval` instead.
  #
  # And the caveat that applies to the whole file: a deny rule matches what
  # Claude's own tools run. It does not follow `direnv exec`, `devbox run`, or a
  # script that calls the same command a level down. It narrows the way in, it
  # does not seal it.
  environment.etc."claude-code/managed-settings.json".source =
    (pkgs.formats.json { }).generate "managed-settings.json"
      settings;
}
