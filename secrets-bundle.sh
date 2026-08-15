#!/usr/bin/env bash
# Build the encrypted credential bundle that `installer.sh --secrets` restores.
#
# Run this on a machine that already works, writing to removable media:
#
#     ./secrets-bundle.sh create /run/media/$USER/USB/secrets.age
#     ./secrets-bundle.sh list                  # what would go in, and what is missing
#
# WHY THIS EXISTS
#
# Everything else in this repo is declarative, so a fresh install comes up
# configured. Credentials cannot work that way: no amount of Nix creates an SSH
# private key that GitHub already trusts. They have to be carried. This is the
# carrying mechanism, deliberately kept outside git — the repo's rule that it
# contains nothing secret still holds, and a bundle on a USB stick is a thing
# you can physically destroy.
#
# It carries two kinds of thing. Credentials, at fixed paths, listed in PATHS.
# And project .env files, which are found rather than listed because they live
# wherever the projects do. Those are gitignored by design, which means they
# exist on exactly one disk and a reinstall is the last time you see them —
# `list` prints them separately so you always read what you are carrying.
#
# ENCRYPTION
#
# age in passphrase mode (`age -p`, scrypt). Not a keypair, on purpose: a
# keypair would need its own private key delivered to the new machine first,
# which is the problem this is supposed to solve. A passphrase you remember has
# no bootstrap.
#
# THE KWALLET CAVEAT — read this one
#
# ~/.local/share/kwalletd is encrypted with your LOGIN PASSWORD. Restoring it
# onto a machine where you choose a different password during install leaves a
# wallet that cannot be opened, and `gh` comes up unauthenticated even though
# the files are present. Use the same password, or plan to re-run `gh auth
# login`. The .env files and the SSH key are unaffected — they are plain files
# and do not go through the wallet.
set -euo pipefail

# Home-relative paths. Everything here is either a secret or the small amount of
# state that makes a secret usable (which GitHub account, which known hosts).
# Missing entries are skipped with a warning, so this list can be a superset.
PATHS=(
	# SSH private key, public key and known_hosts. The key GitHub already
	# trusts — carrying it is what removes "generate a key, paste it into
	# github.com/settings/keys" from the first-boot checklist entirely.
	.ssh

	# gh stores no token here (git_protocol: ssh, the token is in KWallet);
	# what this holds is which account you are, which gh needs to know before
	# the token means anything.
	.config/gh

	# KWallet. This is where the gh token actually lives — hosts.yml above holds
	# only the account name. Any secretspec secret would land here too, though
	# nothing on this system uses secretspec today. Login-password caveat above.
	.local/share/kwalletd

	# Claude Code: the credential, and the config that records you have already
	# onboarded. NOT the rest of ~/.claude — history, projects and caches are
	# machine-local noise and would bloat the bundle for nothing.
	.claude/.credentials.json
	.claude/.claude.json

	# Only present if you actually use gpg; skipped with a warning otherwise.
	.gnupg
)

# Project .env files are found rather than listed: they live at paths only the
# projects know, and a fixed list goes stale the first time you start a new one.
#
# Only these roots are scanned, and the reason is impermanence rather than
# speed. A restored file is written to /persistent/userdata/home/<user>/<path>,
# so it only survives the first boot if <path> is inside a persisted directory.
# Projects/ and Desktop/ are; anything else in $HOME is not, and carrying a
# secret to a location that gets wiped is worse than not carrying it.
ENV_ROOTS=(
	Projects
	Desktop
)

# Excluded from the scan. .git and the build/vendor directories because a match
# in there belongs to a dependency, not to you; .Trash-* because a deleted
# project's secrets should stay deleted.
ENV_PRUNE=(
	.git
	.direnv
	.devenv
	node_modules
	.venv
	__pycache__
	target
	'.Trash-*'
)

