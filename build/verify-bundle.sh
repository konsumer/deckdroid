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
note() { printf '  %-46s %s\n' "$1" "$2"; }

echo "== required entrypoints"
for f in usr/bin/waydroid usr/bin/lxc-start usr/bin/cage usr/lib/libgbinder.so \
         usr/lib/waydroid/waydroid.py; do
  if [ -e "$ROOT/$f" ]; then note "$f" "ok"; else note "$f" "MISSING"; fail=1; fi
done

# Collect ELF objects once. Reading the 4-byte magic directly is far cheaper
# than shelling out to file(1) for every path in the tree.
mapfile -t elves < <(
  find "$ROOT" -type f \( -perm -u+x -o -name '*.so*' \) -print0 \
    | while IFS= read -r -d '' p; do
        [ "$(head -c4 "$p" 2>/dev/null)" = $'\x7fELF' ] && printf '%s\n' "$p"
      done
)
echo "== scanning ${#elves[@]} ELF objects"

echo "== no build-time paths leaked into ELF headers"
leaked=0
for elf in "${elves[@]}"; do
  rp=$(readelf -d "$elf" 2>/dev/null | grep -E 'RPATH|RUNPATH' || true)
  case "$rp" in
    *"/tmp/stage"*|*"/work"*|*"/out"*|*"$ROOT"*)
      note "$(basename "$elf")" "leaks ${rp##*\[}"; leaked=1; fail=1 ;;
  esac
done
[ "$leaked" -eq 0 ] && note "no RPATH/RUNPATH points at the build tree" "ok"

echo "== every needed library resolves"
declare -A have=()
while read -r s; do have["$s"]=host; done < "$HOST_SONAMES"
# Sonames are usually symlinks (libfoo.so.1 -> libfoo.so.1.2.3), so symlinks
# must count as provided; -type f alone would miss almost all of them.
while read -r l; do have["$(basename "$l")"]=bundle; done \
  < <(find "$ROOT" -name '*.so*' \( -type f -o -type l \))

missing=()
for elf in "${elves[@]}"; do
  while read -r need; do
    [ -n "$need" ] || continue
    [ -n "${have[$need]:-}" ] || missing+=("$(basename "$elf") -> $need")
  done < <(readelf -d "$elf" 2>/dev/null | awk -F'[][]' '/NEEDED/{print $2}')
done

if [ ${#missing[@]} -gt 0 ]; then
  printf '%s\n' "${missing[@]}" | sort -u | sed 's/^/  UNRESOLVED /'
  fail=1
else
  note "all sonames resolve against bundle + SteamOS" "ok"
fi

echo "== contents"
du -sh "$ROOT" | sed 's/^/  /'
sed 's/^/  /' "$ROOT/BUNDLE-INFO" 2>/dev/null || true
echo "  bundled packages: $(tr '\n' ' ' < "$ROOT/BUNDLED-PACKAGES" 2>/dev/null)"

rm -rf "$ROOT"
[ "$fail" -eq 0 ] && echo "PASS" || { echo "FAIL"; exit 1; }
