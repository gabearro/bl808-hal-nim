"""tools/bl808_isp.py against a model of the BL808 boot ROM's serial side.

The model checks what the ROM checks: the handshake, the framing, the boot
header's checksum and image hash, the segment header's checksum and the
segment data's, and that an image is only run after it was checked.
"""
from __future__ import annotations

import hashlib
import struct
import sys
import zlib
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import bl808_isp  # noqa: E402


def crc(data: bytes) -> int:
    return zlib.crc32(data) & 0xFFFFFFFF


def template_image() -> bytes:
    """A flash boot image's header as the vendor's tools write it: one flat
    image (bit 8 of the boot configuration) that runs from flash."""
    header = bytearray(352)
    struct.pack_into("<III", header, 0, 0x504E4642, 1, 0x47464346)
    struct.pack_into("<I", header, 0x64, 0x47464350)
    struct.pack_into("<I", header, 0x80, 0x72CF0100)
    struct.pack_into("<I", header, 0x8C, 0xBD60)
    struct.pack_into("<I", header, 0xB0, 1)
    struct.pack_into("<I", header, 0xC0, 0x58000000)
    struct.pack_into("<I", header, 0x15C, crc(bytes(header[:0x15C])))
    return bytes(header) + b"\xA5" * 64


class FakeRom:
    """The serial port as the ROM answers on it."""

    def __init__(self, *, deaf_attempts: int = 0, pending: bool = False,
                 refuse: int | None = None) -> None:
        self.baudrate = 230400
        self.rx = bytearray()          # host -> ROM, not yet parsed
        self.tx = bytearray()          # ROM -> host
        self.synced = False
        self.deaf_attempts = deaf_attempts
        self.pending = pending
        self.refuse = refuse
        self.header: bytes | None = None
        self.segment: tuple[int, int, int] | None = None
        self.memory: dict[int, bytes] = {}
        self.received = bytearray()
        self.checked = False
        self.running_at: int | None = None
        self.commands: list[int] = []

    # pyserial's surface
    def write(self, data: bytes) -> int:
        self.rx += data
        self._step()
        return len(data)

    def read(self, count: int) -> bytes:
        out = bytes(self.tx[:count])
        del self.tx[:count]
        return out

    def flush(self) -> None:
        pass

    def reset_input_buffer(self) -> None:
        self.tx.clear()

    def _ok(self, data: bytes | None = None) -> None:
        if self.pending:
            self.tx += b"PD"
        self.tx += b"OK"
        if data is not None:
            self.tx += struct.pack("<H", len(data)) + data

    def _fail(self, code: int) -> None:
        self.tx += b"FL" + struct.pack("<H", code)

    def _step(self) -> None:
        if not self.synced:
            tail = bl808_isp.BL808_HANDSHAKE_TAIL
            if not self.rx.endswith(tail):
                return
            sync = self.rx[:-len(tail)]
            assert len(sync) >= 100 and set(sync) == {0x55}
            self.rx.clear()
            if self.deaf_attempts > 0:
                self.deaf_attempts -= 1
                return
            self.synced = True
            self.tx += b"OK"
            return
        while len(self.rx) >= 4:
            command, zero, length = struct.unpack_from("<BBH", self.rx)
            assert zero == 0
            if len(self.rx) < 4 + length:
                return
            payload = bytes(self.rx[4:4 + length])
            del self.rx[:4 + length]
            self.commands.append(command)
            if command == self.refuse:
                self._fail(0x0204)
            else:
                self._command(command, payload)

    def _command(self, command: int, payload: bytes) -> None:
        if command == 0x10:
            self._ok(bytes(range(24)))
        elif command == 0x11:
            if len(payload) != 352 or struct.unpack_from("<I", payload, 0x15C)[0] != crc(payload[:0x15C]):
                return self._fail(0x0204)
            if struct.unpack_from("<I", payload, 0x80)[0] & (1 << 8):
                return self._fail(0x0217)        # a flash image cannot be loaded into RAM
            self.header = payload
            self._ok()
        elif command == 0x17:
            if self.header is None or len(payload) != 16 or \
                    struct.unpack_from("<I", payload, 12)[0] != crc(payload[:12]):
                return self._fail(0x0208)
            self.segment = struct.unpack_from("<III", payload)
            self.segment_header = payload
            self.received.clear()
            self._ok(payload)
        elif command == 0x18:
            assert self.segment is not None and 0 < len(payload) <= 4080
            self.received += payload
            self._ok()
        elif command == 0x19:
            assert self.header is not None and self.segment is not None
            address, length, data_crc = self.segment
            data = bytes(self.received)
            want = self.header[0x90:0xB0]
            if len(data) != length or crc(data) != data_crc or \
                    hashlib.sha256(self.segment_header + data).digest() != want or \
                    struct.unpack_from("<I", self.header, 0x8C)[0] != 1:
                return self._fail(0x020B)
            self.memory[address] = data
            self.checked = True
            self._ok()
        elif command == 0x1A:
            if not self.checked:
                return self._fail(0x020C)
            self.running_at = struct.unpack_from("<I", self.header, 0xC0)[0]
            self._ok()
        else:
            self._fail(0x0101)


