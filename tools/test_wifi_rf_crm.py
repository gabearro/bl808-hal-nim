"""Check CRM clock and reset stores against crm_bl616.c.o."""

from pathlib import Path

import pytest

from test_wifi_message_allocation import run_program
from test_wifi_rf_channel_entry import rf_procedure
from test_wifi_rf_power_replay import RF, object_type


def source() -> str:
    rf = RF.read_text()
    code = object_type(rf, "CrmPhyClockBlock") + r'''
var
  clock: CrmPhyClockBlock
  events: seq[tuple[offset: int, value: uint32]]
proc crmPhyClockRegs(): ptr CrmPhyClockBlock = addr clock
proc updateReg32(p: ptr uint32; keep, value: uint32) =
  p[] = (p[] and keep) or value
  events.add((cast[int](p) - cast[int](addr clock), p[]))
proc volatileStore(p: ptr uint32; value: uint32) =
  p[] = value
  events.add((cast[int](p) - cast[int](addr clock), value))
proc arch_delay_us(us: uint32) = events.add((-1, us))
'''
    for name in ("crm_init", "crm_mdm_reset", "crm_clk_set"):
        code += rf_procedure(rf, name)
    return code


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_crm_register_sequences(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for seed in [0'u32, high(uint32), 0xA5A5A5A5'u32, 0x76543210'u32]:
  clock.rfClockMux10 = seed
  events.setLen(0)
  crm_init()
  let expected = seed or 0x08000000'u32
  doAssert clock.rfClockMux10 == expected
  doAssert events == @[(0x10, expected)]

for bit in 0 .. 31:
  clock.rfClockMux10 = 1'u32 shl bit
  events.setLen(0)
  crm_init()
  doAssert clock.rfClockMux10 == ((1'u32 shl bit) or 0x08000000'u32)
  doAssert events == @[(0x10, clock.rfClockMux10)]

for mode in [0'u32, 1, 2, high(uint32)]:
  clock.phyClockSelect8 = 0xA5A5A5A5'u32
  events.setLen(0)
  crm_clk_set(mode)
  var expected = 0xA5A5A5A5'u32
  var wanted: seq[tuple[offset: int, value: uint32]]
  if mode <= 1:
    expected = (expected and 0xFFFFFFCF'u32) or (if mode == 1: 0x10'u32 else: 0'u32)
    wanted.add((0x08, expected))
    expected = (expected and 0xFFFFFF3F'u32) or (if mode == 1: 0x40'u32 else: 0'u32)
    wanted.add((0x08, expected))
  doAssert clock.phyClockSelect8 == expected and events == wanted

events.setLen(0)
crm_mdm_reset()
doAssert clock.modemReset18 == 0
doAssert events == @[(0x18, 0x11'u32), (-1, 1'u32),
                     (0x18, 0'u32), (-1, 1'u32)]
''')
