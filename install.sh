#!/usr/bin/env bash
set -Eeuo pipefail

PATH="/usr/sbin:/usr/bin:/sbin:/bin"
LC_ALL="C"
LANG="C"
export PATH LC_ALL LANG

MANAGER_VERSION="1.5.0"
SERVICE_NAME="hcr-server"
SYSTEMD_DIR="/etc/systemd/system"
DEFAULT_PORT="8880"
DEFAULT_TRANSPORT="plain"
DEFAULT_MAX_DOWNLOAD_FRAME="16384"
DEFAULT_DOWNLOAD_POLL_TIMEOUT="8s"

PORT="$DEFAULT_PORT"
TRANSPORT="$DEFAULT_TRANSPORT"
MAX_DOWNLOAD_FRAME="$DEFAULT_MAX_DOWNLOAD_FRAME"
DOWNLOAD_POLL_TIMEOUT="$DEFAULT_DOWNLOAD_POLL_TIMEOUT"
ACTION="menu"
TEMP_UNIT=""

# ANSI: solo si hay terminal real.
if [ -t 1 ]; then
  C_GOLD='\033[1;33m'; C_GREEN='\033[1;32m'; C_RED='\033[1;31m'
  C_CYAN='\033[1;36m'; C_WHITE='\033[1;37m'; C_GRAY='\033[0;37m'; C_RESET='\033[0m'
else
  C_GOLD=''; C_GREEN=''; C_RED=''; C_CYAN=''; C_WHITE=''; C_GRAY=''; C_RESET=''
fi

BAR='=x=x=x=x=x=x=x=x=x=x=x=x=x=x=x=x=x=x=x=x='

fail() {
  printf '%bError:%b %s\n' "$C_RED" "$C_RESET" "$*" >&2
  return 1
}

command -v readlink >/dev/null 2>&1 || { echo "Error: readlink was not found." >&2; exit 1; }
SCRIPT_PATH="$(readlink -f -- "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname -- "$SCRIPT_PATH")"
BINARY_PATH="${SCRIPT_DIR}/hcr-server"
TLS_CERT_PATH="${SCRIPT_DIR}/fullchain.pem"
TLS_KEY_PATH="${SCRIPT_DIR}/privkey.pem"
UNIT_SOURCE_PATH="${SCRIPT_DIR}/${SERVICE_NAME}.service"
UNIT_LINK_PATH="${SYSTEMD_DIR}/${SERVICE_NAME}.service"
STATE_PATH="${SCRIPT_DIR}/hcr-manager.conf"
FIREWALL_STATE_PATH="${SCRIPT_DIR}/.hcr-manager-firewall"
EXTRA_STATE_PATH="${SCRIPT_DIR}/hcr-extra-ports.conf"
AUTOTUNE_STATE_PATH="${SCRIPT_DIR}/hcr-autotune.conf"

cleanup() {
  local rc=$?
  set +e
  [ -n "${TEMP_UNIT:-}" ] && rm -f -- "$TEMP_UNIT"
  return "$rc"
}
trap cleanup EXIT

prompt_read() {
  local __var="$1" __prompt="$2" __value=""
  if [ -r /dev/tty ] && [ -w /dev/tty ]; then
    printf '%s' "$__prompt" >/dev/tty
    IFS= read -r __value </dev/tty || return 1
  else
    printf '%s' "$__prompt"
    IFS= read -r __value || return 1
  fi
  printf -v "$__var" '%s' "$__value"
}

pause_menu() {
  local _tmp=""
  prompt_read _tmp "Presiona ENTER para continuar... " || true
}

clear_screen() {
  if [ -t 1 ]; then printf '\033[2J\033[H'; fi
}

usage() {
  cat <<EOF
HCR / SPEIGO VPN Manager v${MANAGER_VERSION}

Uso interactivo:
  sudo ./install.sh
  sudo ./install.sh menu

MULTI-PORT:
  Instala primero el HCR principal y usa la opción [5] para crear listeners HCR
  adicionales reales en otros puertos. Cada puerto extra tiene su propio servicio systemd.

Uso directo:
  sudo ./install.sh --port <1-65535> --transport <plain|tls|auto> \\
    --max-download-frame <512-16384> --download-poll-timeout <duracion>
  sudo ./install.sh --uninstall

AUTO-TUNE:
  Ajusta automáticamente NOFILE, TasksMax y memoria por listener según vCPU, RAM
  y cantidad de listeners HCR. Usa opción [14] después de redimensionar la VPS.

Defaults SpeiGo:
  puerto: ${DEFAULT_PORT}
  transport: ${DEFAULT_TRANSPORT}
  MAX_DOWNLOAD_FRAME: ${DEFAULT_MAX_DOWNLOAD_FRAME}
  DOWNLOAD_POLL_TIMEOUT: ${DEFAULT_DOWNLOAD_POLL_TIMEOUT}
EOF
}

require_command() { command -v "$1" >/dev/null 2>&1 || fail "$1 no está instalado."; }

require_environment() {
  [ "$(id -u)" -eq 0 ] || fail "Ejecuta el manager como root (sudo)."
  [ "$(uname -s)" = "Linux" ] || fail "Este manager requiere Linux."
  local c
  for c in stat systemctl systemd-analyze flock ln mv mktemp sleep sed grep awk; do require_command "$c"; done
  systemctl show --property=Version --value >/dev/null 2>&1 || fail "systemd no está disponible."
  if [[ ! "$SCRIPT_DIR" =~ ^/[-A-Za-z0-9._/@+:]+$ ]]; then
    fail "La ruta del manager contiene caracteres no soportados: $SCRIPT_DIR"
  fi
}

acquire_install_lock() {
  exec 9<"${SYSTEMD_DIR}" || fail "No se pudo abrir el directorio de systemd para bloqueo."
  flock -n 9 || fail "Ya hay otro proceso de instalación HCR ejecutándose."
}

