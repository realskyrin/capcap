#!/bin/bash
# Render the five README images from inspected, current capcap/Safari captures.
# Requires Agent Command Line to be on in capcap Settings > Permissions.
set -euo pipefail
if [ "$#" -ne 5 ]; then
  echo "Usage: $0 SOURCE.png EDITOR.png BEAUTIFY.png SETTINGS.png OUTPUT_DIR" >&2
  exit 64
fi
CAPCAP="${CAPCAP:-/Applications/capcap.app/Contents/MacOS/capcap}"
DEMO_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="$5"
mkdir -p "$OUTPUT_DIR"
render() {
  "$CAPCAP" agent validate --input "$1" --spec "$DEMO_DIR/$2.json"
  "$CAPCAP" agent annotate --input "$1" --spec "$DEMO_DIR/$2.json" --out "$OUTPUT_DIR/$3.png"
}
render "$1" spotlight spotlight
render "$1" magnifier magnifier
render "$2" editor-frame editor
render "$3" beautify-frame beautify
render "$4" settings-frame image-hosting
