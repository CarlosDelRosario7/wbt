#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# wbt - instalador genérico (Debian/Ubuntu/Kali, Fedora, Arch, openSUSE).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="/usr/local"
BINDIR=""
LIBDIR=""
SYSTEMD_DIR="${SYSTEMD_DIR:-/etc/systemd/system}"
WITH_HOTSPOT=0
INSTALL_DEPS=1
ENABLE=0
START=0

usage() {
    cat <<'EOF'
Uso: sudo ./install.sh [opciones]

Opciones:
  --prefix RUTA        Prefijo de instalación (por defecto /usr/local)
  --with-hotspot       Instala wifi-hotspot si falta (dependencia de wbt share)
  --no-deps            No instala las dependencias del sistema
  --enable             Habilita wbt al arrancar el sistema (por defecto: no)
  --no-enable          No habilita el arranque automático (por defecto)
  --start              Arranca wbt-ppp y wbt-watch al terminar
  -h, --help           Esta ayuda

El instalador copia wbt a /usr/local/bin y /usr/local/lib/wbt, crea
/etc/wbt/wbt.conf.example e instala las unidades systemd. Por defecto no
habilita el arranque automático: inícialo con 'sudo wbt start' o actívalo
con 'sudo wbt enable'.
EOF
}

log() {
    printf '\033[0;32m[install]\033[0m %s\n' "$*"
}

warn() {
    printf '\033[1;33m[install WARN]\033[0m %s\n' "$*" >&2
}

die() {
    printf '\033[0;31m[install ERROR]\033[0m %s\n' "$*" >&2
    exit 1
}

while (($#)); do
    case "$1" in
        --prefix)
            shift
            PREFIX="${1:-}"
            ;;
        --prefix=*)
            PREFIX="${1#*=}"
            ;;
        --with-hotspot) WITH_HOTSPOT=1 ;;
        --no-deps) INSTALL_DEPS=0 ;;
        --enable) ENABLE=1 ;;
        --no-enable) ENABLE=0 ;;
        --start) START=1 ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            die "Opción desconocida: $1 (usa --help)"
            ;;
    esac
    shift
