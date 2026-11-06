#!/usr/bin/env bash
# Crea (si no existe) la red aislada de gestión k8s-mgmt en qemu:///system.
# Aislada = sin <forward> ni DHCP: solo une el PC con su propia VM.
# Idempotente: si ya existe, solo la arranca y la marca como autoarranque.
set -euo pipefail
export LC_ALL=C   # salidas de virsh en inglés, para que los grep no dependan del idioma
REPO="$(cd "$(dirname "$0")/.." && pwd)"
source "$REPO/grupos/comun.env"
V="virsh -c qemu:///system"

if $V net-info "$MGMT_RED" >/dev/null 2>&1; then
  echo "La red $MGMT_RED ya existe; no se redefine."
else
  XML="$(mktemp)"
  cat > "$XML" <<EOF
<network>
  <name>${MGMT_RED}</name>
  <bridge name='${MGMT_BRIDGE}' stp='on' delay='0'/>
  <ip address='${MGMT_HOST_IP}' prefix='${MGMT_LEN}'/>
</network>
EOF
  $V net-define "$XML"
  rm -f "$XML"
fi
$V net-info "$MGMT_RED" | grep -q 'Active: *yes' || $V net-start "$MGMT_RED"
$V net-autostart "$MGMT_RED"
$V net-dumpxml "$MGMT_RED"
