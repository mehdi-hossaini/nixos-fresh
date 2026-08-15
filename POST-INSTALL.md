# After first boot

Five steps, about 10 minutes. Do them in order — 4 needs the authentication
from 3, which needs the key from 2.

The repo is public, deliberately. That is what lets a live ISO `git clone` it
with no credentials, which is the first thing an install needs and the one
step that cannot bootstrap itself. Nothing secret is in it: the password hash
and the LUKS keyfile are both generated at install time onto `/persistent` and
never enter git. What *is* public is an email address, this machine's disk
serials in `hosts/nixos-machine/disko.nix`, and every opinion in here.

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
with its history and its remote, and a tmpfiles rule in
`modules/nixos/impermanence.nix` has already made it yours. No chown, nothing to
graft. What is *not* done is the commit for this machine: the installer stages
`hosts/<hostname>/` and stops there, because a host directory describing
hardware you have not booted yet is not worth committing.

That ownership trades a little safety — anything running as you can edit the
system config without a password — for a workflow that functions at all: `nh os
switch` declines to run as root, and root has no SSH key to push with. It is
declared rather than done by hand so a new machine comes up already usable.

If the ISO cloned over HTTPS, point the remote at SSH so pushes use your key
from step 2:

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

Because `/etc/nixos` is yours, the `safe.directory` line in
`modules/home/default.nix` is no longer load-bearing. Leave it — it costs
nothing and covers you if ownership ever reverts to root.

## 5. Rust projects

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

# What an install delivers

## Identical on every machine — `modules/`

| Area | What the installed system has |
|---|---|
| **Disk** | GPT + 2G ESP, LUKS on root, btrfs with zstd:1, `noatime`, `discard=async`, `commit=120` |
| **Encryption** | One passphrase at boot. Root unlocked in initrd; data disk (if any) unlocked after switch-root from a keyfile on the encrypted root, so no key sits on the ESP |
| **Boot** | systemd-boot, 10 generations, systemd in initrd, `quiet loglevel=3 nowatchdog`, `/tmp` on disk (never tmpfs) |
| **Root filesystem** | Impermanent — `@root` wiped and re-snapshotted from `@root-blank` every boot, outgoing root kept 7 days in `old_roots/` |
| **Persisted (system)** | `/etc/nixos`, NM connections + runtime, `/etc/ssh`, `/etc/machine-id`, `/var/log`, `/var/lib/{nixos,bluetooth,systemd,NetworkManager,fwupd,AccountsService}`, `/var/db/sudo` |
| **Persisted (user)** | `Projects Documents Downloads Pictures Videos Music Desktop`, `.ssh`, `.gnupg`, `.claude`, `.vscode`, `.config`, `.local/{share,state}`, `.cargo`, `.cache/{sccache,nix,mesa_shader_cache,nvidia}` |
| **Desktop** | KDE Plasma 6 on Wayland, SDDM (Wayland), `hardware.graphics` + 32-bit |
| **Keyboard** | xkb `se,ir`, caps→escape, alt+shift layout toggle; console `sv-latin1` |
| **Locale** | `en_US.UTF-8`, `LC_TIME=sv_SE.UTF-8`, `Europe/Stockholm` |
| **Audio/HW** | pipewire (alsa + 32-bit + pulse), rtkit, bluetooth, fwupd |
| **Network** | NetworkManager, firewall enabled |
| **Memory** | zram (zstd, priority 100) over disk swap (priority 0), earlyoom at 5%/10% — protects the session, prefers killing compilers |
| **User** | `mutableUsers = false`, password hash from `/persistent/system/secrets`, fish shell, groups `wheel networkmanager video audio input`; activation *fails loudly* if the hash file is missing |
| **Ownership** | `/etc/nixos` owned by you via tmpfiles, so `nh` and `git` work without sudo from first boot |
| **Nix** | flakes, weekly GC (14d) + optimise, devenv & nix-community caches, 32 substitution jobs |
| **Fonts** | JetBrainsMono Nerd Font, set as default monospace |
| **Packages** | `brave-origin alacritty zellij vscode claude-code git gh jujutsu jjui devenv sccache ast-grep shellcheck gitleaks uv nh nixd statix nixfmt ripgrep fd eza bat fzf jq btop` + nix-ld |
| **Home** | fish, direnv + nix-direnv, git (identity, `main` default, rebase pulls, autoSetupRemote), jj (identity, `jj`→log, `code --wait`), jjui, full gruvbox Alacritty, bat, fzf |
| **Build env** | `RUSTC_WRAPPER=sccache`, `NH_FLAKE=/etc/nixos`, `EDITOR=code --wait`, `CLAUDE_CONFIG_DIR` |

## Varies per machine — `hosts/<name>/`

A host declares three facts about itself and the rest is derived:

| Knob | Source | Effect |
|---|---|---|
| Hostname | the directory name | also becomes the flake attribute, so `nh os switch` always resolves |
| Disk devices | `disko.nix`, by-id | validated as real block devices before anything is erased |
| Layout | `two-disk` or `single-disk` | two-disk adds `/data` + swap on disk 2; single-disk puts swap on the main disk, no `/data` |
| `machine.threads` | detected via `nproc` | → `nix.settings.cores`, `CARGO_BUILD_JOBS` |
| `machine.memoryGiB` | detected via `MemTotal` | → `max-jobs` (2 under 24 GiB, else 4), `zramSwap.memoryPercent` (targets ~8 GiB, capped 60) |
| `machine.hasDataDisk` | from the layout | gates the `/etc/crypttab` entry |
| GPU | hand-written | template has none — correct for Intel/AMD. NVIDIA needs the PRIME block with bus IDs |

On `nixos-machine` that resolves to `max-jobs 2 × cores 6`, `CARGO_BUILD_JOBS=6`,
zram 57%. See `modules/nixos/machine.nix` for the reasoning behind each formula.
Adding RAM means editing one number.

## Still manual after install

| | |
|---|---|
| SSH key | generate, then register at <https://github.com/settings/keys> |
| `gh` login | `gh auth login` (SSH, finds the key) |
| Claude Code login | once |
| Project `.env` files | gone with the old disk — they are gitignored, so they exist on one disk only |
| Commit `hosts/<name>/` | the installer stages it and stops |
| Plasma look and feel | `.config` persisted; only power settings are declared (`modules/home/plasma.nix`), the rest is hand-set |
| VS Code extensions | marketplace, once, on brand-new hardware |
| Per-project devenv | `devenv.nix` + `direnv allow` |

This describes what the config *declares*. Only the `nixos-machine` path has run
end to end — the `single-disk` template is verified by evaluation, not by an
install.

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
and system-wide Rust. Each was a decision, not an oversight.

**`plasma-manager` was on this list and now is not.** It is installed, but
scoped to powerdevil alone (`modules/home/plasma.nix`) with `overrideConfig`
left false, so it writes only the keys it names. The rest of Plasma is still
hand-set and merely persisted — the reason it was excluded in the first place,
which holds for everything except the power settings.

**secretspec** was here and was removed. It was installed, configured with a
`keyring` provider, and used by nothing: no `secretspec.toml` existed anywhere,
its audit log had never been written, and the only command ever run against it
was `config init`. Project secrets go in gitignored `.env` files loaded by
direnv's `dotenv_if_exists`, which is what the one devenv project actually does.
Note that `devenv` vendors its own `secretspec` binary, so the command is still
on PATH — removing the package only stopped declaring a second, shadowed copy.
