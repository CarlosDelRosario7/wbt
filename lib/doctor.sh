#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# wbt - diagnóstico de solo lectura.

DOCTOR_FAILS=0
DOCTOR_WARNS=0

doctor_section() {
    printf '\n%s== %s ==%s\n' "$WBT_BLUE" "$1" "$WBT_NC"
}

doctor_ok() {
    printf '  %sOK%s    %-26s %s\n' "$WBT_GREEN" "$WBT_NC" "$1" "${2:-}"
}

doctor_warn() {
    printf '  %sWARN%s  %-26s %s\n' "$WBT_YELLOW" "$WBT_NC" "$1" "${2:-}"
    DOCTOR_WARNS=$((DOCTOR_WARNS + 1))
}

doctor_fail() {
    printf '  %sFAIL%s  %-26s %s\n' "$WBT_RED" "$WBT_NC" "$1" "${2:-}"
    DOCTOR_FAILS=$((DOCTOR_FAILS + 1))
}

doctor_info() {
    printf '  --    %-26s %s\n' "$1" "${2:-}"
}

doctor_check_deps() {
    local command missing=()
    doctor_section "Dependencias"
    while IFS= read -r command; do
        if wbt_have "$command"; then
            doctor_ok "$command" "$(command -v "$command")"
        else
            doctor_fail "$command" "falta; ejecuta: sudo wbt deps --install"
            missing+=("$command")
        fi
    done < <(deps_required_commands)
    if ((${#missing[@]} == 0)); then
        doctor_ok "dependencias" "completas"
    fi
}

doctor_check_wifi() {
    local iface ssid channel band support
    doctor_section "Wi-Fi y red DIRECT-NS"

    if ! iface="$(wifi_iface)"; then
        doctor_fail "interfaz Wi-Fi" "no encontrada"
        return
    fi
    doctor_ok "interfaz Wi-Fi" "$iface"

    if ! ssid="$(wifi_current_ssid "$iface")"; then
        doctor_warn "SSID" "sin conexión"
        ssid=""
    elif wifi_is_direct_ns "$ssid"; then
        doctor_ok "SSID" "$ssid (DIRECT-NS-*)"
    else
        doctor_warn "SSID" "$ssid (no es DIRECT-NS-*)"
    fi

    if channel="$(wifi_channel "$iface")"; then
        band="$(wifi_band_from_channel "$channel" 2>/dev/null || printf '?')"
        doctor_ok "canal STA" "$channel (${band} GHz)"
    else
        doctor_warn "canal STA" "no disponible"
        channel=""
    fi

    support="$(wifi_ap_sta_support 2>/dev/null || true)"
    case "$support" in
        yes) doctor_ok "AP+STA" "soportado en el mismo phy" ;;
        no) doctor_fail "AP+STA" "el adaptador no lo soporta" ;;
        *) doctor_warn "AP+STA" "no se pudo verificar" ;;
    esac

    if wifi_is_direct_ns "$ssid"; then
        # Con el PPP activo no se sondea el puerto: NetShare atiende una sola
        # conexión y un `nc -z` puede cortar la sesión de pppd.
        if ppp_is_up; then
            doctor_ok "NetShare ${WBT_PPP_PORT}" "enlace PPP activo; sin sondeo"
        elif wbt_tcp_check "$WBT_VPN_HOST" "$WBT_PPP_PORT" 4; then
            doctor_ok "NetShare ${WBT_PPP_PORT}" "responde en ${WBT_VPN_HOST}"
        else
            doctor_fail "NetShare ${WBT_PPP_PORT}" "sin respuesta; revisa NetShare/VPN del teléfono"
        fi
    else
        doctor_info "NetShare ${WBT_PPP_PORT}" "se comprobará al conectar a DIRECT-NS-*"
    fi

    local profiles
    profiles="$(wifi_saved_direct_profiles | paste -sd ', ' - 2>/dev/null || true)"
    if [[ -n "$profiles" ]]; then
        doctor_ok "perfiles guardados" "$profiles"
    else
        doctor_warn "perfiles guardados" "ninguno; conéctate una vez a DIRECT-NS-*"
    fi
}

doctor_check_phone_vpn() {
    doctor_section "Teléfono (ADB, opcional)"
    # shellcheck disable=SC2034  # lo usa usb_adb
    if ! WBT_ADB_BIN="$(usb_find_adb 2>/dev/null)"; then
        doctor_info "ADB" "no instalado; no se puede comprobar la VPN del teléfono"
        return
    fi
    if [[ "$(usb_adb get-state 2>/dev/null || true)" != "device" ]]; then
        doctor_info "ADB" "sin dispositivo autorizado"
        return
    fi
    doctor_ok "ADB" "dispositivo conectado"

    local tun
    tun="$(usb_adb shell 'ip -4 addr show tun0 2>/dev/null' 2>/dev/null || true)"
    if printf '%s' "$tun" | grep -q 'inet '; then
        doctor_fail "VPN del teléfono" "tun0 activa; desactívala o excluye NetShare"
    else
        doctor_ok "VPN del teléfono" "sin tun0 (VPN apagada)"
    fi
}

