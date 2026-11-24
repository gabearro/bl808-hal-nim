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
const MAX_CHAN_CTXT = 2
const VIF_TYPE_STA = 0'u8
const VIF_TYPE_AP = 2'u8
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
    contextIndexOrMarker: uint8
  ChanEnv = object
    currentCtxt: pointer
var
  sm: Sm
  conn: Conn
  vifs: array[MAX_VIFS, Vif]
  contexts: array[MAX_VIFS, ChanCtxtView]
  chanEnv: ChanEnv
  chanCtxtEpochs: array[MAX_CHAN_CTXT, uint32]
  phy: PhyEnvView
  calls: seq[string]
  programmed: seq[uint32]
  powerUpdates: int
  retuneTypeDuringRfc: bool
  reclaim: uint32
  reclaimQueries: int
  irqEnabled = true
  nimFwBleWifiRoleWindowEnabled: uint32
  nimFwDbgStaTxChannelSource, nimFwDbgStaTxChannelReq0: uint32
  nimFwDbgStaTxChannelReq1, nimFwDbgStaTxChannelVif: uint32
  nimFwDbgStaTxRfRestore, nimFwDbgStaTxRfFullRestore: uint32
template volatileLoad(p: untyped): untyped = p[]
template volatileStore(p, value: untyped) = p[] = value
template phyEnvViewPtr(): ptr PhyEnvView = addr phy
proc smEnvView(): ptr Sm = addr sm
proc connectInfoView(p: pointer): ptr Conn = cast[ptr Conn](p)
proc irqSave(): uint32 =
  result = irqEnabled.uint32
  irqEnabled = false
proc irqRestore(saved: uint32) = irqEnabled = saved != 0
proc vifChannelForIdx(i: uint8): ptr Vif = addr vifs[i]
proc chanCtxtForIdx(i: uint8): ptr ChanCtxtView = addr contexts[i]
proc chanEnvView(): ptr ChanEnv = addr chanEnv
proc selectedMgmtTxPower(): uint32 = 17
proc crm_clk_set(bandwidth: uint32) = calls.add("clock")
proc bl808MdmSetChannel(primary, center, bandwidth: uint32) = calls.add("modem")
proc rfc_config_bandwidth(bandwidth: uint32) = calls.add("bandwidth")
proc rfPriApplyWb03RfcEntryBaseline() = discard
proc pulsePhyChannelRfWindow() = discard
proc rfc_config_channel(center: uint32) =
  programmed.add(center)
  if retuneTypeDuringRfc:
    phy.channelBandType = (phy.channelBandType and 0x00FF'u16) or 0x0100'u16
proc rfPhyTraceCheckpoint(phase: uint32) = discard
proc trpcLoadPowerFromConfig(kind: uint8) = calls.add("rate-power")
proc rxl_timer_int_handler() = calls.add("rx-timer")
proc rxl_cntrl_evt() = calls.add("rx-drain")
proc tpc_update_tx_power(unusedVifIdx: uint8) =
  doAssert irqEnabled
  calls.add("tx-power")
  inc powerUpdates
proc regWrite(address: uint; value: uint32) =
  doAssert address == MACHW_BASE + 0xDC and value == 0x1F0
  calls.add("mac-bandwidth")
proc wifi_hosal_rf_turn_on() = calls.add("rf-on")
proc wifiRfCoreInitMode(frequency, mode: uint32) =
  doAssert frequency == 40_000_000 and mode == wifiBleCoex
  calls.add("rf-init")
  for i in 0 ..< phy.initCfgWords.len:
    phy.initCfgWords[i] = 0
proc phy_init(cfg: pointer) =
  var initCfgWords: array[9, uint32]
  if cfg != nil:
    let words = cast[ptr UncheckedArray[uint32]](cfg)
    for i in 0 ..< initCfgWords.len:
      initCfgWords[i] = words[i]
  calls.add("phy-init")
  phy = default(PhyEnvView)
  phy.initCfgWords = initCfgWords
  phy.primaryFreq = 2412
  phy.centerFreq1 = 2412
proc nim_ble_coex_wifi_rf_reclaim_needed(): uint32 =
  inc reclaimQueries
  reclaim
'''


def source(forced_freq: int = 0) -> str:
    rf = (FW / "global_state/rf_bl808_core.nim").read_text()
    layout = (FW / "layout_types.nim").read_text()
    tx = (FW / "tx_layer.nim").read_text()
    code = (object_type(layout, "ChanCtxtDefView") + object_type(rf, "PhyEnvView")
            + object_type(layout, "MmChanCtxtUpdatePayload"))
    code += f"const WifiAuthForceFreq = {forced_freq}\n" + PLATFORM
    if "proc phyEnvCenter2Word(" in rf:
        code += procedure(rf, "phyEnvCenter2Word")
    if "proc phyChannelMatches(" in rf:
        code += procedure(rf, "phyChannelMatches")
    code += procedure(rf, "phy_set_channel")
    decls = (FW / "global_state/forward_decls_mac.nim").read_text()
    for overload in re.finditer(r"^proc phySetChannel\*\(", decls, re.M):
        code += procedure(decls[overload.start():], "phySetChannel")
    code += procedure((FW / "kernel_mac_channel.nim").read_text(), "chan_ctxt_update")
    if "  nimFwStaTxPreparedBand:" in tx:
        start = tx.index("var\n  nimFwStaTxPreparedBand:")
        code += tx[start:tx.index("proc wifi_nimfw_apply_sta_tx_channel", start)]
    code += procedure(tx, "wifi_nimfw_apply_sta_tx_channel")
    code += procedure(tx, "wifi_nimfw_prepare_sta_tx_channel")
    return code + r'''
proc clearCalls() =
  calls.setLen(0)
  programmed.setLen(0)
  powerUpdates = 0
proc setup() =
  sm = default(Sm)
  conn = default(Conn)
  vifs = default(typeof(vifs))
  contexts = default(typeof(contexts))
  phy = default(PhyEnvView)
  reclaim = 0
  retuneTypeDuringRfc = false
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
  doAssert powerUpdates == 1
  doAssert calls[0 .. 1] == @["rx-timer", "rx-drain"]
  doAssert calls[^2 .. ^1] == @["tx-power", "mac-bandwidth"]
  doAssert programmed == @[expected.centerFreq1.uint32]
'''


CASES = {
    "pending_join_ignores_previous_channel": r'''
setup()
vifs[0].state = 0
vifs[0].channelFreqPair = 2437'u32 or (2437'u32 shl 16)
vifs[1] = Vif(state: 1, vifType: VIF_TYPE_STA, chanCtxt: addr contexts[1])
contexts[1].channel = contexts[0].channel
contexts[0].channel = ChanCtxtDefView(primFreq: 2462, centerFreq1: 2462,
  txPower: 13, phyEnvFlags: 3)
