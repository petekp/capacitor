#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
VENV_DIR="${VENV_DIR:-$REPO_ROOT/.verifier/.venv}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
APALACHE_VERSION="${APALACHE_VERSION:-0.52.2}"
APALACHE_REPO="${APALACHE_REPO:-apalache-mc/apalache}"
APALACHE_HOME="${HOME}/.local/bin"
APALACHE_INSTALL_ROOT="${HOME}/.local/share"
APALACHE_BIN="${APALACHE_HOME}/apalache-mc"
APALACHE_DIR="${APALACHE_INSTALL_ROOT}/apalache-${APALACHE_VERSION}"

mkdir -p "$REPO_ROOT/.verifier/facts" "$REPO_ROOT/.verifier/reports" "$REPO_ROOT/.verifier/specs" "$APALACHE_HOME"

"$PYTHON_BIN" - <<'PY'
import sys
if sys.version_info < (3, 10):
    raise SystemExit("Python 3.10+ is required")
PY

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
  ARCHIVE="apalache.tgz"
  URL="https://github.com/${APALACHE_REPO}/releases/download/v${APALACHE_VERSION}/apalache.tgz"
  curl -fsSL "$URL" -o "$TMP_DIR/$ARCHIVE"
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
