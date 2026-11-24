"""Exercise AP management admission without changing teardown TX behavior."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import procedure
from test_wifi_message_allocation import run_program

ROOT = Path(__file__).resolve().parents[1]
FW = ROOT / "src/bl808/wifi/fw"

PLATFORM = r"""
const
  MAX_VIFS = 2
  VIF_TYPE_AP = 2'u8
  KeMsgConsumed = 0.cint
type Vif = object
  vifType, state: uint8
type MessageHeader = object
  paramLen: uint32
var
  header = MessageHeader(paramLen: 64)
  vifs: array[MAX_VIFS, Vif]
  apmPendingCancelMask, apmStoppingVifs, startupMask: uint8
  rxVifEpochs: array[MAX_VIFS, uint32]
  calls: seq[string]
proc vifChannelForIdx(i: uint8): ptr Vif =
  doAssert i < MAX_VIFS
  addr vifs[i]
proc apmStartPendingForVif(i: uint8): bool = (startupMask and (1'u8 shl i)) != 0
proc rxuMgtDispatchView(p: pointer): ptr RxuMgtDispatchView = cast[ptr RxuMgtDispatchView](p)
proc keMsgHdrFromPayload(p: pointer): ptr MessageHeader = addr header
proc apm_probe_req_handler(p: pointer) = calls.add("probe")
proc apm_auth_handler(p: pointer) = calls.add("auth")
proc apm_assoc_req_handler(p: pointer; reassoc: uint32) = calls.add("assoc" & $reassoc)
proc apm_deauth_handler(p: pointer) = calls.add("deauth")
proc apm_disassoc_handler(p: pointer) = calls.add("disassoc")
proc apm_beacon_handler(p: pointer) = calls.add("beacon")
"""

CHECKS = r"""
var message: RxuMgtDispatchView
for vif in 0'u8 .. 1:
  for sample in [(0xB0'u16, "auth"), (0x00'u16, "assoc0"), (0x20'u16, "assoc1"),
                 (0xC0'u16, "deauth"), (0xA0'u16, "disassoc"), (0x80'u16, "beacon")]:
    for phase in 0 .. 5:
      vifs = default(typeof(vifs))
      vifs[vif] = Vif(vifType: 2, state: 1)
      calls.setLen(0)
      apmPendingCancelMask = 0
      apmStoppingVifs = 0
      startupMask = 0
      header.paramLen = 64
      case phase
      of 1: vifs[vif].state = 0
      of 2: apmPendingCancelMask = 1'u8 shl vif
      of 3: apmStoppingVifs = 1'u8 shl vif
      of 4: startupMask = 1'u8 shl vif
      of 5: vifs[vif].vifType = 0
      else: discard
      message = RxuMgtDispatchView(frameCtrl: sample[0], vifIdx: vif)
      doAssert rxu_mgt_ind_handler_apm(addr message) == KeMsgConsumed
      doAssert calls == (if phase == 0: @[sample[1]] else: newSeq[string]())
      doAssert apmSessionCurrent(vif, rxVifEpochs[vif]) == (phase == 0)
      inc rxVifEpochs[vif]
      doAssert not apmSessionCurrent(vif, rxVifEpochs[vif] - 1)

for invalid in [2'u8, 7, 255]:
  calls.setLen(0)
  message = RxuMgtDispatchView(frameCtrl: 0xB0, vifIdx: invalid)
  doAssert rxu_mgt_ind_handler_apm(addr message) == KeMsgConsumed
  doAssert not apmSessionCurrent(invalid, 0) and calls.len == 0
doAssert rxu_mgt_ind_handler_apm(nil) == KeMsgConsumed

# The probe handler, not this dispatcher, resolves wildcard VIF requests.
message = RxuMgtDispatchView(frameCtrl: 0x40, vifIdx: 255)
discard rxu_mgt_ind_handler_apm(addr message)
doAssert calls == @["probe"]

for length in 0'u32 .. 8'u32:
  calls.setLen(0)
  header.paramLen = length
  message = RxuMgtDispatchView(frameCtrl: 0xB0, vifIdx: 0)
  doAssert rxu_mgt_ind_handler_apm(addr message) == KeMsgConsumed
  doAssert calls.len == 0
"""


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_ap_receive_dispatch(tmp_path: Path, mode: str) -> None:
    layout = (FW / "layout_types.nim").read_text()
    name = "RxuMgtDispatchView"
    code = "type\n  " + name + layout.split("  " + name, 1)[1].split("\n\n  ", 1)[0] + "\n"
    code += PLATFORM
    handlers = (FW / "task_handlers.nim").read_text()
    code += procedure(handlers, "apmVifRunning")
    code += procedure((FW / "scan_station_ap_me.nim").read_text(), "apmSessionCurrent")
    code += procedure(handlers, "rxu_mgt_ind_handler_apm")
    run_program(tmp_path, mode, code + CHECKS)