let desired = contexts[0].channel
sm.primaryFreq = 2437
sm.centerFreq = 2437
phy_set_channel(addr desired, 0)
clearCalls()
wifi_nimfw_prepare_sta_tx_channel()
doAssert nimFwDbgStaTxChannelSource == 4 and nimFwDbgStaTxChannelVif == 0
doAssert matches(desired) and calls.len == 0, "auth undid the scheduler's retune"
phy_set_channel(addr contexts[1].channel, 0)
clearCalls()
wifi_nimfw_prepare_sta_tx_channel()
checkPrepared(desired)
doAssert (sm.primaryFreq, sm.centerFreq) == (2437'u16, 2437'u16)
''',
    "pending_join_without_context": r'''
for missing in 0..3:
  setup()
  conn.vifIdx = 1
  sm.primaryFreq = 2412
  sm.centerFreq = 2412
  vifs[1] = Vif(state: 1, vifType: VIF_TYPE_STA, chanCtxt: addr contexts[1],
    channelFreqPair: 2462'u32 or (2462'u32 shl 16))
  case missing
  of 0: conn.vifIdx = 255
  of 1: vifs[1].vifType = VIF_TYPE_AP
  of 2: vifs[1].chanCtxt = nil
  else: discard # linked, but not programmed yet
  nimFwBleWifiRoleWindowEnabled = 1
  reclaim = 1
  wifi_nimfw_prepare_sta_tx_channel()
  doAssert nimFwDbgStaTxChannelSource == 0 and nimFwDbgStaTxChannelVif == high(uint32)
  doAssert calls.len == 0 and reclaimQueries == 0, "join borrowed a cached channel"
''',
    "connected_cache_metadata": r'''