mode_is_writable_by_others() { (( (8#$1 & 8#022) != 0 )); }

validate_secure_directory() {
  local current="$SCRIPT_DIR" mode
  while :; do
    [ -d "$current" ] && [ ! -L "$current" ] || fail "La ruta debe ser un directorio real: $current"
    [ "$(stat -c '%u' -- "$current")" = "0" ] || fail "La ruta debe pertenecer a root: $current"
    mode="$(stat -c '%a' -- "$current")"
    mode_is_writable_by_others "$mode" && fail "La ruta no puede ser escribible por grupo/otros: $current"
    [ "$current" = "/" ] && break
    current="$(dirname -- "$current")"
  done
}

validate_root_file() {
  local executable="$1" label="$2" path="$3" mode
  [ -f "$path" ] && [ ! -L "$path" ] || fail "$label debe ser un archivo regular: $path"
  [ "$(stat -c '%u' -- "$path")" = "0" ] || fail "$label debe pertenecer a root: $path"
  mode="$(stat -c '%a' -- "$path")"
  mode_is_writable_by_others "$mode" && fail "$label no puede ser escribible por grupo/otros: $path"
  if [ "$executable" = "true" ] && [ ! -x "$path" ]; then fail "$label debe ser ejecutable: $path"; fi
}

validate_binary_identity() {
  local output
  output="$("$BINARY_PATH" -version 2>/dev/null)" || fail "El binario HCR no responde a -version."
  [[ "$output" =~ ^hcr-server\ version\ [0-9]+\.[0-9]+\.[0-9]+(\ -\ Patch\ [1-9][0-9]*)?$ ]] || fail "Versión de binario HCR no reconocida: $output"
}

validate_tls_pair() {
  require_command openssl
  local cert_pub key_pub key_mode
  validate_root_file false "Certificado TLS" "$TLS_CERT_PATH"
  validate_root_file false "Clave TLS" "$TLS_KEY_PATH"
  key_mode="$(stat -c '%a' -- "$TLS_KEY_PATH")"
  (( (8#${key_mode} & 8#077) == 0 )) || fail "privkey.pem debe tener permisos privados (por ejemplo 600)."
  cert_pub="$(openssl x509 -in "$TLS_CERT_PATH" -pubkey -noout 2>/dev/null)" || fail "No se pudo leer fullchain.pem."
  key_pub="$(openssl pkey -in "$TLS_KEY_PATH" -passin pass: -pubout 2>/dev/null)" || fail "No se pudo leer privkey.pem."
  [ "$cert_pub" = "$key_pub" ] || fail "fullchain.pem y privkey.pem no corresponden."
}

validate_port() {
  local value="$1"
  case "$value" in ''|*[!0-9]*) return 1 ;; esac
  [ "$((10#$value))" -ge 1 ] && [ "$((10#$value))" -le 65535 ]
}

validate_frame() {
  local value="$1"
  case "$value" in ''|*[!0-9]*) return 1 ;; esac
  [ "$((10#$value))" -ge 512 ] && [ "$((10#$value))" -le 16384 ]
}

validate_timeout() { [[ "$1" =~ ^[1-9][0-9]*(ms|s|m)$ ]]; }

validate_transport() { case "$1" in plain|tls|auto) return 0 ;; *) return 1 ;; esac; }


# -----------------------------------------------------------------------------
# AUTO-TUNE v1.5.0
# Ajusta límites por listener usando CPU, RAM y cantidad total de listeners HCR.
# No toca sysctl globales ni parámetros de SSH para no perjudicar otros servicios.
# -----------------------------------------------------------------------------
AT_CPU=1
AT_MEM_MB=1024
AT_LISTENERS=1
AT_CPU_SHARE=1
AT_MEM_SHARE_MB=1024
AT_NOFILE=16384
AT_TASKS=512
AT_MEMORY_HIGH_MB=512
AT_MEMORY_MAX_MB=768
AT_PROFILE="BALANCED"

clamp_int() {
  local v="$1" lo="$2" hi="$3"
  [ "$v" -lt "$lo" ] && v="$lo"
  [ "$v" -gt "$hi" ] && v="$hi"
  printf '%s' "$v"
}

detect_cpu_count() {
  local n=""
  if command -v nproc >/dev/null 2>&1; then n="$(nproc 2>/dev/null || true)"; fi
  if ! [[ "$n" =~ ^[1-9][0-9]*$ ]] && command -v getconf >/dev/null 2>&1; then
    n="$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)"
  fi
  [[ "$n" =~ ^[1-9][0-9]*$ ]] || n=1
  printf '%s' "$n"
}

detect_mem_mb() {
  local kb=""
  kb="$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null || true)"
  [[ "$kb" =~ ^[1-9][0-9]*$ ]] || kb=1048576
  printf '%s' "$((kb / 1024))"
}

extra_port_count() {
  local p t f d n=0
  if [ -f "$EXTRA_STATE_PATH" ]; then
    while read -r p t f d; do
      validate_port "${p:-}" || continue
      validate_transport "${t:-}" || continue
      validate_frame "${f:-}" || continue
      validate_timeout "${d:-}" || continue
      n=$((n + 1))
    done < "$EXTRA_STATE_PATH"
  fi
  printf '%s' "$n"
}

managed_listener_count() {
  local n=0 extras
  extras="$(extra_port_count)"
  if [ -L "$UNIT_LINK_PATH" ] || [ -f "$UNIT_SOURCE_PATH" ]; then n=1; fi
  n=$((n + extras))
  [ "$n" -ge 1 ] || n=1
  printf '%s' "$n"
}

calculate_autotune() {
  local listeners="${1:-1}" cpu mem cpu_share mem_share fd_cpu fd_mem nofile tasks
  local reserve budget per_max per_high profile
  [[ "$listeners" =~ ^[1-9][0-9]*$ ]] || listeners=1
  cpu="$(detect_cpu_count)"
  mem="$(detect_mem_mb)"
  cpu_share=$(((cpu + listeners - 1) / listeners))
  [ "$cpu_share" -ge 1 ] || cpu_share=1
  mem_share=$((mem / listeners))
  [ "$mem_share" -ge 128 ] || mem_share=128

  fd_cpu=$((cpu_share * 16384))
  fd_mem=$((mem_share * 16))
  nofile="$fd_cpu"
  [ "$fd_mem" -lt "$nofile" ] && nofile="$fd_mem"
  nofile="$(clamp_int "$nofile" 8192 262144)"

  tasks=$((cpu_share * 512))
  tasks="$(clamp_int "$tasks" 512 8192)"

  if [ "$mem" -le 2048 ]; then
    reserve=$((mem / 4)); [ "$reserve" -ge 384 ] || reserve=384
  elif [ "$mem" -le 4096 ]; then
    reserve=768
  else
    reserve=$((mem / 5)); [ "$reserve" -ge 1024 ] || reserve=1024
  fi
  budget=$((mem - reserve)); [ "$budget" -ge 512 ] || budget=512
  per_max=$((budget / listeners)); [ "$per_max" -ge 256 ] || per_max=256
  per_high=$((per_max * 75 / 100)); [ "$per_high" -ge 192 ] || per_high=192

  if [ "$cpu" -ge 8 ] && [ "$mem" -ge 8192 ]; then profile="HIGH-CAPACITY"
  elif [ "$cpu" -ge 4 ] && [ "$mem" -ge 4096 ]; then profile="BALANCED+"
  elif [ "$cpu" -ge 2 ] && [ "$mem" -ge 2048 ]; then profile="BALANCED"
  else profile="SMALL-VPS"
  fi

  AT_CPU="$cpu"; AT_MEM_MB="$mem"; AT_LISTENERS="$listeners"
  AT_CPU_SHARE="$cpu_share"; AT_MEM_SHARE_MB="$mem_share"
  AT_NOFILE="$nofile"; AT_TASKS="$tasks"
  AT_MEMORY_HIGH_MB="$per_high"; AT_MEMORY_MAX_MB="$per_max"
  AT_PROFILE="$profile"
}

save_autotune_state() {
  umask 077
  cat > "$AUTOTUNE_STATE_PATH" <<EOF
CPU=$AT_CPU
MEM_MB=$AT_MEM_MB
LISTENERS=$AT_LISTENERS
CPU_SHARE=$AT_CPU_SHARE
MEM_SHARE_MB=$AT_MEM_SHARE_MB
LIMIT_NOFILE=$AT_NOFILE
TASKS_MAX=$AT_TASKS
MEMORY_HIGH_MB=$AT_MEMORY_HIGH_MB
MEMORY_MAX_MB=$AT_MEMORY_MAX_MB
PROFILE=$AT_PROFILE
EOF
  chmod 0600 "$AUTOTUNE_STATE_PATH"
}

show_autotune_summary() {
  local count="${1:-$(managed_listener_count)}"
  calculate_autotune "$count"
  printf ' AUTO-TUNE: %b%s%b | CPU %b%s vCPU%b | RAM %b%s MB%b | Listeners %b%s%b\n' \
    "$C_GREEN" "$AT_PROFILE" "$C_RESET" "$C_CYAN" "$AT_CPU" "$C_RESET" \
    "$C_CYAN" "$AT_MEM_MB" "$C_RESET" "$C_CYAN" "$AT_LISTENERS" "$C_RESET"
  printf ' Recursos/listener: NOFILE %b%s%b | Tasks %b%s%b | MemoryHigh %b%sM%b | MemoryMax %b%sM%b\n' \
    "$C_CYAN" "$AT_NOFILE" "$C_RESET" "$C_CYAN" "$AT_TASKS" "$C_RESET" \
    "$C_CYAN" "$AT_MEMORY_HIGH_MB" "$C_RESET" "$C_CYAN" "$AT_MEMORY_MAX_MB" "$C_RESET"
}

save_state() {
  umask 077
  cat > "$STATE_PATH" <<EOF
PORT=$PORT
TRANSPORT=$TRANSPORT
MAX_DOWNLOAD_FRAME=$MAX_DOWNLOAD_FRAME
DOWNLOAD_POLL_TIMEOUT=$DOWNLOAD_POLL_TIMEOUT
EOF
  chmod 0600 "$STATE_PATH"
}

load_state() {
  local p="" t="" f="" d=""
  if [ -f "$STATE_PATH" ] && [ ! -L "$STATE_PATH" ]; then
    p="$(sed -n 's/^PORT=//p' "$STATE_PATH" | tail -n1)"
    t="$(sed -n 's/^TRANSPORT=//p' "$STATE_PATH" | tail -n1)"
    f="$(sed -n 's/^MAX_DOWNLOAD_FRAME=//p' "$STATE_PATH" | tail -n1)"
    d="$(sed -n 's/^DOWNLOAD_POLL_TIMEOUT=//p' "$STATE_PATH" | tail -n1)"
    validate_port "$p" && PORT="$((10#$p))"
    validate_transport "$t" && TRANSPORT="$t"
    validate_frame "$f" && MAX_DOWNLOAD_FRAME="$((10#$f))"
    validate_timeout "$d" && DOWNLOAD_POLL_TIMEOUT="$d"
  elif [ -f "$UNIT_SOURCE_PATH" ]; then
    local line
    line="$(grep '^ExecStart=' "$UNIT_SOURCE_PATH" 2>/dev/null | head -n1 || true)"
    p="$(printf '%s\n' "$line" | sed -n 's/.*--listen :\([0-9][0-9]*\).*/\1/p')"
    t="$(printf '%s\n' "$line" | sed -n 's/.*--transport \([^ ]*\).*/\1/p')"
    f="$(printf '%s\n' "$line" | sed -n 's/.*--max-download-frame \([0-9][0-9]*\).*/\1/p')"
    d="$(printf '%s\n' "$line" | sed -n 's/.*--download-poll-timeout \([^ ]*\).*/\1/p')"
    validate_port "$p" && PORT="$((10#$p))"
    validate_transport "$t" && TRANSPORT="$t"
    validate_frame "$f" && MAX_DOWNLOAD_FRAME="$((10#$f))"
    validate_timeout "$d" && DOWNLOAD_POLL_TIMEOUT="$d"
  fi
}


extra_service_name() { printf 'hcr-server-extra-%s' "$1"; }
extra_unit_source_path() { printf '%s/hcr-server-extra-%s.service' "$SCRIPT_DIR" "$1"; }
extra_unit_link_path() { printf '%s/hcr-server-extra-%s.service' "$SYSTEMD_DIR" "$1"; }

extra_port_exists() {
  local p="$1"
  [ -f "$EXTRA_STATE_PATH" ] && grep -Eq "^${p}[[:space:]]" "$EXTRA_STATE_PATH" 2>/dev/null
}

extra_state_add() {
  local p="$1" t="$2" f="$3" d="$4" tmp
  umask 077
  tmp="$(mktemp "${SCRIPT_DIR}/.extra.XXXXXX")"
  if [ -f "$EXTRA_STATE_PATH" ]; then
    grep -Ev "^${p}[[:space:]]" "$EXTRA_STATE_PATH" > "$tmp" || true
  fi
  printf '%s %s %s %s\n' "$p" "$t" "$f" "$d" >> "$tmp"
  sort -n -k1,1 "$tmp" -o "$tmp"
  mv -f "$tmp" "$EXTRA_STATE_PATH"
  chmod 0600 "$EXTRA_STATE_PATH"
}

extra_state_remove() {
  local p="$1" tmp
  [ -f "$EXTRA_STATE_PATH" ] || return 0
  tmp="$(mktemp "${SCRIPT_DIR}/.extra.XXXXXX")"
  grep -Ev "^${p}[[:space:]]" "$EXTRA_STATE_PATH" > "$tmp" || true
  if [ -s "$tmp" ]; then
    mv -f "$tmp" "$EXTRA_STATE_PATH"
    chmod 0600 "$EXTRA_STATE_PATH"
  else
    rm -f "$tmp" "$EXTRA_STATE_PATH"
  fi
}

extra_get_line() {
  local p="$1"
  [ -f "$EXTRA_STATE_PATH" ] || return 1
  grep -E "^${p}[[:space:]]" "$EXTRA_STATE_PATH" | tail -n1
}

extra_service_is_active() {
  local p="$1"
  systemctl is-active --quiet "$(extra_service_name "$p").service" 2>/dev/null
}

port_has_listener() {
  local p="$1"
  if command -v ss >/dev/null 2>&1; then
    # No usar el filtro `sport = :PORT`: algunas versiones antiguas de ss lo
    # interpretan distinto. Parsear la lista completa es más portable.
    ss -ltnH 2>/dev/null | awk -v p="$p" '
      $4 ~ (":" p "$") { found=1; exit }
      END { exit(found ? 0 : 1) }
    '
    return $?
  fi
  if command -v netstat >/dev/null 2>&1; then
    netstat -ltn 2>/dev/null | awk -v p="$p" '
      NR > 2 && $4 ~ (":" p "$") { found=1; exit }
      END { exit(found ? 0 : 1) }
    '
    return $?
  fi
  return 1
}

validate_extra_unit_link() {
  local p="$1" src link
  src="$(extra_unit_source_path "$p")"
  link="$(extra_unit_link_path "$p")"
  if [ -L "$link" ]; then
    [ "$(readlink -- "$link")" = "$src" ] || fail "Ya existe otra unidad systemd para el puerto HCR $p."
  elif [ -e "$link" ]; then
    fail "Ya existe una unidad systemd ajena: $link"
  fi
}

render_extra_unit() {
  local p="$1" t="$2" f="$3" d="$4" listener_count="${5:-$(managed_listener_count)}" tls_args="" src
  calculate_autotune "$listener_count"
  src="$(extra_unit_source_path "$p")"
  if [ "$t" = "tls" ] || [ "$t" = "auto" ]; then
    tls_args=" --tls-cert ${TLS_CERT_PATH} --tls-key ${TLS_KEY_PATH}"
  fi
  TEMP_UNIT="$(mktemp "${SCRIPT_DIR}/.hcr-extra-${p}.XXXXXX.service")" || { fail "No se pudo crear la unidad temporal para TCP $p."; return 1; }
  chmod 0600 "$TEMP_UNIT" || { fail "No se pudieron aplicar permisos a la unidad temporal TCP $p."; return 1; }
  cat > "$TEMP_UNIT" <<EOF
[Unit]
Description=SpeiGo HCR relay extra TCP ${p}
Documentation=file:${SCRIPT_DIR}/README.md
Wants=network-online.target
After=network-online.target ssh.service sshd.service
StartLimitIntervalSec=60
StartLimitBurst=10

[Service]
Type=exec
User=root
Group=root
WorkingDirectory=${SCRIPT_DIR}
ExecStart=${BINARY_PATH} --listen :${p} --target 127.0.0.1:22 --transport ${t}${tls_args} --max-download-frame ${f} --download-poll-timeout ${d}
Restart=always
RestartSec=2s
TimeoutStopSec=15s
KillSignal=SIGTERM
UMask=0077
NoNewPrivileges=true
CapabilityBoundingSet=
AmbientCapabilities=
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=read-only
ProtectControlGroups=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
RestrictNamespaces=true
MemoryDenyWriteExecute=false
ReadOnlyPaths=${SCRIPT_DIR}
LimitNOFILE=${AT_NOFILE}
LimitCORE=0
TasksMax=${AT_TASKS}
MemoryHigh=${AT_MEMORY_HIGH_MB}M
MemoryMax=${AT_MEMORY_MAX_MB}M
StandardOutput=journal
StandardError=journal
SyslogIdentifier=hcr-server-extra-${p}

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "$TEMP_UNIT" || { fail "No se pudieron aplicar permisos a la unidad TCP $p."; return 1; }
  # systemd-analyze puede imprimir warnings de unidades AJENAS ya instaladas
  # (como BADVPN). systemctl + listener TCP son la validación real de este HCR.
  systemd-analyze verify "$TEMP_UNIT" >/dev/null 2>&1 || true
  mv -f -- "$TEMP_UNIT" "$src" || { fail "No se pudo instalar la unidad systemd extra TCP $p."; return 1; }
  TEMP_UNIT=""
}

show_extra_failure_diagnostics() {
  local p="$1" svc
  svc="$(extra_service_name "$p").service"
  printf '%b[DIAGNÓSTICO]%b Estado de %s:\n' "$C_GOLD" "$C_RESET" "$svc" >&2
  systemctl status --no-pager --full "$svc" 2>/dev/null | sed -n '1,18p' >&2 || true
  printf '%b[DIAGNÓSTICO]%b Últimas líneas del journal:\n' "$C_GOLD" "$C_RESET" >&2
  journalctl -u "$svc" -n 18 --no-pager 2>/dev/null >&2 || true
}

verify_extra_health() {
  local p="$1" svc pid="" last_pid="" stable=0 i
  svc="$(extra_service_name "$p").service"

  # Espera de asentamiento: el listener debe estar active, tener PID válido y
  # escuchar realmente en TCP p durante 3 comprobaciones consecutivas con el
  # mismo PID. Esto evita tanto falsos OK como falsos errores por arranque.
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
      pid="$(systemctl show --property=MainPID --value "$svc" 2>/dev/null || true)"
      if [[ "$pid" =~ ^[1-9][0-9]*$ ]] && port_has_listener "$p"; then
        if [ "$pid" = "$last_pid" ]; then
          stable=$((stable + 1))
        else
          last_pid="$pid"
          stable=1
        fi
        [ "$stable" -ge 3 ] && return 0
      else
        stable=0
        last_pid=""
      fi
    else
      stable=0
      last_pid=""
    fi
    sleep 1
  done

  fail "El listener HCR extra TCP $p no logró permanecer activo y escuchando de forma estable."
  show_extra_failure_diagnostics "$p"
  return 1
}

cleanup_failed_extra_install() {
  local p="$1" svc src link
  svc="$(extra_service_name "$p")"
  src="$(extra_unit_source_path "$p")"
  link="$(extra_unit_link_path "$p")"
  systemctl disable --now "${svc}.service" >/dev/null 2>&1 || true
  if [ -L "$link" ] && [ "$(readlink -- "$link" 2>/dev/null || true)" = "$src" ]; then
    rm -f -- "$link"
  fi
  rm -f -- "$src"
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl reset-failed "${svc}.service" >/dev/null 2>&1 || true
}

retune_all_services() {
  local count="${1:-$(managed_listener_count)}" p t f d
  [[ "$count" =~ ^[1-9][0-9]*$ ]] || count=1
  calculate_autotune "$count"

  if [ -L "$UNIT_LINK_PATH" ] || [ -f "$UNIT_SOURCE_PATH" ]; then
    load_state
    render_unit "$count" || return 1
    mv -f -- "$TEMP_UNIT" "$UNIT_SOURCE_PATH" || { fail "No se pudo actualizar AUTO-TUNE del HCR principal."; return 1; }
    TEMP_UNIT=""
  fi
  if [ -f "$EXTRA_STATE_PATH" ]; then
    while read -r p t f d; do
      validate_port "${p:-}" || continue
      validate_transport "${t:-}" || continue
      validate_frame "${f:-}" || continue
      validate_timeout "${d:-}" || continue
      render_extra_unit "$p" "$t" "$f" "$d" "$count" || return 1
    done < "$EXTRA_STATE_PATH"
  fi

  systemctl daemon-reload >/dev/null 2>&1 || { fail "systemd no pudo aplicar AUTO-TUNE."; return 1; }

  if [ -L "$UNIT_LINK_PATH" ] || [ -f "$UNIT_SOURCE_PATH" ]; then
    systemctl restart "${SERVICE_NAME}.service" || { fail "No se pudo reiniciar HCR principal tras AUTO-TUNE."; return 1; }
    verify_service_health || return 1
  fi
  if [ -f "$EXTRA_STATE_PATH" ]; then
    while read -r p t f d; do
      validate_port "${p:-}" || continue
      systemctl restart "$(extra_service_name "$p").service" || { fail "No se pudo reiniciar HCR extra TCP $p tras AUTO-TUNE."; return 1; }
      verify_extra_health "$p" || return 1
    done < "$EXTRA_STATE_PATH"
  fi

  calculate_autotune "$count"
  save_autotune_state
  return 0
}

manual_autotune() {
  service_is_installed || { fail "HCR principal aún no está instalado."; return 1; }
  local count
  count="$(managed_listener_count)"
  printf 'Recalculando AUTO-TUNE con CPU/RAM actuales y %s listener(s)...\n' "$count"
  if ! retune_all_services "$count"; then
    printf '%b[ERROR]%b AUTO-TUNE no pudo aplicarse completamente. Revisa Estado/Logs.\n' "$C_RED" "$C_RESET"
    return 1
  fi
  printf '%b[OK]%b AUTO-TUNE aplicado y listeners validados.\n' "$C_GREEN" "$C_RESET"
  show_autotune_summary "$count"
}

install_extra_service() {
  local p="$1" t="$2" f="$3" d="$4" planned_count="${5:-$(( $(managed_listener_count) + 1 ))}" svc src link
  validate_port "$p" || { fail "Puerto extra inválido: $p"; return 1; }
  validate_transport "$t" || { fail "Transport extra inválido: $t"; return 1; }
  validate_frame "$f" || { fail "Frame extra inválido: $f"; return 1; }
  validate_timeout "$d" || { fail "Poll extra inválido: $d"; return 1; }
  validate_secure_directory || return 1
  validate_root_file true "Manager" "$SCRIPT_PATH" || return 1
  validate_root_file true "Binario HCR" "$BINARY_PATH" || return 1
  validate_binary_identity || return 1
  if [ "$t" = "tls" ] || [ "$t" = "auto" ]; then validate_tls_pair || return 1; fi
  validate_extra_unit_link "$p" || return 1

  svc="$(extra_service_name "$p")"
  src="$(extra_unit_source_path "$p")"
  link="$(extra_unit_link_path "$p")"

  render_extra_unit "$p" "$t" "$f" "$d" "$planned_count" || return 1
  if [ ! -L "$link" ]; then
    ln -s -- "$src" "$link" || { fail "No se pudo enlazar la unidad extra TCP $p."; cleanup_failed_extra_install "$p"; return 1; }
  fi
  systemctl daemon-reload || { fail "systemd no pudo recargar unidades para TCP $p."; cleanup_failed_extra_install "$p"; return 1; }
  systemctl enable "${svc}.service" >/dev/null || { fail "No se pudo habilitar ${svc}.service."; cleanup_failed_extra_install "$p"; return 1; }
  systemctl reset-failed "${svc}.service" >/dev/null 2>&1 || true

  if ! systemctl restart "${svc}.service"; then
    fail "El listener HCR extra TCP $p no pudo iniciar."
    show_extra_failure_diagnostics "$p"
    cleanup_failed_extra_install "$p"
    return 1
  fi
  if ! verify_extra_health "$p"; then
    cleanup_failed_extra_install "$p"
    return 1
  fi
  if ! extra_state_add "$p" "$t" "$f" "$d"; then
    fail "El listener TCP $p inició, pero no se pudo guardar su estado."
    cleanup_failed_extra_install "$p"
    return 1
  fi
  return 0
}

remove_extra_service() {
  local p="$1" close_fw="${2:-true}" svc src link
  extra_port_exists "$p" || { fail "El puerto HCR extra $p no está registrado."; return 1; }
  svc="$(extra_service_name "$p")"
  src="$(extra_unit_source_path "$p")"
  link="$(extra_unit_link_path "$p")"
  systemctl disable --now "${svc}.service" >/dev/null 2>&1 || true
  if [ -L "$link" ] && [ "$(readlink -- "$link")" = "$src" ]; then rm -f -- "$link"; fi
  rm -f -- "$src"
  systemctl daemon-reload
  systemctl reset-failed "${svc}.service" >/dev/null 2>&1 || true
  extra_state_remove "$p"
  if [ "$close_fw" = "true" ] && [ -f "$FIREWALL_STATE_PATH" ] && grep -qx "$p" "$FIREWALL_STATE_PATH" 2>/dev/null; then
    firewall_close "$p" || true
  fi
}

show_extra_ports() {
  local found="false" p t f d state color
  printf ' Puertos HCR adicionales:\n'
  if [ -f "$EXTRA_STATE_PATH" ]; then
    while read -r p t f d; do
      validate_port "${p:-}" || continue
      validate_transport "${t:-}" || continue
      validate_frame "${f:-}" || continue
      validate_timeout "${d:-}" || continue
      found="true"; state="OFF"; color="$C_RED"
      if extra_service_is_active "$p"; then state="ON"; color="$C_GREEN"; fi
      printf '   - TCP %b%s%b | %b%s%b | %s | Frame %s | Poll %s\n' "$C_CYAN" "$p" "$C_RESET" "$color" "$state" "$C_RESET" "$t" "$f" "$d"
    done < "$EXTRA_STATE_PATH"
  fi
  [ "$found" = "true" ] || printf '   - Ninguno\n'
}

add_extra_port_menu() {
  service_is_installed || { fail "Instala primero el HCR principal con la opción 1 o 2."; return 1; }
  load_state
  local main_port="$PORT" p="" inherit="" et="$TRANSPORT" ef="$MAX_DOWNLOAD_FRAME" ed="$DOWNLOAD_POLL_TIMEOUT" value="" old_count planned_count
  prompt_read p "Nuevo puerto HCR adicional: " || return 1
  validate_port "$p" || { fail "Puerto inválido."; return 1; }
  p="$((10#$p))"
  [ "$p" != "$main_port" ] || { fail "TCP $p ya es el puerto HCR principal."; return 1; }
  if extra_port_exists "$p"; then
    if extra_service_is_active "$p" && port_has_listener "$p"; then
      fail "TCP $p ya está registrado y funcionando como puerto HCR adicional."
      return 1
    fi
    # Recuperación específica para registros fantasma creados por v1.4.0:
    # si estaba registrado pero no existe un listener sano, limpiar y recrear.
    printf '%b[REPARANDO]%b Registro HCR extra TCP %s incompleto/antiguo; se recreará.\n' "$C_GOLD" "$C_RESET" "$p"
    cleanup_failed_extra_install "$p"
    extra_state_remove "$p"
  fi
  if port_has_listener "$p"; then
    fail "TCP $p ya está ocupado por otro listener. Elige otro puerto."
    return 1
  fi
  prompt_read inherit "¿Usar el mismo perfil del HCR principal ($TRANSPORT, Frame $MAX_DOWNLOAD_FRAME, Poll $DOWNLOAD_POLL_TIMEOUT)? [S/n]: " || return 1
  case "$inherit" in
    n|N|no|NO)
      choose_transport || return 1; et="$TRANSPORT"
      choose_frame || return 1; ef="$MAX_DOWNLOAD_FRAME"
      prompt_read value "DOWNLOAD_POLL_TIMEOUT [${DEFAULT_DOWNLOAD_POLL_TIMEOUT}]: " || return 1
      if [ -n "$value" ]; then validate_timeout "$value" || { fail "Timeout inválido."; return 1; }; ed="$value"; else ed="$DEFAULT_DOWNLOAD_POLL_TIMEOUT"; fi
      ;;
    *) : ;;
  esac

  old_count="$(managed_listener_count)"
  planned_count=$((old_count + 1))
  if ! install_extra_service "$p" "$et" "$ef" "$ed" "$planned_count"; then
    load_state
    printf '%b[NO CREADO]%b TCP %s no se registró como listener HCR adicional.\n' "$C_RED" "$C_RESET" "$p"
    return 1
  fi

  printf '%b[AUTO-TUNE]%b Repartiendo recursos entre %s listeners HCR...\n' "$C_GOLD" "$C_RESET" "$planned_count"
  if ! retune_all_services "$planned_count"; then
    printf '%b[ROLLBACK]%b El nuevo puerto inició, pero AUTO-TUNE no validó el conjunto. Se elimina TCP %s.\n' "$C_RED" "$C_RESET" "$p"
    remove_extra_service "$p" false || true
    retune_all_services "$old_count" || true
    load_state
    return 1
  fi

  firewall_open "$p" || true
  load_state
  printf '%b[OK]%b Listener HCR adicional TCP %s creado, estable, escuchando y AUTO-TUNED.\n' "$C_GREEN" "$C_RESET" "$p"
}

remove_extra_port_menu() {
  local p=""
  show_extra_ports
  [ -f "$EXTRA_STATE_PATH" ] || return 0
  prompt_read p "Puerto HCR adicional a eliminar: " || return 1
  validate_port "$p" || { fail "Puerto inválido."; return 1; }
  p="$((10#$p))"
  extra_port_exists "$p" || { fail "TCP $p no es un puerto HCR adicional administrado por este manager."; return 1; }
  remove_extra_service "$p" true
  local new_count
  new_count="$(managed_listener_count)"
  printf '%b[AUTO-TUNE]%b Recalculando recursos para %s listener(s)...\n' "$C_GOLD" "$C_RESET" "$new_count"
  if ! retune_all_services "$new_count"; then
    printf '%b[AVISO]%b El puerto fue eliminado, pero AUTO-TUNE no pudo revalidar todos los listeners. Usa la opción 14.\n' "$C_GOLD" "$C_RESET"
  fi
  printf '%b[OK]%b Listener HCR adicional TCP %s eliminado. El principal sigue intacto.\n' "$C_GREEN" "$C_RESET" "$p"
}

validate_bundle() {
  validate_secure_directory
  validate_root_file true "Manager" "$SCRIPT_PATH"
  validate_root_file true "Binario HCR" "$BINARY_PATH"
  validate_binary_identity
  if [ "$TRANSPORT" = "tls" ] || [ "$TRANSPORT" = "auto" ]; then validate_tls_pair; fi
}

validate_unit_link() {
  if [ -L "$UNIT_LINK_PATH" ]; then
    [ "$(readlink -- "$UNIT_LINK_PATH")" = "$UNIT_SOURCE_PATH" ] || fail "Ya existe otro ${SERVICE_NAME}.service administrado desde otra ruta."
  elif [ -e "$UNIT_LINK_PATH" ]; then
    fail "Ya existe una unidad systemd ajena: $UNIT_LINK_PATH"
  fi
}

render_unit() {
  local listener_count="${1:-$(managed_listener_count)}" tls_args=""
  calculate_autotune "$listener_count"
  if [ "$TRANSPORT" = "tls" ] || [ "$TRANSPORT" = "auto" ]; then
    tls_args=" --tls-cert ${TLS_CERT_PATH} --tls-key ${TLS_KEY_PATH}"
  fi
  TEMP_UNIT="$(mktemp "${SCRIPT_DIR}/.${SERVICE_NAME}.XXXXXX.service")"
  chmod 0600 "$TEMP_UNIT"
  cat > "$TEMP_UNIT" <<EOF
[Unit]
Description=SpeiGo HCR relay
Documentation=file:${SCRIPT_DIR}/README.md
Wants=network-online.target
After=network-online.target ssh.service sshd.service
StartLimitIntervalSec=60
StartLimitBurst=10

[Service]
Type=exec
User=root
Group=root
WorkingDirectory=${SCRIPT_DIR}
ExecStart=${BINARY_PATH} --listen :${PORT} --target 127.0.0.1:22 --transport ${TRANSPORT}${tls_args} --max-download-frame ${MAX_DOWNLOAD_FRAME} --download-poll-timeout ${DOWNLOAD_POLL_TIMEOUT}
Restart=always
RestartSec=2s
TimeoutStopSec=15s
KillSignal=SIGTERM
UMask=0077
NoNewPrivileges=true
CapabilityBoundingSet=
AmbientCapabilities=
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=read-only
ProtectControlGroups=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
RestrictNamespaces=true
MemoryDenyWriteExecute=false
ReadOnlyPaths=${SCRIPT_DIR}
LimitNOFILE=${AT_NOFILE}
LimitCORE=0
TasksMax=${AT_TASKS}
MemoryHigh=${AT_MEMORY_HIGH_MB}M
MemoryMax=${AT_MEMORY_MAX_MB}M
StandardOutput=journal
StandardError=journal
SyslogIdentifier=hcr-server

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "$TEMP_UNIT"
  systemd-analyze verify "$TEMP_UNIT" >/dev/null 2>&1 || true
}

verify_service_health() {
  local pid="" last_pid="" stable=0 i
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    if systemctl is-active --quiet "${SERVICE_NAME}.service" 2>/dev/null; then
      pid="$(systemctl show --property=MainPID --value "${SERVICE_NAME}.service" 2>/dev/null || true)"
      if [[ "$pid" =~ ^[1-9][0-9]*$ ]] && port_has_listener "$PORT"; then
        if [ "$pid" = "$last_pid" ]; then stable=$((stable + 1)); else last_pid="$pid"; stable=1; fi
        [ "$stable" -ge 3 ] && return 0
      else
        stable=0; last_pid=""
      fi
    else
      stable=0; last_pid=""
    fi
    sleep 1
  done
  fail "HCR principal no logró permanecer activo y escuchando de forma estable en TCP $PORT."
  systemctl status --no-pager --full "${SERVICE_NAME}.service" 2>/dev/null | sed -n '1,18p' >&2 || true
  journalctl -u "${SERVICE_NAME}.service" -n 18 --no-pager 2>/dev/null >&2 || true
  return 1
}

install_service() {
  validate_port "$PORT" || { fail "Puerto inválido: $PORT"; return 1; }
  validate_transport "$TRANSPORT" || { fail "Transport inválido: $TRANSPORT"; return 1; }
  validate_frame "$MAX_DOWNLOAD_FRAME" || { fail "MAX_DOWNLOAD_FRAME debe estar entre 512 y 16384."; return 1; }
  validate_timeout "$DOWNLOAD_POLL_TIMEOUT" || { fail "DOWNLOAD_POLL_TIMEOUT inválido (ej. 8s)."; return 1; }
  PORT="$((10#$PORT))"; MAX_DOWNLOAD_FRAME="$((10#$MAX_DOWNLOAD_FRAME))"
  if extra_port_exists "$PORT"; then
    fail "TCP $PORT ya pertenece a un listener HCR adicional. Elimina ese extra antes de usarlo como puerto principal."
    return 1
  fi
  validate_bundle || return 1
  validate_unit_link || return 1
  local planned_count
  planned_count=$((1 + $(extra_port_count)))
  render_unit "$planned_count" || return 1
  mv -f -- "$TEMP_UNIT" "$UNIT_SOURCE_PATH" || { fail "No se pudo instalar la unidad principal."; return 1; }
  TEMP_UNIT=""
  if [ ! -L "$UNIT_LINK_PATH" ]; then
    ln -s -- "$UNIT_SOURCE_PATH" "$UNIT_LINK_PATH" || { fail "No se pudo enlazar hcr-server.service."; return 1; }
  fi
  systemctl daemon-reload || { fail "systemd no pudo recargar hcr-server.service."; return 1; }
  systemctl enable "${SERVICE_NAME}.service" >/dev/null || { fail "No se pudo habilitar hcr-server.service."; return 1; }
  systemctl reset-failed "${SERVICE_NAME}.service" >/dev/null 2>&1 || true
  if ! systemctl restart "${SERVICE_NAME}.service"; then
    systemctl status --no-pager --full "${SERVICE_NAME}.service" || true
    fail "HCR no pudo iniciar."
    return 1
  fi
  verify_service_health || return 1
  save_state || { fail "HCR inició, pero no se pudo guardar el estado del manager."; return 1; }
  calculate_autotune "$planned_count"
  save_autotune_state
  if [ "$(extra_port_count)" -gt 0 ]; then
    printf '%b[AUTO-TUNE]%b Rebalanceando HCR principal + extras...\n' "$C_GOLD" "$C_RESET"
    retune_all_services "$planned_count" || return 1
  fi
  return 0
}

service_is_active() { systemctl is-active --quiet "${SERVICE_NAME}.service" 2>/dev/null; }
service_is_installed() { [ -L "$UNIT_LINK_PATH" ] || [ -f "$UNIT_SOURCE_PATH" ]; }

record_firewall_port() {
  local p="$1"
  touch "$FIREWALL_STATE_PATH"; chmod 0600 "$FIREWALL_STATE_PATH"
  grep -qx "$p" "$FIREWALL_STATE_PATH" 2>/dev/null || printf '%s\n' "$p" >> "$FIREWALL_STATE_PATH"
}

forget_firewall_port() {
  local p="$1" tmp
  [ -f "$FIREWALL_STATE_PATH" ] || return 0
  tmp="$(mktemp "${SCRIPT_DIR}/.fw.XXXXXX")"
  grep -vx "$p" "$FIREWALL_STATE_PATH" > "$tmp" || true
  mv -f "$tmp" "$FIREWALL_STATE_PATH"; chmod 0600 "$FIREWALL_STATE_PATH"
}

firewall_open() {
  local p="$1"
  validate_port "$p" || fail "Puerto inválido: $p"
  p="$((10#$p))"
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw allow "${p}/tcp" >/dev/null
    record_firewall_port "$p"
    printf '%b[OK]%b Puerto TCP %s abierto en UFW.\n' "$C_GREEN" "$C_RESET" "$p"
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="${p}/tcp" >/dev/null
    firewall-cmd --reload >/dev/null
    record_firewall_port "$p"
    printf '%b[OK]%b Puerto TCP %s abierto en firewalld.\n' "$C_GREEN" "$C_RESET" "$p"
  else
    printf '%b[INFO]%b No hay UFW/firewalld activo. HCR ya escucha en TCP %s; revisa el firewall del proveedor VPS si aplica.\n' "$C_GOLD" "$C_RESET" "$p"
  fi
}

firewall_close() {
  local p="$1"
  validate_port "$p" || fail "Puerto inválido: $p"
  p="$((10#$p))"
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw --force delete allow "${p}/tcp" >/dev/null 2>&1 || true
    forget_firewall_port "$p"
    printf '%b[OK]%b Regla TCP %s eliminada de UFW.\n' "$C_GREEN" "$C_RESET" "$p"
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --remove-port="${p}/tcp" >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
    forget_firewall_port "$p"
    printf '%b[OK]%b Regla TCP %s eliminada de firewalld.\n' "$C_GREEN" "$C_RESET" "$p"
  else
    printf '%b[INFO]%b No hay UFW/firewalld activo; no se modificó el firewall.\n' "$C_GOLD" "$C_RESET"
  fi
}


uninstall_service() {
  load_state
  local old_port="$PORT" p t f d snapshot=""

  # Primero retirar todos los listeners HCR adicionales administrados.
  if [ -f "$EXTRA_STATE_PATH" ]; then
    snapshot="$(mktemp "${SCRIPT_DIR}/.extra-uninstall.XXXXXX")"
    cp -f "$EXTRA_STATE_PATH" "$snapshot"
    while read -r p t f d; do
      validate_port "${p:-}" || continue
      if extra_port_exists "$p"; then remove_extra_service "$p" true || true; fi
    done < "$snapshot"
    rm -f "$snapshot"
  fi

  if service_is_installed; then
    systemctl disable --now "${SERVICE_NAME}.service" >/dev/null 2>&1 || true
    if [ -L "$UNIT_LINK_PATH" ] && [ "$(readlink -- "$UNIT_LINK_PATH")" = "$UNIT_SOURCE_PATH" ]; then rm -f -- "$UNIT_LINK_PATH"; fi
    rm -f -- "$UNIT_SOURCE_PATH"
    systemctl daemon-reload
    systemctl reset-failed "${SERVICE_NAME}.service" >/dev/null 2>&1 || true
  fi
  rm -f -- "$STATE_PATH" "$EXTRA_STATE_PATH" "$AUTOTUNE_STATE_PATH"
  printf '%b[OK]%b HCR principal y todos los listeners HCR adicionales fueron desinstalados. El binario oficial y el manager se conservaron.\n' "$C_GREEN" "$C_RESET"
  if [ -f "$FIREWALL_STATE_PATH" ] && grep -qx "$old_port" "$FIREWALL_STATE_PATH" 2>/dev/null; then
    firewall_close "$old_port" || true
  fi
}


status_line() {
  load_state
  local svc="OFF" svc_color="$C_RED"
  if service_is_active; then svc="ON"; svc_color="$C_GREEN"; fi
  printf '%b%s%b\n' "$C_GOLD" "$BAR" "$C_RESET"
  printf ' Principal: %b%s%b | Puerto: %b%s%b | Transport: %b%s%b\n' "$svc_color" "$svc" "$C_RESET" "$C_CYAN" "$PORT" "$C_RESET" "$C_CYAN" "$TRANSPORT" "$C_RESET"
  printf ' Rendimiento principal: Frame %b%s%b | Poll %b%s%b\n' "$C_CYAN" "$MAX_DOWNLOAD_FRAME" "$C_RESET" "$C_CYAN" "$DOWNLOAD_POLL_TIMEOUT" "$C_RESET"
  show_extra_ports
  show_autotune_summary "$(managed_listener_count)"
  printf '%b%s%b\n' "$C_GOLD" "$BAR" "$C_RESET"
}


show_menu() {
  clear_screen
  load_state
  printf '%b%s%b\n' "$C_GOLD" "$BAR" "$C_RESET"
  printf '%b      HCR / SPEIGO VPN  -  MENÚ DE INSTALACIONES%b\n' "$C_WHITE" "$C_RESET"
  printf '%b              Manager PRO v%s AUTO-TUNE MULTI-PORT%b\n' "$C_GRAY" "$MANAGER_VERSION" "$C_RESET"
  printf '%b%s%b\n' "$C_GOLD" "$BAR" "$C_RESET"
  printf '  %b[1]%b Instalación rápida HCR Plain :%s  %b[16384 / 8s]%b\n' "$C_CYAN" "$C_RESET" "$DEFAULT_PORT" "$C_GREEN" "$C_RESET"
  printf '  %b[2]%b Instalación personalizada principal (Plain/TLS/Auto)\n' "$C_CYAN" "$C_RESET"
  printf '  %b[3]%b Cambiar puerto HCR principal\n' "$C_CYAN" "$C_RESET"
  printf '  %b[4]%b Cambiar transport HCR principal\n' "$C_CYAN" "$C_RESET"
  printf '  %b[5]%b Agregar puerto HCR adicional %b[LISTENER REAL]%b\n' "$C_CYAN" "$C_RESET" "$C_GREEN" "$C_RESET"
  printf '  %b[6]%b Eliminar puerto HCR adicional\n' "$C_CYAN" "$C_RESET"
  printf '  %b[7]%b Ver puertos HCR activos\n' "$C_CYAN" "$C_RESET"
  printf '  %b[8]%b Abrir puerto TCP solo en firewall\n' "$C_CYAN" "$C_RESET"
  printf '  %b[9]%b Cerrar puerto TCP solo en firewall\n' "$C_CYAN" "$C_RESET"
  printf ' %b[10]%b Estado completo HCR\n' "$C_CYAN" "$C_RESET"
  printf ' %b[11]%b Reiniciar HCR principal + extras\n' "$C_CYAN" "$C_RESET"
  printf ' %b[12]%b Ver registros HCR\n' "$C_CYAN" "$C_RESET"
  printf ' %b[13]%b Desinstalar HCR completo\n' "$C_CYAN" "$C_RESET"
  printf ' %b[14]%b Recalcular AUTO-TUNE CPU/RAM\n' "$C_CYAN" "$C_RESET"
  printf '  %b[0]%b Salir\n' "$C_CYAN" "$C_RESET"
  status_line
}

install_quick() {
  PORT="$DEFAULT_PORT"; TRANSPORT="plain"; MAX_DOWNLOAD_FRAME="$DEFAULT_MAX_DOWNLOAD_FRAME"; DOWNLOAD_POLL_TIMEOUT="$DEFAULT_DOWNLOAD_POLL_TIMEOUT"
  printf '\nInstalando HCR Plain en TCP %s con perfil %s / %s...\n' "$PORT" "$MAX_DOWNLOAD_FRAME" "$DOWNLOAD_POLL_TIMEOUT"
  if ! install_service; then
    printf '%b[ERROR]%b La instalación principal no pasó la comprobación de salud.\n' "$C_RED" "$C_RESET"
    return 1
  fi
  firewall_open "$PORT" || true
  printf '%b[OK]%b HCR instalado, activo y AUTO-TUNED.\n' "$C_GREEN" "$C_RESET"
  show_autotune_summary "$(managed_listener_count)"
}

choose_transport() {
  local opt=""
  printf '\n  [1] plain  - recomendado para SpeiGo HCR Plain\n'
  printf '  [2] tls\n'
  printf '  [3] auto   - acepta Plain y TLS\n'
  prompt_read opt "Transport [1-3]: " || return 1
  case "$opt" in 1) TRANSPORT="plain" ;; 2) TRANSPORT="tls" ;; 3) TRANSPORT="auto" ;; *) fail "Opción inválida." ;; esac
}

