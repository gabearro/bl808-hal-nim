#!/usr/bin/env python3
"""Host-side TCP/UDP probe for the BL808 lwIP HTTP server example."""
from __future__ import annotations

import argparse
import socket
import sys
import time


def parse_lwip_ip(value: str) -> str:
    raw = int(value, 0)
    return ".".join(str((raw >> shift) & 0xFF) for shift in (0, 8, 16, 24))


def tcp_http_probe(host: str, port: int, timeout_s: float) -> str:
    request = (
        f"GET / HTTP/1.1\r\n"
        f"Host: {host}\r\n"
        "Connection: close\r\n"
        "\r\n"
    ).encode("ascii")
    chunks: list[bytes] = []
    with socket.create_connection((host, port), timeout=timeout_s) as sock:
        sock.settimeout(timeout_s)
        sock.sendall(request)
        while True:
            try:
                data = sock.recv(1024)
            except socket.timeout:
                break
            if not data:
                break
            chunks.append(data)
    return b"".join(chunks).decode("utf-8", errors="replace")


def udp_echo_probe(host: str, port: int, timeout_s: float) -> bytes:
    payload = b"BL808 Nim lwIP UDP echo host probe"
    deadline = time.monotonic() + timeout_s
    last_error: Exception | None = None
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.settimeout(0.5)
        while time.monotonic() < deadline:
            try:
                sock.sendto(payload, (host, port))
                data, addr = sock.recvfrom(2048)
                if addr[0] == host and data == payload:
                    return data
            except OSError as exc:
                last_error = exc
            time.sleep(0.1)
    if last_error is not None:
        raise TimeoutError(f"UDP echo probe timed out after {timeout_s}s: {last_error}")
    raise TimeoutError(f"UDP echo probe timed out after {timeout_s}s")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--ip", required=True,
                        help="Device IP as dotted IPv4 or lwIP hex marker value.")
    parser.add_argument("--http-port", type=int, default=80)
    parser.add_argument("--udp-port", type=int, default=65000)
    parser.add_argument("--timeout", type=float, default=10.0)
    args = parser.parse_args()

    host = parse_lwip_ip(args.ip) if args.ip.startswith("0x") else args.ip
    print(f"device_ip={host}", flush=True)

    response = tcp_http_probe(host, args.http_port, args.timeout)
    status = response.splitlines()[0] if response else ""
    if "HTTP/1.1 200 OK" not in response:
        print(response, end="")
        raise RuntimeError(f"HTTP probe failed: {status or 'empty response'}")
    if "Hello World! from Nim on BL808" not in response:
        print(response, end="")
        raise RuntimeError("HTTP probe missing greeting")
    if "device_mac=" not in response or "ip=" not in response:
        print(response, end="")
        raise RuntimeError("HTTP probe missing diagnostics")
    print("[PASS] lwIP TCP HTTP/1.1 response", flush=True)

    data = udp_echo_probe(host, args.udp_port, args.timeout)
    print(f"[PASS] lwIP UDP echo bytes={len(data)}", flush=True)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"[FAIL] {exc}", file=sys.stderr, flush=True)
        raise
