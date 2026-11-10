#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# wbt - Wi-Fi: detección de interfaz, red DIRECT-NS-* y canal de la STA.

# Devuelve la interfaz Wi-Fi principal (excluye la AP y las de P2P).
wifi_iface() {
    if [[ -n "${WBT_WIFI_IFACE:-}" && "${WBT_WIFI_IFACE}" != "auto" ]]; then
        printf '%s\n' "$WBT_WIFI_IFACE"
        return 0
    fi

    local dev=""
    if wbt_have nmcli; then
        dev="$(nmcli -t -f DEVICE,TYPE device status 2>/dev/null \
            | awk -F: '$2 == "wifi" { print $1; exit }')"
    fi
    if [[ -z "$dev" ]] && wbt_have iw; then
        dev="$(iw dev 2>/dev/null \
            | awk '$1 == "Interface" { print $2 }' \
            | grep -vE '^(wifi-ap|p2p)' \
            | head -n1)"
    fi
    [[ -n "$dev" ]] || return 1
    printf '%s\n' "$dev"
}

# SSID actual de la interfaz (NetworkManager primero, iw como respaldo).
wifi_current_ssid() {
    local iface="${1:-$(wifi_iface)}" ssid=""
    [[ -n "$iface" ]] || return 1

    if wbt_have nmcli; then
        ssid="$(nmcli -g GENERAL.CONNECTION device show "$iface" 2>/dev/null || true)"
        [[ "$ssid" == "--" ]] && ssid=""
    fi
    if [[ -z "$ssid" ]] && wbt_have iw; then
        ssid="$(iw dev "$iface" link 2>/dev/null \
            | sed -n 's/^[[:space:]]*SSID: //p' | head -n1)"
    fi
    [[ -n "$ssid" ]] || return 1
    printf '%s\n' "$ssid"
}

wifi_is_direct_ns() {
    [[ "${1:-}" =~ ^DIRECT-NS- ]]
}

# Parser puro (testeable): extrae el canal de la salida de `iw dev X info`.
wifi_channel_from_iw_output() {
    printf '%s\n' "${1:-}" \
        | sed -n 's/.*channel \([0-9][0-9]*\).*/\1/p' \
        | head -n1
}

wifi_channel() {
    local iface="${1:-$(wifi_iface)}" out=""
    [[ -n "$iface" ]] || return 1
    wbt_have iw || return 1
    out="$(iw dev "$iface" info 2>/dev/null || true)"
    local channel
    channel="$(wifi_channel_from_iw_output "$out")"
    [[ -n "$channel" ]] || return 1
    printf '%s\n' "$channel"
}

wifi_frequency() {
    local iface="${1:-$(wifi_iface)}" freq=""
    [[ -n "$iface" ]] || return 1
    wbt_have iw || return 1
    freq="$(iw dev "$iface" link 2>/dev/null \
        | sed -n 's/^[[:space:]]*freq: \([0-9][0-9.]*\).*/\1/p' | head -n1)"
    [[ -n "$freq" ]] || return 1
    printf '%s\n' "${freq%%.*}"
}

wifi_band_from_channel() {
    local channel="${1:-0}"
    [[ "$channel" =~ ^[0-9]+$ ]] || return 1
    if ((channel >= 1 && channel <= 14)); then
        printf '2.4\n'
    elif ((channel > 14)); then
        printf '5\n'
    else
        return 1
    fi
}

wifi_band_from_frequency() {
    local freq="${1:-0}"
    [[ "$freq" =~ ^[0-9]+$ ]] || return 1
    if ((freq > 0 && freq < 3000)); then
        printf '2.4\n'
    elif ((freq >= 4900)); then
        printf '5\n'
    else
        return 1
    fi
}

# ¿El adaptador soporta AP+STA en el mismo phy/canal?
# Imprime yes, no o unknown. Devuelve 0 solo si es yes.
wifi_ap_sta_support() {
    wbt_have iw || {
        printf 'unknown\n'
        return 1
    }
    local out=""
    out="$(iw list 2>/dev/null || true)"
    [[ -n "$out" ]] || {
        printf 'unknown\n'
        return 1
    }
    if printf '%s\n' "$out" \
        | grep -Eq '#\{[[:space:]]*managed[[:space:]]*\}.*#\{[^}]*\bAP\b'; then
        printf 'yes\n'
        return 0
    fi
    if printf '%s\n' "$out" | grep -q 'valid interface combinations'; then
        printf 'no\n'
        return 1
    fi
    printf 'unknown\n'
    return 1
}

