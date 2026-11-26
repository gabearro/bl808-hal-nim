"""Run kernel dispatch with RX management-message generation metadata."""

from pathlib import Path
import re

import pytest

from test_wifi_disconnect_tx import procedure
from test_wifi_message_allocation import TIM_METADATA_STUBS, run_program

ROOT = Path(__file__).resolve().parents[1]
FW = ROOT / "src/bl808/wifi/fw"

PLATFORM = r"""
const
  TASK_RXU = 7'u8
  TASK_SM = 4'u8
  TASK_MAX = 11'u8
  TASK_LAST_EMB = 8'u8
  STA_INFO_TAB_ENTRIES = 7
  MAX_VIFS = 2
  RXU_MGT_IND = 0x1C00'u16
  KE_EVT_KE_MESSAGE = 4'u32
  KeMsgConsumed = 0.cint
  KeMsgNoFree = 1.cint
  KeMsgSaved = 2.cint
  KeMsgTailSlack = 4'u32
type
  CoListHdr = object
    next: ptr CoListHdr
  CoList = object
    first, last: ptr CoListHdr
  KeMsgHdr = object
    next: ptr KeMsgHdr
    id: uint16
    destId, srcId: uint8
    paramLen: uint32
  KeMsgHandlerDesc = object
    handlers: pointer
    numHandlers: uint16
  KeTaskDesc = object
    stateTable, defaultHandler: pointer
    statePtr: ptr uint16
    stateCount, instanceCount: uint16
  RxMgtProtection = enum
    rxMgtProtectionUnknown, rxMgtWithoutProtection, rxMgtVerifiedCcmp, rxMgtVerifiedBip
  RxStationIdentity = object
    epoch: uint32
    vifEpochs: array[MAX_VIFS, uint32]
    keyRevision: uint64
    station, vif: uint8
    captured, associated: bool
    when defined(bl808WifiDiagPeerRxAdmission):
      mgmtProtection: RxMgtProtection
  RxMgtIdentityNode = object
    next: ptr RxMgtIdentityNode
    message: pointer
    identity: RxStationIdentity
  Sta = object
    valid, instNbr: uint8
const KeMsgHdrSize = sizeof(KeMsgHdr).uint
var
  keMsgQueueSent, keMsgQueueSaved: CoList
  keTaskDescs: array[11, KeTaskDesc]
  taskStates: array[11, uint16]
  rxMgtIdentities: ptr RxMgtIdentityNode
  rxStationIdentities: array[41, RxStationIdentity]
  rxUploadEpochs: array[41, uint32]
  rxVifEpochs: array[MAX_VIFS, uint32]
  rxKeyRevision = 1'u64
  stations: array[7, Sta]
  epochs: array[7, uint32]
  frame: uint8
  live: seq[pointer]
  allocationCalls, frees, handled, external, assertions: int
  lastSize: uint32
  handlerResult: cint
  interrupts = true
  events: uint32
  failAlloc: bool
  onAlloc: proc()
  table: KeMsgHandlerDesc
  nimFwDbgSmOrphanDrained: uint32
proc malloc(n: csize_t): pointer {.importc, header: "<stdlib.h>".}
proc free(p: pointer) {.importc, header: "<stdlib.h>".}
proc keMsgPayload(h: ptr KeMsgHdr): pointer = cast[pointer](cast[uint](h) + KeMsgHdrSize)
proc keMsgHdrFromPayload(p: pointer): ptr KeMsgHdr = cast[ptr KeMsgHdr](cast[uint](p) - KeMsgHdrSize)
proc keMsgExternalPayload(p: pointer): pointer = p
proc heapAlloc(n: uint32): pointer {.cdecl.} =
  inc allocationCalls
  lastSize = n
  if onAlloc != nil: onAlloc()
  if failAlloc: return nil
  doAssert n < 32768
  result = malloc(n.csize_t)
  doAssert result != nil
  live.add(result)
proc heapFree(p: pointer) {.cdecl.} =
  var found = -1
  for i, entry in live:
    if entry == p: found = i
  doAssert found >= 0, "double free"
  var node = rxMgtIdentities
  while node != nil:
    doAssert node.message != p, "freed message retained generation metadata"
    node = node.next
  live.delete(found)
  inc frees
  free(p)
proc blOpsFunc(offset: int): pointer =
  case offset
  of 0xB8: cast[pointer](heapAlloc)
  of 0xBC: cast[pointer](heapFree)
  else: nil
template platformFree(p: pointer) = heapFree(p)
proc c_memset(p: pointer; value: cint; n: csize_t): pointer =
  doAssert value == 0
  zeroMem(p, n.int)
  p
proc assert_err(a, b: cstring; line: int) = inc assertions
proc irqSave(): uint32 =
  result = interrupts.uint32 * 8
  interrupts = false
proc irqRestore(saved: uint32) = interrupts = (saved and 8) != 0
proc txlHaltVifQueues(vif: uint8; selected: var uint8): bool = true
proc txl_retire_vif(vif: uint8; selected: uint8) = discard
proc staInfoForIdx(i: uint8): ptr Sta = addr stations[i]
proc staDeleteEpoch(i: uint8): uint32 = epochs[i]
proc rxMpduDescIndex(p: pointer): int = (if p == addr frame: 0 else: -1)
proc co_list_push_back(list: ptr CoList; node: ptr CoListHdr) =
  node.next = nil
  if list.last == nil: list.first = node
  else: list.last.next = node
  list.last = node
proc co_list_pop_front(list: ptr CoList): ptr CoListHdr =
  result = list.first
  if result == nil: return
  list.first = result.next
  if list.first == nil: list.last = nil
  result.next = nil
proc ke_evt_set(mask: uint32) = events = events or mask
proc keResumeSavedMessagesIfIdle() = discard
proc keUpdateMessageEventAfterSchedule() =
  if keMsgQueueSent.first == nil: events = events and not KE_EVT_KE_MESSAGE
proc ke_task_local(task: uint8): bool = task <= TASK_LAST_EMB
proc encodedArgU8(p: pointer): uint8 = cast[uint](p).uint8
proc keMsgHandlerDescAt(table: pointer; state: uint16): ptr KeMsgHandlerDesc =
  cast[ptr KeMsgHandlerDesc](table)
proc handler(p: pointer): cint {.cdecl.} =
  inc handled
  handlerResult
proc ke_handler_search(id: uint16; desc: ptr KeMsgHandlerDesc): pointer = desc.handlers
proc bl_rx_e2a_handler(p: pointer) =
  doAssert keMsgHdrFromPayload(p).paramLen == 68
  inc external
template nimFwTrace(args: varargs[untyped]) = discard
template nimFwTraceU32(args: varargs[untyped]) = discard
template nimFwTrace2U32(args: varargs[untyped]) = discard
proc setup() =
  doAssert live.len == 0 and rxMgtIdentities == nil
  keMsgQueueSent = default(CoList)
  keMsgQueueSaved = default(CoList)
  allocationCalls = 0
  frees = 0
  handled = 0
  external = 0
  assertions = 0
  failAlloc = false
  onAlloc = nil
  interrupts = true
  handlerResult = KeMsgConsumed
  table = KeMsgHandlerDesc(handlers: cast[pointer](handler), numHandlers: 1)
  taskStates = default(typeof(taskStates))
  for index, task in keTaskDescs.mpairs:
    task = KeTaskDesc(defaultHandler: addr table, statePtr: addr taskStates[index],
                      stateCount: 1, instanceCount: 1)
  stations[2] = Sta(valid: 1, instNbr: 0)
  rxStationIdentities[0] = RxStationIdentity(captured: true, associated: true,
    station: 2, vif: 0, epoch: epochs[2], vifEpochs: rxVifEpochs)
"""

