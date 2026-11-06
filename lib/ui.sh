# lib/ui.sh - salida visual común a todos los scripts de SmartRiberIA
# Uso: source "$REPO/lib/ui.sh"
# Colores solo si la salida es una terminal (o FORCE_COLOR=1); NO_COLOR=1 los desactiva.

if { [[ -t 1 ]] || [[ -n "${FORCE_COLOR:-}" ]]; } && [[ -z "${NO_COLOR:-}" ]]; then
  C_R=$'\e[31m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_B=$'\e[34m'; C_M=$'\e[35m'
  C_C=$'\e[36m'; C_N=$'\e[1m'; C_D=$'\e[2m'; C_0=$'\e[0m'
else
  C_R=""; C_G=""; C_Y=""; C_B=""; C_M=""; C_C=""; C_N=""; C_D=""; C_0=""
fi

N_OK=0; N_KO=0; N_AV=0

_linea() { local n="$1" c="$2" s=""; for ((i = 0; i < n; i++)); do s+="$c"; done; printf '%s' "$s"; }

# Longitud visible (caracteres, no bytes) aunque el script use LC_ALL=C
_ancho() { local LC_ALL=C.UTF-8; printf '%s' "${#1}"; }
_pad()   { local n=$(( $2 - $(_ancho "$1") )); (( n < 0 )) && n=0; printf '%s%s' "$1" "$(_linea "$n" ' ')"; }

# Recuadro con el título del script
titulo() {
  local t="$1" sub="${2:-}" w a b
  a=$(_ancho "$t"); b=$(_ancho "$sub"); w=$(( a > b ? a : b ))
  printf '\n%s╔%s╗%s\n' "$C_C" "$(_linea $((w + 4)) '═')" "$C_0"
  printf '%s║%s  %s%s%s  %s║%s\n' "$C_C" "$C_0" "$C_N" "$(_pad "$t" "$w")" "$C_0" "$C_C" "$C_0"
  [[ -n "$sub" ]] && printf '%s║%s  %s%s%s  %s║%s\n' "$C_C" "$C_0" "$C_D" "$(_pad "$sub" "$w")" "$C_0" "$C_C" "$C_0"
  printf '%s╚%s╝%s\n' "$C_C" "$(_linea $((w + 4)) '═')" "$C_0"
}

seccion() { printf '\n%s%s▶ %s%s\n' "$C_N" "$C_B" "$1" "$C_0"; }
dato()    { printf '  %s%s%s %s\n' "$C_D" "$(_pad "$1" 20)" "$C_0" "$2"; }
info()    { printf '  %s•%s %s\n' "$C_C" "$C_0" "$1"; }
ok()      { N_OK=$((N_OK + 1)); printf '  %s[ OK ]%s %s\n' "$C_G$C_N" "$C_0" "$1"; }
aviso()   { N_AV=$((N_AV + 1)); printf '  %s[AVISO]%s %s\n' "$C_Y$C_N" "$C_0" "$1"
            [[ -n "${2:-}" ]] && printf '         %s↳ %s%s\n' "$C_D" "$2" "$C_0"; return 0; }
ko()      { N_KO=$((N_KO + 1)); printf '  %s[ KO ]%s %s\n' "$C_R$C_N" "$C_0" "$1"
            [[ -n "${2:-}" ]] && printf '         %s↳ %s%s\n' "$C_Y" "$2" "$C_0"; return 0; }

# comprobar "descripción" "pista si falla" comando [args...]
comprobar() {
  local desc="$1" pista="$2"; shift 2
  if "$@" >/dev/null 2>&1; then ok "$desc"; else ko "$desc" "$pista"; fi
}

# Bloque de texto (ficheros generados, comandos)
bloque() {
  printf '  %s┌─ %s%s\n' "$C_M" "$1" "$C_0"
  sed "s/^/  ${C_M}│${C_0} /"
  printf '  %s└%s%s\n' "$C_M" "$(_linea 40 '─')" "$C_0"
}

# Resumen final: devuelve 1 si hubo algún KO
resumen() {
  local estado color
  if (( N_KO == 0 )); then estado="CONFIGURACIÓN CORRECTA (OK)"; color="$C_G"
  else estado="CONFIGURACIÓN INCORRECTA (KO)"; color="$C_R"; fi
  printf '\n%s%s%s%s\n' "$color" "$C_N" "$(_linea 50 '━')" "$C_0"
  printf '%s%s  %s%s\n' "$color" "$C_N" "$estado" "$C_0"
  printf '  %s%d OK%s · %s%d KO%s · %s%d avisos%s\n' "$C_G" "$N_OK" "$C_0" "$C_R" "$N_KO" "$C_0" "$C_Y" "$N_AV" "$C_0"
  printf '%s%s%s%s\n' "$color" "$C_N" "$(_linea 50 '━')" "$C_0"
  (( N_KO == 0 ))
}

# Corta el script si ya hay algún KO (antes de tocar nada)
parar_si_ko() {
  if (( N_KO > 0 )); then
    resumen || true
    printf '%sNo se ha modificado nada. Corrige los KO y vuelve a ejecutar.%s\n' "$C_Y" "$C_0"
    exit 1
  fi
}
