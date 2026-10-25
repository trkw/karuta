#!/bin/sh
# Support/AppIcon.svg から Support/AppIcon.icns を作り直す（macOS 用）
# 必要なもの: rsvg-convert（brew install librsvg）と iconutil（標準）
set -eu
cd "$(dirname "$0")/.."

command -v rsvg-convert >/dev/null || { echo "rsvg-convert がありません: brew install librsvg" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
set="$work/AppIcon.iconset"
mkdir "$set"
for size in 16 32 128 256 512; do
	rsvg-convert -w "$size" -h "$size" Support/AppIcon.svg -o "$set/icon_${size}x${size}.png"
	rsvg-convert -w $((size * 2)) -h $((size * 2)) Support/AppIcon.svg -o "$set/icon_${size}x${size}@2x.png"
done
iconutil -c icns "$set" -o Support/AppIcon.icns
ls -lh Support/AppIcon.icns
