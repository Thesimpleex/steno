#!/bin/zsh
# Baut Steno.app und packt sie als build/Steno.dmg (App + Verknüpfung zu „Applications“).
# Der Dateiname bleibt über Versionen gleich, damit die Download-Links immer passen.
set -euo pipefail
cd "$(dirname "$0")"
./build.sh
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto build/Steno.app "$STAGE/Steno.app"
ln -s /Applications "$STAGE/Applications"
rm -f build/Steno.dmg
hdiutil create -volname "Steno $VERSION" -srcfolder "$STAGE" -ov -format UDZO build/Steno.dmg >/dev/null 2>&1
shasum -a 256 build/Steno.dmg
