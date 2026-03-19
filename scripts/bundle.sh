#!/bin/bash
set -e

# Build binary
echo "Building capcap..."
swift build -c debug

# Paths
BUILD_DIR=".build/debug"
APP_NAME="capcap.app"
APP_DIR="build/$APP_NAME"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

# Clean previous build
rm -rf "build/$APP_NAME"

# Create .app bundle structure
mkdir -p "$MACOS"
mkdir -p "$RESOURCES"

# Copy binary
cp "$BUILD_DIR/capcap" "$MACOS/capcap"

# Copy Info.plist
cp "capcap/App/Info.plist" "$CONTENTS/Info.plist"

# Code sign with ad-hoc signature (stable identity for macOS permissions)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
codesign --force --sign - --entitlements "$SCRIPT_DIR/capcap.entitlements" "$APP_DIR"

echo "✅ Built and signed $APP_DIR"
echo ""
echo "To run:"
echo "  open build/$APP_NAME"
echo ""
echo "To install to /Applications:"
echo "  cp -r build/$APP_NAME /Applications/"
