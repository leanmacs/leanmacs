# The image `mise run linux-ci` and `mise run linux-window` run the gate in
# (tools/linux/run.sh; README.md, "The gate on Linux").
#
# It holds the system packages, mise and elan, and nothing of the project.
# What the project pins stays where it is pinned: mise installs the tools
# `mise.toml` names, and elan the Lean toolchain `lean/lean-toolchain` names,
# into a cache directory on the host that outlives the container.
#
# Debian 13 (trixie) slim, pinned by digest: this was `debian:trixie-slim` on
# 2026-11-11. Its packages are whatever that release serves when the image is
# built.
FROM debian@sha256:a72b4433de1cf7d6bae0c4cee74d0547f58601a643b3375f070c51600d63b6b2

# The first line is what the build needs: a system C compiler and linker
# (`build-essential`: gcc, GNU ld, glibc's headers), git for Lake's
# dependencies and for the `c-fmt` task's file list, curl and the
# certificates for downloads, zstd for the Lean toolchain's archive,
# pkg-config for build scripts of the window library's dependencies,
# and pipx, through which mise installs clang-format.
#
# The second line is for `linux-window` alone: a display that needs no
# screen (Xvfb), a way to type into it (xdotool), and the libraries the
# window library loads at run time under X11. The clipboard adapter needs
# no library of the system: it speaks X11 through a connection of its own.
#
# The third line is for `linux-render` and for the window that draws in
# `linux-window`: Mesa's Vulkan drivers, of which llvmpipe draws on the
# CPU, and the Vulkan loader wgpu opens at run time. They are enough for a
# surface on an X11 window as they are. The gate asks for no adapter
# (the root `clippy.toml` forbids it to tests), so it
# runs the same with them there.
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates curl git build-essential zstd pkg-config pipx python3-venv \
        xvfb xdotool libx11-6 libx11-xcb1 libxcursor1 libxi6 libxrandr2 \
        libxkbcommon0 libxkbcommon-x11-0 libxcb1 \
        mesa-vulkan-drivers libvulkan1 \
    && rm -rf /var/lib/apt/lists/*

# For `linux-window`'s change of scale: a daemon that owns the display's
# XSETTINGS selection and serves settings from a file it reads again when
# it is signalled. Xvfb has no such daemon of its own, and a change of its
# `Xft/DPI` is how the window library's X11 back end hears of a new scale
# while a window is open (tools/linux/run.sh, `inside_drawing_window`).
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        xsettingsd \
    && rm -rf /var/lib/apt/lists/*

# mise and elan, each at an exact version, each download checked against the
# SHA-256 of the release file. Only the arm64 files have been run; the amd64
# checksums are those of the same releases.
ARG MISE_VERSION=2026.11.2
ARG MISE_SHA256_ARM64=18bf3ac02033c2a50b772b411e35528cd1888386b4316895fcae626db6ad96f3
ARG MISE_SHA256_AMD64=62cad463c1413f05398ca339168a8f655120b6f0b0b8adce3bc6758bafaf0602
ARG ELAN_VERSION=4.2.4
ARG ELAN_SHA256_ARM64=05febd124d84ebf994b2e7479922a5650b1e950c17ae3bd1ddd776b65bb72bf9
ARG ELAN_SHA256_AMD64=42b94d4244e8353142c456ec0e4ca6528fd898a6c604d4059f494e706e431f63

# elan is one binary that acts as whichever tool it is named after, so `lean`
# and `lake` are links to it: each reads `lean-toolchain` in the directory it
# is run from and installs that toolchain on first use.
RUN set -eu; \
    case "$(dpkg --print-architecture)" in \
        arm64) mise_file=linux-arm64; mise_sum=$MISE_SHA256_ARM64; \
               elan_file=aarch64-unknown-linux-gnu; elan_sum=$ELAN_SHA256_ARM64 ;; \
        amd64) mise_file=linux-x64; mise_sum=$MISE_SHA256_AMD64; \
               elan_file=x86_64-unknown-linux-gnu; elan_sum=$ELAN_SHA256_AMD64 ;; \
        *) echo "no mise or elan release is pinned for this architecture" >&2; exit 1 ;; \
    esac; \
    releases=https://github.com; \
    curl -sSfL -o /usr/local/bin/mise \
        "$releases/jdx/mise/releases/download/v$MISE_VERSION/mise-v$MISE_VERSION-$mise_file"; \
    echo "$mise_sum  /usr/local/bin/mise" | sha256sum -c -; \
    chmod +x /usr/local/bin/mise; \
    curl -sSfL -o /tmp/elan.tar.gz \
        "$releases/leanprover/elan/releases/download/v$ELAN_VERSION/elan-$elan_file.tar.gz"; \
    echo "$elan_sum  /tmp/elan.tar.gz" | sha256sum -c -; \
    tar -xzf /tmp/elan.tar.gz -C /tmp; \
    install -m 0755 /tmp/elan-init /usr/local/bin/elan; \
    rm /tmp/elan.tar.gz /tmp/elan-init; \
    for tool in lean lake leanc leanmake; do ln -s elan "/usr/local/bin/$tool"; done

# Where the tools keep what they install. `/cache` is a directory of the
# host and `/cargo` a Docker volume; run.sh mounts both and says why they
# differ.
ENV ELAN_HOME=/cache/elan \
    RUSTUP_HOME=/cache/rustup \
    MISE_DATA_DIR=/cache/mise/data \
    MISE_CACHE_DIR=/cache/mise/cache \
    MISE_STATE_DIR=/cache/mise/state \
    MISE_TRUSTED_CONFIG_PATHS=/work \
    MISE_YES=1 \
    CARGO_HOME=/cargo/home \
    PATH=/cargo/home/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

WORKDIR /work
