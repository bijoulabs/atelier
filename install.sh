#!/usr/bin/env bash
# Install the atelier CLI + global skill. Idempotent.
# usage: ./install.sh [library-path]   (library-path seeds ~/.config/atelier/config on first install)
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"

( cd "$SRC/cli" && zig build -Doptimize=ReleaseSafe )
mkdir -p "$HOME/.local/bin"
install -m 0755 "$SRC/cli/zig-out/bin/atelier" "$HOME/.local/bin/atelier"

mkdir -p "$HOME/.claude/skills"
ln -sfn "$SRC/skill" "$HOME/.claude/skills/atelier"

mkdir -p "$HOME/.config/atelier"
CFG="$HOME/.config/atelier/config"
if [ ! -f "$CFG" ]; then
  if [ $# -ge 1 ]; then
    echo "library=$1" > "$CFG"
    echo "seeded $CFG"
  else
    echo "note: no default library configured; pass a library path (./install.sh <path>)"
    echo "      or set library=<path> in $CFG"
  fi
fi

echo "installed: $("$HOME/.local/bin/atelier" --help 2>&1 | head -1)"