for other in 0..3:
  setup()
  sm.connectInfo = nil
  vifs[1] = Vif(state: 1, vifType: VIF_TYPE_STA, chanCtxt: addr contexts[1])
  let desired = ChanCtxtDefView(band: 0, chanType: 1, primFreq: 2452,
    centerFreq1: 2462, centerFreq2: 0, txPower: 13)
  contexts[1].channel = desired
  contexts[0].channel = desired
  contexts[0].channel.txPower = 2
  case other
  of 0: vifs[0].vifType = VIF_TYPE_AP
  of 1: vifs[0].state = 0
  of 2: contexts[0].channel.centerFreq1 = 2452
  else: contexts[0].channel.primFreq = 2472
  sm.primaryFreq = desired.primFreq
  sm.centerFreq = desired.centerFreq1
  wifi_nimfw_prepare_sta_tx_channel()
  checkPrepared(desired)
  doAssert nimFwDbgStaTxChannelSource == 1 and nimFwDbgStaTxChannelVif == 0x101
  clearCalls()
  wifi_nimfw_prepare_sta_tx_channel()
  doAssert calls.len == 0
  sm.connectInfo = addr conn
  conn.vifIdx = 0
  clearCalls()
  wifi_nimfw_prepare_sta_tx_channel()
  let expectedVif = if other == 0: high(uint32) elif other == 1: 0'u32 else: 0x100'u32
  doAssert nimFwDbgStaTxChannelVif == expectedVif, "live attempt borrowed another STA"
''',
    "detached_channel_move": r'''
setup()
sm.connectInfo = nil
sm.primaryFreq = 2437
sm.centerFreq = 2437
let updated = ChanCtxtDefView(band: 0, chanType: 1, primFreq: 2452,
  centerFreq1: 2462, txPower: 13, phyEnvFlags: 3)
chanEnv.currentCtxt = vifs[0].chanCtxt
var update = MmChanCtxtUpdatePayload(ctxtIdx: 0, band: updated.band,
  secChan: updated.chanType, primFreq: updated.primFreq, centerFreq1: updated.centerFreq1,
  txPower: updated.txPower, txPowerTailPadding: updated.phyEnvFlags)
chan_ctxt_update(addr update)
doAssert contexts[0].channel == updated and matches(updated)
clearCalls()
wifi_nimfw_prepare_sta_tx_channel()
doAssert calls.len == 0, "TX reverted an already applied context update"
doAssert nimFwDbgStaTxChannelSource == 2 and nimFwDbgStaTxChannelVif == 0x100
phy.primaryFreq = 2412
wifi_nimfw_prepare_sta_tx_channel()
checkPrepared(updated)
doAssert (sm.primaryFreq, sm.centerFreq) == (2437'u16, 2437'u16)
clearCalls()
vifs[1] = Vif(state: 1, vifType: VIF_TYPE_STA, chanCtxt: addr contexts[1])
contexts[1].channel = ChanCtxtDefView(primFreq: 2412, centerFreq1: 2412, txPower: 7)
wifi_nimfw_prepare_sta_tx_channel()
doAssert nimFwDbgStaTxChannelSource == 1 and nimFwDbgStaTxChannelVif == high(uint32)
doAssert phy.primaryFreq == 2437 and phy.centerFreq1 == 2437
''',
    "five_ghz_band_without_context": r'''
setup()
sm.connectInfo = nil
vifs[0].chanCtxt = nil
sm.primaryFreq = 5180
sm.centerFreq = 5180
wifi_nimfw_prepare_sta_tx_channel()
doAssert nimFwDbgStaTxChannelSource == 1
doAssert phy.primaryFreq == 5180 and (phy.channelBandType and 0xFF) == 1
setup()
sm.connectInfo = nil
vifs[0].chanCtxt = nil
vifs[0].channelFreqPair = 5180'u32 or (5180'u32 shl 16)
wifi_nimfw_prepare_sta_tx_channel()
doAssert nimFwDbgStaTxChannelSource == 3
doAssert phy.primaryFreq == 5180 and (phy.channelBandType and 0xFF) == 1
setup()
contexts[0].channel = ChanCtxtDefView(band: 1, primFreq: 5180,
  centerFreq1: 5180, txPower: 13)
sm.primaryFreq = 5180
sm.centerFreq = 5180
wifi_nimfw_prepare_sta_tx_channel()
doAssert nimFwDbgStaTxChannelSource == 4
checkPrepared(contexts[0].channel)
''',
    "empty_context_fallback": r'''
