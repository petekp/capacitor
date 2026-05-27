#!/bin/bash
set -e
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=/dev/null
source "$SCRIPT_DIR/load-runtime-env.sh"

runtime_service_dir() {
    printf '%s\n' "${CAPACITOR_RUNTIME_DIR:-$HOME/.capacitor/runtime}"
}

runtime_service_pid_file_path() {
    local port="${1:-7474}"
    printf '%s/runtime-service-%s.pid\n' "$(runtime_service_dir)" "$port"
}

runtime_service_token_file_path() {
    local port="${1:-7474}"
    printf '%s/runtime-service-%s.token\n' "$(runtime_service_dir)" "$port"
}

runtime_service_connection_file_path() {
    printf '%s/runtime-service.json\n' "$(runtime_service_dir)"
}

legacy_daemon_socket_path() {
    printf '%s\n' "${CAPACITOR_LEGACY_DAEMON_SOCKET:-$HOME/.capacitor/daemon.sock}"
}

legacy_daemon_dir_path() {
    printf '%s\n' "${CAPACITOR_LEGACY_DAEMON_DIR:-$HOME/.capacitor/daemon}"
}

legacy_daemon_launch_agent_path() {
    printf '%s\n' "$HOME/Library/LaunchAgents/com.capacitor.daemon.plist"
}

read_pid_from_file() {
    local path="$1"
    local pid=""

    if [[ ! -f "$path" ]]; then
        return 1
    fi

    pid="$(tr -d '[:space:]' < "$path" 2>/dev/null || true)"
    if [[ "$pid" =~ ^[0-9]+$ ]]; then
        printf '%s\n' "$pid"
        return 0
    fi

    return 1
}

runtime_service_listener_pids() {
    local port="${1:-7474}"
    lsof -nP -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null || true
}

runtime_service_port_in_use() {
    local port="${1:-7474}"
    lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1
}

runtime_service_pid_listens_on_port() {
    local pid="$1"
    local port="${2:-7474}"
    lsof -nP -a -p "$pid" -iTCP:"$port" -sTCP:LISTEN -t >/dev/null 2>&1
}

wait_for_pid_exit() {
    local pid="$1"
    local timeout_seconds="${2:-3}"
    local attempts=$((timeout_seconds * 10))
    local attempt=0

    while (( attempt < attempts )); do
        if ! kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
        sleep 0.1
        attempt=$((attempt + 1))
    done

    return 1
}

terminate_pid_with_escalation() {
    local pid="$1"
    local label="$2"

    if [[ ! "$pid" =~ ^[0-9]+$ ]] || [[ "$pid" -le 1 ]] || [[ "$pid" -eq "$$" ]]; then
        return 0
    fi

    if ! kill -0 "$pid" 2>/dev/null; then
        return 0
    fi

    echo "Stopping $label process $pid..."
    kill -TERM "$pid" 2>/dev/null || true
    if wait_for_pid_exit "$pid" 3; then
        return 0
    fi

    echo "Force killing $label process $pid..."
    kill -KILL "$pid" 2>/dev/null || true
    wait_for_pid_exit "$pid" 2 || true
}

cleanup_runtime_service_artifacts() {
    local port="${1:-7474}"

    rm -f "$(runtime_service_pid_file_path "$port")"
    rm -f "$(runtime_service_token_file_path "$port")"
    rm -f "$(runtime_service_connection_file_path)"
}

reap_runtime_service() {
    local port="${1:-7474}"
    local pid_file
    local pid_from_file=""
    local listener_pid=""
    local existing_pid=""
    local candidate_pids=""
    local port_wait_attempt=0

    pid_file="$(runtime_service_pid_file_path "$port")"
    pid_from_file="$(read_pid_from_file "$pid_file" || true)"
    if [[ -n "$pid_from_file" ]] && kill -0 "$pid_from_file" 2>/dev/null && runtime_service_pid_listens_on_port "$pid_from_file" "$port"; then
        candidate_pids="$pid_from_file"
    fi

    while IFS= read -r listener_pid; do
        [[ -z "$listener_pid" ]] && continue

        local seen=false
        for existing_pid in $candidate_pids; do
            if [[ "$existing_pid" == "$listener_pid" ]]; then
                seen=true
                break
            fi
        done

        if [[ "$seen" == false ]]; then
            candidate_pids="${candidate_pids:+$candidate_pids }$listener_pid"
        fi
    done < <(runtime_service_listener_pids "$port")

    if [[ -n "$candidate_pids" ]] || runtime_service_port_in_use "$port"; then
        echo "Reaping stale runtime service on port $port..."
    fi

    for existing_pid in $candidate_pids; do
        terminate_pid_with_escalation "$existing_pid" "runtime service"
    done

    cleanup_runtime_service_artifacts "$port"

    while (( port_wait_attempt < 50 )); do
        if ! runtime_service_port_in_use "$port"; then
            return 0
        fi
        sleep 0.1
        port_wait_attempt=$((port_wait_attempt + 1))
    done

    echo "Error: Port $port is still occupied after runtime service cleanup." >&2
    return 1
}

