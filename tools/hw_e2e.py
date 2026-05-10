"""WiFi+BLE e2e soak orchestrator (single-cell mode for Iteration 1).

Per cell:
  1. Build firmware via existing `make m0 FILE=...`.
  2. Anchor-flash via existing `tools/hw_validate.py` plumbing.
  3. Open the UART, drive a read loop, parse `@e2e` markers, stop after N
     attempts (or on overall timeout).
  4. Aggregate to a CellReport, write JSON, print summary table.

Iteration 1 supports a single cell: WiFi blob backend.
"""
from __future__ import annotations

import argparse
import dataclasses
import io
import json
import socket as _socket
import subprocess
import sys
import threading as _threading
import time
from pathlib import Path
from typing import IO

from e2e_markers import (
    AttemptRecord, CellReport, MarkerEvent,
    aggregate_attempts, parse_marker_line, summarize_cell,
)
from e2e_phases import Phase
from hw_e2e_mac import wifi_passive_check


REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_BUILD_DIR = REPO_ROOT / "build" / "hw-e2e"


def drive_uart_for_attempts(
    uart_stream: IO[str],
    expected_attempts: int,
    overall_timeout_s: float,
) -> list[AttemptRecord]:
    """Read lines from `uart_stream` until we have N completed attempts or
    timeout. Returns whatever attempts were captured.

    For Iteration 1 the timeout is enforced only for live serial streams (the
    test passes a StringIO that returns "" at EOF; we treat EOF as "stop"). For
    real serial we read non-blocking with deadline checks.
    """
    deadline = time.monotonic() + overall_timeout_s
    events: list[MarkerEvent | None] = []
    completed = 0
    while completed < expected_attempts:
        if time.monotonic() > deadline:
            break
        line = uart_stream.readline()
        if line == "":
            # EOF (StringIO) — stop.
            if isinstance(uart_stream, io.StringIO):
                break
            # Real serial: short sleep to avoid busy-loop, then continue.
            time.sleep(0.01)
            continue
        ev = parse_marker_line(line)
        events.append(ev)
        if ev is not None and ev.phase is Phase.ATTEMPT and ev.kind.value in ("ok", "fail"):
            completed += 1
    return aggregate_attempts(events)


def write_cell_report_json(
    out_path: Path,
    cell_name: str,
    report: CellReport,
    extra: dict | None = None,
) -> None:
    payload = {
        "cell_name": cell_name,
        "attempts_total": report.attempts_total,
        "attempts_ok": report.attempts_ok,
        "success_rate": report.success_rate,
        "failures_by_phase": {p.value: c for p, c in report.failures_by_phase.items()},
        "attempts": [
            {
                "n": a.n,
                "total": a.total,
                "result": a.result,
                "last_started_phase": a.last_started_phase.value if a.last_started_phase else None,
                "last_completed_phase": a.last_completed_phase.value if a.last_completed_phase else None,
                "failure_bucket": a.failure_bucket.value if a.failure_bucket else None,
                "fail_reason": a.fail_reason,
            }
            for a in report.attempts
        ],
    }
    if extra:
        payload.update(extra)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(payload, indent=2))


def print_cell_summary(cell_name: str, report: CellReport) -> None:
    print(f"\n=== {cell_name} ===")
    print(f"attempts: {report.attempts_ok}/{report.attempts_total} ok "
          f"({report.success_rate * 100:.1f}%)")
    if report.failures_by_phase:
        print("failures by phase:")
        for phase, count in sorted(
            report.failures_by_phase.items(), key=lambda kv: -kv[1]
        ):
            print(f"  {phase.value:>14}  {count}")
    else:
        print("failures by phase: (none)")


def run_via_hw_validate(
    *, test_name: str, ssid: str, password: str, attempts: int,
    uart_port: str, uart_baud: int, work_dir: Path,
) -> Path:
    """Build + anchor-flash + run the test via hw_validate.py's catalog mode.

    Uses the existing ``--test <name> --uart-anchor-flash --uart-anchor-runtime-jtag``
    plumbing (which builds the firmware, flashes via the M0 UART anchor, resets
    the board, and captures UART output) instead of duplicating it.

    Returns the path to the UART log file written by hw_validate.py.
    """
    log_path = work_dir / "logs" / f"{test_name}.primary.uart.log"
    cmd = [
        sys.executable, str(REPO_ROOT / "tools" / "hw_validate.py"),
        "--test", test_name,
        "--uart-anchor-flash", "--uart-anchor-runtime-jtag",
        "--openocd-sudo", "--ftdi-reset-sudo",
        "--work-dir", str(work_dir),
        "--uart", uart_port, "--uart-baud", str(uart_baud),
    ]
    env = {
        **__import__("os").environ,
        "BL808_WIFI_SSID": ssid,
        "BL808_WIFI_PASSWORD": password,
        "BL808_WIFI_E2E_ATTEMPTS": str(attempts),
    }
    print(f"$ BL808_WIFI_SSID=*** BL808_WIFI_PASSWORD=*** "
          f"BL808_WIFI_E2E_ATTEMPTS={attempts} {' '.join(cmd)}")
    proc = subprocess.run(cmd, cwd=REPO_ROOT, env=env)
    if proc.returncode != 0 and not log_path.is_file():
        raise RuntimeError(
            f"hw_validate.py failed (exit={proc.returncode}) and produced no "
            f"UART log at {log_path}"
        )
    if not log_path.is_file():
        raise FileNotFoundError(f"expected UART log at {log_path}")
    return log_path


def parse_log_file(log_path: Path) -> list[AttemptRecord]:
    """Parse a hw_validate UART log file into AttemptRecords."""
    text = log_path.read_text(encoding="utf-8", errors="replace")
    events = [parse_marker_line(line) for line in text.splitlines()]
    return aggregate_attempts(events)


