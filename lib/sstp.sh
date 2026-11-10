#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# wbt - modo SSTP (experimental). Método de Windows con certificado .p12.

WBT_SSTP_PORT="${WBT_SSTP_PORT:-8383}"
WBT_SSTP_USER="${WBT_SSTP_USER:-def}"
WBT_SSTP_PASS="${WBT_SSTP_PASS:-0000}"
WBT_SSTP_P12_PASS="${WBT_SSTP_P12_PASS:-123456}"
WBT_SSTP_P12_FILE="${WBT_SSTP_P12_FILE:-/tmp/netshare.p12}"
WBT_SSTP_CERT_BUNDLE="${WBT_SSTP_CERT_BUNDLE:-/tmp/netshare-certs.pem}"
WBT_SSTP_CERT_DIR="${WBT_SSTP_CERT_DIR:-/tmp/netshare-certs}"
WBT_SSTP_HOST="${WBT_SSTP_HOST:-$WBT_VPN_HOST}"
WBT_SSTP_FORWARD_CERT=0
WBT_SSTP_FORWARD_VPN=0
WBT_SSTP_REDIRECT=0

sstp_require_deps() {
    local missing=() command
    for command in sstpc curl openssl; do
        wbt_have "$command" || missing+=("$command")
    done
    if ((${#missing[@]})); then
        wbt_err "Faltan dependencias para SSTP: ${missing[*]}"
        wbt_err "En Debian/Ubuntu/Kali: sudo apt install sstp-client openssl curl ca-certificates iptables"
        return 1
    fi
    return 0
}

sstp_ca_dir() {
    if [[ -d /usr/local/share/ca-certificates ]]; then
        printf '/usr/local/share/ca-certificates\n'
    elif [[ -d /etc/pki/ca-trust/source/anchors ]]; then
        printf '/etc/pki/ca-trust/source/anchors\n'
    else
        return 1
    fi
}

sstp_update_ca() {
    if wbt_have update-ca-certificates; then
        update-ca-certificates
    elif wbt_have update-ca-trust; then
        update-ca-trust extract
    else
        wbt_warn "No encontré update-ca-certificates ni update-ca-trust."
    fi
}

sstp_cleanup() {
    if ((WBT_SSTP_REDIRECT == 1)); then
        wbt_log "Eliminando la regla de redirección SSTP ..."
        iptables -t nat -D OUTPUT -p tcp -d "$WBT_SSTP_HOST" --dport 443 \
            -j DNAT --to-destination "${WBT_SSTP_HOST}:${WBT_SSTP_PORT}" 2>/dev/null || true
        WBT_SSTP_REDIRECT=0
    fi
    if ((WBT_SSTP_FORWARD_CERT == 1)) && [[ -n "${WBT_ADB_BIN:-}" ]]; then
        usb_adb forward --remove tcp:8181 >/dev/null 2>&1 || true
        WBT_SSTP_FORWARD_CERT=0
    fi
    if ((WBT_SSTP_FORWARD_VPN == 1)) && [[ -n "${WBT_ADB_BIN:-}" ]]; then
        usb_adb forward --remove tcp:443 >/dev/null 2>&1 || true
        WBT_SSTP_FORWARD_VPN=0
    fi
}

sstp_setup_usb() {
    WBT_ADB_BIN="$(usb_find_adb)" || {
        wbt_err "El modo SSTP por USB necesita adb."
        return 1
    }
    usb_adb start-server >/dev/null 2>&1 || true
    if [[ "$(usb_adb get-state 2>/dev/null || true)" != "device" ]]; then
        wbt_err "No hay un dispositivo ADB conectado y autorizado."
        return 1
    fi

    WBT_SSTP_HOST="127.0.0.1"
    wbt_log "SSTP por USB: forward 127.0.0.1:8181 -> teléfono:8181 ..."
    usb_adb forward --remove tcp:8181 >/dev/null 2>&1 || true
    usb_adb forward tcp:8181 tcp:8181 >/dev/null || return 1
    WBT_SSTP_FORWARD_CERT=1

    wbt_log "SSTP por USB: forward 127.0.0.1:443 -> teléfono:${WBT_SSTP_PORT} ..."
    usb_adb forward --remove tcp:443 >/dev/null 2>&1 || true
    usb_adb forward tcp:443 "tcp:${WBT_SSTP_PORT}" >/dev/null || return 1
    WBT_SSTP_FORWARD_VPN=1
    return 0
}

sstp_fetch_cert() {
    local url i port
    local urls=(
        "http://${WBT_SSTP_HOST}:8181/netshare.p12"
        "http://${WBT_SSTP_HOST}:7777/netshare.p12"
    )
    for url in "${urls[@]}"; do
        for ((i = 1; i <= 3; i++)); do
            wbt_log "Descargando certificado .p12 (${i}/3) desde $url ..."
            if curl -fsSL --connect-timeout 5 --max-time 30 \
                -o "$WBT_SSTP_P12_FILE" "$url"; then
                [[ -s "$WBT_SSTP_P12_FILE" ]] && return 0
            fi
            sleep 2
        done
    done

    # Fallback por ADB (localhost), útil cuando la red no enruta al teléfono.
    if WBT_ADB_BIN="$(usb_find_adb 2>/dev/null)"; then
        for port in 8181 7777; do
            usb_adb forward "tcp:${port}" "tcp:${port}" >/dev/null 2>&1 || true
            wbt_log "Intentando descarga vía ADB (puerto ${port}) ..."
            if curl -fsSL --max-time 60 -o "$WBT_SSTP_P12_FILE" \
                "http://127.0.0.1:${port}/netshare.p12"; then
                usb_adb forward --remove "tcp:${port}" >/dev/null 2>&1 || true
                return 0
            fi
            usb_adb forward --remove "tcp:${port}" >/dev/null 2>&1 || true
        done
    fi
    return 1
}

sstp_import_cert() {
    local ca_dir file
    sstp_fetch_cert || {
        wbt_err "No se pudo descargar el certificado .p12 de NetShare."
        return 1
    }
    [[ -s "$WBT_SSTP_P12_FILE" ]] || {
        wbt_err "El archivo .p12 descargado está vacío."
        return 1
    }

    wbt_log "Extrayendo certificados del .p12 ..."
    rm -f "$WBT_SSTP_CERT_BUNDLE"
    if ! openssl pkcs12 -in "$WBT_SSTP_P12_FILE" -nokeys \
        -passin "pass:$WBT_SSTP_P12_PASS" -out "$WBT_SSTP_CERT_BUNDLE" 2>/dev/null; then
        openssl pkcs12 -legacy -in "$WBT_SSTP_P12_FILE" -nokeys \
            -passin "pass:$WBT_SSTP_P12_PASS" -out "$WBT_SSTP_CERT_BUNDLE" 2>/dev/null \
            || {
                wbt_err "No se pudo abrir el .p12 (¿contraseña incorrecta?)."
                return 1
            }
    fi
    grep -q 'BEGIN CERTIFICATE' "$WBT_SSTP_CERT_BUNDLE" || {
        wbt_err "El .p12 no contiene certificados."
        return 1
    }

    ca_dir="$(sstp_ca_dir)" || {
        wbt_err "No encontré el directorio de autoridades del sistema."
        return 1
    }
    rm -rf "$WBT_SSTP_CERT_DIR"
    mkdir -p "$WBT_SSTP_CERT_DIR"
    awk -v dir="$WBT_SSTP_CERT_DIR" '
        /BEGIN CERTIFICATE/ { n++ }
        n > 0 { print > (dir "/cert-" n ".pem") }
    ' "$WBT_SSTP_CERT_BUNDLE"

    rm -f "$ca_dir"/netshare-cert-*.crt
    for file in "$WBT_SSTP_CERT_DIR"/*.pem; do
        [[ -e "$file" ]] || continue
        cp "$file" "$ca_dir/netshare-$(basename "$file" .pem).crt"
    done
    sstp_update_ca
    wbt_log "Certificado importado en $ca_dir."
    return 0
}

sstp_add_redirect() {
    wbt_log "Redirigiendo ${WBT_SSTP_HOST}:443 -> ${WBT_SSTP_HOST}:${WBT_SSTP_PORT} ..."
    iptables -t nat -D OUTPUT -p tcp -d "$WBT_SSTP_HOST" --dport 443 \
        -j DNAT --to-destination "${WBT_SSTP_HOST}:${WBT_SSTP_PORT}" 2>/dev/null || true
    iptables -t nat -A OUTPUT -p tcp -d "$WBT_SSTP_HOST" --dport 443 \
        -j DNAT --to-destination "${WBT_SSTP_HOST}:${WBT_SSTP_PORT}" || return 1
    WBT_SSTP_REDIRECT=1
    return 0
}

sstp_connect() {
    local -a extra=()
    [[ "$WBT_SSTP_HOST" != "127.0.0.1" ]] && extra+=(--save-server-route)

    wbt_log "Conectando VPN SSTP a ${WBT_SSTP_HOST}:${WBT_SSTP_PORT} ..."
    sstpc \
        --user "$WBT_SSTP_USER" \
        --password "$WBT_SSTP_PASS" \
        --ca-cert "$WBT_SSTP_CERT_BUNDLE" \
        --cert-warn \
        "${extra[@]}" \
        --log-stdout \
        "$WBT_SSTP_HOST" -- \
        noauth defaultroute replacedefaultroute usepeerdns \
        mtu 1400 mru 1400 noccp noipv6 lcp-echo-interval 0
}

sstp_run() {
    wbt_require_root "sstp"
    sstp_require_deps || return 1
    trap sstp_cleanup EXIT INT TERM

    local ssid=""
    ssid="$(wifi_current_ssid 2>/dev/null || true)"

    if wifi_is_direct_ns "$ssid"; then
        wbt_log "Wi-Fi DIRECT-NS detectado ($ssid); usando SSTP por Wi-Fi."
        sstp_import_cert || return 1
        sstp_add_redirect || return 1
    else
        wbt_log "El Wi-Fi actual no es DIRECT-NS-*; usando SSTP por USB/ADB."
        sstp_setup_usb || return 1
        sstp_import_cert || return 1
    fi

    sstp_connect
}
