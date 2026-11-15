"""Check TX-confirmation and RX-control diagnostics against the vendor ABI."""

from pathlib import Path

import pytest

from test_wifi_auth_frames import layouts
from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


PLATFORM = """
type
  CoListHdr = object
    next: ptr CoListHdr
  CoList = object
    first, last: ptr CoListHdr
""" + layouts(
    "HostTxDescView", "HostTxHwDescView",
    "HostTxThdEntryView", "RxlCntrlEnvView", "RxSwDescView", "RxMpduDescView",
).replace("mpduDescPadding*: uint32", "mpduDescPadding*: pointer") + r'''
# The MPDU list word follows the native pointer width in this host fixture.
# Firmware layout assertions and the M0 build check the actual RV32 offsets.
type Record = tuple[kind: char, line: cint, message: string]
var
  txQueues: array[5, CoList]
  txDescriptors: array[10, HostTxDescView]
  txHardware: array[10, HostTxHwDescView]
  txHeads: array[10, HostTxThdEntryView]
  rxEnv: RxlCntrlEnvView
  rxDescriptors: array[41, RxMpduDescView]
  rxHeaders: array[41, RxSwDescView]
  records: seq[Record]
  logEnabled, printEnabled: bool
  countCalls, headReads: int
  expectedFile: cstring
  interruptsEnabled, expectedIrq, snapshotActive: bool
  loggerAction: proc(line: cint)
  printerAction: proc()
  restoreAction: proc()
  headerReads: int
proc txCfmList(index: uint32): ptr CoList = addr txQueues[index]
proc rxlCntrlEnvView(): ptr RxlCntrlEnvView = addr rxEnv
proc hostTxDescAt(p: pointer): ptr HostTxDescView = cast[ptr HostTxDescView](p)
proc hostTxHwDescAt(p: pointer): ptr HostTxHwDescView = cast[ptr HostTxHwDescView](p)
proc rxMpduDescView(p: pointer): ptr RxMpduDescView = cast[ptr RxMpduDescView](p)
proc rxSwDescView(p: pointer): ptr RxSwDescView = cast[ptr RxSwDescView](p)
proc irqSave(): uint32 =
  result = if interruptsEnabled: 8'u32 else: 0'u32
  interruptsEnabled = false
  snapshotActive = true
proc irqRestore(saved: uint32) =
  interruptsEnabled = (saved and 8) != 0
  snapshotActive = false
  if restoreAction != nil:
    let callback = restoreAction
    restoreAction = nil
    callback()
proc rxMpduDescIndex(p: pointer): int =
  doAssert snapshotActive
  for index in 0 ..< rxDescriptors.len:
    if p == cast[pointer](addr rxDescriptors[index]): return index
  -1
proc rxMpduHeader(p: pointer): ptr RxSwDescView =
  let index = rxMpduDescIndex(p)
  doAssert index >= 0
  inc headerReads
  if rxDescriptors[index].swDesc == cast[pointer](addr rxHeaders[index]):
    return addr rxHeaders[index]
proc rxSwTableDescAt(index: int): ptr RxMpduDescView = addr rxDescriptors[index]
proc hostTxHeadThd(hw: ptr HostTxHwDescView): ptr HostTxThdEntryView =
  doAssert snapshotActive
  inc headReads
  # RV32 pointer tokens keep the production wrapper layout intact on the host.
  if hw.txConfirmDescPtr == 0: return nil
  doAssert hw.txConfirmDescPtr <= txHeads.len.uint32
  addr txHeads[hw.txConfirmDescPtr.int - 1]
proc co_list_cnt(list: ptr CoList): uint32 =
  inc countCalls
  var node = list.first
  while node != nil:
    inc result
    doAssert result <= 41
    node = node.next
{.emit: "#include <stdarg.h>\n#include <stdio.h>".}
proc logger(level: uint32; tag, file: cstring; line: cint; format: cstring)
    {.cdecl, varargs.} =
  doAssert level == 2 and tag == nil and file == expectedFile
  doAssert not snapshotActive and interruptsEnabled == expectedIrq
  doAssert cast[uint](format) > 4096, "missing format string"
  var output: array[192, char]
  var size: cint
  {.emit: ["va_list args; va_start(args, ", format, "); ", size,
    " = vsnprintf((char*)", output, ", sizeof(", output, "), ",
    format, ", args); va_end(args);"].}
  doAssert size >= 0 and size < output.len.cint
  records.add(('l', line, $cast[cstring](addr output[0])))
  if loggerAction != nil: loggerAction(line)
proc printer(format: cstring) {.cdecl, varargs.} =
  doAssert format == cstring(" %p(%08lx)")
  doAssert not snapshotActive and interruptsEnabled == expectedIrq
  var output: array[96, char]
  var size: cint
  {.emit: ["va_list args; va_start(args, ", format, "); ", size,
    " = vsnprintf((char*)", output, ", sizeof(", output, "), ",
    format, ", args); va_end(args);"].}
  doAssert size > 0 and size < output.len.cint
  records.add(('p', 0.cint, $cast[cstring](addr output[0])))
  if printerAction != nil: printerAction()
proc blOpsFunc(offset: int): pointer =
  case offset
  of 204: (if logEnabled: cast[pointer](logger) else: nil)
  of 4: (if printEnabled: cast[pointer](printer) else: nil)
  else: raiseAssert "unexpected platform slot"
proc getLogFunc(offset: int): pointer = blOpsFunc(offset)
proc snprintf(output: cstring; size: csize_t; format: cstring): cint
  {.importc, header: "<stdio.h>", varargs.}
proc entryText(node: pointer; status: uint32): string =
  var output: array[96, char]
  discard snprintf(cast[cstring](addr output[0]), output.len.csize_t,
                   " %p(%08lx)", node, status.culong)
  $cast[cstring](addr output[0])
proc setup(populated: bool) =
  txQueues = default(typeof(txQueues))
  txDescriptors = default(typeof(txDescriptors))
  txHardware = default(typeof(txHardware))
  txHeads = default(typeof(txHeads))
  rxEnv = default(typeof(rxEnv))
  rxDescriptors = default(typeof(rxDescriptors))
  rxHeaders = default(typeof(rxHeaders))
  records.setLen(0)
  logEnabled = true
  printEnabled = true
  countCalls = 0
  headReads = 0
  headerReads = 0
  interruptsEnabled = true
  expectedIrq = true
  snapshotActive = false
  loggerAction = nil
  printerAction = nil
  restoreAction = nil
  if not populated: return
  var index = 0
  for queue in 0 ..< 5:
    if queue == 0: continue
    txQueues[queue].first = addr txDescriptors[index].link
    for position in 0 ..< queue:
      txDescriptors[index].hwDesc = addr txHardware[index]
      txHardware[index].txConfirmDescPtr = (index + 1).uint32
      txHardware[index].status = 0xDEADBEEF'u32
      txHeads[index].flags = 0x81000000'u32 + index.uint32
      if position + 1 < queue:
        txDescriptors[index].link.next = addr txDescriptors[index + 1].link
      txQueues[queue].last = addr txDescriptors[index].link
      inc index
  rxEnv.queue.first = cast[ptr CoListHdr](addr rxDescriptors[0])
  rxEnv.queue.last = cast[ptr CoListHdr](addr rxDescriptors[^1])
  for index in 0 ..< rxDescriptors.len:
    rxDescriptors[index].swDesc = addr rxHeaders[index]
    rxHeaders[index].hwFlags = 0xF0000000'u32 + index.uint32
    if index + 1 < rxDescriptors.len:
      cast[ptr CoListHdr](addr rxDescriptors[index]).next =
        cast[ptr CoListHdr](addr rxDescriptors[index + 1])
proc expectedTx(): seq[Record] =
  if not logEnabled: return
  result = @[
    ('l', 570.cint, "---------- txl_cfm_dump ----------\r\n"),
    ('l', 572.cint, "txl_cfm_env:\r\n"),
    ('l', 573.cint, "  cfmlist: 5 [AC_BK AC_BE AC_VI AC_VO AC_BEACON]\r\n")]
  for queue in 0 ..< 5:
    var count = 0
    var node = txQueues[queue].first
    while node != nil:
      inc count
      node = node.next
    result.add(('l', 577.cint, "    [" & $queue & "] cfmlist cnt " & $count & "\r\n"))
    result.add(('l', 581.cint, "      cfm list:"))
    node = txQueues[queue].first
    while printEnabled and node != nil:
      let desc = hostTxDescAt(node)
      var status = 0'u32
      if desc.hwDesc != nil:
        let token = hostTxHwDescAt(desc.hwDesc).txConfirmDescPtr
        if token != 0: status = txHeads[token.int - 1].flags
      result.add(('p', 0.cint, entryText(node, status)))
      node = node.next
    result.add(('l', 589.cint, "\r\n"))
proc expectedRxNodes(nodes: openArray[int]): seq[Record] =
  if not logEnabled: return
  result = @[
    ('l', 763.cint, "---------- rxl_cntrl_dump --------\r\n"),
    ('l', 766.cint, "  ready list:" & $nodes.len & "\r\n")]
  for index in nodes:
    let header = rxDescriptors[index].swDesc
    let status = if header == cast[pointer](addr rxHeaders[index]):
                   rxHeaders[index].hwFlags else: 0'u32
    result.add(('l', 770.cint, entryText(addr rxDescriptors[index], status)))
  result.add(('l', 774.cint, "\r\n"))
proc expectedRx(): seq[Record] =
  var nodes: seq[int]
  if rxEnv.queue.first != nil:
    for index in 0 ..< rxDescriptors.len: nodes.add(index)
  expectedRxNodes(nodes)
'''


