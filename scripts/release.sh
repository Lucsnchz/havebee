#!/bin/bash
# Arma (y con --publish, publica) una versión de Havebee para descargar y para la actualización
# automática: app universal firmada y notarizada, Havebee-<versión>.dmg, appcast.xml (Sparkle) y
# latest.json (lo lee la web para el botón de descarga).
#
# Uso:
#   scripts/release.sh --notes "Qué cambió"            # arma en build/release/ sin publicar
#   scripts/release.sh --notes-file notas.md --publish  # arma y sube a havebee.com/downloads
#   scripts/release.sh --unsigned --notes "prueba"      # firma ad hoc, solo para probar en esta Mac
#
# Opciones:
#   --notes "…" | --notes-file F   notas de la versión (texto; las líneas con «- » son una lista)
#   --version X                    otra versión que la de Resources/Info.plist (solo para probar)
#   --unsigned                     firma ad hoc, sin notarizar (no se puede publicar)
#   --skip-notarize                firma con DEVELOPER_ID pero sin notarizar (no se puede publicar)
#   --publish                      sube el DMG, appcast.xml y latest.json al servidor
#   --appcast F                    appcast actual, para conservar las versiones anteriores
#                                  (con --publish se baja solo del servidor)
#   --base-url URL                 dónde quedan las descargas (por defecto https://havebee.com/downloads)
#   --out DIR                      carpeta de salida (por defecto build/release)
#
# Variables: DEVELOPER_ID (identidad de firma), NOTARY_PROFILE (perfil de notarytool, «havebee»),
# SPARKLE_ACCOUNT (cuenta de la clave EdDSA en el llavero, «havebee»), HAVEBEE_SERVER y
# HAVEBEE_REMOTE_DIR (destino de --publish).
set -euo pipefail
cd "$(dirname "$0")/.."

DEVELOPER_ID=${DEVELOPER_ID:-"Developer ID Application: Luciano Sanchez (L3VMKAPR6J)"}
NOTARY_PROFILE=${NOTARY_PROFILE:-havebee}
SPARKLE_ACCOUNT=${SPARKLE_ACCOUNT:-havebee}
SERVER=${HAVEBEE_SERVER:-forge@137.184.243.149}
REMOTE_DIR=${HAVEBEE_REMOTE_DIR:-/home/forge/havebee.com/downloads}
BASE_URL=https://havebee.com/downloads
OUT=build/release
VERSION=""
NOTES=""
UNSIGNED=false
SKIP_NOTARIZE=false
PUBLISH=false
PREVIOUS_APPCAST=""

fail() { echo "release: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --version) VERSION=$2; shift 2 ;;
    --notes) NOTES=$2; shift 2 ;;
    --notes-file) NOTES=$(cat "$2"); shift 2 ;;
    --unsigned) UNSIGNED=true; shift ;;
    --skip-notarize) SKIP_NOTARIZE=true; shift ;;
    --publish) PUBLISH=true; shift ;;
    --appcast) PREVIOUS_APPCAST=$2; shift 2 ;;
    --base-url) BASE_URL=${2%/}; shift 2 ;;
    --out) OUT=$2; shift 2 ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    *) fail "opción desconocida: $1 (ver --help)" ;;
  esac
done

PLIST_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
MIN_OS=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" Resources/Info.plist)
VERSION=${VERSION:-$PLIST_VERSION}
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || fail "versión inválida: «${VERSION}» (tiene que ser como 0.2.0)"
[ -n "$NOTES" ] || fail "faltan las notas de la versión (--notes o --notes-file)"

TOOLS=.build/artifacts/sparkle/Sparkle/bin
[ -x "$TOOLS/sign_update" ] || swift package resolve >/dev/null
[ -x "$TOOLS/sign_update" ] || fail "no encuentro las herramientas de Sparkle en $TOOLS"

# --- Qué se puede publicar --------------------------------------------------------------------
if $PUBLISH; then
  $UNSIGNED && fail "una versión sin firmar no se publica"
  $SKIP_NOTARIZE && fail "una versión sin notarizar no se publica"
  [ "$VERSION" = "$PLIST_VERSION" ] || fail "--version $VERSION no coincide con Resources/Info.plist ($PLIST_VERSION): cambiala ahí y commiteá"
  [ -z "${HAVEBEE_BUNDLE_ID:-}${HAVEBEE_BUILD:-}${HAVEBEE_VERSION:-}" ] || fail "HAVEBEE_BUNDLE_ID/BUILD/VERSION son solo para pruebas"
  [ -z "$(git status --porcelain)" ] || fail "hay cambios sin commitear: la versión tiene que salir de un commit"
  [ "$BASE_URL" = "https://havebee.com/downloads" ] || fail "--base-url es solo para pruebas"
