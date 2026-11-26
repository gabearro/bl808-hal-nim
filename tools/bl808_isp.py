#!/usr/bin/env python3
"""The BL808 boot ROM's serial protocol: load a program into RAM and run it.

With BOOT held at power-up the ROM listens on UART0 (GPIO14 TX, GPIO15 RX).
This module speaks to it directly, with pyserial and nothing from the vendor's
tools. The harness uses it to load its own RAM flash anchor
(tools/uart_flash_anchor.c), which then writes flash; it can also be run by
hand:

    tools/bl808_isp.py probe <port>
    tools/bl808_isp.py run <port> <program.bin> --address 0x62020000

The exchange (every multi-byte number little-endian):

    host: 0x55 repeated for about 6 ms, so the ROM can measure the bit rate
    host: 50 00 08 00 38 F0 00 20 00 00 00 18    (the BL808 step: one register write)
    rom:  "OK"

    command:  <id> 00 <length:2> <payload>
    answer:   "OK"                              done
              "OK" <length:2> <data>            done, with data
              "FL" <code:2>                     refused
              "PD"                              still working; another answer follows

    0x10  boot info (chip and fuse state)       -> data
    0x11  boot header, 352 bytes
    0x17  segment header, 16 bytes              -> data (the header as the ROM read it)
    0x18  segment data, up to 4080 bytes at a time
    0x19  check the image
    0x1A  run it

A RAM image is a boot header followed by segments. The header's layout is the
flash boot header's; the one sent here is made from the header of a known-good
BL808 boot image (the boot2 image the harness already flashes), with the image
described as one RAM segment.
"""
from __future__ import annotations

import argparse
import hashlib
import struct
import sys
import time
import zlib
from pathlib import Path
from typing import Any, Callable

HEADER_SIZE = 352
HEADER_MAGIC = 0x504E4642                # "BFNP"
HEADER_FLASH_CFG_MAGIC = 0x47464346      # "FCFG"
HEADER_BOOTCFG = 0x080
HEADER_NO_SEGMENT = 1 << 8               # set: one flat flash image; clear: RAM segments
HEADER_SEGMENT_COUNT = HEADER_BOOTCFG + 12
HEADER_HASH = HEADER_BOOTCFG + 16
HEADER_M0_IMAGE_ADDRESS = 0x0BC
HEADER_M0_ENTRY = 0x0C0
HEADER_CRC = 0x15C
SEGMENT_HEADER_SIZE = 16
SEGMENT_CHUNK = 4080

CMD_BOOT_INFO = 0x10
CMD_BOOT_HEADER = 0x11
CMD_SEGMENT_HEADER = 0x17
CMD_SEGMENT_DATA = 0x18
CMD_CHECK_IMAGE = 0x19
CMD_RUN_IMAGE = 0x1A

BL808_HANDSHAKE_TAIL = bytes.fromhex("5000080038F0002000000018")

# The M0's on-chip RAM is at 0x62020000 through the cache and at 0x22020000
# without it; the ROM writes through the uncached alias.
M0_CACHED_RAM = 0x62020000
M0_UNCACHED_RAM = 0x22020000
M0_RAM_ALIAS_SIZE = 0x00030000


class RomError(RuntimeError):
    pass


def crc32(data: bytes) -> int:
    return zlib.crc32(data) & 0xFFFFFFFF


def segment_load_address(entry: int) -> int:
    if M0_CACHED_RAM <= entry < M0_CACHED_RAM + M0_RAM_ALIAS_SIZE:
        return M0_UNCACHED_RAM + (entry - M0_CACHED_RAM)
    return entry


def build_segment(load_address: int, payload: bytes) -> tuple[bytes, bytes]:
    """The 16-byte segment header (address, length, reserved, CRC of the
    first twelve bytes) and the payload padded to 16 bytes."""
    data = payload + b"\x00" * (-len(payload) % 16)
    head = struct.pack("<III", load_address, len(data), crc32(data))
    return head + struct.pack("<I", crc32(head)), data


def build_ram_image(template: bytes, entry: int, payload: bytes) -> tuple[bytes, bytes, bytes]:
    """Boot header, segment header and segment data for `payload`, linked to
    run at `entry` in the M0's RAM. `template` is any valid BL808 boot image
    (only its 352-byte header is used: flash and clock settings)."""
    if len(template) < HEADER_SIZE:
        raise RomError("the boot header template is shorter than a BL808 boot header")
    header = bytearray(template[:HEADER_SIZE])
    magic, _, flash_magic = struct.unpack_from("<III", header)
    if magic != HEADER_MAGIC or flash_magic != HEADER_FLASH_CFG_MAGIC:
        raise RomError("the boot header template is not a BL808 boot image")
    if struct.unpack_from("<I", header, HEADER_CRC)[0] != crc32(bytes(header[:HEADER_CRC])):
        raise RomError("the boot header template's checksum is wrong")
    load_address = segment_load_address(entry)
    segment_header, data = build_segment(load_address, payload)
    bootcfg = struct.unpack_from("<I", header, HEADER_BOOTCFG)[0] & ~HEADER_NO_SEGMENT
    struct.pack_into("<I", header, HEADER_BOOTCFG, bootcfg)
    struct.pack_into("<I", header, HEADER_SEGMENT_COUNT, 1)
    struct.pack_into("<I", header, HEADER_M0_IMAGE_ADDRESS, load_address)
    struct.pack_into("<I", header, HEADER_M0_ENTRY, entry)
    header[HEADER_HASH:HEADER_HASH + 32] = hashlib.sha256(segment_header + data).digest()
    struct.pack_into("<I", header, HEADER_CRC, crc32(bytes(header[:HEADER_CRC])))
    return bytes(header), segment_header, data


