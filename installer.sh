#!/usr/bin/env bash
# Fresh NixOS install — KDE Plasma 6, impermanent root, full-disk encryption.
#
# Run from a NixOS live ISO, as root, from inside this directory:
#
#     sudo ./installer.sh
#
# It asks three things: which disks, the hostname, and your password. Everything
# else is in the flake beside this script.
#
# DESTRUCTIVE. Both disks you pick are repartitioned. Nothing is backed up.
set -euo pipefail

NIX_FLAGS=(--extra-experimental-features "nix-command flakes")
FLAKE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
HOST="nixos-machine"

die() {
	printf '\n[ERROR] %s\n' "$*" >&2
	exit 1
}
say() { printf '\n\033[1m==>\033[0m %s\n' "$*"; }
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

# ── Preflight ────────────────────────────────────────────────────────────
[ "$(id -u)" -eq 0 ] || die "must run as root (sudo ./installer.sh)"
[ -d /sys/firmware/efi ] || die "not booted in UEFI mode — this layout is GPT/ESP only"
for f in flake.nix disko.nix configuration.nix home.nix; do
	[ -f "$FLAKE_DIR/$f" ] || die "$f missing — run this script from inside the config directory"
done

# A flake only sees git-tracked files. An untracked disko.nix evaluates to the
# OLD layout, or fails — either way you find out after the disk is gone.
# (Staged-but-uncommitted changes are fine: flakes copy tracked files from the
# working tree, so only untracked files are actually invisible to evaluation.)
if [ -d "$FLAKE_DIR/.git" ]; then
	if [ -n "$(git -C "$FLAKE_DIR" ls-files --others --exclude-standard)" ]; then
		die "$FLAKE_DIR is a git repo with untracked files.
       Flake evaluation ignores them. Run:  git -C '$FLAKE_DIR' add -A"
	fi
fi

# ── Pick the disks ───────────────────────────────────────────────────────
say "Disks on this machine"
lsblk -dno NAME,SIZE,MODEL | sed 's/^/    /'
echo
echo "    Stable /dev/disk/by-id names:"
for link in /dev/disk/by-id/*; do
	case "$link" in
	*-part*) continue ;;
	*nvme-eui*) continue ;;
	esac
	[ -b "$link" ] || continue
	printf '      %-60s -> %s\n' "$(basename "$link")" "$(basename "$(readlink -f "$link")")"
done

echo
echo "  MAIN disk: ESP + encrypted root (/, /nix, /persistent)."
MAIN_ID="$(ask "  by-id name of the MAIN disk")"
echo
echo "  DATA disk: 64G encrypted swap + encrypted /data."
DATA_ID="$(ask "  by-id name of the DATA disk")"

MAIN="/dev/disk/by-id/$MAIN_ID"
DATA="/dev/disk/by-id/$DATA_ID"
[ -b "$MAIN" ] || die "$MAIN is not a block device"
[ -b "$DATA" ] || die "$DATA is not a block device"
[ "$(readlink -f "$MAIN")" != "$(readlink -f "$DATA")" ] || die "MAIN and DATA are the same disk"

# ── Hostname ─────────────────────────────────────────────────────────────
HOSTNAME_IN="$(ask "  Hostname" "$HOST")"

# ── Confirm ──────────────────────────────────────────────────────────────
cat <<EOF

  ────────────────────────────────────────────────────────────────────
   ABOUT TO ERASE, COMPLETELY AND WITHOUT BACKUP:

     MAIN  $MAIN
           -> $(readlink -f "$MAIN")  ($(lsblk -dno SIZE "$(readlink -f "$MAIN")"))
     DATA  $DATA
           -> $(readlink -f "$DATA")  ($(lsblk -dno SIZE "$(readlink -f "$DATA")"))

     Hostname: $HOSTNAME_IN
  ────────────────────────────────────────────────────────────────────

EOF
CONFIRM="$(ask "  Type ERASE BOTH DISKS to continue")"
[ "$CONFIRM" = "ERASE BOTH DISKS" ] || die "aborted — nothing was written"

# ── Password hash ────────────────────────────────────────────────────────
# Never enters git or the Nix store; written to /persistent/system/secrets.
say "Password for user 'mehti'"
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
say "Generating data-disk keyfile"
umask 077
dd if=/dev/urandom of=/tmp/cryptdata.key bs=64 count=1 status=none
chmod 0400 /tmp/cryptdata.key

# ── Point disko at the real disks ────────────────────────────────────────
say "Writing disk paths into disko.nix"
sed -i \
	-e "s|/dev/disk/by-id/CHANGE_ME_MAIN|$MAIN|" \
	-e "s|/dev/disk/by-id/CHANGE_ME_DATA|$DATA|" \
	"$FLAKE_DIR/disko.nix"
grep -Eq "CHANGE_ME_(MAIN|DATA)" "$FLAKE_DIR/disko.nix" && die "disko.nix still contains a CHANGE_ME placeholder"
sed -i "s|hostName = \"nixos-machine\"|hostName = \"$HOSTNAME_IN\"|" "$FLAKE_DIR/configuration.nix"

# ── Hardware config ──────────────────────────────────────────────────────
# --no-filesystems: disko owns every fileSystems/swapDevices entry. A second
# definition from here collides and fails eval.
say "Detecting hardware"
nixos-generate-config --no-filesystems --show-hardware-config >"$FLAKE_DIR/hardware-configuration.nix"

# ── Dry run, then partition ──────────────────────────────────────────────
say "Dry run (nothing is written)"
nix "${NIX_FLAGS[@]}" run github:nix-community/disko -- \
	--mode destroy,format,mount --dry-run "$FLAKE_DIR/disko.nix" >/dev/null
echo "    layout is valid"

say "Partitioning — you will be asked to SET the disk passphrase now"
echo "    (this is the passphrase you will type at every boot)"
nix "${NIX_FLAGS[@]}" run github:nix-community/disko -- \
	--mode destroy,format,mount "$FLAKE_DIR/disko.nix"

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
install -m 0400 /tmp/cryptdata.key /mnt/persistent/system/secrets/cryptdata.key

# ── Config onto the persistent volume ────────────────────────────────────
# NOT /mnt/etc/nixos: that lives on @root, which the first boot wipes.
# /persistent/system/etc/nixos is what impermanence bind-mounts to /etc/nixos.
say "Installing config to /persistent/system/etc/nixos"
install -d -m 0755 /mnt/persistent/system/etc/nixos
cp -rT "$FLAKE_DIR" /mnt/persistent/system/etc/nixos
rm -rf /mnt/persistent/system/etc/nixos/.git

# ── Install ──────────────────────────────────────────────────────────────
say "Building and installing (this takes a while)"
nixos-install \
	--flake "/mnt/persistent/system/etc/nixos#$HOST" \
	--no-root-password

shred -u /tmp/cryptdata.key 2>/dev/null || rm -f /tmp/cryptdata.key

cat <<EOF

  ────────────────────────────────────────────────────────────────────
   Done. Reboot and remove the USB stick.

   At boot you get ONE passphrase prompt (the disk), then SDDM (your
   user password). The data disk unlocks itself.

   Then read POST-INSTALL.md — it is at /etc/nixos/POST-INSTALL.md on
   the installed system.
  ────────────────────────────────────────────────────────────────────

EOF
