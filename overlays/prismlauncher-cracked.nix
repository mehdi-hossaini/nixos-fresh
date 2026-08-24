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

    # The fork's wrapper predates Java 25, so Prism finds no JDK new enough for
    # current Minecraft and downloads Mojang's own runtime instead. That one is
    # unpatched: its AWT resolves shared libraries purely from LD_LIBRARY_PATH,
    # and the wrapper sets only libX11/libXcursor/libXext/libXrandr/libXxf86vm.
    # The first mod to touch java.awt then dies on libXi.so.6, which poisons
    # java.awt.Toolkit for the rest of the session and takes down everything
    # later reaching for ImageIO.
    #
    # jdk25 stops the download (a nixpkgs JDK has the paths in its RPATH);
    # additionalLibs repairs an already-downloaded Mojang runtime, so an
    # instance pinned to one keeps working either way.
    jdks = [
      final.jdk25
      final.jdk21
      final.jdk17
      final.jdk8
    ];
    additionalLibs = [
      final.libxi
      final.libxrender
      final.libxtst
      final.freetype
      final.fontconfig.lib
      # waylandcraft ships its compositor as a native Rust library inside the
      # mod jar, and that .so carries a hard DT_NEEDED on libxkbcommon.so.0.
      # The wrapper's stock library set covers GLFW's needs but not that one,
      # and there is no /usr/lib to fall back on, so without this entry the mod
      # fails at load with UnsatisfiedLinkError rather than anything readable.
      final.libxkbcommon
    ];
    # xwayland-satellite is executed by bare name, not by path, so it has to be
    # on the game process's PATH — the wrapper's is a prefix over the session's,
    # and a Prism instance inherits it. Absent, waylandcraft still starts but
    # every X11 application silently refuses to appear in a window.
    #
    # libxkbcommon is repeated here for `xkbcli`, which lives in its `out`
    # alongside the library; waylandcraft's README asks for it.
    additionalPrograms = [
      final.xwayland-satellite
      final.libxkbcommon
    ];
  };
}
