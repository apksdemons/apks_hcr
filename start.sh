#!/usr/bin/env bash
set -Eeuo pipefail

# SpeiGo HCR - One-command launcher
# Repository: https://github.com/apksdemons/apks_hcr

REPO="apksdemons/apks_hcr"
BRANCH="main"
RAW_BASE="https://raw.githubusercontent.com/${REPO}/refs/heads/${BRANCH}"
INSTALL_DIR="/opt/speigo-hcr"

say() {
  printf '%s\n' "$*"
}

fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

[ "$(uname -s)" = "Linux" ] || fail "Este launcher solo soporta Linux."

case "$(uname -m)" in
  x86_64|amd64) ;;
  *) fail "Este bundle contiene hcr-server amd64. Arquitectura detectada: $(uname -m)" ;;
esac

command -v curl >/dev/null 2>&1 || fail "Falta curl. Instálalo y vuelve a ejecutar el comando."
command -v mktemp >/dev/null 2>&1 || fail "Falta mktemp."
command -v install >/dev/null 2>&1 || fail "Falta el comando install (coreutils)."

if [ "$(id -u)" -eq 0 ]; then
  SUDO=()
else
  command -v sudo >/dev/null 2>&1 || fail "Ejecuta como root o instala sudo."
  sudo -v || fail "No se pudo obtener acceso sudo."
  SUDO=(sudo)
fi

TMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf -- "${TMP_DIR}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

say "=x=x=x=x=x=x=x=x=x=x=x=x=x=x=x=x=x=x=x=x="
say "          HCR / SPEIGO VPN - INSTALADOR RÁPIDO"
say "=x=x=x=x=x=x=x=x=x=x=x=x=x=x=x=x=x=x=x=x="
say "Descargando archivos oficiales desde GitHub..."

curl -fL --retry 3 --connect-timeout 15 \
  "${RAW_BASE}/install.sh" -o "${TMP_DIR}/install.sh" || fail "No se pudo descargar install.sh"

curl -fL --retry 3 --connect-timeout 15 \
  "${RAW_BASE}/hcr-server" -o "${TMP_DIR}/hcr-server" || fail "No se pudo descargar hcr-server"

# README es útil porque la unidad systemd generada lo referencia como documentación.
if ! curl -fL --retry 2 --connect-timeout 15 \
  "${RAW_BASE}/README.md" -o "${TMP_DIR}/README.md"; then
  printf '# HCR / SpeiGo VPN\n' > "${TMP_DIR}/README.md"
fi

[ -s "${TMP_DIR}/install.sh" ] || fail "install.sh descargado está vacío."
[ -s "${TMP_DIR}/hcr-server" ] || fail "hcr-server descargado está vacío."

"${SUDO[@]}" mkdir -p "${INSTALL_DIR}"
"${SUDO[@]}" chown root:root "${INSTALL_DIR}"
"${SUDO[@]}" chmod 0755 "${INSTALL_DIR}"

"${SUDO[@]}" install -o root -g root -m 0700 "${TMP_DIR}/install.sh" "${INSTALL_DIR}/install.sh"
"${SUDO[@]}" install -o root -g root -m 0700 "${TMP_DIR}/hcr-server" "${INSTALL_DIR}/hcr-server"
"${SUDO[@]}" install -o root -g root -m 0644 "${TMP_DIR}/README.md" "${INSTALL_DIR}/README.md"

say "Archivos actualizados en ${INSTALL_DIR}"
say "Abriendo menú profesional..."
say ""

exec "${SUDO[@]}" "${INSTALL_DIR}/install.sh" menu
