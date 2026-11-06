# lib/puesto.sh - ÚNICA regla que deriva la identidad de un puesto.
# Requiere: comun.env y gN.env cargados, y PUESTO definido.
# Define: X, NOMBRE, IP, MAC_LAN, MAC_MGMT, MGMT_VM_IP
X=""
for p in $PUESTOS; do [[ "${p%%:*}" == "$PUESTO" ]] && X="${p##*:}"; done
NOMBRE="g${GRUPO}-${PUESTO}"
IP="${RED_PREFIJO}.$((IP_BASE + ${X:-0}))"
MAC_LAN="52:54:00:00:0${GRUPO}:0${X}"
MAC_MGMT="52:54:00:00:0${GRUPO}:1${X}"
MGMT_VM_IP="${MGMT_PREFIJO}.$((10 + ${X:-0}))"

# ip_de <puesto>: IP de aula de otro puesto del mismo grupo
ip_de() { local q x=""; for q in $PUESTOS; do [[ "${q%%:*}" == "$1" ]] && x="${q##*:}"; done; echo "${RED_PREFIJO}.$((IP_BASE + x))"; }
