"""Observe firmware MAC state requests without retiming unrelated writes."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW
from test_wifi_message_allocation import run_program


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_trace_records_only_mac_state_writes(tmp_path: Path, mode: str) -> None:
    trace = (FW / "mac_state_trace.nim").read_text().replace("mmio.regWrite", "writeRegister")
    platform = r'''
from std/volatile import volatileStore
const MACHW_STATE_CNTRL_REG = 0x24B00038'u
var interrupts: bool
var clock, reads: uint32
var writes: seq[tuple[address: uint, word: uint32, interrupts: bool]]
proc writeRegister(address: uint; word: uint32) =
  writes.add((address, word, interrupts))
proc macTimeNow(): uint32 =
  doAssert not interrupts
  inc reads
  clock
proc irqSave(): uint32 =
  result = interrupts.uint32 shl 3
  interrupts = false
proc irqRestore(previous: uint32) = interrupts = (previous and 8) != 0
'''
    run_program(tmp_path, mode, platform + trace + r'''
for initialIrq in [false, true]:
  interrupts = initialIrq
  reads = 0
  macStateTraceCount = high(uint32) - 2
  clock = 0xFFFFFFFE'u32
  regWrite(MACHW_STATE_CNTRL_REG + 4, 0xBEEF)
  doAssert interrupts == initialIrq and reads == 0
  doAssert macStateTraceCount == high(uint32) - 2
  doAssert writes[^1] == (MACHW_STATE_CNTRL_REG + 4, 0xBEEF'u32, initialIrq)
  for i in 0'u32 ..< 11'u32:
    let slot = (macStateTraceCount mod MacStateTraceEntries.uint32).int
    let word = [0'u32, 0x20, 0x30][(i mod 3).int]
    regWrite(MACHW_STATE_CNTRL_REG, word)
    doAssert writes[^1] == (MACHW_STATE_CNTRL_REG, word, false)
    doAssert interrupts == initialIrq and reads == i + 1
    doAssert macStateTraceLog[slot] == [clock, word]
    inc clock
  doAssert macStateTraceCount == 8
  doAssert macStateTraceLog[0] == [1'u32, 0]
  doAssert macStateTraceLog[7] == [8'u32, 0x20]
''')