choose_frame() {
  local opt="" custom=""
  printf '\n  [1] 16384  Máximo rendimiento / recomendado\n'
  printf '  [2] 12288  Balanceado\n'
  printf '  [3] 8192   Conservador\n'
  printf '  [4] 6144   Perfil anterior / rollback\n'
  printf '  [5] Manual (512-16384)\n'
  prompt_read opt "MAX_DOWNLOAD_FRAME [1-5]: " || return 1
  case "$opt" in
    1) MAX_DOWNLOAD_FRAME="16384" ;; 2) MAX_DOWNLOAD_FRAME="12288" ;; 3) MAX_DOWNLOAD_FRAME="8192" ;; 4) MAX_DOWNLOAD_FRAME="6144" ;;
    5) prompt_read custom "Valor [512-16384]: " || return 1; validate_frame "$custom" || fail "Frame inválido."; MAX_DOWNLOAD_FRAME="$((10#$custom))" ;;
    *) fail "Opción inválida." ;;
  esac
}

custom_install() {
  local value=""
  load_state
  prompt_read value "Puerto HCR [${PORT}]: " || return 1
  [ -n "$value" ] && { validate_port "$value" || { fail "Puerto inválido."; return 1; }; PORT="$((10#$value))"; }
  choose_transport || return 1
  choose_frame || return 1
  prompt_read value "DOWNLOAD_POLL_TIMEOUT [8s]: " || return 1
  [ -n "$value" ] && { validate_timeout "$value" || { fail "Timeout inválido (ej. 8s)."; return 1; }; DOWNLOAD_POLL_TIMEOUT="$value"; } || DOWNLOAD_POLL_TIMEOUT="$DEFAULT_DOWNLOAD_POLL_TIMEOUT"
  if [ "$TRANSPORT" = "tls" ] || [ "$TRANSPORT" = "auto" ]; then
    printf 'TLS requiere fullchain.pem y privkey.pem junto al manager.\n'
  fi
  if ! install_service; then
    printf '%b[ERROR]%b La instalación personalizada no pasó la comprobación de salud.\n' "$C_RED" "$C_RESET"
    return 1
  fi
  firewall_open "$PORT" || true
  printf '%b[OK]%b Instalación personalizada completada.\n' "$C_GREEN" "$C_RESET"
}


