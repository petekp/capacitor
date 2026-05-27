#!/usr/bin/env bash
set -euo pipefail

WORKTREE_PATH=""
APP_PATH=""
BUNDLE_ID="com.capacitor.app.preview"
DISPLAY_NAME="Capacitor Preview"
SWIFT_ONLY=false
SWIFT_SCRATCH_PATH=""

if [[ -n "${HOME:-}" ]]; then
    export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"
else
    export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"
fi

usage() {
    cat <<EOF
Usage: build-preview-app.sh --worktree <path> [--app-path <path>] [--bundle-id <id>] [--display-name <name>] [--swift-scratch-path <path>] [--swift-only]

Build a local Capacitor Preview .app from an explicit worktree.
This is intentionally narrow: it proves the Preview App contract for Capacitor
without trying to support arbitrary macOS app layouts.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --worktree)
            WORKTREE_PATH="${2:-}"
            shift 2
            ;;
        --app-path)
            APP_PATH="${2:-}"
            shift 2
            ;;
        --bundle-id)
            BUNDLE_ID="${2:-}"
            shift 2
            ;;
        --display-name)
            DISPLAY_NAME="${2:-}"
            shift 2
            ;;
        --swift-scratch-path)
            SWIFT_SCRATCH_PATH="${2:-}"
            shift 2
            ;;
        --swift-only)
            SWIFT_ONLY=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "error: unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [[ -z "$WORKTREE_PATH" ]]; then
    echo "error: --worktree is required" >&2
    exit 2
fi

PROJECT_ROOT="$(cd "$WORKTREE_PATH" && pwd -P)"
APP_PATH="${APP_PATH:-$PROJECT_ROOT/apps/swift/CapacitorPreview.app}"