PLATFORM += TIM_METADATA_STUBS

CHECKS = r"""
setup()
let old = rxMgtAllocMessage(addr frame, 4, 68)
doAssert old != nil
ke_msg_send(old)
inc epochs[2]
rxStationIdentities[0].epoch = epochs[2]
ke_task_schedule()
doAssert handled == 0, "stale copied management frame reached the handler"
doAssert live.len == 0 and frees == 1 and interrupts

for size in [0'u32, 1, 3, 4, 67, 68, 69, 256, 2304]:
  setup()
  let p = rxMgtAllocMessage(addr frame, 4, size)
  doAssert p != nil and keMsgHdrFromPayload(p).paramLen == size
  doAssert allocationCalls == 1
  doAssert rxMgtIdentities != nil
  doAssert cast[uint](rxMgtIdentities) mod alignof(RxMgtIdentityNode).uint == 0
  doAssert cast[uint](rxMgtIdentities) >= cast[uint](p) + size.uint + KeMsgTailSlack.uint
  doAssert cast[uint](rxMgtIdentities) + sizeof(RxMgtIdentityNode).uint <=
    cast[uint](keMsgHdrFromPayload(p)) + lastSize.uint
  let identity = rxMgtIdentities.identity
  let bytes = cast[ptr UncheckedArray[uint8]](p)
  for i in 0 ..< size.int + 4: bytes[i] = 0xA5
  doAssert rxMgtIdentities.identity == identity
  when declared(rxMgtMessageCurrent):
    doAssert rxMgtMessageCurrent(keMsgHdrFromPayload(p))
  ke_msg_send(p)
  ke_task_schedule()
  doAssert handled == 1 and live.len == 0 and rxMgtIdentities == nil

setup()
let savedMessage = rxMgtAllocMessage(addr frame, 4, 68)
handlerResult = KeMsgSaved
ke_msg_send(savedMessage)
ke_task_schedule()
doAssert handled == 1 and live.len == 1
inc epochs[2]
co_list_push_back(addr keMsgQueueSent, co_list_pop_front(addr keMsgQueueSaved))
ke_task_schedule()
doAssert handled == 1 and live.len == 0

setup()
let forwarded = rxMgtAllocMessage(addr frame, 4, 68)
inc epochs[2]
ke_msg_forward_and_change_id(forwarded, 123, 3, 4)
ke_task_schedule()
doAssert handled == 0 and live.len == 0

setup()
let outbound = rxMgtAllocMessage(addr frame, 9, 68)
ke_msg_send(outbound)
doAssert external == 1 and live.len == 0 and rxMgtIdentities == nil

setup()
let missing = rxMgtAllocMessage(addr frame, 4, 68)
table.handlers = nil
ke_msg_send(missing)
ke_task_schedule()
doAssert live.len == 0 and rxMgtIdentities == nil

setup()
handlerResult = KeMsgNoFree
let retained = rxMgtAllocMessage(addr frame, 4, 68)
ke_msg_send(retained)
ke_task_schedule()
doAssert handled == 1 and live.len == 1 and rxMgtIdentities != nil
ke_msg_free(keMsgHdrFromPayload(retained))
doAssert live.len == 0 and rxMgtIdentities == nil

setup()
var messages: array[3, pointer]
for message in messages.mitems: message = rxMgtAllocMessage(addr frame, 4, 68)
for index in [1, 0, 2]: ke_msg_free(keMsgHdrFromPayload(messages[index]))
doAssert live.len == 0 and rxMgtIdentities == nil and frees == 3

setup()
onAlloc = proc() = inc epochs[2]
doAssert rxMgtAllocMessage(addr frame, 4, 68) == nil
doAssert allocationCalls == 1 and frees == 1 and assertions == 0
doAssert live.len == 0 and rxMgtIdentities == nil

setup()
failAlloc = true
doAssert rxMgtAllocMessage(addr frame, 4, 68) == nil
doAssert allocationCalls == 1 and assertions == 1 and rxMgtIdentities == nil

setup()
for length in [high(uint32), high(uint32) - 1]:
  doAssert rxMgtAllocMessage(addr frame, 4, length) == nil
doAssert rxMgtAllocMessage(cast[pointer](1), 4, 68) == nil
rxStationIdentities[0].captured = false
doAssert rxMgtAllocMessage(addr frame, 4, 68) == nil
doAssert allocationCalls == 0 and assertions == 0 and rxMgtIdentities == nil

setup()
let plain = ke_msg_alloc(123, 4, 4, 2)
ke_msg_send(plain)
ke_task_schedule()
doAssert handled == 1 and live.len == 0 and rxMgtIdentities == nil

"""


