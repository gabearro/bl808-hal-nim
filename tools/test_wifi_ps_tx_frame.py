"""Check TX power-save notifications and their diagnostic callback boundary."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program
from test_wifi_ps_frame_logging import PLATFORM


def source() -> str:
    platform = PLATFORM.replace("direction == 1", "direction == 0")
    platform = platform.replace("  of 1005:", """  of 1097:
    doAssert format == cstring("tx frame: UAPSD\\r\\n")
  of 1005:""")
    platform = platform.replace('  events.add("log:" & $line)',
                                '  events.add("log:" & $line)\n'
                                '  if onLog != nil: onLog()')
    support = r'''
const
  STA_INFO_TAB_ENTRIES = 7
type Station = object
  instNbr: uint8
var
  stations: array[STA_INFO_TAB_ENTRIES, Station]
  stationEpochs: array[STA_INFO_TAB_ENTRIES, uint32]
  resetting: bool
proc staInfoForIdx(index: uint8): ptr Station =
  doAssert index < STA_INFO_TAB_ENTRIES
  addr stations[index]
proc staDeleteEpoch(index: uint8): uint32 = stationEpochs[index]
proc txlResetting(): bool = resetting
proc prepare() =
  setup()
  ps.enabled = 1
  vif.vifType = VIF_TYPE_STA
  vif.state = 1
  vif.flags = 0xA5A50006'u32
  stations = default(typeof(stations))
  for station in stations.mitems: station.instNbr = vif.vifIdx
  stationEpochs = default(typeof(stationEpochs))
  rxVifEpochs = default(typeof(rxVifEpochs))
  txResetEpoch = 0
  resetting = false
  onLog = nil
'''
    power = (FW / "power_save.nim").read_text()
    return ("var onLog: proc()\n" + platform + support
            + procedure(power, "psTxTidToAc") + procedure(power, "ps_check_tx_frame"))


CASES = {
    "vendor_state_and_logging": r'''
for hasLogger in [false, true]:
  for enabled in [false, true]:
    for kind in [0'u8, 1, 2, 4]:
      for active in [false, true]:
        for tid in 0'u8 .. 8:
          for bitmap in 0'u8 .. 15:
            prepare()
            logging = hasLogger
            ps.enabled = enabled.uint8
            vif.vifType = kind
            vif.state = active.uint8
            vif.uapsdBitmap = bitmap
            let before = vif
            let eligible = enabled and kind == VIF_TYPE_STA and active
            let ac = [1'u8, 0, 0, 1, 2, 2, 3, 3, 3][tid]
            let trigger = eligible and (bitmap and (1'u8 shl ac)) != 0
            onLog = proc() =
              doAssert vif == before, "state changed before the vendor diagnostic"
            doAssert not ps_check_tx_frame(0, tid)
            var expected = before
            if trigger:
              expected.flags = expected.flags or 8
              expected.psLastTime = macNow
            doAssert vif == expected
            doAssert lookups == trigger.int
            if trigger:
              doAssert events == (if hasLogger: @["log:1097", "time"] else: @["time"])
              doAssert messages == (if hasLogger:
                @[(1097.cint, "tx frame: UAPSD\r\n")] else: @[])
            else:
              doAssert messages.len == 0
              doAssert events == (if eligible: @["traffic"] else: @[])
''',
    "diagnostic_reentry": r'''
for change in 0 .. 10:
  prepare()
  vif.uapsdBitmap = 2
  var expected: Vif
  onLog = proc() =
    case change
    of 0: inc txResetEpoch
    of 1: resetting = true
    of 2: inc stationEpochs[0]
    of 3: inc rxVifEpochs[1]
    of 4: stations[0].instNbr = 0
    of 5: vif.state = 0
    of 6: vif.vifType = 2
    of 7: ps.enabled = 0
    of 8: vif.vifIdx = 0
    of 9: vif.uapsdBitmap = 0
    else: mappedVif = nil
    vif.flags = 0x12340000
    vif.psLastTime = 0x55667788
    expected = vif
  doAssert not ps_check_tx_frame(0, 0)
  doAssert messages == @[(1097.cint, "tx frame: UAPSD\r\n")]
  doAssert events == @["log:1097"]
  doAssert vif == expected, "wrote PS state after the diagnostic changed its owner"

# An unrelated station/VIF change must not suppress a current TX notification.
prepare()
vif.uapsdBitmap = 2
onLog = proc() =
  inc stationEpochs[1]
  inc rxVifEpochs[0]
doAssert not ps_check_tx_frame(0, 0)
doAssert events == @["log:1097", "time"]
doAssert vif.flags == 0xA5A5000E'u32 and vif.psLastTime == macNow
''',
    "input_boundaries": r'''
for station in 0 .. 255:
  for tid in 0 .. 255:
    if station < STA_INFO_TAB_ENTRIES and tid <= 8: continue
    prepare()
    vif.uapsdBitmap = 15
    let before = vif
    doAssert not ps_check_tx_frame(station.uint8, tid.uint8)
    doAssert vif == before and events.len == 0 and messages.len == 0 and lookups == 0
for index in [2'u8, 7, 255]:
  prepare()
  stations[0].instNbr = index
  let before = vif
  doAssert not ps_check_tx_frame(0, 0)
  doAssert vif == before and events.len == 0 and lookups == 0
prepare()
resetting = true
vif.uapsdBitmap = 2
let before = vif
doAssert not ps_check_tx_frame(0, 0)
doAssert vif == before and events.len == 0 and lookups == 0
prepare()
vif.vifIdx = 0
doAssert not ps_check_tx_frame(0, 0)
doAssert events.len == 0 and messages.len == 0 and lookups == 0
prepare()
mappedVif = nil
doAssert not ps_check_tx_frame(0, 0)
doAssert events.len == 0 and messages.len == 0 and lookups == 0
''',
}


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
@pytest.mark.parametrize("case", CASES)
def test_ps_tx_frame(tmp_path: Path, mode: str, case: str) -> None:
    run_program(tmp_path, mode, source() + CASES[case])
