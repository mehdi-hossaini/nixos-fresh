# Windows apps on Linux: a dockur/windows container running a real Windows VM
# under KVM, with an Electron front end that pulls individual app windows out
# over RDP so they sit on the Plasma taskbar like native ones.
#
# The package is in nixpkgs, so law 1 is satisfiable without the .deb/AppImage
# its README leads with — and nothing here packages anything. What this file
# does is the four pieces of *system* state the package cannot bring with it:
# a container runtime, group access to it, a permit for its EOL Electron, and
# (in impermanence.nix, where the list lives) the two directories whose loss
# would mean reinstalling Windows.
{
  pkgs,
  user,
  ...
}:
{
  environment.systemPackages = [ pkgs.winboat ];

  # Electron 40.10.5 is past end-of-life — nixpkgs marks it insecure with that
  # as the entire reason, not a specific CVE. Upstream pins electron_40 and the
  # nixpkgs build follows it, so the alternatives are this permit or no winboat.
  #
  # Two things bound the blast radius, and they are why this is a permit rather
  # than a reason to stop. It admits exactly one version string, not "insecure
  # packages" as a class. And nothing else here pulls electron_40 — Obsidian and
  # Claude Code carry their own — so the permit covers winboat alone today.
  #
  # It goes stale by design: when nixpkgs bumps winboat past this Electron the
  # build fails naming the version it wanted instead, which is the loud failure
  # you want from a security exception. Update the string, do not widen it.
  nixpkgs.config.permittedInsecurePackages = [ "electron-40.10.5" ];

  # Rootful Docker specifically. The README rules out Docker Desktop, and while
  # the package wraps podman-compose onto PATH too, rootless podman would have
  # to be talked through /dev/kvm and RDP port binding — the supported path is
  # the cheaper one here.
  #
  # docker-compose needs no wiring: virtualisation.docker.enableCompose was
  # removed from nixpkgs, and the winboat wrapper already suffixes its own
  # docker-compose, freerdp and usbutils onto PATH.
  virtualisation.docker.enable = true;

  # Talking to the daemon socket without sudo — winboat shells out to
  # docker-compose as you, and every prompt it would otherwise hit is one an
  # agent session cannot answer either (law 3).
  #
  # Worth saying plainly rather than leaving implied: the docker group is
  # root-equivalent, because anything in it can bind-mount / into a privileged
  # container. That is not a new boundary on this machine — this is the single
  # user account and it is already in wheel — but it would be on a shared one,
  # and the reasoning should not have to be rediscovered there.
  users.users.${user}.extraGroups = [ "docker" ];

  # /dev/kvm needs no group entry: systemd's stock udev rules ship it 0666 on a
  # host whose kernel has KVM, verified here rather than assumed. A machine
  # where virtualisation is off in firmware has no /dev/kvm at all, and winboat
  # reports that itself at setup — there is nothing this file could assert that
  # would say it earlier or more clearly.
}
