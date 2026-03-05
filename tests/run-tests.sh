#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_FILE="$SCRIPT_DIR/adb-manager.bats"

if ! command -v bats >/dev/null 2>&1; then
    echo "bats is not installed."
    echo "Install example:"
    echo "  Ubuntu/Debian: sudo apt install -y bats"
    echo "  Arch/CachyOS : sudo pacman -Sy --noconfirm bats"
    exit 1
fi

bats "$TEST_FILE" "$@"
