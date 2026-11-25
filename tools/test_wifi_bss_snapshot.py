"""The BSS parameter batch carries the VIF's configuration as sm_set_bss_param found it.

The batch is built in one firmware step, which nothing re-enters (the
firmware step is not reentered: wifiStepEnter), so no allocator or control
callback can change the VIF while the requests are filled. The former cases
that mutated the VIF from such callbacks were removed with that guard.
"""

from pathlib import Path

import pytest

from test_wifi_auth_frames import layouts
from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program
from test_wifi_sm_bss_allocation import LIFETIME, source as allocation_source


def source() -> str:
    names = ["MeSetPsDisableReqPayload", "MmSetBssidReqPayload", "MmSetBasicRatesReqPayload",
             "MmSetBeaconIntReqPayload", "MeSetActiveReqPayload", "MmSetEdcaReqPayload"]
    types = layouts(*names)
    types += "const\n" + "".join(f"  {name}Size = sizeof({name}).uint32\n" for name in names)
    code = allocation_source(types, (FW / "scan_station_ap_me.nim").read_text())
    code = code.replace(procedure(code, "me_legacy_rate_bitfield_build"), r'''
var observedRates: array[13, uint8]
proc me_legacy_rate_bitfield_build(p: pointer; basic: uint8): uint32 =
  inc rateBuilds
  doAssert basic == 1
  if rateHook != nil: rateHook()
  observedRates = cast[ptr array[13, uint8]](p)[]
  0x1234
''', 1)
    return code + LIFETIME + r'''
var expectedRates: array[13, uint8]
proc prepareSnapshot() =
  setup()
  observedRates = default(typeof(observedRates))
  vif.basicRates = [3'u8, 2, 4, 11, 0, 0, 0, 0, 0, 0, 0, 0, 0]
  expectedRates = vif.basicRates
proc finishBatch() =
  while sm.pendingBssParams.first != nil:
    acknowledgeBss()
    sm_send_next_bss_param()
  acknowledgeBss()
  doAssert sent.len == 9 and smOwn.answer == nil
proc checkSnapshot(band = 1'u8; qosMask = 5'u8; uapsd = true) =
  doAssert observedRates == expectedRates
  let psRequest = cast[ptr MeSetPsDisableReqPayload](sent[0])
  doAssert psRequest.disable == 1 and psRequest.vifIdx == 1
  let bssid = cast[ptr MmSetBssidReqPayload](sent[1])
  doAssert bssid.bssid == [2'u8, 3, 4, 5, 6, 7] and bssid.vifIdx == 1
  let rates = cast[ptr MmSetBasicRatesReqPayload](sent[2])
  doAssert rates.rateBitfield == 0x1234 and rates.band == band and rates.vifIdx == 1
  let beacon = cast[ptr MmSetBeaconIntReqPayload](sent[3])
  doAssert beacon.interval == 100 and beacon.vifIdx == 1
  for ac in 0..3:
    let edca = cast[ptr MmSetEdcaReqPayload](sent[ac + 4])
    doAssert edca.edcaParam == 0x11223300'u32 + ac.uint32
    doAssert edca.acmFlag == ac.uint8 and edca.vifIdx == 1
    doAssert edca.uapsdAc == (uapsd and (mac_ac2uapsd[ac] and qosMask) != 0).uint8
  let active = cast[ptr MeSetActiveReqPayload](sent[8])
  doAssert active.active == 1 and active.vifIdx == 1
'''


CASES = {
    "configuration": r'''
prepareSnapshot()
sm_set_bss_param()
finishBatch()
checkSnapshot()
finish()
''',
    "missing_channel": r'''
prepareSnapshot()
vif.operChan = nil
sm_set_bss_param()
finishBatch()
checkSnapshot(band = 0)
finish()
''',
    "uapsd_snapshot_matrix": r'''
for period in [0'u32, 100'u32]:
  for gate in [0'u8, 128, 255]:
    for mask in 0'u8..15:
      prepareSnapshot()
      ps.uapsdPeriod = period
      vif.wmmQosInfo = gate
      connection.qosInfo = mask
      sm_set_bss_param()
      finishBatch()
      checkSnapshot(qosMask = mask, uapsd = period != 0 and gate >= 128)
      finish()
''',
    "maximum_rate_count": r'''
prepareSnapshot()
vif.basicRates[0] = 12
for index in 1..12: vif.basicRates[index] = index.uint8
expectedRates = vif.basicRates
sm_set_bss_param()
finishBatch()
checkSnapshot()
finish()
''',
    "invalid_rate_count": r'''
for count in [13'u8, 255]:
  prepareSnapshot()
  vif.basicRates[0] = count
  sm_set_bss_param()
  doAssert calls == 0 and rateBuilds == 0 and sent.len == 0
  doAssert allocated.len == 0 and smOwn.request == nil
  doAssert failures == @[(14'u16, 0xFFFF'u16)]
  finish()
''',
    "allocation_failure": r'''
prepareSnapshot()
failAt = 3
sm_set_bss_param()
doAssert sent.len == 0 and allocated.len == 0 and rateBuilds == 0
doAssert failures == @[(14'u16, 0xFFFF'u16)]
finish()
''',
}


@pytest.mark.parametrize("case", CASES)
@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_bss_snapshot(tmp_path: Path, case: str, mode: str) -> None:
    run_program(tmp_path, mode, source() + CASES[case])
