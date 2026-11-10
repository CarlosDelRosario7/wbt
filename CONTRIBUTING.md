# Contribuir a wbt

Gracias por tu interés. Este proyecto es pequeño y prioriza la claridad y la
fiabilidad del enlace PPP.

## Antes de enviar cambios

```bash
make lint    # shellcheck + bash -n
make test    # pruebas de shell + unittest del proxy
make check   # ambas
```

El release se valida en local con `make release`, que exige un árbol limpio y
ejecuta `make check`. Después se crea el tag y se publica manualmente.

## Estilo

- Bash con `set -euo pipefail` en el punto de entrada.
- Funciones en `snake_case` y prefijos por módulo (`wifi_`, `ppp_`, `share_`,
  `watch_`, `doctor_`, `status_`, `deps_`).
- Mensajes de usuario en español; la ayuda principal es bilingüe.
- No añadir dependencias que no estén disponibles en Debian/Ubuntu, Fedora,
  Arch y openSUSE sin una alternativa.
- No modificar el proyecto `wifi-hotspot`: `wbt` solo lo invoca.

## Pruebas manuales útiles

```bash
# Solo lectura
wbt doctor
wbt status

# Comprobar el peer PPP generado
bash -c 'source lib/core.sh; source lib/ppp.sh; ppp_peer_text 192.168.49.1 8181'

# Una pasada del watchdog (requiere root)
sudo wbt watch --once
```

Para cambios en la secuencia PPP/hotspot, documenta en el PR:

- distribución y versión del kernel;
- adaptador Wi-Fi y combinaciones AP+STA (`iw list`);
- si había hotspot activo;
- salida de `wbt doctor` y `journalctl -u wbt-ppp -n 80`.

## Licencia

Al contribuir aceptas que tu aporte se publique bajo GPL-3.0-or-later.
