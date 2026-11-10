#!/usr/bin/env bash
# Hito 02 (P07): primer servidor RKE2 + Cilium. Se ejecuta DENTRO de la VM del servidor.
# Uso: bash vm/comprobar-hito02.sh <grupo 1|2|3> <puesto>   (en este hito: cp1)
# Evidencia (sin colores): ~/evidencias/hito02_<vm>_<fecha>.txt
set -euo pipefail
export LC_ALL=C PATH="$PATH:/usr/sbin:/sbin:/usr/local/bin:/var/lib/rancher/rke2/bin"
GRUPO_ARG="${1:-}"; PUESTO="${2:-}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
[[ "$GRUPO_ARG" =~ ^[123]$ && -n "$PUESTO" ]] || { echo "Uso: bash vm/comprobar-hito02.sh <1|2|3> <cp1|…>"; exit 1; }
source "$REPO/grupos/comun.env"; source "$REPO/grupos/g${GRUPO_ARG}.env"; source "$REPO/lib/puesto.sh"
[[ -n "$X" ]] || { echo "Puesto desconocido: $PUESTO"; exit 1; }
mkdir -p "$HOME/evidencias"
EVID="$HOME/evidencias/hito02_${NOMBRE}_$(date +%Y%m%d_%H%M%S).txt"
[[ -t 1 ]] && export FORCE_COLOR=1
K=(kubectl --kubeconfig "$HOME/.kube/config")

