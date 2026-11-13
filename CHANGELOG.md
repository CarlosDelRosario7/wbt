# Changelog

Todas las versiones notables de `wbt`. El formato sigue
[Keep a Changelog](https://keepachangelog.com/es-ES/1.1.0/) y el proyecto usa
versionado semántico.

## [0.1.2] - 2026-11-13

### Añadido

- Comandos `wbt start`, `wbt stop`, `wbt enable` y `wbt disable` para decidir
  cuándo arranca wbt.
- Opción `--enable` en `install.sh` para habilitar el arranque con el sistema.

### Cambiado

- Por defecto wbt **ya no arranca con el sistema**: el instalador deja las
  unidades deshabilitadas y el usuario elige con `wbt start` (solo la sesión)
  o `wbt enable` (también en cada arranque).
- `wbt stop` conserva el estado de habilitación; para quitarlo del arranque se
  usa `wbt disable`.
- `wbt status` y `wbt doctor` distinguen "detenido a propósito" de una caída:
  muestran la vigilancia como detenida y no la marcan como advertencia.

## [0.1.1] - 2026-11-10

### Corregido

- `wbt doctor` ya no sondea el puerto 8181 cuando el enlace PPP está activo.
  NetShare atiende una sola conexión y el sondeo podía cortar la sesión de
  `pppd` (`Modem hangup`); ahora se limita a comprobar el estado del enlace.

## [0.1.0] - 2026-11-10

### Añadido

- CLI modular `wbt` con comandos `ppp`, `usb`, `sstp`, `share`, `unshare`,
  `watch`, `doctor`, `deps`, `status`, `stop`, `logs`, `version` y `help`.
- Conexión PPP por Wi-Fi Direct con reencuadre de tramas para NetShare.
- Secuencia automática al arrancar con hotspot activo: detener hotspot,
  conectar la STA a `DIRECT-NS-*`, levantar PPP y restaurar el hotspot con
  uplink `ppp0` y el canal real.
- Watchdog de salud (`wbt watch`) con comprobaciones de IP, ruta por defecto,
  DNS y HTTP; reinicio de `wbt-ppp` tras fallos consecutivos y enfriamiento.
- Integración con `wifi-hotspot` sin modificarlo: `wbt share` pasa
  `--uplink ppp0 --channel <canal STA> --band <banda>`.
- Diagnóstico `wbt doctor`: dependencias, AP+STA, DIRECT-NS-*, puerto 8181,
  VPN del teléfono por ADB, PPP, hotspot y servicios.
- Instalador genérico para Debian/Ubuntu/Kali, Fedora, Arch y openSUSE.
- Unidades `wbt-ppp.service` y `wbt-watch.service` con protección contra
  bucles de reinicio (código 75).
- README en español y inglés, ayuda bilingüe, licencia GPL-3.0-or-later.
- Pruebas de shell, pruebas del proxy Python y validación local con
  shellcheck (`make release`).
- `contrib/wbt.bat` conservado como referencia del script original.

### Notas

- Los modos `usb` y `sstp` se consideran experimentales.
- El modo recomendado y probado es `ppp` por Wi-Fi Direct.