def run_wifi_blob_cell(
    *, uart_port: str, uart_baud: int, ssid: str, password: str,
    attempts: int, ap_check_target: str | None,
    overall_timeout_s: float, build_dir: Path,
) -> CellReport:
    if ap_check_target is not None:
        r = wifi_passive_check(ap_check_target, count=2, timeout_s=2.0)
        if not r.ok:
            print(f"WARNING: AP sanity check failed: {r.detail!r} (continuing anyway)")

    work_dir = build_dir / "hw-validate-work"
    log_path = run_via_hw_validate(
        test_name="m0_wifi_e2e_test",
        ssid=ssid, password=password, attempts=attempts,
        uart_port=uart_port, uart_baud=uart_baud, work_dir=work_dir,
    )
    print(f"uart log: {log_path}")
    attempts_records = parse_log_file(log_path)

    report = summarize_cell(attempts_records)
    print_cell_summary("wifi-blob", report)
    out_dir = build_dir / time.strftime("%Y%m%d-%H%M%S")
    write_cell_report_json(
        out_dir / "wifi-blob.json", "wifi-blob", report,
        extra={"uart_log": str(log_path)},
    )
    return report


class EchoServer:
    """Tiny TCP echo server: bind to 0.0.0.0:0, accept loop on a daemon thread,
    each connection gets its bytes echoed back. Used by the WiFi e2e harness so
    the board has a known TCP target on the harness host's LAN.
    """

    def __init__(self) -> None:
        self._sock: _socket.socket | None = None
        self._thread: _threading.Thread | None = None
        self._stop_evt = _threading.Event()
        self.port: int = 0

    def start(self) -> None:
        s = _socket.socket(_socket.AF_INET, _socket.SOCK_STREAM)
        s.setsockopt(_socket.SOL_SOCKET, _socket.SO_REUSEADDR, 1)
        s.bind(("0.0.0.0", 0))
        s.listen(4)
        s.settimeout(0.2)  # allow accept loop to check stop flag
        self._sock = s
        self.port = s.getsockname()[1]
        self._stop_evt.clear()
        self._thread = _threading.Thread(target=self._accept_loop, daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop_evt.set()
        if self._sock is not None:
            try:
                self._sock.close()
            except OSError:
                pass
            self._sock = None
        if self._thread is not None:
            self._thread.join(timeout=1.0)
            self._thread = None

    def _accept_loop(self) -> None:
        while not self._stop_evt.is_set():
            try:
                conn, _addr = self._sock.accept()  # type: ignore[union-attr]
            except _socket.timeout:
                continue
            except OSError:
                # socket closed by stop()
                return
            try:
                data = conn.recv(64)
                if data:
                    conn.sendall(data)
            except OSError:
                pass
            finally:
                conn.close()


def discover_lan_ip() -> str:
    """Return the local interface IP that would be used to reach the public
    internet. Uses the standard UDP-getsockname trick (no packet sent). Falls
    back to gethostbyname(gethostname()) if the UDP path errors.

    The returned IP is what gets passed to firmware as WifiEchoHost so the
    board can TCP-connect back to the harness host across the WiFi LAN.
    """
    import socket
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            # 8.8.8.8 is just a routable address; no packet is actually sent
            # by connect() on a UDP socket — it just sets the default peer.
            s.connect(("8.8.8.8", 53))
            ip = s.getsockname()[0]
        finally:
            s.close()
        if ip.startswith("127."):
            # No default route → loopback. Fall through to the gethostbyname path.
            raise OSError("UDP-getsockname returned loopback; no default route?")
        return ip
    except OSError:
        ip = socket.gethostbyname(socket.gethostname())
        if ip.startswith("127."):
            raise RuntimeError(
                f"discover_lan_ip found no non-loopback interface (got {ip!r}). "
                f"Is this host connected to a LAN?"
            )
        return ip


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cell", choices=["wifi-blob"], default="wifi-blob")
    parser.add_argument("--uart", default="/dev/tty.usbserial-XXXX")
    parser.add_argument("--uart-baud", type=int, default=230400)
    parser.add_argument("--ssid", required=True,
                        help="WiFi SSID (required; pass on the command line)")
    parser.add_argument("--password", required=True,
                        help="WiFi password (required; do NOT commit; pass via CI secret or shell)")
    parser.add_argument("--attempts", type=int, default=3)
    parser.add_argument("--ap-check-target", default=None,
                        help="Optional host the Mac pings before the cell starts")
    parser.add_argument("--overall-timeout-s", type=float, default=120.0)
    parser.add_argument("--build-dir", type=Path, default=DEFAULT_BUILD_DIR)
    parser.add_argument("--success-floor", type=float, default=2/3,
                        help="Minimum success rate to exit 0 (default 2/3)")
    args = parser.parse_args(argv)
    if args.cell != "wifi-blob":
        print(f"cell {args.cell!r} not supported in Iteration 1", file=sys.stderr)
        return 2
    report = run_wifi_blob_cell(
        uart_port=args.uart, uart_baud=args.uart_baud,
        ssid=args.ssid, password=args.password,
        attempts=args.attempts, ap_check_target=args.ap_check_target,
        overall_timeout_s=args.overall_timeout_s, build_dir=args.build_dir,
    )
    if report.success_rate >= args.success_floor:
        print(f"\nPASS: success rate {report.success_rate * 100:.1f}% "
              f">= floor {args.success_floor * 100:.1f}%")
        return 0
    print(f"\nFAIL: success rate {report.success_rate * 100:.1f}% "
          f"< floor {args.success_floor * 100:.1f}%")
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
