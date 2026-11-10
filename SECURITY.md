# Seguridad

## Alcance

`wbt` se ejecuta como root porque necesita `pppd`, `iptables` (modo SSTP) y
`wifi-hotspot`. Trata el archivo `/etc/wbt/wbt.conf` y el peer
`/etc/ppp/peers/netshare` como configuración privilegiada.

## Prácticas del proyecto

- El peer PPP se crea con permisos `0600`.
- La contraseña PPP no se escribe en el peer; se pasa a `pppd` por línea de
  comandos (visible para root en `ps`, como en cualquier `pppd`).
- `wbt share` no modifica el código de `wifi-hotspot`; solo ejecuta su CLI.
- El instalador no descarga binarios arbitrarios: usa el gestor de paquetes de
  la distribución o compila el proyecto `wifi-hotspot` desde su repositorio.
- El proxy PPP solo escucha en el socket TCP que abre hacia el teléfono; no
  abre puertos locales.

## Riesgos conocidos

- Una VPN activa en el teléfono puede interceptar el tráfico de NetShare. No es
  una vulnerabilidad de `wbt`; desactívala o excluye NetShare.
- `wifi-hotspot` crea un AP con la contraseña del perfil guardado. Usa WPA2/WPA3
  y una contraseña fuerte.
- Los modos `usb` y `sstp` son experimentales y no reciben el mismo nivel de
  pruebas que `ppp`.

## Reportar una vulnerabilidad

Abre un issue privado en GitHub o contacta al mantenedor
(`CarlosDelRosario7`) sin publicar detalles explotables. Incluye versión,
distribución, pasos de reproducción y el impacto esperado.
