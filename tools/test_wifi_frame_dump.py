"""Verify TX pool diagnostics with real C varargs and callback-time changes."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


PLATFORM = r'''
const
  TxlFrameDescCount = 4'u32
  TxlFrameDescSize = 220'u
  InvalidFrameDescIndex = high(uint32)
type
  CoListHdr = object
    next: ptr CoListHdr
  CoList = object
    first, last: ptr CoListHdr
  Env = object
    freeList, usedList: CoList
  Record = tuple[kind: char, line: cint, message: string]
var
  txl_frame_desc_storage: array[4 * 220, uint8]
  env: Env
  records: seq[Record]
  interruptsEnabled, expectedIrq, snapshotActive: bool
  logEnabled = true
  printEnabled = true
  callbackKind = 'l'
  callback, restoreCallback: proc()
proc invoke() =
  if callback != nil:
    let action = callback
    callback = nil
    action()
proc irqSave(): uint32 =
  result = if interruptsEnabled: 8'u32 else: 0'u32
  interruptsEnabled = false
  snapshotActive = true
proc irqRestore(saved: uint32) =
  interruptsEnabled = (saved and 8) != 0
  snapshotActive = false
  if restoreCallback != nil:
    let action = restoreCallback
    restoreCallback = nil
    action()
proc txFrameEnv(): ptr Env = addr env
proc co_list_cnt(list: ptr CoList): uint32 =
  var node = list.first
  while node != nil:
    inc result
    doAssert result <= 8
    node = node.next
{.emit: "#include <stdarg.h>\n#include <stdio.h>".}
proc logger(level: uint32; tag, file: cstring; line: cint; format: cstring)
    {.cdecl, varargs.} =
  doAssert level == 2 and tag == nil and file == cstring("txl_frame.c")
  doAssert cast[uint](format) > 4096, "logger format is not a string pointer"
  doAssert interruptsEnabled == expectedIrq and not snapshotActive
  var output: array[192, char]
  var size: cint
  {.emit: ["va_list args; va_start(args, ", format, "); ", size,
    " = vsnprintf((char*)", output, ", sizeof(", output, "), ",
    format, ", args); va_end(args);"].}
  doAssert size >= 0 and size < output.len.cint
  records.add(('l', line, $cast[cstring](addr output[0])))
  if callbackKind == 'l': invoke()
proc printer(format: cstring) {.cdecl, varargs.} =
  doAssert format == cstring(" %p")
  doAssert interruptsEnabled == expectedIrq and not snapshotActive
  var output: array[64, char]
  var size: cint
  {.emit: ["va_list args; va_start(args, ", format, "); ", size,
    " = vsnprintf((char*)", output, ", sizeof(", output, "), ",
    format, ", args); va_end(args);"].}
  doAssert size > 0 and size < output.len.cint
  records.add(('p', 0.cint, $cast[cstring](addr output[0])))
  if callbackKind == 'p': invoke()
proc blOpsFunc(offset: int): pointer =
  case offset
  of 204: (if logEnabled: cast[pointer](logger) else: nil)
  of 4: (if printEnabled: cast[pointer](printer) else: nil)
  else: raiseAssert "unexpected operation slot"
proc getLogFunc(offset: int): pointer = blOpsFunc(offset)
proc snprintf(output: cstring; size: csize_t; format: cstring): cint
  {.importc, header: "<stdio.h>", varargs.}
proc pointerText(p: pointer): string =
  var output: array[64, char]
  discard snprintf(cast[cstring](addr output[0]), output.len.csize_t, " %p", p)
  $cast[cstring](addr output[0])
proc slot(index: int): ptr CoListHdr =
  cast[ptr CoListHdr](addr txl_frame_desc_storage[index * 220])
proc setup(freeCount: int; irq: bool) =
  zeroMem(addr txl_frame_desc_storage[0], txl_frame_desc_storage.len)
  env = default(Env)
  for index in 0 ..< freeCount:
    slot(index).next = if index + 1 < freeCount: slot(index + 1) else: nil
  for index in freeCount ..< 4:
    slot(index).next = if index + 1 < 4: slot(index + 1) else: nil
  if freeCount > 0: env.freeList = CoList(first: slot(0), last: slot(freeCount - 1))
  if freeCount < 4: env.usedList = CoList(first: slot(freeCount), last: slot(3))
  records.setLen(0)
  interruptsEnabled = irq
  expectedIrq = irq
  snapshotActive = false
  logEnabled = true
  printEnabled = true
  callback = nil
  restoreCallback = nil
  callbackKind = 'l'
proc expected(freeNodes, usedNodes: openArray[pointer]): seq[Record] =
  if not logEnabled: return
  result = @[
    ('l', 1101.cint, "---------- txl_frame_dump ----------\r\n"),
    ('l', 1103.cint, "txl_frame_desc:\r\n"),
    ('l', 1104.cint, "  total: 4\r\n"),
    ('l', 1105.cint, "  list:")]
  if printEnabled:
    for index in 0 ..< 4: result.add(('p', 0.cint, pointerText(slot(index))))
  result.add(('l', 1109.cint, "\r\n"))
  result.add(('l', 1111.cint, "txl_frame_env:\r\n"))
  result.add(('l', 1113.cint, "  desc_free cnt: " & $freeNodes.len & "\r\n"))
  result.add(('l', 1114.cint, "     list:"))
  if printEnabled:
    for node in freeNodes: result.add(('p', 0.cint, pointerText(node)))
  result.add(('l', 1122.cint, "\r\n"))
  result.add(('l', 1123.cint, "  desc_done cnt: " & $usedNodes.len & "\r\n"))
  result.add(('l', 1124.cint, "     list:"))
  for node in usedNodes: result.add(('l', 1128.cint, pointerText(node)))
  result.add(('l', 1132.cint, "\r\n"))
  result.add(('l', 1133.cint, "========== txl_frame_dump End ======\r\n"))
'''


CASES = {
    "arguments": r'''
for irq in [false, true]:
  for count in 0 .. 4:
    for enabled in [false, true]:
      setup(count, irq)
      printEnabled = enabled
      var freeNodes, usedNodes: seq[pointer]
      for index in 0 ..< count: freeNodes.add(slot(index))
      for index in count ..< 4: usedNodes.add(slot(index))
      let wanted = expected(freeNodes, usedNodes)
      let before = txl_frame_desc_storage
      let envBefore = env
      txl_frame_dump()
      doAssert records == wanted
      doAssert txl_frame_desc_storage == before and env == envBefore
      doAssert interruptsEnabled == irq
setup(2, true)
logEnabled = false
txl_frame_dump()
doAssert records.len == 0 and interruptsEnabled
''',
    "callback": r'''
for irq in [false, true]:
  for stage in 0 .. 2:
    setup(2, irq)
    let wanted = expected([cast[pointer](slot(0)), slot(1)],
                          [cast[pointer](slot(2)), slot(3)])
    proc replace() =
      zeroMem(addr txl_frame_desc_storage[0], txl_frame_desc_storage.len)
      env = default(Env)
    if stage == 2: restoreCallback = replace
    else:
      callbackKind = if stage == 1: 'p' else: 'l'
      callback = replace
    txl_frame_dump()
    doAssert records == wanted and env == default(Env)
    doAssert interruptsEnabled == irq
''',
    "invalid_list": r'''
for irq in [false, true]:
  setup(4, irq)
  slot(0).next = slot(0)
  txl_frame_dump()
  doAssert records == expected([cast[pointer](slot(0))], [])
  setup(4, irq)
  slot(0).next = slot(1)
  slot(1).next = slot(0)
  txl_frame_dump()
  doAssert records == expected([cast[pointer](slot(0)), slot(1)], [])
  setup(4, irq)
  slot(0).next = cast[ptr CoListHdr](1)
  txl_frame_dump()
  doAssert records == expected([cast[pointer](slot(0))], [])
  setup(4, irq)
  env.freeList.first = cast[ptr CoListHdr](1)
  txl_frame_dump()
  doAssert records == expected([], [])
  doAssert interruptsEnabled == irq
''',
}


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("case", CASES)
def test_frame_pool_dump(tmp_path: Path, mode: str, case: str) -> None:
    tx = (FW / "tx_layer.nim").read_text()
    code = PLATFORM + procedure(tx, "txl_frame_desc_index")
    code += procedure(tx, "txlFrameDumpNodes")
    code += procedure(tx, "txl_frame_dump")
    run_program(tmp_path, mode, code + CASES[case])
