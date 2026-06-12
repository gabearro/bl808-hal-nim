#!/usr/bin/env python3
"""Capture the device-derived PUF root hash across cold boots.

Waits for a real power cycle (port drop then reappear) before each capture, so
every reading is a genuine fresh boot. Reports whether the SHA-256(root) printed
by m0_puf_root_test is identical across cold cycles -- i.e. whether the
*extracted key*, not just the raw SRAM, is reproducible.

Usage:
  python3 tools/puf/puf_root_collect.py --port /dev/cu.usbserial-TGKWL2RS --count 4
"""
from __future__ import annotations
import argparse
import os
import re
import time

import serial  # type: ignore

ROOT_RE = re.compile(rb"rootsha=([0-9A-Fa-fx ]+)")


def wait_absent(port):
    while os.path.exists(port):
        time.sleep(0.2)
    time.sleep(0.5)


def wait_present(port):
    while not os.path.exists(port):
        time.sleep(0.2)
    time.sleep(1.0)


def open_port(port, baud):
    while True:
        try:
            return serial.Serial(port, baud, timeout=0.3)
        except (serial.SerialException, OSError):
            time.sleep(0.3)


def read_root(ser, port, baud, timeout_s):
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        try:
            line = ser.readline()
        except (serial.SerialException, OSError):
            try:
                ser.close()
            except Exception:
                pass
            ser = open_port(port, baud)
            continue
        m = ROOT_RE.search(line)
        if m:
            return " ".join(m.group(1).decode("ascii", "ignore").split()), ser
    return None, ser


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", required=True)
    ap.add_argument("--baud", type=int, default=230400)
    ap.add_argument("--count", type=int, default=4)
    ap.add_argument("--timeout", type=float, default=60.0)
    args = ap.parse_args()

    roots = []
    ser = open_port(args.port, args.baud)
    for i in range(args.count):
        print(f"[{i+1}/{args.count}] >>> COLD POWER-CYCLE NOW (unplug ~5s, replug) <<<")
        try:
            ser.close()
        except Exception:
            pass
        wait_absent(args.port)
        print("  power-off detected; waiting for boot...")
        wait_present(args.port)
        ser = open_port(args.port, args.baud)
        root, ser = read_root(ser, args.port, args.baud, args.timeout)
        if root is None:
            print("  timeout; retrying this slot")
            continue
        print(f"  rootsha = {root}")
        roots.append(root)

    print("\n=== RESULT ===")
    uniq = set(roots)
    if roots and len(uniq) == 1:
        print(f"ALL {len(roots)} cold boots derived the SAME root hash.")
        print("==> PUF-derived key is reproducible across power cycles (end-to-end).")
    else:
        print(f"{len(roots)} captures, {len(uniq)} distinct root hashes:")
        for u in uniq:
            print("  ", u)
        print("==> NOT stable; investigate.")


if __name__ == "__main__":
    main()
