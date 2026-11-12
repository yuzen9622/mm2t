#!/usr/bin/env bash
# Renders both locales: soundtrack from src/cues.json, picture from Remotion (muted), muxed by ffmpeg.
# Usage: scripts/render.sh [zh|en|all]
set -euo pipefail
cd "$(dirname "$0")/.."
PY=${PROMO_PYTHON:-../.build/promo-venv/bin/python}
"$PY" scripts/soundtrack.py
mkdir -p out/tmp
for loc in ${1:-zh en}; do
  [[ "$loc" == all ]] && continue
  comp=$([[ "$loc" == zh ]] && echo PromoZh || echo PromoEn)
  npx remotion render src/index.ts "$comp" "out/tmp/$loc-picture.mp4" --muted --codec=h264 --crf=16 --x264-preset=slow --log=error
  ffmpeg -loglevel error -y -i "out/tmp/$loc-picture.mp4" -i public/audio/soundtrack.wav \
    -map 0:v -map 1:a -c:v copy -c:a aac -b:a 256k -movflags +faststart -shortest "out/mm2t-promo-$loc.mp4"
  echo "out/mm2t-promo-$loc.mp4"
done
