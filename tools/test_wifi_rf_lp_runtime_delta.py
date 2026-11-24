"""Check the retained RF low-power channel compensation table transform."""

from pathlib import Path

import pytest

from test_wifi_message_allocation import run_program
from test_wifi_rf_channel_entry import rf_procedure
from test_wifi_rf_power_replay import RF


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_low_power_channel_delta_updates_only_high_power_rows(
    tmp_path: Path, mode: str
) -> None:
    rf = RF.read_text()
    source = r'''
type
  RfPriTxPowerTableRow = array[9, int16]
  RfPriPowerTableScope = enum rfPowerAll, rfPowerWlan, rfPowerBz
const
  RfPriTxPowerRowPowerThresholdTenthsIndex = 8
  RfPriTxPowerTableDefault = block:
    var rows: array[18, RfPriTxPowerTableRow]
    for i in 0 ..< rows.len:
      rows[i][7] = (i - 9).int16
      rows[i][8] = (240 - i * 30).int16
    rows
  RfPriTxPowerTableIndexDefault = block:
    var indices: array[13, int16]
    for i in 0 ..< indices.len: indices[i] = (i + 2).int16
    indices
var
  bl808RfTxPowerTable = RfPriTxPowerTableDefault
  bl808RfTxPowerTableIndex = RfPriTxPowerTableIndexDefault
  bl808RfLowPowerTableDelta: int16
  bl808RfChannelLpPowerComp: array[14, int16]
  bl808RfChannelPowerComp: array[14, int16]
  writes: int
proc rfPriWriteTxPowerTable(scope: RfPriPowerTableScope = rfPowerAll) =
  doAssert scope == rfPowerWlan
  inc writes
'''
    for name in (
        "rfSignExtend16",
        "rfPriResetTxPowerRuntimeTables",
        "rfPriApplyLowPowerRuntimeDelta",
        "rf_pri_set_channel_lp_pwr_comp",
    ):
        source += rf_procedure(rf, name)
    source += r'''
const cases = [
  (-32768'i32, -3'i32, 0'i32),
  (-37'i32, -3'i32, 0'i32),
  (-36'i32, -3'i32, 0'i32),
  (-31'i32, -3'i32, 5'i32),
  (-30'i32, -2'i32, -6'i32),
  (-19'i32, -2'i32, 5'i32),
  (-18'i32, -1'i32, -6'i32),
  (-7'i32, -1'i32, 5'i32),
  (-6'i32, 0'i32, -6'i32),
  (8'i32, 0'i32, 8'i32),
  (9'i32, 1'i32, -3'i32),
  (20'i32, 1'i32, 8'i32),
  (21'i32, 2'i32, -3'i32),
  (24'i32, 2'i32, 0'i32),
  (25'i32, 2'i32, 0'i32),
  (32767'i32, 2'i32, 0'i32),
]
for (delta, coarse, residual) in cases:
  for channel in 1 .. 14:
    bl808RfTxPowerTable = default(typeof(bl808RfTxPowerTable))
    bl808RfTxPowerTableIndex = default(typeof(bl808RfTxPowerTableIndex))
    bl808RfChannelPowerComp[channel - 1] = 0
    bl808RfChannelLpPowerComp[channel - 1] = delta.int16
    writes = 0
    rf_pri_set_channel_lp_pwr_comp(channel.uint32)
    doAssert writes == 1 and bl808RfLowPowerTableDelta == delta.int16
    for row in 0 ..< 18:
      let expected = RfPriTxPowerTableDefault[row]
      if row < 7:
        doAssert bl808RfTxPowerTable[row] == expected
      else:
        doAssert bl808RfTxPowerTable[row][7] == expected[7] + residual.int16
        doAssert bl808RfTxPowerTable[row][8] == expected[8] - (coarse * 30).int16
        for field in 0 ..< 7:
          doAssert bl808RfTxPowerTable[row][field] == expected[field]
    for slot in 0 ..< 13:
      let expected = RfPriTxPowerTableIndexDefault[slot]
      doAssert bl808RfTxPowerTableIndex[slot] ==
        (if slot < 7: expected else: expected - coarse.int16)
for (lowPower, normal, expectedDelta) in [
  (32767'i16, -32768'i16, -1'i16),
  (-32768'i16, 32767'i16, 1'i16)]:
  bl808RfChannelLpPowerComp[0] = lowPower
  bl808RfChannelPowerComp[0] = normal
  writes = 0
  rf_pri_set_channel_lp_pwr_comp(1)
  doAssert writes == 1 and bl808RfLowPowerTableDelta == expectedDelta
  doAssert bl808RfTxPowerTable[7][7] ==
    RfPriTxPowerTableDefault[7][7] + expectedDelta
for invalid in [0'u32, 15'u32, high(uint32)]:
  writes = 0
  let beforeTable = bl808RfTxPowerTable
  let beforeIndices = bl808RfTxPowerTableIndex
  rf_pri_set_channel_lp_pwr_comp(invalid)
  doAssert writes == 0 and bl808RfTxPowerTable == beforeTable
  doAssert bl808RfTxPowerTableIndex == beforeIndices
'''
    run_program(tmp_path, mode, source)
