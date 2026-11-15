"""Exercise delay RF ownership, WL callback ABI/liveness and channel state."""

from pathlib import Path
import re

import pytest

from test_wifi_disconnect_tx import FW, ROOT, procedure
from test_wifi_message_allocation import run_program
from test_wifi_rf_channel_entry import rf_procedure
from test_wifi_rf_power_replay import object_type

RF = FW / "global_state/rf_bl808_core.nim"
CORE = FW / "global_state/rf_core_init_asserts.nim"
DELAY = ROOT / "src/bl808/wifi/support/delay_parts"


def wl_types() -> str:
    rf = RF.read_text()
    code = f'import "{ROOT / "src/bl808/radio_phy"}"\n'
    code += object_type(rf, "WlRfConfig") + object_type(rf, "WlRfMemoryOverlay")
    for name in ("WlParamLoadCb", "WlCapcodeSetCb", "WlCapcodeGetCb"):
        code += "type\n" + next(line for line in rf.splitlines() if line.startswith("  " + name + " =")) + "\n"
    return code + "const WlRfConfigMagic = 0xACDE'u32\n"


def delay_source() -> str:
    code = (DELAY / "debug_state.nim").read_text()
    code += r'''
var
  rfStatus: uint32
  reads, writes: seq[uint32]
  waits: seq[uint32]
proc regRead32(address: uint32): uint32 =
  reads.add(address)
  rfStatus
proc regWrite32(address, value: uint32) =
  writes.add(address)
  rfStatus = value
proc delayMtimeUs(us: uint32) = waits.add(us)
'''
    code += (DELAY / "rf_latch.nim").read_text()
    exported = (DELAY / "exported.nim").read_text()
    exported, count = re.subn(r'^  \{\.emit:.*$', "  caller = 0x1234'u32", exported, flags=re.M)
    assert count == 2
    return code + exported


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_delay_hooks_do_not_clear_rf_busy_bits(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, delay_source() + r'''
for enabled in [0'u32, 1, 2, high(uint32)]:
  for status in [0'u32, 1, 0x00100000, 0x01000000, 0x01100000, high(uint32)]:
    for us in [0'u32, 1, 10, 50, 100, high(uint32)]:
      for callback in [arch_delay_us, udelay, wrapWaitUs]:
        rfStatus = status
        reads.setLen(0)
        writes.setLen(0)
        waits.setLen(0)
        nimWifiDbgRfTxcalLatchCount = 17
        nimWifiDbgRfTxcalBefore = 123
        nimWifiDbgRfTxcalAfter = 456
        nim_wifi_rf_latch_service_enable(enabled)
        callback(us)
        doAssert rfStatus == status and reads.len == 0 and writes.len == 0,
          "delay hook read or changed live RF calibration status"
        doAssert waits == @[us] and nimWifiDbgDelayCallerRa == 0x1234
        doAssert nimWifiDbgRfTxcalLatchCount == 17
        doAssert nimWifiDbgRfTxcalBefore == 123 and nimWifiDbgRfTxcalAfter == 456
''')


def core_source() -> str:
    code = wl_types() + r'''
var
  wifiBl808WlRmem: WlRfMemoryOverlay
  wifiBl808RfInited: uint32
  nimFwDbgRfPhase, nimFwDbgRfApiMode, nimFwDbgRfRestore: uint32
  calls: seq[string]
proc nimFwConnectTrace2U32(text: string; a, b: uint32) = discard
proc rfPriLoadConfiguredDeviceInfo() = calls.add("device")
proc wl_cfg_get(rmem: ptr WlRfMemoryOverlay): ptr WlRfConfig =
  calls.add("cfg")
  addr rmem.config
proc snapshotWifiRfCalibData() = calls.add("snapshot")
proc nim_wifi_rf_latch_service_enable(enabled: uint32) = calls.add("latch")
proc wl_init(): int8 =
  calls.add("init")
  0
'''
    code += rf_procedure(RF.read_text(), "configureWlRfConfig")
    return code + procedure(CORE.read_text(), "wifiRfCoreInitMode")


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_core_initialization_has_no_latch_service_window(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, core_source() + r'''
for inited in [0'u32, 1, 2, high(uint32)]:
  for radioMode in [wifiOnly, bleOnly, wifiBleCoex]:
    for crystal in [24000000'u32, 26000000, 32000000, 38400000, 40000000, 52000000]:
      calls.setLen(0)
      wifiBl808RfInited = inited
      wifiBl808WlRmem = default(WlRfMemoryOverlay)
      wifiBl808WlRmem.config.xtalCapCodes = 0x2A2A
      wifiRfCoreInitMode(crystal, radioMode)
      doAssert calls == @["device", "cfg", "snapshot", "init", "snapshot"],
        "RF core initialization opened an unmatched latch-service window"
      let cfg = addr wifiBl808WlRmem.config
      doAssert cfg.xtalfreqHz == crystal and cfg.apiMode == apiFromRadioPhyMode(radioMode)
      doAssert cfg.requestFullCalibration == (inited == 0).uint8
      doAssert cfg.enableParamLoadCallback == 0 and cfg.paramLoadCallback == nil
      doAssert cfg.capcodeSetCallback == nil and cfg.capcodeGetCallback == nil
      doAssert cfg.xtalCapCodes == 0x2A2A and cfg.status == 0
      doAssert nimFwDbgRfPhase == 5 and wifiBl808RfInited == 1
      doAssert nimFwDbgRfRestore == (inited != 0).uint32
''')


