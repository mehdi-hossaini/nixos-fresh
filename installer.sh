#!/usr/bin/env bash
# Portable NixOS install — KDE Plasma 6, impermanent root, full-disk encryption.
#
# Run from a NixOS live ISO, as root, from inside a clone of this repo:
#
#     sudo ./installer.sh [hostname] [--secrets /path/to/secrets.age]
#
# Two paths, and which one you get depends only on whether hosts/<hostname>/
# already exists:
#
#   REINSTALL — the directory exists. Its disko.nix is used exactly as
#               committed. Nothing in it is rewritten; the disks it names are
#               checked against this machine before anything is erased.
#
#   NEW HOST  — the directory does not exist. You pick a layout and the disks,
#               the script detects CPU and RAM, and hosts/<hostname>/ is
#               written from templates/host/. Commit it afterwards.
#
# The predecessor of this script rewrote disko.nix in place with sed, which
# worked exactly once: after the first install the file held real device paths
# and the placeholder substitution silently matched nothing, so a second run on
# a different machine would have formatted whatever the first machine's disks
# were called. Host directories exist to make that unrepresentable.
#
# --secrets restores the bundle built by secrets-bundle.sh: SSH key, gh account,
# KWallet, Claude Code credential. With it the machine is usable the moment it
# boots; without it you get a correctly configured machine that is logged in to
# nothing. Everything else in this repo is declarative, but credentials cannot
# be — no amount of Nix produces a private key GitHub already trusts.
#
# DESTRUCTIVE. Every disk named in hosts/<hostname>/disko.nix is repartitioned.
# Nothing is backed up.
set -euo pipefail

NIX_FLAGS=(--extra-experimental-features "nix-command flakes")
FLAKE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

die() {
	printf '\n[ERROR] %s\n' "$*" >&2
	exit 1
}
say() { printf '\n\033[1m==>\033[0m %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
ask() {
	local prompt="$1" default="${2-}" reply
	if [ -n "$default" ]; then
		read -r -p "$prompt [$default]: " reply
		printf '%s' "${reply:-$default}"
	else
		read -r -p "$prompt: " reply
		printf '%s' "$reply"
	fi
}
# git, tolerant of the live ISO's "dubious ownership" complaint about a clone
# made by a different user than the root shell running this.
git_() { git -c safe.directory="$FLAKE_DIR" -C "$FLAKE_DIR" "$@"; }
have_git() { [ -d "$FLAKE_DIR/.git" ] && command -v git >/dev/null 2>&1; }

# The live ISO has no age. Same fallback shape as hash_password below.
run_age() {
	if command -v age >/dev/null 2>&1; then
		age "$@"
	else
		nix "${NIX_FLAGS[@]}" shell nixpkgs#age -c age "$@"
	fi
}

# ── Arguments ────────────────────────────────────────────────────────────
SECRETS_BUNDLE=""
POSITIONAL=()
while [ $# -gt 0 ]; do
	case "$1" in
	--secrets)
		SECRETS_BUNDLE="${2-}"
		[ -n "$SECRETS_BUNDLE" ] || die "--secrets needs a path"
		shift 2
		;;
	--secrets=*)
		SECRETS_BUNDLE="${1#*=}"
		shift
		;;
	-h | --help)
		sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed 's/^# \?//;$d'
		exit 0
		;;
	-*)
		die "unknown option: $1"
		;;
	*)
		POSITIONAL+=("$1")
		shift
		;;
	esac
done
set -- ${POSITIONAL[@]+"${POSITIONAL[@]}"}

# ── Preflight ────────────────────────────────────────────────────────────
[ "$(id -u)" -eq 0 ] || die "must run as root (sudo ./installer.sh)"
[ -d /sys/firmware/efi ] || die "not booted in UEFI mode — this layout is GPT/ESP only"
for f in flake.nix identity.nix modules/nixos/default.nix templates/host/default.nix; do
	[ -e "$FLAKE_DIR/$f" ] || die "$f missing — run this script from inside the config directory"
done

