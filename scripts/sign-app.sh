#!/bin/bash
# Firma Havebee.app de adentro hacia afuera: los servicios de Sparkle, su framework y la app, todo
# con la misma identidad (sin --deep).
# Uso: scripts/sign-app.sh <Havebee.app> <identidad>
#   «-»             -> firma ad hoc, sin hardened runtime (para esta Mac y las pruebas)
#   otra identidad  -> «Developer ID Application: …» (o «Apple Development: …» para probar), con
#                      hardened runtime y sello de tiempo.
#
# Ad hoc no lleva hardened runtime a propósito: la validación de librerías exige que la app y
# Sparkle.framework tengan el mismo Team ID, y una firma ad hoc no tiene ninguno (dyld no carga
# Sparkle y la app se cierra al abrir).
set -euo pipefail
APP=$1
IDENTITY=$2
OPTS=(--force --sign "$IDENTITY")
[ "$IDENTITY" != "-" ] && OPTS+=(--options runtime --timestamp)

sign() { codesign "${OPTS[@]}" "$@" 2>&1 | grep -v "replacing existing signature" >&2 || true; }

FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
if [ -d "$FRAMEWORK" ]; then
  V="$FRAMEWORK/Versions/B"
  # El orden lo pide Sparkle: primero lo de adentro. Downloader conserva sus entitlements.
  [ -d "$V/XPCServices/Installer.xpc" ] && sign "$V/XPCServices/Installer.xpc"
  [ -d "$V/XPCServices/Downloader.xpc" ] && sign --preserve-metadata=entitlements "$V/XPCServices/Downloader.xpc"
  sign "$V/Autoupdate"
  sign "$V/Updater.app"
  sign "$FRAMEWORK"
fi
sign "$APP"
codesign --verify --deep --strict "$APP"

# Todas las piezas con el mismo Team ID (o ninguna, si es ad hoc): si no, dyld no carga Sparkle.
team() { codesign -dv "$1" 2>&1 | sed -n 's/^TeamIdentifier=//p'; }
EXPECTED=$(team "$APP")
for piece in "$FRAMEWORK" "$FRAMEWORK/Versions/B/Autoupdate" "$FRAMEWORK/Versions/B/Updater.app" \
             "$FRAMEWORK/Versions/B/XPCServices/Installer.xpc" "$FRAMEWORK/Versions/B/XPCServices/Downloader.xpc"; do
  [ -e "$piece" ] || continue
  if [ "$(team "$piece")" != "$EXPECTED" ]; then
    echo "Firma inconsistente: $piece tiene Team ID «$(team "$piece")» y la app «${EXPECTED}»." >&2
    exit 1
  fi
done
