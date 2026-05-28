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
    parser.add_argument("--gatt-service-uuid",
                        default="12345678-1234-5678-1234-56789abcdef0",
                        help="Service UUID to register for incoming connections.")
    parser.add_argument("--characteristic-uuid",
                        default="12345678-1234-5678-1234-56789abcdef1",
                        help="Readable characteristic UUID to expose under the advertised service.")
    parser.add_argument("--no-gatt-service", action="store_true",
                        help="Do not register a matching CBMutableService before advertising.")
    parser.add_argument("--duration", type=float, default=20.0,
                        help="Seconds to keep advertising before exiting.")
    parser.add_argument("--startup-timeout", type=float, default=8.0,
                        help="Seconds to wait for Bluetooth to power on and start advertising.")
    parser.add_argument("--restart-interval", type=float, default=0.0,
                        help="Seconds between stop/start advertising cycles. Disabled by default.")
    parser.add_argument("--restart-count", type=int, default=-1,
                        help="Maximum restart cycles when --restart-interval is set; negative means unlimited.")
    parser.add_argument("--debug", action="store_true",
                        help="Print CoreBluetooth startup state transitions.")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        import objc  # type: ignore
        from CoreBluetooth import (  # type: ignore
            CBAdvertisementDataLocalNameKey,
            CBAdvertisementDataServiceUUIDsKey,
            CBAttributePermissionsReadable,
            CBCharacteristicPropertyRead,
            CBMutableCharacteristic,
            CBMutableService,
            CBPeripheralManager,
            CBPeripheralManagerStatePoweredOn,
            CBUUID,
        )
        from Foundation import NSData, NSDate, NSObject, NSRunLoop  # type: ignore
    except ImportError as exc:
        print(f"[FAIL] BLE advertising unavailable: {exc}", flush=True)
        return 1

    class PeripheralDelegate(NSObject):  # type: ignore[misc, valid-type]
        def init(self):  # noqa: D401 - Objective-C initializer
            self = objc.super(PeripheralDelegate, self).init()
            if self is None:
                return None
            self.name = args.name
            self.advertised_service_cb_uuid = (
                CBUUID.UUIDWithString_(args.service_uuid)
                if args.service_uuid else None
            )
            self.gatt_service_cb_uuid = (
                CBUUID.UUIDWithString_(args.gatt_service_uuid)
                if args.gatt_service_uuid else None
            )
            self.characteristic_cb_uuid = (
                CBUUID.UUIDWithString_(args.characteristic_uuid)
                if args.characteristic_uuid else None
            )
            self.service_add_requested = False
            self.service_added = (
                self.gatt_service_cb_uuid is None or args.no_gatt_service
            )
            self.powered_on = False
            self.advertising_requested = False
            self.started = False
            self.failed = False
            return self

        def advertisement_data(self):
            advertisement = {}
            if self.name:
                advertisement[CBAdvertisementDataLocalNameKey] = self.name
            if self.advertised_service_cb_uuid is not None:
                advertisement[CBAdvertisementDataServiceUUIDsKey] = [
                    self.advertised_service_cb_uuid
                ]
            return advertisement

        def start_advertising(self, peripheral):
            self.advertising_requested = True
            if args.debug:
                print(f"[INFO] BLE advertising request={self.advertisement_data()}", flush=True)
            peripheral.startAdvertising_(self.advertisement_data())

        def maybe_start_advertising(self, peripheral):
            if (
                self.started
                or self.advertising_requested
                or not self.powered_on
                or not self.service_added
            ):
                if args.debug:
                    print(
                        "[INFO] BLE advertising wait "
                        f"started={self.started} requested={self.advertising_requested} "
                        f"powered={self.powered_on} service_added={self.service_added}",
                        flush=True,
                    )
                return
            self.start_advertising(peripheral)

        def peripheralManagerDidUpdateState_(self, peripheral):
            if args.debug:
                print(f"[INFO] BLE peripheral state={peripheral.state()}", flush=True)
            if peripheral.state() != CBPeripheralManagerStatePoweredOn:
                return
            self.powered_on = True
            if (
                self.gatt_service_cb_uuid is not None
                and not args.no_gatt_service
                and not self.service_add_requested
            ):
                service = CBMutableService.alloc().initWithType_primary_(
                    self.gatt_service_cb_uuid, True
                )
                if self.characteristic_cb_uuid is not None:
                    value = b"bl808-hal"
                    ns_value = NSData.dataWithBytes_length_(value, len(value))
                    characteristic = (
                        CBMutableCharacteristic.alloc()
                        .initWithType_properties_value_permissions_(
                            self.characteristic_cb_uuid,
                            CBCharacteristicPropertyRead,
                            ns_value,
                            CBAttributePermissionsReadable,
                        )
                    )
                    service.setCharacteristics_([characteristic])
                peripheral.addService_(service)
                self.service_add_requested = True
                if args.debug:
                    print("[INFO] BLE advertising service add requested", flush=True)
                return
            self.maybe_start_advertising(peripheral)

        def peripheralManager_didAddService_error_(self, peripheral, service, error):
            if error is not None:
                self.failed = True
                print(f"[FAIL] BLE advertising service add: {error}", flush=True)
                return
            self.service_added = True
            self.maybe_start_advertising(peripheral)

        def peripheralManagerDidStartAdvertising_error_(self, peripheral, error):
            if error is not None:
                self.failed = True
                self.advertising_requested = False
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
        if args.debug:
            print(
                "[INFO] BLE advertising final "
                f"powered={delegate.powered_on} service_requested={delegate.service_add_requested} "
                f"service_added={delegate.service_added} requested={delegate.advertising_requested} "
                f"started={delegate.started}",
                flush=True,
            )
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
            delegate.advertising_requested = False
            delegate.maybe_start_advertising(manager)
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
