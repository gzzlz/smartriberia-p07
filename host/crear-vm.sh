#!/usr/bin/env bash
# Crea la VM de un puesto a partir de la imagen base fijada, validando todo antes.
# Uso:  host/crear-vm.sh <grupo 1|2|3> <puesto cp1|cp2|cp3|w1|w2|w3> [--dry-run]
#   --dry-run  valida, genera la semilla y muestra el comando sin crear la VM.
# Si alguna comprobación previa da KO, el script se detiene sin modificar nada.
set -euo pipefail
export LC_ALL=C

GRUPO_ARG="${1:-}"; PUESTO="${2:-}"; DRY="${3:-}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
SR_HOME="${SR_HOME:-$HOME/smartriberia}"     # imágenes y discos (fuera del repo)
source "$REPO/lib/ui.sh"

if [[ ! "$GRUPO_ARG" =~ ^[123]$ || -z "$PUESTO" ]]; then
  ko "Uso: host/crear-vm.sh <1|2|3> <cp1|cp2|cp3|w1|w2|w3> [--dry-run]"; exit 1
fi
source "$REPO/grupos/comun.env"
source "$REPO/grupos/g${GRUPO_ARG}.env"
V=(virsh -c qemu:///system)

# --- Derivar todo del grupo y del puesto -----------------------------------
X=""
for p in $PUESTOS; do [[ "${p%%:*}" == "$PUESTO" ]] && X="${p##*:}"; done
NOMBRE="g${GRUPO}-${PUESTO}"
IP="${RED_PREFIJO}.$((10 + ${X:-0}))"
MAC_LAN="52:54:00:00:0${GRUPO}:0${X}"
MAC_MGMT="52:54:00:00:0${GRUPO}:1${X}"
IFACE="$(ip route show default | awk '{print $5; exit}')"
BASE="$SR_HOME/imagenes/$IMAGEN"
DISCO="$SR_HOME/vms/${NOMBRE}.qcow2"
SEMILLA_DIR="$SR_HOME/vms/${NOMBRE}-seed"
SEMILLA_ISO="$SR_HOME/vms/${NOMBRE}-seed.iso"
MODO="CREACIÓN"; [[ "$DRY" == "--dry-run" ]] && MODO="SIMULACIÓN (--dry-run, no se crea nada)"

titulo "SmartRiberIA · Crear VM $NOMBRE" "Modo: $MODO · Host: $(hostname) · $(date '+%F %T')"

seccion "Parámetros del puesto"
dato "Grupo / puesto"   "G${GRUPO} / ${PUESTO} (X=${X:-?})"
dato "Hostname"         "$NOMBRE"
dato "IP aula"          "$IP/$PREFIJO_LEN  →  gw $GATEWAY · dns $DNS"
dato "MAC aula"         "$MAC_LAN  (macvtap sobre ${IFACE:-?})"
dato "IP / MAC gestión" "$MGMT_VM_IP/$MGMT_LEN  /  $MAC_MGMT  (red $MGMT_RED)"
dato "Recursos"         "$VCPU vCPU · $((RAM_MB / 1024)) GiB RAM · ${DISCO_GB} GiB disco"
dato "Imagen base"      "$IMAGEN"
dato "Disco"            "$DISCO"

# --- 1. Comprobaciones previas (no modifican nada) --------------------------
seccion "1. Puesto y herramientas"
if [[ -n "$X" ]]; then ok "Puesto '$PUESTO' válido (X=$X)"; else ko "Puesto '$PUESTO' desconocido" "Usa cp1, cp2, cp3, w1, w2 o w3"; fi
for h in virsh virt-install qemu-img xorrisofs openssl sha512sum; do
  comprobar "Herramienta: $h" "No está instalada en este host" command -v "$h"
done

seccion "2. Recursos del host"
MEM_LIBRE_MB=$(( $(awk '/^MemAvailable:/ {print $2}' /proc/meminfo) / 1024 ))
if (( MEM_LIBRE_MB >= RAM_MB )); then ok "RAM disponible: $((MEM_LIBRE_MB / 1024)) GiB (necesita $((RAM_MB / 1024)))"
else ko "RAM disponible: $((MEM_LIBRE_MB / 1024)) GiB (necesita $((RAM_MB / 1024)))" "Apaga otras VMs o aplicaciones"; fi
if (( $(nproc) >= VCPU )); then ok "CPUs del host: $(nproc) (necesita $VCPU)"
else ko "CPUs del host: $(nproc) (necesita $VCPU)"; fi
mkdir -p "$SR_HOME/vms"
LIBRE_GB=$(( $(df -Pk "$SR_HOME/vms" | awk 'NR==2 {print $4}') / 1024 / 1024 ))
if (( LIBRE_GB >= DISCO_GB )); then ok "Espacio libre en $(df -P "$SR_HOME/vms" | awk 'NR==2 {print $6}'): ${LIBRE_GB} GiB (máx. del disco ${DISCO_GB})"
else ko "Espacio libre: ${LIBRE_GB} GiB (el disco puede crecer hasta ${DISCO_GB})" "Libera espacio o usa otra partición (SR_HOME)"; fi

seccion "3. Imagen base"
comprobar "Imagen presente" "Descárgala (paso 2) en $SR_HOME/imagenes" test -f "$BASE"
comprobar "SHA512 coincide con el oficial" "Descarga corrupta o build distinta a la fijada" \
  bash -c "cd '$SR_HOME/imagenes' && grep ' ${IMAGEN}\$' SHA512SUMS | sha512sum -c --quiet -"

seccion "4. Red"
# Nota: nada de "cmd | grep -q" en el shell principal (pipefail + SIGPIPE = falso KO)
LINK="$(ip link show "$IFACE" 2>/dev/null || true)"
if [[ -n "$IFACE" ]] && grep -q 'state UP' <<<"$LINK"; then ok "Interfaz física $IFACE activa (ruta por defecto)"
else ko "Interfaz física no detectada o caída" "Comprueba el cable y 'ip route'"; fi
comprobar "Red $MGMT_RED creada y activa" "Ejecuta host/crear-red-mgmt.sh" \
  bash -c "${V[*]} net-info $MGMT_RED | grep -q '^Active: *yes'"

seccion "5. Unicidad (evita conflictos entre puestos y grupos)"
if "${V[@]}" dominfo "$NOMBRE" >/dev/null 2>&1; then ko "No existe otra VM '$NOMBRE'" "Ya existe: bórrala solo si es desechable"
else ok "No existe otra VM '$NOMBRE'"; fi
if [[ -e "$DISCO" ]]; then ko "No existe el disco $(basename "$DISCO")" "Ya hay un disco con ese nombre: no se sobrescribe"
else ok "No existe el disco $(basename "$DISCO")"; fi
MACS_HOST="$(for d in $("${V[@]}" list --all --name); do "${V[@]}" dumpxml "$d" | grep -oi "mac address='[^']*'"; done 2>/dev/null || true)"
for m in "$MAC_LAN" "$MAC_MGMT"; do
  if grep -qi "$m" <<<"$MACS_HOST"; then ko "MAC $m libre en este host" "Otra VM la usa: revisa grupo y puesto"
  else ok "MAC $m libre en este host"; fi
