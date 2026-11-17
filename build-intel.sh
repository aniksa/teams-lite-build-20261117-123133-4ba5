#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

APP_NAME="Teams Lite"
EXECUTABLE="TeamsLite"
TARGET="TeamsLite"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
MACOS="$APP/Contents/MacOS"
RES="$APP/Contents/Resources"

rm -rf "$DIST"
mkdir -p "$MACOS" "$RES"

echo "==> Building x86_64 release"
swift build -c release --arch x86_64 -Xlinker -dead_strip
X86_BIN="$ROOT/.build/x86_64-apple-macosx/release/$TARGET"

echo "==> Building arm64 release"
swift build -c release --arch arm64 -Xlinker -dead_strip
ARM_BIN="$ROOT/.build/arm64-apple-macosx/release/$TARGET"

test -f "$X86_BIN" || { echo "Missing x86_64 binary: $X86_BIN" >&2; exit 1; }
test -f "$ARM_BIN" || { echo "Missing arm64 binary: $ARM_BIN" >&2; exit 1; }

echo "==> Creating Universal2 executable"
lipo -create "$X86_BIN" "$ARM_BIN" -output "$MACOS/$EXECUTABLE"
chmod +x "$MACOS/$EXECUTABLE"
echo "==> Stripping nonessential symbols"
strip -x "$MACOS/$EXECUTABLE"

ARCHS="$(lipo -archs "$MACOS/$EXECUTABLE")"
echo "==> Architectures: $ARCHS"
echo "$ARCHS" | grep -q "x86_64"
echo "$ARCHS" | grep -q "arm64"

cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

if [[ -d "$ROOT/Resources/Assets" ]]; then
  cp -R "$ROOT/Resources/Assets/." "$RES/"
fi

PLIST_EXEC="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")"
test "$PLIST_EXEC" = "$EXECUTABLE"

codesign --force --deep --sign - --entitlements "$ROOT/Resources/TeamsLite.entitlements" "$APP"
codesign --verify --deep --strict "$APP"

echo "==> Verifying sandbox entitlement"
ENTITLEMENTS="$(codesign -d --entitlements :- "$APP" 2>/dev/null)"
echo "$ENTITLEMENTS" | grep -q "com.apple.security.app-sandbox"
echo "$ENTITLEMENTS" | grep -q "<true/>"
echo "$ENTITLEMENTS" | grep -q "com.apple.security.files.user-selected.read-only"

ARTIFACT="Teams-Lite-Native-v3.10.3-Files-Universal2.zip"
cd "$DIST"
ditto -c -k --sequesterRsrc --keepParent "$APP_NAME.app" "$ARTIFACT"
shasum -a 256 "$ARTIFACT" > "$ARTIFACT.sha256"

echo "==> Built: $DIST/$ARTIFACT"
