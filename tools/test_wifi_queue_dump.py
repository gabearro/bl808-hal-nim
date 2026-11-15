"""Exercise production queue/timer formatting, snapshots, and row-buffer cleanup."""

from pathlib import Path
import re

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


PLATFORM = r'''
import std/strutils
type
  CoListHdr = object
    next: ptr CoListHdr
  CoList = object
    first, last: ptr CoListHdr
var
  messageQueue, keTimerQueue: CoList
  messages: array[3, KeMsgHdr]
  timers: array[3, KeTimerEntry]
  output: seq[string]
  outputIrqs: seq[bool]
  live: seq[pointer]
  sizes: seq[uint32]
  allocs, frees, failAllocAt, failPutAt: int
  missingAlloc, missingFree, missingPuts: bool
  irq: bool
  onAllocate, onOutput: proc()
proc malloc(size: csize_t): pointer {.importc, header: "<stdlib.h>".}
proc free(p: pointer) {.importc, header: "<stdlib.h>".}
proc c_sprintf(p: pointer; format: cstring): cint
    {.importc: "sprintf", header: "<stdio.h>", varargs, discardable.}
proc c_strlen(p: pointer): csize_t {.importc: "strlen", header: "<string.h>".}
proc keMsgPayload(p: ptr KeMsgHdr): pointer = cast[pointer](cast[uint](p) + sizeof(KeMsgHdr).uint)
proc irqSave(): uint32 =
  result = if irq: 8'u32 else: 0'u32
  irq = false
proc irqRestore(saved: uint32) = irq = (saved and 8) != 0
proc putsHook(text: cstring) {.cdecl, raises: [Exception].} =
  doAssert text != nil, "dump passed nil instead of a string"
  output.add($text)
  outputIrqs.add(irq)
  if onOutput != nil: onOutput()
  if output.len == failPutAt: raise newException(ValueError, "output stopped")
proc allocHook(size: uint32): pointer {.cdecl, raises: [Exception].} =
  inc allocs
  sizes.add(size)
  if onAllocate != nil: onAllocate()
  if allocs == failAllocAt: return nil
  result = malloc(size.csize_t)
  doAssert result != nil
  live.add(result)
proc freeHook(p: pointer) {.cdecl.} =
  let index = live.find(p)
  doAssert index >= 0, "line buffer was freed twice or was not allocated"
  live.delete(index)
  inc frees
  free(p)
proc platformFree(p: pointer) = freeHook(p)
proc blOpsFunc(slot: int): pointer =
  case slot
  of 8:
    if missingPuts: nil else: cast[pointer](putsHook)
  of 184:
    if missingAlloc: nil else: cast[pointer](allocHook)
  of 188:
    if missingFree: nil else: cast[pointer](freeHook)
  of 4: nil
  else: raiseAssert "unexpected callback slot"
proc pointerText(p: pointer): string =
  var text: array[32, char]
  c_sprintf(addr text[0], "%p", p)
  $cast[cstring](addr text[0])
proc setup(enabled = true; rows = 3) =
  doAssert live.len == 0
  messageQueue = default(CoList)
  keTimerQueue = default(CoList)
  messages = default(typeof(messages))
  timers = default(typeof(timers))
  for index in 0 ..< rows:
    messages[index] = KeMsgHdr(id: (index * 30000 + 7).uint16,
      destId: (index + 1).uint8, srcId: (index + 3).uint8,
      paramLen: [0'u32, 0x80000000'u32, 0xFFFFFFFF'u32][index])
    timers[index] = KeTimerEntry(id: (index * 30000 + 9).uint16,
      taskId: (index + 5).uint8,
      time: [0'u32, 0x80000000'u32, 0xFFFFFFFF'u32][index])
    if index + 1 < rows:
      messages[index].next = addr messages[index + 1]
      timers[index].next = addr timers[index + 1]
  if rows != 0:
    messageQueue.first = cast[ptr CoListHdr](addr messages[0])
    messageQueue.last = cast[ptr CoListHdr](addr messages[rows - 1])
    keTimerQueue.first = cast[ptr CoListHdr](addr timers[0])
    keTimerQueue.last = cast[ptr CoListHdr](addr timers[rows - 1])
  irq = enabled
  output.setLen(0)
  outputIrqs.setLen(0)
  sizes.setLen(0)
  allocs = 0
  frees = 0
  failAllocAt = -1
  failPutAt = -1
  missingAlloc = false
  missingFree = false
  missingPuts = false
  onAllocate = nil
  onOutput = nil
proc messageText(msg: ptr KeMsgHdr): string =
  ($msg.id).alignLeft(10) & ($msg.destId).alignLeft(10) &
    ($msg.srcId).alignLeft(10) & ($cast[int32](msg.paramLen)).alignLeft(10) &
    pointerText(keMsgPayload(msg)).alignLeft(10)
proc timerText(timer: ptr KeTimerEntry): string =
  ($timer.id).alignLeft(10) & ($timer.taskId).alignLeft(10) &
    ($cast[int32](timer.time)).alignLeft(10)
'''


