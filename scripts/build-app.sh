#!/bin/bash
# Compila Havebee y arma build/Havebee.app.
# Uso: scripts/build-app.sh            -> solo compila
#      scripts/build-app.sh --install  -> además la copia a /Applications
#
# El ejecutable de SwiftPM se llama Hive; dentro de la app se llama Havebee. El identificador
# (com.lucianosanchez.hive) y la carpeta de datos (~/Library/Application Support/Hive) no cambian:
# ajustes, permisos de avisos, sesiones e historial siguen siendo los mismos.
set -euo pipefail
cd "$(dirname "$0")/.."

[ -f Resources/AppIcon.icns ] || swift scripts/make-icon.swift

swift build -c release --force-resolved-versions

APP=build/Havebee.app
rm -rf "$APP" build/Hive.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --force-resolved-versions --show-bin-path)/Hive" "$APP/Contents/MacOS/Havebee"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# El número de build crece con cada commit: es lo que compara la actualización automática.
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"
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
  # Si está abierta (con el nombre nuevo o el viejo), hay que cerrarla antes de reemplazarla.
  if pgrep -xq Havebee || pgrep -xq Hive; then
    echo "Cerrá Havebee antes de instalar (las sesiones se pueden reanudar después)." >&2
    exit 1
  fi
  rm -rf "$DEST/Havebee.app.new"
  cp -R "$APP" "$DEST/Havebee.app.new"
  rm -rf "$DEST/Havebee.app"
  mv "$DEST/Havebee.app.new" "$DEST/Havebee.app"
  # La instalación vieja se llamaba Hive.app: se borra solo después de copiar la nueva.
  rm -rf "$DEST/Hive.app"
  echo "Instalada en $DEST/Havebee.app"
fi