wait_for_pattern_exit() {
    local pattern="$1"
    local timeout_seconds="${2:-3}"
    local attempts=$((timeout_seconds * 10))
    local attempt=0

    while (( attempt < attempts )); do
        if ! pgrep -f "$pattern" >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.1
        attempt=$((attempt + 1))
    done

    return 1
}

installed_release_capacitor_pattern() {
    printf '%s\n' '/Applications/Capacitor.app/Contents/MacOS/Capacitor$'
}

installed_release_capacitor_pids() {
    pgrep -f "$(installed_release_capacitor_pattern)" 2>/dev/null || true
}

non_debug_capacitor_processes() {
    local expected_debug_binary="$1"
    local process_line

    pgrep -fl '/Capacitor$' 2>/dev/null | while IFS= read -r process_line; do
        [[ -z "$process_line" ]] && continue
        case "$process_line" in
            *"$expected_debug_binary" | \
            *'/CapacitorPreview.app/Contents/MacOS/Capacitor')
                ;;
            *)
                printf '%s\n' "$process_line"
                ;;
        esac
    done || true
}

terminate_installed_release_capacitor() {
    local pid

    # New dev behavior: the repo Debug app and installed release app have the
    # same human-facing product name. Keep the release build out of dev runs so
    # manual checks and AX automation cannot silently attach to the wrong app.
    while IFS= read -r pid; do
        [[ -z "$pid" ]] && continue
        terminate_pid_with_escalation "$pid" "installed release Capacitor app"
    done < <(installed_release_capacitor_pids)
}

terminate_non_debug_capacitor_processes() {
    local expected_debug_binary="$1"
    local process_line
    local pid

    # New dev behavior: after launching the repo Debug app, most other Capacitor
    # GUI processes are unsafe for manual testing. Capacitor Preview is allowed
    # because Work Batch preview verification intentionally opens it beside
    # Debug.
    while IFS= read -r process_line; do
        [[ -z "$process_line" ]] && continue
        pid="${process_line%% *}"
        [[ -z "$pid" ]] && continue
        terminate_pid_with_escalation "$pid" "non-Debug Capacitor app"
    done < <(non_debug_capacitor_processes "$expected_debug_binary")
}

assert_no_installed_release_capacitor() {
    local pids

    pids="$(installed_release_capacitor_pids)"
    if [[ -z "$pids" ]]; then
        return 0
    fi

    echo "Error: Installed release Capacitor is still running during a Debug restart." >&2
    echo "Release PIDs: $pids" >&2
    echo "Close /Applications/Capacitor.app, then rerun ./scripts/dev/restart-alpha-stable.sh." >&2
    return 1
}

assert_no_non_debug_capacitor_processes() {
    local expected_debug_binary="$1"
    local process_lines

    process_lines="$(non_debug_capacitor_processes "$expected_debug_binary")"
    if [[ -z "$process_lines" ]]; then
        return 0
    fi

    echo "Error: A non-Debug Capacitor build is still running during a Debug restart." >&2
    echo "Non-Debug processes:" >&2
    printf '%s\n' "$process_lines" >&2
    echo "Expected debug binary: $expected_debug_binary" >&2
    echo "Manual testing would be unsafe; rerun ./scripts/dev/restart-alpha-stable.sh." >&2
    return 1
}

