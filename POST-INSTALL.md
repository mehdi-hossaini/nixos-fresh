# After first boot

Seven steps, about 10 minutes. Do them in order — both 0 and 4 need the
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

The old one died with the disk.

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

## 4. Reconnect this config to the repo it came from

Not a `gh repo create` — `mehdi-hossaini/nixos-fresh` already exists, which is
the whole premise of step 0. It has its own history on `main`, ending at the
commit that added this file. Meanwhile `installer.sh` left `/etc/nixos`
root-owned, and a local `git init` has already run in it, on `master`, with a
history **unrelated** to the remote's. Those two histories have to be joined,
and `git push` will refuse until they are.

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

Then graft this machine's state onto the real history:

```sh
cd /etc/nixos
git remote add origin git@github.com:mehdi-hossaini/nixos-fresh.git
git fetch origin
git reset --soft origin/main    # moves the branch pointer, touches no files
git commit -m "post-install: machine-specific config"
git branch -m master main
git push -u origin main
```

`reset --soft` leaves every file exactly as it is on disk, so what lands on the
remote is one honest commit describing how this machine differs from what was
cloned. Do not force-push: the remote history is the one worth keeping, and the
local `master` commits only exist because the disk was reinstalled.

Once `/etc/nixos` is yours, the `safe.directory` line in `home.nix` is no longer
load-bearing. Leave it — it costs nothing and covers you if ownership ever
reverts to root.

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

`sccache` and `CARGO_BUILD_JOBS=6` are set system-wide and apply inside devenv
shells automatically.

---

# Day-to-day

| | |
|---|---|
| Rebuild | `nh os switch` (`NH_FLAKE` is already `/etc/nixos`) |
| Test without applying | `nh os build` |
| Update inputs | `nh os switch --update` |
| Run something on the dGPU | `nvidia-offload <cmd>` |
| Check the dGPU is asleep | `cat /sys/bus/pci/devices/0000:01:00.0/power/runtime_status` |

# Things you will want to change

**Persisted paths.** Anything not in `environment.persistence` in
`configuration.nix` is gone at reboot. When you find something that should have
survived, add it there — user paths under
`environment.persistence."/persistent/userdata"`, system paths under
`"/persistent/system"`.

**Boot passphrase.** Currently typed every boot, no TPM. To add TPM2 unlock with
a PIN later (no reinstall needed):

```sh
sudo systemd-cryptenroll --tpm2-device=auto --tpm2-with-pin=yes /dev/disk/by-partlabel/disk-main-cryptroot
```

Then add `boot.initrd.systemd.enable = true;` (already set) and the device's
`crypttab` options. The passphrase keeps working as a fallback.

**Memory.** 14G, both SODIMM slots full with 8G sticks. If you ever change your
mind, a matched 2×16G DDR5-5600 kit is ~€70-90 and is worth more than every
tuning knob in `configuration.nix` combined. After it lands, raise
`nix.settings.max-jobs`/`cores` and `CARGO_BUILD_JOBS`.

**Alacritty has no tabs.** If that grates, `programs.alacritty` → `programs.kitty`
in `home.nix` is a two-line change.

# Not installed, on purpose

Steam, OBS, any gaming stack, the CachyOS kernel, Firefox, Konsole, Ghostty,
`plasma-manager`, and system-wide Rust. Each was a decision, not an oversight.
