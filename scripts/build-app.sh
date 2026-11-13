#!/bin/bash
# Compila Havebee y arma build/Havebee.app.
# Uso: scripts/build-app.sh               -> solo compila (para esta Mac)
#      scripts/build-app.sh --install     -> además la copia a /Applications
#      scripts/build-app.sh --universal   -> Apple Silicon e Intel (lo usa scripts/release.sh)
#
# El ejecutable de SwiftPM se llama Hive; dentro de la app se llama Havebee. El identificador
# (com.lucianosanchez.hive) y la carpeta de datos (~/Library/Application Support/Hive) no cambian:
# ajustes, permisos de avisos, sesiones e historial siguen siendo los mismos.
set -euo pipefail
cd "$(dirname "$0")/.."

INSTALL=false
ARCHS=()
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=true ;;
    --universal) ARCHS=(--arch arm64 --arch x86_64) ;;
    *) echo "Opción desconocida: $arg" >&2; exit 2 ;;
  esac
done

[ -f Resources/AppIcon.icns ] || swift scripts/make-icon.swift

BUILD_FLAGS=(-c release --force-resolved-versions ${ARCHS[@]+"${ARCHS[@]}"})
swift build "${BUILD_FLAGS[@]}"
BIN=$(swift build "${BUILD_FLAGS[@]}" --show-bin-path)

APP=build/Havebee.app
rm -rf "$APP" build/Hive.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN/Hive" "$APP/Contents/MacOS/Havebee"
# Las rutas de esta Mac que agrega SwiftPM no sirven en otra: solo queda la de Contents/Frameworks.
for rpath in $(otool -l "$APP/Contents/MacOS/Havebee" | awk '/LC_RPATH/{getline; getline; print $2}'); do
  case "$rpath" in
    @executable_path/../Frameworks|/usr/lib/swift) ;;
    *) install_name_tool -delete_rpath "$rpath" "$APP/Contents/MacOS/Havebee" 2>/dev/null || true ;;
  esac
done
# Sparkle (actualizaciones): el framework entero, con sus servicios y su Updater.app.
ditto "$BIN/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# El número de build crece con cada commit: es lo que compara la actualización automática.
BUILD=${HAVEBEE_BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"
# Solo para scripts/release.sh y sus pruebas: otra versión, u otro identificador para que una copia
# de prueba no comparta ajustes con la app instalada.
[ -n "${HAVEBEE_VERSION:-}" ] && /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $HAVEBEE_VERSION" "$APP/Contents/Info.plist"
[ -n "${HAVEBEE_BUNDLE_ID:-}" ] && /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $HAVEBEE_BUNDLE_ID" "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/Credits.rtf "$APP/Contents/Resources/Credits.rtf"
cp LICENSE THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"
cp -R LICENSES "$APP/Contents/Resources/LICENSES"
scripts/sign-app.sh "$APP" -
echo "Listo: $(pwd)/$APP"

if $INSTALL; then
  DEST=/Applications
  [ -w "$DEST" ] || DEST="$HOME/Applications"
  mkdir -p "$DEST"
  # Si está abierta (con el nombre nuevo o el viejo), hay que cerrarla antes de reemplazarla. Con ps
  # y no con pgrep: desde la terminal de un agente (sandbox) pgrep no ve la app y daría «cerrada».
  RUNNING=$(ps -axo comm=)
  for name in Havebee Hive; do
    if grep -qxF "$DEST/$name.app/Contents/MacOS/$name" <<<"$RUNNING"; then
      echo "Cerrá Havebee antes de instalar (las sesiones se pueden reanudar después)." >&2
      exit 1
    fi
  done
  rm -rf "$DEST/Havebee.app.new"
  cp -R "$APP" "$DEST/Havebee.app.new"
  rm -rf "$DEST/Havebee.app"
  mv "$DEST/Havebee.app.new" "$DEST/Havebee.app"
  # La instalación vieja se llamaba Hive.app: se borra solo después de copiar la nueva.
  rm -rf "$DEST/Hive.app"
  echo "Instalada en $DEST/Havebee.app"
fi
