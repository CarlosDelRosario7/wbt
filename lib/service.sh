#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# wbt - control de los servicios systemd (arranque manual y con el sistema).

service_units() {
    printf '%s\n' wbt-ppp.service wbt-watch.service
}

service_require_systemd() {
    if ! wbt_is_systemd; then
        wbt_err "systemd no está disponible; usa 'sudo wbt watch' en primer plano."
        return 1
    fi
}

service_require_installed() {
    local unit
    service_require_systemd || return 1
    while IFS= read -r unit; do
        if ! wbt_unit_exists "$unit"; then
            wbt_err "La unidad ${unit} no está instalada. Ejecuta ./install.sh."
            return 1
        fi
    done < <(service_units)
}

# Arranca wbt para esta sesión, sin tocar el arranque del sistema.
service_start() {
    local -a units=()
    wbt_require_root "start"
    service_require_installed || return 1
    mapfile -t units < <(service_units)
    systemctl reset-failed "${units[@]}" >/dev/null 2>&1 || true
    wbt_log "Arrancando wbt-ppp.service y wbt-watch.service ..."
    if ! systemctl start wbt-ppp.service; then
        wbt_warn "wbt-ppp no arrancó; el watcher intentará recuperarlo."
    fi
    systemctl start wbt-watch.service
    wbt_log "wbt iniciado. Comprueba el enlace con: wbt status"
}

# Detiene todo ahora; conserva el estado de habilitación del sistema.
service_stop() {
    local keep_share="${1:-}"
    wbt_require_root "stop"
    if wbt_unit_active wbt-watch.service; then
        wbt_log "Deteniendo wbt-watch.service ..."
        systemctl stop wbt-watch.service || true
    fi
    if [[ "$keep_share" != "--keep-share" ]]; then
        share_stop
    fi
    ppp_stop
    wbt_log "wbt detenido."
}

# Arranca ahora y habilita el arranque automático con el sistema.
service_enable() {
    local -a units=()
    wbt_require_root "enable"
    service_require_installed || return 1
    mapfile -t units < <(service_units)
    wbt_log "Habilitando el arranque automático de wbt ..."
    systemctl enable "${units[@]}"
    service_start
    wbt_log "wbt arrancará con el sistema."
}

# Detiene todo y deshabilita el arranque automático con el sistema.
service_disable() {
    local -a units=()
    wbt_require_root "disable"
    service_require_installed || return 1
    mapfile -t units < <(service_units)
    service_stop
    wbt_log "Deshabilitando el arranque automático de wbt ..."
    systemctl disable "${units[@]}"
    wbt_log "wbt ya no arrancará con el sistema."
}
