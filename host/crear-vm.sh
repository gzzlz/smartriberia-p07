#!/usr/bin/env bash
# Crea la VM de un puesto a partir de la imagen base fijada.
# Uso:  host/crear-vm.sh <grupo 1|2|3> <puesto cp1|cp2|cp3|w1|w2|w3> [--dry-run]
#   --dry-run  genera semilla y muestra el comando virt-install sin crear nada.
# Requisitos: imagen descargada y verificada en ~/smartriberia/imagenes,
#             red k8s-mgmt creada (host/crear-red-mgmt.sh).
set -euo pipefail
export LC_ALL=C

GRUPO_ARG="${1:?Falta el grupo (1, 2 o 3)}"
PUESTO="${2:?Falta el puesto (cp1, cp2, cp3, w1, w2 o w3)}"
DRY="${3:-}"

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SR_HOME="${SR_HOME:-$HOME/smartriberia}"     # imágenes y discos (fuera del repo)
source "$REPO/grupos/comun.env"
source "$REPO/grupos/g${GRUPO_ARG}.env"

# --- Derivar todo del grupo y del puesto -----------------------------------
X=""
for p in $PUESTOS; do [[ "${p%%:*}" == "$PUESTO" ]] && X="${p##*:}"; done
[[ -n "$X" ]] || { echo "Puesto desconocido: $PUESTO"; exit 1; }

NOMBRE="g${GRUPO}-${PUESTO}"
IP="${RED_PREFIJO}.$((10 + X))"
MAC_LAN="52:54:00:00:0${GRUPO}:0${X}"
MAC_MGMT="52:54:00:00:0${GRUPO}:1${X}"
IFACE="$(ip route show default | awk '{print $5; exit}')"
BASE="$SR_HOME/imagenes/$IMAGEN"
DISCO="$SR_HOME/vms/${NOMBRE}.qcow2"
SEMILLA_DIR="$SR_HOME/vms/${NOMBRE}-seed"
SEMILLA_ISO="$SR_HOME/vms/${NOMBRE}-seed.iso"

echo "== $NOMBRE | IP $IP/$PREFIJO_LEN | MAC $MAC_LAN (macvtap sobre $IFACE) | gestión $MGMT_VM_IP ($MAC_MGMT)"

# --- Comprobaciones previas -----------------------------------------------
[[ -f "$BASE" ]] || { echo "No está la imagen base: $BASE"; exit 1; }
( cd "$SR_HOME/imagenes" && grep " ${IMAGEN}\$" SHA512SUMS | sha512sum -c --quiet - ) \
  || { echo "La imagen base no coincide con SHA512SUMS"; exit 1; }
virsh -c qemu:///system net-info "$MGMT_RED" >/dev/null 2>&1 \
  || { echo "Falta la red $MGMT_RED: ejecuta host/crear-red-mgmt.sh"; exit 1; }
if virsh -c qemu:///system dominfo "$NOMBRE" >/dev/null 2>&1; then
  echo "Ya existe una VM llamada $NOMBRE; no se toca."; exit 1
fi

# --- Contraseña del usuario (fuera del repo, chmod 600) --------------------
SECRETO="$SR_HOME/secreto.env"
if [[ ! -f "$SECRETO" ]]; then
  read -rsp "Contraseña para el usuario $USUARIO_VM de la VM: " P1; echo
  read -rsp "Repítela: " P2; echo
  [[ "$P1" == "$P2" && -n "$P1" ]] || { echo "No coinciden o vacía"; exit 1; }
  umask 077; echo "HASH_PASS='$(openssl passwd -6 "$P1")'" > "$SECRETO"
  unset P1 P2
fi
source "$SECRETO"
CLAVE_SSH=""
[[ -f "$HOME/.ssh/id_ed25519.pub" ]] && CLAVE_SSH="$(cat "$HOME/.ssh/id_ed25519.pub")"

# --- Semilla cloud-init (NoCloud) ------------------------------------------
mkdir -p "$SEMILLA_DIR"

