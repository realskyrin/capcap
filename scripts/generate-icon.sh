#!/usr/bin/env bash
# Render a source SVG into AppIcon.icns + PNGs for the asset catalog.
# Usage: scripts/generate-icon.sh [path/to/source.svg]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${1:-$ROOT/design/AppIcon-3-pink-blue.svg}"

if [[ ! -f "$SRC" ]]; then
    echo "error: source SVG not found: $SRC" >&2
    exit 1
fi

ICNS_OUT="$ROOT/Resources/AppIcon.icns"
APPICONSET="$ROOT/Resources/Assets.xcassets/AppIcon.appiconset"
WORK="$(mktemp -d)"
ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"

echo "==> rendering $SRC → 1024x1024 master PNG"
qlmanage -t -s 1024 -o "$WORK" "$SRC" >/dev/null 2>&1
MASTER="$WORK/$(basename "$SRC").png"
[[ -f "$MASTER" ]] || { echo "error: qlmanage failed to produce $MASTER" >&2; exit 1; }

# iconutil expects these specific filenames inside the .iconset folder.
declare -a SPECS=(
    "16:icon_16x16.png"
    "32:icon_16x16@2x.png"
    "32:icon_32x32.png"
    "64:icon_32x32@2x.png"
    "128:icon_128x128.png"
    "256:icon_128x128@2x.png"
    "256:icon_256x256.png"
    "512:icon_256x256@2x.png"
    "512:icon_512x512.png"
    "1024:icon_512x512@2x.png"
)

for spec in "${SPECS[@]}"; do
    size="${spec%%:*}"
    name="${spec##*:}"
    dst="$ICONSET/$name"
    cp "$MASTER" "$dst"
    sips -z "$size" "$size" "$dst" >/dev/null
done

echo "==> iconutil → $ICNS_OUT"
mkdir -p "$(dirname "$ICNS_OUT")"
iconutil -c icns "$ICONSET" -o "$ICNS_OUT"

# Mirror the PNGs into the asset catalog so an Xcode build (if ever used) picks them up.
echo "==> populating $APPICONSET"
mkdir -p "$APPICONSET"
declare -a CATALOG=(
    "16:icon_16.png"
    "32:icon_16@2x.png"
    "32:icon_32.png"
    "64:icon_32@2x.png"
    "128:icon_128.png"
    "256:icon_128@2x.png"
    "256:icon_256.png"
    "512:icon_256@2x.png"
    "512:icon_512.png"
    "1024:icon_512@2x.png"
)
for spec in "${CATALOG[@]}"; do
    size="${spec%%:*}"
    name="${spec##*:}"
    dst="$APPICONSET/$name"
    cp "$MASTER" "$dst"
    sips -z "$size" "$size" "$dst" >/dev/null
done

# Refresh Contents.json so each entry references its filename.
cat > "$APPICONSET/Contents.json" <<'JSON'
{
  "images": [
    { "idiom": "mac", "scale": "1x", "size": "16x16",   "filename": "icon_16.png" },
    { "idiom": "mac", "scale": "2x", "size": "16x16",   "filename": "icon_16@2x.png" },
    { "idiom": "mac", "scale": "1x", "size": "32x32",   "filename": "icon_32.png" },
    { "idiom": "mac", "scale": "2x", "size": "32x32",   "filename": "icon_32@2x.png" },
    { "idiom": "mac", "scale": "1x", "size": "128x128", "filename": "icon_128.png" },
    { "idiom": "mac", "scale": "2x", "size": "128x128", "filename": "icon_128@2x.png" },
    { "idiom": "mac", "scale": "1x", "size": "256x256", "filename": "icon_256.png" },
    { "idiom": "mac", "scale": "2x", "size": "256x256", "filename": "icon_256@2x.png" },
    { "idiom": "mac", "scale": "1x", "size": "512x512", "filename": "icon_512.png" },
    { "idiom": "mac", "scale": "2x", "size": "512x512", "filename": "icon_512@2x.png" }
  ],
  "info": { "author": "xcode", "version": 1 }
}
JSON

rm -rf "$WORK"
echo "==> done."
echo "    icns:    $ICNS_OUT"
echo "    catalog: $APPICONSET"
