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
LIBGLIBUTIL_REPO=https://github.com/sailfishos/libglibutil
LIBGLIBUTIL_TAG=1.0.82
LIBGBINDER_REPO=https://github.com/mer-hybris/libgbinder
LIBGBINDER_TAG=1.1.52
GBINDER_PYTHON_REPO=https://github.com/waydroid/gbinder-python
GBINDER_PYTHON_TAG=1.1.2
WAYDROID_REPO=https://github.com/waydroid/waydroid
WAYDROID_TAG=1.6.3

# Binary packages to pull from the SteamOS repos.
BINARY_PKGS=(lxc cage wlr-randr dnsmasq)

msg() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

rm -rf "$STAGE"
# pacman refuses to initialise against a root whose db dir does not exist yet.
mkdir -p "$PKGROOT/var/lib/pacman" "$PKGROOT/var/cache/pacman/pkg" "$BUNDLE/usr" "$OUT"

# ---------------------------------------------------------------------------
msg "Resolving binary packages into an alternate root"
# pacman does the dependency closure for us; -r keeps it out of the build image.
# --hookdir suppresses post-transaction hooks, which are meaningless against an
# alternate root with no /dev and only produce noise.
sudo pacman -r "$PKGROOT" -Sy --noconfirm --dbpath "$PKGROOT/var/lib/pacman" \
  --hookdir "$PKGROOT/nonexistent-hooks" "${BINARY_PKGS[@]}"

msg "Selecting packages the Deck does not already ship"
# Anything present in SteamOS is a liability to ship: a second copy of
# mesa/libdrm/glibc would shadow the host's own stack over LD_LIBRARY_PATH.
# So rather than deleting what we do not want, copy in only what we do -- that
# way nothing can survive by accident.
pac() { sudo pacman -r "$PKGROOT" --dbpath "$PKGROOT/var/lib/pacman" "$@"; }

mapfile -t installed < <(pac -Qq)
kept=()
for pkg in "${installed[@]}"; do
  grep -qx "$pkg" "$DECK_LIST" || kept+=("$pkg")
done
echo "bundling ${#kept[@]} of ${#installed[@]} packages; SteamOS already has the rest"
printf '%s\n' "${kept[@]}" > "$STAGE/bundled-packages.txt"

msg "Copying their files into the bundle"
for pkg in "${kept[@]}"; do
  while read -r f; do
    # pacman -Ql prints paths prefixed with the alternate root; strip it so the
    # patterns below see the real /usr/... path.
    f=${f#"$PKGROOT"}
    case "$f" in
      */) continue ;;                                  # directory entry
      /usr/share/man/*|/usr/share/doc/*|/usr/share/info/*|/usr/share/locale/*) continue ;;
      /usr/bin/*|/usr/lib/*|/usr/libexec/*|/usr/share/*) ;;
      *) continue ;;                                   # nothing outside /usr relocates
    esac
    [ -e "$PKGROOT$f" ] || [ -L "$PKGROOT$f" ] || continue
    mkdir -p "$BUNDLE$(dirname "$f")"
    sudo cp -a "$PKGROOT$f" "$BUNDLE$f"
  done < <(pac -Qlq "$pkg")
done

sudo chown -R "$(id -u):$(id -g)" "$BUNDLE"
# Everything must stay readable by whoever unpacks it, and a user-owned
# relocated bundle has no business carrying setuid bits.
sudo chmod -R u+rwX,go-s "$BUNDLE"

# ---------------------------------------------------------------------------
build_git() { # url tag builder...
  local url=$1 tag=$2; shift 2
  local name; name=$(basename "$url" .git)
  msg "Building $name $tag"
  git clone --depth 1 --branch "$tag" "$url" "$STAGE/$name"
  ( cd "$STAGE/$name" && "$@" )
}

# libglibutil and libgbinder are plain Makefiles; they honour prefix + DESTDIR.
build_git "$LIBGLIBUTIL_REPO" "$LIBGLIBUTIL_TAG" \
  bash -c 'make -j"$(nproc)" release pkgconfig && make install-dev DESTDIR="'"$BUNDLE"'" LIBDIR=/usr/lib'
# The .pc files these projects install still say prefix=/usr, so pkg-config
# hands back include paths that do not exist in a relocated tree. Point the
# compiler at the real locations explicitly; our -I comes first and wins.
export PKG_CONFIG_PATH=$BUNDLE/usr/lib/pkgconfig
export CFLAGS="-I$BUNDLE/usr/include -I$BUNDLE/usr/include/gutil -I$BUNDLE/usr/include/gbinder"
export LDFLAGS="-L$BUNDLE/usr/lib"

build_git "$LIBGBINDER_REPO" "$LIBGBINDER_TAG" \
  bash -c 'make -j"$(nproc)" release pkgconfig && make install-dev DESTDIR="'"$BUNDLE"'" LIBDIR=/usr/lib'

# gbinder.c is not committed upstream, so the .pyx must be cythonised here.
# setup.py still imports distutils; setuptools supplies the shim on Python 3.13.
build_git "$GBINDER_PYTHON_REPO" "$GBINDER_PYTHON_TAG" \
  bash -c 'python3 setup.py --cython build && python3 setup.py --cython install --prefix=/usr --root="'"$BUNDLE"'"'

build_git "$WAYDROID_REPO" "$WAYDROID_TAG" \
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
  echo "gbinder-python: $GBINDER_PYTHON_TAG"
  echo "waydroid: $WAYDROID_TAG"
} > "$BUNDLE/BUNDLE-INFO"
cp "$STAGE/bundled-packages.txt" "$BUNDLE/BUNDLED-PACKAGES"

msg "Packing"
sudo tar -C "$BUNDLE" --owner=0 --group=0 -czf "$OUT/deckdroid-bundle-x86_64.tar.gz" .
sudo chown "$(id -u):$(id -g)" "$OUT/deckdroid-bundle-x86_64.tar.gz"
( cd "$OUT" && sha256sum deckdroid-bundle-x86_64.tar.gz > deckdroid-bundle-x86_64.tar.gz.sha256 )
ls -lh "$OUT"
