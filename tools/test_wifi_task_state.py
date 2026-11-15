"""Check task descriptor counts and state-boundary dispatch behavior."""

import json
from pathlib import Path
import re
import shutil
import struct
import subprocess

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


PLATFORM = r'''
type
  CoListHdr = object
    next: ptr CoListHdr
  CoList = object
    first, last: ptr CoListHdr
  KeMsgHdr = object
    next: ptr CoListHdr
    id: uint16
    destId, srcId: uint8
    paramLen: uint32
  RxEnv = object
    processingFlag: uint8
const
  MM_IDLE = 0'u8
  KeMsgConsumed = 0.cint
  KeMsgNoFree = 1.cint
  KeMsgSaved = 2.cint
var
  keTaskDescs: array[10, KeTaskDesc]
  keMsgQueueSent, keMsgQueueSaved: CoList
  mmState: uint8
  rx: RxEnv
  assertions, reschedules, handled, tableReads, frees, eventUpdates: int
  interrupts = true
  active: bool
  onAssert: proc()
  message: KeMsgHdr
  handlerResult: cint
  mm_state_handler: array[4, KeMsgHandlerDesc]
  scanu_state_handler: array[3, KeMsgHandlerDesc]
  mm_default_handler, scan_default_handler, scanu_default_handler: KeMsgHandlerDesc
  me_default_handler, sm_default_handler, apm_default_handler: KeMsgHandlerDesc
  bam_default_handler, cfg_default_handler: KeMsgHandlerDesc
proc assert_err(condition, file: cstring; line: cint) =
  inc assertions
  if onAssert != nil: onAssert()
proc rxlCntrlEnvView(): ptr RxEnv = addr rx
proc ke_reschedule_saved_messages(task: uint8): bool =
  inc reschedules
  false
proc irqSave(): uint32 =
  result = interrupts.uint32 * 8
  interrupts = false
proc irqRestore(saved: uint32) = interrupts = (saved and 8) != 0
proc co_list_pop_front(queue: ptr CoList): ptr CoListHdr =
  result = queue.first
  if result != nil:
    queue.first = result.next
    if queue.first == nil: queue.last = nil
    result.next = nil
proc co_list_push_back(queue: ptr CoList; node: ptr CoListHdr) =
  node.next = nil
  if queue.last == nil: queue.first = node
  else: queue.last.next = node
  queue.last = node
proc keResumeSavedMessagesIfIdle() = discard
proc keUpdateMessageEventAfterSchedule() = inc eventUpdates
proc keMsgPayload(header: ptr KeMsgHdr): pointer =
  cast[pointer](cast[uint](header) + sizeof(KeMsgHdr).uint)
proc ke_msg_free(node: pointer) =
  doAssert node == (addr message) and active
  active = false
  inc frees
proc rxMgtMessageCurrent(node: pointer): bool = true
proc chanUpdateAdmit(request: pointer): bool = true
proc handler(param: pointer): cint {.cdecl.} =
  doAssert active and param == keMsgPayload(addr message)
  inc handled
  handlerResult
proc keMsgHandlerDescAt(table: pointer; state: uint16): ptr KeMsgHandlerDesc =
  inc tableReads
  let count = if table == addr mm_state_handler: 4 else: 3
  doAssert state.int < count, "state lookup exceeded its table"
  addr cast[ptr UncheckedArray[KeMsgHandlerDesc]](table)[state]
proc ke_handler_search(id: uint16; desc: ptr KeMsgHandlerDesc): pointer =
  doAssert desc != nil
  desc.handlers
template nimFwTrace(args: varargs[untyped]) = discard
template nimFwTraceU32(args: varargs[untyped]) = discard
template nimFwTrace2U32(args: varargs[untyped]) = discard
'''


