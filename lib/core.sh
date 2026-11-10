#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# wbt - funciones comunes: configuración, logs, privilegios y utilidades.

# ---------------------------------------------------------------------------
# Configuración por defecto. Se puede sobrescribir en /etc/wbt/wbt.conf o con
# variables de entorno (útil para pruebas).
# ---------------------------------------------------------------------------
# shellcheck disable=SC2034  # usado por bin/wbt, status y doctor
WBT_VERSION="0.1.1"
WBT_CONFIG_FILE="${WBT_CONFIG_FILE:-/etc/wbt/wbt.conf}"
WBT_RUN_DIR="${WBT_RUN_DIR:-/run/wbt}"
WBT_STATE_DIR="${WBT_STATE_DIR:-/var/lib/wbt}"
WBT_LOG_FILE="${WBT_LOG_FILE:-/var/log/wbt.log}"

if [[ -r "$WBT_CONFIG_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$WBT_CONFIG_FILE"
fi

WBT_WIFI_IFACE="${WBT_WIFI_IFACE:-auto}"
WBT_PPP_IFACE="${WBT_PPP_IFACE:-ppp0}"
WBT_VPN_HOST="${WBT_VPN_HOST:-192.168.49.1}"
WBT_PPP_PORT="${WBT_PPP_PORT:-8181}"
WBT_PPP_USER="${WBT_PPP_USER:-netshare}"
WBT_PPP_PASS="${WBT_PPP_PASS:-0000}"
WBT_PPP_PEER="${WBT_PPP_PEER:-netshare}"
WBT_PPP_PROXY="${WBT_PPP_PROXY:-${WBT_LIBDIR:-/usr/local/lib/wbt}/netshare_ppp_proxy.py}"
WBT_HTTP_CHECK_URL="${WBT_HTTP_CHECK_URL:-https://example.com}"
WBT_WATCH_INTERVAL="${WBT_WATCH_INTERVAL:-20}"
WBT_WATCH_FAILS="${WBT_WATCH_FAILS:-2}"
WBT_WATCH_COOLDOWN="${WBT_WATCH_COOLDOWN:-90}"
WBT_SHARE_SSID="${WBT_SHARE_SSID:-}"
WBT_SHARE_PASSWORD="${WBT_SHARE_PASSWORD:-}"
WBT_DNS_FALLBACK="${WBT_DNS_FALLBACK:-8.8.8.8 1.1.1.1}"

# shellcheck disable=SC2034  # usado por share/watch
WBT_SHARE_FLAG="${WBT_RUN_DIR}/share-desired"
# shellcheck disable=SC2034  # usado por ppp
WBT_PPP_LOCK="${WBT_RUN_DIR}/ppp.lock"

# ---------------------------------------------------------------------------
# Colores y logs
# ---------------------------------------------------------------------------
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    WBT_RED=$'\033[0;31m'
    WBT_GREEN=$'\033[0;32m'
    WBT_YELLOW=$'\033[1;33m'
    WBT_BLUE=$'\033[0;34m'
    WBT_NC=$'\033[0m'
else
    WBT_RED=""
    WBT_GREEN=""
    WBT_YELLOW=""
    WBT_BLUE=""
    WBT_NC=""
fi

wbt_append_log() {
    [[ -n "${WBT_LOG_FILE:-}" ]] || return 0
    [[ ${EUID:-$(id -u)} -eq 0 ]] || return 0
    {
        printf '[%s] %s\n' "$(date '+%F %T')" "$*" >>"$WBT_LOG_FILE"
    } 2>/dev/null || true
}

wbt_log() {
    printf '%s[wbt]%s %s\n' "$WBT_GREEN" "$WBT_NC" "$*"
    wbt_append_log "[wbt] $*"
}

wbt_warn() {
    printf '%s[wbt WARN]%s %s\n' "$WBT_YELLOW" "$WBT_NC" "$*" >&2
    wbt_append_log "[wbt WARN] $*"
}

wbt_err() {
    printf '%s[wbt ERROR]%s %s\n' "$WBT_RED" "$WBT_NC" "$*" >&2
    wbt_append_log "[wbt ERROR] $*"
}

wbt_die() {
    wbt_err "$*"
    exit 1
}

wbt_info() {
    printf '%s[wbt]%s %s\n' "$WBT_BLUE" "$WBT_NC" "$*"
}

# ---------------------------------------------------------------------------
# Privilegios y entorno
# ---------------------------------------------------------------------------
wbt_require_root() {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        wbt_die "Esta orden necesita root. Usa: sudo wbt $*"
    fi
}

wbt_real_user() {
    local user="${SUDO_USER:-}"
    if [[ -z "$user" && -n "${PKEXEC_UID:-}" ]]; then
        user="$(getent passwd "$PKEXEC_UID" 2>/dev/null | cut -d: -f1)"
    fi
    printf '%s\n' "${user:-${USER:-root}}"
}

wbt_user_home() {
    getent passwd "$1" 2>/dev/null | cut -d: -f6
}

# Ejecuta un comando como el usuario que invocó sudo/pkexec. Se usa para ADB,
# que necesita el servidor y la clave autorizada del usuario (no los de root).
wbt_as_real_user() {
    local user home
    user="$(wbt_real_user)"
    if [[ ${EUID:-$(id -u)} -eq 0 && "$user" != "root" ]]; then
        home="$(wbt_user_home "$user")"
        sudo -u "$user" env HOME="${home:-/home/$user}" "$@"
    else
        "$@"
    fi
}

wbt_is_systemd() {
    [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1
}

wbt_run_dir() {
    if [[ ! -d "$WBT_RUN_DIR" ]]; then
        mkdir -p "$WBT_RUN_DIR" 2>/dev/null || true
    fi
}

# ---------------------------------------------------------------------------
# Utilidades de red
# ---------------------------------------------------------------------------
wbt_have() {
    command -v "$1" >/dev/null 2>&1
}

# Comprueba un puerto TCP. Devuelve 0 si acepta conexiones.
wbt_tcp_check() {
    local host="$1" port="$2" timeout="${3:-3}"
    if wbt_have nc; then
        nc -z -w "$timeout" "$host" "$port" >/dev/null 2>&1
        return
    fi
    timeout "$timeout" bash -c "exec 3<>/dev/tcp/${host}/${port}" 2>/dev/null
}

# HTTP a través de una interfaz concreta. Acepta 2xx y 3xx.
wbt_http_check() {
    local iface="$1" url="${2:-$WBT_HTTP_CHECK_URL}" code
    wbt_have curl || return 1
    code="$(curl -sS -o /dev/null -w '%{http_code}' \
        --interface "$iface" \
        --connect-timeout 5 --max-time 10 \
        "$url" 2>/dev/null)" || return 1
    [[ "$code" =~ ^[23][0-9][0-9]$ ]]
}

# Devuelve la primera interfaz de la ruta por defecto (puede haber varias).
wbt_default_route_dev() {
    ip route show default 2>/dev/null \
        | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit }}'
}

# ¿La interfaz tiene una ruta por defecto?
wbt_has_default_route() {
    ip route show default 2>/dev/null | grep -qE "dev ${1}([[:space:]]|$)"
}

# ¿La interfaz tiene una dirección IPv4?
wbt_iface_has_ipv4() {
    ip -4 addr show dev "$1" 2>/dev/null | grep -q 'inet '
}

wbt_iface_ipv4() {
    ip -4 -o addr show dev "$1" 2>/dev/null \
        | awk '{print $4}' | head -n1
}

# DNS que entrega pppd (usepeerdns) o, si no hay, un fallback público.
wbt_dns_servers() {
    local servers=()
    if [[ -r /etc/ppp/resolv.conf ]]; then
        mapfile -t servers < <(
            awk '/^[[:space:]]*nameserver[[:space:]]+/ { print $2 }' /etc/ppp/resolv.conf \
                | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'
        )
    fi
    if ((${#servers[@]} == 0)); then
        read -r -a servers <<<"$WBT_DNS_FALLBACK"
    fi
    printf '%s\n' "${servers[@]}"
}

# NetworkManager suele dejar /etc/resolv.conf apuntando al DNS del Wi-Fi
# (192.168.49.1), que NetShare puede rechazar. Mientras ppp0 esté arriba,
# usamos el DNS que entregó el propio PPP.
wbt_fix_dns() {
    wbt_iface_has_ipv4 "$WBT_PPP_IFACE" || return 0

    local -a servers=()
    mapfile -t servers < <(wbt_dns_servers)
    ((${#servers[@]} > 0)) || return 0

    if wbt_have resolvectl && systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        resolvectl dns "$WBT_PPP_IFACE" "${servers[@]}" >/dev/null 2>&1 || true
        resolvectl domain "$WBT_PPP_IFACE" '~.' >/dev/null 2>&1 || true
        return 0
    fi

    # No tocar enlaces simbólicos gestionados por systemd-resolved/openresolv.
    if [[ -L /etc/resolv.conf ]]; then
        local target
        target="$(readlink -f /etc/resolv.conf 2>/dev/null || true)"
        case "$target" in
            *systemd/resolve* | *resolvconf*) return 0 ;;
        esac
    fi

    local current="" desired="" server
    [[ -r /etc/resolv.conf ]] && current="$(
        awk '/^nameserver[[:space:]]+/ { printf "%s ", $2 }' /etc/resolv.conf
    )"
    current="${current% }"
    desired="${servers[*]}"
    [[ "$current" == "$desired" ]] && return 0

    wbt_run_dir
    if [[ ! -f "$WBT_RUN_DIR/resolv.conf.bak" ]]; then
        cp -a /etc/resolv.conf "$WBT_RUN_DIR/resolv.conf.bak" 2>/dev/null || true
    fi

    local tmp
    tmp="$(mktemp "$WBT_RUN_DIR/resolv.conf.XXXXXX")"
    {
        printf '# wbt: DNS de NetShare (%s)\n' "$WBT_PPP_IFACE"
        for server in "${servers[@]}"; do
            printf 'nameserver %s\n' "$server"
        done
        printf 'options timeout:2 attempts:2\n'
    } >"$tmp"
    if install -m 0644 "$tmp" /etc/resolv.conf 2>/dev/null; then
        wbt_log "DNS ajustado a ${desired} (el DNS del Wi-Fi no era utilizable)."
    else
        wbt_warn "No se pudo actualizar /etc/resolv.conf."
    fi
    rm -f "$tmp"
    return 0
}

wbt_restore_dns() {
    local backup="$WBT_RUN_DIR/resolv.conf.bak"
    [[ -f "$backup" ]] || return 0
    if head -n1 /etc/resolv.conf 2>/dev/null | grep -q '^# wbt:'; then
        install -m 0644 "$backup" /etc/resolv.conf 2>/dev/null || true
    fi
    rm -f "$backup"
}

# Espera a que exista la interfaz con IP y ruta por defecto.
wbt_wait_iface() {
    local iface="$1" timeout="${2:-60}" elapsed=0
    while ((elapsed < timeout)); do
        if wbt_iface_has_ipv4 "$iface" && wbt_has_default_route "$iface"; then
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    return 1
}

# ---------------------------------------------------------------------------
# systemd
# ---------------------------------------------------------------------------
wbt_unit_exists() {
    wbt_is_systemd || return 1
    systemctl list-unit-files "$1" --no-legend 2>/dev/null | grep -q "^$1"
}

wbt_unit_enabled() {
    wbt_is_systemd || return 1
    systemctl is-enabled --quiet "$1" 2>/dev/null
}

wbt_unit_active() {
    wbt_is_systemd || return 1
    systemctl is-active --quiet "$1" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Varios
# ---------------------------------------------------------------------------
wbt_read_file() {
    [[ -r "$1" ]] && cat "$1" 2>/dev/null || true
}

wbt_now() {
    date +%s
}

wbt_distro_id() {
    local id=""
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        id="$(. /etc/os-release && printf '%s' "${ID:-}")"
    fi
    printf '%s\n' "${id:-unknown}"
}

wbt_distro_like() {
    local like=""
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        like="$(. /etc/os-release && printf '%s' "${ID_LIKE:-}")"
    fi
    printf '%s\n' "$like"
}

wbt_pkg_manager() {
    local id like
    id="$(wbt_distro_id)"
    like="$(wbt_distro_like)"
    case " $id $like " in
        *" debian "* | *" ubuntu "* | *" linuxmint "* | *" kali "* | *" raspbian "* | *" pop "*)
            if wbt_have apt-get; then printf 'apt\n'; return 0; fi
            ;;
        *" fedora "* | *" rhel "* | *" centos "* | *" rocky "* | *" alma "*)
            if wbt_have dnf; then printf 'dnf\n'; return 0; fi
            ;;
        *" arch "* | *" endeavouros "* | *" manjaro "*)
            if wbt_have pacman; then printf 'pacman\n'; return 0; fi
            ;;
        *" opensuse "* | *" suse "* | *" sles "*)
            if wbt_have zypper; then printf 'zypper\n'; return 0; fi
            ;;
    esac
    # Fallback por binario disponible.
    if wbt_have apt-get; then printf 'apt\n'
    elif wbt_have dnf; then printf 'dnf\n'
    elif wbt_have pacman; then printf 'pacman\n'
    elif wbt_have zypper; then printf 'zypper\n'
    else printf 'unknown\n'
    fi
}
