# wbt — Internet through NetShare on Linux

`wbt` connects a Linux laptop to the Internet through **NetShare** (Android)
using **Wi-Fi Direct + PPP**, and optionally shares that connection with other
devices through [`wifi-hotspot`](https://github.com/CarlosDelRosario7/wifi-hotspot).

It is the evolution of the original Windows script (`wbt.bat`, kept in
`contrib/`) and of the first Linux port, now organized as a modular CLI and a
systemd service.

> **Important:** an active VPN on the phone (RethinkDNS, Tailscale, WireGuard,
> etc.) can capture NetShare traffic and break the link. Disable it or exclude
> NetShare and LAN traffic. This is the most common cause of
> `LCP: timeout sending Config-Requests` or port 8181 not responding.

## How it works

```
Android phone                            Linux laptop
┌──────────────────┐   Wi-Fi Direct   ┌──────────────────────────────┐
│ NetShare         │   DIRECT-NS-*    │ wlan0 (STA)                  │
│ 192.168.49.1:8181│◄────────────────►│   │                          │
│ PPP server       │   PPP over TCP   │   ▼                          │
└──────────────────┘                  │ ppp0 ──► Internet            │
                                      │   │                          │
                                      │   ▼                          │
                                      │ wifi-ap (wifi-hotspot)        │
                                      │ 10.42.0.0/24 ──► clients      │
                                      └──────────────────────────────┘
```

1. `wbt ppp` connects `wlan0` to the `DIRECT-NS-*` network created by NetShare.
2. It starts `pppd` against `192.168.49.1:8181` through a Python proxy that
   reframes HDLC frames (NetShare's Java server requires a leading `0x7e` flag
   on every frame).
3. When `ppp0` has an IP address and a default route, the link is ready.
4. `wbt share` starts `wifi-hotspot` with `--uplink ppp0` and **the same
   channel** as the STA. On a single Wi-Fi card, AP+STA only works on the same
   channel; otherwise hostapd fails.
5. `wbt watch` checks real link health (IP, route, HTTP) and restarts
   `wbt-ppp` only when needed.

### The hotspot and the STA conflict

While the hotspot is active, `wlan0` cannot connect to `DIRECT-NS-*` (or the
connection does not survive). Therefore `wbt ppp` performs this sequence:

```
hotspot active → stop it → connect wlan0 to DIRECT-NS-* →
bring PPP up → restart hotspot with uplink ppp0 and the STA channel
```

The `wbt-ppp` service runs that sequence on startup. If the hotspot was active
before, it restores it at the end. The watcher repeats it when the link stops
passing traffic.

## Requirements

### Laptop

- Linux with `systemd` for the services (you can also run `wbt watch` in the
  foreground on other init systems).
- `pppd`, `python3`, `curl`, `iproute2`, `iw`, `NetworkManager` and
  `util-linux`.
- A Wi-Fi card supporting **AP+STA on the same channel** (most modern
  laptops; check with `wbt doctor`).
- Optional: [`wifi-hotspot`](https://github.com/CarlosDelRosario7/wifi-hotspot)
  only if you use `wbt share`.

### Phone

- Android with **NetShare** (`kha.prog.mikrotik`) running and sharing.
- No active VPN (or NetShare/LAN excluded).
- Optional: USB debugging and `adb` for `wbt usb` and for `wbt doctor` to
  check the phone VPN.

## Installation

```bash
git clone https://github.com/CarlosDelRosario7/wbt.git
cd wbt
sudo ./install.sh
```

The installer:

- copies `wbt` to `/usr/local/bin` and the libraries to `/usr/local/lib/wbt`;
- installs `wbt-ppp.service` and `wbt-watch.service`;
- enables both services;
- installs missing dependencies with `apt`, `dnf`, `pacman` or `zypper`
  (it does not run `apt update`);
- creates `/etc/wbt/wbt.conf.example` (defaults work without configuration).

Options:

```bash
sudo ./install.sh --with-hotspot   # install wifi-hotspot if missing
sudo ./install.sh --no-deps        # do not touch the package manager
sudo ./install.sh --no-enable      # install but do not enable services
sudo ./install.sh --start          # start wbt-ppp and wbt-watch at the end
sudo ./install.sh --prefix /usr    # install under /usr instead of /usr/local
```

### Startup

```bash
sudo systemctl start wbt-ppp wbt-watch
wbt status
```

If the hotspot was active, `wbt-ppp` stops it for a few seconds, connects the
STA, brings PPP up and restores it with the correct uplink.

### Supported distributions

| Family | Manager | Examples |
|---|---|---|
| Debian/Ubuntu | `apt` | Debian, Ubuntu, Kali, Linux Mint, Pop!_OS |
| Fedora/RHEL | `dnf` | Fedora, RHEL, Rocky, AlmaLinux |
| Arch | `pacman` | Arch, EndeavourOS, Manjaro |
| openSUSE | `zypper` | openSUSE Tumbleweed/Leap, SLES |

On other distributions install the dependencies manually and use `wbt watch`
in the foreground if systemd is unavailable.

## Usage

| Command | What it does |
|---|---|
| `sudo wbt ppp` | Connect over PPP (used by `wbt-ppp.service`) |
| `sudo wbt share` | Start/reconfigure `wifi-hotspot` with uplink `ppp0` |
| `sudo wbt unshare` | Stop the hotspot |
| `sudo wbt watch` | Foreground watchdog |
| `sudo wbt watch --once` | Run one watchdog pass |
| `wbt doctor` | Read-only diagnostics |
| `wbt status` | Link, service and hotspot status |
| `wbt deps` | Check dependencies |
| `sudo wbt deps --install` | Install missing packages |
| `sudo wbt stop` | Stop watcher, hotspot and PPP |
| `wbt logs` | Recent service logs |
| `wbt version` | Version |
| `wbt help [es\|en]` | Bilingual help |

### Sharing with wifi-hotspot

```bash
sudo wbt share
# or with a specific profile:
sudo wbt share --ssid "MyAP" --password "secret123"
```

`wbt share` **does not modify** the `wifi-hotspot` project: it only invokes it
with

```
--uplink ppp0 --channel <real wlan0 channel> --band <2.4|5>
```

If `wifi-hotspot` is missing, it fails with instructions. To install it:

```bash
sudo ./install.sh --with-hotspot
# or from its repository:
# https://github.com/CarlosDelRosario7/wifi-hotspot
```

The profile saved by `wifi-hotspot` (SSID, password, security) is reused when
you do not pass `--ssid`/`--password`.

### USB mode (experimental)

```bash
sudo wbt usb
```

Uses `adb forward` and PPP over USB; it does not change the laptop Wi-Fi.
Requires `adb` and authorized USB debugging.

### SSTP mode (experimental)

```bash
sudo wbt sstp
```

Port of the Windows method: downloads the `.p12` certificate, imports it into
the system trust store and uses `sstpc`. It is more fragile than PPP and
depends on `sstp-client`, `openssl` and `iptables`.

## systemd services

```bash
systemctl status wbt-ppp
systemctl status wbt-watch
journalctl -u wbt-ppp -u wbt-watch -f
```

- `wbt-ppp.service`: runs `wbt ppp --service`. If there is no `DIRECT-NS-*`
  network or NetShare does not respond, it exits with code 75 and **does not**
  enter a restart loop (`RestartPreventExitStatus=75`). The watcher recovers it
  later.
- `wbt-watch.service`: runs `wbt watch --interval 20`. It checks IP, route and
  HTTP; restarts `wbt-ppp` after two consecutive failures, with a 90-second
  cooldown. It also detects hotspot startup and fixes uplink/channel.

Stop everything:

```bash
sudo wbt stop
```

Uninstall:

```bash
sudo ./uninstall.sh            # keeps /etc/wbt and logs
sudo ./uninstall.sh --purge    # also removes configuration and logs
```

## Configuration

Copy the example and edit as needed:

```bash
sudo cp /etc/wbt/wbt.conf.example /etc/wbt/wbt.conf
sudoedit /etc/wbt/wbt.conf
sudo systemctl restart wbt-ppp wbt-watch
```

Main variables:

| Variable | Default | Description |
|---|---|---|
| `WBT_WIFI_IFACE` | `auto` | STA Wi-Fi interface |
| `WBT_PPP_IFACE` | `ppp0` | PPP interface |
| `WBT_VPN_HOST` | `192.168.49.1` | NetShare PPP server |
| `WBT_PPP_PORT` | `8181` | PPP port |
| `WBT_PPP_USER` / `WBT_PPP_PASS` | `netshare` / `0000` | PPP credentials |
| `WBT_HTTP_CHECK_URL` | `https://example.com` | Health check URL |
| `WBT_WATCH_INTERVAL` | `20` | Seconds between checks |
| `WBT_WATCH_FAILS` | `2` | Consecutive failures before restart |
| `WBT_WATCH_COOLDOWN` | `90` | Cooldown between restarts |
| `WBT_DNS_FALLBACK` | `8.8.8.8 1.1.1.1` | Fallback DNS if PPP provides none |
| `WBT_SHARE_SSID` / `WBT_SHARE_PASSWORD` | empty | Profile for `wbt share` |

## Troubleshooting

### NetShare does not respond on 8181

```bash
nc -z -w 3 192.168.49.1 8181 && echo OK
wbt doctor
```

If it fails:

1. Check that NetShare is sharing on the phone.
2. **Disable any VPN** (RethinkDNS, Tailscale, WireGuard...). The VPN captures
   NetShare traffic and the `SYN-ACK` leaves through `tun0`.
3. If you need the VPN, exclude NetShare and allow LAN traffic.
4. Reconnect `wlan0` to `DIRECT-NS-*`.

### `ppp0` does not appear or the service restart-loops

```bash
journalctl -u wbt-ppp -n 100 --no-pager
wbt logs
```

- `LCP: timeout sending Config-Requests` is almost always the phone VPN or
  `wlan0` not being on `DIRECT-NS-*`.
- If the service exits with code 75, systemd does not retry; the watcher will
  when NetShare becomes available again.
- Manual restart:

```bash
sudo systemctl reset-failed wbt-ppp
sudo systemctl restart wbt-ppp
```

### The hotspot does not start or hostapd fails

On a single Wi-Fi card, AP+STA requires the **same channel**. `wbt share`
passes it automatically, but if the channel changes (roaming), restart the
hotspot:

```bash
sudo wbt share
```

Check the channel:

```bash
iw dev wlan0 info | grep channel
wifi-hotspot status
```

### The hotspot has no Internet

```bash
wbt status
wifi-hotspot status
sudo iptables -t nat -S | grep 10.42
```

The uplink must be `ppp0` and the AP channel must match the STA channel.
`wbt share` fixes both.

### The phone VPN comes back

`wbt doctor` detects it when `adb` is available:

```bash
adb shell ip -4 addr show tun0
```

If `tun0` appears, turn the VPN off. There is no reliable way to bypass a VPN
that captures all traffic from the laptop side.

## Project layout

```
bin/wbt                     Entry point and dispatch
lib/core.sh                 Config, logging, privileges, utilities
lib/wifi.sh                 STA, DIRECT-NS-*, channel and AP+STA
lib/ppp.sh                  PPP peer, proxy, startup sequence
lib/share.sh                wifi-hotspot integration
lib/watch.sh                Health watchdog
lib/doctor.sh               Diagnostics
lib/status.sh               Status
lib/deps.sh                 Per-distro dependencies
lib/usb.sh                  USB/ADB mode (experimental)
lib/sstp.sh                 SSTP mode (experimental)
lib/netshare_ppp_proxy.py   PPP reframing for NetShare
systemd/*.in                systemd units
tests/                      Shell and proxy tests
contrib/wbt.bat             Original Windows script (reference)
install.sh / uninstall.sh   Install and uninstall
```

## Development

```bash
make lint     # shellcheck + bash -n
make test     # shell tests + proxy unittest
make check    # lint + test
make release  # verify a clean tree and validate the release locally
```

Releases are validated **locally** with `make release`; then create the tag
with `git tag -a vX.Y.Z -m "wbt X.Y.Z"` and push it with `git push`.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).

## Spanish

Lee la documentación en español: [README.md](README.md).
