#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# wbt - integración con wifi-hotspot (proyecto externo, no se modifica).

share_require() {
    if ! wbt_have wifi-hotspot; then
        wbt_err "No se encontró el comando 'wifi-hotspot'."
        wbt_err "wbt share lo necesita para compartir el enlace PPP por Wi-Fi."
        wbt_err "Instálalo desde https://github.com/CarlosDelRosario7/wifi-hotspot"
        wbt_err "o ejecuta: sudo ./install.sh --with-hotspot"
        return 1
    fi
}

# Ejecuta wifi-hotspot sin volcar su banner al journal: la salida puede
# contener la contraseña del AP. Solo se muestra (redactada) si falla.
share_exec() {
    local output rc=0
    output="$(mktemp "${TMPDIR:-/tmp}/wbt-hotspot.XXXXXX")" || return 1
    if "$@" >"$output" 2>&1; then
        rc=0
    else
        rc=$?
        sed -E 's/^([[:space:]]*(Password|Contraseña)[[:space:]]*:).*/\1 ****/' \
            "$output" >&2 || true
        wbt_warn "wifi-hotspot terminó con código ${rc}."
    fi
    rm -f "$output"
    return "$rc"
}

share_json() {
    wifi-hotspot status --json 2>/dev/null || printf '{}\n'
}

share_field() {
    local field="$1" json
    json="$(share_json)"
    printf '%s' "$json" | python3 -c '
import json
import sys

try:
    data = json.load(sys.stdin)
except Exception:
    print("")
    raise SystemExit(0)
value = data.get(sys.argv[1], "")
if isinstance(value, bool):
    print("true" if value else "false")
elif value is None:
    print("")
else:
    print(value)
' "$field" 2>/dev/null
}

share_is_active() {
    local json
    json="$(share_json)"
    printf '%s' "$json" | python3 -c '
import json
import sys

try:
    data = json.load(sys.stdin)
except Exception:
    raise SystemExit(1)
running = data.get("status") == "running" or data.get("alive") is True
raise SystemExit(0 if running else 1)
' 2>/dev/null
}

share_uplink() {
    share_field uplink
}

share_channel() {
    share_field channel
}

share_ssid_name() {
    share_field ssid
}

share_clients_count() {
    local json
    json="$(share_json)"
    printf '%s' "$json" | python3 -c '
import json
import sys

try:
    data = json.load(sys.stdin)
    print(len(data.get("clients") or []))
except Exception:
    print(0)
' 2>/dev/null
}

# Argumentos que se pasan a wifi-hotspot. Función pura para pruebas.
share_build_args() {
    local channel="$1" band="$2" uplink="${3:-$WBT_PPP_IFACE}"
    printf '%s\n' \
        --uplink "$uplink" \
        --channel "$channel" \
        --band "$band"
}

share_needs_reconfigure() {
    local sta_channel="${1:-}" uplink channel
    share_is_active || return 1
    uplink="$(share_uplink)"
    channel="$(share_channel)"
    [[ "$uplink" != "$WBT_PPP_IFACE" ]] && return 0
    if [[ -n "$sta_channel" && "$channel" != "$sta_channel" ]]; then
        return 0
    fi
    return 1
}

share_wait_active() {
    local timeout="${1:-20}" elapsed=0
    while ((elapsed < timeout)); do
        if share_is_active; then
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    return 1
}

