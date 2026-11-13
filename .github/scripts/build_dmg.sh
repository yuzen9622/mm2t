#!/bin/bash
# Usage: build_dmg.sh <mm2t.app> <output.dmg>
# Builds the installer DMG (background, icon positions, volume icon) with dmgbuild, which writes the
# .DS_Store directly and needs no Finder or AppleScript. Settings live in .github/dmg/.
set -euo pipefail

app="$1"
dmg="$2"
dmgbuild_version=1.6.7
dir="$(cd "$(dirname "$0")/../dmg" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

icon="$app/Contents/Resources/MM2T.icns"
if [[ ! -f "$icon" ]]; then
  echo "::error::$icon is missing, so the DMG would have no volume icon"
  exit 1
fi

python3 -m venv "$work/venv"
"$work/venv/bin/pip" install --quiet "dmgbuild==$dmgbuild_version"

# One TIFF carrying both the 1x and 2x background so Retina displays stay sharp.
tiffutil -cathidpicheck "$dir/background.png" "$dir/background@2x.png" -out "$work/background.tiff"

rm -f "$dmg"
# hdiutil on hosted runners sometimes fails with "Resource busy"; a retry clears it.
for attempt in 1 2 3; do
  "$work/venv/bin/dmgbuild" -s "$dir/settings.py" \
    -D app="$app" -D icon="$icon" -D background="$work/background.tiff" \
    mm2t "$dmg" && break
  if [[ $attempt -eq 3 ]]; then exit 1; fi
  sleep 10
done
