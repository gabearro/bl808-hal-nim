"""Exercise STA channel preparation against the real PHY channel state."""

from pathlib import Path
import re

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


def object_type(text: str, name: str) -> str:
    match = re.search(rf"^  {name} .*?\n(?=  \w|\S|\Z)", text, re.M | re.S)
    assert match
    return "type\n" + match.group(0)


PLATFORM = r'''
const MAX_VIFS = 2
const VIF_TYPE_STA = 0'u8
const MACHW_BASE = 0x24B00000'u
const wifiBleCoex = 1'u32
type
  Sm = object
    primaryFreq, centerFreq: uint16
    connectInfo: pointer
  Conn = object
    vifIdx: uint8
  Vif = object
    state, vifType: uint8
    channelFreqPair: uint32
    chanCtxt: pointer
  ChanCtxtView = object
    channel: ChanCtxtDefView
var
  sm: Sm
  conn: Conn
  vifs: array[MAX_VIFS, Vif]
  contexts: array[MAX_VIFS, ChanCtxtView]
  phy: PhyEnvView
  calls: seq[string]
  programmed: seq[uint32]
  powerUpdates: seq[uint8]
  reclaim: uint32
  reclaimQueries: int
  nimFwBleWifiRoleWindowEnabled: uint32
  nimFwDbgStaTxChannelSource, nimFwDbgStaTxChannelReq0: uint32
  nimFwDbgStaTxChannelReq1, nimFwDbgStaTxChannelVif: uint32
  nimFwDbgStaTxRfRestore, nimFwDbgStaTxRfFullRestore: uint32
template volatileLoad(p: untyped): untyped = p[]
template volatileStore(p, value: untyped) = p[] = value
template phyEnvViewPtr(): ptr PhyEnvView = addr phy
proc smEnvView(): ptr Sm = addr sm
proc connectInfoView(p: pointer): ptr Conn = cast[ptr Conn](p)
proc vifChannelForIdx(i: uint8): ptr Vif = addr vifs[i]
proc selectedMgmtTxPower(): uint32 = 17
proc crm_clk_set(bandwidth: uint32) = calls.add("clock")
proc bl808MdmSetChannel(primary, center, bandwidth: uint32) = calls.add("modem")
proc rfc_config_bandwidth(bandwidth: uint32) = calls.add("bandwidth")
proc rfPriApplyWb03RfcEntryBaseline() = discard
proc pulsePhyChannelRfWindow() = discard
proc rfc_config_channel(center: uint32) = programmed.add(center)
proc rfPhyTraceCheckpoint(phase: uint32) = discard
proc trpcLoadPowerFromConfig(kind: uint8) = calls.add("rate-power")
proc rxl_timer_int_handler() = calls.add("rx-timer")
proc rxl_cntrl_evt() = calls.add("rx-drain")
proc tpc_update_tx_power(power: uint8) =
  calls.add("tx-power")
  powerUpdates.add(power)
proc regWrite(address: uint; value: uint32) =
  doAssert address == MACHW_BASE + 0xDC and value == 0x1F0
  calls.add("mac-bandwidth")
proc wifi_hosal_rf_turn_on() = calls.add("rf-on")
proc wifiRfCoreInitMode(frequency, mode: uint32) =
  doAssert frequency == 40_000_000 and mode == wifiBleCoex
  calls.add("rf-init")
proc phy_init(cfg: pointer) =
  doAssert cfg == nil
  calls.add("phy-init")
  phy = default(PhyEnvView)
  phy.primaryFreq = 2412
  phy.centerFreq1 = 2412
proc nim_ble_coex_wifi_rf_reclaim_needed(): uint32 =
  inc reclaimQueries
  reclaim
'''


def source() -> str:
    rf = (FW / "global_state/rf_bl808_core.nim").read_text()
    layout = (FW / "layout_types.nim").read_text()
    tx = (FW / "tx_layer.nim").read_text()
    code = object_type(layout, "ChanCtxtDefView") + object_type(rf, "PhyEnvView")
    code += PLATFORM
    if "proc phyEnvCenter2Word(" in rf:
        code += procedure(rf, "phyEnvCenter2Word")
    if "proc phyChannelMatches(" in rf:
        code += procedure(rf, "phyChannelMatches")
    code += procedure(rf, "phy_set_channel")
    decls = (FW / "global_state/forward_decls_mac.nim").read_text()
    for overload in re.finditer(r"^proc phySetChannel\*\(", decls, re.M):
        code += procedure(decls[overload.start():], "phySetChannel")
    if "  nimFwStaTxPreparedBand:" in tx:
        start = tx.index("var\n  nimFwStaTxPreparedBand:")
        code += tx[start:tx.index("proc wifi_nimfw_apply_sta_tx_channel", start)]
    code += procedure(tx, "wifi_nimfw_apply_sta_tx_channel")
    code += procedure(tx, "wifi_nimfw_prepare_sta_tx_channel")
    return code + r'''
proc clearCalls() =
  calls.setLen(0)
  programmed.setLen(0)
  powerUpdates.setLen(0)
proc setup() =
  sm = default(Sm)
  conn = default(Conn)
  vifs = default(typeof(vifs))
  contexts = default(typeof(contexts))
  phy = default(PhyEnvView)
  reclaim = 0
  reclaimQueries = 0
  nimFwBleWifiRoleWindowEnabled = 0
  nimFwDbgStaTxRfRestore = 0
  nimFwDbgStaTxRfFullRestore = 0
  when declared(nimFwStaTxPreparedBand):
    nimFwStaTxPreparedBand = 0
    nimFwStaTxPreparedChanType = 0
    nimFwStaTxPreparedPrimaryFreq = 0
    nimFwStaTxPreparedCenterFreq1 = 0
    nimFwStaTxPreparedCenterFreq2 = 0
  sm.connectInfo = addr conn
  vifs[0] = Vif(state: 1, vifType: VIF_TYPE_STA, chanCtxt: addr contexts[0])
  contexts[0].channel = ChanCtxtDefView(band: 0, chanType: 0,
    primFreq: 2437, centerFreq1: 2437, txPower: 17)
  clearCalls()
proc matches(channel: ChanCtxtDefView): bool =
  phy.channelBandType == (channel.band.uint16 or (channel.chanType.uint16 shl 8)) and
    phy.primaryFreq == channel.primFreq and phy.centerFreq1 == channel.centerFreq1 and
    phy.centerFreq2 == channel.centerFreq2 and
    (phy.txPowerAndFlags shr 8).uint8 == channel.phyEnvFlags
proc checkPrepared(expected: ChanCtxtDefView) =
  doAssert matches(expected), "STA preparation left the PHY on another channel"
  doAssert phy.txPowerAndFlags == (expected.txPower.uint16 or
    (expected.phyEnvFlags.uint16 shl 8))
  doAssert powerUpdates == @[expected.txPower]
  doAssert calls[0 .. 1] == @["rx-timer", "rx-drain"]
  doAssert calls[^2 .. ^1] == @["tx-power", "mac-bandwidth"]
  doAssert programmed == @[expected.centerFreq1.uint32]
'''


