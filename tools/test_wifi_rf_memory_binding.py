"""WL lookup ownership, post-call return value and default RF entry binding."""
from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW
from test_wifi_message_allocation import run_program
from test_wifi_rf_channel_entry import rf_procedure
from test_wifi_rf_core_entry import wl_types

RF = FW / "global_state/rf_bl808_core.nim"


def source() -> str:
    rf = RF.read_text()
    code = wl_types() + r'''
var
  memories {.align: 4.}: array[3, WlRfMemoryOverlay]
  wlCfgGlobal, wlCalGlobal, wlEnvGlobal, rfCalibDataGlobal: pointer
  initialRf: pointer
  configCalls, callbackCalls, modemCalls: int
  configAction: proc()
proc wl_rf_cfg_init() =
  inc configCalls
  doAssert wlCfgGlobal == addr memories[0].config
  doAssert wlCalGlobal == addr memories[0].calib[0]
  doAssert wlEnvGlobal == addr memories[0].env[0]
  if configAction != nil: configAction()
proc seedWlCfgTxPowerDefaults(cfg: ptr WlRfConfig) = discard
proc wlLpDefaultInit() = doAssert false
proc lp_rf_pri_init(cold, chip: uint32) = doAssert false
proc lp_phy_init(crystal, frequency: uint32) = doAssert false
proc wlLpXtalIndex(frequency: uint32): uint32 = 0
proc paramCallback(frequency: ptr uint32): int8 {.cdecl.} =
  inc callbackCalls
  0
proc setCallback(a, b: uint8) {.cdecl.} = inc callbackCalls
proc getCallback(a, b: ptr uint8) {.cdecl.} = inc callbackCalls
'''
    for name in ["wl_cfg_get", "wl_env_get", "wl_lp_init", "rf_pri_init_calib_mem", "configureWlRfConfig"]:
        code += rf_procedure(rf, name)
    code += r'''
proc modemInitCoreMode(frequency, restore: uint32; mode: RadioPhyMode) =
  inc modemCalls
  doAssert rfCalibDataGlobal == initialRf, "a WL lookup prematurely rebound RF calibration"
  rf_pri_init_calib_mem()
  doAssert rfCalibDataGlobal == wlCalGlobal
'''
    code += rf_procedure(rf, "wl_init")
    return code + r'''
proc setup(seed: int; savedRf: bool) =
  let bytes = cast[ptr UncheckedArray[uint8]](addr memories[0])
  for i in 0 ..< sizeof(memories): bytes[i] = ((seed + i * 13) and 255).uint8
  wlCfgGlobal = addr memories[2].config
  wlCalGlobal = addr memories[2].calib[0]
  wlEnvGlobal = addr memories[2].env[0]
  initialRf = if savedRf: addr memories[1].calib[0] else: nil
  rfCalibDataGlobal = initialRf
  configCalls = 0
  callbackCalls = 0
  modemCalls = 0
  configAction = nil
'''


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
@pytest.mark.parametrize("getter", ["config", "environment"])
def test_wl_lookup_does_not_rebind_rf_storage(tmp_path: Path, mode: str, getter: str) -> None:
    code = source() + f"const ConfigLookup = {str(getter == 'config').lower()}\n"
    run_program(tmp_path, mode, code + r'''
for seed in [0, 1, 127, 255]:
  for savedRf in [false, true]:
    for status in [0'u32, WlRfConfigMagic, 0xFFFFFFFF'u32]:
      setup(seed, savedRf)
      memories[0].config.status = status
      let before = memories
      var expected = before
      when ConfigLookup:
        if status != WlRfConfigMagic:
          expected[0].config.xtalfreqHz = 40000000
          expected[0].config.capcodeGetCallback = nil
          expected[0].config.capcodeSetCallback = nil
          expected[0].config.xtalCapCodes = 0x2020
        doAssert wl_cfg_get(addr memories[0]) == addr memories[0].config
        doAssert configCalls == 1
      else:
        doAssert wl_env_get(addr memories[0]) == addr memories[0].env[0]
        doAssert configCalls == 0
      doAssert rfCalibDataGlobal == initialRf, "WL lookup changed separately owned RF calibration"
      doAssert memories == expected
      doAssert wlCfgGlobal == addr memories[0].config
      doAssert wlCalGlobal == addr memories[0].calib[0]
      doAssert wlEnvGlobal == addr memories[0].env[0]
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_wl_nil_guards_only_clear_wl_bindings(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for savedRf in [false, true]:
  for operation in 0 .. 2:
    setup(37, savedRf)
    let before = memories
    case operation
    of 0: doAssert wl_cfg_get(nil) == nil
    of 1: doAssert wl_env_get(nil) == nil
    else: doAssert wl_lp_init(nil, 2462) == -1
    doAssert wlCfgGlobal == nil and wlCalGlobal == nil and wlEnvGlobal == nil
    doAssert rfCalibDataGlobal == initialRf, "a local WL nil guard cleared unrelated RF state"
    doAssert memories == before and configCalls == 0
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_wl_config_getter_returns_post_initializer_binding(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
proc replaceConfig() = wlCfgGlobal = addr memories[2].config
proc clearConfig() = wlCfgGlobal = nil
for clear in [false, true]:
  setup(121, true)
  memories[0].config.status = WlRfConfigMagic
  let before = memories
  configAction = if clear: clearConfig else: replaceConfig
  let actual = wl_cfg_get(addr memories[0])
  let expected = if clear: nil else: addr memories[2].config
  doAssert actual == expected, "config getter returned its entry pointer instead of the current binding"
  doAssert memories == before and configCalls == 1
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_default_wl_profile_defers_rf_binding_to_rf_initializer(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for radioMode in [wifiOnly, bleOnly, wifiBleCoex]:
  for cold in [0'u8, 1, 2, 255]:
    setup(77, true)
    memories[0].config.status = WlRfConfigMagic
    memories[0].config.enableParamLoadCallback = 255
    memories[0].config.paramLoadCallback = cast[pointer](paramCallback)
    memories[0].config.capcodeSetCallback = cast[pointer](setCallback)
    memories[0].config.capcodeGetCallback = cast[pointer](getCallback)
    let calibration = memories[0].calib
    let cfg = wl_cfg_get(addr memories[0])
    configureWlRfConfig(cfg, 40000000, radioMode, cold)
    doAssert cfg.paramLoadCallback == nil and cfg.capcodeSetCallback == nil and cfg.capcodeGetCallback == nil
    doAssert cfg.enableParamLoadCallback == 0
    doAssert wl_init() == 0
    doAssert modemCalls == 1 and callbackCalls == 0 and configCalls == 1
    doAssert rfCalibDataGlobal == addr memories[0].calib[0]
    doAssert memories[0].calib == calibration
    doAssert cfg.status == WlRfConfigMagic and memories[0].env[9] == 0
''')