done

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "Ejecuta el instalador con sudo."
[[ -n "$PREFIX" ]] || die "El prefijo no puede estar vacío."
[[ "$PREFIX" == /* ]] || die "El prefijo debe ser una ruta absoluta."

BINDIR="${PREFIX}/bin"
LIBDIR="${PREFIX}/lib/wbt"

[[ -f "$SCRIPT_DIR/bin/wbt" ]] || die "No encuentro bin/wbt. Ejecuta el instalador desde el repositorio."
[[ -f "$SCRIPT_DIR/lib/core.sh" ]] || die "No encuentro lib/core.sh."
[[ -f "$SCRIPT_DIR/lib/netshare_ppp_proxy.py" ]] || die "No encuentro el proxy PPP."

install_hotspot() {
    local src="${WBT_HOTSPOT_SRC:-}" tmp="" manager

    if command -v wifi-hotspot >/dev/null 2>&1; then
        log "wifi-hotspot ya está instalado: $(command -v wifi-hotspot)"
        return 0
    fi

    if [[ -z "$src" && -d "$SCRIPT_DIR/../WiFi" ]]; then
        src="$(cd "$SCRIPT_DIR/../WiFi" && pwd)"
    fi
    if [[ -z "$src" && -d "$SCRIPT_DIR/../wifi-hotspot" ]]; then
        src="$(cd "$SCRIPT_DIR/../wifi-hotspot" && pwd)"
    fi
    if [[ -z "$src" ]]; then
        command -v git >/dev/null 2>&1 || die "Falta git para clonar wifi-hotspot."
        tmp="$(mktemp -d)"
        log "Clonando wifi-hotspot en $tmp ..."
        git clone --depth 1 https://github.com/CarlosDelRosario7/wifi-hotspot.git \
            "$tmp/wifi-hotspot"
        src="$tmp/wifi-hotspot"
    fi
    [[ -f "$src/Makefile" ]] || die "No encuentro el proyecto wifi-hotspot en $src."

    manager="$(. "$SCRIPT_DIR/lib/core.sh" && wbt_pkg_manager)"
    log "Intentando instalar wifi-hotspot desde $src con el empaquetado de la distro ..."

    case "$manager" in
        apt)
            if [[ -x "$src/packaging/deb/build.sh" ]]; then
                (cd "$src" && ./packaging/deb/build.sh) \
                    && apt-get install -y "$src"/dist/wifi-hotspot_*.deb \
                    && return 0
            fi
            ;;
        dnf | zypper)
            if [[ -x "$src/packaging/rpm/build.sh" ]]; then
                (cd "$src" && ./packaging/rpm/build.sh) || true
                if [[ "$manager" == "dnf" ]]; then
                    dnf install -y "$src"/dist/*.rpm && return 0
                else
                    zypper --non-interactive install "$src"/dist/*.rpm && return 0
                fi
            fi
            ;;
    esac

    warn "El empaquetado de la distro no está disponible; usando 'make install'."
    (cd "$src" && make install) || die "No se pudo instalar wifi-hotspot."
    if command -v wifi-hotspot >/dev/null 2>&1; then
        log "wifi-hotspot instalado desde el código fuente."
        warn "Si falta wifi-hotspotd, wbt share ejecutará el motor directamente como root."
        return 0
    fi
    die "wifi-hotspot sigue sin estar disponible después de instalarlo."
}

log "Instalando wbt en $BINDIR y $LIBDIR ..."
install -d -m 0755 "$BINDIR" "$LIBDIR" "$SYSTEMD_DIR" /etc/wbt /var/log

install -m 0755 "$SCRIPT_DIR/bin/wbt" "$BINDIR/wbt"
for file in "$SCRIPT_DIR"/lib/*.sh; do
    install -m 0644 "$file" "$LIBDIR/$(basename "$file")"
done
install -m 0755 "$SCRIPT_DIR/lib/netshare_ppp_proxy.py" "$LIBDIR/netshare_ppp_proxy.py"
install -m 0644 "$SCRIPT_DIR/etc/wbt.conf.example" "$LIBDIR/wbt.conf.example"
install -m 0644 "$SCRIPT_DIR/etc/wbt.conf.example" /etc/wbt/wbt.conf.example

if [[ ! -e /etc/wbt/wbt.conf ]]; then
    log "No hay /etc/wbt/wbt.conf; se usarán los valores por defecto."
    log "Puedes crear uno con: sudo cp /etc/wbt/wbt.conf.example /etc/wbt/wbt.conf"
fi

if [[ -d "$SYSTEMD_DIR" ]]; then
    for unit in wbt-ppp.service wbt-watch.service; do
        sed "s|@BINDIR@|$BINDIR|g" \
            "$SCRIPT_DIR/systemd/${unit}.in" >"$SYSTEMD_DIR/$unit"
        chmod 0644 "$SYSTEMD_DIR/$unit"
    done
    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload
    fi
else
    warn "No existe $SYSTEMD_DIR; se omiten las unidades systemd."
fi

if ((INSTALL_DEPS)); then
    log "Comprobando dependencias del sistema ..."
    if ! "$SCRIPT_DIR/bin/wbt" deps --install; then
        warn "Algunas dependencias no se pudieron instalar; revisa 'wbt deps'."
    fi
fi

if ((WITH_HOTSPOT)); then
    install_hotspot
fi

if ((!ENABLE)) && command -v systemctl >/dev/null 2>&1; then
    if systemctl is-enabled --quiet wbt-ppp.service 2>/dev/null \
        || systemctl is-enabled --quiet wbt-watch.service 2>/dev/null; then
        warn "Los servicios ya estaban habilitados de una instalación anterior."
        warn "Para quitar el arranque automático: sudo wbt disable"
    fi
fi

if ((ENABLE)) && command -v systemctl >/dev/null 2>&1; then
    log "Habilitando wbt-ppp.service y wbt-watch.service ..."
    systemctl enable wbt-ppp.service wbt-watch.service
fi

if ((START)) && command -v systemctl >/dev/null 2>&1; then
    log "Arrancando wbt-ppp.service ..."
    systemctl restart wbt-ppp.service
    log "Arrancando wbt-watch.service ..."
    systemctl restart wbt-watch.service
fi

printf '\n'
log "wbt instalado correctamente."
printf '  Binario:   %s/wbt\n' "$BINDIR"
printf '  Librería:  %s\n' "$LIBDIR"
printf '  Servicios: wbt-ppp.service, wbt-watch.service\n'
printf '\nSiguientes pasos:\n'
if ((!START)); then
    printf '  sudo wbt start     # iniciar ahora (solo esta sesión)\n'
fi
if ((!ENABLE)); then
    printf '  sudo wbt enable    # iniciar ahora y en cada arranque\n'
else
    printf '  wbt arrancará automáticamente con el sistema\n'
fi
printf '  wbt status\n'
printf '  wbt doctor\n'
printf '  sudo wbt share     # solo si tienes wifi-hotspot instalado\n'
