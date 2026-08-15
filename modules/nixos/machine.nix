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
}