cat > "$SEMILLA_DIR/meta-data" <<EOF
instance-id: ${NOMBRE}-${DEBIAN_BUILD}
local-hostname: ${NOMBRE}
EOF

# /etc/hosts con los 6 nodos del grupo (no hay DNS interno en el aula)
HOSTS=""
for p in $PUESTOS; do
  n="${p%%:*}"; x="${p##*:}"
  HOSTS+="      ${RED_PREFIJO}.$((10 + x)) g${GRUPO}-${n}"$'\n'
done

cat > "$SEMILLA_DIR/user-data" <<EOF
#cloud-config
hostname: ${NOMBRE}
fqdn: ${NOMBRE}
manage_etc_hosts: false
timezone: ${ZONA_HORARIA}
users:
  - name: ${USUARIO_VM}
    groups: [sudo]
    shell: /bin/bash
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    lock_passwd: false
    passwd: '${HASH_PASS}'
$( [[ -n "$CLAVE_SSH" ]] && printf '    ssh_authorized_keys:\n      - %s\n' "$CLAVE_SSH" )
ssh_pwauth: true
ntp:
  enabled: true
  servers: [${NTP}]
package_update: true
packages: [qemu-guest-agent, curl, chrony]
write_files:
  - path: /etc/hosts
    owner: root:root
    permissions: '0644'
    content: |
      127.0.0.1 localhost
      ::1 localhost ip6-localhost ip6-loopback
${HOSTS}
runcmd:
  - [systemctl, enable, --now, qemu-guest-agent]
EOF

cat > "$SEMILLA_DIR/network-config" <<EOF
version: 2
ethernets:
  lan0:
    match:
      macaddress: "${MAC_LAN}"
    set-name: lan0
    addresses: [${IP}/${PREFIJO_LEN}]
    routes:
      - to: default
        via: ${GATEWAY}
    nameservers:
      addresses: [${DNS}]
  mgmt0:
    match:
      macaddress: "${MAC_MGMT}"
    set-name: mgmt0
    addresses: [${MGMT_VM_IP}/${MGMT_LEN}]
EOF

xorrisofs -quiet -output "$SEMILLA_ISO" -volid cidata -joliet -rock \
  "$SEMILLA_DIR/user-data" "$SEMILLA_DIR/meta-data" "$SEMILLA_DIR/network-config"

# --- Variante de SO que conoce este virt-install ---------------------------
OSV=linux2022
for v in debian13 debian12; do
  virt-install --osinfo list 2>/dev/null | grep -qw "$v" && { OSV="$v"; break; }
done

CMD=(virt-install --connect qemu:///system
  --name "$NOMBRE" --memory "$RAM_MB" --vcpus "$VCPU" --cpu host-passthrough
  --osinfo "$OSV" --import
  --disk "path=$DISCO,format=qcow2,bus=virtio"
  --disk "path=$SEMILLA_ISO,device=cdrom,readonly=on"
  --network "type=direct,source=$IFACE,source_mode=bridge,mac=$MAC_LAN,model=virtio"
  --network "network=$MGMT_RED,mac=$MAC_MGMT,model=virtio"
  --graphics spice --video virtio --channel spicevmc
  --noautoconsole)

if [[ "$DRY" == "--dry-run" ]]; then
  echo "--- user-data";      cat "$SEMILLA_DIR/user-data"
  echo "--- network-config"; cat "$SEMILLA_DIR/network-config"
  echo "--- comando (no se ejecuta)"; printf '%q ' "${CMD[@]}"; echo
  exit 0
fi

# --- Disco: copia INDEPENDIENTE de la base (sin backing file) y ampliación --
qemu-img convert -O qcow2 "$BASE" "$DISCO"
qemu-img resize "$DISCO" "${DISCO_GB}G"

"${CMD[@]}"
echo "VM $NOMBRE creada. Consola: virt-manager o 'virt-viewer -c qemu:///system $NOMBRE'"