frontmost_app_snapshot() {
    osascript \
        -e 'tell application "System Events"' \
        -e 'set frontProc to first application process whose frontmost is true' \
        -e 'set procName to name of frontProc' \
        -e 'set procID to unix id of frontProc' \
        -e 'try' \
        -e 'set procPath to POSIX path of application file of frontProc' \
        -e 'on error' \
        -e 'set procPath to ""' \
        -e 'end try' \
        -e 'return procName & linefeed & procID & linefeed & procPath' \
        -e 'end tell' 2>/dev/null || true
}

assert_debug_app_frontmost() {
    local expected_path="$1"
    local expected_pid="$2"
    local snapshot
    local front_name
    local front_pid
    local front_path

    if [[ "${CAPACITOR_ALLOW_BACKGROUND_DEBUG_APP:-0}" == "1" ]]; then
        return 0
    fi

    snapshot="$(frontmost_app_snapshot)"
    front_name="$(printf '%s\n' "$snapshot" | sed -n '1p')"
    front_pid="$(printf '%s\n' "$snapshot" | sed -n '2p')"
    front_path="$(printf '%s\n' "$snapshot" | sed -n '3p')"

    if [[ "$front_path" == "$expected_path" || "$front_pid" == "$expected_pid" ]]; then
        return 0
    fi

    echo "Error: Debug app launched, but it is not the proven frontmost app." >&2
    echo "Expected path: $expected_path" >&2
    echo "Expected pid: $expected_pid" >&2
    echo "Front app: ${front_name:-<unknown>}" >&2
    echo "Front pid: ${front_pid:-<unknown>}" >&2
    echo "Front path: ${front_path:-<empty>}" >&2
    echo "Manual testing would be unsafe; rerun ./scripts/dev/restart-alpha-stable.sh." >&2
    return 1
}

kill_stale_capacitor_daemon() {
    local legacy_pattern='[c]apacitor-daemon'
    local launch_agent_path
    local launch_domain

    launch_agent_path="$(legacy_daemon_launch_agent_path)"
    launch_domain="gui/$(id -u)"

    if [[ -f "$launch_agent_path" ]]; then
        echo "Unloading legacy capacitor-daemon LaunchAgent..."
        launchctl bootout "$launch_domain" "$launch_agent_path" >/dev/null 2>&1 ||
            launchctl remove com.capacitor.daemon >/dev/null 2>&1 ||
            true
        rm -f "$launch_agent_path"
    fi

    if pgrep -f "$legacy_pattern" >/dev/null 2>&1; then
        echo "Cleaning up legacy capacitor-daemon..."
        pkill -TERM -f "$legacy_pattern" 2>/dev/null || true
        if ! wait_for_pattern_exit "$legacy_pattern" 3; then
            pkill -KILL -f "$legacy_pattern" 2>/dev/null || true
            wait_for_pattern_exit "$legacy_pattern" 2 || true
        fi
    fi

    rm -f "$(legacy_daemon_socket_path)"
    rm -rf "$(legacy_daemon_dir_path)"
}

write_plist_string() {
    local plist_path="$1"
    local key="$2"
    local value="$3"

    if ! /usr/libexec/PlistBuddy -c "Set :$key $value" "$plist_path" 2>/dev/null; then
        /usr/libexec/PlistBuddy -c "Add :$key string $value" "$plist_path" 2>/dev/null || true
    fi
}

write_debug_bundle_metadata() {
    local plist_path="$1"

    write_plist_string "$plist_path" "CFBundleIdentifier" "com.capacitor.app.debug"
    # New dev behavior: give the repo-built app a distinct LaunchServices name
    # so manual testing and automation do not accidentally target the installed
    # release bundle at /Applications/Capacitor.app.
    write_plist_string "$plist_path" "CFBundleName" "Capacitor Debug"
    write_plist_string "$plist_path" "CFBundleDisplayName" "Capacitor Debug"
    write_plist_string "$plist_path" "CapacitorChannel" "$CHANNEL"
    write_plist_string "$plist_path" "CapacitorProfile" "$PROFILE"
    write_plist_string "$plist_path" "CapacitorSkipSetupValidation" "$SKIP_SETUP_VALIDATION"

    if [[ -n "${CAPACITOR_FEATURES_ENABLED:-}" ]]; then
        write_plist_string "$plist_path" "CapacitorFeaturesEnabled" "$CAPACITOR_FEATURES_ENABLED"
    fi
    if [[ -n "${CAPACITOR_FEATURES_DISABLED:-}" ]]; then
        write_plist_string "$plist_path" "CapacitorFeaturesDisabled" "$CAPACITOR_FEATURES_DISABLED"
    fi
}

