# lib/k8s.sh - utilidades de Kubernetes comunes a los scripts de la VM.
# Requiere: el array K con el comando kubectl (p. ej. K=(kubectl --kubeconfig ~/.kube/config)).

# Componentes del sistema que deben estar listos antes de dar el nodo por operativo.
# cilium-operator no se espera entero: con un solo nodo su 2.ª réplica queda Pending (antiafinidad).
SISTEMA_DS="cilium"
SISTEMA_DEPLOY="cilium-operator rke2-coredns-rke2-coredns hubble-relay hubble-ui"

# sistema_pendiente: imprime lo que aún no está listo (vacío = todo listo)
sistema_pendiente() {
  local d r a p=""
  for d in $SISTEMA_DS; do
    r="$("${K[@]}" -n kube-system get ds "$d" -o jsonpath='{.status.numberReady}/{.status.desiredNumberScheduled}' </dev/null 2>/dev/null || true)"
    [[ "$r" =~ ^([1-9][0-9]*)/\1$ ]] || p+="ds/$d($r) "
  done
  for d in $SISTEMA_DEPLOY; do
    a="$("${K[@]}" -n kube-system get deploy "$d" -o jsonpath='{.status.availableReplicas}' </dev/null 2>/dev/null || true)"
    [[ "${a:-0}" -ge 1 ]] || p+="deploy/$d "
  done
  # Jobs de instalación de charts (helm-install-*): deben haber terminado
  while read -r j s; do
    [[ -n "$j" && "$s" != 1 ]] && p+="job/$j "
  done < <("${K[@]}" -n kube-system get jobs -o jsonpath='{range .items[*]}{.metadata.name} {.status.succeeded}{"\n"}{end}' </dev/null 2>/dev/null || true)
  printf '%s' "$p"
}

# esperar_sistema <segundos>: espera a que todo esté listo. Devuelve 1 si vence el plazo.
# Deja en PENDIENTE lo que faltaba al terminar.
esperar_sistema() {
  local lim=$(( $(date +%s) + ${1:-300} ))
  PENDIENTE="$(sistema_pendiente)"
  while [[ -n "$PENDIENTE" ]]; do
    (( $(date +%s) >= lim )) && return 1
    sleep 5
    PENDIENTE="$(sistema_pendiente)"
  done
  return 0
}
