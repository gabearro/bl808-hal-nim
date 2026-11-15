"""Keep TX accounting and IPC ownership transfer within the same IRQ scope."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_host_completion_owner import program
from test_wifi_message_allocation import run_program


def source() -> str:
    code = "var requireCritical = false\n" + program(None)
    code = code.replace(procedure(code, "hostTxHeadThd"), r'''
proc hostTxHeadThd(p: ptr HwDesc): ptr HeadThd =
  if requireCritical: doAssert not interruptsEnabled
  p.head
''', 1)
    code += r'''
var internalQueued, internalDrains: int
var expectedDrainIrq = true
proc txl_frame_cfm(p: pointer) =
  if requireCritical: doAssert not interruptsEnabled
  inc internalQueued
proc txl_frame_evt() =
  if requireCritical: doAssert interruptsEnabled == expectedDrainIrq
  inc internalDrains
'''
    tx = (FW / "tx_layer.nim").read_text()
    for name in ("txl_cfm_flush", "txl_cfm_flush_desc"):
        code += procedure(tx, name)
    return code


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_host_publication_precedes_first_irq_restore(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for operation in 0 .. 2:
  for ac in 0'u8 .. 4:
    setup()
    requireCritical = true
    internalQueued = 0
    internalDrains = 0
    let frame = addr wrappers[0].txDesc
    txEnv.packetCounter = 1
    ke_env[0] = txl_cfm_evt_bit[ac]
    var list: CoList
    if operation == 0: co_list_push_back(addr confirmLists[ac], addr frame.link)
    elif operation == 1: co_list_push_back(addr list, addr frame.link)
    var fired = false
    onRestore = proc() =
      if fired or txEnv.packetCounter != 0: return
      fired = true
      onRestore = nil
      doAssert published.first == addr wrappers[0].link
      doAssert published.last == addr wrappers[0].link
      doAssert outputs[0] != 0 and wrappers[0].txDesc.active == 0
      drainPublished()
      # A new transmission may own the same wrapper after publication.
      wrappers[0].txDesc.active = 1
      wrappers[0].txDesc.bufDesc = cast[pointer](0x1234)
      txEnv.packetCounter = 7
    case operation
    of 0: txl_cfm_evt(ac)
    of 1: txl_cfm_flush(ac, addr list, 0x40000000'u32)
    else: txl_cfm_flush_desc(ac, frame, 0x40000000'u32)
    onRestore = nil
    doAssert fired and consumed == @[0]
    doAssert txEnv.packetCounter == 7 and wrappers[0].txDesc.active == 1
    doAssert wrappers[0].txDesc.bufDesc == cast[pointer](0x1234)
    doAssert published.first == nil and published.last == nil
    doAssert indications == @[(1'u32 shl ac)]
    doAssert internalDrains == (operation != 0).int and interruptsEnabled
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_internal_flush_drains_after_restoring_irq(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for batch in [false, true]:
  setup()
  requireCritical = true
  internalQueued = 0
  internalDrains = 0
  let frame = addr wrappers[0].txDesc
  frame.queueFirst = nil
  var list: CoList
  if batch:
    co_list_push_back(addr list, addr frame.link)
    txl_cfm_flush(0, addr list, 0x40000000'u32)
  else:
    txl_cfm_flush_desc(0, frame, 0x40000000'u32)
  doAssert internalQueued == 1 and internalDrains == 1
  doAssert published.first == nil and indications.len == 0
  doAssert interruptsEnabled
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_masked_completion_keeps_interrupts_masked(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for operation in 0 .. 2:
  setup()
  requireCritical = true
  expectedDrainIrq = false
  internalQueued = 0
  internalDrains = 0
  let frame = addr wrappers[0].txDesc
  txEnv.packetCounter = 1
  ke_env[0] = txl_cfm_evt_bit[2]
  var list: CoList
  if operation == 0: co_list_push_back(addr confirmLists[2], addr frame.link)
  elif operation == 1: co_list_push_back(addr list, addr frame.link)
  interruptsEnabled = false
  case operation
  of 0: txl_cfm_evt(2)
  of 1: txl_cfm_flush(2, addr list, 0x40000000'u32)
  else: txl_cfm_flush_desc(2, frame, 0x40000000'u32)
  doAssert not interruptsEnabled and txEnv.packetCounter == 0
  doAssert published.first == addr wrappers[0].link
  doAssert indications == @[4'u32]
  doAssert internalDrains == (operation != 0).int
  drainPublished()
  doAssert consumed == @[0]
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_batch_wrapper_can_be_reused_after_each_publication(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
setup()
requireCritical = true
internalQueued = 0
internalDrains = 0
var list: CoList
for i in 0 .. 1:
  co_list_push_back(addr list, addr wrappers[i].txDesc.link)
txEnv.packetCounter = 2
onRestore = proc() =
  if published.first == nil: return
  drainPublished()
  doAssert txEnv.packetCounter == (2 - consumed.len).uint32
  for i in consumed:
    wrappers[i].txDesc.active = 1
    wrappers[i].txDesc.bufDesc = cast[pointer](0x1234)
txl_cfm_flush(2, addr list, 0x40000000'u32)
onRestore = nil
doAssert consumed == @[0, 1] and txEnv.packetCounter == 0
doAssert list.first == nil and list.last == nil
doAssert published.first == nil and published.last == nil
doAssert internalDrains == 1 and indications == @[4'u32]
doAssert interruptsEnabled
for i in 0 .. 1:
  doAssert wrappers[i].txDesc.active == 1
  doAssert wrappers[i].txDesc.bufDesc == cast[pointer](0x1234)
''')
