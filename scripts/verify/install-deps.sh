#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
VENV_DIR="${VENV_DIR:-$REPO_ROOT/.verifier/.venv}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
BOOTSTRAP_MANIFEST="${BOOTSTRAP_MANIFEST:-$SCRIPT_DIR/bootstrap-manifest.json}"
DEFAULTS="$("$PYTHON_BIN" - "$BOOTSTRAP_MANIFEST" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
payload = json.loads(path.read_text())
apalache = payload.get("apalache", {})
print(payload.get("python_min_version", "3.10"))
print(payload.get("requirements_sha256", ""))
print(apalache.get("version", "0.52.2"))
print(apalache.get("repo", "apalache-mc/apalache"))
print(apalache.get("archive_name", "apalache.tgz"))
print(apalache.get("archive_sha256", ""))
PY
)"
PYTHON_MIN_VERSION="$(printf '%s\n' "$DEFAULTS" | sed -n '1p')"
REQUIREMENTS_SHA256="$(printf '%s\n' "$DEFAULTS" | sed -n '2p')"
DEFAULT_APALACHE_VERSION="$(printf '%s\n' "$DEFAULTS" | sed -n '3p')"
DEFAULT_APALACHE_REPO="$(printf '%s\n' "$DEFAULTS" | sed -n '4p')"
DEFAULT_APALACHE_ARCHIVE="$(printf '%s\n' "$DEFAULTS" | sed -n '5p')"
DEFAULT_APALACHE_SHA256="$(printf '%s\n' "$DEFAULTS" | sed -n '6p')"
APALACHE_VERSION="${APALACHE_VERSION:-$DEFAULT_APALACHE_VERSION}"
APALACHE_REPO="${APALACHE_REPO:-$DEFAULT_APALACHE_REPO}"
APALACHE_ARCHIVE="${APALACHE_ARCHIVE:-$DEFAULT_APALACHE_ARCHIVE}"
APALACHE_SHA256="${APALACHE_SHA256:-$DEFAULT_APALACHE_SHA256}"
APALACHE_HOME="${HOME}/.local/bin"
APALACHE_INSTALL_ROOT="${HOME}/.local/share"
APALACHE_BIN="${APALACHE_HOME}/apalache-mc"
APALACHE_DIR="${APALACHE_INSTALL_ROOT}/apalache-${APALACHE_VERSION}"

mkdir -p "$REPO_ROOT/.verifier/facts" "$REPO_ROOT/.verifier/reports" "$REPO_ROOT/.verifier/specs" "$APALACHE_HOME"

"$PYTHON_BIN" - "$PYTHON_MIN_VERSION" <<'PY'
import sys
minimum = tuple(int(part) for part in sys.argv[1].split("."))
if sys.version_info < minimum:
    raise SystemExit(f"Python {sys.argv[1]}+ is required")
PY

ACTUAL_REQUIREMENTS_SHA256="$("$PYTHON_BIN" - "$SCRIPT_DIR/requirements.txt" <<'PY'
import hashlib
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
print(hashlib.sha256(path.read_bytes()).hexdigest())
PY
)"
if [[ -n "$REQUIREMENTS_SHA256" && "$ACTUAL_REQUIREMENTS_SHA256" != "$REQUIREMENTS_SHA256" ]]; then
  echo "Verifier requirements.txt hash drifted from bootstrap-manifest.json." >&2
  exit 1
fi

if [[ ! -d "$VENV_DIR" ]]; then
  "$PYTHON_BIN" -m venv "$VENV_DIR"
fi

"$VENV_DIR/bin/pip" install --upgrade pip >/dev/null
if [[ "${VERIFY_SKIP_PYTHON_DEPS:-0}" != "1" ]]; then
  "$VENV_DIR/bin/pip" install -r "$SCRIPT_DIR/requirements.txt" >/dev/null
fi

if command -v apalache-mc >/dev/null 2>&1; then
  echo "Dependencies installed."
  exit 0
fi

if [[ "${VERIFY_SKIP_APALACHE_INSTALL:-0}" == "1" ]]; then
  echo "Dependencies installed."
  exit 0
fi

if ! command -v java >/dev/null 2>&1; then
  echo "Java 17+ is required for Apalache. Install Java before continuing." >&2
  exit 1
fi

if ! java -version 2>&1 | grep -Eq 'version "1?7|version "2[0-9]'; then
  echo "Java 17+ is required for Apalache." >&2
  exit 1
fi

if [[ ! -x "$APALACHE_BIN" ]]; then
  TMP_DIR="$(mktemp -d)"
  trap 'rm -rf "$TMP_DIR"' EXIT
  ARCHIVE="$APALACHE_ARCHIVE"
  URL="https://github.com/${APALACHE_REPO}/releases/download/v${APALACHE_VERSION}/${APALACHE_ARCHIVE}"
  curl -fsSL "$URL" -o "$TMP_DIR/$ARCHIVE"
  ACTUAL_APALACHE_SHA256="$("$PYTHON_BIN" - "$TMP_DIR/$ARCHIVE" <<'PY'
import hashlib
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
print(hashlib.sha256(path.read_bytes()).hexdigest())
PY
)"
  if [[ -n "$APALACHE_SHA256" && "$ACTUAL_APALACHE_SHA256" != "$APALACHE_SHA256" ]]; then
    echo "Apalache archive checksum mismatch for $URL." >&2
    exit 1
  fi
  tar -xzf "$TMP_DIR/$ARCHIVE" -C "$TMP_DIR"
  FOUND_DIR="$(find "$TMP_DIR" -maxdepth 2 -type d -name "apalache-*full*" | head -n 1)"
  if [[ -z "$FOUND_DIR" ]]; then
    FOUND_DIR="$(find "$TMP_DIR" -maxdepth 2 -type d -name "apalache*" | head -n 1)"
  fi
  if [[ -z "$FOUND_DIR" ]]; then
    echo "Failed to locate Apalache distribution in downloaded archive." >&2
    exit 1
  fi
  rm -rf "$APALACHE_DIR"
  mkdir -p "$APALACHE_INSTALL_ROOT"
  cp -R "$FOUND_DIR" "$APALACHE_DIR"
  ln -sf "$APALACHE_DIR/bin/apalache-mc" "$APALACHE_BIN"
fi

echo "Dependencies installed."
