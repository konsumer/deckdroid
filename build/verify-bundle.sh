#!/bin/bash
# Fails the build unless the bundle is genuinely relocatable and self-consistent.
#
# The bundle is untarred to a random path, then every ELF in it is checked so
# that each library it needs is either inside the bundle or provided by SteamOS
# itself (build/deck-sonames-*.txt, captured from a real Deck). A soname in
# neither list means the Deck would fail to start it at runtime.
set -euo pipefail

TARBALL=${1:?usage: verify-bundle.sh <tarball>}
SRC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HOST_SONAMES=$SRC_DIR/deck-sonames-3.8.16.txt

# A path that shares no prefix with wherever it was built.
ROOT=$(mktemp -d /tmp/relocate-XXXXXX)/deeply/nested/elsewhere
mkdir -p "$ROOT"
tar -C "$ROOT" -xzf "$TARBALL"

fail=0
note() { printf '  %-44s %s\n' "$1" "$2"; }

echo "== required entrypoints"
for f in usr/bin/waydroid usr/bin/lxc-start usr/bin/cage usr/lib/libgbinder.so; do
  if [ -e "$ROOT/$f" ]; then note "$f" "ok"; else note "$f" "MISSING"; fail=1; fi
done

echo "== no build-time paths leaked into ELF headers"
# An RPATH/RUNPATH pointing at the build stage means the binary only works there.
while read -r elf; do
  rp=$(readelf -d "$elf" 2>/dev/null | grep -E 'RPATH|RUNPATH' | grep -oE '\[.*\]' || true)
  case "$rp" in
    *"/tmp/stage"*|*"/work"*|*"/out"*) note "$(basename "$elf")" "leaks $rp"; fail=1 ;;
  esac
done < <(find "$ROOT" -type f -exec sh -c 'file -b "$1" | grep -q ELF' _ {} \; -print)

echo "== every needed library resolves"
declare -A have=()
while read -r s; do have["$s"]=host; done < "$HOST_SONAMES"
while read -r l; do have["$(basename "$l")"]=bundle; done < <(find "$ROOT" -name '*.so*' -type f)

missing=()
while read -r elf; do
  while read -r need; do
    [ -n "$need" ] || continue
    [ -n "${have[$need]:-}" ] || missing+=("$(basename "$elf") -> $need")
  done < <(readelf -d "$elf" 2>/dev/null | awk -F'[][]' '/NEEDED/{print $2}')
done < <(find "$ROOT" -type f -exec sh -c 'file -b "$1" | grep -q ELF' _ {} \; -print)

if [ ${#missing[@]} -gt 0 ]; then
  printf '%s\n' "${missing[@]}" | sort -u | sed 's/^/  UNRESOLVED /'
  fail=1
else
  note "all sonames" "resolve against bundle + SteamOS"
fi

echo "== bundle contents"
du -sh "$ROOT"
cat "$ROOT/BUNDLE-INFO" 2>/dev/null | sed 's/^/  /'

rm -rf "$ROOT"
[ "$fail" -eq 0 ] && echo "PASS" || { echo "FAIL"; exit 1; }