def init_source() -> str:
    code = wl_types() + r'''
var
  memories: array[2, WlRfMemoryOverlay]
  wlCfgGlobal, wlEnvGlobal: pointer
  calls: seq[string]
  rebindAt: int
  dropConfig: bool
  callbackResult: int8
  programmedFrequency, programmedRestore: uint32
  programmedMode: RadioPhyMode
proc rebind() =
  if dropConfig:
    wlCfgGlobal = nil
    wlEnvGlobal = nil
  else:
    wlCfgGlobal = addr memories[1].config
    wlEnvGlobal = addr memories[1].env[0]
proc loadParam(frequency: ptr uint32): int8 {.cdecl.} =
  calls.add("param")
  doAssert frequency == addr memories[0].config.xtalfreqHz
  frequency[] = 26000000
  if rebindAt == 1: rebind()
  callbackResult
proc setFirst(a, b: uint8) {.cdecl.} =
  calls.add("set1")
  doAssert a == 18 and b == 52
  if rebindAt == 2: rebind()
proc setSecond(a, b: uint8) {.cdecl.} =
  calls.add("set2")
  doAssert a == 1 and b == 2
proc getFirst(a, b: ptr uint8) {.cdecl.} =
  calls.add("get1")
  doAssert a == b, "WL capcode getter must receive two aliased byte pointers"
  a[] = 42
  doAssert b[] == 42
  if rebindAt == 3: rebind()
proc getSecond(a, b: ptr uint8) {.cdecl.} =
  calls.add("get2")
  doAssert a == b
  b[] = 43
  doAssert a[] == 43
proc modemInitCoreMode(frequency, restore: uint32; radioMode: RadioPhyMode) =
  calls.add("modem")
  programmedFrequency = frequency
  programmedRestore = restore
  programmedMode = radioMode
  if rebindAt == 4: rebind()
'''
    code += rf_procedure(RF.read_text(), "wl_init")
    return code + r'''
proc setup() =
  memories = default(typeof(memories))
  memories[0].config = WlRfConfig(status: 0x1111, xtalfreqHz: 40000000,
    apiMode: WlApiModeWlan, requestFullCalibration: 1,
    enableParamLoadCallback: 1, paramLoadCallback: cast[pointer](loadParam),
    xtalCapCodes: 0x3412, capcodeSetCallback: cast[pointer](setFirst))
  memories[1].config = WlRfConfig(status: 0x2222, xtalfreqHz: 52000000,
    apiMode: WlApiModeAll, requestFullCalibration: 0,
    xtalCapCodes: 0x0201, capcodeSetCallback: cast[pointer](setSecond))
  for memory in memories.mitems: memory.env[9] = 0x5A
  wlCfgGlobal = addr memories[0].config
  wlEnvGlobal = addr memories[0].env[0]
  calls.setLen(0)
  rebindAt = 0
  dropConfig = false
  callbackResult = 0
'''


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
@pytest.mark.parametrize("phase", [1, 2, 3, 4], ids=["param", "cap_set", "cap_get", "modem"])
def test_wl_initialization_reloads_configuration_after_callouts(tmp_path: Path, mode: str, phase: int) -> None:
    code = init_source() + f"const RebindPhase = {phase}\n"
    run_program(tmp_path, mode, code + r'''
for status in [-128'i8, -1, 0, 1, 127]:
  setup()
  rebindAt = RebindPhase
  callbackResult = status
  when RebindPhase == 3:
    when compiles(block:
      let callback: WlCapcodeGetCb = getFirst
      var cap: uint8
      callback(addr cap, addr cap)):
      memories[0].config.capcodeGetCallback = cast[pointer](getFirst)
      memories[1].config.capcodeGetCallback = cast[pointer](getSecond)
    else:
      doAssert false, "WL capcode getter callback ABI omits its second pointer"
  doAssert wl_init() == status
  let expectedCalls = case RebindPhase
    of 1: @["param", "set2", "modem"]
    of 2: @["param", "set1", "modem"]
    of 3: @["param", "set1", "get1", "modem"]
    else: @["param", "set1", "modem"]
  doAssert calls == expectedCalls, "WL initialization continued through stale callback configuration"
  if RebindPhase <= 3:
    doAssert programmedFrequency == 52000000 and programmedRestore == 1 and programmedMode == wifiBleCoex
  else:
    doAssert programmedFrequency == 26000000 and programmedRestore == 0 and programmedMode == wifiOnly
  doAssert memories[0].config.status == 0x1111 and memories[1].config.status == WlRfConfigMagic,
    "WL initialization published status to stale configuration storage"
  doAssert memories[0].env[9] == 0x5A and memories[1].env[9] == 0
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_wl_capcode_callback_abi_and_optional_stage_order(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, init_source() + r'''
when compiles(block:
  let callback: WlCapcodeGetCb = getFirst
  var cap: uint8
  callback(addr cap, addr cap)):
  for enabled in [0'u8, 1, 2, 255]:
    for cold in [0'u8, 1, 2, 255]:
      for codes in [0x3412'u16, 0x3450, 0x5012]:
        setup()
        let cfg = addr memories[0].config
        cfg.enableParamLoadCallback = enabled
        cfg.requestFullCalibration = cold
        cfg.xtalCapCodes = codes
        cfg.capcodeGetCallback = cast[pointer](getFirst)
        var expected: seq[string]
        if enabled != 0: expected.add("param")
        if codes == 0x3412: expected.add("set1")
        expected.add("get1")
        expected.add("modem")
        doAssert wl_init() == 0 and calls == expected
        doAssert programmedFrequency == (if enabled == 0: 40000000'u32 else: 26000000'u32)
        doAssert programmedRestore == (cold == 0).uint32
        doAssert cfg.status == WlRfConfigMagic and memories[0].env[9] == 0
else:
  doAssert false, "WL capcode getter callback ABI omits its second pointer"
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_wl_initialization_stops_if_a_callout_invalidates_configuration(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, init_source() + r'''
when compiles(block:
  let callback: WlCapcodeGetCb = getFirst
  var cap: uint8
  callback(addr cap, addr cap)):
  for phase in 1 .. 4:
    setup()
    rebindAt = phase
    dropConfig = true
    if phase == 3: memories[0].config.capcodeGetCallback = cast[pointer](getFirst)
    doAssert wl_init() == -1, "WL initialization used configuration invalidated by a callout"
    doAssert memories[0].config.status == 0x1111 and memories[1].config.status == 0x2222
    doAssert memories[0].env[9] == 0x5A and memories[1].env[9] == 0x5A
    doAssert ("modem" in calls) == (phase == 4)
else:
  doAssert false, "WL capcode getter callback ABI omits its second pointer"
''')


def channel_source() -> str:
    rf = RF.read_text()
    code = wl_types()
    code += "var\n" + next(line for line in rf.splitlines() if line.startswith("  bl808RfChannelPowerIndex:")) + "\n"
    code += r'''
var
  config: WlRfConfig
  wlCfgGlobal: pointer
  bl808RfChannelPowerComp, bl808RfChannelLpPowerComp: array[14, int16]
  bl808RfTempPowerComp, bl808RfAppliedPowerComp, bl808RfCurrentTemperatureC: int16
  bl808RfTempCalEnabled, bl808RfTempMeasurementPass: uint8
  indices: seq[uint32]
proc rfSignedByte(value: uint8): int16 = cast[int8](value).int16
proc rfPriRefreshTempCompParamFromWlCfg() = discard
proc rfPriComputeTemperaturePowerComp(channel: uint32; temperature: int32): int16 =
  indices.add(channel)
  0
proc rf_pri_set_channel_total_pwr_comp(channel: uint32) = indices.add(channel)
proc rf_pri_set_channel_lp_pwr_comp(channel: uint32) = indices.add(channel)
'''
    return (code + rf_procedure(rf, "rfSignExtend16") + rf_procedure(rf, "rf_pri_set_temp_comp")
            + rf_procedure(rf, "rf_pri_set_channel_pwr_comp"))


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_current_channel_is_a_byte_initialized_to_channel_one(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, channel_source() + r'''
doAssert sizeof(bl808RfChannelPowerIndex) == 1 and bl808RfChannelPowerIndex == 1,
  "saved current channel differs from the vendor byte/default"
wlCfgGlobal = addr config
bl808RfTempCalEnabled = 1
rf_pri_set_temp_comp(35)
doAssert indices == @[1'u32, 1]
for channel in [0'u32, 1, 6, 14, 15, 255, 256, 257, 65537, high(uint32)]:
  indices.setLen(0)
  rf_pri_set_channel_pwr_comp(channel)
  doAssert bl808RfChannelPowerIndex.uint32 == (channel and 255)
  if channel >= 1 and channel <= 14:
    doAssert indices == @[channel, channel, channel, channel]
  else:
    doAssert indices.len == 0
''')
