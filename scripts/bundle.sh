#!/bin/bash
set -e

# Build configuration
# - CONFIG=debug|release  (default: debug)
# - UNIVERSAL=1           build a fat arm64+x86_64 binary (default: host arch only)
CONFIG="${CONFIG:-debug}"
UNIVERSAL="${UNIVERSAL:-0}"

for arg in "$@"; do
    case "$arg" in
        --universal) UNIVERSAL=1 ;;
        --release)   CONFIG="release" ;;
        --debug)     CONFIG="debug" ;;
    esac
done

# Paths
APP_NAME="capcap.app"
APP_DIR="build/$APP_NAME"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

# Build binary
if [ "$UNIVERSAL" = "1" ]; then
    echo "Building capcap ($CONFIG, universal: arm64 + x86_64)..."
    swift build -c "$CONFIG" --arch arm64 --arch x86_64
    # SwiftPM emits the merged universal binary under .build/apple/Products/<Config>/
    CONFIG_CAP="$(tr '[:lower:]' '[:upper:]' <<< "${CONFIG:0:1}")${CONFIG:1}"
    BUILD_BIN=".build/apple/Products/$CONFIG_CAP/capcap"
    if [ ! -f "$BUILD_BIN" ]; then
        # Fallback: merge per-arch binaries with lipo
        ARM_BIN=".build/arm64-apple-macosx/$CONFIG/capcap"
        X86_BIN=".build/x86_64-apple-macosx/$CONFIG/capcap"
        if [ -f "$ARM_BIN" ] && [ -f "$X86_BIN" ]; then
            BUILD_BIN=".build/$CONFIG/capcap-universal"
            lipo -create -output "$BUILD_BIN" "$ARM_BIN" "$X86_BIN"
        else
            echo "error: universal binary not found at $BUILD_BIN and per-arch fallbacks missing" >&2
            exit 1
        fi
    fi
else
    echo "Building capcap ($CONFIG, host arch only)..."
    swift build -c "$CONFIG"
    BUILD_BIN=".build/$CONFIG/capcap"
fi

# Clean previous bundle
rm -rf "$APP_DIR"

# Create .app bundle structure
mkdir -p "$MACOS"
mkdir -p "$RESOURCES"

# Copy binary
cp "$BUILD_BIN" "$MACOS/capcap"

# Copy Info.plist
cp "capcap/App/Info.plist" "$CONTENTS/Info.plist"

# Copy app icon
cp "Resources/AppIcon.icns" "$RESOURCES/AppIcon.icns"

# Copy menu bar icon source. The SVG lives in design/ so tweaking it updates the
# app bundle on the next rebuild without touching Swift code.
cp "design/menuBarIcon.svg" "$RESOURCES/MenuBarIcon.svg"

# Copy localization bundles (.lproj). The app loads these directly for its
# in-app language picker — see Localizer.swift.
for lproj in Resources/*.lproj; do
    [ -d "$lproj" ] || continue
    cp -R "$lproj" "$RESOURCES/"
done

# Code signing
# -----------------------------------------------------------------------------
# Sign with the SAME self-signed certificate CI uses ("capcap Self-Signed") so
# the app's code-signing identity — and therefore its macOS TCC permission
# grants (Screen Recording / Accessibility) — stay stable between local test
# builds and released builds. Without this, every local rebuild looks like a
# different app to TCC and you must re-authorize.
#
# Import the cert once (it lives in capcap-signing.p12, default password "capcap"):
#   security import ~/Desktop/capcap-signing.p12 \
#     -k ~/Library/Keychains/login.keychain-db -P capcap -T /usr/bin/codesign
#
# Override the identity with the SIGN_IDENTITY env var. If the cert isn't in the
# keychain, fall back to ad-hoc signing (still launchable, but TCC grants won't
# match released builds).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SIGN_IDENTITY="${SIGN_IDENTITY:-capcap Self-Signed}"
if security find-identity -p codesigning 2>/dev/null | grep -qF "$SIGN_IDENTITY"; then
    echo "Signing with: $SIGN_IDENTITY"
    codesign --force --deep --entitlements "$SCRIPT_DIR/capcap.entitlements" \
        --sign "$SIGN_IDENTITY" "$APP_DIR"
else
    echo "warning: '$SIGN_IDENTITY' not found in keychain — falling back to ad-hoc signing." >&2
    echo "warning: TCC permissions won't match released builds until you import capcap-signing.p12." >&2
    codesign --force --deep --entitlements "$SCRIPT_DIR/capcap.entitlements" --sign - "$APP_DIR"
fi

echo "✅ Built and signed $APP_DIR"
ARCHS=$(lipo -archs "$MACOS/capcap" 2>/dev/null || echo "unknown")
echo "   Architectures: $ARCHS"
echo ""
echo "To run:"
echo "  open build/$APP_NAME"
echo ""
echo "To install to /Applications:"
echo "  cp -r build/$APP_NAME /Applications/"
