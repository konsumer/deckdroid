#!/bin/bash
# Assembles a relocatable Waydroid bundle for SteamOS.
#
# Two sources of content:
#   1. Prebuilt SteamOS packages (lxc, cage, wlroots, ...) resolved by pacman
#      into an alternate root, then pruned of anything the Deck already ships.
#   2. The gbinder/waydroid stack, which has no binary package and is built here.
#
# Nothing is prefixed to a fixed location: the result is untarred anywhere and
# driven by bin/deckdroid-env, which sets PATH/LD_LIBRARY_PATH/PYTHONPATH.
set -euo pipefail

SRC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
OUT=${OUT:-/out}
STAGE=${STAGE:-/tmp/stage}
PKGROOT=$STAGE/pkgroot
BUNDLE=$STAGE/bundle
DECK_LIST=${DECK_LIST:-$SRC_DIR/deck-installed-3.8.16.txt}

# Pinned upstream revisions. Bump deliberately, never float.
LIBGLIBUTIL_TAG=1.0.79
LIBGBINDER_TAG=1.1.42
PYTHON_GBINDER_TAG=1.1.2
WAYDROID_TAG=1.6.3

# Binary packages to pull from the SteamOS repos.
BINARY_PKGS=(lxc cage wlr-randr dnsmasq)

msg() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

rm -rf "$STAGE"; mkdir -p "$PKGROOT" "$BUNDLE/usr" "$OUT"

# ---------------------------------------------------------------------------
msg "Resolving binary packages into an alternate root"
# pacman does the dependency closure for us; -r keeps it out of the build image.
sudo pacman -r "$PKGROOT" -Sy --noconfirm --dbpath "$PKGROOT/var/lib/pacman" \
  "${BINARY_PKGS[@]}"

msg "Pruning packages the Deck already ships"
# Anything present in SteamOS is a liability to ship: bundling a second copy of
# mesa/libdrm/systemd would shadow the host's GPU stack over LD_LIBRARY_PATH.
mapfile -t installed < <(sudo pacman -r "$PKGROOT" --dbpath "$PKGROOT/var/lib/pacman" -Qq)
kept=(); dropped=0
for pkg in "${installed[@]}"; do
  if grep -qx "$pkg" "$DECK_LIST"; then
    # Delete only this package's files, leaving shared dirs alone.
    while read -r f; do
      [ -f "$PKGROOT/$f" ] && sudo rm -f "$PKGROOT/$f"
    done < <(sudo pacman -r "$PKGROOT" --dbpath "$PKGROOT/var/lib/pacman" -Qlq "$pkg" | sed 's|^/||')
    dropped=$((dropped + 1))
  else
    kept+=("$pkg")
  fi
done
echo "kept ${#kept[@]} packages, dropped $dropped already on the Deck"
printf '%s\n' "${kept[@]}" > "$STAGE/bundled-packages.txt"

sudo rm -rf "$PKGROOT/var/lib/pacman" "$PKGROOT/var/cache"
sudo chown -R "$(id -u):$(id -g)" "$PKGROOT"
# Keep only what a relocated prefix can actually use.
for d in usr/bin usr/lib usr/share usr/libexec; do
  [ -d "$PKGROOT/$d" ] && { mkdir -p "$BUNDLE/$(dirname $d)"; cp -a "$PKGROOT/$d" "$BUNDLE/$d"; }
done

# ---------------------------------------------------------------------------
build_git() { # url tag builder...
  local url=$1 tag=$2; shift 2
  local name; name=$(basename "$url" .git)
  msg "Building $name $tag"
  git clone --depth 1 --branch "$tag" "$url" "$STAGE/$name"
  ( cd "$STAGE/$name" && "$@" )
}

# libglibutil and libgbinder are plain Makefiles; they honour prefix + DESTDIR.
build_git https://github.com/mer-hybris/libglibutil "$LIBGLIBUTIL_TAG" \
  bash -c 'make -j"$(nproc)" release pkgconfig && make install-dev DESTDIR="'"$BUNDLE"'" LIBDIR=/usr/lib'
export PKG_CONFIG_PATH=$BUNDLE/usr/lib/pkgconfig
export CFLAGS="-I$BUNDLE/usr/include" LDFLAGS="-L$BUNDLE/usr/lib"

build_git https://github.com/mer-hybris/libgbinder "$LIBGBINDER_TAG" \
  bash -c 'make -j"$(nproc)" release pkgconfig && make install-dev DESTDIR="'"$BUNDLE"'" LIBDIR=/usr/lib'

build_git https://github.com/mer-hybris/python-gbinder "$PYTHON_GBINDER_TAG" \
  bash -c 'python3 setup.py build && python3 setup.py install --prefix=/usr --root="'"$BUNDLE"'"'

build_git https://github.com/waydroid/waydroid "$WAYDROID_TAG" \
  bash -c 'make install DESTDIR="'"$BUNDLE"'" PREFIX=/usr USE_SYSTEMD=0 USE_NFTABLES=1'

# Headers and static archives are build-time only.
rm -rf "$BUNDLE/usr/include" "$BUNDLE/usr/lib/pkgconfig"
find "$BUNDLE" -name '*.a' -delete

# ---------------------------------------------------------------------------
msg "Recording provenance"
{
  echo "built: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "steamos_repos: ${STEAMOS_SUFFIX:-3.8.1x}"
  echo "glibc: $(ldd --version | head -1 | grep -oE '[0-9.]+$')"
  echo "python: $(python3 --version | awk '{print $2}')"
  echo "libglibutil: $LIBGLIBUTIL_TAG"
  echo "libgbinder: $LIBGBINDER_TAG"
  echo "python-gbinder: $PYTHON_GBINDER_TAG"
  echo "waydroid: $WAYDROID_TAG"
} > "$BUNDLE/BUNDLE-INFO"
cp "$STAGE/bundled-packages.txt" "$BUNDLE/BUNDLED-PACKAGES"

msg "Packing"
tar -C "$BUNDLE" -czf "$OUT/deckdroid-bundle-x86_64.tar.gz" .
( cd "$OUT" && sha256sum deckdroid-bundle-x86_64.tar.gz > deckdroid-bundle-x86_64.tar.gz.sha256 )
ls -lh "$OUT"
