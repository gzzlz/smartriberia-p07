# SmartRiberIA - infraestructura reproducible (P07)

Regla: lo único que cambia entre grupos es `grupos/gN.env`. Todo lo demás es común.
G2 y G3 solo ejecutan versiones etiquetadas (`p07-h01`, ...). Nada se arregla a mano:
se corrige aquí, se etiqueta y se vuelve a ejecutar.

## Estructura
| Ruta | Qué es |
|---|---|
| `lib/ui.sh` | Salida visual común: colores, `[ OK ]` / `[ KO ]` / `[AVISO]` y resumen |
| `lib/puesto.sh` | **Regla única** que calcula hostname, IP y MACs a partir de grupo y puesto |
| `vm/comprobar-hito01.sh` | Comprobación del hito 01 dentro de la VM; guarda la evidencia en `~/evidencias/` |
| `grupos/comun.env` | Imagen fijada, recursos, red del aula, NTP, red de gestión, puestos |
| `grupos/g1.env` ... `g3.env` | `IP_BASE` del grupo, CIDR de pods/servicios, nombre e ID de Cilium |
| `host/crear-red-mgmt.sh` | Red aislada `rke2-mgmt` (192.168.200.0/24) para entrar a la VM desde su PC |
| `host/descargar-rke2.sh` | Hito 02: descarga y verifica (SHA-256) los artefactos air-gap de la versión fijada de RKE2 |
| `host/crear-token.sh` | Hito 02: genera el token del grupo (solo el piloto); fuera del repositorio |
| `host/enviar-a-vm.sh` | Envía a la VM el repositorio, los artefactos y el token |
| `vm/preparar-nodo.sh` | Hito 02: módulos, sysctl y networkd para RKE2 + Cilium |
| `vm/instalar-rke2.sh` | Hito 02: genera config.yaml según el rol e instala RKE2 (con --dry-run) |
| `vm/comprobar-hito02.sh` | Hito 02: comprobación y evidencia del primer servidor |
| `host/crear-vm.sh` | Copia independiente del disco + semilla cloud-init + `virt-install` |

## Fuera del repositorio (en `~/smartriberia/`)
`imagenes/` (base + SHA512SUMS), `vms/` (discos y semillas), `secreto.env` (hash de la contraseña, chmod 600), `rke2/<versión>/` (artefactos), `token-gN.secreto` (token del grupo, chmod 600).

## Esquema de cada puesto (N = grupo, X = 1..6 para cp1..w3)
IP aula `172.30.101.(200+10N+X)/16` (G1 .211-216, G2 .221-226, G3 .231-236) · IP gestión `192.168.200.(10+X)` ·
MAC aula `52:54:00:00:0N:0X` · MAC gestión `52:54:00:00:0N:1X` · hostname `gN-<puesto>`

El router del aula solo encamina 172.30.101.0/24 (aunque el host tenga /16): por eso todas las VMs van en 101.x.

## Uso (en el host, sin sudo)
```bash
bash host/crear-red-mgmt.sh
bash host/crear-vm.sh <N> <puesto> --dry-run   # revisar
bash host/crear-vm.sh <N> <puesto>             # crear
```
