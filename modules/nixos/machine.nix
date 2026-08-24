# What a host knows about its own hardware, and what the shared modules derive
# from it.
#
# Before this file the build and memory tuning were six literals scattered
# across configuration.nix — max-jobs, cores, CARGO_BUILD_JOBS, zram percent —
# each correct only for 12 threads and 14 GiB, and each needing a separate edit
# on a machine with different numbers. Here a host states the two facts it
# actually knows and the rest falls out. The defaults reproduce this laptop's
# hand-tuned values exactly; every one of them is still overridable per host.
{ config, lib, ... }:
let
  cfg = config.machine;
in
{
  options.machine = {
    threads = lib.mkOption {
      type = lib.types.ints.positive;
      example = 12;
      description = "Logical CPUs — what `nproc` prints.";
    };

    memoryGiB = lib.mkOption {
      type = lib.types.ints.positive;
      example = 14;
      description = "Installed RAM in GiB — what `free -g` reports as total.";
    };

    hasDataDisk = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether this host uses the two-disk layout: a second disk carrying
        random-key swap and a LUKS container named `cryptdata` mounted at
        /data. Gates the /etc/crypttab entry that unlocks it after switch-root.
        A single-disk host leaves this false and gets swap on the main disk.
      '';
    };

    secretsDir = lib.mkOption {
      type = lib.types.str;
      default = "/persistent/system/secrets";
      description = ''
        Where installer.sh leaves the things that must never enter git or the
        Nix store: the user's password hash and the data-disk keyfile. On the
        encrypted root, mode 0700, created by tmpfiles before anything reads it.
      '';
    };

    buildJobs = lib.mkOption {
      type = lib.types.ints.positive;
      default = if cfg.memoryGiB < 24 then 2 else 4;
      defaultText = lib.literalExpression "if memoryGiB < 24 then 2 else 4";
      description = ''
        nix.settings.max-jobs — how many derivations build at once.

        This MULTIPLIES with buildCores: peak concurrency is jobs x cores, not
        jobs. The product is held at `threads` below, so the machine is
        saturated and never oversubscribed. What this option picks is how that
        product is split, and the constraint is RAM rather than CPU: the number
        of SIMULTANEOUS derivations sets peak memory, so a tight machine wants
        the smaller factor here (2x6 rather than 3x4 for 12 threads). Past
        ~24 GiB that stops binding and 4 parallel jobs schedules better.
      '';
    };

    buildCores = lib.mkOption {
      type = lib.types.ints.positive;
      default = lib.max 1 (cfg.threads / cfg.buildJobs);
      defaultText = lib.literalExpression "threads / buildJobs";
      description = ''
        nix.settings.cores, and CARGO_BUILD_JOBS. The second matters as much as
        the first: nix's own limits do NOT bound cargo, so left alone cargo
        grabs every thread and OOMs on a Rust link.
      '';
    };

    zramPercent = lib.mkOption {
      type = lib.types.ints.between 1 100;
      default = lib.min 60 (800 / cfg.memoryGiB);
      defaultText = lib.literalExpression "min 60 (800 / memoryGiB)  # ~8 GiB of zram";
      description = ''
        zramSwap.memoryPercent. Targets ~8 GiB of compressed swap regardless of
        how much RAM the host has — that is the useful amount to have in front
        of disk swap, and scaling it with RAM would give a 64 GiB machine 36 GiB
        of zram it will never touch. Capped at 60% so a small machine does not
        hand most of itself to the compressor.
      '';
    };
  };

  # Three facts the options above state in prose and nothing has been checking.
  # Each one fails today at the worst possible moment — a thrashing build, a
  # boot that hangs after switch-root, a login that is refused on a machine you
  # cannot log into to fix it. An assertion moves all three to `nh os build`,
  # which costs seconds and needs no hardware.
  config.assertions = [
    {
      # buildJobs MULTIPLIES with buildCores. The defaults hold the product at
      # `threads` by construction (integer division), so this only ever fires
      # for a host that overrides one of them — which is exactly when the
      # reasoning in the descriptions above has been lost. Oversubscribing is
      # not a slow build, it is the OOM that memory.nix exists to survive.
      assertion = cfg.buildJobs * cfg.buildCores <= cfg.threads;
      message = ''
        machine.buildJobs (${toString cfg.buildJobs}) x machine.buildCores (${toString cfg.buildCores})
        = ${
          toString (cfg.buildJobs * cfg.buildCores)
        }, which oversubscribes machine.threads (${toString cfg.threads}).
        Peak build concurrency is the product, not either factor. Lower one of
        them, or raise machine.threads if this host really has that many.
      '';
    }
    {
      # hasDataDisk gates the crypttab entry in impermanence.nix, which names
      # disk-data-cryptdata by partlabel. Disagreement between the two is
      # invisible until boot: true with no such partition hangs waiting for a
      # device that does not exist, false with one leaves /data unmounted and
      # the disk silently unused.
      assertion =
        cfg.hasDataDisk == (
          (config.disko.devices.disk ? data)
          && (config.disko.devices.disk.data.content.partitions ? cryptdata)
        );
      message = ''
        machine.hasDataDisk is ${lib.boolToString cfg.hasDataDisk}, but this host's disko layout
        ${
          if cfg.hasDataDisk then
            "has no disk `data` with a `cryptdata` partition"
          else
            "does declare disk `data` with a `cryptdata` partition"
        }.
        These two describe the same disk and must agree — set the option to
        ${lib.boolToString (!cfg.hasDataDisk)}, or use the matching layout from templates/host/.
      '';
    }
    {
      # Law 5 and law 7 at once: the password hash and the data-disk keyfile
      # live here. Anywhere outside /persistent is erased at the next boot,
      # which locks the user out of the machine needed to fix it, and anything
      # in the Nix store would be world-readable besides.
      assertion = lib.hasPrefix "/persistent/" cfg.secretsDir;
      message = ''
        machine.secretsDir is "${cfg.secretsDir}", which is not under /persistent/.
        Impermanence erases everything else at boot, taking the user's password
        hash with it. Keep it on the encrypted root under /persistent/.
      '';
    }
  ];
}
