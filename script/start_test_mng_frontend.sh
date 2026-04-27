#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WEB_DIR="$ROOT_DIR/test-mng-web"
VITE_PATTERN="$WEB_DIR.*vite"

echo "Restarting Main Frontend (test-mng-web)..."

if pgrep -f "$VITE_PATTERN" >/dev/null 2>&1; then
  echo "Stopping existing frontend dev process..."
  pkill -f "$VITE_PATTERN" || true
  sleep 2

  if pgrep -f "$VITE_PATTERN" >/dev/null 2>&1; then
    echo "Force stopping lingering frontend process..."
    pkill -9 -f "$VITE_PATTERN" || true
  fi
else
  echo "No running frontend dev process found."
fi

cd "$WEB_DIR"
pnpm install
pnpm run dev