main() {
source "$REPO/lib/ui.sh"
titulo "SmartRiberIA · Hito 02 · $NOMBRE" "VM: $(hostname) · $(date '+%F %T %Z') · repo $(cat "$REPO/.version" 2>/dev/null || echo '?')"

seccion "1. RKE2"
comprobar "Servicio rke2-server activo" "sudo journalctl -u rke2-server --no-pager | tail -50" systemctl is-active --quiet rke2-server
VER="$(/usr/local/bin/rke2 --version 2>/dev/null | head -1 || true)"
if grep -qF "$RKE2_VERSION" <<<"$VER"; then ok "Versión fijada: $RKE2_VERSION"; else ko "Versión: ${VER:-desconocida} (esperada $RKE2_VERSION)"; fi
comprobar "kubectl con acceso al API" "¿Existe ~/.kube/config?" "${K[@]}" get --raw=/readyz
CFGS="$(sudo cat /etc/rancher/rke2/config.yaml 2>/dev/null || true)"
for l in "node-ip: $IP" "cni: cilium" "cluster-cidr: $POD_CIDR" "service-cidr: $SVC_CIDR"; do
  comprobar "config.yaml contiene '$l'" "" grep -qx "$l" <<<"$CFGS"
done
comprobar "config.yaml con permisos 600 (lleva el token)" "" bash -c "[[ \$(sudo stat -c %a /etc/rancher/rke2/config.yaml) == 600 ]]"

seccion "2. Nodo"
NODOS="$("${K[@]}" get nodes -o wide 2>/dev/null || true)"
bloque "kubectl get nodes -o wide" <<<"$NODOS"
LISTO="$("${K[@]}" get node "$NOMBRE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
if [[ "$LISTO" == True ]]; then ok "Nodo $NOMBRE Ready"; else ko "Nodo $NOMBRE no Ready ($LISTO)"; fi
IIP="$("${K[@]}" get node "$NOMBRE" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)"
if [[ "$IIP" == "$IP" ]]; then ok "InternalIP $IIP (lan0, no la de gestión)"; else ko "InternalIP $IIP (esperada $IP)" "Revisa node-ip en config.yaml"; fi
ROLES_N="$("${K[@]}" get node "$NOMBRE" -o jsonpath='{.metadata.labels}' 2>/dev/null || true)"
comprobar "Roles control-plane y etcd" "" bash -c "grep -q 'node-role.kubernetes.io/control-plane' <<<'$ROLES_N' && grep -q 'node-role.kubernetes.io/etcd' <<<'$ROLES_N'"
TAINTS="$("${K[@]}" get node "$NOMBRE" -o jsonpath='{.spec.taints}' 2>/dev/null || true)"
if [[ -z "$TAINTS" || "$TAINTS" == "[]" ]]; then ok "Sin taints: el servidor también ejecuta cargas"; else aviso "Taints: $TAINTS"; fi

seccion "3. Pods del sistema"
PODS="$("${K[@]}" get pods -A -o wide 2>/dev/null || true)"
bloque "kubectl get pods -A -o wide" <<<"$PODS"
MALOS="$(awk 'NR>1 && $4 ~ /CrashLoopBackOff|Error|ImagePull|ErrImage|CreateContainer/' <<<"$PODS")"
PEND="$(awk 'NR>1 && $4 ~ /Pending|ContainerCreating|Init/' <<<"$PODS")"
if [[ -z "$MALOS" ]]; then ok "Ningún pod en error"; else ko "Pods en error: $(awk '{print $2}' <<<"$MALOS" | tr '\n' ' ')" "kubectl -n kube-system describe pod <nombre>"; fi
if [[ -n "$PEND" ]]; then aviso "Pods pendientes: $(awk '{print $2}' <<<"$PEND" | tr '\n' ' ')" "Normal en réplicas que esperan a más nodos (p. ej. 2.ª réplica de cilium-operator)"; fi
for c in etcd kube-apiserver kube-controller-manager kube-scheduler; do
  comprobar "$c-$NOMBRE Running" "" bash -c "awk '\$2==\"$c-$NOMBRE\" && \$4==\"Running\"' <<<\"\$0\" | grep -q ." "$PODS"
done
comprobar "CoreDNS Running" "" bash -c "awk '\$2 ~ /coredns/ && \$2 !~ /autoscaler/ && \$4==\"Running\"' <<<\"\$0\" | grep -q ." "$PODS"

seccion "4. Cilium"
comprobar "DaemonSet cilium con todos sus pods listos" "kubectl -n kube-system get ds cilium" \
  bash -c "[[ \$(${K[*]} -n kube-system get ds cilium -o jsonpath='{.status.numberReady}/{.status.desiredNumberScheduled}') =~ ^([1-9][0-9]*)/\\1\$ ]]"
ST="$("${K[@]}" -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status --brief 2>&1 || true)"
if [[ "$ST" == OK* ]]; then ok "cilium-dbg status: OK"; else ko "cilium-dbg status: $(head -1 <<<"$ST")" "kubectl -n kube-system exec ds/cilium -- cilium-dbg status"; fi
CC="$("${K[@]}" -n kube-system get cm cilium-config -o json 2>/dev/null || true)"
cval() { python3 -c "import json,sys; print(json.load(sys.stdin)['data'].get(sys.argv[1],''))" "$1" <<<"$CC" 2>/dev/null || true; }
v="$(cval cluster-name)"; [[ "$v" == "$CILIUM_CLUSTER_NAME" ]] && ok "cluster-name = $v" || ko "cluster-name = '$v' (esperado $CILIUM_CLUSTER_NAME)" "HelmChartConfig no aplicado"
v="$(cval cluster-id)";   [[ "$v" == "$CILIUM_CLUSTER_ID" ]] && ok "cluster-id = $v" || ko "cluster-id = '$v' (esperado $CILIUM_CLUSTER_ID)"
v="$(cval devices)";      [[ "$v" == lan0 ]] && ok "devices = lan0 (datapath solo en la red del aula)" || ko "devices = '$v' (esperado lan0)"
v="$(cval enable-hubble)"; [[ "$v" == true ]] && ok "Hubble activado" || ko "enable-hubble = '$v'"
for d in hubble-relay hubble-ui; do
  comprobar "Deployment $d disponible" "kubectl -n kube-system get deploy $d" \
    bash -c "[[ \$(${K[*]} -n kube-system get deploy $d -o jsonpath='{.status.availableReplicas}') -ge 1 ]]"
done

seccion "5. Servicios del clúster (rangos del grupo)"
KIP="$("${K[@]}" get svc kubernetes -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)"
ESP_KIP="${SVC_CIDR%.0/*}.1"
[[ "$KIP" == "$ESP_KIP" ]] && ok "Service kubernetes = $KIP (dentro de $SVC_CIDR)" || ko "Service kubernetes = $KIP (esperado $ESP_KIP)"
SVCS="$("${K[@]}" -n kube-system get svc -o jsonpath='{range .items[*]}{.metadata.name}={.spec.clusterIP}{"\n"}{end}' 2>/dev/null || true)"
comprobar "DNS del clúster en $CLUSTER_DNS" "Revisa cluster-dns" grep -q "=${CLUSTER_DNS}\$" <<<"$SVCS"
PCIDR="$("${K[@]}" get node "$NOMBRE" -o jsonpath='{.spec.podCIDR}' 2>/dev/null || true)"
[[ "${PCIDR%.*.*}" == "${POD_CIDR%.*.*}" ]] && ok "podCIDR del nodo $PCIDR (dentro de $POD_CIDR)" || ko "podCIDR $PCIDR fuera de $POD_CIDR"

seccion "6. Prueba con un pod: DNS interno, DNS externo e Internet"
# Sin modo interactivo (-i): un kubectl que lee del terminal dentro de timeout queda detenido (SIGTTIN).
PRUEBA_CMD='nslookup kubernetes.default.svc.cluster.local >/dev/null 2>&1 && echo DNS_INTERNO_OK; nslookup deb.debian.org >/dev/null 2>&1 && echo DNS_EXTERNO_OK; wget -q -T 8 -O /dev/null http://deb.debian.org/ && echo INTERNET_OK; hostname -i'
"${K[@]}" delete pod prueba-hito02 --ignore-not-found --wait=true </dev/null >/dev/null 2>&1 || true
if "${K[@]}" run prueba-hito02 --image=docker.io/library/busybox:1.36 --restart=Never --command -- sh -c "$PRUEBA_CMD" </dev/null >/dev/null 2>&1; then
  ok "Pod de prueba creado (busybox desde Docker Hub)"
else ko "No se pudo crear el pod de prueba"; fi
info "Esperando a que el pod termine (máx. 3 min)…"
if "${K[@]}" wait pod/prueba-hito02 --for=jsonpath='{.status.phase}'=Succeeded --timeout=180s </dev/null >/dev/null 2>&1; then
  ok "Pod de prueba terminado"
else
  EV="$("${K[@]}" get events --field-selector involvedObject.name=prueba-hito02 -o custom-columns=MOTIVO:.reason,MENSAJE:.message --no-headers </dev/null 2>&1 | tail -3)"
  ko "El pod de prueba no terminó en 3 min" "Eventos: $(tr '\n' ' ' <<<"$EV")"
fi
SAL="$("${K[@]}" logs prueba-hito02 </dev/null 2>&1 || true)"
"${K[@]}" delete pod prueba-hito02 --ignore-not-found --wait=false </dev/null >/dev/null 2>&1 || true
grep -q DNS_INTERNO_OK <<<"$SAL" && ok "Pod resuelve kubernetes.default (CoreDNS)" || ko "Pod no resuelve nombres internos" "kubectl -n kube-system logs -l k8s-app=kube-dns"
grep -q DNS_EXTERNO_OK <<<"$SAL" && ok "Pod resuelve deb.debian.org (reenvío a 8.8.8.8)" || ko "Pod no resuelve nombres externos" "¿resolv-conf del kubelet?"
grep -q INTERNET_OK    <<<"$SAL" && ok "Pod sale a Internet (masquerade por lan0)" || ko "Pod sin salida a Internet"
PIP="$(grep -oE '10\.[0-9]+\.[0-9]+\.[0-9]+' <<<"$SAL" | head -1 || true)"
if [[ -n "$PIP" && "${PIP%.*.*}" == "${POD_CIDR%.*.*}" ]]; then ok "IP del pod de prueba $PIP dentro de $POD_CIDR"
else ko "IP del pod de prueba '${PIP:-?}' fuera de $POD_CIDR" "IPAM de Cilium no usa el cluster-cidr del grupo"; fi
v="$(cval ipam)"; info "IPAM de Cilium: ${v:-?}"

seccion "7. Copia de seguridad de etcd"
SN="hito02-${NOMBRE}"
if sudo /usr/local/bin/rke2 etcd-snapshot save --name "$SN" >/dev/null 2>&1; then ok "Snapshot de etcd '$SN' creado"; else ko "Snapshot de etcd" "sudo rke2 etcd-snapshot save --name $SN"; fi
LS="$(sudo ls -1 /var/lib/rancher/rke2/server/db/snapshots/ 2>/dev/null || true)"
comprobar "Snapshot presente en /var/lib/rancher/rke2/server/db/snapshots" "" grep -q "^$SN" <<<"$LS"

seccion "8. El token no está en el repositorio"
if grep -rqF "$(cat "$HOME/.smartriberia/token" 2>/dev/null || echo NOHAYTOKEN)" "$REPO" 2>/dev/null; then ko "¡El token aparece dentro de ~/repo!" "Bórralo y revisa qué fichero lo contiene"
else ok "El token no aparece en el repositorio"; fi

resumen || true
(( N_KO == 0 ))
}

set +e
main 2>&1 | tee "$EVID.raw"; RC=${PIPESTATUS[0]}
sed 's/\x1b\[[0-9;]*m//g' "$EVID.raw" > "$EVID" && rm -f "$EVID.raw"
echo "  • Evidencia guardada en: $EVID"
exit "$RC"