change_port() {
  service_is_installed || { fail "HCR principal aún no está instalado."; return 1; }
  load_state
  local old="$PORT" value=""
  prompt_read value "Nuevo puerto HCR principal [actual ${PORT}]: " || return 1
  validate_port "$value" || { fail "Puerto inválido."; return 1; }
  PORT="$((10#$value))"
  [ "$PORT" = "$old" ] && { echo "El puerto principal ya es $PORT."; return 0; }
  if extra_port_exists "$PORT"; then
    fail "TCP $PORT ya pertenece a un listener HCR adicional. Elimina ese extra primero o elige otro puerto."
    PORT="$old"
    return 1
  fi
  if port_has_listener "$PORT"; then
    fail "TCP $PORT ya está ocupado por otro listener."
    PORT="$old"
    return 1
  fi
  if ! install_service; then
    PORT="$old"
    load_state
    printf '%b[ERROR]%b No se cambió el puerto principal porque el nuevo listener no quedó estable.\n' "$C_RED" "$C_RESET"
    return 1
  fi
  firewall_open "$PORT" || true
  printf '%b[OK]%b HCR principal cambió de TCP %s a TCP %s.\n' "$C_GREEN" "$C_RESET" "$old" "$PORT"
  if [ -f "$FIREWALL_STATE_PATH" ] && grep -qx "$old" "$FIREWALL_STATE_PATH" 2>/dev/null; then firewall_close "$old" || true; fi
}

