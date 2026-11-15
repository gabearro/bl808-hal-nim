"""Exercise MAC polling with the real control flow and modeled CSR/MMIO access."""

from pathlib import Path
import re

import pytest

from test_wifi_message_allocation import ROOT, run_program


SUPPORT = ROOT / "src/bl808/wifi/support"

PLATFORM = r'''
var
  irqState: uint32
  saves, restores: int
  registers: array[4, uint32]
  reads: seq[uint32]
  handlers: seq[string]
  persistent: bool
  macIrqCount, macPollIrqCount, macTrapIrqCount, ipcTrapIrqCount: uint32
proc regRead32(address: uint32): uint32 =
  doAssert (irqState and 8) == 0 and saves == restores + 1
  reads.add(address)
  case address
  of MacIrqStatus0: registers[0]
  of MacIrqStatus1: registers[1]
  of MachwIrqRaw: registers[2]
  of MachwIrqUnmask: registers[3]
  else: raise newException(ValueError, "unexpected MMIO read")
proc mac_irq() =
  doAssert (irqState and 8) == 0
  handlers.add("mac")
  if not persistent:
    registers[0] = 0
    registers[1] = 0
proc hal_machw_gen_handler() =
  doAssert (irqState and 8) == 0
  handlers.add("general")
  if not persistent: registers[2] = 0
proc bl_irq_handler() =
  doAssert (irqState and 8) == 0
  handlers.add("ipc")
proc setup(enabled: bool) =
  irqState = 0xA5A50000'u32 or (if enabled: 8'u32 else: 0'u32)
  saves = 0
  restores = 0
  registers = default(typeof(registers))
  reads.setLen(0)
  handlers.setLen(0)
  persistent = false
  macIrqCount = 10
  macPollIrqCount = 20
  macTrapIrqCount = 30
  ipcTrapIrqCount = 40
proc checkPoll(enabled: bool; expected: seq[string]; rounds: int) =
  doAssert irqState == (0xA5A50000'u32 or (if enabled: 8'u32 else: 0'u32))
  doAssert saves == rounds and restores == rounds
  doAssert handlers == expected
  doAssert macIrqCount == 10 + expected.len.uint32
  doAssert macPollIrqCount == 20 + expected.len.uint32
  doAssert macTrapIrqCount == 30 and ipcTrapIrqCount == 40
  doAssert reads.len == rounds * 4
  for i in 0..<rounds:
    doAssert reads[i*4..i*4+3] ==
      @[MacIrqStatus0, MacIrqStatus1, MachwIrqRaw, MachwIrqUnmask]
'''


def source() -> str:
    constants = (SUPPORT / "defs_parts/mmio.nim").read_text()
    names = "MacIrqStatus0|MacIrqStatus1|MachwIrqRaw|MachwIrqUnmask"
    constants = re.findall(r"^  (?:" + names + r") = .*$", constants, re.M)
    assert len(constants) == 4
    backend = (SUPPORT / "backend_irq.nim").read_text()
    backend = backend.split("template macServiceIrqSave", 1)[1]
    backend = "template macServiceIrqSave" + backend
    emissions = re.findall(r"\{\.emit:.*?\.\}", backend, re.S)
    assert len(emissions) == 2
    # Keep the real template branches; replace only the target CSR instructions.
    backend = backend.replace(emissions[0],
        "prev = irqState\n    irqState = irqState and not 8'u32\n    inc saves", 1)
    backend = backend.replace(emissions[1], "irqState = irqState or 8'u32", 1)
    backend = backend.replace("template macServiceIrqRestore(prev: uint32) =\n",
        "template macServiceIrqRestore(prev: uint32) =\n  inc restores\n", 1)
    return "const\n" + "\n".join(constants) + "\n" + PLATFORM + backend


CASES = {
    "idle_and_masked": r'''
for enabled in [false, true]:
  for raw in [0'u32, 1, 0xFFFFFFFF'u32]:
    setup(enabled)
    registers[2] = raw
    bl808WifiBackendPollMacIrq()
    checkPoll(enabled, @[], 1)
''',
    "dispatch_and_drain": r'''
for enabled in [false, true]:
  for slot in [0, 1]:
    for bit in [1'u32, 0x80000000'u32]:
      setup(enabled)
      registers[slot] = bit
      registers[2] = 0xB
      registers[3] = 2
      bl808WifiBackendPollMacIrq()
      checkPoll(enabled, @["mac", "general"], 3)
  setup(enabled)
  registers[2] = 0x80000000'u32
  registers[3] = 0x80000000'u32
  bl808WifiBackendPollMacIrq()
  checkPoll(enabled, @["general"], 2)
''',
    "bounded_service": r'''
for enabled in [false, true]:
  for platform in [false, true]:
    setup(enabled)
    if platform: registers[0] = 1
    else:
      registers[2] = 8
      registers[3] = 8
    persistent = true
    var expected: seq[string]
    for _ in 0..<32: expected.add(if platform: "mac" else: "general")
    bl808WifiBackendPollMacIrq()
    checkPoll(enabled, expected, 32)
    bl808WifiBackendPollMacIrq()
    expected.add(expected)
    checkPoll(enabled, expected, 64)
    registers = default(typeof(registers))
    bl808WifiBackendPollMacIrq()
    checkPoll(enabled, expected, 65)
''',
    "trap_entry": r'''
setup(false)
bl808WifiBackendMacIrqTrampoline()
bl808WifiBackendIpcIrqTrampoline()
doAssert irqState == 0xA5A50000'u32
doAssert saves == 0 and restores == 0 and reads.len == 0
doAssert handlers == @["mac", "ipc"]
doAssert macIrqCount == 11 and macPollIrqCount == 20
doAssert macTrapIrqCount == 31 and ipcTrapIrqCount == 41
''',
}


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("case", CASES)
def test_backend_irq(tmp_path: Path, mode: str, case: str) -> None:
    run_program(tmp_path, mode, source() + CASES[case])
