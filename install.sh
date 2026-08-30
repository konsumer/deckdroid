#!/bin/bash
# Bootstrap deckdroid on a Steam Deck.
#   curl -sSfL https://raw.githubusercontent.com/konsumer/deckdroid/main/install.sh | bash
#   ... or choose a location:
#   curl -sSfL .../install.sh | bash -s -- --root /run/media/deck/SD/Android
set -euo pipefail

REPO=${DECKDROID_REPO:-konsumer/deckdroid}
ROOT=${DECKDROID_ROOT:-$HOME/Android_Waydroid}
SIZE=32G

while [ $# -gt 0 ]; do
  case $1 in
    --root) ROOT=$2; shift 2 ;;
    --size) SIZE=$2; shift 2 ;;
    *) echo "usage: install.sh [--root DIR] [--size 32G]" >&2; exit 1 ;;
  esac
done

say() { printf '\033[1;36m::\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -ne 0 ] || die "run this as your normal user, not root"

# Fail early and legibly rather than part-way through a large download.
awk '$2 == "binder" { f = 1 } END { exit !f }' /proc/filesystems || die \
"this kernel has no binder support, so Waydroid cannot run.
  running: $(uname -r)
  SteamOS 3.8.16 (kernel 6.16) has it built in; 6.11, 6.18 and 7.2 do not.
  Check for a SteamOS update first."

say "installing deckdroid to $ROOT"
mkdir -p "$ROOT/bin"

say "fetching launcher scripts"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
curl -fSL --progress-bar -o "$tmp/tools.tar.gz" \
  "https://github.com/$REPO/releases/download/latest/deckdroid-tools.tar.gz" \
  || die "could not download launcher scripts"
tar -C "$ROOT/bin" -xzf "$tmp/tools.tar.gz"
chmod +x "$ROOT/bin/"*

exec "$ROOT/bin/deckdroid" install --root "$ROOT" --size "$SIZE"
