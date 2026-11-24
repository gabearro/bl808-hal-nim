#!/usr/bin/env python3
"""Expose the Nim USB anchor and registered application UARTs as local PTYs.

The USB device has one CDC ACM transport. This helper creates PTYs when the
device registers channels; --uart1/--uart2 also support the older host-opened
bridge mode.
Point hw_validate.py --uart at the anchor PTY. PTYs exist while this process
runs.
"""

from __future__ import annotations

import argparse
import os
import select
import struct
import sys
import time
import tty

import serial
from serial.tools import list_ports

MAGIC = b"\xA5\x5A"
REGISTER = 1
DATA = 2
UNREGISTER = 3
OPEN = 4
CLOSE = 5
CREDIT = 6
MAX_PAYLOAD = 48
MAX_PENDING_PTY_BYTES = 4096
REGISTRATION_VERSION = 1
ROLE_ANCHOR = 0
ROLE_CONSOLE = 1
ROLE_UART = 2
ROLE_BRIDGE = 3
VIRTUAL_UART = 0xFF
ANCHOR_VID = 0x1209
ANCHOR_PID = 0xB808


def registration_label(channel: int, payload: bytes) -> str | None:
    """Describe a firmware registration, including the legacy empty payload."""
    if not 0 <= channel <= 255:
        return None
    if not payload:
        return "Anchor console/flash" if channel == 0 else f"UART{channel}"
    if len(payload) != 7 or payload[0] != REGISTRATION_VERSION:
        return None
    role, uart = payload[1], payload[2]
    baud = struct.unpack_from("<I", payload, 3)[0]
    if role == ROLE_ANCHOR and channel == 0:
        return "Anchor console/flash"
    if role == ROLE_CONSOLE and channel == 3 and uart in (0, 1, 2, VIRTUAL_UART):
        location = "USB" if uart == VIRTUAL_UART else f"UART{uart}"
        return f"App console ({location}, {baud} baud)" if baud else f"App console ({location})"
    if role in (ROLE_UART, ROLE_BRIDGE) and uart in (1, 2) and channel == uart:
        return f"UART{uart} ({baud} baud)" if baud else f"UART{uart}"
    return None


def find_mux_port(preferred: str, identity: tuple[str | None, str | None] | None,
                  available: list) -> str | None:
    """Find the same USB anchor after macOS assigns a new serial device path."""
    matches = [port for port in available
               if port.vid == ANCHOR_VID and port.pid == ANCHOR_PID]
    if identity is not None:
        serial_number, location = identity
        if location:
            located = [port for port in matches if port.location == location]
            if len(located) == 1:
                return located[0].device
        if serial_number:
            numbered = [port for port in matches
                        if port.serial_number == serial_number]
            if len(numbered) == 1:
                return numbered[0].device
    if any(port.device == preferred for port in matches):
        return preferred
    if len(matches) == 1:
        return matches[0].device
    return preferred if identity is None and os.path.exists(preferred) else None


def frame(kind: int, channel: int, payload: bytes = b"") -> bytes:
    if len(payload) > MAX_PAYLOAD:
        raise ValueError("mux payload is too large")
    return MAGIC + bytes((kind, channel, len(payload))) + payload


class Decoder:
    def __init__(self) -> None:
        self.buffer = bytearray()

    def feed(self, data: bytes) -> list[tuple[int, int, bytes]]:
        self.buffer.extend(data)
        result = []
        while len(self.buffer) >= 5:
            if self.buffer[:2] != MAGIC:
                del self.buffer[0]
                continue
            length = self.buffer[4]
            if length > MAX_PAYLOAD:
                del self.buffer[0]
                continue
            if len(self.buffer) < 5 + length:
                break
            result.append((self.buffer[2], self.buffer[3],
                           bytes(self.buffer[5:5 + length])))
            del self.buffer[:5 + length]
        return result


class HostFlowControl:
    """Track device-granted bytes for application-owned input channels."""

    def __init__(self) -> None:
        self.flow_channels: set[int] = set()
        self.credits: dict[int, int] = {}

    def register(self, channel: int, payload: bytes) -> None:
        if payload and payload[1] in (ROLE_CONSOLE, ROLE_UART):
            self.flow_channels.add(channel)
            self.credits[channel] = 0
        else:
            self.unregister(channel)

    def unregister(self, channel: int) -> None:
        self.flow_channels.discard(channel)
        self.credits.pop(channel, None)

    def grant(self, channel: int, payload: bytes) -> None:
        if channel in self.flow_channels and len(payload) == 2:
            self.credits[channel] = min(
                65535, self.credits[channel] + struct.unpack("<H", payload)[0]
            )

    def allowance(self, channel: int) -> int:
        if channel not in self.flow_channels:
            return MAX_PAYLOAD
        return min(MAX_PAYLOAD, self.credits[channel])

    def sent(self, channel: int, count: int) -> None:
        if channel in self.flow_channels:
            self.credits[channel] -= count


