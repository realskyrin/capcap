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

# Resolve the SDK explicitly for both configurations. An unqualified SDK lookup
# can retain a stale Command Line Tools path and produce a binary that opts into
# legacy AppKit controls, even when the selected Xcode has a newer SDK.
MACOS_SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
if [ ! -d "$MACOS_SDK_PATH" ] || [ ! -f "$MACOS_SDK_PATH/SDKSettings.plist" ]; then
    echo "error: macOS SDK not found at $MACOS_SDK_PATH" >&2
    exit 1
fi
echo "Using macOS SDK: $MACOS_SDK_PATH"

# Swift's Clang linker invocation can use --sysroot, which does not populate
# Clang's Darwin SDK version. Pass -isysroot as well so LC_BUILD_VERSION records
# the actual SDK instead of the deployment target, preserving modern controls.
SWIFT_SDK_ARGS=(--sdk "$MACOS_SDK_PATH"
    -Xswiftc -Xclang-linker -Xswiftc "-isysroot$MACOS_SDK_PATH")

# Paths
APP_NAME="capcap.app"
APP_DIR="build/$APP_NAME"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
PLUGINS="$CONTENTS/PlugIns"
EXTENSION_PRODUCT_NAME="CapcapShareExtension"
EXTENSION_NAME="$EXTENSION_PRODUCT_NAME.appex"
EXTENSION_DIR="$PLUGINS/$EXTENSION_NAME"
EXTENSION_CONTENTS="$EXTENSION_DIR/Contents"
EXTENSION_MACOS="$EXTENSION_CONTENTS/MacOS"
EXTENSION_RESOURCES="$EXTENSION_CONTENTS/Resources"

# Use identical options for the build and SwiftPM's output-path query so app,
# extension, and resources always come from the current build system's output.
SWIFT_BUILD_ARGS=(-c "$CONFIG" "${SWIFT_SDK_ARGS[@]}")
if [ "$UNIVERSAL" = "1" ]; then
    echo "Building capcap ($CONFIG, universal: arm64 + x86_64)..."
    SWIFT_BUILD_ARGS+=(--arch arm64 --arch x86_64)
else
    echo "Building capcap ($CONFIG, host arch only)..."
fi
swift build "${SWIFT_BUILD_ARGS[@]}"
BUILD_DIR="$(swift build "${SWIFT_BUILD_ARGS[@]}" --show-bin-path)"
BUILD_BIN="$BUILD_DIR/capcap"
EXTENSION_BUILD_BIN="$BUILD_DIR/$EXTENSION_PRODUCT_NAME"
echo "Using SwiftPM products: $BUILD_DIR"

if [ ! -f "$BUILD_BIN" ]; then
    echo "error: app binary not found at $BUILD_BIN" >&2
    exit 1
fi

if [ ! -f "$EXTENSION_BUILD_BIN" ]; then
    echo "error: share extension binary not found at $EXTENSION_BUILD_BIN" >&2
    exit 1
fi

PERMISSION_FLOW_BUNDLE="$BUILD_DIR/capcap_PermissionFlow.bundle"
if [ ! -d "$PERMISSION_FLOW_BUNDLE" ]; then
    echo "error: missing SwiftPM resource bundle: $PERMISSION_FLOW_BUNDLE" >&2
    exit 1
fi

if [ "$UNIVERSAL" = "1" ]; then
    for binary in "$BUILD_BIN" "$EXTENSION_BUILD_BIN"; do
        ARCHS="$(lipo -archs "$binary")"
        if [[ " $ARCHS " != *" arm64 "* ]] || [[ " $ARCHS " != *" x86_64 "* ]]; then
            echo "error: binary is not universal (archs: $ARCHS): $binary" >&2
            exit 1
        fi
    done
fi

# Clean previous bundle
rm -rf "$APP_DIR"

# Create .app bundle structure
mkdir -p "$MACOS"
mkdir -p "$RESOURCES"
mkdir -p "$EXTENSION_MACOS"
mkdir -p "$EXTENSION_RESOURCES"

# Copy binary
cp "$BUILD_BIN" "$MACOS/capcap"

# Copy share extension bundle
cp "$EXTENSION_BUILD_BIN" "$EXTENSION_MACOS/$EXTENSION_PRODUCT_NAME"
cp "capcap-share-extension/Info.plist" "$EXTENSION_CONTENTS/Info.plist"
cp "Resources/AppIcon.icns" "$EXTENSION_RESOURCES/AppIcon.icns"

# Copy Info.plist
cp "capcap/App/Info.plist" "$CONTENTS/Info.plist"
bash scripts/inject-build-metadata.sh "$CONTENTS/Info.plist"
APP_SHORT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$CONTENTS/Info.plist")"
APP_BUNDLE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$CONTENTS/Info.plist")"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_SHORT_VERSION" "$EXTENSION_CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $APP_BUNDLE_VERSION" "$EXTENSION_CONTENTS/Info.plist"

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

# Copy SwiftPM resource bundles. PermissionFlow uses Bundle.module for its
# floating authorization panel strings; if this bundle is absent, Intel builds
# crash with a Swift assertion the first time the panel is shown.
cp -R "$PERMISSION_FLOW_BUNDLE" "$RESOURCES/"

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
sign_bundles() {
    local identity="$1"
    codesign --force --entitlements "$SCRIPT_DIR/capcap-share-extension.entitlements" \
        --sign "$identity" "$EXTENSION_DIR"
    codesign --force --entitlements "$SCRIPT_DIR/capcap.entitlements" \
        --sign "$identity" "$APP_DIR"
}

if security find-identity -p codesigning 2>/dev/null | grep -qF "$SIGN_IDENTITY"; then
    echo "Signing with: $SIGN_IDENTITY"
    sign_bundles "$SIGN_IDENTITY"
else
    echo "warning: '$SIGN_IDENTITY' not found in keychain — falling back to ad-hoc signing." >&2
    echo "warning: TCC permissions won't match released builds until you import capcap-signing.p12." >&2
    sign_bundles -
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
