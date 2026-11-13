#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Pruebas unitarias de las funciones de shell (sin red ni root).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WBT_LIBDIR="$ROOT/lib"
export WBT_CONFIG_FILE="/dev/null"
export WBT_LOG_FILE=""
WBT_RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/wbt-test.XXXXXX")"
export WBT_RUN_DIR
trap 'rm -rf "$WBT_RUN_DIR"' EXIT

# shellcheck source=lib/core.sh
source "$WBT_LIBDIR/core.sh"
# shellcheck source=lib/wifi.sh
source "$WBT_LIBDIR/wifi.sh"
# shellcheck source=lib/ppp.sh
source "$WBT_LIBDIR/ppp.sh"
# shellcheck source=lib/share.sh
source "$WBT_LIBDIR/share.sh"
# shellcheck source=lib/watch.sh
source "$WBT_LIBDIR/watch.sh"
# shellcheck source=lib/service.sh
source "$WBT_LIBDIR/service.sh"
# shellcheck source=lib/deps.sh
source "$WBT_LIBDIR/deps.sh"

PASS=0
FAIL=0

ok() {
    PASS=$((PASS + 1))
    printf '  ok   %s\n' "$1"
}

fail() {
    FAIL=$((FAIL + 1))
    printf '  FAIL %s\n' "$1"
    [[ -n "${2:-}" ]] && printf '       %s\n' "$2"
}

assert_eq() {
    local expected="$1" actual="$2" name="$3"
    if [[ "$actual" == "$expected" ]]; then
        ok "$name"
    else
        fail "$name" "esperado='$expected' obtenido='$actual'"
    fi
}

assert_contains() {
    local haystack="$1" needle="$2" name="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        ok "$name"
    else
        fail "$name" "no contiene '$needle'"
    fi
}

assert_rc() {
    local expected="$1" actual="$2" name="$3"
    if [[ "$actual" -eq "$expected" ]]; then
        ok "$name"
    else
        fail "$name" "código esperado=$expected obtenido=$actual"
    fi
}

section() {
    printf '\n%s\n' "$1"
}

section "Wi-Fi: parser de canal"
iw_output='Interface wlan0
	ifindex 3
	addr 84:ef:18:a2:8c:fd
	ssid DIRECT-NS-Danny
	type managed
	channel 8 (2447 MHz), width: 20 MHz, center1: 2447 MHz'
assert_eq "8" "$(wifi_channel_from_iw_output "$iw_output")" "extrae canal 8"
assert_eq "" "$(wifi_channel_from_iw_output "sin canal")" "sin canal devuelve vacío"
assert_eq "1" "$(wifi_channel_from_iw_output "... channel 1 (2412 MHz) ...")" "extrae canal 1"

section "Wi-Fi: bandas"
assert_eq "2.4" "$(wifi_band_from_channel 1)" "canal 1 -> 2.4"
assert_eq "2.4" "$(wifi_band_from_channel 8)" "canal 8 -> 2.4"
assert_eq "2.4" "$(wifi_band_from_channel 14)" "canal 14 -> 2.4"
assert_eq "5" "$(wifi_band_from_channel 36)" "canal 36 -> 5"
assert_eq "5" "$(wifi_band_from_channel 149)" "canal 149 -> 5"
assert_eq "2.4" "$(wifi_band_from_frequency 2447)" "2447 MHz -> 2.4"
assert_eq "5" "$(wifi_band_from_frequency 5180)" "5180 MHz -> 5"

section "Wi-Fi: detección DIRECT-NS"
if wifi_is_direct_ns "DIRECT-NS-Danny"; then ok "DIRECT-NS-Danny es Direct"; else fail "DIRECT-NS-Danny es Direct"; fi
if ! wifi_is_direct_ns "Brucc"; then ok "Brucc no es Direct"; else fail "Brucc no es Direct"; fi
if ! wifi_is_direct_ns ""; then ok "SSID vacío no es Direct"; else fail "SSID vacío no es Direct"; fi

section "Share: argumentos para wifi-hotspot"
mapfile -t args < <(share_build_args 6 2.4)
expected=(--uplink ppp0 --channel 6 --band 2.4)
if [[ "${args[*]}" == "${expected[*]}" ]]; then
    ok "construye --uplink/--channel/--band"
else
    fail "construye --uplink/--channel/--band" "obtenido: ${args[*]}"
fi

section "Share: salida de wifi-hotspot sin credenciales"
mockbin="$(mktemp -d "$WBT_RUN_DIR/mock.XXXXXX")"
cat >"$mockbin/wifi-hotspot" <<'MOCK'
#!/usr/bin/env bash
printf 'SSID: Danny\nPassword: 12345678\nContraseña: secreta\n'
exit 1
MOCK
chmod +x "$mockbin/wifi-hotspot"
set +e
share_output="$(PATH="$mockbin:$PATH" share_exec wifi-hotspot start 2>&1)"
share_rc=$?
set -e
assert_rc 1 "$share_rc" "share_exec propaga el error"
assert_contains "$share_output" "Password: ****" "redacta Password"
assert_contains "$share_output" "Contraseña: ****" "redacta Contraseña"
if [[ "$share_output" != *12345678* && "$share_output" != *secreta* ]]; then
    ok "la contraseña no llega a la salida"
