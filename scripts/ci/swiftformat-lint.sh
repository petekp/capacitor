#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

# Honor an explicit binary path so the caller can pin the exact SwiftFormat
# build. CI must set this: the macOS runner images ship their own SwiftFormat in
# /opt/homebrew/bin, which precedes /usr/local/bin in PATH, so a bare
# `swiftformat` here would lint with the image's version rather than the pinned
# one CI installed. Locally this falls back to PATH lookup.
SWIFTFORMAT_BIN="${SWIFTFORMAT_BIN:-swiftformat}"

"$SWIFTFORMAT_BIN" --lint apps/swift
