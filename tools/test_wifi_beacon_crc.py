"""Exercise the streaming CRC and the beacon IE bytes supplied to it."""

from pathlib import Path
import zlib

import pytest

from test_wifi_beacon_probe_policy import source as probe_source
from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


CRC_SOURCE = FW.parent / "support/utils_facade_parts/bin_tlv_crc.nim"
HELPERS = r'''
template ptrAt(base: pointer; offset: uint): pointer =
  cast[pointer](cast[uint](base) + offset)
proc zero(p: pointer; length: uint) = zeroMem(p, length.int)
'''


def crc_source() -> str:
    code = CRC_SOURCE.read_text()
    start = code.find("const WifiCrc32Table")
    if start < 0:
        start = code.index("proc utils_crc32_stream_init")
    return HELPERS + code[start:].replace("utils_crc32_stream_", "candidate_crc32_stream_")


def beacon_source() -> str:
    code = probe_source()
    for name in ("utils_crc32_stream_init", "utils_crc32_stream_feed_block",
                 "utils_crc32_stream_results"):
        code = code.replace(procedure(code, name), "", 1)
    code = code.replace("frameStorage: array[36, uint8]", "frameStorage: array[512, uint8]")
    code = code.replace(procedure(code, "macIeAt"), r'''
proc macIeAt(p: uint): ptr MacIeView =
  let first = cast[uint](addr frameStorage[36])
  let limit = cast[uint](addr frameStorage[0]) + rx.frameLen.uint
  doAssert p >= first and p + 2 <= limit, "IE header exceeds the received frame"
  cast[ptr MacIeView](p)
''', 1)
    code = code.replace(procedure(code, "macIePayload"), r'''
proc macIePayload(p: ptr MacIeView): ptr UncheckedArray[uint8] =
  doAssert p.len >= 2, "TIM countdown exceeds its element"
  cast[ptr UncheckedArray[uint8]](cast[uint](p) + 2)
''', 1)
    wrappers = r'''
proc utils_crc32_stream_init(p: pointer) = candidate_crc32_stream_init(p)
proc utils_crc32_stream_feed_block(p, data: pointer; length: uint32) =
  candidate_crc32_stream_feed_block(p, cast[ptr uint8](data), length)
proc utils_crc32_stream_results(p: pointer): uint32 = candidate_crc32_stream_results(p)
'''
    return crc_source() + wrappers + code + r'''
proc loadIes(bytes: openArray[uint8]) =
  setup()
  doAssert bytes.len <= frameStorage.len - 36
  for index, value in bytes: frameStorage[index + 36] = value
  rx.frameLen = (36 + bytes.len).uint16
'''


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_streaming_crc_matches_standard_results(tmp_path: Path, mode: str) -> None:
    checks = ""
    for data in (b"", b"123456789", b"bl808\0wifi", bytes(range(256))):
        values = ", ".join(f"{value}'u8" for value in data) if data else "0'u8"
        crc = zlib.crc32(data)
        checks += f'''
block:
  var data: array[{max(len(data), 1)}, uint8] = [{values}]
  for split in [0, {len(data) // 2}, {len(data)}]:
    var storage = [0xA5A5A5A5'u32, 0x12345678'u32, 0x5A5A5A5A'u32]
    candidate_crc32_stream_init(addr storage[1])
    doAssert storage[1] == high(uint32)
    candidate_crc32_stream_feed_block(addr storage[1], addr data[0], split.uint32)
    let tail = if split < {len(data)}: addr data[split] else: nil
    candidate_crc32_stream_feed_block(addr storage[1], tail, ({len(data)} - split).uint32)
    doAssert candidate_crc32_stream_results(addr storage[1]) == {crc}'u32
    doAssert candidate_crc32_stream_results(addr storage[1]) == {crc}'u32
    doAssert storage[1] == ({crc}'u32 xor high(uint32))
    doAssert storage[0] == 0xA5A5A5A5'u32 and storage[2] == 0x5A5A5A5A'u32
'''
    run_program(tmp_path, mode, crc_source() + checks)


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_beacon_crc_uses_non_tim_payloads(tmp_path: Path, mode: str) -> None:
    first = zlib.crc32(bytes([100, 0, 0, 0]) + b"abc\x06") ^ 0xFFFFFFFF
    second = zlib.crc32(bytes([100, 0, 0, 0]) + b"abc\x0b") ^ 0xFFFFFFFF
    run_program(tmp_path, mode, beacon_source() + f'''
loadIes([0'u8, 3, 97, 98, 99, 5, 4, 0, 3, 0, 1, 3, 1, 6])
doAssert mm_check_beacon(addr rx, addr vif, addr sta, addr timOut) == 1
doAssert vif.beaconCrc == {first}'u32
doAssert timOut == pointerAddrU32(addr frameStorage[41])
doAssert mm_check_beacon(addr rx, addr vif, addr sta, addr timOut) == 0
frameStorage[43] = 2
frameStorage[46] = 128
doAssert mm_check_beacon(addr rx, addr vif, addr sta, addr timOut) == 0
frameStorage[49] = 11
doAssert mm_check_beacon(addr rx, addr vif, addr sta, addr timOut) == 1
doAssert vif.beaconCrc == {second}'u32
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_short_tim_is_not_published_or_read(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, beacon_source() + r'''
for size in 0 .. 3:
  var bytes = newSeq[uint8](size + 2)
  bytes[0] = 5
  bytes[1] = size.uint8
  loadIes(bytes)
  sta.listenWindowDuration = 0
  process()
  doAssert timOut == 0, "a short TIM was published to power-save processing"
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_trailing_and_truncated_elements_stop_at_frame_end(tmp_path: Path, mode: str) -> None:
    expected = zlib.crc32(bytes([100, 0, 0, 0]) + b"Z") ^ 0xFFFFFFFF
    run_program(tmp_path, mode, beacon_source() + f'''
for bytes in [@[0'u8, 1, 90, 221], @[0'u8, 1, 90, 221, 4, 1]]:
  loadIes(bytes)
  process()
  doAssert timOut == 0 and vif.beaconCrc == {expected}'u32
''')
