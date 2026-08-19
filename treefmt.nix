# One formatting config for the whole tree, reached two ways: `nix fmt` applies it,
# checks.formatting fails if anything drifts from it. Before this, nixfmt and shfmt
# were configured inside the checks output with their flags spelled out there, so
# "how this repo is formatted" had no single home.
_: {
  projectRootFile = "flake.nix";

  programs.nixfmt.enable = true;
  programs.shfmt = {
    enable = true;
    # Matches claude/check-conventions.sh. shfmt defaults to tabs, which would
    # rewrite every line of it.
    indent_size = 2;
  };

  # hosts/*/hardware-configuration.nix is written by nixos-generate-config and
  # forbids hand edits; formatting it is an edit, and one the generator undoes.
  settings.formatter.nixfmt.excludes = [ "hosts/*/hardware-configuration.nix" ];

  # installer.sh has never been shfmt'd — 256 lines change at any indent width.
  # It partitions disks and shreds an encryption keyfile, so reformatting it is a
  # decision of its own rather than a side effect of adding a formatter.
  settings.formatter.shfmt.excludes = [ "installer.sh" ];
}
