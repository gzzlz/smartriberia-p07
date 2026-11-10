#!/usr/bin/env bash
# Hito 02 (P07): instala RKE2 en el nodo según su rol (server-init, server o agent). DENTRO de la VM.
# Uso: bash vm/instalar-rke2.sh <grupo 1|2|3> <puesto cp1|…|w3> [--dry-run]
#   --dry-run  comprueba y muestra el config.yaml y el HelmChartConfig sin instalar nada.
set -euo pipefail
export LC_ALL=C PATH="$PATH:/usr/sbin:/sbin:/usr/local/bin:/var/lib/rancher/rke2/bin"
GRUPO_ARG="${1:-}"; PUESTO="${2:-}"; DRY="${3:-}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
source "$REPO/lib/ui.sh"
[[ "$GRUPO_ARG" =~ ^[123]$ && -n "$PUESTO" ]] || { ko "Uso: bash vm/instalar-rke2.sh <1|2|3> <cp1|…|w3> [--dry-run]"; exit 1; }
source "$REPO/grupos/comun.env"; source "$REPO/grupos/g${GRUPO_ARG}.env"; source "$REPO/lib/puesto.sh"
ART="$HOME/rke2-artefactos/$RKE2_VERSION"
TOKEN_F="$HOME/.smartriberia/token"
TIPO=server; [[ "$ROL" == agent ]] && TIPO=agent
MODO="INSTALACIÓN"; [[ "$DRY" == "--dry-run" ]] && MODO="SIMULACIÓN (--dry-run, no se instala nada)"

titulo "SmartRiberIA · RKE2 en $NOMBRE" "Modo: $MODO · VM: $(hostname) · $(date '+%F %T %Z')"

seccion "Parámetros"
dato "Nodo"            "$NOMBRE ($IP)"
dato "Rol"             "$ROL  →  servicio rke2-$TIPO"
dato "Versión"         "$RKE2_VERSION"
dato "Registro"        "$( [[ "$ROL" == server-init ]] && echo "este nodo crea el clúster" || echo "https://$SERVIDOR_REG:9345 ($SERVIDOR_REG_IP)")"
[[ "$TIPO" == server ]] && dato "Pods / servicios" "$POD_CIDR / $SVC_CIDR (DNS $CLUSTER_DNS)"
[[ "$TIPO" == server ]] && dato "Cilium" "clúster $CILIUM_CLUSTER_NAME (id $CILIUM_CLUSTER_ID) · interfaz lan0 · Hubble"

# --- 1. Comprobaciones ---------------------------------------------------------
seccion "1. Comprobaciones previas"
[[ -n "$ROL" ]] && ok "Rol de $PUESTO: $ROL" || ko "El puesto $PUESTO no tiene rol en ROLES (comun.env)"
if [[ "$(hostname)" == "$NOMBRE" ]]; then ok "Hostname $NOMBRE"; else ko "Hostname $(hostname) (esperado $NOMBRE)"; fi
comprobar "Nodo preparado (vm/preparar-nodo.sh)" "Ejecuta antes: bash vm/preparar-nodo.sh $GRUPO $PUESTO" \
  bash -c "test -s /etc/sysctl.d/90-rke2.conf && test -s /etc/systemd/networkd.conf.d/90-cilium.conf && [[ \$(/usr/sbin/sysctl -n net.ipv4.ip_forward) == 1 ]]"
for f in $RKE2_ARTEFACTOS install.sh; do comprobar "Artefacto: $f" "Desde el host: host/descargar-rke2.sh y host/enviar-a-vm.sh $GRUPO $PUESTO" test -s "$ART/$f"; done
comprobar "SHA-256 de los artefactos" "Repite host/enviar-a-vm.sh" bash -c \
  "cd '$ART' && grep -E ' (rke2\\.linux-amd64\\.tar\\.gz|rke2-images-(core|cilium)\\.linux-amd64\\.tar\\.zst)\$' sha256sum-amd64.txt | sha256sum -c --quiet -"
comprobar "Token del grupo (~/.smartriberia/token)" "El piloto lo genera (host/crear-token.sh) y se envía con host/enviar-a-vm.sh" \
  bash -c "grep -qxE '[0-9a-f]{64}' '$TOKEN_F'"
