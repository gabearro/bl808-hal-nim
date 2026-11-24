"""Exercise RF compensation ingress with valid and missing caller storage."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


RF = (FW / "global_state/rf_bl808_core.nim").read_text()


def source() -> str:
    code = r'''
var
  bl808RfChannelPowerComp: array[14, int16]
  bl808RfChannelLpPowerComp: array[14, int16]
  bl808RfBzChannelPowerComp: array[5, int16]
  bl808RfTempRoomOffset: int16
  bl808RfTempCalEnabled: uint8
  bl808RfTempChannelCount: uint32 = 5
  bl808RfTempChannels: array[5, uint16]
  bl808RfTempHighOffsets: array[5, int16]
  bl808RfTempLowOffsets: array[5, int16]
'''
    for name in (
        "rfSignedByte", "rf_pri_input_channel_pwr_comp",
        "rf_pri_input_channel_lp_pwr_comp", "rf_pri_input_temp_comp_param",
        "rf_pri_input_bz_channel_pwr_comp",
    ):
        code += procedure(RF, name)
    return code


@pytest.mark.parametrize("mode", ["checked", "firmware", "asan"])
def test_compensation_ingress_preserves_state_on_missing_input(
    tmp_path: Path, mode: str,
) -> None:
    run_program(tmp_path, mode, source() + r'''
var channelBytes: array[14, uint8]
for i in 0 ..< channelBytes.len:
  channelBytes[i] = uint8(i * 19)
channelBytes[0] = 0
channelBytes[1] = 127
channelBytes[2] = 128
channelBytes[3] = 255
rf_pri_input_channel_pwr_comp(addr channelBytes[0])
rf_pri_input_channel_lp_pwr_comp(addr channelBytes[0])
for i in 0 ..< channelBytes.len:
  doAssert bl808RfChannelPowerComp[i] == cast[int8](channelBytes[i]).int16
  doAssert bl808RfChannelLpPowerComp[i] == cast[int8](channelBytes[i]).int16
let normalBefore = bl808RfChannelPowerComp
let lowBefore = bl808RfChannelLpPowerComp
rf_pri_input_channel_pwr_comp(nil)
rf_pri_input_channel_lp_pwr_comp(nil)
doAssert bl808RfChannelPowerComp == normalBefore
doAssert bl808RfChannelLpPowerComp == lowBefore

var bzBytes = [0'u8, 127'u8, 128'u8, 255'u8, 42'u8]
rf_pri_input_bz_channel_pwr_comp(addr bzBytes[0])
for i in 0 ..< bzBytes.len:
  doAssert bl808RfBzChannelPowerComp[i] == cast[int8](bzBytes[i]).int16
let bzBefore = bl808RfBzChannelPowerComp
rf_pri_input_bz_channel_pwr_comp(nil)
doAssert bl808RfBzChannelPowerComp == bzBefore

var channels = [2412'u16, 2434, 2450, 2466, 2478]
var highOffsets = [10'i16, -20, 30, -40, 50]
var lowOffsets = [-11'i16, 21, -31, 41, -51]
rf_pri_input_temp_comp_param(addr channels[0], addr highOffsets[0],
                             addr lowOffsets[0], 17, 1)
doAssert bl808RfTempChannels == channels
doAssert bl808RfTempHighOffsets == highOffsets
doAssert bl808RfTempLowOffsets == lowOffsets
doAssert bl808RfTempRoomOffset == 17 and bl808RfTempCalEnabled == 1
for missing in 0 ..< 3:
  let channelPtr: pointer = if missing == 0: nil else: addr channels[0]
  let highPtr: pointer = if missing == 1: nil else: addr highOffsets[0]
  let lowPtr: pointer = if missing == 2: nil else: addr lowOffsets[0]
  rf_pri_input_temp_comp_param(channelPtr, highPtr, lowPtr, 99, 2)
  doAssert bl808RfTempChannels == channels
  doAssert bl808RfTempHighOffsets == highOffsets
  doAssert bl808RfTempLowOffsets == lowOffsets
  doAssert bl808RfTempRoomOffset == 17 and bl808RfTempCalEnabled == 1
rf_pri_input_temp_comp_param(nil, nil, nil, 23, 0)
doAssert bl808RfTempRoomOffset == 23 and bl808RfTempCalEnabled == 0
doAssert bl808RfTempChannels == channels
''')