VIF_CHECKS = r"""
for vif in 0'u8 .. 1:
  for associated in [false, true]:
    setup()
    stations[2].instNbr = vif
    rxCaptureStation(addr frame, (if associated: 0x02000000'u32 or (10'u32 shl 15) else: 0))
    doAssert rxBindVif(addr frame, vif)
    let p = rxMgtAllocMessage(addr frame, 4, 68)
    doAssert p != nil
    ke_msg_send(p)
    discard rxInvalidateVif(vif)
    doAssert not rxStationCurrent(addr frame)
    ke_task_schedule()
    doAssert handled == 0 and live.len == 0,
      "old management frame survived a VIF/connection generation change"

    # An unrelated VIF change does not discard this interface's frame.
    setup()
    stations[2].instNbr = vif
    rxCaptureStation(addr frame, (if associated: 0x02000000'u32 or (10'u32 shl 15) else: 0))
    doAssert rxBindVif(addr frame, vif)
    ke_msg_send(rxMgtAllocMessage(addr frame, 4, 68))
    discard rxInvalidateVif(vif xor 1)
    ke_task_schedule()
    doAssert handled == 1 and live.len == 0

  # Even without a resolved VIF at harvest, retain both original epochs.
  setup()
  rxCaptureStation(addr frame, 0)
  discard rxInvalidateVif(vif)
  doAssert not rxBindVif(addr frame, vif), "late binding forgot harvest epoch"
  doAssert rxMgtAllocMessage(addr frame, 4, 68) == nil
  doAssert allocationCalls == 0
  rxCaptureStation(addr frame, 0)
  doAssert rxBindVif(addr frame, vif)
  doAssert not rxBindVif(addr frame, vif xor 1), "bound frame changed VIF"
  doAssert rxStationCurrent(addr frame)

  # Resolve the VIF before copying; allocation callbacks cannot refresh it.
  onAlloc = proc() = discard rxInvalidateVif(vif)
  doAssert rxMgtAllocMessage(addr frame, 4, 68) == nil
  doAssert live.len == 0 and rxMgtIdentities == nil

  setup()
  rxCaptureStation(addr frame, 0)
  doAssert rxBindVif(addr frame, vif)
  let saved = rxMgtAllocMessage(addr frame, 4, 68)
  handlerResult = KeMsgSaved
  ke_msg_send(saved)
  ke_task_schedule()
  discard rxInvalidateVif(vif)
  co_list_push_back(addr keMsgQueueSent, co_list_pop_front(addr keMsgQueueSaved))
  ke_task_schedule()
  doAssert handled == 1 and live.len == 0

# Truly unresolved discovery records do not belong to a connection attempt.
setup()
rxCaptureStation(addr frame, 0)
doAssert rxBindVif(addr frame, 255)
let discovery = rxMgtAllocMessage(addr frame, 2, 68)
discard rxInvalidateVif(0)
discard rxInvalidateVif(1)
doAssert rxMgtMessageCurrent(keMsgHdrFromPayload(discovery))
ke_msg_free(keMsgHdrFromPayload(discovery))
let before = rxVifEpochs
discard rxInvalidateVif(255)
doAssert rxVifEpochs == before
doAssert not rxBindVif(cast[pointer](1), 0)
doAssert not rxBindVif(addr frame, 2)

rxVifEpochs[0] = high(uint32)
setup()
discard rxInvalidateVif(0)
doAssert rxVifEpochs[0] == 0 and not rxStationCurrent(addr frame)
interrupts = false
discard rxInvalidateVif(0)
doAssert not interrupts
rxCaptureStation(addr frame, 0)
doAssert rxBindVif(addr frame, 0) and not interrupts
interrupts = true
"""


