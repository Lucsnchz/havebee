#!/bin/bash
# Compila Hive y arma build/Hive.app.
# Uso: scripts/build-app.sh            -> solo compila
#      scripts/build-app.sh --install  -> además la copia a /Applications
set -euo pipefail
cd "$(dirname "$0")/.."

[ -f Resources/AppIcon.icns ] || swift scripts/make-icon.swift

swift build -c release --force-resolved-versions

APP=build/Hive.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --force-resolved-versions --show-bin-path)/Hive" "$APP/Contents/MacOS/Hive"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/Credits.rtf "$APP/Contents/Resources/Credits.rtf"
cp LICENSE THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"
cp -R LICENSES "$APP/Contents/Resources/LICENSES"
codesign --force --sign - "$APP" >/dev/null
echo "Listo: $(pwd)/$APP"

if [ "${1:-}" = "--install" ]; then
  DEST=/Applications
  [ -w "$DEST" ] || DEST="$HOME/Applications"
  mkdir -p "$DEST"
  # Si Hive está abierta, hay que cerrarla antes de reemplazarla.
  if pgrep -xq Hive; then
    echo "Cerrá Hive antes de instalar (las sesiones se pueden reanudar después)." >&2
    exit 1
  fi
  rm -rf "$DEST/Hive.app"
  cp -R "$APP" "$DEST/"
  echo "Instalada en $DEST/Hive.app"
fi
