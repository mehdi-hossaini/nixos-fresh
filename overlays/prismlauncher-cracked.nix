# PrismLauncher-Cracked overlay, patched to resolve extra-cmake-modules
# from kdePackages (Qt6) instead of the removed top-level alias, and to add
# pkg-config, which upstream's nix/unwrapped.nix omits from
# nativeBuildInputs (unlike nixpkgs' own prismlauncher-unwrapped) — without
# it, CMake's find_package(PkgConfig) fails configuring qtnetworkauth.
#
# Deliberately named `prismlauncher`, not `prismlauncher-cracked`, so it
# replaces the official nixpkgs package everywhere (including home-manager
# via useGlobalPkgs) rather than living alongside it — the offline-auth
# fork is the one actually wanted here.
{ prismlauncher-cracked }:

final: prev:

let
  upstreamPrism = prismlauncher-cracked.overlays.default final prev;
in
{
  prismlauncher-unwrapped =
    (upstreamPrism.prismlauncher-unwrapped.override {
      extra-cmake-modules = final.kdePackages.extra-cmake-modules;
    }).overrideAttrs
      (old: {
        nativeBuildInputs = old.nativeBuildInputs ++ [ final.pkg-config ];
      });

  prismlauncher = upstreamPrism.prismlauncher.override {
    prismlauncher-unwrapped = final.prismlauncher-unwrapped;
  };
}