CASES = {
    "arguments": r'''
for populated in [false, true]:
  setup(populated)
  expectedFile = "txl_cfm.c"
  let wantedTx = expectedTx()
  txl_cfm_dump()
  doAssert records == wantedTx
  doAssert countCalls == 0
  doAssert headReads == (if populated: 10 else: 0)
  setup(populated)
  expectedFile = "rxl_cntrl.c"
  let wantedRx = expectedRx()
  rxl_cntrl_dump()
  doAssert records == wantedRx and countCalls == 0
''',
    "missing_callbacks": r'''
for populated in [false, true]:
  setup(populated)
  expectedFile = "txl_cfm.c"
  logEnabled = false
  txl_cfm_dump()
  doAssert records.len == 0 and countCalls == 0 and headReads == 0
  expectedFile = "rxl_cntrl.c"
  rxl_cntrl_dump()
  doAssert records.len == 0 and countCalls == 0
  setup(populated)
  expectedFile = "txl_cfm.c"
  printEnabled = false
  let wanted = expectedTx()
  txl_cfm_dump()
  doAssert records == wanted and countCalls == 0 and headReads == 0
''',
    "missing_status": r'''
setup(true)
expectedFile = "txl_cfm.c"
txDescriptors[0].hwDesc = nil
txHardware[1].txConfirmDescPtr = 0
let wantedTx = expectedTx()
txl_cfm_dump()
doAssert records == wantedTx
setup(true)
expectedFile = "rxl_cntrl.c"
rxDescriptors[0].swDesc = nil
let wantedRx = expectedRx()
rxl_cntrl_dump()
doAssert records == wantedRx
''',
}


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("case", CASES)
def test_queue_dump_abi(tmp_path: Path, mode: str, case: str) -> None:
    tx = (FW / "tx_layer.nim").read_text()
    rx = (FW / "rx_layer.nim").read_text()
    code = PLATFORM + procedure(tx, "txl_cfm_dump")
    code += procedure(rx, "rxl_cntrl_dump")
    run_program(tmp_path, mode, code + CASES[case])