# Checked here rather than at restore time, which is after the disks are gone.
# A typo'd USB path should cost you a retry, not an install.
if [ -n "$SECRETS_BUNDLE" ]; then
	[ -f "$SECRETS_BUNDLE" ] || die "--secrets $SECRETS_BUNDLE is not a file"
	[ -s "$SECRETS_BUNDLE" ] || die "--secrets $SECRETS_BUNDLE is empty"
fi

# A flake only sees git-tracked files. An untracked host directory evaluates to
# nothing, or fails — either way you find out after the disk is gone. Checked
# BEFORE this script creates any files of its own; the ones it creates are
# staged for you further down.
# (Staged-but-uncommitted changes are fine: flakes copy tracked files from the
# working tree, so only untracked files are actually invisible to evaluation.)
if have_git; then
	if [ -n "$(git_ ls-files --others --exclude-standard)" ]; then
		die "$FLAKE_DIR is a git repo with untracked files.
       Flake evaluation ignores them. Run:  git -C '$FLAKE_DIR' add -A"
	fi
fi

# ── Which host ───────────────────────────────────────────────────────────
say "Hosts defined in this config"
for d in "$FLAKE_DIR"/hosts/*/; do
	[ -d "$d" ] || continue
	note "$(basename "$d")"
done
[ -n "$(ls -A "$FLAKE_DIR/hosts" 2>/dev/null)" ] || note "(none yet)"

HOST="${1-}"
[ -n "$HOST" ] || HOST="$(ask "  Hostname to install")"
[ -n "$HOST" ] || die "no hostname given"
# The directory name becomes networking.hostName and the flake attribute, so it
# has to be a legal hostname as well as a legal path component.
[[ "$HOST" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] ||
	die "'$HOST' is not a valid hostname (lowercase letters, digits and hyphens; must not start or end with a hyphen)"

HOST_DIR="$FLAKE_DIR/hosts/$HOST"

# ── New host: build hosts/<name>/ from the templates ─────────────────────
if [ -d "$HOST_DIR" ]; then
	say "Reinstalling existing host '$HOST'"
	note "using hosts/$HOST/disko.nix exactly as committed"
else
	say "New host '$HOST' — choosing a disk layout"
	cat <<-EOF

	    1) two-disk    ESP + encrypted root on the main disk; swap and an
	                   encrypted /data on a second disk. Needs two disks.
	    2) single-disk ESP + swap + encrypted root, all on one disk. No /data.

	EOF
	LAYOUT_CHOICE="$(ask "  Layout" "2")"
	case "$LAYOUT_CHOICE" in
	1 | two-disk) LAYOUT="two-disk" ;;
	2 | single-disk) LAYOUT="single-disk" ;;
	*) die "unknown layout '$LAYOUT_CHOICE'" ;;
	esac

	say "Disks on this machine"
	lsblk -dno NAME,SIZE,MODEL | sed 's/^/    /'
	echo
	note "Stable /dev/disk/by-id names:"
	for link in /dev/disk/by-id/*; do
		case "$link" in
		*-part*) continue ;;
		*nvme-eui*) continue ;;
		esac
		[ -b "$link" ] || continue
		printf '      %-60s -> %s\n' "$(basename "$link")" "$(basename "$(readlink -f "$link")")"
	done

	echo
	note "MAIN disk: ESP + encrypted root (/, /nix, /persistent)."
	MAIN_ID="$(ask "  by-id name of the MAIN disk")"
	MAIN="/dev/disk/by-id/$MAIN_ID"
	[ -b "$MAIN" ] || die "$MAIN is not a block device"

	DATA=""
	if [ "$LAYOUT" = "two-disk" ]; then
		echo
		note "DATA disk: encrypted swap + encrypted /data."
		DATA_ID="$(ask "  by-id name of the DATA disk")"
		DATA="/dev/disk/by-id/$DATA_ID"
		[ -b "$DATA" ] || die "$DATA is not a block device"
		[ "$(readlink -f "$MAIN")" != "$(readlink -f "$DATA")" ] ||
			die "MAIN and DATA are the same disk"
		SWAP_DEFAULT="64G"
	else
		# Hibernation is off, so swap never has to hold an image of RAM. This
		# only takes what zram overflows.
		SWAP_DEFAULT="16G"
	fi
	SWAP_SIZE="$(ask "  Swap partition size" "$SWAP_DEFAULT")"

	# CPU and RAM, so machine.nix can derive the build and memory tuning. Read
	# from this machine because this machine is the one being installed onto.
	THREADS="$(nproc)"
	MEMORY_GIB="$(awk '/^MemTotal:/ { print int($2 / 1048576) }' /proc/meminfo)"
	[ "${MEMORY_GIB:-0}" -ge 1 ] || die "could not read MemTotal from /proc/meminfo"
	if [ "$LAYOUT" = "two-disk" ]; then HAS_DATA_DISK="true"; else HAS_DATA_DISK="false"; fi

	say "Writing hosts/$HOST"
	mkdir -p "$HOST_DIR"
	sed -e "s|@MAIN_DISK@|$MAIN|g" \
		-e "s|@DATA_DISK@|$DATA|g" \
		-e "s|@SWAP_SIZE@|$SWAP_SIZE|g" \
		"$FLAKE_DIR/templates/host/$LAYOUT/disko.nix" >"$HOST_DIR/disko.nix"
	# The three machine.* placeholders are quoted in the template so it stays
	# parseable Nix; the quotes are part of what gets replaced, because these
	# options are an int, an int and a bool.
	sed -e "s|@HOSTNAME@|$HOST|g" \
		-e "s|\"@THREADS@\"|$THREADS|g" \
		-e "s|\"@MEMORY_GIB@\"|$MEMORY_GIB|g" \
		-e "s|\"@HAS_DATA_DISK@\"|$HAS_DATA_DISK|g" \
		"$FLAKE_DIR/templates/host/default.nix" >"$HOST_DIR/default.nix"

	# The guard the old script only appeared to have. It runs against a freshly
	# copied template, so an unsubstituted placeholder is a real failure rather
	# than the expected state of an already-installed file.
	if grep -REn '@[A-Z_]+@' "$HOST_DIR"; then
		die "hosts/$HOST still contains unsubstituted placeholders (listed above)"
	fi

	note "layout:  $LAYOUT"
	note "cpu/ram: $THREADS threads, $MEMORY_GIB GiB"
	note "review hosts/$HOST/default.nix after the install — an NVIDIA laptop"
	note "needs a GPU block there, and nothing else does"
fi

# ── Hardware config ──────────────────────────────────────────────────────
# --no-filesystems: disko owns every fileSystems/swapDevices entry. A second
# definition from here collides and fails eval.
say "Detecting hardware"
nixos-generate-config --no-filesystems --show-hardware-config >"$HOST_DIR/hardware-configuration.nix"
note "wrote hosts/$HOST/hardware-configuration.nix"

# ── Make the new files visible to flake evaluation ───────────────────────
if have_git; then
	say "Staging hosts/$HOST so the flake can see it"
	git_ add -A
fi

# ── Sanity-check the layout against this machine ─────────────────────────
# The check that would have caught the old sed bug: whatever disko.nix names,
# this machine must actually have. For a reinstall these paths come from the
# committed file and have never been validated against the hardware in front
# of you.
say "Checking the disks hosts/$HOST/disko.nix names"
mapfile -t DISKS < <(sed -n 's/.*device = "\([^"]*\)".*/\1/p' "$HOST_DIR/disko.nix")
[ "${#DISKS[@]}" -gt 0 ] || die "no device paths found in hosts/$HOST/disko.nix"
for d in "${DISKS[@]}"; do
	[ -b "$d" ] || die "hosts/$HOST/disko.nix names $d, which is not a block device on this machine.
       This is the right failure: that file describes a different computer.
       Install under a new hostname instead — sudo ./installer.sh <new-name>"
	printf '      %-60s -> %s (%s)\n' "$d" "$(basename "$(readlink -f "$d")")" "$(lsblk -dno SIZE "$(readlink -f "$d")" | tr -d ' ')"
