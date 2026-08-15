# After first boot

Six steps, about 10 minutes. Do them in order — both 0 and 4 need the
authentication from 3, which needs the key from 2.

## 0. Make this repo private again — DO THIS FIRST

It was flipped public so the live ISO could `git clone` it without
authenticating. Nothing secret is in it (the password hash and the LUKS keyfile
are generated at install time and never enter git), but public was a temporary
convenience, not a decision.

```sh
gh repo edit mehdi-hossaini/nixos-fresh --visibility private \
  --accept-visibility-change-consequences
```

This needs `gh auth login` first — so in practice: do step 2 and 3, then come
straight back here.

## 1. Confirm impermanence actually works

```sh
touch /tmp-test-me ~/tmp-test-me
sudo reboot
```

After the reboot both files should be gone, and `~/Projects` should still exist.
If `/tmp-test-me` survived, the rollback unit did not run:

```sh
journalctl -b -u rollback
```

The outgoing root is kept for a week as `old_roots/<timestamp>` on the btrfs
**top-level** subvolume — that is where to look for anything you lose in the
first few days. It is not `/persistent/old_roots/`: `/persistent` is its own
subvolume, and the rollback unit mounts `subvolid=5` to do the move. So reaching
it means mounting the top level yourself:

```sh
sudo mkdir -p /mnt/btrfs
sudo mount -o subvolid=5 /dev/mapper/cryptroot /mnt/btrfs
ls /mnt/btrfs/old_roots/
# ... recover what you need, then:
sudo umount /mnt/btrfs
```

## 2. SSH key

```sh
ssh-keygen -t ed25519 -C "littlemehti@gmail.com"
cat ~/.ssh/id_ed25519.pub
```

Add it at <https://github.com/settings/keys>.

## 3. GitHub CLI

```sh
gh auth login          # choose SSH, it will find the key from step 2
gh auth status
```

## 4. Commit this machine's host directory

`installer.sh` copied the whole clone to `/persistent/system/etc/nixos`,
**including `.git`** — so `/etc/nixos` is already the repo you installed from,
with its history and its remote. There is nothing to graft. What is *not* done
is the commit for this machine: the installer stages `hosts/<hostname>/` and
stops there, because a host directory describing hardware you have not booted
yet is not worth committing.

First take ownership, so `git` and `gh` use your SSH key from step 2 rather than
root's, which does not exist:

```sh
sudo chown -R mehti:users /etc/nixos
```

That trades a little safety — anything running as you can now edit the system
config without a password — for a workflow that actually functions. The
alternative is keeping it root-owned and passing your key explicitly to every
push with `sudo git -c core.sshCommand='ssh -i ~/.ssh/id_ed25519'`, which gets
old fast.

If the ISO cloned over HTTPS, point the remote at SSH so pushes use that key:

```sh
cd /etc/nixos
git remote -v                                                    # check first
git remote set-url origin git@github.com:mehdi-hossaini/nixos-fresh.git
```

Then commit the host:

```sh
cd /etc/nixos
git status                    # hosts/<hostname>/ should be staged
git commit -m "add host $(hostname)"
git push
```

Once `/etc/nixos` is yours, the `safe.directory` line in `modules/home/default.nix`
is no longer load-bearing. Leave it — it costs nothing and covers you if
ownership ever reverts to root.

## 5. secretspec

```sh
secretspec config init      # pick `keyring` — KWallet already provides it
```

Per project: `secretspec init` writes a `secretspec.toml` next to `devenv.nix`.

## 6. Rust projects

There is deliberately **no system-wide `rustc` or `cargo`**. Toolchains are
per-project, so two projects can disagree about versions. In each repo:

```nix
# devenv.nix
{ pkgs, ... }:
{
  languages.rust = {
    enable = true;
    channel = "stable";      # or read rust-toolchain.toml via toolchainFile
    mold.enable = true;      # the linker — biggest single build-time win
  };
}
```

Then `echo "use devenv" > .envrc && direnv allow`.

`sccache` and `CARGO_BUILD_JOBS` are set system-wide and apply inside devenv
shells automatically.

---

# How this config is laid out

