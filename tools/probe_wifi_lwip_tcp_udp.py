#!/usr/bin/env python3
"""Host-side TCP/UDP probe for the BL808 lwIP HTTP server example."""
from __future__ import annotations

import argparse
import re
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


def tcp_http_request(
    host: str,
    port: int,
    timeout_s: float,
    method: str,
    path: str,
    body: bytes = b"",
) -> bytes:
    request = (
        f"{method} {path} HTTP/1.1\r\n"
        f"Host: {host}\r\n"
        f"Content-Length: {len(body)}\r\n"
        "Connection: close\r\n"
        "\r\n"
    ).encode("ascii") + body
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
    return b"".join(chunks)


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


def parse_http_diagnostics(response: str) -> dict[str, str]:
    diagnostics: dict[str, str] = {}
    for line in response.splitlines():
        if "=" in line and not line.startswith("HTTP/"):
            key, value = line.split("=", 1)
            diagnostics[key.strip()] = value.strip()
    return diagnostics


ADD_WASM = bytes(
    [
        0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00,
        0x01, 0x07, 0x01, 0x60, 0x02, 0x7F, 0x7F, 0x01,
        0x7F, 0x03, 0x02, 0x01, 0x00, 0x07, 0x07, 0x01,
        0x03, 0x61, 0x64, 0x64, 0x00, 0x00, 0x0A, 0x09,
        0x01, 0x07, 0x00, 0x20, 0x00, 0x20, 0x01, 0x6A,
        0x0B,
    ]
)


def require_http_status(response: bytes, expected: bytes) -> str:
    text = response.decode("utf-8", errors="replace")
    first = text.splitlines()[0] if text else ""
    if expected.decode("ascii") not in first:
        print(text, end="")
        raise RuntimeError(
            f"expected HTTP status {expected.decode('ascii')}, got {first or 'empty response'}"
        )
    return text


def wasm_http_probe(host: str, port: int, timeout_s: float) -> None:
    install = tcp_http_request(
        host, port, timeout_s, "POST", "/wasm/programs/5", ADD_WASM
    )
    require_http_status(install, b"201 Created")

    invoke = tcp_http_request(
        host, port, timeout_s, "POST", "/wasm/programs/5/invoke/add", b"19,23"
    )
    invoke_text = require_http_status(invoke, b"200 OK")
    if "value=42" not in invoke_text:
        print(invoke_text, end="")
        raise RuntimeError("WASM invoke response missing value=42")

    delete = tcp_http_request(host, port, timeout_s, "DELETE", "/wasm/programs/5")
    require_http_status(delete, b"200 OK")
    print("[PASS] lwIP WASM HTTP install/invoke/delete", flush=True)


def require_int_at_least(diag: dict[str, str], key: str, minimum: int) -> int:
    if key not in diag:
        raise RuntimeError(f"HTTP diagnostics missing {key}")
    try:
        value = int(diag[key], 0)
    except ValueError as exc:
        raise RuntimeError(f"HTTP diagnostics {key} is not an integer: {diag[key]}") from exc
    if value < minimum:
        raise RuntimeError(
            f"HTTP diagnostics {key}={value} below expected minimum {minimum}"
        )
    return value


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
    diagnostics = parse_http_diagnostics(response)
    if "device_mac" not in diagnostics or "ip" not in diagnostics:
        print(response, end="")
        raise RuntimeError("HTTP probe missing diagnostics")
    if not re.fullmatch(r"[0-9A-F]{2}(:[0-9A-F]{2}){5}", diagnostics["device_mac"]):
        print(response, end="")
        raise RuntimeError(f"HTTP probe malformed device_mac={diagnostics['device_mac']}")
    if diagnostics["ip"] != host:
        print(response, end="")
        raise RuntimeError(f"HTTP probe ip={diagnostics['ip']} does not match {host}")
    print("[PASS] lwIP TCP HTTP/1.1 response", flush=True)

    wasm_http_probe(host, args.http_port, args.timeout)

    data = udp_echo_probe(host, args.udp_port, args.timeout)
    print(f"[PASS] lwIP UDP echo bytes={len(data)}", flush=True)

    response_after_udp = tcp_http_probe(host, args.http_port, args.timeout)
    diagnostics_after_udp = parse_http_diagnostics(response_after_udp)
    require_int_at_least(diagnostics_after_udp, "http_requests", 2)
    require_int_at_least(diagnostics_after_udp, "udp_rx_packets", 1)
    require_int_at_least(diagnostics_after_udp, "udp_tx_packets", 1)
    require_int_at_least(diagnostics_after_udp, "udp_rx_bytes_total", len(data))
    require_int_at_least(diagnostics_after_udp, "udp_tx_bytes_total", len(data))
    if diagnostics_after_udp.get("udp_last_remote_ip", "0.0.0.0") == "0.0.0.0":
        print(response_after_udp, end="")
        raise RuntimeError(
            "HTTP diagnostics did not record the UDP host remote IP"
        )
    print("[PASS] lwIP HTTP diagnostics reflect UDP RX/TX", flush=True)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"[FAIL] {exc}", file=sys.stderr, flush=True)
        raise