done

# Which secrets are needed follows from the layout, not from a flag passed
# around: a data disk exists iff the file declares a cryptdata container.
NEEDS_DATA_KEY=false
grep -q 'name = "cryptdata"' "$HOST_DIR/disko.nix" && NEEDS_DATA_KEY=true

# ── Confirm ──────────────────────────────────────────────────────────────
cat <<EOF

  ────────────────────────────────────────────────────────────────────
   ABOUT TO ERASE, COMPLETELY AND WITHOUT BACKUP:

$(printf '     %s\n' "${DISKS[@]}")

     Installing: $HOST
  ────────────────────────────────────────────────────────────────────

EOF
CONFIRM="$(ask "  Type ERASE $HOST to continue")"
[ "$CONFIRM" = "ERASE $HOST" ] || die "aborted — nothing was written"

# ── Password hash ────────────────────────────────────────────────────────
# Never enters git or the Nix store; written to /persistent/system/secrets.
# Read straight out of identity.nix rather than through `nix eval`: this is a
# prompt label, and nothing should have to evaluate to print one.
USER_NAME="$(sed -n 's/^[[:space:]]*user[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$FLAKE_DIR/identity.nix")"
[ -n "$USER_NAME" ] || die "could not read the user name out of identity.nix"
say "Password for user '$USER_NAME'"
if [ -n "$SECRETS_BUNDLE" ]; then
	note "The bundle contains KWallet, which is encrypted with your LOGIN"
	note "PASSWORD. Type the SAME password you use on the machine the bundle"
	note "came from, or the wallet will restore intact and refuse to open —"
	note "and gh and secretspec will both come up with no secrets."
	echo