setup()
sm.connectInfo = nil
contexts[0].channel.primFreq = 0
contexts[0].channel.centerFreq1 = 0
vifs[0].channelFreqPair = 2462'u32 or (2462'u32 shl 16)
wifi_nimfw_prepare_sta_tx_channel()
doAssert nimFwDbgStaTxChannelSource == 3
doAssert phy.primaryFreq == 2462 and phy.centerFreq1 == 2462
setup()
sm.connectInfo = nil
contexts[0].channel.primFreq = 0
contexts[0].channel.centerFreq1 = 0
vifs[1] = Vif(state: 1, vifType: VIF_TYPE_STA, chanCtxt: addr contexts[1])
contexts[1].channel = ChanCtxtDefView(band: 0, chanType: 1,
  primFreq: 2462, centerFreq1: 2472, txPower: 9)
wifi_nimfw_prepare_sta_tx_channel()
doAssert nimFwDbgStaTxChannelSource == 2
checkPrepared(contexts[1].channel)
''',
    "partial_pair_fallback": r'''
setup()
sm.connectInfo = nil
contexts[0].channel.primFreq = 0
contexts[0].channel.centerFreq1 = 0
vifs[0].channelFreqPair = 2462'u32 shl 16
vifs[1] = Vif(state: 1, vifType: VIF_TYPE_STA, chanCtxt: addr contexts[1])
contexts[1].channel = ChanCtxtDefView(band: 0, chanType: 1,
  primFreq: 2462, centerFreq1: 2472, txPower: 9)
wifi_nimfw_prepare_sta_tx_channel()
doAssert nimFwDbgStaTxChannelSource == 2
checkPrepared(contexts[1].channel)
''',
    "late_phy_type_snapshot": r'''
setup()
var desired = contexts[0].channel
desired.chanType = 1
retuneTypeDuringRfc = true
phy_set_channel(addr desired, 0)
doAssert matches(desired)
doAssert programmed == @[desired.centerFreq1.uint32]
doAssert calls == @["clock", "modem", "bandwidth"],
  "rate-power decision must use the PHY type after RF programming"
''',
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
    "reclaim_preserves_phy_config": r'''
setup()
phy.initCfgWords[0] = 1
nimFwBleWifiRoleWindowEnabled = 1
reclaim = 1
wifi_nimfw_prepare_sta_tx_channel()
doAssert phy.initCfgWords[0] == 1
for i in 1 ..< phy.initCfgWords.len:
  doAssert phy.initCfgWords[i] == 0
doAssert matches(contexts[0].channel)

setup()
for i in 0 ..< phy.initCfgWords.len:
  phy.initCfgWords[i] = 0xA5A50000'u32 or i.uint32
let expected = phy.initCfgWords
nimFwBleWifiRoleWindowEnabled = 1
reclaim = 1
wifi_nimfw_prepare_sta_tx_channel()
doAssert phy.initCfgWords == expected
doAssert matches(contexts[0].channel)
doAssert calls[0 .. 2] == @["rf-on", "rf-init", "phy-init"]
''',
    "sources_and_phy_contract": r'''
setup()
sm.primaryFreq = 2412
sm.centerFreq = 2412
sm.connectInfo = nil
vifs[0].chanCtxt = nil
wifi_nimfw_prepare_sta_tx_channel()
doAssert nimFwDbgStaTxChannelSource == 1 and phy.primaryFreq == 2412
setup()
vifs[0].channelFreqPair = 2462'u32 or (2462'u32 shl 16)
sm.connectInfo = nil
vifs[0].chanCtxt = nil
wifi_nimfw_prepare_sta_tx_channel()
doAssert nimFwDbgStaTxChannelSource == 3 and phy.primaryFreq == 2462
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


def test_detached_forced_channel(tmp_path: Path) -> None:
    run_program(tmp_path, "checked", source(forced_freq=2412) + r'''
setup()
sm.connectInfo = nil
sm.primaryFreq = 2412
sm.centerFreq = 2412
wifi_nimfw_prepare_sta_tx_channel()
doAssert nimFwDbgStaTxChannelSource == 1 and nimFwDbgStaTxChannelVif == high(uint32)
doAssert phy.primaryFreq == 2412 and phy.centerFreq1 == 2412
''')