change_transport() {
  service_is_installed || { fail "HCR aún no está instalado."; return 1; }
  load_state
  local old="$TRANSPORT"
  choose_transport || return 1
  [ "$TRANSPORT" = "$old" ] && { echo "El transport ya es $TRANSPORT."; return 0; }
  if ! install_service; then
    TRANSPORT="$old"
    load_state
    printf '%b[ERROR]%b No se cambió el transport porque el servicio no quedó estable.\n' "$C_RED" "$C_RESET"
    return 1
  fi
  printf '%b[OK]%b Transport cambiado: %s -> %s.\n' "$C_GREEN" "$C_RESET" "$old" "$TRANSPORT"
}

change_performance() {
  service_is_installed || { fail "HCR aún no está instalado."; return 1; }
  load_state
  local old_frame="$MAX_DOWNLOAD_FRAME" old_poll="$DOWNLOAD_POLL_TIMEOUT" value=""
  choose_frame || return 1
  prompt_read value "DOWNLOAD_POLL_TIMEOUT [actual ${DOWNLOAD_POLL_TIMEOUT}, recomendado 8s]: " || return 1
  [ -n "$value" ] && { validate_timeout "$value" || { fail "Timeout inválido."; return 1; }; DOWNLOAD_POLL_TIMEOUT="$value"; }
  if ! install_service; then
    MAX_DOWNLOAD_FRAME="$old_frame"
    DOWNLOAD_POLL_TIMEOUT="$old_poll"
    load_state
    printf '%b[ERROR]%b No se aplicó el perfil porque el servicio no quedó estable.\n' "$C_RED" "$C_RESET"
    return 1
  fi
  printf '%b[OK]%b Rendimiento actualizado: Frame %s -> %s | Poll %s -> %s.\n' "$C_GREEN" "$C_RESET" "$old_frame" "$MAX_DOWNLOAD_FRAME" "$old_poll" "$DOWNLOAD_POLL_TIMEOUT"
}