fi
hash_password() {
	if command -v mkpasswd >/dev/null 2>&1; then
		mkpasswd -m sha-512
	elif command -v openssl >/dev/null 2>&1; then
		openssl passwd -6 -stdin
	else
		nix "${NIX_FLAGS[@]}" shell nixpkgs#mkpasswd -c mkpasswd -m sha-512
	fi
}
while :; do
	read -r -s -p "  Password: " P1 && echo
	read -r -s -p "  Again:    " P2 && echo
	[ -n "$P1" ] || {
		echo "  empty, try again"
		continue
	}
	[ "$P1" = "$P2" ] && break
	echo "  mismatch, try again"
done
PW_HASH="$(printf '%s' "$P1" | hash_password)"
unset P1 P2
[ -n "$PW_HASH" ] || die "password hashing produced nothing"

# ── Data-disk keyfile ────────────────────────────────────────────────────
# 64 random bytes. disko uses it to format cryptdata; it then lives on the
# encrypted root at /persistent/system/secrets/cryptdata.key, where crypttab
# reads it after switch-root. That is why there is only one passphrase prompt.
umask 077
if [ "$NEEDS_DATA_KEY" = true ]; then
	say "Generating data-disk keyfile"
	dd if=/dev/urandom of=/tmp/cryptdata.key bs=64 count=1 status=none
	chmod 0400 /tmp/cryptdata.key
fi

# ── Dry run, then partition ──────────────────────────────────────────────
say "Dry run (nothing is written)"
nix "${NIX_FLAGS[@]}" run github:nix-community/disko -- \
	--mode destroy,format,mount --dry-run "$HOST_DIR/disko.nix" >/dev/null
note "layout is valid"

say "Partitioning — you will be asked to SET the disk passphrase now"
note "(this is the passphrase you will type at every boot)"
nix "${NIX_FLAGS[@]}" run github:nix-community/disko -- \
	--mode destroy,format,mount "$HOST_DIR/disko.nix"

mountpoint -q /mnt || die "disko finished but /mnt is not mounted"

# ── The blank snapshot impermanence rolls back to ────────────────────────
# Taken NOW, while @root is empty. Every boot deletes @root and re-snapshots
# this. If it is taken later it captures whatever nixos-install wrote, and the
# rollback stops rolling anything back.
say "Creating @root-blank snapshot"
mkdir -p /mnt-btrfs
mount -o subvolid=5 /dev/mapper/cryptroot /mnt-btrfs
btrfs subvolume snapshot -r /mnt-btrfs/@root /mnt-btrfs/@root-blank
umount /mnt-btrfs
rmdir /mnt-btrfs

