"""Check MAC idle ownership, timer separation, and monitor filter persistence."""

from pathlib import Path
import re

import pytest

from test_wifi_auth_frames import layouts
from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


PLATFORM = r'''
const
  KE_EVT_PRIM_TBTT = 0x02000000'u32
  KE_EVT_SEC_TBTT = 0x01000000'u32
  KE_EVT_IDLE = 0x04000000'u32
  KE_EVT_KE_TIMER = 0x20000000'u32
  KE_EVT_MM_TIMER = 0x40000000'u32
type
  PsGuard = object
    before: array[16, uint8]
    value: PsEnvView
    after: array[16, uint8]
  MmGuard = object
    before: array[16, uint8]
    value: MmEnvView
    after: array[16, uint8]
var
  ps: PsGuard
  mm: MmGuard
  tx: tuple[resetInProgress: uint8]
  registers: array[0x9000 div 4, uint32]
  writes: seq[tuple[address: uint, value: uint32, interrupts: bool]]
  interrupts: bool
  events, assertions, timeoutCalls: uint32
  nimFwDbgMachwGen, nimFwDbgMachwStatus, nimFwDbgMachwGenStatus: uint32
  # Baseline-only sentinels detect use of the obsolete, unrelated storage.
  halMachwRxCntrlBackup, halMachwStatusFlags: uint32
proc psEnvView(): ptr PsEnvView = addr ps.value
proc mmEnvView(): ptr MmEnvView = addr mm.value
proc txControlEnv(): ptr typeof(tx) = addr tx
proc regRead(address: uint): uint32 =
  doAssert address >= MACHW_BASE and address < MACHW_BASE + 0x9000
  registers[(address - MACHW_BASE) div 4]
proc regWrite(address: uint; value: uint32) =
  doAssert address >= MACHW_BASE and address < MACHW_BASE + 0x9000
  writes.add((address, value, interrupts))
  registers[(address - MACHW_BASE) div 4] = value
proc setRegister(address: uint; value: uint32) =
  registers[(address - MACHW_BASE) div 4] = value
proc irqSave(): uint32 =
  result = if interrupts: 8'u32 else: 0'u32
  interrupts = false
proc irqRestore(saved: uint32) = interrupts = (saved and 8) != 0
proc assert_rec(a, b: cstring; line: cint) = inc assertions
proc waitRegLowNibbleClear(address: uint): bool =
  doAssert address == MACHW_STATE_CNTRL_REG
  setRegister(address, 0)
  true
proc nimFwTrace2U32(label: string; a, b: uint32) = discard
proc rxl_timeout_int_handler() = inc timeoutCalls
proc ke_evt_set(mask: uint32) =
  if (mask and KE_EVT_IDLE) != 0:
    doAssert (ps.value.statusFlags and 4) == 0
  events = events or mask
proc bytes(p: pointer; size: int): seq[uint8] =
  let data = cast[ptr UncheckedArray[uint8]](p)
  for index in 0..<size: result.add(data[index])
proc checkPsUnchangedExceptFlags(snapshot: seq[uint8]) =
  let actual = bytes(addr ps, sizeof(ps))
  let offset = offsetof(PsGuard, value) + offsetof(PsEnvView, statusFlags)
  for index in 0..<actual.len:
    if index < offset or index >= offset + 4:
      doAssert actual[index] == snapshot[index]
proc checkMmUnchangedExceptFilter(snapshot: seq[uint8]) =
  let actual = bytes(addr mm, sizeof(mm))
  let offset = offsetof(MmGuard, value) + offsetof(MmEnvView, rxFilterBase)
  for index in 0..<actual.len:
    if index < offset or index >= offset + 4:
      doAssert actual[index] == snapshot[index]
proc setup(enabled: bool) =
  for value in ps.before.mitems: value = 0xA5
  for value in ps.after.mitems: value = 0x5A
  for value in mm.before.mitems: value = 0x3C
  for value in mm.after.mitems: value = 0xC3
  ps.value = default(PsEnvView)
  tx.resetInProgress = 0
  mm.value = default(MmEnvView)
  ps.value.enabled = 1
  ps.value.mode = 2
  ps.value.statusFlags = 0xC000000A'u32
  ps.value.flags = 0xB1
  mm.value.rxFilterBase = 0x3503858C'u32
  mm.value.rxFilterExtra = 0x80000021'u32
  mm.value.keepAliveLimit = 10
  registers = default(typeof(registers))
  writes.setLen(0)
  events = 0
  assertions = 0
  timeoutCalls = 0
  interrupts = enabled
  halMachwRxCntrlBackup = 0x31415926
  halMachwStatusFlags = 0x13579002
  setRegister(MACHW_STATE_CNTRL_REG, 3)
  setRegister(MACHW_TIMLO_REG, 0xFFFFFF00'u32)
  setRegister(MACHW_ABS_TIMER_REG, 0x12345678'u32)
  setRegister(MACHW_INTC_IRQ_STAT_REG, 0x180)
  setRegister(MACHW_INTC_UNMASK_REG, 0x10000)
'''


def source() -> str:
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    constants = (FW / "register_constants.nim").read_text().split("\nwhen defined", 1)[0]
    interrupt_constants = re.findall(r"^  MACHW_INTC_.*$", kernel, re.M)
    code = constants + "\nconst\n" + "\n".join(interrupt_constants) + "\n"
    code += layouts("PsEnvView", "MmEnvView") + PLATFORM
    for name in ["hal_machw_idle_req", "hal_machw_disable_int", "hal_machw_reset", "hal_machw_gen_handler",
                 "hal_machw_monitor_mode", "mm_rx_filter_set"]:
        code += procedure(kernel, name)
    return code


