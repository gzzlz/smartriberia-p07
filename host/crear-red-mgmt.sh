#!/usr/bin/env bash
# Crea (si no existe) la red aislada de gestión en qemu:///system y la valida.
# Aislada = sin <forward> ni DHCP: solo une el PC con su propia VM.
# Idempotente: si ya existe, no la redefine; solo la arranca y comprueba.
set -euo pipefail
export LC_ALL=C   # salidas de virsh en inglés, para que los grep no dependan del idioma
REPO="$(cd "$(dirname "$0")/.." && pwd)"
source "$REPO/lib/ui.sh"
source "$REPO/grupos/comun.env"
V=(virsh -c qemu:///system)

titulo "SmartRiberIA · Red de gestión $MGMT_RED" "Host: $(hostname) · $(date '+%F %T')"

seccion "Parámetros"
dato "Red"     "$MGMT_RED"
dato "Bridge"  "$MGMT_BRIDGE"
dato "IP host" "$MGMT_HOST_IP/$MGMT_LEN"
dato "IP VM"   "${MGMT_PREFIJO}.(10+X)/$MGMT_LEN según el puesto (cp1=.11 … w3=.16)"

seccion "Creación"
if "${V[@]}" net-info "$MGMT_RED" >/dev/null 2>&1; then
  info "La red ya existe: no se redefine"
else
  XML="$(mktemp)"
  cat > "$XML" <<EOF
<network>
  <name>${MGMT_RED}</name>
  <bridge name='${MGMT_BRIDGE}' stp='on' delay='0'/>
  <ip address='${MGMT_HOST_IP}' prefix='${MGMT_LEN}'/>
</network>
EOF
  comprobar "Red definida" "Revisa permisos del grupo libvirt" "${V[@]}" net-define "$XML"
  rm -f "$XML"
fi
# Sin tuberías con grep -q: con pipefail, el SIGPIPE de virsh daría un falso "inactiva"
INFO="$("${V[@]}" net-info "$MGMT_RED" 2>/dev/null || true)"
grep -q '^Active: *yes' <<<"$INFO" || "${V[@]}" net-start "$MGMT_RED" >/dev/null
"${V[@]}" net-autostart "$MGMT_RED" >/dev/null

seccion "Comprobaciones"
XMLV="$("${V[@]}" net-dumpxml "$MGMT_RED" 2>/dev/null || true)"
INFO="$("${V[@]}" net-info "$MGMT_RED" 2>/dev/null || true)"
comprobar "Red activa"             "virsh -c qemu:///system net-start $MGMT_RED" grep -q '^Active: *yes' <<<"$INFO"
comprobar "Autoarranque activado"  "virsh -c qemu:///system net-autostart $MGMT_RED" grep -q '^Autostart: *yes' <<<"$INFO"
comprobar "IP del host $MGMT_HOST_IP/$MGMT_LEN" "La red existente tiene otra IP: revisa el XML" \
  grep -qE "address='${MGMT_HOST_IP}' (prefix='${MGMT_LEN}'|netmask='255.255.255.0')" <<<"$XMLV"
if grep -q '<forward' <<<"$XMLV"; then ko "Red aislada (sin <forward>)" "La red existente reenvía tráfico: no es la esperada"
else ok "Red aislada (sin <forward>)"; fi
if grep -q '<dhcp' <<<"$XMLV"; then aviso "La red tiene DHCP" "No molesta, pero la VM usa IP fija"
else ok "Sin DHCP (la VM usa IP fija)"; fi
comprobar "Bridge $MGMT_BRIDGE presente en el host" "La red no se ha arrancado" ip link show "$MGMT_BRIDGE"

seccion "Definición actual"
bloque "virsh net-dumpxml $MGMT_RED" <<<"$XMLV"

resumen
