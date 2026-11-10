#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# wbt - enlace PPP con el servidor de NetShare y proxy de reencuadre.

PPPD_PID=""

# Texto del peer PPP. Es una función pura para poder probarla sin root.
ppp_peer_text() {
    local host="$1" port="$2" proxy="${3:-$WBT_PPP_PROXY}"
    cat <<EOF
nodetach
noauth
usepeerdns
mtu 8192
mru 8192
defaultroute
replacedefaultroute
lcp-echo-interval 0
noccp
noipv6
debug
logfd 2
pty "$proxy $host $port"
EOF
}

ppp_proxy_path() {
    printf '%s\n' "$WBT_PPP_PROXY"
}

ppp_proxy_ok() {
    [[ -f "$WBT_PPP_PROXY" ]] || return 1
    [[ -x "$WBT_PPP_PROXY" ]] || return 1
    head -n1 "$WBT_PPP_PROXY" | grep -q 'python'
}

ppp_write_peer() {
    local host="$1" port="$2"
    local peer="/etc/ppp/peers/${WBT_PPP_PEER}"
    local tmp

    [[ ${EUID:-$(id -u)} -eq 0 ]] || {
        wbt_err "Se necesita root para escribir $peer."
        return 1
    }
    ppp_proxy_ok || {
        wbt_err "No encuentro el proxy PPP ejecutable en $WBT_PPP_PROXY."
        wbt_err "Reinstala wbt o revisa WBT_PPP_PROXY en /etc/wbt/wbt.conf."
        return 1
    }

    install -d -m 0755 /etc/ppp/peers
    touch /etc/ppp/options
    tmp="$(mktemp)"
    ppp_peer_text "$host" "$port" >"$tmp"
    install -m 0600 "$tmp" "$peer"
    rm -f "$tmp"
    wbt_log "Peer PPP actualizado: $peer"
}

ppp_preflight() {
    local host="${1:-$WBT_VPN_HOST}" port="${2:-$WBT_PPP_PORT}"
    wbt_tcp_check "$host" "$port" 4
}

ppp_is_up() {
    wbt_iface_has_ipv4 "$WBT_PPP_IFACE" && wbt_has_default_route "$WBT_PPP_IFACE"
}

ppp_pid_for_peer() {
    local pid cmd
    for pid in $(pgrep -x pppd 2>/dev/null || true); do
        [[ -r "/proc/$pid/cmdline" ]] || continue
        cmd="$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null || true)"
        if [[ "$cmd" == *"call ${WBT_PPP_PEER}"* ]]; then
            printf '%s\n' "$pid"
        fi
    done
}

ppp_start_child() {
    local host="$1" port="$2" pppd_bin
    pppd_bin="$(command -v pppd 2>/dev/null || true)"
    [[ -n "$pppd_bin" ]] || pppd_bin="/usr/sbin/pppd"
    [[ -x "$pppd_bin" ]] || {
        wbt_err "No se encontró pppd. Instala el paquete 'ppp'."
        return 1
    }

    "$pppd_bin" user "$WBT_PPP_USER" password "$WBT_PPP_PASS" \
        call "$WBT_PPP_PEER" &
    PPPD_PID=$!
}

