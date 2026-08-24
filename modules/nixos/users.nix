{
  config,
  lib,
  pkgs,
  user,
  fullName,
  ...
}:
let
  # Written by installer.sh, never by git and never into the Nix store.
  passwordHashFile = "${config.machine.secretsDir}/user-password";
in
{
  users.mutableUsers = false;
  users.users.${user} = {
    isNormalUser = true;
    description = fullName;
    extraGroups = [
      "wheel"
      "networkmanager"
      "video"
      "audio"
      "input"
    ];
    hashedPasswordFile = passwordHashFile;
    shell = pkgs.fish;
  };
  programs.fish.enable = true;

  # This was here for the Claude Code VS Code extension's bundled binary. VS Code
  # is gone, and the need is not: mason.nvim downloads prebuilt language servers
  # for neovim and runs them from ~/.local/share/nvim/mason. Being generic-Linux
  # ELFs they look for the loader at the FHS path /lib64/ld-linux-x86-64.so.2,
  # where NixOS keeps stub-ld: a stub whose only job is to print "cannot run
  # dynamically linked executables" and exit 127. nix-ld puts a real loader there
  # instead. Servers needing more than glibc would list their libraries in
  # programs.nix-ld.libraries.
  programs.nix-ld.enable = true;

  # mutableUsers = false and no root password means a missing hash file leaves
  # NO usable account and nothing to recover from. update-users-groups.pl only
  # warns; an empty file is worse than a missing one (empty = no password
  # required, not locked). The path is on /persistent so eval cannot check it —
  # this has to happen at activation.
  #
  # This is also the check that catches a fresh install where installer.sh was
  # skipped: on a new machine it is the first thing to fail, and it fails
  # loudly, before the reboot that would otherwise lock you out.
  system.activationScripts.checkPasswordHash.text = ''
    if [ ! -s ${lib.escapeShellArg passwordHashFile} ]; then
      echo "ERROR: ${passwordHashFile} is missing or empty." >&2
      echo "       Every account on this host would be unusable. Fix before reboot:" >&2
      echo "         sudo install -d -m 0700 ${config.machine.secretsDir}" >&2
      echo "         sudo sh -c 'mkpasswd -m sha-512 > ${passwordHashFile}'" >&2
      echo "         sudo chmod 600 ${passwordHashFile}" >&2
      false
    fi
  '';
  system.activationScripts.users.deps = [ "checkPasswordHash" ];
}
