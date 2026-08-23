# ActivityWatch's media watcher, feeding the same server modules/home/default.nix
# already runs. Not in nixpkgs — checked 2026-08-23, the only aw-* attributes
# there are the server, aw-qt, aw-notify, the two stock watchers and awatcher —
# so it is built here rather than installed around, which is law 1.
#
# It is the one addition from the upstream watcher list that needs no compromise
# on this machine. On Linux it reads MPRIS over the session bus, a protocol both
# Plasma and Brave already speak, so unlike the stock ActivityWatch watchers
# nothing about it wants X11 or a wayland toplevel protocol. Same author as
# awatcher, which is already the window/AFK watcher here.
#
# Two upstream inconsistencies, recorded rather than smoothed over:
#   - Cargo.toml still says version 1.1.3 at tag v1.1.4. The tag is what is
#     fetched and what `version` below states; the crate metadata is simply
#     behind, and copying 1.1.3 here would misname the store path.
#   - LICENSE is the Unlicense, in full, ending "refer to <https://unlicense.org>",
#     while Cargo.toml declares "Mozilla Public License 2.0". The file that
#     actually grants rights wins, so meta.license follows LICENSE and names the
#     disagreement here rather than picking silently.
final: _prev: {
  aw-watcher-media-player = final.rustPlatform.buildRustPackage rec {
    pname = "aw-watcher-media-player";
    version = "1.1.4";

    src = final.fetchFromGitHub {
      owner = "2e3s";
      repo = "aw-watcher-media-player";
      rev = "v${version}";
      hash = "sha256-DjoalKlnhUWEmun57G17/gtqifo3arcbkEw/vMVNWD0=";
    };

    cargoLock = {
      lockFile = "${src}/Cargo.lock";
      # aw-client-rust is pulled from aw-server-rust's git tree at a pinned rev
      # rather than from crates.io, and a lock file cannot pin the contents of a
      # git checkout the way it pins a registry tarball — so nix needs the hash
      # stated separately.
      outputHashes = {
        "aw-client-rust-0.1.0" = "sha256-fCjVfmjrwMSa8MFgnC8n5jPzdaqSmNNdMRaYHNbs8Bo=";
      };
    };

    # The mpris crate binds libdbus; openssl-sys arrives transitively through
    # aw-client-rust and refuses to build without a real OpenSSL to point at.
    # Both are found through pkg-config. build.rs is a no-op outside msvc, so
    # nothing else is needed at build time.
    nativeBuildInputs = [ final.pkg-config ];
    buildInputs = [
      final.dbus
      final.openssl
    ];

    meta = {
      description = "Watcher reporting currently playing media to ActivityWatch";
      homepage = "https://github.com/2e3s/aw-watcher-media-player";
      license = final.lib.licenses.unlicense;
      mainProgram = "aw-watcher-media-player";
      platforms = final.lib.platforms.linux;
    };
  };
}