manual_open_port() { local p=""; prompt_read p "Puerto TCP a abrir: " || return 1; firewall_open "$p"; }
manual_close_port() { local p=""; prompt_read p "Puerto TCP a cerrar: " || return 1; firewall_close "$p"; }


show_status() {
  load_state
  printf '\n'; status_line
  printf ' Binario: %s\n' "$("$BINARY_PATH" -version 2>/dev/null || echo desconocido)"
  if service_is_installed; then
    printf '\n%b--- HCR PRINCIPAL ---%b\n' "$C_GOLD" "$C_RESET"
    systemctl status --no-pager --full "${SERVICE_NAME}.service" 2>/dev/null | sed -n '1,12p' || true
  else
    echo ' HCR principal no está instalado.'
  fi
  local p t f d
  if [ -f "$EXTRA_STATE_PATH" ]; then
    while read -r p t f d; do
      validate_port "${p:-}" || continue
      printf '\n%b--- HCR EXTRA TCP %s ---%b\n' "$C_GOLD" "$p" "$C_RESET"
      systemctl status --no-pager --full "$(extra_service_name "$p").service" 2>/dev/null | sed -n '1,10p' || true
    done < "$EXTRA_STATE_PATH"
  fi
}


restart_hcr() {
  service_is_installed || { fail "HCR principal aún no está instalado."; return 1; }
  load_state
  if ! systemctl restart "${SERVICE_NAME}.service"; then
    fail "No se pudo reiniciar HCR principal."
    return 1
  fi
  verify_service_health || return 1

  local p t f d
  if [ -f "$EXTRA_STATE_PATH" ]; then
    while read -r p t f d; do
      validate_port "${p:-}" || continue
      if ! systemctl restart "$(extra_service_name "$p").service"; then
        fail "No se pudo reiniciar HCR extra TCP $p."
        return 1
      fi
      verify_extra_health "$p" || return 1
    done < "$EXTRA_STATE_PATH"
  fi
  printf '%b[OK]%b HCR principal y todos los puertos adicionales fueron reiniciados correctamente.\n' "$C_GREEN" "$C_RESET"
}

