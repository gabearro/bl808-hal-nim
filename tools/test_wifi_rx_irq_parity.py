"""Exercise the RX control status gate found at rxl_cntrl.o +0xDA."""

from pathlib import Path

import pytest

from test_wifi_message_allocation import run_program
from test_wifi_rx_admission import admission_source


@pytest.mark.parametrize("mode", ["checked", "release"])
def test_control_uses_vendor_associated_status_bits(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, admission_source(r'''
for flags in [0x02006000'u32, 0x20026000'u32]:
  reset(0x0208'u16, 24)
  let status = flags or (12'u32 shl 15)
  rxHeaderHwDescAt(0).hwFlags = status
  rxCaptureStation(rxSwTableDescAt(0), status)
  let associated = flags == 0x02006000'u32
  doAssert rxStationIdentities[0].associated == associated
  doAssert rxStationIdentities[0].station == (if associated: 4'u8 else: 0xFF'u8)
  dispatch()
  doAssert powerCalls == (if associated: 1 else: 0)
  doAssert clockCalls == (if associated: 1 else: 0)
  doAssert upperCalls == 1 and freed == 1 and recovered == 0
  doAssert interrupts and not rxlControlActive

reset(0x0208'u16, 24)
let associatedStatus = 0x02006000'u32 or (12'u32 shl 15)
rxHeaderHwDescAt(0).hwFlags = associatedStatus
rxCaptureStation(rxSwTableDescAt(0), associatedStatus)
inc stationEpochs[4]
dispatch()
doAssert powerCalls == 0 and clockCalls == 0 and upperCalls == 0
doAssert freed == 1 and recovered == 0 and interrupts
'''))
