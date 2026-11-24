"""Check the RF channel-compensation configuration handoff."""

from pathlib import Path

import pytest

from test_wifi_message_allocation import run_program
from test_wifi_rf_channel_entry import rf_procedure
from test_wifi_rf_power_replay import RF


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_channel_compensation_reloads_config_after_lp_replay(
    tmp_path: Path, mode: str
) -> None:
    code = r'''
type WlRfConfig = object
  channelPowerComp, channelLowPowerComp: array[14, uint8]
  temperaturePowerComp: uint8
var
  firstCfg, secondCfg: WlRfConfig
  wlCfgGlobal: pointer
  bl808RfChannelPowerIndex: uint8
  bl808RfChannelPowerComp, bl808RfChannelLpPowerComp: array[14, int16]
  bl808RfTempMeasurementPass: uint8
  bl808RfTempPowerComp, bl808RfAppliedPowerComp: int16
  bl808RfCurrentTemperatureC: int16
  replayCalls: seq[uint32]
  tempCalls: seq[tuple[pass: uint8, temperature: int32]]
  rebindAfterReplay, clearAfterReplay: bool
proc rfSignedByte(value: uint8): int16 = cast[int8](value).int16
proc rf_pri_set_channel_lp_pwr_comp(index: uint32) =
  replayCalls.add(index)
  if rebindAfterReplay: wlCfgGlobal = addr secondCfg
  if clearAfterReplay: wlCfgGlobal = nil
proc rf_pri_set_temp_comp(temperature: int32) =
  tempCalls.add((bl808RfTempMeasurementPass, temperature))
  if bl808RfTempMeasurementPass != 0: bl808RfTempPowerComp = temperature.int16
'''
    code += rf_procedure(RF.read_text(), "rf_pri_set_channel_pwr_comp")
    code += r'''
firstCfg.channelPowerComp[0] = 0xFE
firstCfg.channelLowPowerComp[0] = 3
firstCfg.temperaturePowerComp = 7
secondCfg.temperaturePowerComp = 0xF5
bl808RfCurrentTemperatureC = 29
wlCfgGlobal = addr firstCfg
rebindAfterReplay = true
rf_pri_set_channel_pwr_comp(1)
doAssert replayCalls == @[1'u32]
doAssert bl808RfChannelPowerComp[0] == -2
doAssert bl808RfChannelLpPowerComp[0] == 3
doAssert tempCalls == @[(1'u8, -11'i32), (0'u8, 29'i32)]
doAssert bl808RfAppliedPowerComp == -11

tempCalls.setLen(0)
replayCalls.setLen(0)
wlCfgGlobal = addr firstCfg
rebindAfterReplay = false
clearAfterReplay = true
rf_pri_set_channel_pwr_comp(2)
doAssert replayCalls == @[2'u32]
doAssert tempCalls.len == 0
doAssert bl808RfTempMeasurementPass == 0

replayCalls.setLen(0)
rf_pri_set_channel_pwr_comp(257)
doAssert bl808RfChannelPowerIndex == 0
doAssert replayCalls.len == 0
'''
    run_program(tmp_path, mode, code)