def run_lifetime(tmp_path: Path, mode: str, checks: str, *, rx_admission: bool = False) -> None:
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    rx = (FW / "rx_layer.nim").read_text()
    source = ("{.define: bl808WifiDiagPeerRxAdmission.}\n" if rx_admission else "") + PLATFORM
    for name in ["ke_msg_try_alloc", "ke_msg_alloc"]:
        source += procedure(kernel, name)
    for name in ["rxInvalidateQuiescentVif", "rxInvalidateVif", "rxUploadGeneration", "rxUploadCurrent", "rxCaptureStation", "rxIdentityCurrent", "rxStationCurrent", "rxBindVif",
                 "rxMgtMessageCurrent", "rxMgtNoteProtection",
                 "rxMgtForget", "rxMgtIdentityAt"]:
        if re.search(rf"^proc {name}\(", rx, re.M):
            source += procedure(rx, name)
    if "proc rxInvalidateVif(" not in rx:
        source += "\nproc rxInvalidateVif(vif: uint8) =\n  if vif < MAX_VIFS: inc rxVifEpochs[vif]\n"
    if "proc rxBindVif(" not in rx:
        source += "\nproc rxBindVif(frame: pointer; vif: uint8): bool =\n  rxStationIdentities[0].vif = vif\n  rxStationCurrent(frame)\n"
    source += procedure(kernel, "ke_msg_free")
    if "proc rxMgtAllocMessage(" in rx:
        source += procedure(rx, "rxMgtAllocMessage")
    else:
        source += "\nproc rxMgtAllocMessage(frame: pointer; dest: uint8; size: uint32): pointer =\n  ke_msg_alloc(RXU_MGT_IND, dest, TASK_RXU, size)\n"
    for name in ["ke_msg_send", "ke_msg_forward_and_change_id", "ke_queue_extract",
                 "cmp_dest_id", "ke_task_schedule"]:
        source += procedure(kernel, name)
    run_program(tmp_path, mode, source + checks)


