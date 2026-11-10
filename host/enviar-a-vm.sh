#!/usr/bin/env bash
# Envía a la VM del puesto: el repositorio, los artefactos de RKE2 y el token del grupo (si existen).
# Uso: host/enviar-a-vm.sh <grupo> <puesto>
# Destinos en la VM: ~/repo, ~/rke2-artefactos/<versión>, ~/.smartriberia/token (600)
set -euo pipefail
export LC_ALL=C
GRUPO_ARG="${1:-}"; PUESTO="${2:-}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
SR_HOME="${SR_HOME:-$HOME/smartriberia}"
source "$REPO/lib/ui.sh"
[[ "$GRUPO_ARG" =~ ^[123]$ && -n "$PUESTO" ]] || { ko "Uso: host/enviar-a-vm.sh <1|2|3> <cp1|…|w3>"; exit 1; }
source "$REPO/grupos/comun.env"; source "$REPO/grupos/g${GRUPO_ARG}.env"; source "$REPO/lib/puesto.sh"
[[ -n "$X" ]] || { ko "Puesto desconocido: $PUESTO"; exit 1; }
DEST="$USUARIO_VM@$MGMT_VM_IP"
SSHO=(-o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new)
ART="$SR_HOME/rke2/$RKE2_VERSION"
TOKEN="$SR_HOME/token-g${GRUPO}.secreto"

titulo "SmartRiberIA · Enviar a $NOMBRE" "Host: $(hostname) · $(date '+%F %T')"
seccion "Conexión"
comprobar "SSH sin contraseña a $DEST" "¿VM apagada? ¿Clave SSH no instalada? Prueba: ssh $DEST" ssh "${SSHO[@]}" "$DEST" true
comprobar "La VM es $NOMBRE" "Estás conectando a otra VM" bash -c "[[ \$(ssh ${SSHO[*]} $DEST hostname) == '$NOMBRE' ]]"
parar_si_ko

seccion "1. Repositorio → ~/repo"
VERSION_REPO="$(git -C "$REPO" describe --tags --always --dirty 2>/dev/null || echo 'sin-git')"
if tar -C "$REPO" --exclude=.git -czf - . | ssh "${SSHO[@]}" "$DEST" "rm -rf ~/repo && mkdir -p ~/repo && tar -xzf - -C ~/repo && echo '$VERSION_REPO' > ~/repo/.version"; then
  ok "Repositorio enviado (versión $VERSION_REPO)"
else ko "Envío del repositorio"; fi
[[ "$VERSION_REPO" == *dirty* ]] && aviso "El repositorio tiene cambios sin commit" "Haz commit antes de validar el hito"

seccion "2. Artefactos RKE2 → ~/rke2-artefactos/$RKE2_VERSION"
if [[ -d "$ART" ]]; then
  ssh "${SSHO[@]}" "$DEST" "mkdir -p ~/rke2-artefactos/$RKE2_VERSION"
  if tar -C "$ART" -cf - . | ssh "${SSHO[@]}" "$DEST" "tar -xf - -C ~/rke2-artefactos/$RKE2_VERSION"; then ok "Artefactos copiados"
  else ko "Copia de artefactos"; fi
  comprobar "SHA-256 correcto también en la VM" "Copia corrupta: repite este script" \
    ssh "${SSHO[@]}" "$DEST" "cd ~/rke2-artefactos/$RKE2_VERSION && grep -E ' (rke2\\.linux-amd64\\.tar\\.gz|rke2-images-(core|cilium)\\.linux-amd64\\.tar\\.zst)\$' sha256sum-amd64.txt | sha256sum -c --quiet -"
else
  aviso "No hay artefactos en $ART" "Ejecuta antes host/descargar-rke2.sh"
fi

seccion "3. Token del grupo → ~/.smartriberia/token"
if [[ -s "$TOKEN" ]]; then
  if ssh "${SSHO[@]}" "$DEST" "umask 077; mkdir -p ~/.smartriberia && cat > ~/.smartriberia/token" < "$TOKEN"; then ok "Token copiado (permisos 600)"
  else ko "Copia del token"; fi
  comprobar "Huella del token idéntica en la VM" "" bash -c "[[ \$(ssh ${SSHO[*]} $DEST 'sha256sum ~/.smartriberia/token' | cut -c1-12) == \$(sha256sum '$TOKEN' | cut -c1-12) ]]"
else
  aviso "No hay token en $TOKEN" "El piloto lo genera con host/crear-token.sh $GRUPO y lo comparte"
fi
resumen
