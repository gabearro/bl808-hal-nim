"""Exercise the demo's native rate-power encoding and runtime table ownership."""

from pathlib import Path

import pytest

from test_wifi_message_allocation import run_program
from test_wifi_rf_channel_entry import rf_procedure
from test_wifi_rf_power_replay import RF
from test_wifi_tpc_adapter import source


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_native_trpc_does_not_reuse_legacy_config_rows(tmp_path: Path, mode: str) -> None:
    rf = RF.read_text()
    code = r'''
var
  nativeBank = true
  trpcEnv: array[2, uint32]
proc rfBankHasBl808WlanCal(): bool = nativeBank
'''
    code += RF.with_name("rf_bl808_trpc.nim").read_text() + source()
    for name in ("trpc_init", "trpc_get_power_idx", "phy_get_rf_gain_idx", "phy_get_rf_gain_capab"):
        code += rf_procedure(rf, name)
    code = code.replace("defined(bl808WifiNativeWlanCalibration)", "true")
    run_program(tmp_path, mode, code + r'''
setup()
let before = trpcTxpwrVsRateTable
doAssert cast[uint8](trpc_get_default_power_idx(0, 255)) == 80
doAssert cast[uint8](trpc_get_default_power_idx(1, 5)) == 72
doAssert cast[uint8](trpc_get_default_power_idx(2, 5)) == 64
doAssert tpc_get_vif_tx_power_vs_rate(0x805) == 64
doAssert cast[uint8](trpc_get_default_power_idx(high(uint32), 255)) == 64

var rates: array[24, uint8]
for i in 0 ..< rates.len: rates[i] = (100 + i).uint8
for (i, value) in [(0, 0xFF), (3, 11), (4, 19), (8, 12), (16, 13), (23, 14)]:
  rates[i] = value.uint8
trpc_update_power(addr rates[0])
loadConfig(0)
loadConfig(1)
var copied: array[24, uint8]
trpc_power_get(addr copied[0])
doAssert copied == rates and trpcTxpwrVsRateTable == before
doAssert cast[uint8](trpc_get_default_power_idx(0, 0)) == 0xE8
doAssert cast[uint8](trpc_get_default_power_idx(0, 4)) == 0xEC
doAssert cast[uint8](trpc_get_default_power_idx(1, 0)) == 0xF0
doAssert cast[uint8](trpc_get_default_power_idx(2, 0)) == 0xF4
doAssert cast[uint8](trpc_get_default_power_idx(2, 255)) == 56
let explicitPowerIndex: proc(formatMod, mcs: uint8; powerDbm: int8): uint8 {.cdecl.} =
  trpc_get_power_idx
for value in -128 .. 127:
  let expected = case value
    of -128 .. 10: 0xE8
    of 11: 0xEC
    of 12: 0xF0
    of 13: 0xF4
    else: (value * 4) and 255
  doAssert explicitPowerIndex(0, 0, value.int8) == expected.uint8
  doAssert explicitPowerIndex(255, 255, value.int8) == expected.uint8

trpcEnv = [0xA5FFFFFF'u32, 0xFFFFFFFF'u32]
trpc_init()
doAssert trpcEnv == [0xA51E0A19'u32, 0x0019098A'u32]
var input = -11'i8
var encoded, maxGain, minGain: int8
phy_get_rf_gain_idx(addr input, addr encoded)
phy_get_rf_gain_capab(addr maxGain, addr minGain)
doAssert input == -11 and encoded == input and maxGain == 22 and minGain == -8

nativeBank = false
phy_get_rf_gain_idx(addr input, addr encoded)
phy_get_rf_gain_capab(addr maxGain, addr minGain)
doAssert input == -10 and encoded == -10 and minGain == -10
doAssert cast[uint8](trpc_get_default_power_idx(0, 0)) == (before[0] shl 2)
''')


def test_pinned_rfc_noop_signatures(tmp_path: Path) -> None:
    rf = RF.read_text()
    code = "".join(rf_procedure(rf, name) for name in (
        "rfc_config_power", "rfc_apply_tx_dvga_offset", "rfc_apply_tx_dvga",
        "rfc_apply_tx_power_offset",
    ))
    run_program(tmp_path, "checked", code + r'''
let config: proc(mode, tbbBoost, tbb, tmx: uint32) {.cdecl.} = rfc_config_power
let offset: proc(offsetQdb: int8) {.cdecl.} = rfc_apply_tx_dvga_offset
let dvga: proc(dvgaQdb: ptr int8) {.cdecl.} = rfc_apply_tx_dvga
let power: proc(channel: uint8; powerOffset: ptr int8) {.cdecl.} = rfc_apply_tx_power_offset
var values: array[4, int8] = [-8'i8, 3, -1, 7]
let original = values
config(1, 2, 3, 4)
offset(-4)
dvga(addr values[0])
power(11, addr values[0])
doAssert values == original
''')
