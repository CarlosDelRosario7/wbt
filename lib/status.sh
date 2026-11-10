#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# wbt - estado resumido del enlace y del hotspot.

status_service_line() {
    local unit="$1" state enabled restarts
    if ! wbt_unit_exists "$unit"; then
        printf 'no instalado\n'
        return 1
    fi
    state="$(systemctl is-active "$unit" 2>/dev/null || true)"
    enabled="$(systemctl is-enabled "$unit" 2>/dev/null || true)"
    restarts="$(systemctl show "$unit" -p NRestarts --value 2>/dev/null || true)"
    printf '%s (%s, reinicios: %s)\n' "$state" "$enabled" "${restarts:-?}"
    [[ "$state" == "active" ]]
}

status_run() {
    local full="${1:-}" rc=0 iface ssid channel band ipaddr hotspot
    local http_code="000" http_time="-" public_ip=""

    printf 'wbt %s\n\n' "$WBT_VERSION"

    printf 'Servicios:\n'
    printf '  wbt-ppp:   '
    status_service_line wbt-ppp.service || rc=1
    printf '  wbt-watch: '
    status_service_line wbt-watch.service || rc=1

    printf '\nWi-Fi:\n'
    if iface="$(wifi_iface)"; then
        ssid="$(wifi_current_ssid "$iface" 2>/dev/null || true)"
        channel="$(wifi_channel "$iface" 2>/dev/null || true)"
        band="$(wifi_band_from_channel "$channel" 2>/dev/null || true)"
        printf '  %s: %s' "$iface" "${ssid:-sin conexión}"
        [[ -n "$channel" ]] && printf ', canal %s (%s GHz)' "$channel" "${band:-?}"
        printf '\n'
        if ! wifi_is_direct_ns "$ssid"; then
            printf '  aviso: la STA no está en una red DIRECT-NS-*\n'
        fi
    else
        printf '  sin interfaz Wi-Fi\n'
        rc=1
    fi

    printf '\nPPP:\n'
    if ipaddr="$(wbt_iface_ipv4 "$WBT_PPP_IFACE")"; then
        printf '  %s: %s' "$WBT_PPP_IFACE" "$ipaddr"
        if wbt_has_default_route "$WBT_PPP_IFACE"; then
            printf ', ruta por defecto: sí\n'
        else
            printf ', ruta por defecto: no\n'
            rc=1
        fi
    else
        printf '  %s: sin IPv4\n' "$WBT_PPP_IFACE"
        rc=1
    fi

    printf '\nInternet:\n'
    if wbt_iface_has_ipv4 "$WBT_PPP_IFACE"; then
        local http_info
        http_info="$(
            curl -sS -o /dev/null -w '%{http_code} %{time_total}\n' \
                --interface "$WBT_PPP_IFACE" --connect-timeout 5 --max-time 12 \
                "$WBT_HTTP_CHECK_URL" 2>/dev/null || printf '000 -\n'
        )"
        http_code="${http_info%% *}"
        http_time="${http_info#* }"
        if [[ "$http_code" =~ ^[23][0-9][0-9]$ ]]; then
            printf '  HTTP %s en %ss (%s)\n' "$http_code" "$http_time" "$WBT_HTTP_CHECK_URL"
        else
            printf '  sin salida HTTP (código %s)\n' "$http_code"
            rc=1
        fi
        if [[ "$full" == "--full" ]]; then
            public_ip="$(curl -sS --interface "$WBT_PPP_IFACE" --max-time 10 \
                https://api.ipify.org 2>/dev/null || true)"
            [[ -n "$public_ip" ]] && printf '  IP pública: %s\n' "$public_ip"
        fi
    else
        printf '  sin enlace PPP\n'
        rc=1
    fi

    printf '\nHotspot:\n'
    if ! wbt_have wifi-hotspot; then
        printf '  wifi-hotspot no instalado\n'
    elif share_is_active; then
        hotspot="$(share_status_line)"
        printf '  %s\n' "$hotspot"
        if [[ "$(share_uplink)" != "$WBT_PPP_IFACE" ]]; then
            printf '  aviso: el uplink del hotspot no es %s\n' "$WBT_PPP_IFACE"
            rc=1
        fi
        if [[ -n "$channel" && "$(share_channel)" != "$channel" ]]; then
            printf '  aviso: el canal del AP no coincide con la STA (%s)\n' "$channel"
            rc=1
        fi
    else
        printf '  detenido\n'
    fi

    if wbt_unit_exists wbt-watch.service; then
        printf '\nVigilancia: %s\n' "$(watch_status_line)"
    fi

    return "$rc"
}