show_logs() {
  service_is_installed || { fail "HCR principal aún no está instalado."; return 1; }
  printf '%bÚltimas 80 líneas HCR principal:%b\n' "$C_GOLD" "$C_RESET"
  journalctl -u "${SERVICE_NAME}.service" -n 80 --no-pager || true
  local p t f d
  if [ -f "$EXTRA_STATE_PATH" ]; then
    while read -r p t f d; do
      validate_port "${p:-}" || continue
      printf '\n%bÚltimas 40 líneas HCR extra TCP %s:%b\n' "$C_GOLD" "$p" "$C_RESET"
      journalctl -u "$(extra_service_name "$p").service" -n 40 --no-pager || true
    done < "$EXTRA_STATE_PATH"
  fi
}


confirm_uninstall() {
  local ans=""
  prompt_read ans "¿Desinstalar HCR principal y TODOS los puertos HCR adicionales? [s/N]: " || return 1
  case "$ans" in s|S|si|SI|sí|Sí) uninstall_service ;; *) echo "Cancelado." ;; esac
}


menu_loop() {
  while :; do
    show_menu
    local opt=""
    prompt_read opt "Selecciona una opción: " || return 0
    printf '\n'
    case "$opt" in
      1) install_quick || true ;;
      2) custom_install || true ;;
      3) change_port || true ;;
      4) change_transport || true ;;
      5) add_extra_port_menu || true ;;
      6) remove_extra_port_menu || true ;;
      7) printf '\n'; show_extra_ports ;;
      8) manual_open_port || true ;;
      9) manual_close_port || true ;;
      10) show_status || true ;;
      11) restart_hcr || true ;;
      12) show_logs || true ;;
      13) confirm_uninstall || true ;;
      14) manual_autotune || true ;;
      0) clear_screen; echo "Saliendo de HCR / SPEIGO VPN Manager."; return 0 ;;
      *) printf '%bOpción inválida.%b\n' "$C_RED" "$C_RESET" ;;
    esac
    printf '\n'
    pause_menu
  done
}

