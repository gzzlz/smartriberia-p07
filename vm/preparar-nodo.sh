#!/usr/bin/env bash
# Hito 02 (P07): prepara Debian 13 para RKE2 + Cilium. Se ejecuta DENTRO de la VM. Idempotente.
# Uso: bash vm/preparar-nodo.sh <grupo 1|2|3> <puesto cp1|…|w3>
set -euo pipefail
export LC_ALL=C PATH="$PATH:/usr/sbin:/sbin"
GRUPO_ARG="${1:-}"; PUESTO="${2:-}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
source "$REPO/lib/ui.sh"
[[ "$GRUPO_ARG" =~ ^[123]$ && -n "$PUESTO" ]] || { ko "Uso: bash vm/preparar-nodo.sh <1|2|3> <cp1|…|w3>"; exit 1; }
source "$REPO/grupos/comun.env"; source "$REPO/grupos/g${GRUPO_ARG}.env"; source "$REPO/lib/puesto.sh"

titulo "SmartRiberIA · Preparar nodo $NOMBRE para RKE2" "VM: $(hostname) · $(date '+%F %T %Z')"

seccion "1. Es el nodo correcto"
if [[ "$(hostname)" == "$NOMBRE" ]]; then ok "Hostname $NOMBRE"; else ko "Hostname $(hostname) (esperado $NOMBRE)" "¿Grupo o puesto equivocados?"; fi
comprobar "lan0 con IP $IP" "La VM no es la del puesto" bash -c "ip -br addr show lan0 | grep -q ' ${IP}/'"
comprobar "sudo sin contraseña" "El usuario debe tener sudo NOPASSWD (cloud-init)" sudo -n true
parar_si_ko

seccion "2. Módulos del kernel (persistentes)"
printf 'overlay\nbr_netfilter\n' | sudo tee /etc/modules-load.d/90-rke2.conf >/dev/null
for m in overlay br_netfilter; do sudo modprobe "$m" || true; done
MODS="$(lsmod)"
for m in overlay br_netfilter; do comprobar "Módulo $m cargado" "sudo modprobe $m" grep -qw "^$m" <<<"$MODS"; done
comprobar "Se cargan al arrancar (/etc/modules-load.d/90-rke2.conf)" "" test -s /etc/modules-load.d/90-rke2.conf

seccion "3. Parámetros de red del kernel (persistentes)"
sudo tee /etc/sysctl.d/90-rke2.conf >/dev/null <<'EOF'
# SmartRiberIA: requisitos de red para RKE2 + Cilium
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF
sudo sysctl --system >/dev/null 2>&1 || true
for k in net.ipv4.ip_forward net.bridge.bridge-nf-call-iptables net.bridge.bridge-nf-call-ip6tables; do
  v="$(sudo sysctl -n "$k" 2>/dev/null || echo '?')"
  if [[ "$v" == "1" ]]; then ok "$k = 1"; else ko "$k = $v" "Revisa /etc/sysctl.d/90-rke2.conf"; fi
done

seccion "4. systemd-networkd no debe borrar las rutas de Cilium"
# Por defecto networkd elimina rutas, reglas y nexthops que no estén en sus .network (man networkd.conf).
sudo mkdir -p /etc/systemd/networkd.conf.d
NUEVO="$(mktemp)"
cat > "$NUEVO" <<'EOF'
# SmartRiberIA: conservar las rutas y reglas que crea Cilium
[Network]
ManageForeignRoutes=no
ManageForeignRoutingPolicyRules=no
ManageForeignNextHops=no
EOF
if sudo cmp -s "$NUEVO" /etc/systemd/networkd.conf.d/90-cilium.conf 2>/dev/null; then
  info "Configuración de networkd ya aplicada: no se reinicia"
else
  sudo install -m 0644 "$NUEVO" /etc/systemd/networkd.conf.d/90-cilium.conf
  sudo systemctl restart systemd-networkd
  sleep 3
  ok "networkd reiniciado con la configuración nueva"
fi
rm -f "$NUEVO"
comprobar "Drop-in /etc/systemd/networkd.conf.d/90-cilium.conf" "" test -s /etc/systemd/networkd.conf.d/90-cilium.conf
comprobar "lan0 conserva $IP tras el reinicio" "Revisa: networkctl status lan0" bash -c "ip -br addr show lan0 | grep -q ' ${IP}/'"
comprobar "Ruta por defecto vía $GATEWAY" "Revisa: ip route" bash -c "ip route | grep -q '^default via ${GATEWAY} dev lan0'"
comprobar "Ping a la puerta de enlace" "" ping -c2 -W2 "$GATEWAY"

seccion "5. Requisitos que deben cumplirse ya"
SW="$(sudo swapon --show --noheadings 2>/dev/null || true)"
if [[ -z "$SW" ]]; then ok "Sin swap"; else ko "Hay swap activa" "sudo swapoff -a y quítala de /etc/fstab"; fi
comprobar "cgroups v2" "" bash -c "[[ \$(stat -fc %T /sys/fs/cgroup) == cgroup2fs ]]"
SYNC="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)"
if [[ "$SYNC" == yes ]]; then ok "Reloj sincronizado"; else ko "Reloj NO sincronizado" "Espera 1 min; chronyc sources"; fi
UP="$(grep -E '^nameserver' /run/systemd/resolve/resolv.conf 2>/dev/null | grep -v '127\.' || true)"
if [[ -n "$UP" ]]; then ok "DNS real para el kubelet: $(awk '{print $2}' <<<"$UP" | tr '\n' ' ')(/run/systemd/resolve/resolv.conf)"
else ko "Sin DNS real en /run/systemd/resolve/resolv.conf" "CoreDNS haría bucle con 127.0.0.53"; fi
comprobar "Kernel >= 5.10 (recomendado por Cilium): $(uname -r)" "" bash -c "printf '5.10\n%s\n' \$(uname -r | cut -d- -f1) | sort -V -C"
LIBRE=$(( $(df -Pk / | awk 'NR==2 {print $4}') / 1024 / 1024 ))
if (( LIBRE >= 20 )); then ok "Disco libre: ${LIBRE} GiB"; else ko "Disco libre: ${LIBRE} GiB" "RKE2 e imágenes necesitan espacio"; fi
if [[ -d /var/lib/rancher/rke2 ]]; then aviso "Ya existe /var/lib/rancher/rke2" "RKE2 instalado antes: instalar-rke2.sh lo detectará"
else ok "Sin restos de RKE2"; fi

seccion "6. Puertos que usará el nodo (deben estar libres)"
ESC="$(sudo ss -Htln 2>/dev/null | awk '{print $4}')"
for pt in 6443 9345 2379 2380 10250; do
  if grep -qE "[:.]${pt}\$" <<<"$ESC"; then
    if [[ -d /var/lib/rancher/rke2 ]]; then info "Puerto $pt en uso (RKE2 ya en marcha)"; else ko "Puerto $pt ocupado" "Otro proceso lo usa"; fi
  else ok "Puerto $pt libre"; fi
done

resumen