CASES = {
    "intervening_retune": r'''
setup()
let expected = contexts[0].channel
wifi_nimfw_prepare_sta_tx_channel()
checkPrepared(expected)
var scanChannel = ChanCtxtDefView(band: 0, primFreq: 2462, centerFreq1: 2462, txPower: 11)
phySetChannel(addr scanChannel)
doAssert matches(scanChannel)
clearCalls()
wifi_nimfw_prepare_sta_tx_channel()
checkPrepared(expected)
doAssert nimFwDbgStaTxRfRestore == 2
clearCalls()
wifi_nimfw_prepare_sta_tx_channel()
doAssert calls.len == 0 and programmed.len == 0
doAssert nimFwDbgStaTxRfRestore == 2 and nimFwDbgStaTxRfFullRestore == 0
''',
    "channel_and_power_changes": r'''
for field in 0 .. 5:
  setup()
  wifi_nimfw_prepare_sta_tx_channel()
  let before = contexts[0].channel
  case field
  of 0: contexts[0].channel.band = 1
  of 1: contexts[0].channel.chanType = 1
  of 2: contexts[0].channel.primFreq = 2412
  of 3: contexts[0].channel.centerFreq1 = 2422
  of 4: contexts[0].channel.centerFreq2 = 2452
  else: contexts[0].channel.txPower = 23
  doAssert matches(before)
  clearCalls()
  wifi_nimfw_prepare_sta_tx_channel()
  if field == 5:
    doAssert calls.len == 0 and phy.txPowerAndFlags == before.txPower.uint16
  else:
    checkPrepared(contexts[0].channel)
  clearCalls()
  wifi_nimfw_prepare_sta_tx_channel()
  doAssert calls.len == 0
''',
    "reset_and_reclaim": r'''
for enabled in [false, true]:
  for requested in [false, true]:
    setup()
    wifi_nimfw_prepare_sta_tx_channel()
    nimFwBleWifiRoleWindowEnabled = enabled.uint32
    reclaim = requested.uint32
    clearCalls()
    wifi_nimfw_prepare_sta_tx_channel()
    doAssert reclaimQueries == enabled.int
    doAssert nimFwDbgStaTxRfFullRestore == (enabled and requested).uint32
    if enabled and requested:
      doAssert calls[0 .. 2] == @["rf-on", "rf-init", "phy-init"]
      doAssert matches(contexts[0].channel)
    else:
      doAssert calls.len == 0
setup()
wifi_nimfw_prepare_sta_tx_channel()
phy_init(nil)
clearCalls()
wifi_nimfw_prepare_sta_tx_channel()
checkPrepared(contexts[0].channel)
''',
    "sources_and_phy_contract": r'''
setup()
sm.primaryFreq = 2412
sm.centerFreq = 2412
wifi_nimfw_prepare_sta_tx_channel()
doAssert nimFwDbgStaTxChannelSource == 1 and phy.primaryFreq == 2412
setup()
vifs[0].channelFreqPair = 2462'u32 or (2462'u32 shl 16)
wifi_nimfw_prepare_sta_tx_channel()
doAssert nimFwDbgStaTxChannelSource == 5 and phy.primaryFreq == 2462
setup()
sm.connectInfo = nil
wifi_nimfw_prepare_sta_tx_channel()
doAssert nimFwDbgStaTxChannelSource == 2 and phy.primaryFreq == 2437
setup()
sm.connectInfo = nil
vifs[0].chanCtxt = nil
wifi_nimfw_prepare_sta_tx_channel()
doAssert nimFwDbgStaTxChannelSource == 0 and calls.len == 0
setup()
var desired = contexts[0].channel
phy_set_channel(addr desired, 1)
phy_set_channel(nil, 0)
doAssert calls.len == 0 and not matches(desired)
phy_set_channel(addr desired, 0)
doAssert matches(desired)
clearCalls()
phy_set_channel(addr desired, 0)
doAssert calls.len == 0 and programmed.len == 0
''',
}


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("case", CASES)
def test_sta_tx_channel(tmp_path: Path, mode: str, case: str) -> None:
    run_program(tmp_path, mode, source() + CASES[case])
