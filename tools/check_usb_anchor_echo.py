#!/usr/bin/env python3
"""Hardware byte-integrity check for the USB anchor's installed echo demo."""

from __future__ import annotations

import argparse
import json
import os
import random
import select
import termios
import time
from pathlib import Path

from hw_validate import HardwareRunLock


def check(path: str, seed: int) -> dict:
    expected = random.Random(seed).randbytes(64 * 1024)
    received = bytearray()
    sent = 0
    fd = os.open(path, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    try:
        time.sleep(0.1)
        termios.tcflush(fd, termios.TCIFLUSH)  # Discard the demo's startup banner.
        start = last_io = time.monotonic()
        while True:
            now = time.monotonic()
            if now - start >= 20 or now - last_io >= 3:
                break
            if len(received) >= len(expected) and now - last_io >= 0.1:
                break
            # Force buffering and backpressure before accepting any echo.
            readable, writable, _ = select.select(
                [fd] if now - start >= 0.4 else [],
                [fd] if sent < len(expected) else [], [], 0.025)
            if writable:
                try:
                    sent += os.write(fd, expected[sent:sent + 4096])
                    last_io = time.monotonic()
                except BlockingIOError:
                    pass
            if readable:
                try:
                    data = os.read(fd, 4096)
                    if not data:
                        break
                    received.extend(data)
                    last_io = time.monotonic()
                except BlockingIOError:
                    pass
    finally:
        os.close(fd)
    identical = received == expected and sent == len(expected)
    mismatch = None if identical else next(
        (i for i, (a, b) in enumerate(zip(expected, received)) if a != b),
        min(len(expected), len(received)))
    return dict(seed=seed, expected=len(expected), sent=sent,
                received=len(received), identical=identical,
                first_difference=mismatch,
                elapsed_seconds=round(time.monotonic() - start, 3))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--uart", required=True, help="USB mux app-console PTY")
    parser.add_argument("--work-dir", type=Path, default=Path("build/hw-validation"))
    parser.add_argument("--seed", type=int, default=808)
    args = parser.parse_args()
    with HardwareRunLock(args.work_dir / "hardware.lock"):
        report = check(args.uart, args.seed)
        output = json.dumps(report, indent=2)
        (args.work_dir / f"usb-echo-{args.seed}.json").write_text(output + "\n")
        print(output)
    return 0 if report["identical"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