if [[ "$ROL" != server-init ]]; then
  comprobar "Servidor de registro $SERVIDOR_REG_IP:9345 accesible" "¿Está instalado y en marcha RKE2 en $SERVIDOR_REG?" \
    timeout 3 bash -c "</dev/tcp/$SERVIDOR_REG_IP/9345"
fi
YA=no
if systemctl list-unit-files "rke2-$TIPO.service" >/dev/null 2>&1 && [[ -e /usr/local/bin/rke2 ]]; then YA=si; fi
if [[ "$YA" == si ]]; then ko "RKE2 no está instalado ya" "Ya instalado: usa vm/comprobar-hito02.sh, o desinstala con /usr/local/bin/rke2-uninstall.sh"
else ok "RKE2 no está instalado ya"; fi
parar_si_ko

# --- 2. Generar configuración ----------------------------------------------------
seccion "2. Configuración generada"
TOKEN="$(cat "$TOKEN_F")"
CFG="$(mktemp)"; HCC="$(mktemp)"
{
  echo "# /etc/rancher/rke2/config.yaml · generado por vm/instalar-rke2.sh"
  echo "# Repositorio: $(cat "$REPO/.version" 2>/dev/null || echo '?') · nodo $NOMBRE · rol $ROL"
  echo "token: \"$TOKEN\""
  [[ "$ROL" != server-init ]] && echo "server: https://${SERVIDOR_REG}:9345"
  echo "node-name: $NOMBRE"
  echo "node-ip: $IP"
  if [[ "$TIPO" == server ]]; then
    echo "advertise-address: $IP"
    echo "tls-san:"; for s in $TLS_SAN; do echo "  - $s"; done
    echo "cni: cilium"
    echo "cluster-cidr: $POD_CIDR"
    echo "service-cidr: $SVC_CIDR"
    echo "cluster-dns: $CLUSTER_DNS"
    echo "write-kubeconfig-mode: \"0600\""
  fi
  echo "kubelet-arg:"
  echo "  - \"resolv-conf=/run/systemd/resolve/resolv.conf\""
  echo "  - \"kube-reserved=$KUBE_RESERVED\""
  echo "  - \"system-reserved=$SYSTEM_RESERVED\""
  echo "node-label:"
  echo "  - \"smartriberia/grupo=g$GRUPO\""
  echo "  - \"smartriberia/puesto=$PUESTO\""
} > "$CFG"
cat > "$HCC" <<EOF
# /var/lib/rancher/rke2/server/manifests/rke2-cilium-config.yaml · generado por vm/instalar-rke2.sh
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: rke2-cilium
  namespace: kube-system
spec:
  valuesContent: |-
    cluster:
      name: ${CILIUM_CLUSTER_NAME}
      id: ${CILIUM_CLUSTER_ID}
    devices: lan0
    hubble:
      enabled: true
      relay:
        enabled: true
      ui:
        enabled: true
EOF
comprobar "config.yaml generado" "" test -s "$CFG"
comprobar "config.yaml: node-ip = $IP" "" grep -qx "node-ip: $IP" "$CFG"
if [[ "$TIPO" == server ]]; then
  comprobar "config.yaml: cni cilium y CIDR del grupo" "Revisa grupos/g$GRUPO.env" \
    bash -c "grep -qx 'cni: cilium' '$CFG' && grep -qx 'cluster-cidr: $POD_CIDR' '$CFG' && grep -qx 'service-cidr: $SVC_CIDR' '$CFG'"
fi
if python3 -c "import yaml" >/dev/null 2>&1; then
  comprobar "YAML válido: config.yaml" "" python3 -c "import yaml,sys; yaml.safe_load(open(sys.argv[1]))" "$CFG"
  [[ "$TIPO" == server ]] && comprobar "YAML válido: HelmChartConfig (y sus valores de Cilium)" "" \
    python3 -c "import yaml,sys; d=yaml.safe_load(open(sys.argv[1])); v=yaml.safe_load(d['spec']['valuesContent']); assert v['devices']=='lan0' and v['cluster']['id']==int(sys.argv[2])" "$HCC" "$CILIUM_CLUSTER_ID"
else
  aviso "No se valida el YAML" "python3-yaml no instalado en la VM"
