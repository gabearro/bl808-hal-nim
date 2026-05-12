#!/usr/bin/env python3
"""Scan for and connect to a BLE peripheral by name or address."""

from __future__ import annotations

import argparse
import asyncio
import sys
import time
from dataclasses import dataclass


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--name", default="bl808-hal",
                        help="Advertised BLE local name to find.")
    parser.add_argument("--address", default=None,
                        help="BLE address to connect to instead of filtering by name.")
    parser.add_argument("--timeout", type=float, default=20.0,
                        help="Total scan/connect timeout in seconds.")
    parser.add_argument("--payload-hex", default=None,
                        help="Match a byte pattern in manufacturer or service data.")
    parser.add_argument("--link-only", action="store_true",
                        help="Validate the BLE link connection without GATT service discovery.")
    parser.add_argument("--hold-seconds", type=float, default=0.2,
                        help="Seconds to keep the link open after connecting.")
    parser.add_argument("--dump-limit", type=int, default=40,
                        help="Maximum advertisements to print on failure; 0 means all.")
    parser.add_argument("--dump-on-fail", action="store_true", default=True,
                        help="Print a compact list of nearby advertisements if not found.")
    return parser.parse_args()


@dataclass
class SeenDevice:
    address: str
    name: str
    local_name: str
    rssi: int | None
    manufacturer_data: dict[int, bytes]
    service_data: dict[str, bytes]
    service_uuids: list[str]
    tx_power: int | None


def hex_bytes(data: bytes, limit: int = 16) -> str:
    shown = data[:limit].hex()
    if len(data) > limit:
        return f"{shown}..."
    return shown


def matches_payload(args: argparse.Namespace, item: SeenDevice) -> bool:
    if not args.payload_hex:
        return False
    needle = bytes.fromhex(args.payload_hex.replace(":", "").replace(" ", ""))
    blobs = list(item.manufacturer_data.values()) + list(item.service_data.values())
    return any(needle in blob for blob in blobs)


async def find_device(args: argparse.Namespace):
    try:
        from bleak import BleakScanner  # type: ignore
    except ImportError as exc:
        raise RuntimeError(
            "bleak is required for BLE host validation; install requirements-hw.txt"
        ) from exc

    deadline = time.monotonic() + args.timeout
    seen: dict[str, SeenDevice] = {}
    while time.monotonic() < deadline:
        remaining = max(0.2, min(2.0, deadline - time.monotonic()))
        devices = await BleakScanner.discover(
            timeout=remaining,
            return_adv=True,
        )
        for key, value in devices.items():
            device, adv = value
            local_name = adv.local_name or ""
            dev_name = device.name or ""
            seen[key] = SeenDevice(
                address=device.address,
                name=dev_name,
                local_name=local_name,
                rssi=getattr(adv, "rssi", None),
                manufacturer_data=dict(getattr(adv, "manufacturer_data", {}) or {}),
                service_data=dict(getattr(adv, "service_data", {}) or {}),
                service_uuids=list(getattr(adv, "service_uuids", []) or []),
                tx_power=getattr(adv, "tx_power", None),
            )
            item = seen[key]
            if args.address and device.address.lower() == args.address.lower():
                return device, seen
            if not args.address and (
                dev_name == args.name
                or local_name == args.name
                or args.name in local_name
                or matches_payload(args, item)
            ):
                return device, seen
    return None, seen


def print_seen_devices(seen: dict[str, SeenDevice], limit: int) -> None:
    if not seen:
        print("[BLE] no advertisements observed", flush=True)
        return
    print("[BLE] observed advertisements:", flush=True)
    def sort_key(item: SeenDevice) -> tuple[int, str]:
        rssi = item.rssi if item.rssi is not None else -999
        return (-rssi, item.address)

    items = sorted(seen.values(), key=sort_key)
    if limit > 0:
        items = items[:limit]
    for item in items:
        label = item.local_name or item.name or "<unnamed>"
        rssi = "" if item.rssi is None else f" rssi={item.rssi}"
        tx_power = "" if item.tx_power is None else f" tx={item.tx_power}"
        details: list[str] = []
        for company_id, data in sorted(item.manufacturer_data.items()):
            details.append(f"mfg=0x{company_id:04x}:{hex_bytes(data)}")
        for uuid, data in sorted(item.service_data.items()):
            details.append(f"svcdata={uuid}:{hex_bytes(data)}")
        if item.service_uuids:
            details.append("svcs=" + ",".join(item.service_uuids[:4]))
        suffix = "" if not details else " " + " ".join(details)
        print(f"[BLE]   {item.address} name={label}{rssi}{tx_power}{suffix}", flush=True)


async def run(args: argparse.Namespace) -> int:
    try:
        from bleak import BleakClient  # type: ignore
    except ImportError as exc:
        raise RuntimeError(
            "bleak is required for BLE host validation; install requirements-hw.txt"
        ) from exc

    device, seen = await find_device(args)
    if device is None:
        print(f"[FAIL] BLE device not found: {args.address or args.name}", flush=True)
        if args.dump_on_fail:
            print_seen_devices(seen, args.dump_limit)
        return 1

    print(f"[PASS] BLE device discovered: {device.address}", flush=True)
    if args.link_only:
        details = getattr(device, "details", None)
        if isinstance(details, tuple) and len(details) == 2:
            peripheral, manager = details
            if hasattr(manager, "connect") and hasattr(manager, "disconnect"):
                disconnected = False

                def on_disconnect() -> None:
                    nonlocal disconnected
                    disconnected = True

                await manager.connect(
                    peripheral,
                    on_disconnect,
                    timeout=args.timeout,
                )
                print("[PASS] BLE connected", flush=True)
                await asyncio.sleep(max(0.0, args.hold_seconds))
                await manager.disconnect(peripheral)
                if not disconnected:
                    await asyncio.sleep(0.2)
                print("[PASS] BLE disconnected", flush=True)
                return 0
        print("[BLE] link-only backend unavailable; falling back to GATT connect", flush=True)

    async with BleakClient(device, timeout=args.timeout) as client:
        if not client.is_connected:
            print("[FAIL] BLE connect", flush=True)
            return 1
        print("[PASS] BLE connected", flush=True)
        await asyncio.sleep(max(0.0, args.hold_seconds))
    print("[PASS] BLE disconnected", flush=True)
    return 0


def main() -> int:
    args = parse_args()
    try:
        return asyncio.run(run(args))
    except Exception as exc:
        print(f"[FAIL] BLE host validation error: {type(exc).__name__}: {exc!r}", flush=True)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
