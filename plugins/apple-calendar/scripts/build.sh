#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/server/Apple Calendar.app"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/apple-calendar-build.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
STAGED_APP="$STAGE/Apple Calendar.app"
BUILD_CACHE="${TMPDIR:-/tmp}/apple-calendar-swift-module-cache"
mkdir -p "$STAGED_APP/Contents/MacOS" "$BUILD_CACHE"
cp "$APP/Contents/Info.plist" "$STAGED_APP/Contents/Info.plist"
/usr/bin/plutil -lint "$APP/Contents/Info.plist" >&2
/usr/bin/xcrun swiftc -O -swift-version 5 -parse-as-library \
  -target "$(uname -m)-apple-macosx14.0" \
  -module-cache-path "$BUILD_CACHE" \
  "$ROOT"/server/Sources/*.swift -o "$STAGED_APP/Contents/MacOS/AppleCalendarMCP"
# Sign outside file-provider directories so Finder metadata cannot race signing.
/usr/bin/xattr -cr "$STAGED_APP"
/usr/bin/codesign --force --sign - --identifier com.yinyueyang.apple-calendar-plugin "$STAGED_APP" >&2
/usr/bin/codesign --verify --strict "$STAGED_APP" >&2
/usr/bin/ditto --norsrc "$STAGED_APP" "$APP"
"$APP/Contents/MacOS/AppleCalendarMCP" --self-test
