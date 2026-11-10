# lib/puesto.sh - ÚNICA regla que deriva la identidad de un puesto.
# Requiere: comun.env y gN.env cargados, y PUESTO definido.
# Define: X, NOMBRE, IP, MAC_LAN, MAC_MGMT, MGMT_VM_IP, ROL, SERVIDOR_REG_IP, TLS_SAN

# ip_de <puesto>: IP de aula de otro puesto del mismo grupo
ip_de() { local q x=""; for q in $PUESTOS; do [[ "${q%%:*}" == "$1" ]] && x="${q##*:}"; done; echo "${RED_PREFIJO}.$((IP_BASE + x))"; }
# rol_de <puesto>: rol RKE2 de un puesto (server-init, server o agent)
rol_de() { local r; for r in ${ROLES:-}; do [[ "${r%%:*}" == "$1" ]] && { echo "${r##*:}"; return; }; done; }

X=""
for p in $PUESTOS; do [[ "${p%%:*}" == "$PUESTO" ]] && X="${p##*:}"; done
NOMBRE="g${GRUPO}-${PUESTO}"
IP="${RED_PREFIJO}.$((IP_BASE + ${X:-0}))"
MAC_LAN="52:54:00:00:0${GRUPO}:0${X}"
MAC_MGMT="52:54:00:00:0${GRUPO}:1${X}"
MGMT_VM_IP="${MGMT_PREFIJO}.$((10 + ${X:-0}))"

# RKE2: rol, servidor de registro (el server-init) y nombres/IPs válidos del API (todos los server)
ROL="$(rol_de "$PUESTO")"
SERVIDOR_REG=""; TLS_SAN=""
for r in ${ROLES:-}; do
  n="${r%%:*}"; rr="${r##*:}"
  [[ "$rr" == "server-init" ]] && SERVIDOR_REG="g${GRUPO}-${n}"
  [[ "$rr" == server* ]] && TLS_SAN+="g${GRUPO}-${n} $(ip_de "$n") "
done
SERVIDOR_REG_IP=""; [[ -n "$SERVIDOR_REG" ]] && SERVIDOR_REG_IP="$(ip_de "${SERVIDOR_REG#g${GRUPO}-}")"
