"""BL808 PHY startup writes and the handoff to the first MAC channel request."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW
from test_wifi_message_allocation import run_program
from test_wifi_rf_channel_entry import modem_source, rf_procedure
from test_wifi_rf_power_replay import RF, object_type


def native_phy_source() -> str:
    rf = RF.read_text()
    code = modem_source() + object_type(rf, "PhyEnvView")
    code += object_type((FW / "layout_types.nim").read_text(), "ChanCtxtDefView")
    code += r'''
var
  phy: PhyEnvView
  nimFwDbgPhyInitCount, nimFwDbgPhyInitPhase: uint32
  nimFwDbgPhyAgcCopyCount, nimFwDbgPhyWifiLdpcAbsent: uint32
  previousCenter: uint16 = 255
proc phyEnvViewPtr(): ptr PhyEnvView = addr phy
proc volatileLoad[T](p: ptr T): T = p[]
proc volatileStore[T](p: ptr T, value: T) = p[] = value
proc programBl808PhyAgcRegisters() = mmioWrites.add((1'u, 0'u32))
proc programBl808PhyAgcTable() = mmioWrites.add((2'u, 0'u32))
proc programBl808PhyLdpcTable() = mmioWrites.add((3'u, 0'u32))
proc trpc_init() =
  doAssert phy.centerFreq1 == 255 and phy.channelBandType == 0x0500
  mmioWrites.add((4'u, 0'u32))
proc rfc_config_channel(mhz: uint32) =
  doAssert phy.centerFreq1 == previousCenter
  mmioWrites.add((5'u, mhz))
proc rfPhyTraceCheckpoint(phase: uint32) = discard
proc rfBankHasBl808WlanCal(): bool = true
proc crm_clk_set(kind: uint32) = doAssert false
proc rfc_config_bandwidth(kind: uint32) = doAssert false
proc trpcLoadPowerFromConfig(kind: uint8) = doAssert false
proc phyInitValidateClock() = doAssert false
proc phyInitProgramBasebandAndAgc() = doAssert false
proc phyInitProgramReceiveTail() = doAssert false
proc phyInitProgramInitialChannel() = doAssert false
'''
    code += rf_procedure(rf, "copyPhyInitCfg")
    code += rf_procedure(rf, "phyChannelMatches")
    code += RF.with_name("rf_bl808_phy_init.nim").read_text()
    # Do not include the adjacent firmware-only include block in this fixture.
    code += rf_procedure(rf, "modemVersionReg")
    for name in ("phy_set_channel", "phy_init", "phy_rc_isr", "phy_get_version", "phy_vht_supported"):
        code += rf_procedure(rf, name).replace("defined(bl808WifiNativeWlanCalibration)", "true")
    return code


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_native_phy_stores_before_one_explicit_channel_request(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, native_phy_source() + r'''
setup()
for word in modemWords.mitems: word = randomWord()
var wanted = modemWords
var expected: seq[tuple[address: uint, value: uint32]]
template put(offset: int; keep, set: uint32) =
  wanted[offset div 4] = (wanted[offset div 4] and keep) or set
  expected.add((cast[uint](addr modemWords[offset div 4]), wanted[offset div 4]))
put(0x800, 0, 0)
put(0x888, 0, 0x1111)
put(0x888, 0, 0)
put(0x820, 0, 0x130D)
put(0x3024, 0xFFC0FFFF'u32, 0x002D0000)
put(0x89C, 0, high(uint32))
put(0x824, 0, 0x10D)
put(0x834, high(uint32), 1)
put(0x818, 0xFFFBFFFF'u32, 0)
put(0x830, 0xFFFF00FF'u32, 0x1B00)
put(0x830, 0xFFFFFF00'u32, 0xF)
put(0x83C, 0, 0x04920492)
put(0x874, 0xF7FFFFFF'u32, 0x08000000)
put(0xB500, 0xFFFFCFFF'u32, 0x2000)
put(0xC80C, 0x00FFFFFF'u32, 0x97000000'u32)
put(0xB004, 0, 1)
put(0xB390, 0xFFFFFFFC'u32, 1)
put(0xB3BC, 0, 0x003D0900)
put(0xB414, high(uint32), 0x100)
expected.add([(1'u, 0'u32), (2'u, 0'u32)])
put(0x838, 0, 0xB4)
put(0x88C, 0, 0x1C13)
put(0x898, 0, 0x02D00438)
put(0x858, 0xFFFFFF00'u32, 0)
put(0x81C, 0, 0x0F0F)
put(0x834, 0x00FFFFFF'u32, 0x06000000)
put(0x818, 0, 0x01880C06)
put(0x860, 0, 0x7F03)
expected.add((3'u, 0'u32))
rf70.channelTuneCtrl26c = 0xAABBCCDD'u32
expected.add((cast[uint](addr rf70.channelTuneCtrl26c), 0x850BCCDD'u32))
put(0xC018, 0xFFFFFC00'u32, 0x50)
expected.add((4'u, 0'u32))

var cfg: array[9, uint32]
for word in cfg.mitems: word = randomWord()
phy_init(addr cfg[0])
doAssert modemWords == wanted and phy.initCfgWords == cfg
doAssert phy.primaryFreq == 255 and phy.centerFreq2 == 255 and nimFwDbgPhyInitPhase == 6
let ram = cast[uint](addr phy)
var bus: typeof(mmioWrites)
for entry in mmioWrites:
  if entry.address < ram or entry.address >= ram + sizeof(phy).uint: bus.add(entry)
doAssert bus == expected, "unexpected native PHY writes, or tuned before the MAC request"

mmioWrites.setLen(0)
var ch = ChanCtxtDefView(primFreq: 2412, centerFreq1: 2412, txPower: 16)
let reset = cast[uint](addr wifiModemRegs().phyChannelPulse888)
phy_set_channel(addr ch, 0)
doAssert mmioWrites == @[(reset, 0x1111'u32), (reset, 0'u32), (5'u, 2412'u32)]
doAssert phy.primaryFreq == 2412 and phy.centerFreq1 == 2412
previousCenter = 2412
mmioWrites.setLen(0)
ch.centerFreq2 = 2420
ch.phyEnvFlags = 3
phy_set_channel(addr ch, 0)
doAssert mmioWrites.len == 0 and phy.centerFreq2 == 2420 and phy.txPowerAndFlags == 0x0310

let state = phy
for band, center in [(0'u8, 2411'u16), (0'u8, 2485'u16), (2'u8, 5200'u16)].items:
  ch.band = band
  ch.centerFreq1 = center
  phy_set_channel(addr ch, 0)
doAssert phy == state and mmioWrites.len == 0
ch.band = 1
ch.centerFreq1 = 5200
phy_set_channel(addr ch, 1)
doAssert phy == state and mmioWrites.len == 0
phy_set_channel(addr ch, 0)
doAssert mmioWrites == @[(reset, 0x1111'u32), (reset, 0'u32), (5'u, 5200'u32)]
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_native_phy_rc_irq_acknowledges_before_reset_and_reports_demo_version(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, native_phy_source() + r'''
setup()
let mdm = wifiModemRegs()
let ack = cast[uint](addr mdm.intAckB420)
let reset = cast[uint](addr mdm.phyChannelPulse888)
for status in [0'u32, 0xFF, 0x100, 0xE5A50358'u32]:
  mmioWrites.setLen(0)
  mdm.intStatusB41c = status
  phy_rc_isr()
  var expected = @[(ack, status)]
  if (status and 0x100) != 0:
    expected.add([(reset, 0x1111'u32), (reset, 0'u32)])
  doAssert mmioWrites == expected

mdm.versionWord = 0x808'u32
mdm.versionScratch3c = 0xA5A55A5A'u32
var first, second: uint32
mmioReads.setLen(0)
phy_get_version(addr first, addr second)
doAssert first == 0x808'u32 and second == 0'u32 and phy_vht_supported()
doAssert mmioReads == @[cast[uint](addr mdm.versionWord)]
''')
