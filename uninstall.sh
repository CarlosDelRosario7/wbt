#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# wbt - desinstalador.

set -euo pipefail

PREFIX="/usr/local"
BINDIR=""
LIBDIR=""
SYSTEMD_DIR="${SYSTEMD_DIR:-/etc/systemd/system}"
PURGE=0

usage() {
    cat <<'EOF'
Uso: sudo ./uninstall.sh [opciones]

Opciones:
  --prefix RUTA   Prefijo usado en la instalación (por defecto /usr/local)
  --purge         Elimina también /etc/wbt, /var/log/wbt.log y el peer PPP
  -h, --help      Esta ayuda
EOF
}

while (($#)); do
    case "$1" in
        --prefix) shift; PREFIX="${1:-}" ;;
        --prefix=*) PREFIX="${1#*=}" ;;
        --purge) PURGE=1 ;;
        -h | --help) usage; exit 0 ;;
        *) printf 'Opción desconocida: %s\n' "$1" >&2; exit 2 ;;
    esac
    shift
done

[[ ${EUID:-$(id -u)} -eq 0 ]] || {
    printf 'Ejecuta el desinstalador con sudo.\n' >&2
    exit 1
}

BINDIR="${PREFIX}/bin"
LIBDIR="${PREFIX}/lib/wbt"

if command -v systemctl >/dev/null 2>&1; then
    systemctl stop wbt-watch.service wbt-ppp.service 2>/dev/null || true
    systemctl disable wbt-watch.service wbt-ppp.service 2>/dev/null || true
fi

rm -f "$SYSTEMD_DIR/wbt-ppp.service" "$SYSTEMD_DIR/wbt-watch.service"
if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload
    systemctl reset-failed wbt-ppp.service wbt-watch.service 2>/dev/null || true
fi

rm -f "$BINDIR/wbt"
rm -rf "$LIBDIR"
rm -rf /run/wbt

if ((PURGE)); then
    rm -rf /etc/wbt
    rm -f /var/log/wbt.log
    rm -f /etc/ppp/peers/netshare
    rm -f /usr/local/bin/netshare-ppp-proxy
    printf 'Datos de configuración y logs eliminados.\n'
fi

printf 'wbt desinstalado.\n'
