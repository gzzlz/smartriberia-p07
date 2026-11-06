#!/usr/bin/env bash
# Hito 01 (P07): identidad y conectividad de la VM. Se ejecuta DENTRO de la VM.
# Uso:  bash vm/comprobar-hito01.sh <grupo 1|2|3> <puesto cp1|cp2|cp3|w1|w2|w3>
# Deja la evidencia (sin colores) en ~/evidencias/hito01_<vm>_<fecha>.txt
set -euo pipefail
export LC_ALL=C

GRUPO_ARG="${1:-}"; PUESTO="${2:-}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
[[ "$GRUPO_ARG" =~ ^[123]$ && -n "$PUESTO" ]] || { echo "Uso: bash vm/comprobar-hito01.sh <1|2|3> <cp1|...|w3>"; exit 1; }
source "$REPO/grupos/comun.env"
source "$REPO/grupos/g${GRUPO_ARG}.env"

PUESTO="$PUESTO"; source "$REPO/lib/puesto.sh"
[[ -n "$X" ]] || { echo "Puesto desconocido: $PUESTO"; exit 1; }

# Evidencia: pantalla con colores, fichero sin colores
mkdir -p "$HOME/evidencias"
EVID="$HOME/evidencias/hito01_${NOMBRE}_$(date +%Y%m%d_%H%M%S).txt"
[[ -t 1 ]] && export FORCE_COLOR=1

