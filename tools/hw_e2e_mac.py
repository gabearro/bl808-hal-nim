"""Mac-side adapter for the WiFi+BLE e2e harness.

Iteration 1 implements only `wifi-passive`: a pre-cell ping check that the
target AP/host is reachable from the Mac. BLE modes raise NotImplementedError
and land in Iteration 2.
"""
from __future__ import annotations

import argparse
import subprocess
import sys
from dataclasses import dataclass


@dataclass
class MacAdapterResult:
    ok: bool
    detail: str


def wifi_passive_check(
    target_host: str, count: int = 2, timeout_s: float = 2.0,
) -> MacAdapterResult:
    """Ping the target host from the Mac. Returns ok=True iff ping returns 0."""
    cmd = [
        "ping",
        "-c", str(count),
        "-W", str(int(timeout_s * 1000)),  # macOS ping -W is ms
        target_host,
    ]
    try:
        proc = subprocess.run(
            cmd, capture_output=True, text=True, timeout=count * timeout_s + 1.0,
        )
    except subprocess.TimeoutExpired:
        return MacAdapterResult(ok=False, detail="ping timeout")
    if proc.returncode == 0:
        return MacAdapterResult(ok=True, detail="")
    detail = (proc.stderr or proc.stdout or f"exit={proc.returncode}").strip()
    return MacAdapterResult(ok=False, detail=detail)


def ble_peripheral_per_attempt(*args, **kwargs) -> MacAdapterResult:
    raise NotImplementedError("BLE peripheral mode lands in Iteration 2")


def ble_central_per_cell(*args, **kwargs) -> MacAdapterResult:
    raise NotImplementedError("BLE central mode lands in Iteration 2")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=["wifi-passive"], required=True)
    parser.add_argument("--target", default="192.168.1.1")
    parser.add_argument("--count", type=int, default=2)
    parser.add_argument("--timeout-s", type=float, default=2.0)
    args = parser.parse_args(argv)
    if args.mode == "wifi-passive":
        r = wifi_passive_check(args.target, args.count, args.timeout_s)
        print(f"wifi-passive: ok={r.ok} detail={r.detail!r}")
        return 0 if r.ok else 1
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
