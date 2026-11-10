#!/usr/bin/env bash
# Descarga UNA vez por PC los artefactos air-gap de la versión fijada de RKE2 y los verifica.
# Uso: host/descargar-rke2.sh
# Destino: ~/smartriberia/rke2/<versión>/  (fuera del repositorio)
set -euo pipefail
export LC_ALL=C
REPO="$(cd "$(dirname "$0")/.." && pwd)"
SR_HOME="${SR_HOME:-$HOME/smartriberia}"
source "$REPO/lib/ui.sh"
source "$REPO/grupos/comun.env"
DEST="$SR_HOME/rke2/$RKE2_VERSION"

titulo "SmartRiberIA · Artefactos RKE2 $RKE2_VERSION" "Host: $(hostname) · $(date '+%F %T')"

seccion "Parámetros"
dato "Versión"   "$RKE2_VERSION"
dato "Origen"    "$RKE2_URL"
dato "Instalador" "$RKE2_INSTALL_URL"
dato "Destino"   "$DEST"

seccion "1. Comprobaciones previas"
for h in curl sha256sum; do comprobar "Herramienta: $h" "No está instalada" command -v "$h"; done
mkdir -p "$DEST"
LIBRE_GB=$(( $(df -Pk "$DEST" | awk 'NR==2 {print $4}') / 1024 / 1024 ))
if (( LIBRE_GB >= 5 )); then ok "Espacio libre: ${LIBRE_GB} GiB (necesita ~2)"; else ko "Espacio libre: ${LIBRE_GB} GiB" "Libera espacio en /home"; fi
parar_si_ko

seccion "2. Descarga (se omite lo que ya está)"
for f in $RKE2_ARTEFACTOS; do
  if [[ -s "$DEST/$f" && "$f" != sha256sum-amd64.txt ]]; then info "$f ya descargado"; continue; fi
  if curl -fsSL --retry 3 -o "$DEST/$f.part" "$RKE2_URL/$f"; then mv "$DEST/$f.part" "$DEST/$f"; ok "Descargado $f ($(du -h "$DEST/$f" | cut -f1))"
  else rm -f "$DEST/$f.part"; ko "Descarga de $f" "¿Nombre del artefacto o versión incorrectos? Comprueba $RKE2_URL/$f"; fi
done
if curl -fsSL --retry 3 -o "$DEST/install.sh.part" "$RKE2_INSTALL_URL"; then mv "$DEST/install.sh.part" "$DEST/install.sh"; ok "Descargado install.sh (fijado a $RKE2_VERSION)"
else rm -f "$DEST/install.sh.part"; ko "Descarga de install.sh"; fi
parar_si_ko

seccion "3. Verificación SHA-256 contra sha256sum-amd64.txt oficial"
for f in $RKE2_ARTEFACTOS; do
  [[ "$f" == sha256sum-amd64.txt ]] && continue
  if ! grep -q " ${f}\$" "$DEST/sha256sum-amd64.txt"; then ko "$f figura en sha256sum-amd64.txt" "El fichero de sumas no lo incluye"; continue; fi
  comprobar "SHA-256 de $f" "Descarga corrupta: bórralo y repite" \
    bash -c "cd '$DEST' && grep ' ${f}\$' sha256sum-amd64.txt | sha256sum -c --quiet -"
done
comprobar "install.sh es un script de shell" "La descarga no es el instalador" bash -c "head -1 '$DEST/install.sh' | grep -q '^#!'"

seccion "Contenido"
ls -lh "$DEST" | tail -n +2 | bloque "$DEST"
resumen