def test_management_protection_is_owned_by_the_queued_message(tmp_path: Path) -> None:
    run_lifetime(tmp_path, "firmware", r'''
setup()
proc protectionOf(payload: pointer; current = true): RxMgtProtection =
  result = rxMgtVerifiedBip
  doAssert rxMgtMessageCurrent(keMsgHdrFromPayload(payload), addr result) == current

let generation = rxUploadGeneration(addr frame)
rxMgtNoteProtection(addr frame, generation, rxMgtVerifiedCcmp)
let old = rxMgtAllocMessage(addr frame, 4, 68)
doAssert protectionOf(old) == rxMgtVerifiedCcmp

# Recycle the descriptor for a different frame from the same association.
rxCaptureStation(addr frame, 0x02000000'u32 or (10'u32 shl 15))
rxMgtNoteProtection(addr frame, generation, rxMgtVerifiedBip)
let fresh = rxMgtAllocMessage(addr frame, 4, 68)
doAssert protectionOf(fresh) == rxMgtProtectionUnknown
rxMgtNoteProtection(addr frame, rxUploadGeneration(addr frame), rxMgtWithoutProtection)
let next = rxMgtAllocMessage(addr frame, 4, 68)
doAssert protectionOf(next) == rxMgtWithoutProtection
doAssert protectionOf(old) == rxMgtVerifiedCcmp

discard rxInvalidateVif(0)
for p in [old, fresh, next]:
  doAssert protectionOf(p, current = false) == rxMgtProtectionUnknown
  ke_msg_free(keMsgHdrFromPayload(p))
doAssert live.len == 0 and rxMgtIdentities == nil and interrupts
''', rx_admission=True)


def test_management_metadata_aligns_after_rv32_header(tmp_path: Path) -> None:
    run_lifetime(tmp_path, "firmware", r'''
const payload = 0x20000'u + 12
const alignment = alignof(RxMgtIdentityNode).uint
for length in 0'u32 .. 78:
  let start = payload + length.uint + KeMsgTailSlack.uint
  let node = cast[uint](rxMgtIdentityAt(cast[pointer](payload), length))
  doAssert node mod alignment == 0
  doAssert start <= node and node < start + alignment
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_management_message_lifetime(tmp_path: Path, mode: str) -> None:
    run_lifetime(tmp_path, mode, CHECKS)


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_management_vif_lifetime(tmp_path: Path, mode: str) -> None:
    run_lifetime(tmp_path, mode, VIF_CHECKS)
