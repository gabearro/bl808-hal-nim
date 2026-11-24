"""Check that platform-event callbacks cannot erase newly published work."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


@pytest.mark.parametrize("mode", ["checked", "firmware"])
def test_platform_event_snapshot_and_reentry(tmp_path: Path, mode: str) -> None:
    source = r'''
type KeEnvPsFlagsView {.packed.} = object
  flags, apPending, padding, otherPending, staPending: uint8
var
  shared: KeEnvPsFlagsView
  eventBits: uint32
  irqEnabled = true
  seen: seq[tuple[event: uint32, flags: KeEnvPsFlagsView]]
  onHandle: proc()
proc keEnvPsFlags(): ptr KeEnvPsFlagsView = addr shared
proc irqSave(): uint32 =
  result = irqEnabled.uint32
  irqEnabled = false
proc irqRestore(saved: uint32) = irqEnabled = saved != 0
proc ke_evt_clear(bit: uint32) = eventBits = eventBits and not bit
proc ke_evt_set(bit: uint32) = eventBits = eventBits or bit
proc c_memset(dst: pointer; value: cint; count: csize_t): pointer =
  doAssert value == 0 and count == 5
  zeroMem(dst, count.int)
  dst
proc bl_main_event_handle(event: uint32; payload: pointer) {.exportc, cdecl.} =
  let snapshot = if payload == nil: default(KeEnvPsFlagsView)
                 else: cast[ptr KeEnvPsFlagsView](payload)[]
  seen.add((event, snapshot))
  if onHandle != nil: onHandle()
'''
    source += procedure((FW / "kernel_mac_channel.nim").read_text(),
                        "bl_event_handle")
    source += r'''
let first = KeEnvPsFlagsView(flags: 1, staPending: 1)
let second = KeEnvPsFlagsView(flags: 2, apPending: 1)
shared = first
eventBits = 0x100'u32
onHandle = proc() =
  shared = second
  ke_evt_set(0x100'u32)
bl_event_handle(1)
doAssert seen == @[(1'u32, first)]
doAssert shared == second and eventBits == 0x100'u32 and irqEnabled

onHandle = nil
bl_event_handle(1)
doAssert seen == @[(1'u32, first), (1'u32, second)]
doAssert shared == default(KeEnvPsFlagsView) and eventBits == 0 and irqEnabled

shared = first
eventBits = 0x80'u32
bl_event_handle(0)
doAssert seen[^1] == (0'u32, default(KeEnvPsFlagsView))
doAssert shared == first and eventBits == 0 and irqEnabled

eventBits = 0x100'u32
let prior = seen.len
bl_event_handle(2)
doAssert seen.len == prior and eventBits == 0x100'u32 and shared == first

irqEnabled = false
bl_event_handle(1)
doAssert not irqEnabled
'''
    run_program(tmp_path, mode, source)