build_sanitized_debug_app_env() {
    local resolved_user="${USER:-}"
    if [[ -z "$resolved_user" ]]; then
        resolved_user="$(id -un 2>/dev/null || true)"
    fi
    resolved_user="${resolved_user:-user}"

    local resolved_logname="${LOGNAME:-$resolved_user}"
    local resolved_home="${HOME:-$PROJECT_ROOT}"
    local resolved_shell="${SHELL:-/bin/zsh}"
    local resolved_tmpdir="${TMPDIR:-/tmp}"
    local resolved_lang="${LANG:-en_US.UTF-8}"

    SANITIZED_APP_ENV=(
        env -i
        "HOME=$resolved_home"
        "USER=$resolved_user"
        "LOGNAME=$resolved_logname"
        "SHELL=$resolved_shell"
        "TMPDIR=$resolved_tmpdir"
        "LANG=$resolved_lang"
        "PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    )

    if [[ -n "${SSH_AUTH_SOCK:-}" ]]; then
        SANITIZED_APP_ENV+=("SSH_AUTH_SOCK=$SSH_AUTH_SOCK")
    fi
    if [[ -n "${__CF_USER_TEXT_ENCODING:-}" ]]; then
        SANITIZED_APP_ENV+=("__CF_USER_TEXT_ENCODING=$__CF_USER_TEXT_ENCODING")
    fi
}

if [[ "${CAPACITOR_RESTART_APP_SOURCE_ONLY:-0}" == "1" ]]; then
    return 0 2>/dev/null || exit 0
fi

# Prefer a real Apple signing identity so helper binaries are attributed to the
# app bundle in Login Items.
SIGNING_IDENTITY="${CAPACITOR_SIGNING_IDENTITY:-}"
if [ -z "$SIGNING_IDENTITY" ]; then
    CERT_LINE=$(security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application" | head -1 || true)
    if [ -n "$CERT_LINE" ]; then
        SIGNING_IDENTITY=$(echo "$CERT_LINE" | awk '{print $2}')
    fi
fi
if [ -z "$SIGNING_IDENTITY" ]; then
    CERT_LINE=$(security find-identity -v -p codesigning 2>/dev/null | grep "Apple Development" | head -1 || true)
    if [ -n "$CERT_LINE" ]; then
        SIGNING_IDENTITY=$(echo "$CERT_LINE" | awk '{print $2}')
    fi
fi
if [ -z "$SIGNING_IDENTITY" ]; then
    SIGNING_IDENTITY="-"
    echo "Warning: No Apple signing identity found. Falling back to ad-hoc signing." >&2
fi

# Parse flags
FORCE_REBUILD=false
SWIFT_ONLY=false
RUNTIME_STATE_FILE="${CAPACITOR_RUNTIME_STATE_FILE:-$HOME/.capacitor/runtime-context.env}"
CHANNEL="${CAPACITOR_CHANNEL:-}"
PROFILE="${CAPACITOR_PROFILE:-}"
SKIP_SETUP_VALIDATION="${CAPACITOR_SKIP_SETUP_VALIDATION:-0}"

if [[ (-z "$CHANNEL" || -z "$PROFILE") && -f "$RUNTIME_STATE_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$RUNTIME_STATE_FILE"
    if [[ -z "$CHANNEL" && -n "${CAPACITOR_RUNTIME_CHANNEL:-}" ]]; then
        CHANNEL="$CAPACITOR_RUNTIME_CHANNEL"
    fi
    if [[ -z "$PROFILE" && -n "${CAPACITOR_RUNTIME_PROFILE:-}" ]]; then
        PROFILE="$CAPACITOR_RUNTIME_PROFILE"
    fi
fi

CHANNEL="${CHANNEL:-alpha}"
PROFILE="${PROFILE:-stable}"
while [[ $# -gt 0 ]]; do
    case $1 in
        --force|-f)
            FORCE_REBUILD=true
            shift
            ;;
        --swift-only|-s)
            SWIFT_ONLY=true
            shift
            ;;
        --alpha)
            CHANNEL="alpha"
            shift
            ;;
        --frontier)
            PROFILE="frontier"
            shift
            ;;
        --channel)
            CHANNEL="${2:-$CHANNEL}"
            shift 2
            ;;
        --channel=*)
            CHANNEL="${1#*=}"
            shift
            ;;
        --profile)
            PROFILE="${2:-$PROFILE}"
            shift 2
            ;;
        --profile=*)
            PROFILE="${1#*=}"
            shift
            ;;
        --help|-h)
            echo "Usage: restart-app.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  -f, --force         Force full rebuild (touch source to invalidate cache)"
            echo "  -s, --swift-only    Skip Rust build, only rebuild Swift"
            echo "      --alpha         Alias for --channel alpha"
            echo "      --channel NAME  Set runtime channel (dev|alpha|beta|prod)"
            echo "      --frontier      Alias for --profile frontier"
            echo "      --profile <stable|frontier>  Set runtime feature profile"
            echo ""
            echo "Defaults come from:"
            echo "  1) CAPACITOR_CHANNEL / CAPACITOR_PROFILE env vars"
            echo "  2) $RUNTIME_STATE_FILE"
            echo "  3) alpha + stable"
            echo "  -h, --help          Show this help message"
            exit 0
            ;;
        *)
            shift
            ;;
    esac
