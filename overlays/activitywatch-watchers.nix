# The ActivityWatch watchers nixpkgs does not carry. Checked 2026-08-23: the only
# aw-* attributes there are aw-server-rust, aw-qt, aw-notify, awatcher and the two
# stock watchers, so everything below is built here rather than installed around,
# which is law 1.
#
# One file rather than one per package: they are a single concern, they share the
# same shape, and grouping them keeps overlays/ from filling with near-identical
# stubs. The Python client libraries they all need — aw-client and aw-core — ARE
# in nixpkgs, which is what makes any of this cheap.
final: _prev:
let
  py = final.python3Packages;

  # Every one of these fetches the same way; only owner/repo/rev/hash differ.
  # Named ghSrc, not src: inside a `rec` the attribute `src` would shadow it and
  # the definition becomes its own argument — nix reports that as infinite
  # recursion with no hint of where.
  ghSrc =
    {
      owner,
      repo,
      rev,
      hash,
    }:
    final.fetchFromGitHub {
      inherit
        owner
        repo
        rev
        hash
        ;
    };
in
{
  # Reads MPRIS over the session bus, which Plasma and Brave both speak, so unlike
  # the stock ActivityWatch watchers it wants neither X11 nor a wayland toplevel
  # protocol.
  #
  # Two upstream inconsistencies, recorded rather than smoothed over:
  #   - Cargo.toml still says 1.1.3 at tag v1.1.4. The tag is what is fetched and
  #     what `version` states; copying 1.1.3 would misname the store path.
  #   - LICENSE is the Unlicense in full, ending "refer to <https://unlicense.org>",
  #     while Cargo.toml declares "Mozilla Public License 2.0". The file that
  #     actually grants rights wins, and the disagreement is named rather than
  #     silently resolved.
  aw-watcher-media-player = final.rustPlatform.buildRustPackage rec {
    pname = "aw-watcher-media-player";
    version = "1.1.4";

    src = ghSrc {
      owner = "2e3s";
      repo = pname;
      rev = "v${version}";
      hash = "sha256-DjoalKlnhUWEmun57G17/gtqifo3arcbkEw/vMVNWD0=";
    };

    cargoLock = {
      lockFile = "${src}/Cargo.lock";
      # aw-client-rust comes from aw-server-rust's git tree at a pinned rev rather
      # than from crates.io, and a lock file cannot pin a git checkout the way it
      # pins a registry tarball, so nix needs the hash stated separately.
      outputHashes = {
        "aw-client-rust-0.1.0" = "sha256-fCjVfmjrwMSa8MFgnC8n5jPzdaqSmNNdMRaYHNbs8Bo=";
      };
    };

    # mpris binds libdbus; openssl-sys arrives transitively through aw-client-rust
    # and refuses to build without a real OpenSSL to point at.
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

  # Wifi SSID and connectivity. Its two git dependencies both come from
  # aw-server-rust at one rev, so they take the same hash under different keys.
  aw-watcher-network-rs = final.rustPlatform.buildRustPackage rec {
    pname = "aw-watcher-network-rs";
    version = "0.1.0";

    src = ghSrc {
      owner = "0xbrayo";
      repo = pname;
      rev = "v${version}";
      hash = "sha256-4Kcp4+lxGMeyRX1gMn5tpUxDH7ri7zKpwYCV0vzQK5o=";
    };

    cargoLock = {
      lockFile = "${src}/Cargo.lock";
      outputHashes = {
        # Same checkout under two keys — cargo records one entry per crate, but
        # both crates live in the same aw-server-rust tree at one rev.
        "aw-client-rust-0.1.0" = "sha256-QRJL2yzSkpC76qwJzQ4gVGb9MUSfiUge6yW7/SUBLvY=";
        "aw-models-0.1.0" = "sha256-QRJL2yzSkpC76qwJzQ4gVGb9MUSfiUge6yW7/SUBLvY=";
      };
    };

    nativeBuildInputs = [ final.pkg-config ];
    buildInputs = [ final.openssl ];

    meta = {
      description = "Watcher reporting network activity and wifi SSIDs to ActivityWatch";
      homepage = "https://github.com/0xbrayo/aw-watcher-network-rs";
      license = final.lib.licenses.mit;
      mainProgram = "aw-watcher-network-rs";
      platforms = final.lib.platforms.linux;
    };
  };

  # Laptop lid, suspend and power-off. This machine has a lid: /proc/acpi/button/lid
  # carries LID0 and the chassis type is 10 (notebook).
  #
  # Upstream builds through poetry-dynamic-versioning, which reads the version out
  # of git history — and a fetched tarball has no .git, so the build would fail
  # working out what it is called. POETRY_DYNAMIC_VERSIONING_BYPASS is the escape
  # hatch the plugin provides for exactly this, and it is handed the tag already
  # being fetched.
  aw-watcher-lid = py.buildPythonApplication rec {
    pname = "aw-watcher-lid";
    version = "0.1.2";
    pyproject = true;

    src = ghSrc {
      owner = "tobixen";
      repo = pname;
      rev = "v${version}";
      hash = "sha256-mt/a5AV+scoGGrQKXSDxa4qvnJrsSzjApZSwGHxS8+Q=";
    };

    env.POETRY_DYNAMIC_VERSIONING_BYPASS = version;

    build-system = [
      py.poetry-core
      py.poetry-dynamic-versioning
    ];

    dependencies = [
      py.aw-client
      py.dbus-python
      py.pygobject3
    ];

    # The suite wants a session bus and a real lid to poke.
    doCheck = false;

    meta = {
      description = "Watcher reporting laptop lid, suspend and power-off state to ActivityWatch";
      homepage = "https://github.com/tobixen/aw-watcher-lid";
      license = final.lib.licenses.gpl3Only;
      mainProgram = "aw-watcher-lid";
      platforms = final.lib.platforms.linux;
    };
  };

  # CPU, RAM, GPU and disk. Upstream's docs page also claims network and sensors;
  # the binary's own --help says "CPU, RAM, GPU and disk usage", and that is what
  # this follows.
  #
  # Two upstream facts the packaging has to work around. It declares the
  # pre-poetry-core backend `poetry.masonry.api`, which today's poetry-core does
  # not provide; and it pins `python = ">=3.9,<3.13"` while nixpkgs is on 3.14.
  # Both live in pyproject.toml and neither reflects a real incompatibility — the
  # code is plain psutil — so postPatch rewrites the backend and drops the ceiling
  # rather than pinning the whole package to an EOL interpreter.
  aw-watcher-utilization = py.buildPythonApplication rec {
    pname = "aw-watcher-utilization";
    version = "1.2.2";
    pyproject = true;

    src = ghSrc {
      owner = "Alwinator";
      repo = pname;
      rev = "v${version}";
      hash = "sha256-CZsJ8itg6wI19uD9nXl/H0A1EFbt87C0yFLHZAsvGQY=";
    };

    postPatch = ''
      substituteInPlace pyproject.toml \
        --replace-fail 'requires = ["poetry>=0.12"]' 'requires = ["poetry-core"]' \
        --replace-fail 'build-backend = "poetry.masonry.api"' 'build-backend = "poetry.core.masonry.api"' \
        --replace-fail 'python = ">=3.9,<3.13"' 'python = ">=3.9"'
    '';

    build-system = [ py.poetry-core ];

    # Upstream caps psutil below 6; nixpkgs ships 7.2.2. The four calls it makes —
    # cpu_percent, virtual_memory, disk_usage, net_io_counters — are psutil's
    # oldest and most stable surface and did not change across that major, so the
    # cap is staleness rather than a real incompatibility. Relaxed by name, not
    # with a blanket --no-deps, so any OTHER dependency drifting out of range
    # still fails the check.
    pythonRelaxDeps = [ "psutil" ];

    # Upstream pulls aw-core and aw-client straight from git; nixpkgs has both, and
    # substituting them is the whole reason this is a twenty-line derivation.
    dependencies = [
      py.aw-client
      py.aw-core
      py.psutil
    ];

    doCheck = false;

    meta = {
      description = "Watcher reporting CPU, RAM, GPU and disk usage to ActivityWatch";
      homepage = "https://github.com/Alwinator/aw-watcher-utilization";
      license = final.lib.licenses.mit;
      mainProgram = "aw-watcher-utilization";
      platforms = final.lib.platforms.linux;
    };
  };
}