def source(path: Path | None = None) -> str:
    layout = (FW / "layout_types.nim").read_text()
    types = "type\n"
    for name in ["KeMsgHdr", "KeTimerEntry"]:
        match = re.search(r"(?ms)^  " + name + r"\b.*?(?=^  \w|\Z)", layout)
        assert match, name
        types += match.group(0)
    code = types + PLATFORM
    lists = (FW / "kernel_mac_channel.nim").read_text()
    code += procedure(lists, "co_list_find") + procedure(lists, "co_list_cnt")
    text = (path or FW / "mac_config_debug.nim").read_text()
    if "proc bugkillerPutLine(" in text:
        code += procedure(text, "bugkillerPutLine")
    code += procedure(text, "puts_space")
    code += procedure(text, "bugkiller_fw_queue_dump")
    code += procedure(text, "bugkiller_fw_queue_timer_dump")
    start = text.index("proc dump_ke_task*")
    start = text.index("proc dump_ke_task*", start + 1)
    code += procedure(text[start:], "dump_ke_task")
    return code + r'''
proc runDump(kind: int) =
  case kind
  of 0: bugkiller_fw_queue_dump(addr messageQueue)
  of 1: bugkiller_fw_queue_timer_dump()
  else: dump_ke_task(7, 12345678)
'''


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_vendor_headers_rows_and_signed_values(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for incoming in [false, true]:
  for rows in 0 .. 3:
    setup(incoming, rows)
    var expected = @["msg_id    dest_id   src_id    param_len param     \r\n"]
    for index in 0 ..< rows: expected.add(@[messageText(addr messages[index]), "\r\n"])
    expected.add("\r\n")
    runDump(0)
    doAssert output == expected
    doAssert allocs == rows and frees == rows and live.len == 0
    for size in sizes: doAssert size == 256
    for state in outputIrqs: doAssert state == incoming
    doAssert irq == incoming

    setup(incoming, rows)
    expected = @["[BugKiller] WIFI QUEUE TIMER\r\n", "msg_id    task_id   time      \r\n"]
    for index in 0 ..< rows: expected.add(@[timerText(addr timers[index]), "\r\n"])
    expected.add("\r\n")
    runDump(1)
    doAssert output == expected
    doAssert allocs == rows and frees == rows and live.len == 0
    for size in sizes: doAssert size == 128
    for state in outputIrqs: doAssert state == incoming
    doAssert irq == incoming

  setup(incoming)
  runDump(2)
  doAssert output == @["7         12345678  ", "\r\n"]
  doAssert allocs == 1 and frees == 1 and live.len == 0 and irq == incoming
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_each_output_error_frees_the_current_row(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for incoming in [false, true]:
  for kind in 0 .. 2:
    setup(incoming)
    runDump(kind)
    let outputCount = output.len
    for failAt in 1 .. outputCount:
      setup(incoming)
      failPutAt = failAt
      var raised = false
      try: runDump(kind)
      except ValueError: raised = true
      doAssert raised and output.len == failAt
      doAssert live.len == 0 and frees == allocs,
        "diagnostic error retained an allocated row"
      doAssert irq == incoming
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_missing_callbacks_and_allocation_failures(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for kind in 0 .. 2:
  for missing in 0 .. 2:
    setup()
    case missing
    of 0: missingPuts = true
    of 1: missingAlloc = true
    else: missingFree = true
    runDump(kind)
    doAssert allocs == 0 and frees == 0 and live.len == 0
  for failAt in 1 .. (if kind == 2: 1 else: 3):
    setup()
    failAllocAt = failAt
    runDump(kind)
    doAssert live.len == 0 and allocs - frees == 1
    doAssert irq

  setup()
  onAllocate = proc() = raise newException(ValueError, "allocation stopped")
  var raised = false
  try: runDump(kind)
  except ValueError: raised = true
  doAssert raised and live.len == 0 and frees == 0
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_allocator_can_remove_the_snapshotted_queue(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for kind in 0 .. 1:
  setup()
  var firstMessage, secondMessage: ptr KeMsgHdr
  var firstTimer, secondTimer: ptr KeTimerEntry
  var expected: string
  if kind == 0:
    firstMessage = cast[ptr KeMsgHdr](malloc(sizeof(KeMsgHdr).csize_t))
    secondMessage = cast[ptr KeMsgHdr](malloc(sizeof(KeMsgHdr).csize_t))
    firstMessage[] = KeMsgHdr(next: secondMessage, id: 11, destId: 2, srcId: 3, paramLen: 42)
    secondMessage[] = KeMsgHdr(id: 12)
    messageQueue = CoList(first: cast[ptr CoListHdr](firstMessage), last: cast[ptr CoListHdr](secondMessage))
    expected = messageText(firstMessage)
  else:
    firstTimer = cast[ptr KeTimerEntry](malloc(sizeof(KeTimerEntry).csize_t))
    secondTimer = cast[ptr KeTimerEntry](malloc(sizeof(KeTimerEntry).csize_t))
    firstTimer[] = KeTimerEntry(next: secondTimer, id: 11, taskId: 2, time: 42)
    secondTimer[] = KeTimerEntry(id: 12)
    keTimerQueue = CoList(first: cast[ptr CoListHdr](firstTimer), last: cast[ptr CoListHdr](secondTimer))
    expected = timerText(firstTimer)
  var fired = false
  onAllocate = proc() =
    if fired: return
    fired = true
    if kind == 0:
      messageQueue = default(CoList)
      free(firstMessage)
      free(secondMessage)
    else:
      keTimerQueue = default(CoList)
      free(firstTimer)
      free(secondTimer)
  runDump(kind)
  doAssert fired and allocs == 1 and frees == 1 and live.len == 0
  doAssert expected in output
  doAssert output.len == (if kind == 0: 4 else: 5)
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_new_rows_do_not_extend_the_dump(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for kind in 0 .. 1:
  setup(rows = 1)
  var fired = false
  onOutput = proc() =
    let rowLine = if kind == 0: 2 else: 3
    if fired or output.len != rowLine: return
    fired = true
    if kind == 0:
      messages[0].next = addr messages[1]
      messageQueue.last = cast[ptr CoListHdr](addr messages[1])
    else:
      timers[0].next = addr timers[1]
      keTimerQueue.last = cast[ptr CoListHdr](addr timers[1])
  runDump(kind)
  doAssert fired and allocs == 1 and frees == 1 and live.len == 0 and irq
''')
