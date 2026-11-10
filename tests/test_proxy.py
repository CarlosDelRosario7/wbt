# SPDX-License-Identifier: GPL-3.0-or-later
"""Pruebas del proxy de reencuadre PPP de NetShare."""

from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path

PROXY_PATH = Path(__file__).resolve().parents[1] / "lib" / "netshare_ppp_proxy.py"
SPEC = importlib.util.spec_from_file_location("netshare_ppp_proxy", PROXY_PATH)
assert SPEC is not None and SPEC.loader is not None
proxy = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(proxy)


class EncodeTests(unittest.TestCase):
    def test_empty_payload(self) -> None:
        self.assertEqual(proxy.encode(b""), b"\x7e\x7e")

    def test_simple_payload(self) -> None:
        self.assertEqual(proxy.encode(b"\x01\x02"), b"\x7e\x01\x02\x7e")

    def test_escapes_flag(self) -> None:
        self.assertEqual(proxy.encode(b"\x7e"), b"\x7e\x7d\x5e\x7e")

    def test_escapes_escape(self) -> None:
        self.assertEqual(proxy.encode(b"\x7d"), b"\x7e\x7d\x5d\x7e")

    def test_roundtrip_all_bytes(self) -> None:
        payload = bytes(range(256))
        framed = proxy.encode(payload)
        self.assertEqual(framed[0], 0x7E)
        self.assertEqual(framed[-1], 0x7E)
        self.assertEqual(proxy.unescape(framed[1:-1]), payload)


class UnescapeTests(unittest.TestCase):
    def test_plain(self) -> None:
        self.assertEqual(proxy.unescape(b"\x01\x02"), b"\x01\x02")

    def test_escaped(self) -> None:
        self.assertEqual(proxy.unescape(b"\x7d\x5e"), b"\x7e")
        self.assertEqual(proxy.unescape(b"\x7d\x5d"), b"\x7d")

    def test_trailing_escape(self) -> None:
        self.assertEqual(proxy.unescape(b"\x7d"), b"\x7d")


class ReframeTests(unittest.TestCase):
    def test_single_frame(self) -> None:
        pending = bytearray()
        out = proxy.reframe(b"\x7e\x01\x02\x7e", pending)
        self.assertEqual(out, b"\x7e\x01\x02\x7e")
        self.assertEqual(bytes(pending), b"")

    def test_multiple_frames(self) -> None:
        pending = bytearray()
        out = proxy.reframe(b"\x7e\x01\x7e\x7e\x02\x7e", pending)
        self.assertEqual(out, b"\x7e\x01\x7e\x7e\x02\x7e")

    def test_partial_frame_is_kept(self) -> None:
        pending = bytearray()
        out = proxy.reframe(b"\x7e\x01", pending)
        self.assertEqual(out, b"")
        self.assertEqual(bytes(pending), b"\x01")

        out = proxy.reframe(b"\x02\x7e", pending)
        self.assertEqual(out, b"\x7e\x01\x02\x7e")
        self.assertEqual(bytes(pending), b"")

    def test_escaped_payload_is_split_safely(self) -> None:
        pending = bytearray()
        # 0x7e dentro del payload viaja como 0x7d 0x5e; no debe cortar la trama.
        out = proxy.reframe(b"\x7e\x01\x7d\x5e\x02\x7e", pending)
        self.assertEqual(out, b"\x7e\x01\x7d\x5e\x02\x7e")


class MainTests(unittest.TestCase):
    def test_no_arguments(self) -> None:
        self.assertEqual(proxy.main([]), 2)

    def test_invalid_port(self) -> None:
        self.assertEqual(proxy.main(["127.0.0.1", "no-es-puerto"]), 2)


if __name__ == "__main__":
    unittest.main()