def source() -> str:
    layout = (FW / "layout_types.nim").read_text()
    declarations = []
    for name in ("KeTaskDesc", "KeMsgHandlerDesc"):
        match = re.search(rf"(?m)^  {name}\* = object\n(?:    [^\n]*\n)+", layout)
        assert match, name
        declarations.append(match.group(0))
    dispatch = (FW / "dispatch_tables.nim").read_text()
    code = (FW.parent / "fw_messages/tasks.nim").read_text()
    code += "\ntype\n" + "".join(declarations) + PLATFORM
    code += dispatch[:dispatch.index("# --- KE task dispatch table types ---")]
    code += dispatch[dispatch.index("proc configureKeTaskDesc("):]
    code += procedure((FW / "task_init_main.nim").read_text(), "ke_task_init")
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    for name in ("ke_task_local", "ke_state_set", "ke_state_get", "ke_task_schedule"):
        code += procedure(kernel, name)
    return code + r'''
proc setup() =
  keTaskDescs = default(typeof(keTaskDescs))
  ke_task_init()
  for desc in keTaskDescs.mitems:
    if desc.statePtr != nil: desc.statePtr[] = 0
  assertions = 0
  reschedules = 0
  handled = 0
  tableReads = 0
  frees = 0
  eventUpdates = 0
  interrupts = true
  onAssert = nil
  active = false
  handlerResult = KeMsgConsumed
  keMsgQueueSent = default(CoList)
  keMsgQueueSaved = default(CoList)
  mmState = 7
  rx.processingFlag = 1
  mm_default_handler = KeMsgHandlerDesc(handlers: cast[pointer](handler), numHandlers: 1)
  scanu_default_handler = mm_default_handler
  for entry in mm_state_handler.mitems: entry = default(KeMsgHandlerDesc)
  for entry in scanu_state_handler.mitems: entry = mm_default_handler
proc enqueue(task: uint8) =
  message = KeMsgHdr(id: 0x1234, destId: task, srcId: 3, paramLen: 0)
  active = true
  co_list_push_back(addr keMsgQueueSent, cast[ptr CoListHdr](addr message))
'''


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_descriptor_counts_and_valid_states(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
setup()
let expected = [4'u16, 4, 3, 2, 11, 3, 5, 0, 1, 0]
for task, count in expected:
  let desc = addr keTaskDescs[task]
  let tail = cast[ptr UncheckedArray[uint16]](cast[uint](desc) + 3 * sizeof(pointer).uint)
  doAssert tail[0] == count, "state count must precede instance count"
  doAssert tail[1] == (if count == 0: 0'u16 else: 1'u16)
  if count == 0: continue
  for state in 0'u16 ..< count:
    ke_state_set(task.uint8, state)
    doAssert ke_state_get(task.uint8) == state
doAssert assertions == 0
let previous = reschedules
ke_state_set(TASK_SM, 10)
doAssert reschedules == previous
ke_state_set(TASK_MM, 0)
doAssert mmState == MM_IDLE and rx.processingFlag == 0
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_invalid_state_access_stops_after_diagnostic(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for task in [TASK_MM, TASK_SCANU, TASK_SM]:
  setup()
  let desc = addr keTaskDescs[task]
  desc.statePtr[] = 1
  for state in [desc.stateCount, high(uint16)]:
    let previous = assertions
    ke_state_set(task, state)
    doAssert desc.statePtr[] == 1 and reschedules == 0
    doAssert assertions == previous + 1
  desc.statePtr[] = desc.stateCount
  doAssert ke_state_get(task) == high(uint16)
  doAssert desc.statePtr[] == desc.stateCount
for task in [7'u8, 9'u8, 10'u8, 255'u8]:
  setup()
  ke_state_set(task, 0)
  doAssert ke_state_get(task) == high(uint16)
  doAssert assertions == 2 and reschedules == 0
  doAssert mmState == 7 and rx.processingFlag == 1
setup()
keTaskDescs[TASK_MM].statePtr = nil
ke_state_set(TASK_MM, 0)
doAssert ke_state_get(TASK_MM) == high(uint16)
doAssert assertions == 2 and mmState == 7 and rx.processingFlag == 1
setup()
keTaskDescs[TASK_MM].instanceCount = 0
ke_state_set(TASK_MM, 0)
doAssert ke_state_get(TASK_MM) == high(uint16)
doAssert assertions == 2 and reschedules == 0
doAssert mmState == 7 and rx.processingFlag == 1
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_dispatch_checks_state_before_table_lookup(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for invalid in [0, 1, 2, 3, 4, 5]:
  setup()
  let task = if invalid == 0: 255'u8 elif invalid == 1: 9'u8 else: TASK_MM
  if invalid == 2: keTaskDescs[task].statePtr = nil
  if invalid == 3: keTaskDescs[task].statePtr[] = 4
  if invalid == 4: keTaskDescs[task].stateCount = 0
  if invalid == 5: keTaskDescs[task].instanceCount = 0
  enqueue(task)
  ke_task_schedule()
  doAssert assertions == 1 and frees == 1 and not active
  doAssert handled == 0 and tableReads == 0 and eventUpdates == 1
  doAssert interrupts and keMsgQueueSent.first == nil and keMsgQueueSaved.first == nil
for task in [TASK_MM, TASK_SCANU]:
  for status in [KeMsgConsumed, KeMsgNoFree, KeMsgSaved]:
    setup()
    keTaskDescs[task].statePtr[] = keTaskDescs[task].stateCount - 1
    handlerResult = status
    enqueue(task)
    ke_task_schedule()
    doAssert assertions == 0 and handled == 1 and tableReads == 1
    doAssert eventUpdates == 1 and interrupts
    if status == KeMsgConsumed:
      doAssert frees == 1 and not active
    else:
      doAssert frees == 0 and active
      doAssert (keMsgQueueSaved.first != nil) == (status == KeMsgSaved)
      keMsgQueueSaved = default(CoList)
      ke_msg_free(addr message)
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_diagnostic_reentry_keeps_replacement_state_and_message(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
setup()
onAssert = proc() = keTaskDescs[TASK_MM].statePtr[] = 2
ke_state_set(TASK_MM, 4)
doAssert assertions == 1 and keTaskDescs[TASK_MM].statePtr[] == 2
doAssert reschedules == 0 and mmState == 7 and rx.processingFlag == 1
setup()
keTaskDescs[TASK_MM].statePtr[] = 4
onAssert = proc() =
  doAssert frees == 1 and not active
  active = true
  message = KeMsgHdr(id: 0x4321, destId: TASK_SM, srcId: 1)
enqueue(TASK_MM)
ke_task_schedule()
doAssert assertions == 1 and frees == 1 and active
doAssert message.id == 0x4321 and message.destId == TASK_SM
doAssert handled == 0 and tableReads == 0 and eventUpdates == 1
onAssert = nil
ke_msg_free(addr message)
''')


def test_vendor_task_counts(tmp_path: Path) -> None:
    ar = shutil.which("riscv64-unknown-elf-ar") or shutil.which("ar")
    r2 = shutil.which("r2")
    if ar is None or r2 is None:
        pytest.skip("ar and radare2 are required")
    archive = FW.parents[3] / "tools/ref/libwifi_bl808.a"
    raw = subprocess.check_output([ar, "p", str(archive), "ke_task.o"])
    obj = tmp_path / "ke_task.o"
    obj.write_bytes(raw)
    sections = json.loads(subprocess.check_output([r2, "-q", "-c", "iSj;q", str(obj)], text=True))
    table = next(section for section in sections if section["name"] == ".rodata.TASK_DESC")
    counts = [struct.unpack_from("<HH", raw, table["paddr"] + index * 16 + 12)
              for index in range(table["size"] // 16)]
    assert counts == [(4, 1), (4, 1), (2, 1), (2, 1), (11, 1),
                      (3, 1), (5, 1), (0, 0), (1, 1), (0, 0)]
