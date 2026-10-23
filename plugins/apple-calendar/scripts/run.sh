#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BINARY="$ROOT/server/Apple Calendar.app/Contents/MacOS/AppleCalendarMCP"
if [ ! -x "$BINARY" ]; then
  echo 'Apple Calendar native component is missing. Run scripts/build.sh on this Mac.' >&2
  exit 1
fi
exec "$BINARY" "$@"
