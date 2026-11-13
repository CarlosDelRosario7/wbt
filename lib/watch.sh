#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# wbt - watchdog de salud del enlace NetShare/PPP y del hotspot.

WBT_WATCH_GRACE="${WBT_WATCH_GRACE:-45}"
WBT_WATCH_RESTART_GRACE="${WBT_WATCH_RESTART_GRACE:-60}"

WBT_WATCH_HOTSPOT_FILE="${WBT_RUN_DIR}/watch.hotspot"
WBT_WATCH_FAILS_FILE="${WBT_RUN_DIR}/watch.fails"
WBT_WATCH_LAST_RESTART="${WBT_RUN_DIR}/watch.last-restart"
WBT_WATCH_LAST_SHARE="${WBT_RUN_DIR}/watch.last-share"
WBT_WATCH_START_FILE="${WBT_RUN_DIR}/watch.start"

watch_read_int() {
    local file="$1" default="${2:-0}" value=""
    [[ -r "$file" ]] && value="$(cat "$file" 2>/dev/null || true)"
    [[ "$value" =~ ^[0-9]+$ ]] || value="$default"
    printf '%s\n' "$value"
}

watch_write_int() {
    local file="$1" value="$2"
    wbt_run_dir
    printf '%s\n' "$value" >"$file" 2>/dev/null || true
}

watch_mark() {
    local file="$1"
    watch_write_int "$file" "$(wbt_now)"
}

watch_cooldown_ok() {
    local file="$1" seconds="$2" last now
    [[ -r "$file" ]] || return 0
    last="$(watch_read_int "$file" 0)"
    now="$(wbt_now)"
    ((now - last >= seconds))
}

watch_in_grace() {
    local seconds="$1" start now
    start="$(watch_read_int "$WBT_WATCH_START_FILE" 0)"
    now="$(wbt_now)"
    ((start > 0 && now - start < seconds))
}

# Comprueba que ppp0 tenga IP, ruta por defecto y salida HTTP real.
watch_ppp_health() {
    if ! wbt_iface_has_ipv4 "$WBT_PPP_IFACE"; then
        wbt_warn "Salud: ${WBT_PPP_IFACE} no tiene IPv4."
        return 1
    fi
    if ! wbt_has_default_route "$WBT_PPP_IFACE"; then
        wbt_warn "Salud: no hay ruta por defecto por ${WBT_PPP_IFACE}."
        return 1
    fi
    # NetworkManager puede reescribir resolv.conf al recargar el hotspot.
    wbt_fix_dns
    if ! wbt_http_check "$WBT_PPP_IFACE"; then
        wbt_warn "Salud: ${WBT_PPP_IFACE} no pasa la prueba HTTP (${WBT_HTTP_CHECK_URL})."
        return 1
    fi
    return 0
}

# Detecta el arranque/parada del hotspot y corrige uplink/canal si hace falta.
watch_hotspot_tick() {
    local active=0 previous=0 just_started=0
    local sta_channel=""

    if share_is_active; then
        active=1
    fi
    previous="$(watch_read_int "$WBT_WATCH_HOTSPOT_FILE" 0)"

    if ((active == 1 && previous == 0)); then
        just_started=1
        wbt_log "Hotspot detectado; se vigilará el enlace PPP."
        wbt_run_dir
        : >"$WBT_SHARE_FLAG"
    elif ((active == 0 && previous == 1)); then
        wbt_log "Hotspot detenido."
        rm -f "$WBT_SHARE_FLAG"
    fi
    watch_write_int "$WBT_WATCH_HOTSPOT_FILE" "$active"

    if ((active == 0)); then
        return 0
    fi

    # Si el hotspot usa otra interfaz o un canal distinto al de la STA,
    # hostapd puede fallar o el NAT no salir por ppp0. Se reconfigura.
    sta_channel="$(wifi_channel "$(wifi_iface)" 2>/dev/null || true)"
    if share_needs_reconfigure "$sta_channel"; then
        if ! watch_cooldown_ok "$WBT_WATCH_LAST_SHARE" "$WBT_WATCH_COOLDOWN"; then
            return 0
        fi
        wbt_log "Hotspot con uplink/canal incorrecto (uplink=$(share_uplink), canal=$(share_channel), STA=${sta_channel:-?}); reconfigurando ..."
        if share_restart; then
            watch_mark "$WBT_WATCH_LAST_SHARE"
        else
            wbt_warn "No se pudo reconfigurar el hotspot; se reintentará."
        fi
    fi

    if ((just_started == 1)); then
        wbt_log "Hotspot listo con uplink ${WBT_PPP_IFACE} y canal ${sta_channel:-?}."
    fi
    return 0
}

