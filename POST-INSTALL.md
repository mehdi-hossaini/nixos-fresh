# After first boot

How much there is to do depends entirely on whether you installed with
`--secrets`:

| | with `--secrets` | without |
|---|---|---|
| SSH key | already there | generate + register with GitHub |
| `gh` login | already there | `gh auth login` |
| Claude Code login | already there | log in once |
| Project `.env` files | restored | gone with the old disk |
| `/etc/nixos` ownership | automatic | automatic |
| **Total** | **steps 1–3, ~3 min** | **steps 1–3 plus "Logging in by hand"** |

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

## 2. Commit this machine's host directory

`installer.sh` copied the whole clone to `/persistent/system/etc/nixos`,
**including `.git`** — so `/etc/nixos` is already the repo you installed from,
with its history and its remote, and a tmpfiles rule has already made it yours.
No chown, no grafting. What is *not* done is the commit for this machine: the
installer stages `hosts/<hostname>/` and stops, because a host directory
describing hardware you have not booted yet is not worth committing.

```sh
cd /etc/nixos
git status                    # hosts/<hostname>/ should be staged
git commit -m "add host $(hostname)"
git push
```

If the ISO cloned over HTTPS, point the remote at SSH first so the push uses
your key:

```sh
git remote -v
git remote set-url origin git@github.com:mehdi-hossaini/nixos-fresh.git
```

## 3. Make the repo private again

It was flipped public so the live ISO could `git clone` it without
authenticating. Nothing secret is in it — the password hash and the LUKS keyfile
are generated at install time, and credentials travel in the bundle, never in
git — but public was a temporary convenience, not a decision.

```sh
gh repo edit mehdi-hossaini/nixos-fresh --visibility private \
  --accept-visibility-change-consequences
```

---

# Logging in by hand

Only needed if you installed **without** `--secrets`.

```sh
# SSH key — the old one died with the disk
ssh-keygen -t ed25519 -C "littlemehti@gmail.com"
cat ~/.ssh/id_ed25519.pub          # paste at https://github.com/settings/keys

# GitHub CLI — choose SSH, it will find the key above
gh auth login
gh auth status

# Claude Code
claude          # follow the login prompt
```

Then build a bundle so the next machine skips all of this.

# The credential bundle

Everything in this repo is declarative except credentials, which cannot be: no
amount of Nix produces a private key GitHub already trusts. `secrets-bundle.sh`
is how they travel.

```sh
./secrets-bundle.sh list                                  # what would go in
./secrets-bundle.sh create /run/media/$USER/USB/secrets.age
```

It carries two kinds of thing, then encrypts with `age -p` — a passphrase, not a
keypair, because a keypair would need its own private key delivered to the new
machine first, which is the problem the bundle exists to solve.

**Credentials, at fixed paths:** `~/.ssh`, `~/.config/gh`, `~/.local/share/kwalletd`
(where the `gh` token actually lives — `hosts.yml` holds only the account name),
`~/.claude/.credentials.json`, `~/.claude/.claude.json` and `~/.gnupg`.

**Project `.env` files, found rather than listed**, because they live wherever
the projects do and a fixed list goes stale the first time you start a new one.
Only `Projects/` and `Desktop/` are scanned, and that is an impermanence
constraint rather than a speed one: a restored file survives the first boot only
if its path is inside a persisted directory. `.git`, `.direnv`, `.devenv`,
`node_modules`, `.venv`, `__pycache__`, `target` and `.Trash-*` are pruned, and
`.env.example`/`.sample`/`.template` are excluded — they are committed templates
with placeholder values, and listing them beside real secrets is exactly the
confusion you do not want when auditing.

`.env` files are gitignored by design, which means they exist on exactly one
disk and a reinstall is otherwise the last time you see them. Run
`./secrets-bundle.sh list` before every `create` and read what it found — the
`.env` section is printed separately for that reason.

Restore it at install time:

```sh
sudo ./installer.sh <hostname> --secrets /path/to/secrets.age
```

The installer unpacks it into `/persistent/userdata/home/<user>/` **after**
`nixos-install`, so it can read the real uid out of `/mnt/etc/passwd` rather
than assuming 1000, and file modes survive the round trip — `.ssh` comes back
0700 with 0600 keys.

**Use the same login password.** KWallet is encrypted with it. Restore the
wallet onto a machine with a different password and it will sit there intact and
unopenable, leaving `gh` unauthenticated. The SSH key and the `.env` files are
plain files and are unaffected — only the wallet depends on the password. The
installer warns about this at the password prompt.

**Keep the bundle on removable media.** It is every credential you have, and
`age -p` has no recovery if you forget the passphrase.

**Refresh it when credentials change** — a rotated SSH key or a re-auth'd `gh`
makes the old bundle stale. `create` refuses to overwrite an existing file, so
retiring one is a deliberate act.

# What is still not automatic, and why

- **Plasma look and feel.** `~/.config` is persisted but not declared, and
  `plasma-manager` is in the "not installed, on purpose" list. A fresh machine
  gets stock Plasma. Reverse that decision by adding `plasma-manager` if it ever
  stops being worth the manual setup.
- **VS Code extensions.** `~/.vscode` is persisted, so this only bites on brand
  new hardware, where you install the Claude Code extension once from the
  marketplace. Declaring it from nixpkgs would pin an older version and fight
  the extension's own updater.
- **Registering a *new* SSH key with GitHub.** Unavoidable when you generate one
  rather than carry it — GitHub has to be told, and only you can tell it.

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
installer.sh       install; --secrets restores the bundle
secrets-bundle.sh  build the bundle
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
sudo ./installer.sh <new-hostname> --secrets /path/to/secrets.age
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
| Refresh credentials | `./secrets-bundle.sh create <path>` |

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

**secretspec** was here and was removed. It was installed, configured with a
`keyring` provider, and used by nothing: no `secretspec.toml` existed anywhere,
its audit log had never been written, and the only command ever run against it
was `config init`. Project secrets go in gitignored `.env` files loaded by
direnv's `dotenv_if_exists`, which is what the one devenv project actually does
and what the bundle now carries. Re-add it if a project ever wants declarative
secrets across several providers; until then it was a package, a config file and
three paragraphs of documentation serving nobody.