RX_SNAPSHOT_CASES = {
    "logger_change": r'''
for irq in [false, true]:
  for targetLine in [763.cint, 766.cint, 770.cint, 774.cint]:
    setup(true)
    interruptsEnabled = irq
    expectedIrq = irq
    expectedFile = "rxl_cntrl.c"
    let wanted = expectedRx()
    loggerAction = proc(line: cint) =
      if line == targetLine:
        loggerAction = nil
        rxEnv = default(typeof(rxEnv))
        rxDescriptors = default(typeof(rxDescriptors))
        rxHeaders = default(typeof(rxHeaders))
    rxl_cntrl_dump()
    doAssert records == wanted
    doAssert rxEnv == default(typeof(rxEnv)) and loggerAction == nil
    doAssert interruptsEnabled == irq and not snapshotActive
    doAssert headerReads == 41 and countCalls == 0
''',
    "restore_change": r'''
for irq in [false, true]:
  setup(true)
  interruptsEnabled = irq
  expectedIrq = irq
  expectedFile = "rxl_cntrl.c"
  let wanted = expectedRx()
  restoreAction = proc() =
    rxEnv = default(typeof(rxEnv))
    for desc in rxDescriptors.mitems:
      desc.swDesc = cast[pointer](1)
      cast[ptr CoListHdr](addr desc).next = cast[ptr CoListHdr](1)
  rxl_cntrl_dump()
  doAssert records == wanted and restoreAction == nil
  doAssert interruptsEnabled == irq and not snapshotActive
''',
    "invalid_queue": r'''
for irq in [false, true]:
  for scenario in 0 .. 5:
    setup(true)
    interruptsEnabled = irq
    expectedIrq = irq
    expectedFile = "rxl_cntrl.c"
    var nodes: seq[int]
    case scenario
    of 0:
      rxEnv.queue.first = cast[ptr CoListHdr](1)
    of 1:
      cast[ptr CoListHdr](addr rxDescriptors[0]).next = cast[ptr CoListHdr](1)
      nodes = @[0]
    of 2:
      cast[ptr CoListHdr](addr rxDescriptors[0]).next = cast[ptr CoListHdr](addr rxDescriptors[0])
      nodes = @[0]
    of 3:
      cast[ptr CoListHdr](addr rxDescriptors[1]).next = cast[ptr CoListHdr](addr rxDescriptors[0])
      nodes = @[0, 1]
    of 4:
      rxDescriptors[0].swDesc = cast[pointer](1)
      for index in 0 ..< 41: nodes.add(index)
    else:
      cast[ptr CoListHdr](addr rxDescriptors[40]).next = cast[ptr CoListHdr](addr rxDescriptors[0])
      for index in 0 ..< 41: nodes.add(index)
    let wanted = expectedRxNodes(nodes)
    let before = (rxEnv, rxDescriptors, rxHeaders)
    rxl_cntrl_dump()
    doAssert records == wanted
    doAssert before == (rxEnv, rxDescriptors, rxHeaders)
    doAssert interruptsEnabled == irq and not snapshotActive
''',
}


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("case", RX_SNAPSHOT_CASES)
def test_rx_control_snapshot(tmp_path: Path, mode: str, case: str) -> None:
    rx = (FW / "rx_layer.nim").read_text()
    run_program(tmp_path, mode, PLATFORM + procedure(rx, "rxl_cntrl_dump") +
                RX_SNAPSHOT_CASES[case])


