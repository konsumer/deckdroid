# Build environment that matches SteamOS 3.8.1x exactly (glibc 2.41, Python 3.13).
# Starts from upstream Arch for the toolchain, then repoints pacman at Valve's
# snapshot repos and downgrades everything to the SteamOS package set, so the
# artifacts we ship link against the same libraries the Deck actually has.
FROM --platform=linux/amd64 archlinux:base-devel

ARG STEAMOS_SUFFIX=3.8.1x
ARG MIRROR=https://steamdeck-packages.steamos.cloud/archlinux-mirror

RUN set -eux; \
    echo "Server = ${MIRROR}/\$repo/os/\$arch" > /etc/pacman.d/mirrorlist; \
    { \
      echo '[options]'; \
      echo 'Architecture = auto'; \
      echo 'ParallelDownloads = 10'; \
      echo 'SigLevel = Never'; \
      echo 'HoldPkg = pacman glibc'; \
      for r in jupiter holo core extra multilib; do \
        echo "[${r}-${STEAMOS_SUFFIX}]"; \
        echo 'Include = /etc/pacman.d/mirrorlist'; \
      done; \
    } > /etc/pacman.conf

# -uu allows downgrades: upstream Arch is newer than the SteamOS snapshot.
RUN pacman -Syuu --noconfirm --overwrite '*' && pacman -Scc --noconfirm || true

RUN pacman -S --noconfirm --needed --overwrite '*' \
      base-devel git meson ninja cmake pkgconf glib2 python python-pip \
      python-setuptools cython rsync || true

# makepkg refuses to run as root
RUN useradd -m -G wheel builder \
 && echo 'builder ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/builder \
 && install -d -o builder -g builder /out /work
USER builder
WORKDIR /work
