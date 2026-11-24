#!/usr/bin/env python3
"""Exercise the resident anchor's native USB command stream without writing flash."""

from __future__ import annotations

import argparse
from pathlib import Path
import struct
import time

import serial

from hw_validate import (
    HardwareRunLock, UART_FLASH_CMD_PING, UART_FLASH_REQ_GUARD,
    UART_FLASH_REQ_MAGIC, UART_FLASH_RESP_MAGIC, uart_flash_header_checksum,
)
from usb_anchor_uart_mux import DATA, OPEN, REGISTER, UNREGISTER, Decoder, frame


def ping(token: int) -> bytes:
    return struct.pack("<6I", UART_FLASH_REQ_MAGIC, UART_FLASH_REQ_GUARD,
                       UART_FLASH_CMD_PING, token, 0,
                       uart_flash_header_checksum(UART_FLASH_CMD_PING, token, 0))


class Stream:
    def __init__(self, link: serial.Serial):
        self.link = link
        self.decoder = Decoder()
        self.data = bytearray()
        self.events: list[int] = []

    def write(self, wire: bytes) -> None:
        if self.link.write(wire) != len(wire):
            raise RuntimeError("short USB write")

    def read(self) -> None:
        for kind, channel, data in self.decoder.feed(self.link.read(512)):
            if channel == 0:
                if kind == DATA:
                    self.data.extend(data)
                else:
                    self.events.append(kind)

    def wait(self, ready, description: str) -> None:
        stop = time.monotonic() + 3
        while not ready():
            if time.monotonic() >= stop:
                raise RuntimeError(f"USB timed out waiting for {description}; "
                                   f"received {len(self.data)} reply bytes, events {self.events}")
            self.read()

    def open(self) -> None:
        self.events.clear()
        self.write(frame(OPEN, 0))
        self.wait(lambda: REGISTER in self.events, "channel 0 registration")
        self.data.clear()  # Discard the unsolicited startup banner.

    def expect(self, first: int, count: int) -> None:
        expected = b"".join(struct.pack("<4I", UART_FLASH_RESP_MAGIC, 0, 1, token)
                            for token in range(first, first + count))
        self.wait(lambda: len(self.data) >= len(expected), f"ping replies at token {first}")
        if self.data[:len(expected)] != expected:
            raise RuntimeError(f"corrupt or out-of-order response at token {first}")
        del self.data[:len(expected)]


def check(path: str, bursts: int, count: int) -> None:
    with serial.Serial(path, 230400, timeout=0.05, write_timeout=3) as link:
        stream = Stream(link)
        stream.open()
        # Deliver an incomplete command header inside one complete mux frame.
        stream.write(frame(DATA, 0, ping(0x10000)[:15]))
        stream.wait(lambda: UNREGISTER in stream.events, "incomplete command timeout")
        if stream.data:
            raise RuntimeError("truncated command received a response")
        stream.open()
        stream.write(frame(DATA, 0, ping(0x10001)))
        stream.expect(0x10001, 1)
        print("PASS: interrupted command timed out; channel reopened without reboot", flush=True)

        # Disconnect between mux header and payload; idle must clear the parser.
        stream.write(frame(DATA, 0, ping(0x10002))[:10])
        time.sleep(0.7)
        stream.open()
        stream.write(frame(DATA, 0, ping(0x10003)))
        stream.expect(0x10003, 1)
        print("PASS: interrupted mux frame discarded; channel reopened without reboot", flush=True)

        for burst in range(bursts):
            first = burst * count
            stream.write(b"".join(frame(DATA, 0, ping(i)) for i in range(first, first + count)))
            stream.expect(first, count)
        print(f"PASS: {bursts * count:,} ordered replies; "
              f"{bursts * count * 24:,} request bytes, {bursts * count * 16:,} response bytes")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--uart", required=True, help="raw USB CDC port, not the mux PTY")
    parser.add_argument("--bursts", type=int, default=512)
    parser.add_argument("--burst-size", type=int, default=32)
    parser.add_argument("--work-dir", type=Path, default=Path("build/hw-validation"))
    args = parser.parse_args()
    with HardwareRunLock(args.work_dir / "hardware.lock"):
        check(args.uart, args.bursts, args.burst_size)


if __name__ == "__main__":
    main()
