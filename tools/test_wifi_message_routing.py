"""Consume invalid destinations without forwarding or retaining metadata.

A message delivered to the host is retired by ke_msg_free, like a consumed
internal one, so every owner hook runs on both paths (audit KTX-5)."""

from pathlib import Path

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
var
  storage: array[40, uint64]
  active: bool
  metadata: array[13, bool]  # one per owner hook of ke_msg_free
  keMsgQueueSent: CoList
  frees, deliveries, assertions, events, traces: int
  interrupts = true
  onAssert: proc()
let header = cast[ptr KeMsgHdr](addr storage[0])
const KE_EVT_KE_MESSAGE = 0x08000000'u32
proc payload(): pointer = cast[pointer](cast[uint](header) + sizeof(KeMsgHdr).uint)
proc keMsgHdrFromPayload(p: pointer): ptr KeMsgHdr =
  doAssert p != nil
  doAssert p == payload()
  header
proc keMsgExternalPayload(p: pointer): pointer = cast[pointer](cast[uint](p) - 8)
proc irqSave(): uint32 =
  result = if interrupts: 8'u32 else: 0'u32
  interrupts = false
proc irqRestore(saved: uint32) = interrupts = saved != 0
proc co_list_push_back(queue: ptr CoList; node: ptr CoListHdr) =
  doAssert active and node == cast[ptr CoListHdr](header)
  doAssert not interrupts
  node.next = nil
  if queue.last == nil: queue.first = node
  else: queue.last.next = node
  queue.last = node
proc ke_evt_set(bits: uint32) =
  doAssert bits == KE_EVT_KE_MESSAGE
  inc events
proc bl_rx_e2a_handler(p: pointer) =
  doAssert active and p == keMsgExternalPayload(payload())
  inc deliveries
proc heapFree(p: pointer) {.cdecl.} =
  doAssert p == header and active, "message was released twice"
  for value in metadata: doAssert not value, "message metadata survived release"
  active = false
  inc frees
proc blOpsFunc(offset: int): pointer =
  doAssert offset == 0xBC
  cast[pointer](heapFree)
proc assert_err(condition, file: cstring; line: cint) =
  doAssert line == 127
  inc assertions
  if onAssert != nil: onAssert()
proc nimFwTrace(message: string) = inc traces
proc nimFwTrace2U32(message: string; first, second: uint32) = inc traces
proc mmTimCaptureMessage(p: ptr KeMsgHdr) = discard
proc smAbortCaptureMessage(p: ptr KeMsgHdr) = discard
proc chanUpdateCaptureMessage(p: ptr KeMsgHdr) = discard
# The channel switch's request is static and carries no per-message metadata.
proc chanSwitchForget(p: pointer): bool = false
proc setup(destination: uint8) =
  storage = default(typeof(storage))
  header[] = KeMsgHdr(id: 0x1234, destId: destination, srcId: 3, paramLen: 4)
  active = true
  for value in metadata.mitems: value = true
  keMsgQueueSent = default(CoList)
  frees = 0
  deliveries = 0
  assertions = 0
  events = 0
  traces = 0
  onAssert = nil
'''


def source() -> str:
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    code = (FW.parent / "fw_messages/tasks.nim").read_text() + PLATFORM
    hooks = ["mmTimForget", "rxMgtForget", "smCleanupForget", "smBssForget", "smActivationForget",
             "smDeferredForget", "smAbortForget", "chanUpdateForget", "mmConnLossForget",
             "chanBcnRequestForget"]
    hooks += ["scanDwellForget", "mmEdcaForget"]
    for index, name in enumerate(hooks):
        code += f"\nproc {name}(p: pointer) =\n  doAssert p == header\n  metadata[{index}] = false\n"
    code += f"\nproc mmConfigForgetIdleOwner(p: pointer): bool =\n  doAssert p == header\n  metadata[{len(hooks)}] = false\n"
    start = kernel.index("template platformFree(")
    code += kernel[start:kernel.index("\n\n", start)] + "\n"
    return code + procedure(kernel, "ke_msg_free") + procedure(kernel, "ke_msg_send")


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_invalid_destination_is_consumed(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for destination in [11'u8, 255'u8]:
  setup(destination)
  ke_msg_send(payload())
  doAssert not active and frees == 1 and assertions == 1
  doAssert deliveries == 0 and events == 0 and traces == 0
  doAssert keMsgQueueSent.first == nil and interrupts
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_valid_destination_boundaries(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
for destination in [0'u8, 8'u8, 9'u8, 10'u8]:
  setup(destination)
  ke_msg_send(payload())
  doAssert assertions == 0 and interrupts
  if destination <= TASK_LAST_EMB:
    doAssert active and frees == 0 and events == 1 and deliveries == 0
    doAssert keMsgQueueSent.first == cast[ptr CoListHdr](header)
    keMsgQueueSent = default(CoList)
    ke_msg_free(header)
  else:
    doAssert not active and frees == 1 and events == 0 and deliveries == 1
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_diagnostic_replacement_is_not_forwarded_or_released(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
setup(11)
onAssert = proc() =
  doAssert frees == 1 and not active
  active = true
  header[] = KeMsgHdr(id: 0x4321, destId: 4, srcId: 2, paramLen: 4)
  for value in metadata.mitems: value = true
  cast[ptr uint32](payload())[] = 0xAABBCCDD'u32
ke_msg_send(payload())
doAssert active and frees == 1 and deliveries == 0 and events == 0
doAssert header.id == 0x4321 and header.destId == 4
doAssert cast[ptr uint32](payload())[] == 0xAABBCCDD'u32
for value in metadata: doAssert value
onAssert = nil
ke_msg_free(header)
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_nil_send_has_no_side_effects(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
setup(4)
let before = storage
ke_msg_send(nil)
doAssert storage == before and active
doAssert frees == 0 and assertions == 0 and events == 0 and deliveries == 0
ke_msg_free(header)
''')