```
flake.nix          enumerates hosts/ — no list to maintain
identity.nix       name, email, username. One of the two files to edit
                   when adopting this config
hosts/<name>/      ONE MACHINE. The only place allowed to name a disk,
  default.nix        a PCI address, a core count or a RAM size
  disko.nix
  hardware-configuration.nix
modules/nixos/     everything true on every machine
modules/home/      home-manager, same
templates/host/    what installer.sh copies to make a new hosts/<name>/
installer.sh
```

The directory name under `hosts/` **is** the hostname — `flake.nix` sets
`networking.hostName` from it, so `nixosConfigurations.<hostname>` always
exists and `nh os switch` can always find it. Renaming a machine is renaming
its directory.

A host declares three facts about itself in `hosts/<name>/default.nix`:

```nix
machine = {
  threads = 12;         # nproc
  memoryGiB = 14;       # free -g
  hasDataDisk = true;   # two-disk layout?
};
```

`nix.settings.max-jobs`, `nix.settings.cores`, `CARGO_BUILD_JOBS`,
`zramSwap.memoryPercent` and the `/etc/crypttab` entry are all derived from
those — see `modules/nixos/machine.nix` for the reasoning behind each formula.
Adding RAM means editing one number.

# Installing on another machine

From a NixOS live ISO, as root, inside a clone of this repo:

```sh
sudo ./installer.sh <new-hostname>
```

If `hosts/<new-hostname>/` does not exist, the installer asks for a layout
(`two-disk` or `single-disk`) and the disks, reads CPU and RAM off the machine
itself, and writes the host directory from `templates/host/`. If it *does*
exist, that is a reinstall and its committed `disko.nix` is used verbatim —
nothing is rewritten in place.

Either way, before erasing anything it checks that every disk named in
`hosts/<name>/disko.nix` is actually a block device on the machine in front of
you. That check is the point of the whole layout: the previous installer
rewrote a single shared `disko.nix` with `sed`, which worked once and then
silently kept pointing at the first machine's disks.

Commit the new `hosts/<name>/` afterwards and the machine is reproducible.

# Day-to-day

| | |
|---|---|
| Rebuild | `nh os switch` (`NH_FLAKE` is already `/etc/nixos`) |
| Test without applying | `nh os build` |
| Update inputs | `nh os switch --update` |
| Run something on the dGPU | `nvidia-offload <cmd>` (nixos-machine only) |
| Check the dGPU is asleep | `cat /sys/bus/pci/devices/0000:01:00.0/power/runtime_status` |
| Format | `nixfmt` — everything but `hardware-configuration.nix`, which is generated |

# Things you will want to change

**Persisted paths.** Anything not in `environment.persistence` in
`modules/nixos/impermanence.nix` is gone at reboot. When you find something that
should have survived, add it there — user paths under
`environment.persistence."/persistent/userdata"`, system paths under
`"/persistent/system"`. This file is shared by every host on purpose: what is
worth keeping does not depend on which laptop you are on.

**Boot passphrase.** Currently typed every boot, no TPM. To add TPM2 unlock with
a PIN later (no reinstall needed):

```sh
sudo systemd-cryptenroll --tpm2-device=auto --tpm2-with-pin=yes /dev/disk/by-partlabel/disk-main-cryptroot
```

Then add the device's `crypttab` options (`boot.initrd.systemd.enable` is
already set in `modules/nixos/boot.nix`). The passphrase keeps working as a
fallback.

**Memory.** `nixos-machine` has 14 GiB, both SODIMM slots full with 8G sticks.
If you ever change your mind, a matched 2×16G DDR5-5600 kit is ~€70-90 and is
worth more than every tuning knob in `modules/` combined. After it lands, edit
`machine.memoryGiB` in `hosts/nixos-machine/default.nix` — max-jobs, cores,
`CARGO_BUILD_JOBS` and the zram size all follow from it.

**A host that is not an NVIDIA laptop.** `templates/host/default.nix` has no GPU
block, which is correct and complete for Intel or AMD graphics —
`modules/nixos/desktop.nix` already enables `hardware.graphics`. Only an NVIDIA
machine needs the block in `hosts/nixos-machine/default.nix`, bus IDs adjusted.

**Alacritty has no tabs.** If that grates, `programs.alacritty` → `programs.kitty`
in `modules/home/default.nix` is a two-line change.

# Not installed, on purpose

Steam, OBS, any gaming stack, the CachyOS kernel, Firefox, Konsole, Ghostty,
`plasma-manager`, and system-wide Rust. Each was a decision, not an oversight.
