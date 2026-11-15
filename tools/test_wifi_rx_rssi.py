"""Compare the production RX-vector decoder with the pinned vendor arithmetic."""

from pathlib import Path
import re

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program
from test_wifi_mgt_receive import management_source


def source() -> str:
    layout = (FW / "layout_types.nim").read_text()
    vector = re.search(r"(?ms)^  PhyRxVectorView\b.*?(?=^  \w|\Z)", layout)
    assert vector
    return (
        "type\n" + vector.group(0)
        + layout[layout.index("template phyRxVectorAt("):layout.index("proc rssiRaw*")]
        + procedure(layout, "rssiRaw")
        + procedure((FW / "power_save.nim").read_text(), "phyif_utils_decode")
        + r'''
proc decode(format, rate: uint32; raw: uint16;
            lowFormat = 0'u32; lowRate = 0'u32): int8 =
  var vector = PhyRxVectorView(
    formatBitsWord: (format shl 16) or lowFormat,
    mcsBitsWord: (rate shl 12) or (lowRate shl 2),
    rssiLo: (raw and 255).uint8, rssiHi: (raw shr 8).uint8)
  let before = vector
  var output = [0x5A'i8, 0'i8, 0x35'i8]
  doAssert phyif_utils_decode(addr vector, addr output[1]) == 0
  doAssert vector == before, "RSSI decode modified the RX vector"
  doAssert output[0] == 0x5A and output[2] == 0x35,
    "RSSI decode wrote outside the output byte"
  output[1]
'''
    )


CASES = {
    "format_and_rate_fields": r'''
# Bits 18:16 select format. Legacy rate bits are 15:12, not 7:2.
for format in 0'u32 .. 7:
  for rate in 0'u32 .. 15:
    let expected = if format <= 1 and rate <= 3: -43'i8 else: -49'i8
    for lowFormat in 0'u32 .. 3:
      for lowRate in [0'u32, 3, 4, 63]:
        # 0xE83E is -6082 as int16 and +62 in the legacy RSSI byte.
        doAssert decode(format, rate, 0xE83E, lowFormat, lowRate) == expected,
          "format/rate selection read unrelated RX-vector bits"
''',
    "signed_wide_rssi": r'''
for config in [(2'u32, 0'u32), (7'u32, 3'u32),
               (0'u32, 4'u32), (1'u32, 15'u32)]:
  let (format, rate) = config
  for sample in [(-32768, -12), (-12201, -100), (-12200, -100),
                 (-6100, -50), (-123, -1), (-122, -1), (-121, 0),
                 (-1, 0), (0, 0), (121, 0), (122, 1), (123, 1),
                 (6100, 50), (32767, 12)]:
    let (raw, expected) = sample
    doAssert decode(format, rate, cast[uint16](raw.int16)) == expected.int8,
      "wide RSSI must use signed division and store the low result byte"
''',
    "legacy_rssi_byte": r'''
for format in 0'u32 .. 1:
  for rate in 0'u32 .. 3:
    for highByte in [0'u16, 0x55, 0xFF]:
      for sample in [(0, 0), (1, 0), (2, -1), (62, -43), (90, -62),
                     (100, -70), (127, -88), (128, 89), (156, 70),
                     (166, 62), (194, 43), (254, 1), (255, 0)]:
        let (lowByte, expected) = sample
        doAssert decode(format, rate, (highByte shl 8) or lowByte.uint16,
                        3, 63) == expected.int8,
          "legacy RSSI must scale the signed RSSI byte, not the rate index"
''',
}


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
@pytest.mark.parametrize("case", CASES)
def test_rx_rssi_decode(tmp_path: Path, mode: str, case: str) -> None:
    run_program(tmp_path, mode, source() + CASES[case])


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_decoded_rssi_reaches_management_indication(tmp_path: Path, mode: str) -> None:
    code = management_source()
    decoder = source().split("\nproc decode(", 1)[0]
    code = code.replace(procedure(code, "phyif_utils_decode"), decoder)
    run_program(tmp_path, mode, code + r'''
for fc in [0x50'u16, 0xB0'u16]:
  for sample in [(2'u32, 0'u32, 0xE82C'u16, -50'i8),
                 (0'u32, 4'u32, 0xE82C'u16, -50'i8),
                 (1'u32, 3'u32, 0xAB64'u16, -70'i8)]:
    let (format, rate, raw, expected) = sample
    reset(fc, 0)
    let vector = phyRxVectorAt(addr rx.phyVector[0])
    vector.formatBitsWord = format shl 16
    vector.mcsBitsWord = rate shl 12
    vector.rssiLo = (raw and 255).uint8
    vector.rssiHi = (raw shr 8).uint8
    discard rxu_mgt_frame_check(addr desc, 4)
    doAssert sent == 1
    let indication = rxuMgtIndMsgAt(addr message[0])
    doAssert indication.rssi == expected and indication.noiseFloor == expected,
      "management indication lost the decoded RSSI"
''')
