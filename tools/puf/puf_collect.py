#!/usr/bin/env python3
"""Collect SRAM-PUF cold-boot captures from the m0_puf_capture firmware.

The firmware (resident in flash) prints, on every boot, a popcount summary and
the 4 KB OCRAM window as hex framed by @PUF_BEGIN/@PUF_END. This tool listens on
the UART, captures one frame per board boot, and saves it. Run it, then power-
cycle the board (cold boot) to capture pristine SRAM power-up state; repeat for
as many captures as you want, then analyze with puf_analyze.py.

Usage:
  python3 tools/puf/puf_collect.py --port /dev/cu.usbserial-TGKWL2RS \
      --out puf_runs --count 10
"""
from __future__ import annotations
import argparse
import os
import re
import sys
import time
from pathlib import Path

import serial  # type: ignore


def wait_port_absent(port: str, settle_s: float = 0.5) -> None:
    """Block until the serial device disappears (board powered off)."""
    while os.path.exists(port):
        time.sleep(0.2)
    time.sleep(settle_s)


def wait_port_present(port: str, settle_s: float = 1.0) -> None:
    """Block until the serial device reappears (board powered on)."""
    while not os.path.exists(port):
        time.sleep(0.2)
    time.sleep(settle_s)

HEX_RE = re.compile(rb"0x([0-9A-Fa-f]{8})")
ONES_RE = re.compile(rb"ocram64k_ones=0x([0-9A-Fa-f]+) of_0x([0-9A-Fa-f]+) hash=0x([0-9A-Fa-f]+)")
CHUNK_RE = re.compile(rb"chunk_ones=([0-9A-Fa-fx ]+)")


def open_port(port: str, baud: int):
    """Open the serial port, retrying until it appears (it vanishes while the
    board is powered off during a cold cycle)."""
    while True:
        try:
            return serial.Serial(port, baud, timeout=0.3)
        except (serial.SerialException, OSError):
            time.sleep(0.3)


def capture_one(state: dict, timeout_s: float) -> tuple[list[int], dict] | None:
    """Wait for one @PUF_BEGIN..@PUF_END frame; return (words, meta) or None.
    Transparently reopens the port if it drops during a power cycle."""
    words: list[int] = []
    meta: dict = {}
    in_frame = False
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        try:
            line = state["ser"].readline()
        except (serial.SerialException, OSError):
            # board powered down mid-cycle; wait for it to re-enumerate
            try:
                state["ser"].close()
            except Exception:
                pass
            state["ser"] = open_port(state["port"], state["baud"])
            words, in_frame = [], False
            continue
        if not line:
            continue
        m = ONES_RE.search(line)
        if m:
            meta = {
                "ones": int(m.group(1), 16),
                "total_bits": int(m.group(2), 16),
                "hash": int(m.group(3), 16),
            }
        cm = CHUNK_RE.search(line)
        if cm:
            meta["chunks"] = [int(x, 16) for x in cm.group(1).split()]
            print(f"  chunk_ones={meta['chunks']}")
        if b"@PUF_BEGIN" in line:
            in_frame = True
            words = []
            continue
        if b"@PUF_END" in line:
            if words:
                return words, meta
            in_frame = False
            continue
        if in_frame:
            words.extend(int(h, 16) for h in HEX_RE.findall(line))
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", required=True)
    ap.add_argument("--baud", type=int, default=230400)
    ap.add_argument("--out", default="puf_runs")
    ap.add_argument("--count", type=int, default=10)
    ap.add_argument("--timeout", type=float, default=30.0,
                    help="seconds to wait for each boot frame")
    ap.add_argument("--cycle-first", action="store_true",
                    help="wait for a power-off/on cycle BEFORE the first capture "
                         "too (so every saved frame is a genuine fresh boot, not "
                         "the firmware already looping from a prior boot)")
    args = ap.parse_args()

    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    state = {"port": args.port, "baud": args.baud,
             "ser": open_port(args.port, args.baud)}

    print(f"Listening on {args.port}. Power-cycle the board for each capture.")
    if args.cycle_first:
        try:
            state["ser"].close()
        except Exception:
            pass
        print("  >>> POWER-CYCLE NOW for a fresh boot (unplug, wait, replug) <<<")
        wait_port_absent(args.port)
        print("  power-off detected; waiting for boot...")
        wait_port_present(args.port)
        state["ser"] = open_port(args.port, args.baud)
    got = 0
    while got < args.count:
        print(f"[{got+1}/{args.count}] capturing this boot's frame...")
        res = capture_one(state, args.timeout)
        if res is None:
            print("  timeout; still waiting (Ctrl-C to stop)")
            continue
        words, meta = res
        path = out / f"run_{got:03d}.txt"
        with path.open("w") as f:
            for w in words:
                f.write(f"{w:08x}\n")
        pct = 100.0 * meta.get("ones", 0) / max(1, meta.get("total_bits", 1))
        print(f"  saved {path} ({len(words)} words)  ones={pct:.1f}%  "
              f"hash=0x{meta.get('hash',0):08x}")
        got += 1
        if got < args.count:
            # Separate cold boots: wait for power-off then power-on.
            try:
                state["ser"].close()
            except Exception:
                pass
            print("  >>> POWER-CYCLE NOW (unplug ~3s, replug) <<<")
            wait_port_absent(args.port)
            print("  power-off detected; waiting for boot...")
            wait_port_present(args.port)
            state["ser"] = open_port(args.port, args.baud)
    try:
        state["ser"].close()
    except Exception:
        pass
    print(f"Done: {got} captures in {out}/")


if __name__ == "__main__":
    main()