# Perfiles de NetworkManager para redes DIRECT-NS-*.
wifi_saved_direct_profiles() {
    wbt_have nmcli || return 0
    nmcli -t -f NAME,TYPE connection show 2>/dev/null \
        | awk -F: '$2 ~ /wireless/ && $1 ~ /^DIRECT-NS-/ { print $1 }'
}

# SSID DIRECT-NS-* más fuerte visible (o vacío).
wifi_scan_direct() {
    local iface="${1:-$(wifi_iface)}"
    [[ -n "$iface" ]] || return 1
    wbt_have nmcli || return 1
    nmcli -t -f SSID,SIGNAL device wifi list ifname "$iface" --rescan yes 2>/dev/null \
        | awk -F: '$1 ~ /^DIRECT-NS-/ { print $2 "\t" $1 }' \
        | sort -rn \
        | awk -F'\t' 'NR == 1 { print $2 }'
}

wifi_profile_exists() {
    local name="$1"
    wbt_have nmcli || return 1
    nmcli -t -f NAME connection show 2>/dev/null | grep -Fxq "$name"
}

wifi_connect_ssid() {
    local ssid="$1" iface="$2"
    [[ -n "$ssid" && -n "$iface" ]] || return 1
    if wifi_profile_exists "$ssid"; then
        nmcli connection up "$ssid" ifname "$iface" >/dev/null 2>&1
    else
        # Las redes Wi-Fi Direct de NetShare suelen ser abiertas. Si tuvieran
        # clave, el usuario debe conectarse una vez para guardar el perfil.
        nmcli device wifi connect "$ssid" ifname "$iface" >/dev/null 2>&1
    fi
}

# Asegura que wlan0 esté conectada a una red DIRECT-NS-*.
# Con el hotspot activo esto puede fallar: el llamador debe detenerlo antes.
wifi_ensure_direct_ns() {
    local iface="${1:-$(wifi_iface)}" ssid="" profile="" best=""
    local elapsed=0 timeout="${2:-60}"

    [[ -n "$iface" ]] || {
        wbt_err "No encontré ninguna interfaz Wi-Fi."
        return 1
    }
    wbt_have nmcli || {
        wbt_err "Se necesita NetworkManager (nmcli) para conectar el Wi-Fi automáticamente."
        return 1
    }

    ssid="$(wifi_current_ssid "$iface" || true)"
    if wifi_is_direct_ns "$ssid"; then
        wbt_log "Wi-Fi ya conectado a $ssid ($iface)."
        return 0
    fi

    wbt_log "Buscando una red DIRECT-NS-* en $iface ..."
    nmcli radio wifi on >/dev/null 2>&1 || true

    while ((elapsed < timeout)); do
        # 1) Perfiles guardados (la clave WPA ya está en NetworkManager).
        while IFS= read -r profile; do
            [[ -n "$profile" ]] || continue
            wbt_log "Probando perfil guardado: $profile"
            if wifi_connect_ssid "$profile" "$iface"; then
                ssid="$(wifi_current_ssid "$iface" || true)"
                if wifi_is_direct_ns "$ssid"; then
                    wbt_log "Conectado a $ssid ($iface)."
                    return 0
                fi
            fi
        done < <(wifi_saved_direct_profiles)

        # 2) Escaneo y conexión (red abierta o perfil con el mismo nombre).
        best="$(wifi_scan_direct "$iface" || true)"
        if [[ -n "$best" ]]; then
            wbt_log "Red encontrada: $best; conectando ..."
            if wifi_connect_ssid "$best" "$iface"; then
                ssid="$(wifi_current_ssid "$iface" || true)"
                if wifi_is_direct_ns "$ssid"; then
                    wbt_log "Conectado a $ssid ($iface)."
                    return 0
                fi
            fi
        fi

        sleep 3
        elapsed=$((elapsed + 3))
    done

    wbt_err "No se pudo conectar a ninguna red DIRECT-NS-* en ${timeout}s."
    wbt_err "Abre NetShare en el teléfono, activa 'Tethering' y, si es la primera vez,"
    wbt_err "conéctate manualmente a DIRECT-NS-* para guardar el perfil."
    return 1
}

# Canal y banda actuales de la STA, con comprobación de errores.
wifi_sta_channel_band() {
    local iface channel band
    iface="$(wifi_iface)" || return 1
    channel="$(wifi_channel "$iface")" || return 1
    band="$(wifi_band_from_channel "$channel")" || return 1
    printf '%s %s\n' "$channel" "$band"
}