CASES = {
    "idle_timer": r'''
setup(true)
hal_machw_idle_req()
doAssert regRead(MACHW_BASE + 0x13C) == 0xC250, "wrong idle timer register"
doAssert regRead(MACHW_ABS_TIMER_REG) == 0x12345678, "MM timer was overwritten"
''',
    "idle_request": r'''
for enabled in [false, true]:
  setup(enabled)
  let before = bytes(addr ps, sizeof(ps))
  let beforeMm = bytes(addr mm, sizeof(mm))
  hal_machw_idle_req()
  doAssert ps.value.statusFlags == 0xC000000E'u32, "idle request did not publish PS flag"
  doAssert regRead(MACHW_BASE + 0x13C) == 0xC250, "wrong idle timer register"
  doAssert regRead(MACHW_ABS_TIMER_REG) == 0x12345678, "MM timer was overwritten"
  doAssert regRead(MACHW_STATE_CNTRL_REG) == 0
  doAssert regRead(MACHW_INTC_IRQ_STAT_REG) == 0x1A0
  doAssert regRead(MACHW_INTC_UNMASK_REG) == 0x10004
  doAssert writes.len == 6
  for write in writes: doAssert not write.interrupts
  doAssert interrupts == enabled and assertions == 0
  doAssert halMachwStatusFlags == 0x13579002
  checkPsUnchangedExceptFlags(before)
  doAssert bytes(addr mm, sizeof(mm)) == beforeMm
''',
    "idle_rejected": r'''
for enabled in [false, true]:
  setup(enabled)
  let before = bytes(addr ps, sizeof(ps))
  setRegister(MACHW_STATE_CNTRL_REG, 0x20)
  hal_machw_idle_req()
  doAssert assertions == 1 and writes.len == 0
  doAssert interrupts == enabled and bytes(addr ps, sizeof(ps)) == before
''',
    "idle_complete": r'''
for enabled in [false, true]:
  setup(enabled)
  hal_machw_idle_req()
  let before = bytes(addr ps, sizeof(ps))
  setRegister(MACHW_INTC_STATUS_RAW, 4)
  hal_machw_gen_handler()
  doAssert ps.value.statusFlags == 0xC000000A'u32
  doAssert events == KE_EVT_IDLE and assertions == 0
  doAssert (regRead(MACHW_INTC_IRQ_STAT_REG) and 0x20) == 0
  doAssert interrupts == enabled
  checkPsUnchangedExceptFlags(before)
''',
    "idle_incomplete": r'''
setup(true)
ps.value.statusFlags = ps.value.statusFlags or 4
let before = bytes(addr ps, sizeof(ps))
setRegister(MACHW_INTC_UNMASK_REG, 4)
setRegister(MACHW_INTC_STATUS_RAW, 4)
hal_machw_gen_handler()
doAssert assertions == 1 and events == 0
doAssert bytes(addr ps, sizeof(ps)) == before
''',
    "reset_clears_pending": r'''
for enabled in [false, true]:
  setup(enabled)
  ps.value.statusFlags = ps.value.statusFlags or 4
  let before = bytes(addr ps, sizeof(ps))
  let beforeMm = bytes(addr mm, sizeof(mm))
  hal_machw_reset()
  doAssert ps.value.statusFlags == 0xC000000A'u32, "reset left idle pending"
  doAssert halMachwStatusFlags == 0x13579002 and interrupts == enabled
  doAssert (regRead(MACHW_STATUS_REG) and 0x80) != 0
  checkPsUnchangedExceptFlags(before)
  doAssert bytes(addr mm, sizeof(mm)) == beforeMm
''',
    "monitor_filter": r'''
for enabled in [false, true]:
  for argument in [false, true]:
    setup(enabled)
    let before = bytes(addr ps, sizeof(ps))
    let beforeMm = bytes(addr mm, sizeof(mm))
    setRegister(MACHW_INTC_UNMASK_REG, 0x80000007'u32)
    setRegister(MACHW_STATUS_REG, 0x0101FFFF)
    hal_machw_monitor_mode(argument)
    doAssert mm.value.rxFilterBase == 0x7FFFFFDE'u32, "monitor filter not published"
    doAssert regRead(MACHW_RX_CNTRL_REG) == 0xFFFFFFFF'u32
    doAssert regRead(MACHW_INTC_UNMASK_REG) == 0x80000004'u32
    doAssert (regRead(MACHW_STATUS_REG) and 0x1E700) == 0xE700
    mm_rx_filter_set()
    doAssert regRead(MACHW_RX_CNTRL_REG) == 0xFFFFFFFF'u32, "filter update lost monitor mode"
    mm.value.rxFilterExtra = 0
    mm_rx_filter_set()
    doAssert regRead(MACHW_RX_CNTRL_REG) == 0x7FFFFFDE'u32
    mm.value.rxFilterExtra = 0x80000021'u32
    doAssert halMachwRxCntrlBackup == 0x31415926
    doAssert halMachwStatusFlags == 0x13579002 and interrupts == enabled
    checkMmUnchangedExceptFilter(beforeMm)
    doAssert bytes(addr ps, sizeof(ps)) == before
''',
}


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("case", CASES)
def test_mac_state(tmp_path: Path, case: str, mode: str) -> None:
    run_program(tmp_path, mode, source() + CASES[case])
