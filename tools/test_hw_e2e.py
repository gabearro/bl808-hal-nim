"""Tests for tools/hw_e2e.py orchestrator (parser path, mocked I/O)."""
from __future__ import annotations

import io
from pathlib import Path

import pytest

from e2e_phases import Phase
from hw_e2e import (
    drive_uart_for_attempts,
    write_cell_report_json,
    print_cell_summary,
)


def test_drive_uart_for_attempts_collects_n_attempts():
    """Parser reads UART line-by-line and returns when N attempts are seen."""
    uart_lines = [
        "boot banner ignored\n",
        "@e2e attempt:start n=1 total=2\n",
        "@e2e scan:start\n",
        "@e2e scan:ok\n",
        "@e2e auth:start\n",
        "@e2e auth:ok\n",
        "@e2e attempt:ok n=1 total=2\n",
        "@e2e attempt:start n=2 total=2\n",
        "@e2e scan:start\n",
        "@e2e scan:fail reason=no_match\n",
        "@e2e attempt:fail n=2 total=2\n",
        "ignored trailing line\n",
    ]
    fake = io.StringIO("".join(uart_lines))
    attempts = drive_uart_for_attempts(fake, expected_attempts=2, overall_timeout_s=10)
    assert len(attempts) == 2
    assert attempts[0].result == "ok"
    assert attempts[1].result == "fail"
    assert attempts[1].failure_bucket == Phase.SCAN


def test_write_cell_report_json_round_trip(tmp_path):
    from e2e_markers import AttemptRecord, summarize_cell
    attempts = [
        AttemptRecord(n=1, total=1, result="ok",
                      last_started_phase=Phase.ASSOC,
                      last_completed_phase=Phase.ASSOC,
                      failure_bucket=None, fail_reason=None),
    ]
    report = summarize_cell(attempts)
    out = tmp_path / "report.json"
    write_cell_report_json(
        out, cell_name="wifi-blob", report=report, extra={"firmware": "x.bin"})
    text = out.read_text()
    assert '"cell_name": "wifi-blob"' in text
    assert '"attempts_total": 1' in text
    assert '"attempts_ok": 1' in text
    assert '"firmware": "x.bin"' in text


def test_print_cell_summary_emits_per_phase_table(capsys):
    from e2e_markers import AttemptRecord, summarize_cell
    attempts = [
        AttemptRecord(n=1, total=2, result="ok",
                      last_started_phase=Phase.ASSOC,
                      last_completed_phase=Phase.ASSOC,
                      failure_bucket=None, fail_reason=None),
        AttemptRecord(n=2, total=2, result="fail",
                      last_started_phase=Phase.AUTH,
                      last_completed_phase=Phase.SCAN,
                      failure_bucket=Phase.AUTH, fail_reason="timeout"),
    ]
    report = summarize_cell(attempts)
    print_cell_summary("wifi-blob", report)
    out = capsys.readouterr().out
    assert "wifi-blob" in out
    assert "1/2" in out  # ok count
    assert "auth" in out  # phase that failed


def test_echo_server_starts_on_kernel_assigned_port():
    """EchoServer binds to 0.0.0.0:0; .port returns the kernel-assigned port."""
    from hw_e2e import EchoServer
    server = EchoServer()
    server.start()
    try:
        assert server.port > 0
        assert server.port < 65536
    finally:
        server.stop()


def test_echo_server_echoes_received_bytes():
    """A client connecting to EchoServer.port and sending bytes gets them back."""
    import socket
    from hw_e2e import EchoServer
    server = EchoServer()
    server.start()
    try:
        with socket.create_connection(("127.0.0.1", server.port), timeout=2.0) as s:
            s.sendall(b"BL808-E2E-PROBE\n")
            received = b""
            while len(received) < 16:
                chunk = s.recv(64)
                if not chunk:
                    break
                received += chunk
        assert received == b"BL808-E2E-PROBE\n"
    finally:
        server.stop()


def test_echo_server_handles_multiple_sequential_connections():
    """Each TCP connection is independent; server keeps accepting after one closes."""
    import socket
    from hw_e2e import EchoServer
    server = EchoServer()
    server.start()
    try:
        for i in range(3):
            with socket.create_connection(("127.0.0.1", server.port), timeout=2.0) as s:
                s.sendall(f"hello-{i}".encode())
                received = b""
                while len(received) < len(f"hello-{i}"):
                    chunk = s.recv(64)
                    if not chunk:
                        break
                    received += chunk
            assert received == f"hello-{i}".encode()
    finally:
        server.stop()


def test_echo_server_stop_releases_port():
    """After .stop(), the port is free for another bind."""
    import socket
    from hw_e2e import EchoServer
    server = EchoServer()
    server.start()
    port = server.port
    server.stop()
    # If the port is still held, this connect will fail or the next bind will EADDRINUSE.
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        s.bind(("127.0.0.1", port))  # should succeed
    finally:
        s.close()
