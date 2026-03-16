#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-root)
      REPO_ROOT="$(cd "$2" && pwd)"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

VENV_DIR="${VENV_DIR:-$REPO_ROOT/.verifier/.venv}"
PYTHON_BIN="$VENV_DIR/bin/python"
if [[ ! -x "$PYTHON_BIN" ]]; then
  PYTHON_BIN="${PYTHON_BIN:-python3}"
fi

"$PYTHON_BIN" - <<'PY' "$SCRIPT_DIR" "$REPO_ROOT"
import pathlib
import sys

script_dir = pathlib.Path(sys.argv[1]).resolve()
repo_root = pathlib.Path(sys.argv[2]).resolve()
sys.path.insert(0, str(script_dir))

from doc_governance import write_architecture_packet  # noqa: E402
from verifier_common import load_yaml  # noqa: E402

config = load_yaml(repo_root / ".verifier" / "structural.yaml")
packet_path, _ = write_architecture_packet(repo_root, config)
print(packet_path)
PY