done
ping -c1 -W1 "$IP" >/dev/null 2>&1 || true
VECINO="$(ip neigh show "$IP" 2>/dev/null || true)"
if grep -q lladdr <<<"$VECINO"; then ko "IP $IP libre en la LAN" "Otro equipo responde con esa IP: ¿grupo o puesto equivocado?"
else ok "IP $IP libre en la LAN"; fi

parar_si_ko

# --- 2. Contraseña (fuera del repo, chmod 600) ------------------------------
seccion "6. Credenciales"
SECRETO="$SR_HOME/secreto.env"
if [[ ! -f "$SECRETO" ]]; then
  read -rsp "  Contraseña para el usuario $USUARIO_VM de la VM: " P1; echo
  read -rsp "  Repítela: " P2; echo
  if [[ "$P1" != "$P2" || -z "$P1" ]]; then ko "Contraseña" "No coinciden o está vacía"; exit 1; fi
  ( umask 077; echo "HASH_PASS='$(openssl passwd -6 "$P1")'" > "$SECRETO" )
  unset P1 P2
  ok "Hash de la contraseña guardado en $SECRETO (permisos 600)"
else
  ok "Se reutiliza el hash de $SECRETO"
fi
source "$SECRETO"
CLAVE_SSH=""
if [[ -f "$HOME/.ssh/id_ed25519.pub" ]]; then CLAVE_SSH="$(cat "$HOME/.ssh/id_ed25519.pub")"; ok "Clave SSH pública añadida (~/.ssh/id_ed25519.pub)"
else aviso "Sin clave SSH en ~/.ssh/id_ed25519.pub" "Solo entrarás con contraseña (opcional: ssh-keygen -t ed25519)"; fi

