#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR/../.." rev-parse --show-toplevel)"
HOOK_PATH="$(git -C "$REPO_ROOT" rev-parse --git-path hooks/pre-commit)"

mkdir -p "$(dirname "$HOOK_PATH")"

cat > "$HOOK_PATH" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOK_SCRIPT="$REPO_ROOT/scripts/dev/pre-commit"

if [[ ! -x "$HOOK_SCRIPT" ]]; then
    echo "Missing pre-commit hook script at $HOOK_SCRIPT" >&2
    exit 1
fi

exec "$HOOK_SCRIPT" "$@"
EOF

chmod +x "$HOOK_PATH"

echo "Installed pre-commit hook at $HOOK_PATH"
