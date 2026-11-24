"""Exercise the RF power-level dispatch and bounded lookup arithmetic."""

from pathlib import Path

import pytest

from test_wifi_message_allocation import run_program
from test_wifi_rf_channel_entry import rf_procedure
from test_wifi_rf_power_replay import RF


@pytest.mark.parametrize("mode", ["checked", "firmware"])
def test_rf_power_level_boundaries(tmp_path: Path, mode: str) -> None:
    rf = RF.read_text()
    source = r'''
type RfPriTxPowerTableRow = array[9, int16]
const RfPriTxPowerRowPowerThresholdTenthsIndex = 8
var
  bl808RfTxPowerTable: array[18, RfPriTxPowerTableRow]
  bl808RfTxGainComp: int16
'''
    source += rf_procedure(rf, "rfPriGetTxGainIndex")
    source += rf_procedure(rf, "rfc_get_power_level")
    source += r'''
for row in 0 ..< 16:
  bl808RfTxPowerTable[row][8] = int16(240 - row * 30)

for rateClass in [0'u32, 1, 2, 3, high(uint32)]:
  doAssert rfc_get_power_level(rateClass, low(int32)) == 60'u32
  doAssert rfc_get_power_level(rateClass, high(int32)) == 0'u32

doAssert rfc_get_power_level(1, 240) == 0'u32
doAssert rfc_get_power_level(2, 240) == 0'u32
doAssert rfc_get_power_level(1, 239) == 4'u32
doAssert rfc_get_power_level(0, 270) == 0'u32
doAssert rfc_get_power_level(0, 269) == 4'u32
doAssert rfc_get_power_level(1, -180) == 56'u32
doAssert rfc_get_power_level(1, -181) == 60'u32

bl808RfTxGainComp = 10
doAssert rfc_get_power_level(1, 249) == 4'u32
doAssert rfc_get_power_level(1, 250) == 0'u32
doAssert rfc_get_power_level(0, 279) == 4'u32
doAssert rfc_get_power_level(0, 280) == 0'u32
'''
    run_program(tmp_path, mode, source)


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_rf_txgain_limits_use_selected_signed_table_rows(tmp_path: Path, mode: str) -> None:
    rf = RF.read_text()
    source = r'''
type RfPriTxPowerTableRow = array[9, int16]
const RfPriTxPowerRowTxGainTenthsIndex = 6
var
  bl808RfTxPowerTable: array[18, RfPriTxPowerTableRow]
  bl808RfTxPowerTableIndex: array[13, int16]
'''
    for name in (
        "rfPriDivTowardZeroBy10",
        "rfPriTxGainDbForTableIndex",
        "rf_pri_get_txgain_max",
        "rf_pri_get_txgain_min",
    ):
        source += rf_procedure(rf, name)
    source += r'''
bl808RfTxPowerTableIndex[0] = 4
bl808RfTxPowerTableIndex[12] = 16
bl808RfTxPowerTable[4][6] = 129
bl808RfTxPowerTable[16][6] = -129
doAssert rf_pri_get_txgain_max() == 12
doAssert rf_pri_get_txgain_min() == -12

bl808RfTxPowerTable[4][6] = 9
bl808RfTxPowerTable[16][6] = -9
doAssert rf_pri_get_txgain_max() == 0
doAssert rf_pri_get_txgain_min() == 0

bl808RfTxPowerTableIndex[0] = -1
bl808RfTxPowerTableIndex[12] = 18
doAssert rf_pri_get_txgain_max() == 0
doAssert rf_pri_get_txgain_min() == 0
'''
    run_program(tmp_path, mode, source)
