"""Low-power RF/PHY and status behavior from the named RF archive members."""

from pathlib import Path
import re

import pytest

from test_wifi_message_allocation import run_program
from test_wifi_rf_channel_entry import rf_procedure
from test_wifi_rf_core_entry import wl_types
from test_wifi_rf_power_replay import RF, object_type


def rf_text() -> str:
    return RF.read_text()


def status_source() -> str:
    rf = rf_text()
    code = object_type(rf, "WlLowPowerStatusEnv") + r'''
var storage: array[3, WlLowPowerStatusEnv]
var wlEnvGlobal: pointer = addr storage[1]
template wlLowPowerStatusEnv(): ptr WlLowPowerStatusEnv =
  cast[ptr WlLowPowerStatusEnv](wlEnvGlobal)
'''
    return code + rf_procedure(rf, "wl_lp_status_clear") + rf_procedure(rf, "wl_lp_status_update")


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_lp_status_signed_weighted_filter(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, status_source() + r'''
for valid in [0'u8, 1, 255]:
  for old in -128 .. 127:
    for incoming in -128 .. 127:
      for active in [1'u32, 2, high(uint32)]:
        for item in storage.mitems:
          item = WlLowPowerStatusEnv(lastStatusCode: old.int8,
            statusCodeToInactiveCountPadding: 0x5A, inactiveUpdateCount: 65432,
            lastUpdateContext: 123, lowPowerActiveLatch: 0xA5,
            statusValid: valid, validFlagTailPadding: [0x33'u8, 0xCC])
        let before = storage
        let total = old * 48 + incoming * 80
        let expected = if valid == 0: incoming
                       elif total >= 0: total div 128
                       else: -((-total + 127) div 128)
        wl_lp_status_update(active, incoming.int8, 0xF1234567'u32)
        doAssert storage[1].lastStatusCode == expected.int8,
          "active status did not apply signed 48/80 smoothing"
        doAssert storage[1].inactiveUpdateCount == 0 and storage[1].statusValid == 1
        doAssert storage[1].lastUpdateContext == 0xF1234567'u32
        var wanted = before[1]
        wanted.lastStatusCode = expected.int8
        wanted.inactiveUpdateCount = 0
        wanted.statusValid = 1
        wanted.lastUpdateContext = 0xF1234567'u32
        doAssert storage[1] == wanted and storage[0] == before[0] and storage[2] == before[2]
wlEnvGlobal = nil
wl_lp_status_update(1, -5, 123)
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_lp_inactive_counter_wrap_and_clear(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, status_source() + r'''
for count in 0 .. 65535:
  for valid in [0'u8, 1, 255]:
    storage[1] = WlLowPowerStatusEnv(lastStatusCode: -90,
      statusCodeToInactiveCountPadding: 0xAA, inactiveUpdateCount: count.uint16,
      lastUpdateContext: 77, lowPowerActiveLatch: 0x55,
      statusValid: valid, validFlagTailPadding: [0x12'u8, 0x34])
    var wanted = storage[1]
    let next = (count + 1) mod 65536
    wanted.inactiveUpdateCount = (if next == 2: 0 else: next).uint16
    if next == 2: wanted.statusValid = 0
    wanted.lastUpdateContext = 0xABCD1234'u32
    wl_lp_status_update(0, 127, 0xABCD1234'u32)
    doAssert storage[1] == wanted, "inactive counter saturated instead of wrapping"
    wanted.lastStatusCode = -90
    wanted.inactiveUpdateCount = 0
    wanted.statusValid = 0
    wanted.lastUpdateContext = 0x98765432'u32
    wl_lp_status_clear(0x98765432'u32)
    doAssert storage[1] == wanted
wlEnvGlobal = nil
wl_lp_status_clear(0)
''')


def entry_source() -> str:
    rf = rf_text()
    code = wl_types() + r'''
const WlXtal26M = 26000000'u32
const WlXtal32M = 32000000'u32
const WlXtal38P4M = 38400000'u32
const WlXtal40M = 40000000'u32
const WlXtal52M = 52000000'u32
var
  memories: array[3, WlRfMemoryOverlay]
  wlCfgGlobal, wlCalGlobal, wlEnvGlobal, rfCalibDataGlobal: pointer
  calls: seq[string]
  rebindAfter: int
  dropConfig: bool
  seenChip, seenXtal, seenFrequency: uint32
proc record(name: string) =
  calls.add(name)
  if calls.len == rebindAfter:
    wlCfgGlobal = if dropConfig: nil else: addr memories[calls.len].config
proc wlLpDefaultInit() = record("default")
proc lp_rf_pri_init(cold, chip: uint32) =
  doAssert cold == 0
  seenChip = chip
  record("lp-rf")
proc lp_phy_init(xtal, frequency: uint32) =
  seenXtal = xtal
  seenFrequency = frequency
  record("lp-phy")
proc rf_pri_input_xtalfreq(hz: uint32) = record("extra-xtal")
proc rf_pri_init(cold, api: uint32) =
  rfCalibDataGlobal = wlCalGlobal
  record("normal-rf")
proc phy_init(cfg: pointer) = record("normal-phy")
proc wlLpProgramEarlyPhyRegs(index: uint32) = record("early")
proc wlLpProgramApiModePhyBranchStart() = record("branch")
proc wlLpProgramApiModeTuneAndAgcPrep(cfg: pointer) = record("tune")
proc wlLpCopyAgcMemoryAndReleaseGate() = record("copy")
proc wlLpProgramAgcCoreRegs() = record("agc")
proc wlLpProgramPostAgcPowerDetectTail() = record("tail")
'''
    code += rf_procedure(rf, "wlLpXtalIndex") + rf_procedure(rf, "wl_lp_init")
    return code + r'''
proc enter(frequency: uint32): int32 =
  when compiles(wl_lp_init(addr memories[0], frequency)):
    wl_lp_init(addr memories[0], frequency)
  else:
    wl_lp_init(addr memories[0], cast[pointer](frequency.uint))
proc setup() =
  memories = default(typeof(memories))
  for i in 0 .. 2:
    memories[i].config.xtalfreqHz = [40000000'u32, 26000000, 52000000][i]
    memories[i].config.efuseChipVersion = (77 + i).uint8
    memories[i].config.apiMode = (1 + i).uint8
  wlCfgGlobal = nil
  wlCalGlobal = nil
  wlEnvGlobal = nil
  rfCalibDataGlobal = addr memories[2].calib[0]
  calls.setLen(0)
  rebindAfter = 0
  dropConfig = false
'''


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_lp_entry_preserves_rf_calibration_and_uses_channel_argument(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, entry_source() + r'''
for crystal in [0'u32, 24000000, 26000000, 32000000, 38400000, 40000000, 52000000, high(uint32)]:
  for chip in 0 .. 255:
    for frequency in [0'u32, 2402, 2412, 2484, 65535, 0xF1234567'u32]:
      setup()
      memories[0].config.xtalfreqHz = crystal
      memories[0].config.efuseChipVersion = chip.uint8
      let savedCal = rfCalibDataGlobal
      doAssert enter(frequency) == 0
      doAssert calls == @["default", "lp-rf", "lp-phy"], "low-power init entered normal RF/PHY"
      doAssert rfCalibDataGlobal == savedCal, "low-power init rebound the RF calibration pointer"
      doAssert wlCfgGlobal == addr memories[0].config
      doAssert wlCalGlobal == (addr memories[0].calib[0]) and wlEnvGlobal == (addr memories[0].env[0])
      doAssert seenChip == chip.uint32 and seenFrequency == frequency
      let expected = case crystal
        of 26000000: 1'u32
        of 32000000: 2'u32
        of 38400000: 3'u32
        of 52000000: 5'u32
        else: 4'u32
      doAssert seenXtal == expected
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_lp_entry_reloads_config_after_initializers(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, entry_source() + r'''
for stage in [1, 2]:
  for drop in [false, true]:
    setup()
    rebindAfter = stage
    dropConfig = drop
    let savedCal = rfCalibDataGlobal
    doAssert enter(2462) == (if drop: -1 else: 0)
    doAssert rfCalibDataGlobal == savedCal
    if drop:
      doAssert calls == (if stage == 1: @["default"] else: @["default", "lp-rf"])
    else:
      doAssert calls == @["default", "lp-rf", "lp-phy"]
      doAssert seenChip == (if stage == 1: 78 else: 77).uint32
      doAssert seenXtal == (if stage == 1: 1 else: 5).uint32
''')


def phy_source() -> str:
    rf = rf_text()
    code = wl_types()
    for name in ("RfRegBlock", "WifiModemBlock", "BbaAgcBlock", "CrmPhyClockBlock",
                 "RfAuxCtrlBlock", "RfDfeInitBlock", "WifiAgcMemoryRam", "RfcLpXtalConfig", "WlLowPowerStatusEnv"):
        code += object_type(rf, name)
    code += rf[rf.index("var rfcXtalCfg*"):].split("\nstatic:", 1)[0] + "\n"
    code += r'''
const WlXtal26M = 26000000'u32
const WlXtal32M = 32000000'u32
const WlXtal38P4M = 38400000'u32
const WlXtal40M = 40000000'u32
const WlXtal52M = 52000000'u32
var
  rfBank: array[0x900 div 4, uint32]
  modemBank: array[0xE000 div 4, uint32]
  auxBank: array[0x600 div 4, uint32]
  crmBank: array[0x40 div 4, uint32]
  pdsWord: uint32
  dfe: RfDfeInitBlock
  agcRam: WifiAgcMemoryRam
  agcmem: array[512, uint32]
  cfgStorage: WlRfConfig
  envStorage: WlLowPowerStatusEnv
  wlCfgGlobal: pointer = addr cfgStorage
  calStorage: array[80, uint32]
  wlCalGlobal: pointer = addr calStorage[0]
  writes: seq[tuple[address, value: uint32]]
  calls: seq[string]
  mutationAt: int
  randomState = 0x9E3779B9'u32
proc randomWord(): uint32 =
  randomState = randomState xor (randomState shl 13)
  randomState = randomState xor (randomState shr 17)
  randomState = randomState xor (randomState shl 5)
  randomState
proc rfRegs(): ptr RfRegBlock = cast[ptr RfRegBlock](addr rfBank[0])
proc wifiModemRegs(): ptr WifiModemBlock = cast[ptr WifiModemBlock](addr modemBank[0])
proc bbaAgcRegs(): ptr BbaAgcBlock = cast[ptr BbaAgcBlock](addr modemBank[0xB000 div 4])
proc rfAuxCtrlRegs(): ptr RfAuxCtrlBlock = cast[ptr RfAuxCtrlBlock](addr auxBank[0x500 div 4])
proc pdsSleepRetainMaskReg(): ptr uint32 = addr pdsWord
proc rfDfeInitRegs(): ptr RfDfeInitBlock = addr dfe
proc crmPhyClockRegs(): ptr CrmPhyClockBlock = cast[ptr CrmPhyClockBlock](addr crmBank[0])
proc wifiAgcMemoryRegs(): ptr WifiAgcMemoryRam = addr agcRam
proc wlLowPowerStatusEnv(): ptr WlLowPowerStatusEnv = addr envStorage
proc address(p: ptr uint32): uint32 =
  let raw = cast[uint](p)
  if p == addr pdsWord: return 0x249000E0'u32
  for bank in [(cast[uint](addr rfBank[0]), sizeof(rfBank).uint, 0x20001000'u32),
               (cast[uint](addr modemBank[0]), sizeof(modemBank).uint, 0x24C00000'u32),
               (cast[uint](addr auxBank[0]), sizeof(auxBank).uint, 0x20000000'u32),
               (cast[uint](addr crmBank[0]), sizeof(crmBank).uint, 0x24940000'u32),
               (cast[uint](addr dfe), sizeof(dfe).uint, 0x20010000'u32),
               (cast[uint](addr agcRam), sizeof(agcRam).uint, 0x24C0A000'u32)]:
    if raw >= bank[0] and raw < bank[0] + bank[1]: return bank[2] + (raw - bank[0]).uint32
  doAssert false, "unknown MMIO address"
proc volatileLoad[T](p: ptr T): T = p[]
proc volatileStore(p: ptr uint32; value: uint32) =
  writes.add((address(p), value))
  p[] = value
proc volatileStore(p: ptr uint8; value: uint8) = p[] = value
proc updateReg32(p: ptr uint32; keep, value: uint32) =
  volatileStore(p, (volatileLoad(p) and keep) or value)
proc record(name: string) =
  calls.add(name)
  if calls.len == mutationAt: cfgStorage.apiMode = 0
proc rc2_config_rxgain(offset: int8) =
  doAssert offset == -5
  record("gain")
proc crm_init() = record("crm")
proc crm_mdm_reset() = record("reset")
proc waitRfUs(us: uint32) =
  doAssert us == 1
  record("wait")
proc crm_clk_set(mode: uint32) =
  doAssert mode == 0
  record("clock")
proc pointerAddrU32(p: pointer): uint32 = cast[uint](p).uint32
proc copyAgcMemory() =
  for i in 0 ..< 512: volatileStore(addr agcRam.memoryWords[i], agcmem[i])
proc setup() =
  for word in rfBank.mitems: word = randomWord()
  for word in modemBank.mitems: word = randomWord()
  for word in crmBank.mitems: word = randomWord()
  for word in auxBank.mitems: word = randomWord()
  for word in agcRam.memoryWords.mitems: word = randomWord()
  for word in agcmem.mitems: word = randomWord()
  for word in calStorage.mitems: word = randomWord()
  writes.setLen(0)
  calls.setLen(0)
  mutationAt = 0
  cfgStorage.apiMode = 1
  wlCfgGlobal = addr cfgStorage
  envStorage.lowPowerActiveLatch = 0xFF
'''
    for name in ("wlLpXtalIndex", "wlLpDefaultInit", "wlLpProgramEarlyPhyRegs", "wlLpApiModeActive",
                 "wlLpProgramApiModePhyBranchStart", "wlLpProgramApiModeTuneAndAgcPrep",
                 "wlLpCopyAgcMemoryAndReleaseGate", "bl808PhyProgramAgcCoreRegs",
                 "wlLpProgramAgcCoreRegs", "wlLpProgramPostAgcPowerDetectTail", "lp_phy_init"):
        if re.search(rf"^proc {name}\*?\(", rf, re.M):
            code += rf_procedure(rf, name)
    return code


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_lp_copy_only_240_words_and_release_gates(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, phy_source() + r'''
for vector in 0 ..< 200:
  setup()
  let before = agcRam
  let oldCrm = crmBank[4]
  let oldGain = modemBank[0xB390 div 4]
  wlLpCopyAgcMemoryAndReleaseGate()
  for i in 0 ..< 512:
    doAssert agcRam.memoryWords[i] == (if i < 240: agcmem[i] else: before.memoryWords[i]),
      "low-power copy changed words beyond the 0x3c0-byte window"
  doAssert writes.len == 242
  for i in 0 ..< 240: doAssert writes[i] == (0x24C0A000'u32 + 4 * i.uint32, agcmem[i])
  doAssert writes[240] == (0x24940010'u32, oldCrm and 0xDFFFFFFF'u32)
  doAssert writes[241] == (0x24C0B390'u32, oldGain and 0xFFFFEFFF'u32)
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_lp_receive_tail_uses_modem_register_not_crm(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, phy_source() + r'''
for vector in 0 ..< 200:
  setup()
  let oldCrm = crmBank
  let oldTail = modemBank[0xC018 div 4]
  wlLpProgramApiModePhyBranchStart()
  doAssert crmBank == oldCrm, "LP RX gain tail wrote the CRM reset register"
  doAssert modemBank[0xC018 div 4] == ((oldTail and 0xFFFFFC00'u32) or 0x50'u32)
  doAssert writes[^1] == (0x24C0C018'u32, modemBank[0xC018 div 4])
  doAssert calls == @["gain", "crm", "reset"]
''')


# Store order and masks decoded from lp_phy_init+0x3a6..0x774, not main phy_init.
LP_AGC = (
    (0xB3A4, 0xFFFFFF00, 0), (0xB3A4, 0xFFFF00FF, 0),
    (0xB394, 0xFF00FFFF, 0xF80000), (0xB398, 0xFFFF00FF, 0x9E00),
    (0xB3C4, 0xFFFFFF00, 0xCE), (0xB364, 0xE0FFFFFF, 0x08000000),
    (0xB364, 0xFFC0FFFF, 0x3C0000), (0xB364, 0xFFFFC0FF, 0x3A00),
    (0xB364, 0xFFFFFFC0, 0x3B), (0xB368, 0xFFC00FFF, 0x270000),
    (0xB368, 0xFFFFFC00, 0x270), (0xB36C, 0xFFFFFF00, 0x10),
    (0xB36C, 0xFFFFF8FF, 0x500), (0xB36C, 0xFF00FFFF, 0x200000),
    (0xB36C, 0xF8FFFFFF, 0x5000000), (0xB370, 0xFF80FFFF, 0x580000),
    (0xB3C0, 0x00FFFFFF, 0x18000000), (0xB3C4, 0xFF00FFFF, 0xE00000),
    (0xB3C4, 0x00FFFFFF, 0xDC000000), (0xB3A0, 0xFFFFFF00, 0x9D),
    (0xB3C0, 0xFFFFFF00, 0xB0), (0xB3C0, 0xFFFF00FF, 0xA300),
    (0xB380, 0xFFF03FFF, 0xF8000), (0xB380, 0xFC0FFFFF, 0x3700000),
    (0xB380, 0x03FFFFFF, 0x04000000), (0xB380, 0xFFFFDFFF, 0),
    (0xB380, 0xFFFFE3FF, 0x400), (0xB384, 0x03FFFFFF, 0xE4000000),
    (0xB384, 0xFC0FFFFF, 0x3700000), (0xB384, 0xFFF03FFF, 0x50000),
    (0xB384, 0xFFFFDFFF, 0), (0xB384, 0xFFFFE3FF, 0x800),
    (0xB388, 0x03FFFFFF, 0x3C000000), (0xB388, 0xFC0FFFFF, 0x1700000),
    (0xB388, 0xFFF03FFF, 0xA8000), (0xB388, 0xFFFFE3FF, 0x400),
    (0xB388, 0xFFFFDFFF, 0), (0xB38C, 0x03FFFFFF, 0x64000000),
    (0xB38C, 0xFC0FFFFF, 0x1800000), (0xB38C, 0xFFF03FFF, 0),
    (0xB38C, 0xFFFFE3FF, 0x800), (0xC830, 0x03FFFFFF, 0xFC000000),
    (0xC830, 0xFC0FFFFF, 0x100000), (0xC830, 0xFFF03FFF, 0xD8000),
    (0xC830, 0xFFFFE3FF, 0x1400), (0xC838, 0x7FFFFFFF, 0x80000000),
    (0xC838, 0xFFF80000, 0x40), (0xC83C, 0x7FFFFFFF, 0x80000000),
    (0xC83C, 0xFFF00000, 0x20), (0xC840, 0x7FFFFFFF, 0),
    (0xC840, 0xFFC00000, 0x36), (0xB004, 0, 1),
    (0xB390, 0xFFFFFFFC, 1), (0xB3BC, 0, 0x1E8480), (0xB414, 0xFFFFFFFF, 0x100),
)


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_lp_agc_trace_is_distinct_from_normal_phy(tmp_path: Path, mode: str) -> None:
    rows = ",\n".join(f"({offset}, {keep}'u32, {value}'u32)" for offset, keep, value in LP_AGC)
    run_program(tmp_path, mode, phy_source() + "\nconst vendor = [\n" + rows + r'''
]
for vector in 0 ..< 200:
  setup()
  var expected = modemBank
  var trace: seq[tuple[address, value: uint32]]
  for row in vendor:
    expected[row[0] div 4] = (expected[row[0] div 4] and row[1]) or row[2]
    trace.add((0x24C00000'u32 + row[0].uint32, expected[row[0] div 4]))
  wlLpProgramAgcCoreRegs()
  doAssert writes == trace, "LP AGC store trace used normal-PHY values or ordering"
  doAssert modemBank == expected
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_lp_phy_api_mode_gate_is_sampled_once(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, phy_source() + r'''
when declared(lp_phy_init):
  for apiMode in 0 .. 255:
    for mutate in 0 .. 7:
      setup()
      cfgStorage.apiMode = apiMode.uint8
      mutationAt = mutate
      lp_phy_init(4, 2462)
      if apiMode in [1, 3]:
        doAssert calls == @["gain", "crm", "reset", "wait", "wait", "wait", "clock", "wait"],
          "LP PHY rechecked API mode after entering its register sequence"
        doAssert (rfBank[0x264 div 4] and 4095) == 2462
        doAssert envStorage.lowPowerActiveLatch == 0
      else:
        doAssert calls.len == 0 and envStorage.lowPowerActiveLatch == 255
else:
  doAssert false, "missing separate LP PHY coordinator"
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_lp_rf_initializer_order_cold_gate_and_calibration_ownership(tmp_path: Path, mode: str) -> None:
    rf = rf_text()
    code = phy_source() + r'''
type
  RfPriPowerTableScope = enum rfPowerAll, rfPowerWlan, rfPowerBz
  RfPriPowerTablePhase = enum rfPowerFields, rfPowerCalibration
var rfCalibDataGlobal: pointer
proc rfPriEfuseInit() =
  doAssert writes.len == 1
  record("efuse")
proc rf_pri_xtalfreq() = record("xtal")
proc writeRfPriFixedValueRegs() = record("fixed")
proc rfPriWifiPllConfig() = record("pll")
proc runRfPriFullCalRestoreBaseline() =
  doAssert writes.len == 3
  record("full")
proc replayRfPriCalRegisters() =
  doAssert writes.len == 3
  record("restore")
proc rfPriWriteTxPowerTable(scope: RfPriPowerTableScope = rfPowerAll;
                            phases: set[RfPriPowerTablePhase] = {rfPowerFields, rfPowerCalibration}) =
  doAssert scope == rfPowerAll and phases == {rfPowerFields} and writes.len == 3
  record("power")
'''
    code += rf_procedure(rf, "lp_rf_pri_init")
    run_program(tmp_path, mode, code + r'''
for cold in [0'u32, 1, 2, high(uint32)]:
  for chip in [0'u32, 1, 128, 255, 0x100, 0xF1234567'u32]:
    for absent in [false, true]:
      setup()
      dfe.dfeTrim824 = randomWord()
      rfCalibDataGlobal = if absent: nil else: addr calStorage[19]
      let savedCal = rfCalibDataGlobal
      let oldDfe = dfe.dfeTrim824
      let oldRf = rfBank
      lp_rf_pri_init(cold, chip)
      doAssert calls == @["efuse", "xtal", "fixed", "pll",
        (if cold == 0: "restore" else: "full"), "power"]
      doAssert rfCalibDataGlobal == savedCal
      let firstRx = oldRf[0x220 div 4] and 0xFFFFE67D'u32
      let secondRx = firstRx and 0xFFFFFF9E'u32
      doAssert writes == @[
        (0x20010824'u32, (oldDfe and 0x9FFFFFFF'u32) or 0x40000000'u32),
        (0x20001220'u32, firstRx), (0x20001220'u32, secondRx),
        (0x2000102C'u32, oldRf[0x2C div 4] or 6'u32),
        (0x2000102C'u32, oldRf[0x2C div 4] or 0x4027'u32),
        (0x2000163C'u32, oldRf[0x63C div 4] or 0x8080'u32),
        (0x20001220'u32, secondRx and 0xFFFFF9FF'u32)]
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_lp_common_crystal_calibration_and_default_mode_gate(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, phy_source() + r'''
const vendorXtal = [
  [0x38E39'u32, 0x471C7, 0x22000000, 0x990],
  [0x34835'u32, 0x41A42, 0x1F627627, 0x990],
  [0x2AAAB'u32, 0x35555, 0x19800000, 0x990],
  [0x238E4'u32, 0x2C71C, 0x15400000, 0x990],
  [0x22222'u32, 0x2AAAB, 0x14400000, 0x97E],
  [0x1A41A'u32, 0x20D21, 0xFB13B14, 0x990]]
for apiMode in 0 .. 255:
  setup()
  cfgStorage.apiMode = apiMode.uint8
  let oldBias = rfBank[0x400 div 4]
  let oldAux = auxBank
  wlLpDefaultInit()
  doAssert rfBank[0x504 div 4] == 0x2C0000 and rfBank[0x508 div 4] == 0x3C0002
  doAssert rfBank[0x50C div 4] == 0x3FFC02 and pdsWord == 0xFFFFFF00'u32
  doAssert crmBank[4] == 0 and crmBank[5] == 0
  if apiMode == 1:
    doAssert writes.len == 13
    doAssert rfBank[0x400 div 4] == (oldBias and not 0x80C300'u32)
    doAssert auxBank[0x540 div 4] == (oldAux[0x540 div 4] or 0xF00'u32)
    doAssert auxBank[0x544 div 4] == (oldAux[0x544 div 4] or 4'u32)
  else:
    doAssert writes.len == 6 and rfBank[0x400 div 4] == oldBias and auxBank == oldAux
for index in [0'u32, 1, 2, 3, 4, 5, 6, high(uint32)]:
  for vector in 0 ..< 100:
    setup()
    let old = rfBank
    let wanted = vendorXtal[if index < 6: index.int else: 4]
    wlLpProgramEarlyPhyRegs(index)
    doAssert rfBank[0x1C0 div 4] == ((old[0x1C0 div 4] and 0xFFFFF000'u32) or (wanted[3] and 0xFFF))
    doAssert rfBank[0x1C4 div 4] == ((old[0x1C4 div 4] and 0xE0000000'u32) or (wanted[2] and 0x1FFFFFFF))
    doAssert rfBank[0x1C8 div 4] == ((old[0x1C8 div 4] and 0xFFF00000'u32) or wanted[0])
    doAssert rfBank[0x1CC div 4] == ((old[0x1CC div 4] and 0xFFF00000'u32) or wanted[1])
    for i in 0 ..< 11:
      doAssert writes[4 + i] == (0x2000113C'u32 + i.uint32 * 4, calStorage[7 + i])
    doAssert calls.len == 0
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_lp_tune_consumes_frequency_bits_without_pointer_semantics(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, phy_source() + r'''
for highWord in [0'u32, 0x12340000, 0x80000000'u32, 0xFFFF0000'u32]:
  for lowWord in 0 .. 65535:
    writes.setLen(0)
    calls.setLen(0)
    rfBank[0x264 div 4] = 0xA5A55A5A'u32
    let frequency = highWord or lowWord.uint32
    wlLpProgramApiModeTuneAndAgcPrep(frequency)
    doAssert rfBank[0x264 div 4] == (0xA5A55000'u32 or (frequency and 0xFFF'u32))
    doAssert calls == @["wait", "wait", "wait"]
''')
