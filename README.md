# wbt — Internet por NetShare en Linux

`wbt` conecta una laptop Linux a Internet usando **NetShare** (Android) por
**Wi-Fi Direct + PPP**, y opcionalmente comparte esa conexión con otros
dispositivos mediante [`wifi-hotspot`](https://github.com/CarlosDelRosario7/wifi-hotspot).

Es la evolución del script original de Windows (`wbt.bat`, conservado en
`contrib/`) y del primer port a Linux, ahora organizado como CLI modular y
servicio systemd.

> **Aviso importante:** una VPN activa en el teléfono (RethinkDNS, Tailscale,
> WireGuard, etc.) puede capturar el tráfico de NetShare y romper la conexión.
> Desactívala o excluye NetShare y el tráfico LAN. Es la causa más común de
> `LCP: timeout sending Config-Requests` o de que el puerto 8181 no responda.

## Cómo funciona

```
Telefono Android                         Laptop Linux
┌──────────────────┐   Wi-Fi Direct   ┌──────────────────────────────┐
│ NetShare         │   DIRECT-NS-*    │ wlan0 (STA)                  │
│ 192.168.49.1:8181│◄────────────────►│   │                          │
│ servidor PPP     │   PPP sobre TCP  │   ▼                          │
└──────────────────┘                  │ ppp0 ──► Internet            │
                                      │   │                          │
                                      │   ▼                          │
                                      │ wifi-ap (wifi-hotspot)        │
                                      │ 10.42.0.0/24 ──► clientes     │
                                      └──────────────────────────────┘
```

1. `wbt ppp` conecta `wlan0` a la red `DIRECT-NS-*` que crea NetShare.
2. Lanza `pppd` contra `192.168.49.1:8181` usando un proxy Python que
   reencuadra las tramas HDLC (el servidor Java de NetShare exige un flag
   `0x7e` al inicio de cada trama).
3. Cuando `ppp0` tiene IP y ruta por defecto, el enlace está listo.
4. `wbt share` arranca `wifi-hotspot` con `--uplink ppp0` y **el mismo canal**
   que la STA. En una sola tarjeta Wi-Fi, AP+STA solo funciona en el mismo
   canal; si no coincide, hostapd falla.
5. `wbt watch` vigila la salud real del enlace (IP, ruta, HTTP) y reinicia
   `wbt-ppp` solo cuando hace falta.

### El hotspot y la STA se pelean

Con el hotspot activo, `wlan0` no puede conectarse a `DIRECT-NS-*` (o la
conexión no se mantiene). Por eso `wbt ppp` hace esta secuencia automática:

```
hotspot activo → detenerlo → conectar wlan0 a DIRECT-NS-* →
levantar PPP → reactivar hotspot con uplink ppp0 y el canal de la STA
```

El servicio `wbt-ppp` ejecuta esa secuencia al arrancar. Si el hotspot estaba
activo antes, lo restaura al final. El watcher la repite si el enlace deja de
pasar tráfico.

## Requisitos

### Laptop

- Linux con `systemd` para los servicios (también puedes usar `wbt watch` en
  primer plano en otros init systems).
- `pppd`, `python3`, `curl`, `iproute2`, `iw`, `NetworkManager` y `util-linux`.
- Una tarjeta Wi-Fi que soporte **AP+STA en el mismo canal** (la mayoría de
  portátiles modernas; compruébalo con `wbt doctor`).
- Opcional: [`wifi-hotspot`](https://github.com/CarlosDelRosario7/wifi-hotspot)
  solo si vas a usar `wbt share`.

### Teléfono

- Android con **NetShare** (`kha.prog.mikrotik`) activo y compartiendo.
- Sin VPN activa (o con NetShare/LAN excluidos).
- Opcional: depuración USB y `adb` para el modo `wbt usb` y para que
  `wbt doctor` compruebe la VPN del teléfono.

## Instalación

```bash
git clone https://github.com/CarlosDelRosario7/wbt.git
cd wbt
sudo ./install.sh
```

El instalador:

- copia `wbt` a `/usr/local/bin` y las librerías a `/usr/local/lib/wbt`;
- instala `wbt-ppp.service` y `wbt-watch.service`, **sin habilitarlos** para el
  arranque salvo que uses `--enable`;
- instala las dependencias que falten con `apt`, `dnf`, `pacman` o `zypper`
  (sin ejecutar `apt update`);
- crea `/etc/wbt/wbt.conf.example` (los valores por defecto funcionan sin
  configuración).

Opciones:

```bash
sudo ./install.sh --with-hotspot   # instala wifi-hotspot si falta
sudo ./install.sh --no-deps        # no toca el gestor de paquetes
sudo ./install.sh --enable         # arranca wbt automáticamente con el sistema
sudo ./install.sh --start          # arranca wbt ahora, sin habilitar el boot
sudo ./install.sh --prefix /usr    # instala en /usr en vez de /usr/local
```

### Arranque

Por defecto el instalador **no habilita** el arranque automático. Tú decides:

```bash
sudo wbt start      # iniciar ahora, solo para esta sesión
sudo wbt stop       # detener ahora
sudo wbt enable     # iniciar ahora y en cada arranque del sistema
sudo wbt disable    # detener y quitar del arranque del sistema
```

Para iniciarlo ahora y comprobar el estado:

```bash
sudo wbt start
wbt status
```

Si el hotspot estaba activo, `wbt-ppp` lo detendrá unos segundos, conectará la
STA, levantará PPP y lo restaurará con el uplink correcto. `wbt enable` es la
opción para quien quiera el arranque automático; `wbt start` no lo activa.

### Distribuciones soportadas

| Familia | Gestor | Ejemplos |
|---|---|---|
| Debian/Ubuntu | `apt` | Debian, Ubuntu, Kali, Linux Mint, Pop!_OS |
| Fedora/RHEL | `dnf` | Fedora, RHEL, Rocky, AlmaLinux |
| Arch | `pacman` | Arch, EndeavourOS, Manjaro |
| openSUSE | `zypper` | openSUSE Tumbleweed/Leap, SLES |

En otras distribuciones instala manualmente las dependencias y usa
`wbt watch` en primer plano si no hay systemd.

## Uso

| Comando | Qué hace |
|---|---|
| `sudo wbt ppp` | Conecta por PPP (lo usa `wbt-ppp.service`) |
| `sudo wbt share` | Arranca/reconfigura `wifi-hotspot` con uplink `ppp0` |
| `sudo wbt unshare` | Detiene el hotspot |
| `sudo wbt watch` | Watchdog en primer plano |
| `sudo wbt watch --once` | Una sola pasada del watchdog |
| `wbt doctor` | Diagnóstico de solo lectura |
| `wbt status` | Estado del enlace, servicios y hotspot |
| `wbt deps` | Comprueba dependencias |
| `sudo wbt deps --install` | Instala lo que falte |
| `sudo wbt start` | Arranca wbt ahora, sin tocar el arranque del sistema |
| `sudo wbt stop` | Detiene watcher, hotspot y PPP |
| `sudo wbt enable` | Arranca ahora y lo habilita en cada arranque |
| `sudo wbt disable` | Detiene y lo quita del arranque del sistema |
| `wbt logs` | Últimos logs de los servicios |
| `wbt version` | Versión |
| `wbt help [es\|en]` | Ayuda bilingüe |

### Compartir con wifi-hotspot

```bash
sudo wbt share
# o con un perfil concreto:
sudo wbt share --ssid "MiAP" --password "clave1234"
```

`wbt share` **no modifica** el proyecto `wifi-hotspot`: solo lo invoca con

```
--uplink ppp0 --channel <canal real de wlan0> --band <2.4|5>
```

Si `wifi-hotspot` no está instalado, falla con instrucciones. Para instalarlo:

```bash
sudo ./install.sh --with-hotspot
# o desde su repositorio:
# https://github.com/CarlosDelRosario7/wifi-hotspot
```

El perfil guardado por `wifi-hotspot` (SSID, contraseña, seguridad) se reutiliza
si no pasas `--ssid`/`--password`.

### Modo USB (experimental)

```bash
sudo wbt usb
```

Usa `adb forward` y PPP por USB; no cambia la red Wi-Fi de la laptop. Requiere
`adb` y depuración USB autorizada.

### Modo SSTP (experimental)

```bash
sudo wbt sstp
```

Port del método de Windows: descarga el certificado `.p12`, lo importa en el
almacén de confianza y usa `sstpc`. Es más frágil que PPP y depende de
`sstp-client`, `openssl` e `iptables`.

## Servicios systemd

```bash
systemctl status wbt-ppp
systemctl status wbt-watch
journalctl -u wbt-ppp -u wbt-watch -f
```

- `wbt-ppp.service`: ejecuta `wbt ppp --service`. Si no hay `DIRECT-NS-*` o
  NetShare no responde, sale con código 75 y **no** entra en un bucle de
  reinicios (`RestartPreventExitStatus=75`). El watcher lo recupera después.
- `wbt-watch.service`: ejecuta `wbt watch --interval 20`. Comprueba IP, ruta y
  HTTP; reinicia `wbt-ppp` tras dos fallos consecutivos, con enfriamiento de
  90 s. También detecta el arranque del hotspot y corrige uplink/canal.

Las unidades se instalan **deshabilitadas** por defecto. Esto controla el
arranque automático:

```bash
sudo wbt start      # ahora, solo esta sesión
sudo wbt enable     # ahora y en cada arranque
sudo wbt disable    # detener y quitar del arranque
```

Para detener todo:

```bash
sudo wbt stop
```

Para desinstalar:

```bash
sudo ./uninstall.sh            # conserva /etc/wbt y los logs
sudo ./uninstall.sh --purge    # elimina también configuración y logs
```

## Configuración

Copia el ejemplo y edita lo necesario:

```bash
sudo cp /etc/wbt/wbt.conf.example /etc/wbt/wbt.conf
sudoedit /etc/wbt/wbt.conf
sudo systemctl restart wbt-ppp wbt-watch
```

Variables principales:

| Variable | Por defecto | Descripción |
|---|---|---|
| `WBT_WIFI_IFACE` | `auto` | Interfaz Wi-Fi de la STA |
| `WBT_PPP_IFACE` | `ppp0` | Interfaz PPP |
| `WBT_VPN_HOST` | `192.168.49.1` | Servidor PPP de NetShare |
| `WBT_PPP_PORT` | `8181` | Puerto PPP |
| `WBT_PPP_USER` / `WBT_PPP_PASS` | `netshare` / `0000` | Credenciales PPP |
| `WBT_HTTP_CHECK_URL` | `https://example.com` | Prueba de salud |
| `WBT_WATCH_INTERVAL` | `20` | Segundos entre comprobaciones |
| `WBT_WATCH_FAILS` | `2` | Fallos consecutivos antes de reiniciar |
| `WBT_WATCH_COOLDOWN` | `90` | Enfriamiento entre reinicios |
| `WBT_SHARE_SSID` / `WBT_SHARE_PASSWORD` | vacío | Perfil para `wbt share` |

## Solución de problemas

### NetShare no responde en 8181

```bash
nc -z -w 3 192.168.49.1 8181 && echo OK
wbt doctor
```

Si falla:

1. Comprueba que NetShare esté compartiendo en el teléfono.
2. **Desactiva cualquier VPN** (RethinkDNS, Tailscale, WireGuard...). La VPN
   captura el tráfico de NetShare y el `SYN-ACK` sale por `tun0`.
3. Si necesitas la VPN, excluye NetShare y permite el tráfico LAN.
4. Vuelve a conectar `wlan0` a `DIRECT-NS-*`.

### `ppp0` no aparece o el servicio reinicia en bucle

```bash
journalctl -u wbt-ppp -n 100 --no-pager
wbt logs
```

- Si el log dice `LCP: timeout sending Config-Requests`, es casi siempre la VPN
  del teléfono o que `wlan0` no está en `DIRECT-NS-*`.
- Si el servicio sale con código 75, systemd no lo reintenta; el watcher lo
  hará cuando NetShare vuelva a estar disponible.
- Para reiniciar a mano:

```bash
sudo systemctl reset-failed wbt-ppp
sudo systemctl restart wbt-ppp
```

### El hotspot no arranca o hostapd falla

En una sola tarjeta Wi-Fi, AP+STA exige el **mismo canal**. `wbt share` lo pasa
automáticamente, pero si cambias de canal (roaming) reinicia el hotspot:

```bash
sudo wbt share
```

Comprueba el canal:

```bash
iw dev wlan0 info | grep channel
wifi-hotspot status
```

### El hotspot no tiene Internet

```bash
wbt status
wifi-hotspot status
sudo iptables -t nat -S | grep 10.42
```

El uplink debe ser `ppp0` y el canal del AP debe coincidir con el de la STA.
`wbt share` corrige ambas cosas.

### La VPN del teléfono vuelve a activarse

`wbt doctor` lo detecta si hay `adb`:

```bash
adb shell ip -4 addr show tun0
```

Si aparece `tun0`, apaga la VPN. No hay forma fiable de saltarse una VPN que
captura todo el tráfico desde el lado de la laptop.

## Estructura del proyecto

```
bin/wbt                     Punto de entrada y dispatch
lib/core.sh                 Configuración, logs, privilegios, utilidades
lib/wifi.sh                 STA, DIRECT-NS-*, canal y AP+STA
lib/ppp.sh                  Peer PPP, proxy, secuencia de arranque
lib/share.sh                Integración con wifi-hotspot
lib/watch.sh                Watchdog de salud
lib/service.sh              Arranque manual y automático (systemd)
lib/doctor.sh               Diagnóstico
lib/status.sh               Estado
lib/deps.sh                 Dependencias por distro
lib/usb.sh                  Modo USB/ADB (experimental)
lib/sstp.sh                 Modo SSTP (experimental)
lib/netshare_ppp_proxy.py   Reencuadre PPP para NetShare
systemd/*.in                Unidades systemd
tests/                      Pruebas de shell y del proxy
contrib/wbt.bat             Script original de Windows (referencia)
install.sh / uninstall.sh   Instalación y desinstalación
```

## Desarrollo

```bash
make lint     # shellcheck + bash -n
make test     # pruebas de shell + unittest del proxy
make check    # lint + test
make release  # comprueba el árbol limpio y valida el release en local
```

El release se valida **localmente** con `make release`; después se crea el
tag con `git tag -a vX.Y.Z -m "wbt X.Y.Z"` y se publica con `git push`.

## Licencia

GPL-3.0-or-later. Consulta [LICENSE](LICENSE).

## English

Read the English documentation: [README.en.md](README.en.md).
