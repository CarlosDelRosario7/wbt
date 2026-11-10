#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# wbt - modo USB/ADB (experimental). No cambia la red Wi-Fi de la laptop.

WBT_USB_LOCAL_PORT="${WBT_USB_LOCAL_PORT:-18181}"
WBT_USB_FORWARD_ACTIVE=0
WBT_ADB_BIN=""

usb_find_adb() {
    local user home candidate
    user="$(wbt_real_user)"
    home="$(wbt_user_home "$user")"

    for candidate in \
        "$(command -v adb 2>/dev/null || true)" \
        "${home:+$home/Android/Sdk/platform-tools/adb}" \
        "${home:+$home/android-sdk/platform-tools/adb}" \
        "/usr/lib/android-sdk/platform-tools/adb" \
        "/opt/android-sdk/platform-tools/adb" \
        "/usr/bin/adb"; do
        if [[ -n "$candidate" && -x "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

usb_adb() {
    [[ -n "$WBT_ADB_BIN" ]] || return 1
    wbt_as_real_user "$WBT_ADB_BIN" "$@"
}

usb_setup() {
    WBT_ADB_BIN="$(usb_find_adb)" || {
        wbt_err "No se encontró adb. Instala android-tools-adb o usa el platform-tools del SDK."
        return 1
    }

    wbt_log "Comprobando dispositivo ADB ..."
    usb_adb start-server >/dev/null 2>&1 || true
    if [[ "$(usb_adb get-state 2>/dev/null || true)" != "device" ]]; then
        wbt_err "No hay un dispositivo ADB conectado y autorizado."
        wbt_err "Activa la depuración USB en el teléfono y acepta la clave."
        return 1
    fi

    wbt_log "Creando forward ADB 127.0.0.1:${WBT_USB_LOCAL_PORT} -> teléfono:8181 ..."
    usb_adb forward --remove "tcp:${WBT_USB_LOCAL_PORT}" >/dev/null 2>&1 || true
    if ! usb_adb forward "tcp:${WBT_USB_LOCAL_PORT}" tcp:8181 >/dev/null; then
        wbt_err "No se pudo crear el forward ADB."
        return 1
    fi
    WBT_USB_FORWARD_ACTIVE=1
    return 0
}

usb_cleanup() {
    if ((WBT_USB_FORWARD_ACTIVE == 1)) && [[ -n "$WBT_ADB_BIN" ]]; then
        wbt_log "Eliminando el forward ADB ..."
        usb_adb forward --remove "tcp:${WBT_USB_LOCAL_PORT}" >/dev/null 2>&1 || true
        WBT_USB_FORWARD_ACTIVE=0
    fi
}

usb_run() {
    wbt_require_root "usb"
    usb_setup || return 1

    # ppp_run_main llama a este hook al terminar o al recibir una señal.
    # shellcheck disable=SC2034  # lo consume ppp.sh
    WBT_CLEANUP_HOOK="usb_cleanup"
    ppp_run_main usb 127.0.0.1 "$WBT_USB_LOCAL_PORT"
}