ppp_terminate_child() {
    local pid="${PPPD_PID:-}" waited=0
    [[ -n "$pid" ]] || return 0
    kill -0 "$pid" 2>/dev/null || return 0
    wbt_warn "Deteniendo pppd (pid $pid) ..."
    kill -TERM "$pid" 2>/dev/null || true
    while kill -0 "$pid" 2>/dev/null && ((waited < 10)); do
        sleep 1
        waited=$((waited + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
        kill -KILL "$pid" 2>/dev/null || true
    fi
    wait "$pid" 2>/dev/null || true
    PPPD_PID=""
}

wbt_cleanup_hook() {
    local hook="${WBT_CLEANUP_HOOK:-}"
    [[ -n "$hook" ]] || return 0
    WBT_CLEANUP_HOOK=""
    "$hook" || true
}

ppp_on_signal() {
    wbt_warn "Señal recibida; cerrando el enlace PPP ..."
    ppp_terminate_child
    wbt_cleanup_hook
    wbt_restore_dns
    exit 0
}

# Secuencia principal:
#   1. Si el hotspot está activo, se detiene (impide conectar la STA).
#   2. Se conecta wlan0 a DIRECT-NS-*.
#   3. Preflight del puerto 8181 (falla rápido si NetShare/VPN no responde).
#   4. Arranca pppd y espera ppp0.
#   5. Si el hotspot estaba activo, se reactiva con uplink ppp0 y el canal real.
ppp_run_main() {
    local mode="${1:-manual}"
    local host="${2:-$WBT_VPN_HOST}"
    local port="${3:-$WBT_PPP_PORT}"
    local hotspot_was_active=0 rc=0

    wbt_require_root "ppp"
    wbt_run_dir

    if wbt_have flock; then
        exec 9>"$WBT_PPP_LOCK"
        if ! flock -n 9; then
            wbt_die "Ya hay otra instancia de wbt ppp en ejecución (lock $WBT_PPP_LOCK)."
        fi
    fi

    if share_is_active; then
        hotspot_was_active=1
    fi

    if ((hotspot_was_active)) && [[ "$mode" != "usb" ]]; then
        wbt_log "Hotspot activo: se detiene para poder conectar wlan0 a DIRECT-NS-*."
        if ! share_stop; then
            wbt_die "No se pudo detener el hotspot; wlan0 no podrá conectar a DIRECT-NS-*."
        fi
    fi

    if [[ "$mode" != "usb" ]]; then
        if ! wifi_ensure_direct_ns; then
            # 75 evita que systemd entre en un bucle de reinicios.
            exit 75
        fi
    fi

    if ! ppp_preflight "$host" "$port"; then
        wbt_err "NetShare no responde en ${host}:${port}."
        wbt_err "Comprueba que NetShare esté compartiendo y que NO haya una VPN"
        wbt_err "activa en el teléfono (RethinkDNS, Tailscale, etc.)."
        exit 75
    fi

    ppp_write_peer "$host" "$port" || exit 1

    trap ppp_on_signal INT TERM

    wbt_log "Conectando por PPP a ${host}:${port} (usuario: ${WBT_PPP_USER}) ..."
    ppp_start_child "$host" "$port" || exit 1

    if ! wbt_wait_iface "$WBT_PPP_IFACE" 60; then
        wbt_err "${WBT_PPP_IFACE} no apareció con IP y ruta por defecto en 60 s."
        wbt_err "Revisa el log: journalctl -u wbt-ppp -n 80 --no-pager"
        ppp_terminate_child
        exit 1
    fi

    wbt_log "${WBT_PPP_IFACE} arriba: $(wbt_iface_ipv4 "$WBT_PPP_IFACE")"
    wbt_fix_dns

    if ((hotspot_was_active)) && [[ "$mode" != "usb" ]]; then
        if ! share_start; then
            wbt_warn "El enlace PPP está arriba, pero no se pudo reactivar el hotspot."
        fi
        # El reinicio del hotspot recarga NetworkManager y puede reescribir
        # /etc/resolv.conf; se vuelve a aplicar el DNS del PPP.
        wbt_fix_dns
    fi

    set +e
    wait "$PPPD_PID"
    rc=$?
    set -e
    PPPD_PID=""
    wbt_cleanup_hook
    wbt_restore_dns

    if ((rc == 0)); then
        wbt_log "PPP desconectado correctamente."
    else
        wbt_warn "pppd terminó con código $rc."
    fi
    return "$rc"
}

ppp_stop() {
    local pid
    if wbt_unit_active wbt-ppp; then
        wbt_log "Deteniendo el servicio wbt-ppp ..."
        systemctl stop wbt-ppp || true
    fi
    pid="$(ppp_pid_for_peer | head -n1)"
    if [[ -n "$pid" ]]; then
        wbt_log "Deteniendo pppd (pid $pid) ..."
        kill -TERM "$pid" 2>/dev/null || true
        local waited=0
        while kill -0 "$pid" 2>/dev/null && ((waited < 10)); do
            sleep 1
            waited=$((waited + 1))
        done
        kill -KILL "$pid" 2>/dev/null || true
    fi
    wbt_restore_dns
    return 0
}