# Inicia (o reconfigura) el hotspot con uplink ppp0 y el canal de la STA.
# Uso: share_start [ssid] [password]
share_start() {
    local ssid="${1:-${WBT_SHARE_SSID:-}}"
    local password="${2:-${WBT_SHARE_PASSWORD:-}}"
    local iface channel band uplink current_channel
    local -a args=()

    wbt_require_root "share"
    share_require || return 1
    ppp_is_up || {
        wbt_err "${WBT_PPP_IFACE} no está arriba. Primero: sudo wbt ppp"
        return 1
    }

    iface="$(wifi_iface)" || {
        wbt_err "No encontré la interfaz Wi-Fi."
        return 1
    }
    channel="$(wifi_channel "$iface")" || {
        wbt_err "No pude leer el canal de $iface. ¿Está conectada a DIRECT-NS-*?"
        return 1
    }
    band="$(wifi_band_from_channel "$channel")" || {
        wbt_err "Canal Wi-Fi no válido: $channel."
        return 1
    }

    mapfile -t args < <(share_build_args "$channel" "$band")
    [[ -n "$ssid" ]] && args+=(--ssid "$ssid")
    [[ -n "$password" ]] && args+=(--password "$password")

    if share_is_active; then
        uplink="$(share_uplink)"
        current_channel="$(share_channel)"
        if [[ "$uplink" == "$WBT_PPP_IFACE" && "$current_channel" == "$channel" ]]; then
            wbt_log "El hotspot ya usa ${uplink} y el canal ${channel}; no se toca."
            wbt_run_dir
            : >"$WBT_SHARE_FLAG"
            return 0
        fi
        wbt_log "Reconfigurando hotspot: uplink=${uplink:-?} canal=${current_channel:-?} -> ${WBT_PPP_IFACE} canal=${channel} ..."
        if ! share_exec wifi-hotspot restart "${args[@]}"; then
            wbt_warn "El reinicio directo falló; probando detener y arrancar ..."
            share_exec wifi-hotspot stop >/dev/null 2>&1 || true
            if ! share_exec wifi-hotspot start "${args[@]}"; then
                wbt_err "wifi-hotspot no pudo arrancar con ${WBT_PPP_IFACE} y canal ${channel}."
                return 1
            fi
        fi
    else
        wbt_log "Arrancando hotspot: uplink=${WBT_PPP_IFACE}, canal=${channel} (${band} GHz) ..."
        if ! share_exec wifi-hotspot start "${args[@]}"; then
            wbt_err "wifi-hotspot no pudo arrancar con ${WBT_PPP_IFACE} y canal ${channel}."
            return 1
        fi
    fi

    if ! share_wait_active 20; then
        wbt_err "El hotspot no reporta estado 'running' después de 20 s."
        return 1
    fi

    uplink="$(share_uplink)"
    if [[ "$uplink" != "$WBT_PPP_IFACE" ]]; then
        wbt_warn "wifi-hotspot reporta uplink '${uplink:-?}' en lugar de ${WBT_PPP_IFACE}."
    else
        wbt_log "Hotspot activo: SSID $(share_ssid_name), uplink ${uplink}, canal ${channel}."
    fi

    wbt_run_dir
    : >"$WBT_SHARE_FLAG"
    # wifi-hotspot recarga NetworkManager; reaplicamos el DNS de ppp0.
    wbt_fix_dns
    return 0
}

share_stop() {
    wbt_run_dir
    rm -f "$WBT_SHARE_FLAG"
    if ! wbt_have wifi-hotspot; then
        return 0
    fi
    if share_is_active; then
        wbt_log "Deteniendo el hotspot ..."
        share_exec wifi-hotspot stop >/dev/null 2>&1 || true
    fi
    return 0
}

# Detiene y vuelve a arrancar el hotspot conservando SSID/clave del perfil.
share_restart() {
    local ssid="${1:-${WBT_SHARE_SSID:-}}"
    local password="${2:-${WBT_SHARE_PASSWORD:-}}"
    share_stop
    sleep 1
    share_start "$ssid" "$password"
}

share_status_line() {
    if ! wbt_have wifi-hotspot; then
        printf 'no instalado\n'
        return 1
    fi
    if ! share_is_active; then
        printf 'detenido\n'
        return 1
    fi
    printf 'activo: SSID %s, uplink %s, canal %s, clientes %s\n' \
        "$(share_ssid_name)" "$(share_uplink)" "$(share_channel)" "$(share_clients_count)"
}
