#!/bin/zsh
# Zeichnet die Fenster von Steno als PNG – ohne Bildschirmaufnahme, mit Beispieldaten in einem eigenen Ordner.
#   tools/screenshots.sh <ordner> [en|de|fr]              Prüfbilder aller Seiten, hell und dunkel
#   tools/screenshots.sh --marketing <ordner> [en|de|fr]  Bilder für README und Webseite
set -euo pipefail
cd "$(dirname "$0")/.."

mode=--snapshots
if [[ "${1:-}" == "--marketing" ]]; then mode=--marketing; shift; fi
out="${1:?Ordner angeben}"
# Mit der Sprache auch das Datumsformat („26.09.26“ statt „9/26/26“), nur für diesen Aufruf.
lang=()
case "${2:-}" in
  de) lang=(--lang de -AppleLocale de_DE) ;;
  en) lang=(--lang en -AppleLocale en_US) ;;
  fr) lang=(--lang fr -AppleLocale fr_FR) ;;
  "") ;;
  *) lang=(--lang "$2") ;;
esac

swift build --arch arm64 >/dev/null
bin="$(swift build --arch arm64 --show-bin-path)/Steno"
libs=(.build/artifacts/*/whisper/whisper.xcframework/macos-arm64_x86_64(N/om))
[[ -n "${libs[1]:-}" ]] || { echo "whisper.framework not found – did 'swift build' succeed?" >&2; exit 1; }
mkdir -p "$out"
DYLD_FRAMEWORK_PATH="$PWD/${libs[1]}" "$bin" "$mode" "$out" "${lang[@]}"
echo "Bilder in $out"
