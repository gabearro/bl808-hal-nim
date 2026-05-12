#!/usr/bin/env python3
"""Advertise a connectable BLE peripheral from macOS CoreBluetooth."""

from __future__ import annotations

import argparse
import sys
import time


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--name", default="bl808-host",
                        help="Local name to put in advertising data.")
    parser.add_argument("--service-uuid",
                        default="12345678-1234-5678-1234-56789abcdef0",
                        help="Service UUID to include in advertising data; empty omits it.")
    parser.add_argument("--duration", type=float, default=20.0,
                        help="Seconds to keep advertising before exiting.")
    parser.add_argument("--startup-timeout", type=float, default=8.0,
                        help="Seconds to wait for Bluetooth to power on and start advertising.")
    parser.add_argument("--restart-interval", type=float, default=0.0,
                        help="Seconds between stop/start advertising cycles. Disabled by default.")
    parser.add_argument("--restart-count", type=int, default=-1,
                        help="Maximum restart cycles when --restart-interval is set; negative means unlimited.")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        import objc  # type: ignore
        from CoreBluetooth import (  # type: ignore
            CBAdvertisementDataLocalNameKey,
            CBAdvertisementDataServiceUUIDsKey,
            CBPeripheralManager,
            CBPeripheralManagerStatePoweredOn,
            CBUUID,
        )
        from Foundation import NSDate, NSObject, NSRunLoop  # type: ignore
    except ImportError as exc:
        print(f"[FAIL] BLE advertising unavailable: {exc}", flush=True)
        return 1

    class PeripheralDelegate(NSObject):  # type: ignore[misc, valid-type]
        def init(self):  # noqa: D401 - Objective-C initializer
            self = objc.super(PeripheralDelegate, self).init()
            if self is None:
                return None
            self.name = args.name
            self.service_uuid = args.service_uuid
            self.started = False
            self.failed = False
            return self

        def start_advertising(self, peripheral):
            advertisement = {
                CBAdvertisementDataLocalNameKey: self.name,
            }
            if self.service_uuid:
                advertisement[CBAdvertisementDataServiceUUIDsKey] = [
                    CBUUID.UUIDWithString_(self.service_uuid)
                ]
            peripheral.startAdvertising_(advertisement)

        def peripheralManagerDidUpdateState_(self, peripheral):
            if peripheral.state() != CBPeripheralManagerStatePoweredOn:
                return
            self.start_advertising(peripheral)

        def peripheralManagerDidStartAdvertising_error_(self, peripheral, error):
            if error is not None:
                self.failed = True
                print(f"[FAIL] BLE advertising start: {error}", flush=True)
                return
            self.started = True
            print("[PASS] BLE advertising started", flush=True)

    delegate = PeripheralDelegate.alloc().init()
    manager = CBPeripheralManager.alloc().initWithDelegate_queue_(delegate, None)
    deadline = time.monotonic() + args.startup_timeout
    while time.monotonic() < deadline and not delegate.started and not delegate.failed:
        NSRunLoop.currentRunLoop().runUntilDate_(
            NSDate.dateWithTimeIntervalSinceNow_(0.1)
        )

    if delegate.failed or not delegate.started:
        print("[FAIL] BLE advertising did not start", flush=True)
        return 1

    end = time.monotonic() + args.duration
    next_restart = (
        time.monotonic() + args.restart_interval
        if args.restart_interval > 0.0 else None
    )
    restarts = 0
    while time.monotonic() < end:
        NSRunLoop.currentRunLoop().runUntilDate_(
            NSDate.dateWithTimeIntervalSinceNow_(0.1)
        )
        if next_restart is not None and time.monotonic() >= next_restart:
            manager.stopAdvertising()
            delegate.started = False
            delegate.start_advertising(manager)
            restarts += 1
            if args.restart_count >= 0 and restarts >= args.restart_count:
                next_restart = None
            else:
                next_restart = time.monotonic() + args.restart_interval

    manager.stopAdvertising()
    print("[PASS] BLE advertising stopped", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
