"""Check BZ RF optimize crystal gating against the pinned rf_pri.c.o."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import procedure
from test_wifi_message_allocation import run_program
from test_wifi_rf_power_replay import RF


@pytest.mark.parametrize("mode", ["checked", "firmware"])
def test_bz_optimize_and_restore_require_40mhz_flag(tmp_path: Path, mode: str) -> None:
    rf = RF.read_text()
    code = r'''
type RfRegBlock = object
  optimizeCtrlD0: uint32
var
  regs: RfRegBlock
  bl808RfDeviceBl616, bl808RfDeviceWb03, bl808RfDeviceBl618m: uint8
  bl808RfPriXtal38p4mFlag, bl808RfPriXtal40mFlag: uint8
  writes: seq[tuple[keep, value: uint32]]
proc rfRegs(): ptr RfRegBlock = addr regs
proc updateReg32(reg: ptr uint32; keep, value: uint32) =
  writes.add((keep, value))
  reg[] = (reg[] and keep) or value
'''
    for name in (
        "rfPriDeviceInfoValid", "rfPriAnyKnownDeviceFlag",
        "rfPriBzOptimizeEnabled", "rf_pri_bz_optimize",
        "rf_pri_bz_optimize_restore",
    ):
        code += procedure(rf, name)
    run_program(tmp_path, mode, code + r'''
for deviceMask in 0 ..< 8:
  bl808RfDeviceBl616 = (deviceMask and 1).uint8
  bl808RfDeviceWb03 = ((deviceMask shr 1) and 1).uint8
  bl808RfDeviceBl618m = ((deviceMask shr 2) and 1).uint8
  for xtalMask in 0 ..< 4:
    bl808RfPriXtal38p4mFlag = (xtalMask and 1).uint8
    bl808RfPriXtal40mFlag = ((xtalMask shr 1) and 1).uint8
    let enabled = deviceMask != 0 and (xtalMask and 2) != 0
    doAssert rfPriBzOptimizeEnabled() == enabled
    for channel in [2459'u32, 2460, 2479, 2480, 2481]:
      for seed in [0'u32, 0xA5A55A5A'u32, high(uint32)]:
        regs.optimizeCtrlD0 = seed
        writes.setLen(0)
        rf_pri_bz_optimize(channel)
        let edge = channel == 2460 or channel == 2480
        let wanted =
          if not enabled: seed
          elif edge: seed and not 4'u32
          else: seed or 4'u32
        doAssert regs.optimizeCtrlD0 == wanted
        if enabled:
          let expectedKeep = if edge: not 4'u32 else: not 0'u32
          let expectedValue = if edge: 0'u32 else: 4'u32
          doAssert writes == @[(expectedKeep, expectedValue)]
        else:
          doAssert writes.len == 0

        writes.setLen(0)
        rf_pri_bz_optimize_restore()
        doAssert regs.optimizeCtrlD0 == (if enabled: wanted or 4'u32 else: wanted)
        if enabled:
          doAssert writes == @[(not 0'u32, 4'u32)]
        else:
          doAssert writes.len == 0
''')