fi

if $UNSIGNED; then
  IDENTITY=-
else
  IDENTITY=$DEVELOPER_ID
  security find-identity -v -p codesigning | grep -qF "\"$IDENTITY\"" || fail "no está el certificado «${IDENTITY}» en el llavero.
Crealo una vez: Xcode → Settings → Accounts → (tu cuenta) → Manage Certificates → + → Developer ID Application.
Para probar sin firma: --unsigned."
  if ! $SKIP_NOTARIZE; then
    xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 || fail "no está el perfil de notarización «${NOTARY_PROFILE}».
Crealo una vez (con una contraseña de app de appleid.apple.com):
  xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id TU_APPLE_ID --team-id L3VMKAPR6J"
  fi
fi

mkdir -p "$OUT"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# --- La app -----------------------------------------------------------------------------------
echo "==> Compilando Havebee $VERSION (Apple Silicon e Intel)"
HAVEBEE_VERSION=$VERSION scripts/build-app.sh --universal
APP=build/Havebee.app
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")
lipo -archs "$APP/Contents/MacOS/Havebee"

notarize() {
  echo "==> Notarizando $(basename "$1")"
  xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait
}

if ! $UNSIGNED; then
  echo "==> Firmando con «${IDENTITY}»"
  scripts/sign-app.sh "$APP" "$IDENTITY"
  if ! $SKIP_NOTARIZE; then
    ditto -c -k --keepParent "$APP" "$WORK/Havebee.zip"
    notarize "$WORK/Havebee.zip"
    xcrun stapler staple "$APP"
  fi
fi

# --- El DMG -----------------------------------------------------------------------------------
DMG_NAME="Havebee-$VERSION.dmg"
DMG="$OUT/$DMG_NAME"
echo "==> Armando $DMG_NAME"
mkdir -p "$WORK/dmg"
ditto "$APP" "$WORK/dmg/Havebee.app"
ln -s /Applications "$WORK/dmg/Applications"
rm -f "$DMG"
hdiutil create -quiet -volname Havebee -srcfolder "$WORK/dmg" -fs HFS+ -format UDZO -ov "$DMG"
if ! $UNSIGNED; then
  codesign --force --sign "$IDENTITY" --timestamp "$DMG"
  if ! $SKIP_NOTARIZE; then
    notarize "$DMG"
    xcrun stapler staple "$DMG"
  fi
fi

# La firma EdDSA va al final: grapar la notarización cambia el archivo.
SIGNATURE=$("$TOOLS/sign_update" --account "$SPARKLE_ACCOUNT" "$DMG" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')
[ -n "$SIGNATURE" ] || fail "sign_update no devolvió la firma EdDSA (¿está la clave «${SPARKLE_ACCOUNT}» en el llavero?)"
SIZE=$(stat -f%z "$DMG")
SHA256=$(shasum -a 256 "$DMG" | cut -d' ' -f1)

# --- appcast.xml y latest.json ----------------------------------------------------------------
if $PUBLISH && [ -z "$PREVIOUS_APPCAST" ]; then
  if scp -q "$SERVER:$REMOTE_DIR/appcast.xml" "$WORK/previous-appcast.xml" 2>/dev/null; then
    PREVIOUS_APPCAST="$WORK/previous-appcast.xml"
  fi
elif [ -z "$PREVIOUS_APPCAST" ] && [ -f "$OUT/appcast.xml" ]; then
  cp "$OUT/appcast.xml" "$WORK/previous-appcast.xml"
  PREVIOUS_APPCAST="$WORK/previous-appcast.xml"
fi

echo "==> Escribiendo appcast.xml y latest.json"
VERSION=$VERSION BUILD=$BUILD MIN_OS=$MIN_OS URL="$BASE_URL/$DMG_NAME" SIZE=$SIZE SHA256=$SHA256 \
SIGNATURE=$SIGNATURE NOTES=$NOTES PREVIOUS="$PREVIOUS_APPCAST" OUT=$OUT BASE_URL=$BASE_URL \
python3 -I - <<'PY'
import datetime, email.utils, html, json, os, sys
import xml.etree.ElementTree as ET

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)
e = os.environ
version, build, notes = e["VERSION"], int(e["BUILD"]), e["NOTES"].strip()
now = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)

