"""Check the RF manual-calibration register moves against rf_pri.c.o."""

from pathlib import Path

import pytest

from test_wifi_message_allocation import run_program
from test_wifi_rf_channel_entry import rf_procedure
from test_wifi_rf_power_replay import RF


def source() -> str:
    rf = RF.read_text()
    code = r'''
type RfRegs = object
  txcalCtrlB8, channelCalStrobeB0, channelCalStatusB4, fcalCtrlA0: uint32
  sdmFractionalHighC8, sdmDivC4, sdmCtrlC0: uint32
  synthCtrl2c, baseCtrl1, calCtrl1c, fcalAc, acalCtrlA4: uint32
var
  bank: RfRegs
  writes: seq[tuple[reg: pointer, value: uint32]]
  delays: seq[uint32]
  states: seq[uint32]
  stateReads: int
proc rfRegs(): ptr RfRegs = addr bank
proc volatileLoad(reg: ptr uint32): uint32 =
  if reg == addr bank.fcalAc:
    result = states[stateReads] shl 24
    inc stateReads
  else:
    result = reg[]
proc volatileStore(reg: ptr uint32; value: uint32) =
  reg[] = value
  writes.add((cast[pointer](reg), value))
proc updateReg32(reg: ptr uint32; keep, setBits: uint32) =
  volatileStore(reg, (reg[] and keep) or setBits)
proc waitRfUs(us: uint32) = delays.add(us)
'''
    for name in (
        "rfPriManualCalAdjustCoarse",
        "rfPriManualCalAdjustFine",
        "rf_pri_manual_incremental_cal_start",
        "rf_pri_manual_incremental_cal_stop",
    ):
        code += rf_procedure(rf, name)
    return code


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_manual_cal_start_field_copies_retry_and_stop(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
proc coarse(word: uint32; delta: int): uint32 =
  let value = ((word shr 16) and 0x3F'u32).int + delta
  (word and 0xFFC0FFFF'u32) or ((value and 0x3F).uint32 shl 16)
proc fine(word: uint32; delta: int): uint32 =
  (word and 0xFFFFFF00'u32) or (((word and 0xFF'u32).int + delta) and 0xFF).uint32

for lowBits in 0'u32 .. 7'u32:
  for coarseDown in [false, true]:
    for retry in [false, true]:
      bank = RfRegs(
        txcalCtrlB8: 0xA50F0011'u32,
        channelCalStrobeB0: 0x12345678'u32,
        channelCalStatusB4: (0xA55A5A50'u32 or lowBits),
        fcalCtrlA0: 0xA55A12C4'u32,
        sdmFractionalHighC8: 0x87654321'u32,
        sdmDivC4: 0xFEDCBA98'u32,
        sdmCtrlC0: 0x12345678'u32,
        synthCtrl2c: 0xFFFF1234'u32,
        baseCtrl1: 0xABCD5678'u32,
        calCtrl1c: 0x00F00000'u32,
        acalCtrlA4: (if coarseDown: 0x1000'u32 else: 0'u32))
      writes.setLen(0)
      delays.setLen(0)
      states = if retry: @[0'u32, 3'u32, 1'u32] else: @[1'u32]
      stateReads = 0
      let original = bank
      rf_pri_manual_incremental_cal_start()

      # rf_pri.c.o +0x6a..0xa2 copies 8:9 -> 14:15, 0:2 ->
      # 11:13, then 4:5 -> 16:17 in the status word.
      let copiedHigh = (original.channelCalStatusB4 and 0xFFFF3FFF'u32) or
        ((original.channelCalStatusB4 shl 6) and 0xC000'u32)
      let copiedLow = (copiedHigh and 0xFFFFC7FF'u32) or
        ((copiedHigh and 7'u32) shl 11)
      let expectedStatus = (copiedLow and 0xFFFCFFFF'u32) or
        ((copiedLow and 0x30'u32) shl 12)
      doAssert bank.channelCalStatusB4 == expectedStatus
      doAssert (bank.channelCalStatusB4 and 0x3800'u32) == lowBits shl 11
      doAssert bank.sdmDivC4 ==
        ((original.sdmDivC4 and 0xC0000000'u32) or
         (original.sdmFractionalHighC8 and 0x3FFFFFFF'u32))

      let seeded = ((original.fcalCtrlA0 and 0xFFC0FF00'u32) or
        ((original.fcalCtrlA0 shr 8) and 0x003F0000'u32) or
        ((original.fcalCtrlA0 shr 8) and 0xFF'u32))
      var expectedFcal = @[seeded]
      if retry:
        let direction = if coarseDown: -1 else: 1
        expectedFcal.add(coarse(expectedFcal[^1], direction))
        expectedFcal.add(fine(expectedFcal[^1], 1))
        expectedFcal.add(coarse(expectedFcal[^1], direction))
        expectedFcal.add(fine(expectedFcal[^1], -1))
      var observedFcal: seq[uint32]
      for write in writes:
        if write.reg == cast[pointer](addr bank.fcalCtrlA0):
          observedFcal.add(write.value)
      doAssert observedFcal == expectedFcal
      doAssert stateReads == (if retry: 3 else: 1)
      doAssert delays == (if retry:
        @[10'u32, 10'u32, 10'u32, 10'u32, 10'u32]
        else: @[10'u32, 10'u32, 10'u32])

      let beforeStop = bank
      let writeCount = writes.len
      rf_pri_manual_incremental_cal_stop()
      doAssert bank.synthCtrl2c == (beforeStop.synthCtrl2c or 0x40'u32)
      doAssert bank.baseCtrl1 == ((beforeStop.baseCtrl1 and not 0xC'u32) or 4'u32)
      doAssert bank.calCtrl1c == (beforeStop.calCtrl1c or 0x60'u32)
      doAssert writes.len == writeCount + 3
      doAssert writes[writeCount].reg == cast[pointer](addr bank.synthCtrl2c)
      doAssert writes[writeCount + 1].reg == cast[pointer](addr bank.baseCtrl1)
      doAssert writes[writeCount + 2].reg == cast[pointer](addr bank.calCtrl1c)
''')
