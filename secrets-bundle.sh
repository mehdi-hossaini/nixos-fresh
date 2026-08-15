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
# wallet that cannot be opened, and `gh` and secretspec will both come up empty
# even though the files are present. Use the same password, or plan to re-auth
# those two.
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

	# KWallet. The gh token and every secretspec secret live in here. See the
	# login-password caveat above.
	.local/share/kwalletd

	# Claude Code: the credential, and the config that records you have already
	# onboarded. NOT the rest of ~/.claude — history, projects and caches are
	# machine-local noise and would bloat the bundle for nothing.
	.claude/.credentials.json
	.claude/.claude.json

	# Only present if you actually use gpg; skipped with a warning otherwise.
	.gnupg
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

# Populates PRESENT and MISSING from PATHS.
scan() {
	PRESENT=()
	MISSING=()
	local p
	for p in "${PATHS[@]}"; do
		if [ -e "$HOME/$p" ]; then
			PRESENT+=("$p")
		else
			MISSING+=("$p")
		fi
	done
}

cmd_list() {
	scan
	say "Would be included"
	if [ "${#PRESENT[@]}" -eq 0 ]; then
		note "(nothing — is this the right account?)"
	else
		local p
		for p in "${PRESENT[@]}"; do
			printf '      %-32s %s\n' "$p" "$(du -sh "$HOME/$p" 2>/dev/null | cut -f1)"
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
