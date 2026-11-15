"""Check notifier traversal after callback-driven list changes."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


PLATFORM = r'''
type
  CoListHdr = object
    next: pointer
  CoList = object
    first, last: ptr CoListHdr
  NotifierNodeView = object
    callback, next: pointer
    priority: int32
var
  nodes: array[5, NotifierNodeView]
  chain: CoList
  calls: seq[int]
  interrupts, callbackIrq: bool
  saves, restores: int
  onCallback: proc(index: int)
  payload: uint32
  fw_nap_chain: array[1, NotifierNodeView]
  fw_nap_chain_ptr: pointer
proc notifierNodeView(node: ptr CoListHdr): ptr NotifierNodeView =
  cast[ptr NotifierNodeView](node)
proc irqSave(): uint32 =
  inc saves
  result = if interrupts: 8'u32 else: 0'u32
  interrupts = false
proc irqRestore(saved: uint32) =
  inc restores
  interrupts = (saved and 8) != 0
proc callback(node: ptr CoListHdr; event: uint32; data: pointer): cint {.cdecl.} =
  doAssert interrupts == callbackIrq
  doAssert event == 0xA5A50001'u32 and data == (addr payload)
  var found = false
  for index in 0 ..< nodes.len:
    if node == cast[ptr CoListHdr](addr nodes[index]):
      found = true
      calls.add(index)
      if onCallback != nil: onCallback(index)
      break
  doAssert found
  0x8000
proc setup(irq: bool) =
  nodes = default(typeof(nodes))
  chain = default(CoList)
  chain.last = cast[ptr CoListHdr](0x1234)
  calls.setLen(0)
  interrupts = irq
  callbackIrq = false
  saves = 0
  restores = 0
  onCallback = nil
  for index in 0 ..< nodes.len:
    nodes[index].callback = cast[pointer](callback)
    nodes[index].priority = (10 - index).int32
proc node(index: int): ptr CoListHdr = cast[ptr CoListHdr](addr nodes[index])
'''


def source() -> str:
    text = (FW / "mac_config_debug.nim").read_text()
    code = PLATFORM
    for name in ["notifier_chain_insert_ordered", "notifier_chain_remove",
                 "notifier_chain_regsiter", "notifier_chain_regsiter_fromCritical",
                 "notifier_chain_unregsiter", "notifier_chain_unregsiter_fromCritical",
                 "notifier_chain_call", "notifier_chain_call_fromeCritical"]:
        code += procedure(text, name)
    platform = (FW / "platform_bl.nim").read_text()
    for name in ["bl_nap_hook_register", "bl_nap_hook_unregister", "bl_nap_hook_call",
                 "bl_nap_hook_register_fromCritical", "bl_nap_hook_unregister_fromCritical",
                 "bl_nap_hook_call_fromCritical"]:
        code += procedure(platform, name)
    return code


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_removed_successor_is_not_dispatched(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for critical in [false, true]:
  for incoming in [false, true]:
    setup(incoming)
    callbackIrq = if critical: incoming else: false
    for index in 0 .. 2:
      notifier_chain_regsiter_fromCritical(addr chain, node(index))
    onCallback = proc(index: int) =
      if index == 0: notifier_chain_unregsiter_fromCritical(addr chain, node(1))
    if critical: notifier_chain_call_fromeCritical(addr chain, 0xA5A50001'u32, addr payload)
    else: notifier_chain_call(addr chain, 0xA5A50001'u32, addr payload)
    doAssert calls == @[0, 2]
    doAssert chain.last == cast[ptr CoListHdr](0x1234)
    doAssert interrupts == incoming
    doAssert saves == (not critical).int and restores == saves
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_inserted_successor_is_dispatched(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for critical in [false, true]:
  setup(false)
  notifier_chain_regsiter_fromCritical(addr chain, node(0))
  notifier_chain_regsiter_fromCritical(addr chain, node(2))
  onCallback = proc(index: int) =
    if index == 0: notifier_chain_regsiter_fromCritical(addr chain, node(1))
  if critical: notifier_chain_call_fromeCritical(addr chain, 0xA5A50001'u32, addr payload)
  else: notifier_chain_call(addr chain, 0xA5A50001'u32, addr payload)
  doAssert calls == @[0, 1, 2]
  doAssert not interrupts
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_empty_priority_and_current_node_removal(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
setup(true)
notifier_chain_call(addr chain, 0xA5A50001'u32, addr payload)
doAssert calls.len == 0 and interrupts and saves == 1 and restores == 1

setup(true)
nodes[1].priority = 10
nodes[2].priority = -5
nodes[3].priority = high(int32)
nodes[4].priority = low(int32)
for index in 0 .. 4:
  notifier_chain_regsiter_fromCritical(addr chain, node(index))
onCallback = proc(index: int) =
  if index == 3: notifier_chain_unregsiter_fromCritical(addr chain, node(3))
notifier_chain_call(addr chain, 0xA5A50001'u32, addr payload)
doAssert calls == @[3, 0, 1, 2, 4]
doAssert chain.first == node(0) and interrupts
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_nap_wrapper_observes_removal_during_callback(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for critical in [false, true]:
  setup(false)
  fw_nap_chain = default(typeof(fw_nap_chain))
  fw_nap_chain_ptr = addr fw_nap_chain[0]
  for index in 0 .. 2:
    bl_nap_hook_register_fromCritical(node(index))
  onCallback = proc(index: int) =
    if index == 0: bl_nap_hook_unregister_fromCritical(node(1))
  if critical: bl_nap_hook_call_fromCritical(0xA5A50001'u32, addr payload)
  else: bl_nap_hook_call(0xA5A50001'u32, addr payload)
  doAssert calls == @[0, 2] and not interrupts
''')