parse_cli() {
  if [ "$#" -eq 0 ]; then ACTION="menu"; return 0; fi
  case "$1" in menu|--menu) ACTION="menu"; shift ;; esac
  [ "$ACTION" = "menu" ] && [ "$#" -eq 0 ] && return 0
  ACTION="install"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --port) [ "$#" -ge 2 ] || { fail "--port requiere un valor."; return 1; }; PORT="$2"; shift 2 ;;
      --transport) [ "$#" -ge 2 ] || { fail "--transport requiere un valor."; return 1; }; TRANSPORT="$2"; shift 2 ;;
      --max-download-frame) [ "$#" -ge 2 ] || { fail "--max-download-frame requiere un valor."; return 1; }; MAX_DOWNLOAD_FRAME="$2"; shift 2 ;;
      --download-poll-timeout) [ "$#" -ge 2 ] || { fail "--download-poll-timeout requiere un valor."; return 1; }; DOWNLOAD_POLL_TIMEOUT="$2"; shift 2 ;;
      --uninstall) ACTION="uninstall"; shift ;;
      -h|--help) usage; exit 0 ;;
      *) fail "Opción desconocida: $1"; return 1 ;;
    esac
  done
}

main() {
  parse_cli "$@"
  require_environment
  acquire_install_lock
  case "$ACTION" in
    menu) menu_loop ;;
    uninstall) uninstall_service ;;
    install)
      validate_port "$PORT" || fail "Puerto inválido: $PORT"
      validate_transport "$TRANSPORT" || fail "Transport inválido: $TRANSPORT"
      validate_frame "$MAX_DOWNLOAD_FRAME" || fail "MAX_DOWNLOAD_FRAME inválido."
      validate_timeout "$DOWNLOAD_POLL_TIMEOUT" || fail "DOWNLOAD_POLL_TIMEOUT inválido."
      install_service
      printf '%b[OK]%b HCR instalado: TCP %s | %s | Frame %s | Poll %s\n' "$C_GREEN" "$C_RESET" "$PORT" "$TRANSPORT" "$MAX_DOWNLOAD_FRAME" "$DOWNLOAD_POLL_TIMEOUT"
      show_autotune_summary "$(managed_listener_count)"
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