main() {
source "$REPO/lib/ui.sh"

titulo "SmartRiberIA · Hito 01 · $NOMBRE" "VM: $(hostname) · $(date '+%F %T %Z')"

# --- Identidad ---------------------------------------------------------------
seccion "1. Identidad"
HN="$(hostnamectl --static 2>/dev/null || hostname)"
if [[ "$HN" == "$NOMBRE" ]]; then ok "Hostname: $HN"; else ko "Hostname: $HN (esperado $NOMBRE)" "Puesto equivocado o cloud-init no aplicado"; fi
MID="$(cat /etc/machine-id 2>/dev/null || true)"
if [[ "$MID" =~ ^[0-9a-f]{32}$ ]]; then ok "machine-id propio: $MID"; else ko "machine-id vacío o inválido" "La imagen no se generalizó"; fi
UUID="$(sudo -n cat /sys/class/dmi/id/product_uuid 2>/dev/null || echo '?')"
dato "product_uuid" "$UUID"
HUELLA="$(ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub 2>/dev/null | awk '{print $2}' || true)"
if [[ -n "$HUELLA" ]]; then ok "Clave SSH de host propia: $HUELLA"; else ko "Sin clave SSH de host" "cloud-init no generó las claves"; fi
info "machine-id, product_uuid y huella SSH deben ser distintos en las 6 VMs del grupo"

# --- Red -----------------------------------------------------------------------
seccion "2. Red"
LINK="$(ip -br link 2>/dev/null || true)"; ADDR="$(ip -br addr 2>/dev/null || true)"; RUTAS="$(ip route 2>/dev/null || true)"
comprobar "lan0 con MAC $MAC_LAN"            "network-config no aplicado o MAC distinta en virt-install" grep -qiE "^lan0 +UP +${MAC_LAN}" <<<"$LINK"
comprobar "lan0 con IP $IP/$PREFIJO_LEN"      "IP o prefijo incorrectos" grep -qE "^lan0 .* ${IP}/${PREFIJO_LEN}( |$)" <<<"$ADDR"
comprobar "mgmt0 con MAC $MAC_MGMT"          "Falta la NIC de gestión" grep -qiE "^mgmt0 +UP +${MAC_MGMT}" <<<"$LINK"
comprobar "mgmt0 con IP $MGMT_VM_IP/$MGMT_LEN" "IP de gestión incorrecta" grep -qE "^mgmt0 .* ${MGMT_VM_IP}/${MGMT_LEN}( |$)" <<<"$ADDR"
comprobar "Ruta por defecto vía $GATEWAY por lan0" "Puerta de enlace incorrecta" grep -qE "^default via ${GATEWAY} dev lan0" <<<"$RUTAS"
N_DEF="$(grep -c '^default' <<<"$RUTAS" || true)"
if [[ "$N_DEF" == "1" ]]; then ok "Una sola ruta por defecto"; else ko "Rutas por defecto: $N_DEF" "mgmt0 no debe tener puerta de enlace"; fi
bloque "ip -br link" <<<"$LINK"
bloque "ip -br addr" <<<"$ADDR"
bloque "ip route" <<<"$RUTAS"

# --- Hora ------------------------------------------------------------------------
seccion "3. Hora (etcd y TLS la necesitan sincronizada)"
SYNC="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)"
TZ_ACT="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
if [[ "$SYNC" == "yes" ]]; then ok "Reloj sincronizado por NTP"; else ko "Reloj NO sincronizado" "Espera 1 min o revisa 'chronyc sources'"; fi
if [[ "$TZ_ACT" == "$ZONA_HORARIA" ]]; then ok "Zona horaria $TZ_ACT"; else aviso "Zona horaria $TZ_ACT (esperada $ZONA_HORARIA)"; fi
FUENTES="$(chronyc -n sources 2>/dev/null || true)"
[[ -n "$FUENTES" ]] && bloque "chronyc sources" <<<"$FUENTES"

# --- cloud-init y paquetes ---------------------------------------------------------
seccion "4. cloud-init y paquetes"
CI="$(cloud-init status 2>/dev/null || true)"
if grep -q 'status: done' <<<"$CI"; then ok "cloud-init terminado (status: done)"
elif grep -q 'running' <<<"$CI"; then aviso "cloud-init aún en ejecución" "Espera y repite el script"
else ko "cloud-init: $(tr '\n' ' ' <<<"$CI")" "Revisa: sudo cloud-init status --long"; fi
for pk in qemu-guest-agent chrony curl; do
  comprobar "Paquete instalado: $pk" "No se instaló: ¿había Internet en el primer arranque?" dpkg -s "$pk"
done
comprobar "Servicio qemu-guest-agent activo" "sudo systemctl status qemu-guest-agent" systemctl is-active --quiet qemu-guest-agent

# --- Internet ------------------------------------------------------------------------
seccion "5. Salida a Internet (orden de diagnóstico)"
comprobar "Ping a la puerta de enlace $GATEWAY" "Fallo de macvtap o de IP"        ping -c2 -W2 "$GATEWAY"
comprobar "Ping a Internet (8.8.8.8)"           "El aula no da salida"             ping -c2 -W2 8.8.8.8
comprobar "DNS: resuelve deb.debian.org"        "Revisa nameservers en network-config" getent hosts deb.debian.org
CODE="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 https://get.rke2.io 2>/dev/null || true)"
if [[ "$CODE" =~ ^[23] ]]; then ok "HTTPS a get.rke2.io (HTTP $CODE)"; else ko "HTTPS a get.rke2.io (HTTP ${CODE:-sin respuesta})" "¿Filtrado de HTTPS o proxy?"; fi

# --- Grupo ---------------------------------------------------------------------------
seccion "6. Nodos del grupo G${GRUPO}"
HOSTS="$(cat /etc/hosts)"
for p in $PUESTOS; do
  n="g${GRUPO}-${p%%:*}"; ipn="$(ip_de "${p%%:*}")"
  comprobar "/etc/hosts: $ipn $n" "write_files de cloud-init no aplicado" grep -qE "^${ipn//./\\.} +${n}\$" <<<"$HOSTS"
done
# Pareja del enunciado: cp1-w1, cp2-w2, cp3-w3 (y todos con cp1)
case "$PUESTO" in cp1) PAREJA=w1;; cp2) PAREJA=w2;; cp3) PAREJA=w3;; w1) PAREJA=cp1;; w2) PAREJA=cp2;; w3) PAREJA=cp3;; esac
for p in $PUESTOS; do
  n="${p%%:*}"; [[ "$n" == "$PUESTO" ]] && continue
  et=""; [[ "$n" == "$PAREJA" ]] && et=" ← pareja del hito"; [[ "$n" == cp1 && "$PUESTO" != cp1 ]] && et="${et:- ← cp1 (obligatorio)}"
  if ping -c2 -W1 "g${GRUPO}-${n}" >/dev/null 2>&1; then ok "Ping a g${GRUPO}-${n}${et}"
  else aviso "g${GRUPO}-${n} no responde todavía${et}" "Normal si esa VM aún no está creada"; fi
done

resumen || true
(( N_KO == 0 ))
}

# Salida en pantalla y copia íntegra (síncrona) en el fichero de evidencia
set +e
main 2>&1 | tee "$EVID.raw"; RC=${PIPESTATUS[0]}
sed 's/\x1b\[[0-9;]*m//g' "$EVID.raw" > "$EVID" && rm -f "$EVID.raw"
echo "  • Evidencia guardada en: $EVID"
exit "$RC"