done

if [[ "$PROFILE" != "stable" && "$PROFILE" != "frontier" ]]; then
    echo "Error: Invalid profile '$PROFILE'. Use stable or frontier." >&2
    exit 1
fi

ENFORCE_ALPHA_ONLY="${CAPACITOR_ENFORCE_ALPHA_ONLY:-1}"
if [[ "$ENFORCE_ALPHA_ONLY" == "1" && "$CHANNEL" != "alpha" && "${CAPACITOR_ALLOW_NON_ALPHA:-}" != "1" ]]; then
    echo "Error: Refusing to launch non-alpha channel '$CHANNEL' in dev workflow." >&2
    echo "Expected channel: alpha" >&2
    echo "Canonical restart: ./scripts/dev/restart-current.sh" >&2
    echo "Intentional override: CAPACITOR_ALLOW_NON_ALPHA=1 ./scripts/dev/restart-app.sh --channel $CHANNEL --profile $PROFILE" >&2
    exit 1
fi

if [[ "${CAPACITOR_RUNTIME_STATE_PERSIST:-1}" == "1" ]]; then
    mkdir -p "$(dirname "$RUNTIME_STATE_FILE")"
    cat > "$RUNTIME_STATE_FILE" <<EOF
# Auto-generated by scripts/dev/restart-app.sh
CAPACITOR_RUNTIME_CHANNEL="$CHANNEL"
CAPACITOR_RUNTIME_PROFILE="$PROFILE"
EOF
fi

# Architecture validation - Apple Silicon only
if [ "$(uname -m)" != "arm64" ]; then
    echo "Error: This project requires Apple Silicon (arm64)." >&2
    echo "Detected architecture: $(uname -m)" >&2
    if [ "$(sysctl -n sysctl.proc_translated 2>/dev/null)" = "1" ]; then
        echo "You appear to be running under Rosetta. Run natively instead." >&2
    fi
    exit 1
fi

# Verify hook is in sync (warn only, don't block)
"$PROJECT_ROOT/scripts/sync-hooks.sh" 2>/dev/null || true

# Kill any existing Capacitor instances (graceful first, then force)
# Prefer killing the release app first to avoid confusing launches.
terminate_installed_release_capacitor
sleep 0.2
# Use killall for reliability - matches process name directly
killall Capacitor 2>/dev/null || true
sleep 0.3
# Match the binary name at end of path to avoid killing unrelated processes
pkill -f '/Capacitor$' 2>/dev/null || true
sleep 0.3
# Force kill any stragglers
killall -9 Capacitor 2>/dev/null || true
sleep 0.3

# Verify no Capacitor processes remain
if pgrep -x Capacitor > /dev/null; then
    echo "Warning: Capacitor process still running after kill attempt" >&2
    pgrep -x Capacitor | xargs kill -9 2>/dev/null || true
    sleep 0.5
fi

# Reap stale runtime boundaries only after the app is fully down. Otherwise the
# app can observe hud-hook disappearing during shutdown, relaunch it, and leave
# the replacement runtime service pinned to port 7474.
reap_runtime_service 7474
kill_stale_capacitor_daemon