# ── Secrets onto the persistent volume ───────────────────────────────────
say "Writing secrets to /persistent/system/secrets"
install -d -m 0700 /mnt/persistent/system/secrets
printf '%s\n' "$PW_HASH" >/mnt/persistent/system/secrets/user-password
chmod 0600 /mnt/persistent/system/secrets/user-password
if [ "$NEEDS_DATA_KEY" = true ]; then
	install -m 0400 /tmp/cryptdata.key /mnt/persistent/system/secrets/cryptdata.key
fi

# ── Config onto the persistent volume ────────────────────────────────────
# NOT /mnt/etc/nixos: that lives on @root, which the first boot wipes.
# /persistent/system/etc/nixos is what impermanence bind-mounts to /etc/nixos.
#
# .git comes along, unlike in the previous version of this script. The repo has
# no secrets in it by construction, and carrying it means the installed system
# has its remote and its history already — there is nothing to graft afterwards.
say "Installing config to /persistent/system/etc/nixos"
install -d -m 0755 /mnt/persistent/system/etc/nixos
cp -rT "$FLAKE_DIR" /mnt/persistent/system/etc/nixos

# ── Install ──────────────────────────────────────────────────────────────
say "Building and installing (this takes a while)"
nixos-install \
	--flake "/mnt/persistent/system/etc/nixos#$HOST" \
	--no-root-password

if [ "$NEEDS_DATA_KEY" = true ]; then
	shred -u /tmp/cryptdata.key 2>/dev/null || rm -f /tmp/cryptdata.key
fi

# ── Credential bundle ────────────────────────────────────────────────────
# AFTER nixos-install on purpose: the user does not exist until activation has
# run, and the restored files need that user's real uid rather than a guessed
# 1000. Impermanence maps ~/x to /persistent/userdata/home/<user>/x, so the
# bundle — which is a tar of home-relative paths — unpacks straight into there.
if [ -n "$SECRETS_BUNDLE" ]; then
	say "Restoring credentials from $(basename "$SECRETS_BUNDLE")"

	USER_HOME="/mnt/persistent/userdata/home/$USER_NAME"
	install -d -m 0700 "$USER_HOME"

	note "age will ask for the bundle passphrase"
	# -p preserves the modes inside the tar, so .ssh comes back 0700 with 0600
	# keys rather than inheriting this script's umask.
	run_age -d "$SECRETS_BUNDLE" | tar -xpf - -C "$USER_HOME"

	# nixos-install has created the user by now, so this is the authoritative
	# uid rather than an assumption about it being 1000.
	RESTORE_UID="$(awk -F: -v u="$USER_NAME" '$1 == u { print $3 }' /mnt/etc/passwd)"
	RESTORE_GID="$(awk -F: -v u="$USER_NAME" '$1 == u { print $4 }' /mnt/etc/passwd)"
	[ -n "$RESTORE_UID" ] && [ -n "$RESTORE_GID" ] ||
		die "restored the bundle but '$USER_NAME' is not in /mnt/etc/passwd — cannot set ownership.
       The files are in $USER_HOME and are owned by root. Fix before rebooting."
	chown -R "$RESTORE_UID:$RESTORE_GID" "$USER_HOME"

	note "restored as uid $RESTORE_UID:$RESTORE_GID into $USER_HOME"
fi

if [ -n "$SECRETS_BUNDLE" ]; then
	READY="ssh, gh, secretspec and Claude Code are already authenticated."
else
	READY="No credentials were restored (no --secrets). ssh, gh and Claude
   Code will each need logging in once — see POST-INSTALL.md."
fi

cat <<EOF

  ────────────────────────────────────────────────────────────────────
   Done — '$HOST' is installed. Reboot and remove the USB stick.

   At boot you get ONE passphrase prompt (the disk), then SDDM (your
   user password).

   $READY

   /etc/nixos is owned by $USER_NAME from the first boot, so git and
   nh work without sudo.

   hosts/$HOST/ is staged but NOT committed. Commit it from the
   installed system so this machine is reproducible next time:

     cd /etc/nixos && git add -A && git commit -m "add host $HOST"
  ────────────────────────────────────────────────────────────────────

EOF
