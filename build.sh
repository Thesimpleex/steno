#!/bin/zsh
# Baut Steno.app (nur Apple Silicon). Mit --install landet sie in /Applications.
# Signiert wird ad hoc – oder mit einer eigenen Identität: STENO_SIGN_IDENTITY="Name des Zertifikats" ./build.sh
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)"
# Im Ordner mit „.noindex“ findet Spotlight die Bau-Kopie nicht – sonst stünde Steno zweimal in der Suche.
APP=build/app.noindex/Steno.app
# Der Ordnername unter artifacts hängt vom Namen des Checkouts ab – deshalb suchen, neuester zuerst.
frameworks=(.build/artifacts/*/whisper/whisper.xcframework/macos-arm64_x86_64/whisper.framework(N/om))
FRAMEWORK="${frameworks[1]:-}"
[[ -n "$FRAMEWORK" ]] || { echo "whisper.framework not found – did 'swift build' succeed?" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN/Steno" "$APP/Contents/MacOS/Steno"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/ggml-silero-v5.1.2.bin Resources/AppIcon.icns Resources/Credits.rtf THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"
cp -R Resources/*.lproj "$APP/Contents/Resources/"
ditto "$FRAMEWORK" "$APP/Contents/Frameworks/whisper.framework"
LIB="$APP/Contents/Frameworks/whisper.framework/Versions/A/whisper"
lipo "$LIB" -thin arm64 -output "$LIB.arm64" && mv "$LIB.arm64" "$LIB"   # Intel-Teil wird nie gebraucht
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/Steno" 2>/dev/null || true
# Interne Symbole entfernen: Sie enthalten sonst den Ordner, in dem gebaut wurde.
strip -S -x "$APP/Contents/MacOS/Steno"

IDENTITY="${STENO_SIGN_IDENTITY:--}"
echo "Signiere mit: $IDENTITY"
codesign --force --sign "$IDENTITY" "$APP/Contents/Frameworks/whisper.framework"
codesign --force --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"
# Die Build-Kopie bei macOS abmelden, sonst startet „open Steno“ oder die Anmeldung womöglich sie statt der installierten App.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$APP" 2>/dev/null || true

if [[ "${1:-}" == "--install" ]]; then
  pkill -x Steno 2>/dev/null || true
  rm -rf /Applications/Steno.app
  ditto "$APP" /Applications/Steno.app
  echo "Installiert: /Applications/Steno.app"
fi