cd "$PROJECT_ROOT"

# Force rebuild by touching App.swift to invalidate Swift's incremental build cache
if [ "$FORCE_REBUILD" = true ]; then
    echo "Force rebuild: invalidating Swift build cache..."
    touch apps/swift/Sources/Capacitor/App.swift
fi

# Rust build (skip if --swift-only)
if [ "$SWIFT_ONLY" = true ]; then
    echo "Skipping Rust build (--swift-only)"
else
    cargo build -p capacitor-core -p hud-hook --release || { echo "Rust build failed"; exit 1; }
fi

# Rust post-build steps (skip if --swift-only)
if [ "$SWIFT_ONLY" != true ]; then
    # Fix the dylib's install name so Swift can find it at runtime.
    # Without this, the library embeds an absolute path that breaks when moved.
    "$PROJECT_ROOT/scripts/dev/fix-dylib.sh"

    # Always regenerate UniFFI bindings to prevent checksum mismatch crashes
    BINDINGS_TMP_DIR="$(mktemp -d)"
    trap 'rm -rf "$BINDINGS_TMP_DIR"' EXIT
    cargo run --release -p capacitor-core --bin uniffi-bindgen generate \
        --library target/release/libcapacitor_core.dylib \
        --language swift \
        --out-dir "$BINDINGS_TMP_DIR"

    cp "$BINDINGS_TMP_DIR/capacitor_core.swift" apps/swift/Sources/Capacitor/Bridge/
    cp "$BINDINGS_TMP_DIR/capacitor_coreFFI.h" apps/swift/Sources/CapacitorCoreFFI/
fi

cd "$PROJECT_ROOT/apps/swift"

# Get the actual build directory (portable across toolchain/layout changes)
SWIFT_DEBUG_DIR=$(swift build --show-bin-path)
mkdir -p "$SWIFT_DEBUG_DIR"

# Copy dylib (skip if --swift-only, assume it's already there)
if [ "$SWIFT_ONLY" != true ]; then
    cp "$PROJECT_ROOT/target/release/libcapacitor_core.dylib" "$SWIFT_DEBUG_DIR/"
fi

# Copy hud-hook binary so Bundle.main can find it (matches release bundle structure).
# Prefer the repo build to avoid stale ~/.local/bin binaries.
if [ -f "$PROJECT_ROOT/target/release/hud-hook" ]; then
    cp "$PROJECT_ROOT/target/release/hud-hook" "$SWIFT_DEBUG_DIR/"
elif [ -f "$HOME/.local/bin/hud-hook" ]; then
    cp "$HOME/.local/bin/hud-hook" "$SWIFT_DEBUG_DIR/"
fi