fi
sed -E 's/^(token: ").*(")$/\1****** (oculto)\2/' "$CFG" | bloque "config.yaml (token oculto)"
[[ "$TIPO" == server ]] && bloque "rke2-cilium-config.yaml" < "$HCC"
parar_si_ko

if [[ "$DRY" == "--dry-run" ]]; then
  rm -f "$CFG" "$HCC"
  resumen && printf '%sListo para instalar: repite sin --dry-run.%s\n' "$C_G" "$C_0"
  exit $?
fi

# --- 3. Instalación --------------------------------------------------------------
seccion "3. Instalación desde los artefactos (air-gap)"
sudo install -d -m 0700 /etc/rancher/rke2
sudo install -m 0600 "$CFG" /etc/rancher/rke2/config.yaml && ok "config.yaml instalado (permisos 600)"
if [[ "$TIPO" == server ]]; then
  sudo install -d /var/lib/rancher/rke2/server/manifests
  sudo install -m 0600 "$HCC" /var/lib/rancher/rke2/server/manifests/rke2-cilium-config.yaml && ok "HelmChartConfig de Cilium instalado"
fi
rm -f "$CFG" "$HCC"; unset TOKEN
sudo install -d /var/lib/rancher/rke2/agent/images
for img in rke2-images-core.linux-amd64.tar.zst rke2-images-cilium.linux-amd64.tar.zst; do
  sudo install -m 0644 "$ART/$img" /var/lib/rancher/rke2/agent/images/ && ok "Imágenes $img en /var/lib/rancher/rke2/agent/images"
done
if sudo env INSTALL_RKE2_ARTIFACT_PATH="$ART" INSTALL_RKE2_TYPE="$TIPO" sh "$ART/install.sh" >"$HOME/rke2-install.log" 2>&1; then
  ok "install.sh ejecutado (log en ~/rke2-install.log)"
else
  ko "install.sh ha fallado" "Mira ~/rke2-install.log"; resumen || true; exit 1
fi
comprobar "Binario rke2 versión $RKE2_VERSION" "Versión instalada distinta" bash -c "/usr/local/bin/rke2 --version | grep -qF '${RKE2_VERSION}'"

seccion "4. Arranque de rke2-$TIPO (el primer arranque tarda varios minutos)"
sudo systemctl enable "rke2-$TIPO.service" >/dev/null 2>&1 && ok "Servicio habilitado al arranque"
info "Arrancando… (si pasa de 10 min, revisa: sudo journalctl -u rke2-$TIPO -f)"
if sudo timeout 900 systemctl start "rke2-$TIPO.service"; then ok "rke2-$TIPO arrancado"
else ko "rke2-$TIPO no arrancó" "sudo journalctl -u rke2-$TIPO --no-pager | tail -50"; resumen || true; exit 1; fi
comprobar "rke2-$TIPO activo" "" systemctl is-active --quiet "rke2-$TIPO"

if [[ "$TIPO" == server ]]; then
  seccion "5. kubectl para el usuario $USER"
  install -d -m 0700 "$HOME/.kube"
  sudo install -m 0600 -o "$USER" -g "$(id -gn)" /etc/rancher/rke2/rke2.yaml "$HOME/.kube/config" && ok "~/.kube/config (permisos 600)"
  grep -q '/var/lib/rancher/rke2/bin' "$HOME/.bashrc" || echo 'export PATH="$PATH:/var/lib/rancher/rke2/bin"' >> "$HOME/.bashrc"
  ok "kubectl en el PATH (abre una sesión nueva o: source ~/.bashrc)"
  info "Esperando a que el nodo esté Ready (máx. 10 min)…"
  if kubectl --kubeconfig "$HOME/.kube/config" wait --for=condition=Ready "node/$NOMBRE" --timeout=600s >/dev/null 2>&1; then ok "Nodo $NOMBRE Ready"
  else ko "Nodo $NOMBRE no está Ready" "kubectl get pods -A ; kubectl describe node $NOMBRE"; fi
fi

if resumen; then info "Siguiente: ${C_N}bash ~/repo/vm/comprobar-hito02.sh $GRUPO $PUESTO${C_0}"; else exit 1; fi
