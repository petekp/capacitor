#!/usr/bin/env bash
set -euo pipefail

preferred="${1:-${CAPACITOR_CI_XCODE_PREFERRED:-/Applications/Xcode.app/Contents/Developer}}"
use_default_candidates="${CAPACITOR_CI_XCODE_USE_DEFAULT_CANDIDATES:-1}"

declare -a candidates=()

add_candidate() {
    local candidate="$1"
    [[ -n "$candidate" ]] || return 0

    local existing
    if ((${#candidates[@]} > 0)); then
        for existing in "${candidates[@]}"; do
            [[ "$existing" != "$candidate" ]] || return 0
        done
    fi

    candidates+=("$candidate")
}

add_candidate "$preferred"

if [[ -n "${CAPACITOR_CI_XCODE_CANDIDATES:-}" ]]; then
    IFS=":" read -r -a configured_candidates <<<"$CAPACITOR_CI_XCODE_CANDIDATES"
    for candidate in "${configured_candidates[@]}"; do
        add_candidate "$candidate"
    done
fi

if [[ "$use_default_candidates" != "0" ]]; then
    add_candidate "/Applications/Xcode.app/Contents/Developer"
    for candidate in /Applications/Xcode*.app/Contents/Developer; do
        [[ -d "$candidate" ]] || continue
        add_candidate "$candidate"
    done
fi

selected=""
for candidate in "${candidates[@]}"; do
    [[ -d "$candidate" ]] || continue
    if DEVELOPER_DIR="$candidate" xcrun -find clang >/dev/null 2>&1; then
        selected="$candidate"
        break
    fi
done

if [[ -z "$selected" ]]; then
    echo "ERROR: no usable Xcode developer directory found" >&2
    printf 'Checked candidates:\n' >&2
    printf '  %s\n' "${candidates[@]}" >&2
    exit 1
fi

if [[ "${CAPACITOR_CI_XCODE_DRY_RUN:-0}" == "1" ]]; then
    echo "Would select Xcode: $selected"
    exit 0
fi

echo "Selecting Xcode: $selected"
sudo xcode-select -s "$selected"
xcodebuild -version
xcrun -find clang
swift --version
