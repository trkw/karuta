#!/bin/sh
# Support/AppIcon.svg から Support/AppIcon.icns を作り直す（macOS 用）
# 必要なもの: rsvg-convert（brew install librsvg）と iconutil（標準）
# pngquant（brew install pngquant）があれば減色してサイズを小さくする
set -eu
cd "$(dirname "$0")/.."

command -v rsvg-convert >/dev/null || { echo "rsvg-convert がありません: brew install librsvg" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
set="$work/AppIcon.iconset"
mkdir "$set"
render() { rsvg-convert -w "$1" -h "$1" Support/AppIcon.svg -o "$set/$2"; }
for size in 16 32 128 256 512; do
	render "$size" "icon_${size}x${size}.png"
	# 512@2x（1024px）はほぼ使われず大きいので入れない
	if [ "$size" -lt 512 ]; then render $((size * 2)) "icon_${size}x${size}@2x.png"; fi
done
if command -v pngquant >/dev/null; then
	pngquant --force --ext .png --quality 80-95 "$set"/*.png
fi
iconutil -c icns "$set" -o Support/AppIcon.icns
ls -lh Support/AppIcon.icns
