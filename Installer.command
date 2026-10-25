#!/bin/bash
# Bygger MODULR.app og lægger den i Programmer-mappen.
#   bash Installer.command                     -> byg og installer
#   bash Installer.command --build-only <mappe> -> byg kun (bruges af auto-opdateringen)
set -e
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
cd "$(dirname "$0")"
APP="MODULR.app"

MODE="install"
OUT="$(pwd)/build"
if [ "$1" = "--build-only" ]; then
  MODE="build"
  OUT="$2"
fi

if [ "$MODE" = "install" ]; then echo "== MODULR installation =="; fi

if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo
  echo "Apples gratis udviklerværktøjer mangler. Der åbner nu et vindue - klik 'Installer'."
  echo "Når det er færdigt (ca. 5-10 min), så kør dette script igen."
  xcode-select --install 2>/dev/null || true
  exit 1
fi

[ "$MODE" = "install" ] && echo "Bygger appen (tager ca. et minut)..."
rm -rf "$OUT"
mkdir -p "$OUT/$APP/Contents/MacOS" "$OUT/$APP/Contents/Resources"
xcrun swiftc -O -parse-as-library -target "$(uname -m)-apple-macos13.0" \
  main.swift -o "$OUT/$APP/Contents/MacOS/MODULR"
cp Info.plist "$OUT/$APP/Contents/Info.plist"

if [ ! -f icon.png ] && [ -f icon.b64 ]; then base64 -D -i icon.b64 -o icon.png; fi
ICONSET="$OUT/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s icon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) icon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$OUT/$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

if [ ! -f logo.png ] && [ -f logo.b64 ]; then base64 -D -i logo.b64 -o logo.png; fi
[ -f logo.png ] && cp logo.png "$OUT/$APP/Contents/Resources/logo.png"

codesign --force --deep -s - "$OUT/$APP" >/dev/null 2>&1 || true

if [ "$MODE" = "build" ]; then exit 0; fi

DEST="/Applications"
if [ ! -w "$DEST" ]; then DEST="$HOME/Applications"; mkdir -p "$DEST"; fi
osascript -e 'quit app "MODULR"' >/dev/null 2>&1 || true
osascript -e 'quit app "BitrateTjek"' >/dev/null 2>&1 || true
rm -rf "$DEST/BitrateTjek.app"   # den gamle version før navneskiftet
rm -rf "$DEST/$APP"
cp -R "$OUT/$APP" "$DEST/"
rm -rf "$OUT"

echo
echo "Færdig! MODULR ligger nu i $DEST og åbner om et øjeblik."
echo "Fremover opdaterer appen sig selv."
open "$DEST/$APP"
