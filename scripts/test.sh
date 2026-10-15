#!/bin/bash
# Corre todos los tests de Hive.
# Uso: scripts/test.sh                      -> todos los tests
#      scripts/test.sh --snapshots <carpeta> -> además guarda capturas de las vistas en PNG
#      scripts/test.sh <filtro>              -> solo los tests que coinciden (ej. HiveCoreTests)
set -euo pipefail
cd "$(dirname "$0")/.."

if [ "${1:-}" = "--snapshots" ]; then
  export HIVE_SNAPSHOTS="${2:?Indicá la carpeta para las capturas}"
  mkdir -p "$HIVE_SNAPSHOTS"
  shift 2
fi

if [ $# -gt 0 ]; then
  swift test --filter "$1"
else
  swift test
fi

if [ -n "${HIVE_SNAPSHOTS:-}" ]; then
  echo "Capturas en $HIVE_SNAPSHOTS"
fi
