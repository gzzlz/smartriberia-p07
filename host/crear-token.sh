#!/usr/bin/env bash
# Genera el token de unión de un grupo. Solo lo ejecuta el piloto (puesto cp1) de cada grupo.
# Uso: host/crear-token.sh <grupo 1|2|3>
# Resultado: ~/smartriberia/token-gN.secreto (permisos 600). NUNCA va al repositorio.
set -euo pipefail
export LC_ALL=C
G="${1:-}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
SR_HOME="${SR_HOME:-$HOME/smartriberia}"
source "$REPO/lib/ui.sh"
[[ "$G" =~ ^[123]$ ]] || { ko "Uso: host/crear-token.sh <1|2|3>"; exit 1; }
F="$SR_HOME/token-g${G}.secreto"

titulo "SmartRiberIA · Token del grupo G$G" "Host: $(hostname) · $(date '+%F %T')"
seccion "Token"
if [[ -s "$F" ]]; then
  ok "Ya existe $F: se reutiliza (no se regenera)"
  info "Regenerarlo con el clúster creado impediría unir nodos nuevos"
else
  ( umask 077; openssl rand -hex 32 > "$F" )
  ok "Generado $F"
fi
comprobar "Permisos 600" "chmod 600 $F" bash -c "[[ \$(stat -c %a '$F') == 600 ]]"
comprobar "Formato: 64 caracteres hexadecimales" "Fichero dañado: bórralo y repite" grep -qxE '[0-9a-f]{64}' "$F"
comprobar "Fuera del repositorio" "No debe estar dentro de $REPO" bash -c "[[ '$F' != '$REPO'/* ]]"
info "Huella para comparar con tus compañeros (no es el token): ${C_N}$(sha256sum "$F" | cut -c1-12)${C_0}"
info "Compártelo con tu grupo por un canal PRIVADO; cada uno lo guarda en la misma ruta."
resumen