die() {
	printf '\n[ERROR] %s\n' "$*" >&2
	exit 1
}
say() { printf '\n\033[1m==>\033[0m %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }

# age is in systemPackages, but this script is also useful from a live ISO where
# it is not. Same fallback shape installer.sh uses for mkpasswd.
run_age() {
	if command -v age >/dev/null 2>&1; then
		age "$@"
	else
		nix --extra-experimental-features "nix-command flakes" \
			shell nixpkgs#age -c age "$@"
	fi
}

# Home-relative paths of every project .env found under ENV_ROOTS.
#
# .env.example and friends are excluded: they are templates with placeholder
# values, they are committed to the repo already, and including them would put
# the word "example" next to real secrets in the bundle listing, which is
# exactly the confusion you do not want when auditing what you are carrying.
discover_env_files() {
	ENV_FILES=()
	local root f prune=()
	# Build the -prune expression: ( -name a -o -name b -o ... )
	local p first=1
	for p in "${ENV_PRUNE[@]}"; do
		if [ "$first" = 1 ]; then
			prune=(-name "$p")
			first=0
		else
			prune+=(-o -name "$p")
		fi
	done

	for root in "${ENV_ROOTS[@]}"; do
		[ -d "$HOME/$root" ] || continue
		while IFS= read -r -d '' f; do
			ENV_FILES+=("${f#"$HOME/"}")
		done < <(
			find "$HOME/$root" -maxdepth 6 \
				\( "${prune[@]}" \) -prune -o \
				\( -type f \( -name '.env' -o -name '.env.*' \) \
				! -name '*.example' ! -name '*.sample' ! -name '*.template' \) \
				-print0 2>/dev/null
		)
	done
}

# Populates FIXED_PRESENT, MISSING, ENV_FILES and the combined PRESENT.
scan() {
	FIXED_PRESENT=()
	MISSING=()
	local p
	for p in "${PATHS[@]}"; do
		if [ -e "$HOME/$p" ]; then
			FIXED_PRESENT+=("$p")
		else
			MISSING+=("$p")
		fi
	done
	discover_env_files
	PRESENT=(
		${FIXED_PRESENT[@]+"${FIXED_PRESENT[@]}"}
		${ENV_FILES[@]+"${ENV_FILES[@]}"}
	)
}

cmd_list() {
	scan
	local p

	say "Credentials"
	if [ "${#FIXED_PRESENT[@]}" -eq 0 ]; then
		note "(nothing — is this the right account?)"
	else
		for p in "${FIXED_PRESENT[@]}"; do
			printf '      %-40s %s\n' "$p" "$(du -sh "$HOME/$p" 2>/dev/null | cut -f1)"
		done
	fi

	# Listed separately and never folded into the count above: these are found,
	# not declared, so the only way to know what you are about to carry is to
	# read them off. Check this list before every `create`.
	say "Project .env files (found under: ${ENV_ROOTS[*]})"
	if [ "${#ENV_FILES[@]}" -eq 0 ]; then
		note "(none found)"
	else
		for p in "${ENV_FILES[@]}"; do
			printf '      %-40s %s\n' "$p" "$(du -sh "$HOME/$p" 2>/dev/null | cut -f1)"
		done
	fi

	if [ "${#MISSING[@]}" -gt 0 ]; then
		say "Not present on this machine, will be skipped"
		printf '      %s\n' "${MISSING[@]}"
	fi
}

cmd_create() {
	local out="${1-}"
	[ -n "$out" ] || die "usage: $0 create <output.age>"
	[ -e "$out" ] && die "$out already exists — refusing to overwrite a bundle"

	local out_dir
	out_dir="$(dirname -- "$out")"
	[ -d "$out_dir" ] || die "$out_dir does not exist (is the USB stick mounted?)"

	scan
	[ "${#PRESENT[@]}" -gt 0 ] || die "none of the listed paths exist under $HOME"

	cmd_list

	say "Encrypting"
	note "age will ask for a passphrase — this is what you type at install time,"
	note "and there is no recovery if you forget it."

	# 0600 from the start: the bundle must never exist world-readable, not even
	# for the moment between creation and chmod.
	umask 077
	# -p is scrypt/passphrase mode. Ownership and modes are preserved by -p on
	# the tar side so .ssh comes back as 0700 with 0600 keys.
	tar -cpf - -C "$HOME" -- "${PRESENT[@]}" | run_age -p -o "$out"
	chmod 0600 "$out"

	say "Done"
	note "$out  ($(du -sh "$out" | cut -f1))"
	note ""
	note "Restore it on a new machine with:"
	note "    sudo ./installer.sh <hostname> --secrets /path/to/$(basename "$out")"
	note ""
	note "Keep it on removable media. It is every credential you have."
}

case "${1-}" in
create)
	shift
	cmd_create "$@"
	;;
list)
	cmd_list
	;;
*)
	cat >&2 <<-EOF
		usage: $0 create <output.age>   build the bundle
		       $0 list                  show what would go in it
	EOF
	exit 2
	;;
esac