# Compile Metal shaders into default.metallib for SwiftUI ShaderLibrary.bundle().
# Only colorEffect shaders work from custom metallibs in SPM builds.
# layerEffect/distortionEffect show yellow "not allowed" regardless of loading path
# (ShaderLibrary.url or .bundle) — a SwiftUI limitation with non-Xcode metallibs.
METAL_DIR="Sources/Capacitor/Shaders"
METAL_OUTDIR="Sources/Capacitor/Resources/Shaders"
METAL_OUT="$METAL_OUTDIR/default.metallib"
mkdir -p "$METAL_OUTDIR"
METAL_NEEDS_REBUILD=false
for src in "$METAL_DIR"/*.metal; do
    if [ "$src" -nt "$METAL_OUT" ] || [ ! -f "$METAL_OUT" ]; then
        METAL_NEEDS_REBUILD=true
        break
    fi
done
if $METAL_NEEDS_REBUILD; then
    AIR_FILES=""
    for src in "$METAL_DIR"/*.metal; do
        base=$(basename "$src" .metal)
        xcrun metal -fno-fast-math -c "$src" -o "/tmp/$base.air"
        AIR_FILES="$AIR_FILES /tmp/$base.air"
    done
    xcrun metallib $AIR_FILES -o "$METAL_OUT"
    rm -f $AIR_FILES
fi

swift build || { echo "Swift build failed"; exit 1; }

# Debug runtime sanity checks to avoid dyld "Library not loaded" crashes.
DEBUG_BIN="$SWIFT_DEBUG_DIR/Capacitor"
SPARKLE_FRAMEWORK="$SWIFT_DEBUG_DIR/Sparkle.framework"

if [ ! -x "$DEBUG_BIN" ]; then
    echo "Error: Debug binary not found at $DEBUG_BIN" >&2
    exit 1
fi

if [ ! -d "$SPARKLE_FRAMEWORK" ]; then
    echo "Error: Sparkle.framework missing at $SPARKLE_FRAMEWORK" >&2
    echo "Try: rm -rf apps/swift/.build && rerun $SCRIPT_DIR/restart-app.sh" >&2
    exit 1
fi

# Ensure the Rust dylib uses @rpath so it resolves via @loader_path at runtime.
if [ -f "$SWIFT_DEBUG_DIR/libcapacitor_core.dylib" ]; then
    # fix-dylib.sh only handles target/release/; this copy needs its own fixup
    install_name_tool -id "@rpath/libcapacitor_core.dylib" "$SWIFT_DEBUG_DIR/libcapacitor_core.dylib"
fi

# Ensure the debug binary has @loader_path rpath (needed for Sparkle.framework in build dir).
if ! otool -l "$DEBUG_BIN" | grep -q "@loader_path"; then
    install_name_tool -add_rpath "@loader_path" "$DEBUG_BIN"
fi

create_debug_bundle_skeleton() {
    local app_path="$1"
    local bundle_id="$2"

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
    <string>${bundle_id}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Capacitor</string>
    <key>CFBundleDisplayName</key>
    <string>Capacitor</string>
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

# Assemble a debug app bundle so LaunchServices opens a real GUI app (no Warp/Terminal windows).
TEMPLATE_APP="$PROJECT_ROOT/apps/swift/Capacitor.app"
FALLBACK_TEMPLATE="/Applications/Capacitor.app"
DEBUG_APP="$PROJECT_ROOT/apps/swift/CapacitorDebug.app"

rm -rf "$DEBUG_APP"
if [ ! -d "$TEMPLATE_APP" ]; then
    if [ -d "$FALLBACK_TEMPLATE" ]; then
        echo "Warning: Template app bundle not found at $TEMPLATE_APP; using $FALLBACK_TEMPLATE" >&2
        TEMPLATE_APP="$FALLBACK_TEMPLATE"
    else
        echo "Warning: Template app bundle not found at $TEMPLATE_APP or $FALLBACK_TEMPLATE; creating a minimal debug bundle." >&2
        create_debug_bundle_skeleton "$DEBUG_APP" "com.capacitor.app.debug"
    fi
fi

if [ -d "${TEMPLATE_APP:-}" ]; then
    rsync -a "$TEMPLATE_APP/" "$DEBUG_APP/"
fi

# Ensure the debug bundle is distinct from the release app.
write_debug_bundle_metadata "$DEBUG_APP/Contents/Info.plist"

# Replace the app executable with the debug binary.
cp "$DEBUG_BIN" "$DEBUG_APP/Contents/MacOS/Capacitor"

# Ensure bundled helpers are present.
if [ -f "$SWIFT_DEBUG_DIR/hud-hook" ]; then
    cp "$SWIFT_DEBUG_DIR/hud-hook" "$DEBUG_APP/Contents/Resources/"
fi

# Replace SPM resource bundle with the freshly-built one.
RESOURCE_BUNDLE="$SWIFT_DEBUG_DIR/Capacitor_Capacitor.bundle"
if [ -d "$RESOURCE_BUNDLE" ]; then
    cp -R "$RESOURCE_BUNDLE" "$DEBUG_APP/Contents/Resources/"
fi

# Replace frameworks with the debug build outputs.
rm -rf "$DEBUG_APP/Contents/Frameworks/Sparkle.framework"
cp -R "$SPARKLE_FRAMEWORK" "$DEBUG_APP/Contents/Frameworks/"
if [ -f "$SWIFT_DEBUG_DIR/libcapacitor_core.dylib" ]; then
    cp "$SWIFT_DEBUG_DIR/libcapacitor_core.dylib" "$DEBUG_APP/Contents/Frameworks/"
    # fix-dylib.sh only handles target/release/; this copy needs its own fixup
    install_name_tool -id "@rpath/libcapacitor_core.dylib" "$DEBUG_APP/Contents/Frameworks/libcapacitor_core.dylib"
fi

# Ensure the debug app binary can resolve bundled frameworks.
DEBUG_APP_BIN="$DEBUG_APP/Contents/MacOS/Capacitor"
if ! otool -l "$DEBUG_APP_BIN" | grep -q "@executable_path/../Frameworks"; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$DEBUG_APP_BIN"
fi
if ! otool -l "$DEBUG_APP_BIN" | grep -q "@loader_path/../Frameworks"; then
    install_name_tool -add_rpath "@loader_path/../Frameworks" "$DEBUG_APP_BIN"
fi

# Give helper binaries stable ad-hoc identifiers instead of hash-based defaults.
if [ -f "$DEBUG_APP/Contents/Resources/hud-hook" ]; then
    codesign --force --sign "$SIGNING_IDENTITY" --identifier com.capacitor.hud-hook "$DEBUG_APP/Contents/Resources/hud-hook"
fi

# Ad-hoc sign the debug bundle so LaunchServices will open it reliably.
if ! codesign --force --deep --sign "$SIGNING_IDENTITY" --identifier com.capacitor.app.debug "$DEBUG_APP" >/dev/null 2>&1; then
    echo "Error: Failed to codesign debug app bundle at $DEBUG_APP" >&2
    exit 1
fi

# Launch the debug app bundle via LaunchServices.
# New debug-launch behavior: this script is often run from Codex or another
# agent host. Start Capacitor Debug with a narrow app environment so host-only
# flags, paths, and secrets do not later leak into user-facing terminal sessions.
build_sanitized_debug_app_env
"${SANITIZED_APP_ENV[@]}" open -n "$DEBUG_APP"

# Bring the debug build to the foreground (best-effort).
# Avoid activating the installed release app by targeting the debug binary PID.
APP_PID=""
for _ in {1..30}; do
    APP_PID=$(pgrep -n -f "$DEBUG_APP/Contents/MacOS/Capacitor$" || true)
    if [ -n "$APP_PID" ]; then
        break
    fi
    sleep 0.2
done

if [ -z "$APP_PID" ]; then
    echo "LaunchServices did not report the debug app process; falling back to direct bundle executable launch." >&2
    "${SANITIZED_APP_ENV[@]}" nohup "$DEBUG_APP_BIN" >/tmp/capacitor-debug-app.launch.log 2>&1 &
    for _ in {1..60}; do
        APP_PID=$(pgrep -n -f "$DEBUG_APP/Contents/MacOS/Capacitor$" || true)
        if [ -n "$APP_PID" ]; then
            break
        fi
        sleep 0.2
    done
fi

if [ -n "$APP_PID" ]; then
    # LaunchServices can occasionally leave more than one debug app process
    # around during rapid rebuild/relaunch cycles. Keep the newest process so
    # manual testing never clicks an older copy of the same debug bundle.
    while IFS= read -r DEBUG_PID; do
        [[ -z "$DEBUG_PID" ]] && continue
        if [[ "$DEBUG_PID" != "$APP_PID" ]]; then
            terminate_pid_with_escalation "$DEBUG_PID" "duplicate debug app"
        fi
    done < <(pgrep -f "$DEBUG_APP/Contents/MacOS/Capacitor$" || true)

    for _ in {1..20}; do
        WIN_COUNT=$(osascript -e "tell application \"System Events\" to tell process whose unix id is $APP_PID to count windows" 2>/dev/null || echo 0)
        if [ "$WIN_COUNT" != "0" ]; then
            break
        fi
        sleep 0.2
    done
    osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $APP_PID) to true" >/dev/null 2>&1 || true
else
    echo "Error: debug app did not stay running. Check Console.app logs for Capacitor." >&2
    exit 1
fi

# LaunchServices, automation tools, or a previous manual click can reopen the
# installed release app while the Debug app is being rebuilt. Treat that as an
# invalid dev state so subsequent manual verification cannot target the wrong
# build by name.
terminate_installed_release_capacitor
assert_no_installed_release_capacitor
terminate_non_debug_capacitor_processes "$DEBUG_APP_BIN"
assert_no_non_debug_capacitor_processes "$DEBUG_APP_BIN"
assert_debug_app_frontmost "$DEBUG_APP" "$APP_PID"