if [[ "$APP_PATH" != /* ]]; then
    APP_PATH="$PROJECT_ROOT/$APP_PATH"
fi

APP_PARENT="$(dirname "$APP_PATH")"
APP_BASENAME="$(basename "$APP_PATH")"
if [[ ! -d "$APP_PARENT" ]]; then
    echo "error: preview app parent directory does not exist: $APP_PARENT" >&2
    exit 2
fi
APP_PARENT="$(cd "$APP_PARENT" && pwd -P)"
APP_PATH="$APP_PARENT/$APP_BASENAME"

if [[ "$APP_PATH" != "$PROJECT_ROOT/"* ]]; then
    echo "error: --app-path must be inside --worktree" >&2
    exit 2
fi

if [[ "$APP_PATH" != *.app ]]; then
    echo "error: --app-path must end in .app" >&2
    exit 2
fi

write_plist_string() {
    local plist_path="$1"
    local key="$2"
    local value="$3"

    if ! /usr/libexec/PlistBuddy -c "Set :$key $value" "$plist_path" 2>/dev/null; then
        /usr/libexec/PlistBuddy -c "Add :$key string $value" "$plist_path" 2>/dev/null || true
    fi
}

write_plist_bool() {
    local plist_path="$1"
    local key="$2"
    local value="$3"

    if ! /usr/libexec/PlistBuddy -c "Set :$key $value" "$plist_path" 2>/dev/null; then
        /usr/libexec/PlistBuddy -c "Add :$key bool $value" "$plist_path" 2>/dev/null || true
    fi
}

find_signing_identity() {
    local signing_identity="${CAPACITOR_SIGNING_IDENTITY:-}"
    local cert_line=""

    if [[ -n "$signing_identity" ]]; then
        printf '%s\n' "$signing_identity"
        return 0
    fi

    cert_line="$(security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application" | head -1 || true)"
    if [[ -z "$cert_line" ]]; then
        cert_line="$(security find-identity -v -p codesigning 2>/dev/null | grep "Apple Development" | head -1 || true)"
    fi

    if [[ -n "$cert_line" ]]; then
        printf '%s\n' "$cert_line" | awk '{print $2}'
        return 0
    fi

    printf '%s\n' "-"
}

require_command() {
    local command_name="$1"

    if ! command -v "$command_name" >/dev/null 2>&1; then
        echo "error: required command not found on PATH: $command_name" >&2
        exit 127
    fi
}

compile_metal_if_needed() {
    local metal_dir="Sources/Capacitor/Shaders"
    local metal_outdir="Sources/Capacitor/Resources/Shaders"
    local metal_out="$metal_outdir/default.metallib"
    local needs_rebuild=false
    local src
    local base
    local air_files=""

    mkdir -p "$metal_outdir"
    for src in "$metal_dir"/*.metal; do
        if [[ "$src" -nt "$metal_out" || ! -f "$metal_out" ]]; then
            needs_rebuild=true
            break
        fi
    done

    if [[ "$needs_rebuild" == true ]]; then
        for src in "$metal_dir"/*.metal; do
            base="$(basename "$src" .metal)"
            xcrun metal -fno-fast-math -c "$src" -o "/tmp/$base.air"
            air_files="$air_files /tmp/$base.air"
        done
        xcrun metallib $air_files -o "$metal_out"
        rm -f $air_files
    fi
}

create_bundle_skeleton() {
    local app_path="$1"

    mkdir -p "$app_path/Contents/MacOS"
    mkdir -p "$app_path/Contents/Frameworks"
    mkdir -p "$app_path/Contents/Resources"

    cat > "$app_path/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>Capacitor</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${DISPLAY_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${DISPLAY_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <false/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticTermination</key>
    <true/>
    <key>NSSupportsSuddenTermination</key>
    <false/>
</dict>
</plist>
EOF
}

cd "$PROJECT_ROOT"

require_command swift
require_command xcrun
require_command rsync
require_command install_name_tool
require_command otool
require_command codesign
require_command security

if [[ "$SWIFT_ONLY" != true ]]; then
    require_command cargo
    cargo build -p capacitor-core -p hud-hook --release
    "$PROJECT_ROOT/scripts/dev/fix-dylib.sh"
fi

cd "$PROJECT_ROOT/apps/swift"
SWIFT_SCRATCH_PATH="${SWIFT_SCRATCH_PATH:-$PROJECT_ROOT/apps/swift/.build-preview}"
SWIFT_RELEASE_DIR="$SWIFT_SCRATCH_PATH/release"
mkdir -p "$SWIFT_RELEASE_DIR"

if [[ "$SWIFT_ONLY" != true ]]; then
    cp "$PROJECT_ROOT/target/release/libcapacitor_core.dylib" "$SWIFT_RELEASE_DIR/"
fi

if [[ -f "$PROJECT_ROOT/target/release/hud-hook" ]]; then
    cp "$PROJECT_ROOT/target/release/hud-hook" "$SWIFT_RELEASE_DIR/"
elif [[ -f "$HOME/.local/bin/hud-hook" ]]; then
    cp "$HOME/.local/bin/hud-hook" "$SWIFT_RELEASE_DIR/"
fi

compile_metal_if_needed
swift build --configuration release --scratch-path "$SWIFT_SCRATCH_PATH"

DEBUG_BIN="$SWIFT_RELEASE_DIR/Capacitor"
SPARKLE_FRAMEWORK="$SWIFT_RELEASE_DIR/Sparkle.framework"
RESOURCE_BUNDLE="$SWIFT_RELEASE_DIR/Capacitor_Capacitor.bundle"

if [[ ! -x "$DEBUG_BIN" ]]; then
    echo "error: Swift build did not produce $DEBUG_BIN" >&2
    exit 1
fi

if [[ ! -d "$SPARKLE_FRAMEWORK" ]]; then
    echo "error: Sparkle.framework missing at $SPARKLE_FRAMEWORK" >&2
    exit 1
fi

if [[ -f "$SWIFT_RELEASE_DIR/libcapacitor_core.dylib" ]]; then
    install_name_tool -id "@rpath/libcapacitor_core.dylib" "$SWIFT_RELEASE_DIR/libcapacitor_core.dylib"
fi

if ! otool -l "$DEBUG_BIN" | grep -q "@loader_path"; then
    install_name_tool -add_rpath "@loader_path" "$DEBUG_BIN"
fi

TEMPLATE_APP="$PROJECT_ROOT/apps/swift/Capacitor.app"
rm -rf "$APP_PATH"
if [[ -d "$TEMPLATE_APP" ]]; then
    rsync -a "$TEMPLATE_APP/" "$APP_PATH/"
else
    create_bundle_skeleton "$APP_PATH"
fi

mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Frameworks" "$APP_PATH/Contents/Resources"
write_plist_string "$APP_PATH/Contents/Info.plist" "CFBundleIdentifier" "$BUNDLE_ID"
write_plist_string "$APP_PATH/Contents/Info.plist" "CFBundleName" "$DISPLAY_NAME"
write_plist_string "$APP_PATH/Contents/Info.plist" "CFBundleDisplayName" "$DISPLAY_NAME"
write_plist_string "$APP_PATH/Contents/Info.plist" "CapacitorChannel" "preview"
write_plist_string "$APP_PATH/Contents/Info.plist" "CapacitorProfile" "preview"
write_plist_string "$APP_PATH/Contents/Info.plist" "CapacitorSkipSetupValidation" "1"
write_plist_bool "$APP_PATH/Contents/Info.plist" "SUEnableAutomaticChecks" "false"

cp "$DEBUG_BIN" "$APP_PATH/Contents/MacOS/Capacitor"

if [[ -f "$SWIFT_RELEASE_DIR/hud-hook" ]]; then
    cp "$SWIFT_RELEASE_DIR/hud-hook" "$APP_PATH/Contents/Resources/"
fi

if [[ -d "$RESOURCE_BUNDLE" ]]; then
    rm -rf "$APP_PATH/Contents/Resources/Capacitor_Capacitor.bundle"
    cp -R "$RESOURCE_BUNDLE" "$APP_PATH/Contents/Resources/"
fi

rm -rf "$APP_PATH/Contents/Frameworks/Sparkle.framework"
cp -R "$SPARKLE_FRAMEWORK" "$APP_PATH/Contents/Frameworks/"

if [[ -f "$SWIFT_RELEASE_DIR/libcapacitor_core.dylib" ]]; then
    cp "$SWIFT_RELEASE_DIR/libcapacitor_core.dylib" "$APP_PATH/Contents/Frameworks/"
    install_name_tool -id "@rpath/libcapacitor_core.dylib" "$APP_PATH/Contents/Frameworks/libcapacitor_core.dylib"
fi

APP_BIN="$APP_PATH/Contents/MacOS/Capacitor"
if ! otool -l "$APP_BIN" | grep -q "@executable_path/../Frameworks"; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_BIN"
fi
if ! otool -l "$APP_BIN" | grep -q "@loader_path/../Frameworks"; then
    install_name_tool -add_rpath "@loader_path/../Frameworks" "$APP_BIN"
fi

SIGNING_IDENTITY="$(find_signing_identity)"
if [[ -f "$APP_PATH/Contents/Resources/hud-hook" ]]; then
    codesign --force --sign "$SIGNING_IDENTITY" --identifier com.capacitor.hud-hook "$APP_PATH/Contents/Resources/hud-hook"
fi

codesign --force --deep --sign "$SIGNING_IDENTITY" --identifier "$BUNDLE_ID" "$APP_PATH"

echo "preview_app_path=$APP_PATH"
echo "preview_bundle_id=$BUNDLE_ID"
echo "preview_display_name=$DISPLAY_NAME"