def notes_html(text):
    parts, items = [], []
    def flush():
        if items:
            parts.append("<ul>" + "".join(f"<li>{html.escape(i)}</li>" for i in items) + "</ul>")
            items.clear()
    for line in text.splitlines():
        line = line.strip()
        if line.startswith(("- ", "* ")):
            items.append(line[2:].strip())
        else:
            flush()
            if line:
                parts.append(f"<p>{html.escape(line)}</p>")
    flush()
    return "".join(parts)

# Versiones anteriores: se conservan, salvo esta misma.
previous = []
if e.get("PREVIOUS") and os.path.exists(e["PREVIOUS"]):
    channel = ET.parse(e["PREVIOUS"]).getroot().find("channel")
    for item in channel.findall("item") if channel is not None else []:
        old_version = item.findtext(f"{{{SPARKLE}}}shortVersionString")
        old_build = int(item.findtext(f"{{{SPARKLE}}}version") or 0)
        if old_version == version:
            sys.exit(f"release: la versión {version} ya está en el appcast: subí el número en Resources/Info.plist")
        if old_build >= build:
            sys.exit(f"release: el build {build} no es mayor que el de {old_version} ({old_build})")
        previous.append(item)

rss = ET.Element("rss", {"version": "2.0"})
channel = ET.SubElement(rss, "channel")
ET.SubElement(channel, "title").text = "Havebee"
ET.SubElement(channel, "link").text = "https://havebee.com"
ET.SubElement(channel, "description").text = "Actualizaciones de Havebee"
ET.SubElement(channel, "language").text = "es"

item = ET.SubElement(channel, "item")
ET.SubElement(item, "title").text = f"Havebee {version}"
ET.SubElement(item, "pubDate").text = email.utils.format_datetime(now)
ET.SubElement(item, f"{{{SPARKLE}}}version").text = str(build)
ET.SubElement(item, f"{{{SPARKLE}}}shortVersionString").text = version
ET.SubElement(item, f"{{{SPARKLE}}}minimumSystemVersion").text = e["MIN_OS"]
ET.SubElement(item, "description").text = notes_html(notes)
ET.SubElement(item, "enclosure", {
    "url": e["URL"], "length": e["SIZE"], "type": "application/octet-stream",
    f"{{{SPARKLE}}}edSignature": e["SIGNATURE"],
})
for old in previous:
    channel.append(old)

ET.indent(rss)
out = e["OUT"]
ET.ElementTree(rss).write(os.path.join(out, "appcast.xml"), encoding="utf-8", xml_declaration=True)

latest = {
    "version": version,
    "build": build,
    "url": e["URL"],
    "size": int(e["SIZE"]),
    "sha256": e["SHA256"],
    "minimumSystemVersion": e["MIN_OS"],
    "publishedAt": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
    "notes": notes,
}
with open(os.path.join(out, "latest.json"), "w", encoding="utf-8") as f:
    json.dump(latest, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY

echo "Listo: $DMG ($SIZE bytes), build $BUILD"
echo "      $OUT/appcast.xml y $OUT/latest.json"

# --- Publicar ---------------------------------------------------------------------------------
if $PUBLISH; then
  echo "==> Subiendo a $SERVER:$REMOTE_DIR"
  ssh "$SERVER" "mkdir -p '$REMOTE_DIR'"
  # Primero el DMG; recién después lo que lo anuncia, así nadie ve una versión que todavía no bajó.
  rsync -t --progress "$DMG" "$SERVER:$REMOTE_DIR/"
  ssh "$SERVER" "cd '$REMOTE_DIR' && ln -sfn '$DMG_NAME' Havebee.dmg"
  rsync -t "$OUT/appcast.xml" "$OUT/latest.json" "$SERVER:$REMOTE_DIR/"
  git tag -a "v$VERSION" -m "Havebee $VERSION" 2>/dev/null && echo "Etiqueta v$VERSION creada (subila con: git push origin v$VERSION)"
  echo "Publicada: $BASE_URL/$DMG_NAME"
fi