class Rom:
    """One conversation with the boot ROM over an open pyserial port."""

    def __init__(self, ser: Any, *, log: Callable[[str], None] | None = None) -> None:
        self.ser = ser
        self.log = log or (lambda _line: None)

    def _read(self, count: int, timeout_s: float) -> bytes:
        deadline = time.monotonic() + timeout_s
        data = bytearray()
        while len(data) < count and time.monotonic() < deadline:
            data += self.ser.read(count - len(data))
        return bytes(data)

    def handshake(self, *, attempts: int = 5) -> None:
        """Let the ROM measure the bit rate and wait for its "OK"."""
        baud = int(self.ser.baudrate)
        sync = b"\x55" * max(1, int(0.006 * baud / 10))
        seen = bytearray()
        for attempt in range(attempts):
            self.ser.reset_input_buffer()
            self.ser.write(sync)
            self.ser.flush()
            time.sleep(0.3)
            self.ser.write(BL808_HANDSHAKE_TAIL)
            self.ser.flush()
            answer = self._read(2, 0.8)
            seen += answer
            if answer == b"OK":
                # Anything else the ROM sent for the sync bytes.
                time.sleep(0.05)
                self.ser.reset_input_buffer()
                self.log(f"rom: handshake ok on attempt {attempt + 1}")
                return
            time.sleep(0.2)
        raise RomError(
            "the boot ROM did not answer (hold BOOT while applying power, then retry); "
            f"received {bytes(seen).hex() or 'nothing'}")

    def command(self, command: int, payload: bytes = b"", *, data: bool = False,
                timeout_s: float = 2.0) -> bytes:
        self.ser.write(bytes([command, 0]) + struct.pack("<H", len(payload)) + payload)
        self.ser.flush()
        deadline = time.monotonic() + timeout_s
        while True:
            status = self._read(2, max(0.05, deadline - time.monotonic()))
            if status == b"OK":
                break
            if status == b"PD" and time.monotonic() < deadline:
                continue
            if status == b"FL":
                code = self._read(2, 0.5)
                raise RomError(f"the boot ROM refused command 0x{command:02X}: "
                               f"error 0x{int.from_bytes(code, 'little'):04X}")
            raise RomError(f"no answer to boot ROM command 0x{command:02X} "
                           f"(received {status.hex() or 'nothing'})")
        if not data:
            return b""
        length = self._read(2, 0.5)
        if len(length) != 2:
            raise RomError(f"boot ROM command 0x{command:02X}: the answer's length is missing")
        body = self._read(int.from_bytes(length, "little"), 1.0)
        if len(body) != int.from_bytes(length, "little"):
            raise RomError(f"boot ROM command 0x{command:02X}: the answer is cut short")
        return body

    def boot_info(self) -> bytes:
        return self.command(CMD_BOOT_INFO, data=True)

    def load(self, header: bytes, segment_header: bytes, data: bytes) -> None:
        """Send a one-segment RAM image and have the ROM check it."""
        self.command(CMD_BOOT_HEADER, header)
        echoed = self.command(CMD_SEGMENT_HEADER, segment_header, data=True)
        if len(echoed) >= 8 and struct.unpack_from("<I", echoed, 4)[0] != len(data):
            raise RomError("the boot ROM read a different segment length than was sent")
        for offset in range(0, len(data), SEGMENT_CHUNK):
            self.command(CMD_SEGMENT_DATA, data[offset:offset + SEGMENT_CHUNK])
        self.command(CMD_CHECK_IMAGE, timeout_s=5.0)
        self.log(f"rom: loaded {len(data)} bytes")

    def run(self) -> None:
        self.command(CMD_RUN_IMAGE)
        self.log("rom: image started")


def load_and_run(ser: Any, *, template: bytes, entry: int, payload: bytes,
                 log: Callable[[str], None] | None = None) -> bytes:
    """Handshake, load `payload` to run at `entry`, start it. Returns the
    ROM's boot info."""
    rom = Rom(ser, log=log)
    rom.handshake()
    info = rom.boot_info()
    header, segment_header, data = build_ram_image(template, entry, payload)
    rom.load(header, segment_header, data)
    rom.run()
    return info


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="action", required=True)
    probe = sub.add_parser("probe", help="check that the board is in its boot ROM")
    run = sub.add_parser("run", help="load a program into RAM and start it")
    for p in (probe, run):
        p.add_argument("port")
        p.add_argument("--baud", type=int, default=230400)
    run.add_argument("program", type=Path)
    run.add_argument("--address", type=lambda text: int(text, 0), default=M0_CACHED_RAM,
                     help="where the program is linked to run (default 0x62020000)")
    run.add_argument("--template", type=Path, required=True,
                     help="a valid BL808 boot image to take the boot header from")
    args = parser.parse_args(argv)

    import serial  # type: ignore

    with serial.Serial(args.port, args.baud, timeout=0.1, write_timeout=5) as ser:
        try:
            if args.action == "probe":
                rom = Rom(ser, log=print)
                rom.handshake()
                print(f"boot info: {rom.boot_info().hex()}")
            else:
                load_and_run(ser, template=args.template.read_bytes(), entry=args.address,
                             payload=args.program.read_bytes(), log=print)
        except RomError as exc:
            print(f"error: {exc}", file=sys.stderr)
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
