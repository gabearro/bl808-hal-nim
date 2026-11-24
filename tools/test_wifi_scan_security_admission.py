"""Exercise the frame handler's vendor security-IE admission branches."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


def source() -> str:
    frame_handler = procedure((FW / "scan_station_ap_me.nim").read_text(),
                              "scanu_frame_handler")
    admission = frame_handler.split(
        "  # Security flag filtering for undirected scan\n", 1)[1].split(
        "  # Find or allocate scan result entry\n", 1)[0]
    return r'''
type WpaParsedInfoView = object
  caps: uint8
var
  scanu_env: tuple[bssidFilterEnabled: uint8]
  forwards: int
proc ke_msg_forward_and_change_id(frame: pointer; id: uint16;
                                   dest, source: uint8) =
  doAssert frame == cast[pointer](0x1000)
  doAssert id == 0x804 and dest == 9 and source == 2
  inc forwards
proc admit(flags: uint32; hasWpa, hasRsn: bool; caps: uint8;
           directed = false): bool =
  let frame = cast[pointer](0x1000)
  let scanFlags = flags
  let wpaIePtr = if hasWpa: cast[pointer](0x2000) else: nil
  let rsnIePtr = if hasRsn: cast[pointer](0x3000) else: nil
  let secInfo = WpaParsedInfoView(caps: caps)
  scanu_env.bssidFilterEnabled = directed.uint8
''' + "  # Security flag filtering for undirected scan\n" + admission + r'''
  true
proc check(flags: uint32; hasWpa, hasRsn: bool; caps: uint8;
           expected: bool) =
  forwards = 0
  doAssert admit(flags, hasWpa, hasRsn, caps) == expected
  doAssert forwards == (not expected).int
  forwards = 0
  doAssert admit(flags, hasWpa, hasRsn, caps, directed = true)
  doAssert forwards == 0
'''


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_vendor_security_ie_admission_matrix(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
# Flags 0x200 alone bypasses the security-IE filter, including open frames.
for caps in [0'u8, 0x40, 0x80, 0xC0]:
  check(0x200, false, false, caps, true)
  check(0x200, true, false, caps, true)
  check(0x200, false, true, caps, true)

# Flag 0x400 dominates 0x200 and requires an RSN IE with capability bit 7.
for flags in [0x400'u32, 0x600'u32]:
  for caps in [0'u8, 0x40, 0x80, 0xC0]:
    let accepted = (caps and 0x80) != 0
    check(flags, false, false, caps, false)
    check(flags, true, false, caps, false)
    check(flags, false, true, caps, accepted)
    check(flags, true, true, caps, accepted)

# Without either flag, RSN capability bit 6 is the only rejection here.
for caps in [0'u8, 0x40, 0x80, 0xC0]:
  check(0, false, false, caps, true)
  check(0, true, false, caps, true)
  check(0, false, true, caps, (caps and 0x40) == 0)
''')
