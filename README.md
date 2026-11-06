# SmartRiberIA - infraestructura reproducible (P07)

Regla: lo único que cambia entre grupos es `grupos/gN.env`. Todo lo demás es común.
G2 y G3 solo ejecutan versiones etiquetadas (`p07-h01`, ...). Nada se arregla a mano:
se corrige aquí, se etiqueta y se vuelve a ejecutar.

## Estructura
| Ruta | Qué es |
|---|---|
| `grupos/comun.env` | Imagen fijada, recursos, red del aula, NTP, red de gestión, puestos |
| `grupos/g1.env` ... `g3.env` | Tramo de IPs, CIDR de pods/servicios, nombre e ID de Cilium |
| `host/crear-red-mgmt.sh` | Red aislada `k8s-mgmt` (192.168.200.0/24) para entrar a la VM desde su PC |
| `host/crear-vm.sh` | Copia independiente del disco + semilla cloud-init + `virt-install` |

## Fuera del repositorio (en `~/smartriberia/`)
`imagenes/` (base + SHA512SUMS), `vms/` (discos y semillas), `secreto.env` (hash de la contraseña, chmod 600).

## Esquema de cada puesto (N = grupo, X = 1..6 para cp1..w3)
IP `172.30.20N.(10+X)/16` · MAC aula `52:54:00:00:0N:0X` · MAC gestión `52:54:00:00:0N:1X` · hostname `gN-<puesto>`

## Uso (en el host, sin sudo)
```bash
bash host/crear-red-mgmt.sh
bash host/crear-vm.sh <N> <puesto> --dry-run   # revisar
bash host/crear-vm.sh <N> <puesto>             # crear
```