doctor_check_ppp() {
    local pid ipaddr
    doctor_section "Enlace PPP"

    pid="$(ppp_pid_for_peer | head -n1)"
    if [[ -n "$pid" ]]; then
        doctor_ok "pppd" "pid $pid"
    else
        doctor_warn "pppd" "no está corriendo"
    fi

    if ipaddr="$(wbt_iface_ipv4 "$WBT_PPP_IFACE")"; then
        doctor_ok "$WBT_PPP_IFACE" "$ipaddr"
    else
        doctor_warn "$WBT_PPP_IFACE" "sin IPv4"
    fi

    if wbt_has_default_route "$WBT_PPP_IFACE"; then
        doctor_ok "ruta por defecto" "$WBT_PPP_IFACE"
    else
        doctor_warn "ruta por defecto" "no pasa por $WBT_PPP_IFACE"
    fi

    if wbt_iface_has_ipv4 "$WBT_PPP_IFACE" && wbt_http_check "$WBT_PPP_IFACE"; then
        doctor_ok "salida HTTP" "$WBT_HTTP_CHECK_URL"
    elif wbt_iface_has_ipv4 "$WBT_PPP_IFACE"; then
        doctor_fail "salida HTTP" "falla a través de $WBT_PPP_IFACE"
    else
        doctor_info "salida HTTP" "sin enlace PPP"
    fi

    if wbt_have getent; then
        if getent ahostsv4 example.com >/dev/null 2>&1; then
            doctor_ok "resolución DNS" "$(awk '/^nameserver/ {printf "%s ", $2}' /etc/resolv.conf 2>/dev/null)"
        else
            doctor_fail "resolución DNS" "falla; revisa /etc/resolv.conf"
        fi
    fi
}

doctor_check_hotspot() {
    doctor_section "Hotspot (wifi-hotspot)"
    if ! wbt_have wifi-hotspot; then
        doctor_warn "wifi-hotspot" "no instalado (solo necesario para wbt share)"
        return
    fi
    doctor_ok "wifi-hotspot" "$(command -v wifi-hotspot)"

    if ! share_is_active; then
        doctor_info "hotspot" "detenido"
        return
    fi
    doctor_ok "hotspot" "activo (SSID $(share_ssid_name))"

    local uplink channel sta_channel
    uplink="$(share_uplink)"
    channel="$(share_channel)"
    sta_channel="$(wifi_channel "$(wifi_iface)" 2>/dev/null || true)"

    if [[ "$uplink" == "$WBT_PPP_IFACE" ]]; then
        doctor_ok "uplink del hotspot" "$uplink"
    else
        doctor_fail "uplink del hotspot" "${uplink:-?} (debería ser $WBT_PPP_IFACE)"
    fi
    if [[ -n "$sta_channel" && "$channel" == "$sta_channel" ]]; then
        doctor_ok "canal AP/STA" "$channel"
    elif [[ -n "$sta_channel" ]]; then
        doctor_fail "canal AP/STA" "AP=$channel STA=$sta_channel"
    else
        doctor_warn "canal AP/STA" "sin canal de la STA"
    fi
}

doctor_check_services() {
    doctor_section "Servicios y configuración"
    if ! wbt_is_systemd; then
        doctor_warn "systemd" "no disponible; usa 'wbt watch' en primer plano"
        return
    fi
    local unit state enabled
    for unit in wbt-ppp.service wbt-watch.service; do
        if ! wbt_unit_exists "$unit"; then
            doctor_warn "$unit" "no instalada (ejecuta sudo ./install.sh)"
            continue
        fi
        state="$(systemctl is-active "$unit" 2>/dev/null || true)"
        enabled="$(systemctl is-enabled "$unit" 2>/dev/null || true)"
        if [[ "$state" == "active" ]]; then
            doctor_ok "$unit" "active, $enabled"
        elif [[ "$enabled" == "disabled" ]]; then
            doctor_info "$unit" "detenido (arranque manual)"
        else
            doctor_warn "$unit" "$state, $enabled"
        fi
    done

    if [[ -r "$WBT_CONFIG_FILE" ]]; then
        doctor_ok "configuración" "$WBT_CONFIG_FILE"
    else
        doctor_info "configuración" "$WBT_CONFIG_FILE (usando valores por defecto)"
    fi
}

doctor_run() {
    printf 'wbt %s - diagnóstico\n' "$WBT_VERSION"
    printf 'Fecha: %s | Usuario: %s | Root: %s\n' \
        "$(date '+%F %T')" "$(wbt_real_user)" \
        "$([[ ${EUID:-$(id -u)} -eq 0 ]] && printf 'sí' || printf 'no')"

    doctor_check_deps
    doctor_check_wifi
    doctor_check_phone_vpn
    doctor_check_ppp
    doctor_check_hotspot
    doctor_check_services

    printf '\nResumen: %s fallo(s), %s advertencia(s).\n' \
        "$DOCTOR_FAILS" "$DOCTOR_WARNS"
    if ((DOCTOR_FAILS > 0)); then
        printf 'Revisa los FAIL antes de usar wbt.\n'
        return 1
    fi
    printf 'Todo lo esencial parece correcto.\n'
    return 0
}