TX_SNAPSHOT_CASES = {
    "callback_change": r'''
for irq in [false, true]:
  for targetLine in [0.cint, 570, 572, 573, 577, 581, 589]:
    setup(true)
    interruptsEnabled = irq
    expectedIrq = irq
    expectedFile = "txl_cfm.c"
    let wanted = expectedTx()
    proc resetTxQueues() =
      txQueues = default(typeof(txQueues))
      txDescriptors = default(typeof(txDescriptors))
      txHardware = default(typeof(txHardware))
      txHeads = default(typeof(txHeads))
    if targetLine == 0:
      printerAction = proc() =
        printerAction = nil
        resetTxQueues()
    else:
      loggerAction = proc(line: cint) =
        if line == targetLine:
          loggerAction = nil
          resetTxQueues()
    txl_cfm_dump()
    doAssert records == wanted
    doAssert txQueues == default(typeof(txQueues))
    doAssert loggerAction == nil and printerAction == nil
    doAssert interruptsEnabled == irq and not snapshotActive
''',
    "restore_change": r'''
for irq in [false, true]:
  setup(true)
  interruptsEnabled = irq
  expectedIrq = irq
  expectedFile = "txl_cfm.c"
  let wanted = expectedTx()
  restoreAction = proc() =
    txQueues = default(typeof(txQueues))
    for desc in txDescriptors.mitems:
      desc.hwDesc = cast[pointer](1)
      desc.link.next = cast[ptr CoListHdr](1)
  txl_cfm_dump()
  doAssert records == wanted and restoreAction == nil
  doAssert interruptsEnabled == irq and not snapshotActive
''',
    "cycles_and_capacity": r'''
for irq in [false, true]:
  for scenario in 0 .. 3:
    setup(true)
    interruptsEnabled = irq
    expectedIrq = irq
    expectedFile = "txl_cfm.c"
    if scenario == 2:
      txQueues = default(typeof(txQueues))
      txQueues[0].first = addr txDescriptors[0].link
      txQueues[0].last = addr txDescriptors[^1].link
      for index in 0 ..< txDescriptors.len:
        txDescriptors[index].link.next =
          if index + 1 < txDescriptors.len: addr txDescriptors[index + 1].link
          else: nil
    elif scenario == 3:
      txQueues[4] = default(CoList)
    let wanted = expectedTx()
    case scenario
    of 0: txDescriptors[0].link.next = addr txDescriptors[0].link
    of 1: txDescriptors[9].link.next = addr txDescriptors[6].link
    of 2: txDescriptors[9].link.next = addr txDescriptors[0].link
    else: txQueues[4].first = addr txDescriptors[0].link
    let before = (txQueues, txDescriptors, txHardware, txHeads)
    txl_cfm_dump()
    doAssert records == wanted
    doAssert before == (txQueues, txDescriptors, txHardware, txHeads)
    doAssert interruptsEnabled == irq and not snapshotActive
''',
}


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("case", TX_SNAPSHOT_CASES)
def test_tx_confirmation_snapshot(tmp_path: Path, mode: str, case: str) -> None:
    tx = (FW / "tx_layer.nim").read_text()
    run_program(tmp_path, mode, PLATFORM + procedure(tx, "txl_cfm_dump") +
                TX_SNAPSHOT_CASES[case])
