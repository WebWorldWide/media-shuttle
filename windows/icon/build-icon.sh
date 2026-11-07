#!/usr/bin/env bash
# Renders the Windows .ico and the Linux app icon from the SVGs in this folder.
# Needs rsvg-convert and ImageMagick (brew install librsvg imagemagick).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

pngs=()
for size in 16 20 24 32 40 48 64 96 128 256; do
  source="$here/MediaShuttle.svg"
  if (( size <= 40 )); then source="$here/MediaShuttle-small.svg"; fi
  rsvg-convert -w "$size" -h "$size" "$source" -o "$work/$size.png"
  pngs+=("$work/$size.png")
done
magick "${pngs[@]}" "$repo/windows/src/MediaShuttle/Assets/MediaShuttle.ico"
cp "$here/MediaShuttle.svg" "$repo/linux/assets/media-shuttle.svg"
echo "Wrote windows/src/MediaShuttle/Assets/MediaShuttle.ico and linux/assets/media-shuttle.svg"