watch_recover() {
    if ! wbt_is_systemd; then
        wbt_err "No hay systemd: no puedo reiniciar wbt-ppp automáticamente."
        return 1
    fi
    if ! wbt_unit_exists wbt-ppp.service; then
        wbt_err "La unidad wbt-ppp.service no está instalada."
        return 1
    fi
    if [[ "$(systemctl is-enabled wbt-ppp.service 2>/dev/null || true)" == "masked" ]]; then
        wbt_err "wbt-ppp.service está enmascarado; no se puede reiniciar."
        return 1
    fi
    wbt_log "Reiniciando wbt-ppp.service ..."
    systemctl reset-failed wbt-ppp.service >/dev/null 2>&1 || true
    if ! systemctl restart wbt-ppp.service; then
        wbt_err "No se pudo reiniciar wbt-ppp.service."
        return 1
    fi
    watch_mark "$WBT_WATCH_LAST_RESTART"
    watch_write_int "$WBT_WATCH_FAILS_FILE" 0
    return 0
}

# Una pasada del watchdog. Devuelve 0 salvo error de configuración grave.
watch_once() {
    local fails=0 max_fails="${WBT_WATCH_FAILS:-2}"
    local just_started=0 previous=0 active=0

    wbt_run_dir

    # Periodo de gracia tras arrancar el watcher o reiniciar el PPP.
    if watch_in_grace "$WBT_WATCH_GRACE"; then
        wbt_log "Watcher en periodo de gracia inicial; esperando a que PPP arranque."
        watch_hotspot_tick
        return 0
    fi
    if ! watch_cooldown_ok "$WBT_WATCH_LAST_RESTART" "$WBT_WATCH_RESTART_GRACE"; then
        wbt_log "Watcher en periodo de gracia tras el último reinicio."
        watch_hotspot_tick
        return 0
    fi

    if share_is_active; then
        active=1
    fi
    previous="$(watch_read_int "$WBT_WATCH_HOTSPOT_FILE" 0)"
    if ((active == 1 && previous == 0)); then
        just_started=1
    fi

    if watch_ppp_health; then
        watch_write_int "$WBT_WATCH_FAILS_FILE" 0
        watch_hotspot_tick
        return 0
    fi

    fails="$(watch_read_int "$WBT_WATCH_FAILS_FILE" 0)"
    fails=$((fails + 1))
    watch_write_int "$WBT_WATCH_FAILS_FILE" "$fails"
    wbt_warn "Comprobación de salud fallida (${fails}/${max_fails})."

    # Si el hotspot acaba de arrancar, no esperamos a la segunda falla: es
    # justo el caso en que el AP impide mantener el enlace.
    if ((just_started == 0 && fails < max_fails)); then
        watch_hotspot_tick
        return 0
    fi

    if ! watch_cooldown_ok "$WBT_WATCH_LAST_RESTART" "$WBT_WATCH_COOLDOWN"; then
        wbt_warn "Enfriamiento activo; no se reinicia todavía."
        watch_hotspot_tick
        return 0
    fi

    if watch_recover; then
        wbt_log "wbt-ppp reiniciado; el hotspot se restaurará desde el propio servicio."
    fi
    return 0
}

watch_status_line() {
    local failures last
    if ! wbt_have systemctl; then
        printf 'systemd no disponible\n'
        return 1
    fi
    if ! wbt_unit_active wbt-watch.service; then
        printf 'detenido\n'
        return 1
    fi
    failures="$(watch_read_int "$WBT_WATCH_FAILS_FILE" 0)"
    last="$(watch_read_int "$WBT_WATCH_LAST_RESTART" 0)"
    if ((last > 0)); then
        printf 'activo; fallos=%s; último reinicio=%s\n' \
            "$failures" "$(date -d "@$last" '+%F %T' 2>/dev/null || printf '%s' "$last")"
    else
        printf 'activo; fallos=%s; sin reinicios\n' "$failures"
    fi
}

watch_loop() {
    local interval="${1:-$WBT_WATCH_INTERVAL}"
    wbt_require_root "watch"
    wbt_run_dir
    watch_write_int "$WBT_WATCH_START_FILE" "$(wbt_now)"
    trap 'wbt_log "Watcher detenido."; exit 0' INT TERM

    wbt_log "Watcher iniciado (intervalo ${interval}s, fallos=${WBT_WATCH_FAILS}, enfriamiento=${WBT_WATCH_COOLDOWN}s)."
    while true; do
        watch_once || true
        sleep "$interval" &
        wait $! 2>/dev/null || true
    done
}