# --- 3. Semilla cloud-init (NoCloud) -----------------------------------------
seccion "7. Semilla cloud-init"
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

for f in user-data meta-data network-config; do
  comprobar "Fichero $f generado" "" test -s "$SEMILLA_DIR/$f"
done
PY=""
for c in /usr/bin/python3 python3; do "$c" -c "import yaml" >/dev/null 2>&1 && { PY="$c"; break; }; done
if [[ -n "$PY" ]]; then
  for f in user-data meta-data network-config; do
    comprobar "YAML válido: $f" "Error de sintaxis en la semilla" \
      "$PY" -c "import yaml,sys; yaml.safe_load(open(sys.argv[1]))" "$SEMILLA_DIR/$f"
  done
else
  aviso "No se valida el YAML" "python3 sin el módulo yaml en este host"
fi
comprobar "user-data empieza por #cloud-config" "cloud-init lo ignoraría" \
  bash -c "head -1 '$SEMILLA_DIR/user-data' | grep -qx '#cloud-config'"
comprobar "network-config con IP $IP y MAC $MAC_LAN" "Semilla incoherente con grupo/puesto" \
  bash -c "grep -q '${IP}/${PREFIJO_LEN}' '$SEMILLA_DIR/network-config' && grep -qi '${MAC_LAN}' '$SEMILLA_DIR/network-config'"
rm -f "$SEMILLA_ISO"
comprobar "ISO de semilla creada" "xorrisofs ha fallado" \
  xorrisofs -quiet -output "$SEMILLA_ISO" -volid cidata -joliet -rock \
  "$SEMILLA_DIR/user-data" "$SEMILLA_DIR/meta-data" "$SEMILLA_DIR/network-config"
comprobar "ISO con etiqueta 'cidata' (la que busca cloud-init)" "Etiqueta de volumen incorrecta" \
  bash -c "xorriso -indev '$SEMILLA_ISO' -pvd_info 2>/dev/null | grep -q 'Volume Id *: cidata'"

parar_si_ko

# --- 4. Comando virt-install ---------------------------------------------------
OSV=linux2022
OSLIST="$(virt-install --osinfo list 2>/dev/null || true)"
for v in debian13 debian12; do
  grep -qw "$v" <<<"$OSLIST" && { OSV="$v"; break; }
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
  seccion "Ficheros generados"
  bloque "user-data"      < "$SEMILLA_DIR/user-data"
  bloque "network-config" < "$SEMILLA_DIR/network-config"
  seccion "Comando que se ejecutaría (variante de SO: $OSV)"
  { printf '%s ' "${CMD[@]}"; echo; } | sed 's/ --/ \\\n  --/g' | bloque "virt-install"
  resumen && printf '%sListo para crear: repite el comando sin --dry-run.%s\n' "$C_G" "$C_0"
  exit $?
fi

# --- 5. Creación ---------------------------------------------------------------
seccion "8. Disco y VM"
comprobar "Copia independiente de la imagen base (sin backing file)" "qemu-img convert ha fallado" \
  qemu-img convert -O qcow2 "$BASE" "$DISCO"
comprobar "Disco ampliado a ${DISCO_GB} GiB" "qemu-img resize ha fallado" \
  qemu-img resize "$DISCO" "${DISCO_GB}G"
comprobar "Disco sin backing file" "El disco depende de la base" \
  bash -c "! qemu-img info '$DISCO' | grep -q 'backing file'"
parar_si_ko
if "${CMD[@]}" >"$SEMILLA_DIR/virt-install.log" 2>&1; then ok "virt-install ejecutado"
else ko "virt-install ha fallado" "Mira $SEMILLA_DIR/virt-install.log"; fi
sleep 3
comprobar "VM $NOMBRE en estado 'running'" "virsh -c qemu:///system domstate $NOMBRE" \
  bash -c "${V[*]} domstate $NOMBRE | grep -q running"

if resumen; then
  info "Consola: ${C_N}virt-viewer -c qemu:///system $NOMBRE${C_0}  (o virt-manager)"
  info "cloud-init tarda 1-2 min en el primer arranque (paquetes y red)"
  info "SSH desde este PC: ${C_N}ssh $USUARIO_VM@$MGMT_VM_IP${C_0}  (red de gestión)"
else
  exit 1
fi
