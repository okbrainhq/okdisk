#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BASENAME="OKDisk"
EXECUTABLE_NAME="OKDiskApp"
ENV="dev"

for arg in "$@"; do
  case "$arg" in
    --prod) ENV="prod" ;;
    --dev) ENV="dev" ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

if [[ "$ENV" == "prod" ]]; then
  APP_NAME="$APP_BASENAME"
  PLIST="$ROOT/Info.plist"
else
  APP_NAME="$APP_BASENAME-Dev"
  PLIST="$ROOT/Info-Dev.plist"
fi

APP="$ROOT/$APP_NAME.app"
BINARY="$ROOT/.build/release/$EXECUTABLE_NAME"
ENTITLEMENTS="$ROOT/OKDisk.entitlements"

cd "$ROOT"
export CODE_SIGNING_ALLOWED=NO
export CODE_SIGN_IDENTITY="-"

swift build -c release --product "$EXECUTABLE_NAME"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/$EXECUTABLE_NAME"
cp "$PLIST" "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

if [[ -f "$ENTITLEMENTS" ]]; then
  codesign --force --sign - --timestamp=none --entitlements "$ENTITLEMENTS" "$APP" >/dev/null
else
  codesign --force --sign - --timestamp=none "$APP" >/dev/null
fi
codesign --verify --deep --strict "$APP" >/dev/null

echo "Built $APP (env=$ENV)"
