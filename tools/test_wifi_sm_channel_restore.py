"""Check the SM coexistence restore bridge into the selected RF PHY ABI."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program
from test_wifi_sta_tx_channel import object_type


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_sm_restore_channel_descriptor(tmp_path: Path, mode: str) -> None:
    forward = (FW / "global_state/forward_decls_mac.nim").read_text()
    wrappers = forward[
        forward.index("proc phySetChannel*(channel"):
        forward.index("proc packChannelMeta")
    ]
    sm = procedure((FW / "scan_station_ap_me.nim").read_text(),
                   "sm_set_channel_coex_connected")
    layout = (FW / "layout_types.nim").read_text()
    source = object_type(layout, "ChanCtxtDefView") + r'''
type
  SmEnv = object
    primaryFreq, centerFreq: uint16
var
  smEnv: SmEnv
  captured: ChanCtxtDefView
  forceArg: uint32
  calls: int
proc smEnvView(): ptr SmEnv = addr smEnv
proc phy_set_channel(channel: ptr ChanCtxtDefView; force: uint32) {.cdecl.} =
  doAssert channel != nil
  captured = channel[]
  forceArg = force
  inc calls
'''
    source += wrappers + sm + r'''
doAssert sizeof(ChanCtxtDefView) == 10
for sample in [(2412'u16, 2412'u16), (2437'u16, 2447'u16),
               (2484'u16, 2484'u16)]:
  smEnv = SmEnv(primaryFreq: sample[0], centerFreq: sample[1])
  captured = default(ChanCtxtDefView)
  forceArg = high(uint32)
  let previousCalls = calls
  sm_set_channel_coex_connected()
  doAssert calls == previousCalls + 1 and forceArg == 0
  doAssert captured.band == 0 and captured.chanType == 0
  doAssert captured.primFreq == sample[0]
  doAssert captured.centerFreq1 == sample[1]
  doAssert captured.centerFreq2 == 0 and captured.txPower == 0
  doAssert captured.phyEnvFlags == 0
'''
    run_program(tmp_path, mode, source)