def test_a_program_is_loaded_into_ram_and_started() -> None:
    rom = FakeRom()
    program = bytes((i * 7 + 1) & 0xFF for i in range(9001))    # three chunks, not a multiple of 16
    info = bl808_isp.load_and_run(rom, template=template_image(), entry=0x62020000, payload=program)
    assert info == bytes(range(24))
    assert rom.commands == [0x10, 0x11, 0x17, 0x18, 0x18, 0x18, 0x19, 0x1A]
    # Through the uncached alias, padded to whole 16-byte blocks; run through the cache.
    assert list(rom.memory) == [0x22020000]
    assert rom.memory[0x22020000] == program + b"\x00" * 7
    assert rom.running_at == 0x62020000
    assert struct.unpack_from("<I", rom.header, 0xBC)[0] == 0x22020000


def test_the_header_keeps_the_templates_flash_and_clock_settings() -> None:
    template = template_image()
    header, segment_header, data = bl808_isp.build_ram_image(template, 0x62020000, b"\x13\x00\x00\x00")
    changed = [i for i in range(352) if header[i] != template[i]]
    allowed = set(range(0x80, 0x84)) | set(range(0x8C, 0xB0)) | set(range(0xBC, 0xC4)) | \
        set(range(0x15C, 0x160))
    assert set(changed) <= allowed
    assert struct.unpack_from("<I", header, 0x80)[0] == 0x72CF0000
    assert len(data) == 16 and len(segment_header) == 16


def test_the_handshake_is_retried_and_a_silent_board_is_reported() -> None:
    rom = FakeRom(deaf_attempts=2)
    bl808_isp.Rom(rom).handshake()
    assert rom.synced
    with pytest.raises(bl808_isp.RomError, match="hold BOOT"):
        bl808_isp.Rom(FakeRom(deaf_attempts=99)).handshake(attempts=2)


def test_a_pending_answer_is_waited_out() -> None:
    rom = FakeRom(pending=True)
    bl808_isp.load_and_run(rom, template=template_image(), entry=0x62020000, payload=b"\x01" * 64)
    assert rom.running_at == 0x62020000


@pytest.mark.parametrize("command", [0x11, 0x17, 0x18, 0x19, 0x1A])
def test_a_refused_command_stops_the_load(command: int) -> None:
    rom = FakeRom(refuse=command)
    with pytest.raises(bl808_isp.RomError, match=f"0x{command:02X}.*0x0204"):
        bl808_isp.load_and_run(rom, template=template_image(), entry=0x62020000, payload=b"\x01" * 64)
    assert rom.running_at is None


def test_a_bad_template_is_refused_before_anything_is_sent() -> None:
    good = template_image()
    for bad in (good[:100], b"\x00" * 352, good[:0x10] + b"\xFF" + good[0x11:]):
        rom = FakeRom()
        with pytest.raises(bl808_isp.RomError):
            bl808_isp.load_and_run(rom, template=bad, entry=0x62020000, payload=b"\x01" * 64)
        assert 0x11 not in rom.commands


def test_the_harnesss_boot2_image_is_a_usable_template() -> None:
    import hw_validate
    try:
        boot2 = hw_validate.find_default_boot2_image()
    except RuntimeError:
        pytest.skip("no BL808 boot2 image on this machine")
    rom = FakeRom()
    bl808_isp.load_and_run(rom, template=boot2.read_bytes(), entry=hw_validate.UART_FLASH_ANCHOR_ENTRY,
                           payload=b"\x6F\x00\x00\x00" * 8)
    assert rom.running_at == hw_validate.UART_FLASH_ANCHOR_ENTRY