else
    fail "la contraseña no llega a la salida" "salida: $share_output"
fi

section "PPP: peer generado"
peer="$(ppp_peer_text 192.168.49.1 8181 /tmp/proxy.py)"
assert_contains "$peer" 'pty "/tmp/proxy.py 192.168.49.1 8181"' "incluye pty del proxy"
assert_contains "$peer" "replacedefaultroute" "reemplaza la ruta por defecto"
assert_contains "$peer" "lcp-echo-interval 0" "desactiva LCP echo (NetShare)"
assert_contains "$peer" "mtu 8192" "MTU 8192"
if [[ "$peer" != *"password"* ]]; then ok "no filtra la contraseña en el peer"; else fail "no filtra la contraseña en el peer"; fi

section "Watch: contadores y enfriamiento"
watch_write_int "$WBT_RUN_DIR/test.counter" 3
assert_eq "3" "$(watch_read_int "$WBT_RUN_DIR/test.counter" 0)" "lee contador"
assert_eq "7" "$(watch_read_int "$WBT_RUN_DIR/no-existe" 7)" "usa valor por defecto"
watch_mark "$WBT_RUN_DIR/test.last"
if watch_cooldown_ok "$WBT_RUN_DIR/test.last" 0; then
    ok "enfriamiento cumplido"
else
    fail "enfriamiento cumplido"
fi
if ! watch_cooldown_ok "$WBT_RUN_DIR/test.last" 3600; then
    ok "enfriamiento activo"
else
    fail "enfriamiento activo"
fi
(
    wbt_have() { return 0; }
    wbt_unit_active() { return 1; }
    watch_status_line || true
) >"$WBT_RUN_DIR/watch-status.txt"
assert_eq "detenido" "$(cat "$WBT_RUN_DIR/watch-status.txt")" "watch_status_line informa detenido"

section "Watch: recuperar con unidad deshabilitada"
recover_log="$WBT_RUN_DIR/recover.log"
set +e
(
    wbt_is_systemd() { return 0; }
    wbt_unit_exists() { return 0; }
    systemctl() {
        printf '%s\n' "$*" >>"$recover_log"
        [[ "$1" == "is-enabled" ]] && printf 'disabled\n'
        return 0
    }
    watch_recover >/dev/null 2>&1
)
recover_rc=$?
set -e
assert_rc 0 "$recover_rc" "watch_recover acepta unidades deshabilitadas"
assert_contains "$(cat "$recover_log")" "restart wbt-ppp.service" "reinicia wbt-ppp deshabilitado"

section "Servicios: unidades y arranque manual"
assert_eq "wbt-ppp.service wbt-watch.service" \
    "$(service_units | paste -sd ' ' -)" "lista las unidades"
systemctl_log="$WBT_RUN_DIR/systemctl.log"
(
    wbt_require_root() { :; }
    wbt_is_systemd() { return 0; }
    wbt_unit_exists() { return 0; }
    systemctl() { printf '%s\n' "$*" >>"$systemctl_log"; }
    service_start >/dev/null
)
assert_contains "$(cat "$systemctl_log")" "start wbt-ppp.service" "service_start arranca wbt-ppp"
assert_contains "$(cat "$systemctl_log")" "start wbt-watch.service" "service_start arranca wbt-watch"

section "CLI: ayuda bilingüe y versión"
help_es="$("$ROOT/bin/wbt" help es)"
help_en="$("$ROOT/bin/wbt" help en)"
help_both="$("$ROOT/bin/wbt" --help)"
assert_contains "$help_es" "Uso:" "ayuda en español"
assert_contains "$help_en" "Usage:" "ayuda en inglés"
assert_contains "$help_both" "Uso:" "--help incluye español"
assert_contains "$help_both" "Usage:" "--help incluye inglés"
assert_contains "$help_es" "wbt start" "ayuda incluye start"
assert_contains "$help_es" "wbt enable" "ayuda incluye enable"
assert_contains "$help_en" "wbt disable" "ayuda incluye disable"
install_help="$("$ROOT/install.sh" --help)"
assert_contains "$install_help" "--enable" "instalador ofrece --enable"
assert_eq "wbt 0.1.2" "$("$ROOT/bin/wbt" version)" "wbt version"

set +e
"$ROOT/bin/wbt" comando-inexistente >/dev/null 2>&1
rc=$?
set -e
assert_rc 2 "$rc" "comando desconocido devuelve 2"

section "Dependencias: resumen"
summary="$(deps_summary_line)"
if [[ -n "$summary" ]]; then ok "deps_summary_line produce salida"; else fail "deps_summary_line produce salida"; fi

printf '\nResultado: %d ok, %d fallos\n' "$PASS" "$FAIL"
((FAIL == 0))
