#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# wbt - dependencias por familia de distribución.

# Comandos necesarios para el modo PPP + watcher.
deps_required_commands() {
    printf '%s\n' pppd python3 curl ip iw nmcli flock
}

# Comandos opcionales (USB, SSTP, comprobación de puertos).
deps_optional_commands() {
    printf '%s\n' nc adb sstpc openssl iptables update-ca-certificates
}

deps_package_for() {
    local manager="$1" command="$2"
    case "$manager:$command" in
        apt:pppd) printf 'ppp\n' ;;
        apt:python3) printf 'python3\n' ;;
        apt:nmcli) printf 'network-manager\n' ;;
        apt:nc) printf 'netcat-openbsd\n' ;;
        apt:flock) printf 'util-linux\n' ;;
        apt:adb) printf 'android-tools-adb\n' ;;
        apt:update-ca-certificates) printf 'ca-certificates\n' ;;
        dnf:pppd) printf 'ppp\n' ;;
        dnf:ip) printf 'iproute\n' ;;
        dnf:nmcli) printf 'NetworkManager\n' ;;
        dnf:nc) printf 'nmap-ncat\n' ;;
        dnf:flock) printf 'util-linux\n' ;;
        dnf:adb) printf 'android-tools\n' ;;
        dnf:update-ca-certificates) printf 'ca-certificates\n' ;;
        pacman:pppd) printf 'ppp\n' ;;
        pacman:python3) printf 'python\n' ;;
        pacman:ip) printf 'iproute2\n' ;;
        pacman:nmcli) printf 'networkmanager\n' ;;
        pacman:nc) printf 'openbsd-netcat\n' ;;
        pacman:flock) printf 'util-linux\n' ;;
        pacman:adb) printf 'android-tools\n' ;;
        pacman:update-ca-certificates) printf 'ca-certificates\n' ;;
        zypper:pppd) printf 'ppp\n' ;;
        zypper:python3) printf 'python3\n' ;;
        zypper:nmcli) printf 'NetworkManager\n' ;;
        zypper:nc) printf 'netcat-openbsd\n' ;;
        zypper:flock) printf 'util-linux\n' ;;
        zypper:adb) printf 'android-tools\n' ;;
        zypper:update-ca-certificates) printf 'ca-certificates\n' ;;
        *:pppd) printf 'ppp\n' ;;
        *:python3) printf 'python3\n' ;;
        *:ip) printf 'iproute2\n' ;;
        *:nmcli) printf 'NetworkManager\n' ;;
        *:flock) printf 'util-linux\n' ;;
        *) printf '%s\n' "$command" ;;
    esac
}

deps_check() {
    local missing=0 command optional
    printf 'Gestor de paquetes: %s\n' "$(wbt_pkg_manager)"
    printf 'Distribución: %s %s\n\n' "$(wbt_distro_id)" "$(wbt_distro_like)"

    printf 'Obligatorias:\n'
    while IFS= read -r command; do
        if wbt_have "$command"; then
            printf '  %sOK%s   %s\n' "$WBT_GREEN" "$WBT_NC" "$command"
        else
            printf '  %sFALTA%s %s\n' "$WBT_RED" "$WBT_NC" "$command"
            missing=1
        fi
    done < <(deps_required_commands)

    printf '\nOpcionales:\n'
    while IFS= read -r optional; do
        if wbt_have "$optional"; then
            printf '  %sOK%s   %s\n' "$WBT_GREEN" "$WBT_NC" "$optional"
        else
            printf '  --   %s (no instalado)\n' "$optional"
        fi
    done < <(deps_optional_commands)

    if ((missing)); then
        printf '\nInstala lo que falta con: sudo wbt deps --install\n'
        return 1
    fi
    printf '\nTodas las dependencias obligatorias están instaladas.\n'
    return 0
}

deps_install() {
    local manager packages=() command package
    manager="$(wbt_pkg_manager)"

    if [[ "$manager" == "unknown" ]]; then
        wbt_err "No reconozco el gestor de paquetes de esta distribución."
        wbt_err "Instala manualmente: pppd, python3, curl, iproute2, iw, NetworkManager, util-linux."
        return 1
    fi

    while IFS= read -r command; do
        if ! wbt_have "$command"; then
            package="$(deps_package_for "$manager" "$command")"
            [[ -n "$package" ]] && packages+=("$package")
        fi
    done < <(deps_required_commands)

    if ((${#packages[@]} == 0)); then
        wbt_log "Las dependencias obligatorias ya están instaladas."
        return 0
    fi

    # Quita duplicados conservando el orden.
    mapfile -t packages < <(printf '%s\n' "${packages[@]}" | awk '!seen[$0]++')
    wbt_log "Instalando con ${manager}: ${packages[*]}"

    case "$manager" in
        apt)
            apt-get install -y "${packages[@]}"
            ;;
        dnf)
            dnf install -y "${packages[@]}"
            ;;
        pacman)
            pacman -S --needed --noconfirm "${packages[@]}"
            ;;
        zypper)
            zypper --non-interactive install "${packages[@]}"
            ;;
    esac
}

deps_summary_line() {
    local missing=() command
    while IFS= read -r command; do
        wbt_have "$command" || missing+=("$command")
    done < <(deps_required_commands)
    if ((${#missing[@]} == 0)); then
        printf 'completas\n'
    else
        printf 'faltan: %s\n' "${missing[*]}"
    fi
}