def run_session(link: serial.Serial, requested: dict[int, int]) -> None:
    ports: dict[int, tuple[int, int]] = {}
    pending_output: dict[int, bytearray] = {}
    flow = HostFlowControl()
    decoder = Decoder()
    next_open = 0.0
    try:
        while True:
            now = time.monotonic()
            if now >= next_open:
                for channel, baud in requested.items():
                    if channel not in ports:
                        payload = b"" if channel == 0 else struct.pack("<I", baud)
                        link.write(frame(OPEN, channel, payload))
                next_open = now + 1.0

            read_fds = [master for channel, (master, _) in ports.items()
                        if flow.allowance(channel) > 0]
            if all(len(data) < MAX_PENDING_PTY_BYTES
                   for data in pending_output.values()):
                read_fds.append(link.fileno())
            write_fds = [ports[channel][0] for channel, data in pending_output.items()
                         if data and channel in ports]
            ready, writable, _ = select.select(read_fds, write_fds, [], 0.1)
            if link.fileno() in ready:
                data = link.read(256)
                if not data:
                    raise serial.SerialException("USB anchor disconnected")
                for kind, channel, payload in decoder.feed(data):
                    if kind == REGISTER:
                        label = registration_label(channel, payload)
                        if label is None:
                            continue
                        flow.register(channel, payload)
                        if channel not in ports:
                            master, slave = os.openpty()
                            tty.setraw(slave)
                            os.set_blocking(master, False)
                            ports[channel] = master, slave
                            pending_output[channel] = bytearray()
                            print(f"{label}: {os.ttyname(slave)}", flush=True)
                    elif kind == UNREGISTER and channel in ports:
                        master, slave = ports.pop(channel)
                        pending_output.pop(channel, None)
                        flow.unregister(channel)
                        os.close(master)
                        os.close(slave)
                    elif kind == CREDIT:
                        flow.grant(channel, payload)
                    elif kind == DATA and channel in ports:
                        pending_output[channel].extend(payload)

            for channel, (master, _) in list(ports.items()):
                if master not in writable or not pending_output[channel]:
                    continue
                try:
                    written = os.write(master, pending_output[channel])
                except BlockingIOError:
                    continue
                if written:
                    del pending_output[channel][:written]

            for channel, (master, _) in list(ports.items()):
                if master not in ready:
                    continue
                allowed = flow.allowance(channel)
                if allowed == 0:
                    continue
                try:
                    data = os.read(master, allowed)
                except OSError:
                    continue
                if data:
                    packet = frame(DATA, channel, data)
                    if link.write(packet) != len(packet):
                        raise serial.SerialException("incomplete USB mux write")
                    flow.sent(channel, len(data))
    finally:
        for channel in requested:
            if channel == 0:
                continue
            try:
                link.write(frame(CLOSE, channel))
            except (OSError, serial.SerialException):
                pass
        for master, slave in ports.values():
            os.close(master)
            os.close(slave)


def run(device: str, requested: dict[int, int]) -> None:
    identity: tuple[str | None, str | None] | None = None
    while True:
        available = list(list_ports.comports())
        current = find_mux_port(device, identity, available)
        if current is None:
            time.sleep(0.5)
            continue
        port_info = next((port for port in available if port.device == current), None)
        try:
            with serial.Serial(current, 230400, timeout=0, write_timeout=2) as link:
                if port_info is not None:
                    identity = port_info.serial_number, port_info.location
                print(f"USB anchor connected: {current}", flush=True)
                run_session(link, requested)
        except (OSError, serial.SerialException) as exc:
            print(f"USB anchor disconnected: {exc}; waiting to reconnect",
                  file=sys.stderr, flush=True)
            time.sleep(0.5)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mux", required=True, help="CDC UART mux device path")
    parser.add_argument("--uart1", type=int, metavar="BAUD", help="open UART1")
    parser.add_argument("--uart2", type=int, metavar="BAUD", help="open UART2")
    args = parser.parse_args()
    requested = {0: 0, **{i: baud for i, baud in ((1, args.uart1), (2, args.uart2))
                          if baud is not None}}
    for channel, baud in requested.items():
        if channel == 0:
            continue
        if not 9600 <= baud <= 3_000_000:
            parser.error("UART baud must be between 9600 and 3000000")
    try:
        run(args.mux, requested)
    except KeyboardInterrupt:
        pass
    except (OSError, serial.SerialException) as exc:
        print(f"USB UART mux stopped: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc


if __name__ == "__main__":
    main()
