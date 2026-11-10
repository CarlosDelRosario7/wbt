#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Reencuadre PPP para el servidor Java de NetShare.

pppd de Linux comparte el flag 0x7e entre tramas consecutivas; el servidor
de NetShare espera un flag inicial en cada trama. Este proceso se ejecuta como
el comando `pty` de pppd: lee tramas HDLC de stdin, las desescapa, y las vuelve
a emitir con flag inicial y final por el socket TCP del teléfono.

Uso: netshare_ppp_proxy.py HOST [PUERTO]
"""

from __future__ import annotations

import os
import socket
import sys
import threading
import time

PPP_FLAG = 0x7E
PPP_ESCAPE = 0x7D
PPP_ESCAPE_XOR = 0x20


def log(message: str) -> None:
    print("[netshare-ppp] " + message, file=sys.stderr, flush=True)


def encode(payload: bytes) -> bytes:
    """Enmarca y escapa una trama PPP (flag inicial y final)."""
    out = bytearray([PPP_FLAG])
    for byte in payload:
        if byte in (PPP_ESCAPE, PPP_FLAG):
            out.append(PPP_ESCAPE)
            out.append(byte ^ PPP_ESCAPE_XOR)
        else:
            out.append(byte)
    out.append(PPP_FLAG)
    return bytes(out)


def unescape(raw: bytes) -> bytes:
    """Deshace el escapado PPP de una trama sin flags."""
    out = bytearray()
    index = 0
    length = len(raw)
    while index < length:
        byte = raw[index]
        if byte == PPP_ESCAPE and index + 1 < length:
            out.append(raw[index + 1] ^ PPP_ESCAPE_XOR)
            index += 2
        else:
            out.append(byte)
            index += 1
    return bytes(out)


def reframe(data: bytes, pending: bytearray) -> bytes:
    """Convierte un bloque leído de pppd en tramas aceptadas por NetShare.

    `pending` conserva la parte incompleta de la última trama entre lecturas.
    """
    pending.extend(data)
    parts = pending.split(b"\x7e")
    del pending[:]
    pending.extend(parts.pop())

    out = bytearray()
    for part in parts:
        if part:
            out.extend(encode(unescape(part)))
    return bytes(out)


def connect_retry(host: str, port: int, attempts: int = 10, delay: float = 1.0) -> socket.socket:
    """Conecta al teléfono con reintentos (NetShare puede tardar en escuchar)."""
    last_error: OSError | None = None
    for attempt in range(attempts):
        try:
            sock = socket.create_connection((host, port), timeout=5)
            sock.settimeout(None)
            try:
                sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            except OSError:
                pass
            return sock
        except OSError as exc:
            last_error = exc
            if attempt + 1 < attempts:
                time.sleep(delay)
    if last_error is not None:
        raise last_error
    raise OSError("no se pudo conectar")


def main(argv: list[str] | None = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    if len(args) < 1:
        log("uso: netshare_ppp_proxy HOST [PUERTO]")
        return 2

    host = args[0]
    try:
        port = int(args[1]) if len(args) > 1 else 8181
    except ValueError:
        log("puerto inválido: %s" % args[1])
        return 2

    try:
        sock = connect_retry(host, port)
    except OSError as exc:
        log("no se pudo conectar a %s:%d: %s" % (host, port, exc))
        return 1

    stop = threading.Event()

    def pump_in() -> None:
        pending = bytearray()
        while not stop.is_set():
            try:
                data = os.read(0, 4096)
            except OSError:
                break
            if not data:
                break
            framed = reframe(data, pending)
            if framed:
                try:
                    sock.sendall(framed)
                except OSError:
                    break
        stop.set()
        try:
            sock.shutdown(socket.SHUT_WR)
        except OSError:
            pass

    def pump_out() -> None:
        while not stop.is_set():
            try:
                data = sock.recv(4096)
            except OSError:
                break
            if not data:
                break
            try:
                os.write(1, data)
            except OSError:
                break
        stop.set()
        # Al cerrarse el socket, terminar el proceso para que pppd detecte el
        # fin del enlace aunque pump_in esté bloqueado en os.read(0).
        os._exit(0)

    thread_in = threading.Thread(target=pump_in, daemon=True)
    thread_out = threading.Thread(target=pump_out, daemon=True)
    thread_in.start()
    thread_out.start()
    thread_in.join()
    return 0


if __name__ == "__main__":
    sys.exit(main())
