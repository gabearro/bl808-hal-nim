"""Run delayed channel requests through real allocation, publication, and MM."""

from pathlib import Path

import pytest

import test_wifi_channel_update as update
from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import TIM_METADATA_STUBS, run_program


PLATFORM = r'''
{.pragma: wifiCtrl.}
const
  MAX_VIFS = 2
  TASK_MM = 0'u8
  TASK_ME = 3'u8
  VIF_TYPE_AP = 2'u8
  TASK_MAX = 11'u8
  TASK_LAST_EMB = 8'u8
  KeMsgHdrSize = sizeof(KeMsgHdr).uint
  KeMsgTailSlack = 4'u32
  KE_EVT_KE_MESSAGE = 1'u32
  KeMsgNoFree = 1.cint
type
  CoListHdr = KeMsgHdr
  CoList = object
    first, last: ptr CoListHdr
  Vif = object
    vifIdx, vifType: uint8
    chanCtxt, operChan: pointer
    channelFreqPair: uint32
    bss: array[176, uint8]
  KeMsgHandlerDesc = object
    handlers: pointer
    numHandlers: uint32
  TaskDesc = object
    instanceCount: uint8
    stateCount: uint16
    statePtr: ptr uint16
    stateTable, defaultHandler: pointer
var
  vifs: array[MAX_VIFS, Vif]
  rxVifEpochs, chanCtxtLinkEpochs: array[MAX_VIFS, uint32]
  mmBcnGeneration: uint32
  channels: array[MAX_VIFS, ScanChannelEntry]
  keMsgQueueSent, keMsgQueueSaved: CoList
  live: seq[pointer]
  sizes: seq[uint32]
  cached: pointer
  cachedSize: uint32
  heapCalls: int
  failAllocation: bool
  onEvent, onFree, onRead: proc()
  keTaskDescs: array[9, TaskDesc]
  handlerDesc: KeMsgHandlerDesc
  lastResult: cint
proc vifChannelForIdx(index: uint8): ptr Vif = addr vifs[index]
proc chanCtxtAt(p: pointer): ptr Context = cast[ptr Context](p)
proc vifBssInfoBase(v: ptr Vif): pointer = addr v.bss[0]
proc vifBssStatus(v: ptr Vif): ptr VifBssStatusOverlay =
  cast[ptr VifBssStatusOverlay](addr v.bss[128])
proc powerConstraintOutputAt(p: pointer): ptr PowerConstraintOutputOverlay =
  cast[ptr PowerConstraintOutputOverlay](p)
proc macIeAt(p: uint): ptr MacIeView = cast[ptr MacIeView](p)
template macIePayload(p: ptr MacIeView): ptr UncheckedArray[uint8] =
  cast[ptr UncheckedArray[uint8]](cast[uint](p) + 2)
proc tpc_update_vif_tx_power(p, power, index: pointer) =
  vifBssStatus(cast[ptr Vif](p)).phyBandwidth = 2
proc malloc(size: csize_t): pointer {.importc, header: "<stdlib.h>".}
proc free(p: pointer) {.importc, header: "<stdlib.h>".}
proc keMsgPayload(header: ptr KeMsgHdr): pointer =
  cast[pointer](cast[uint](header) + KeMsgHdrSize)
proc heapAlloc(size: uint32): pointer {.cdecl.} =
  inc heapCalls
  if failAllocation: return nil
  doAssert size < 16384
  if cached != nil and cachedSize >= size:
    result = cached
    cached = nil
  else:
    result = malloc(size.csize_t)
  doAssert result != nil
  live.add(result)
  sizes.add(size)
  let bytes = cast[ptr UncheckedArray[uint8]](result)
  for i in 0 ..< size.int: bytes[i] = 0xA5
proc assertNoTag(header: pointer)
proc heapFree(p: pointer) {.cdecl.} =
  assertNoTag(p)
  let index = live.find(p)
  doAssert index >= 0, "double free"
  let size = sizes[index]
  live.delete(index)
  sizes.delete(index)
  if cached == nil:
    cached = p
    cachedSize = size
  else: free(p)
  if onFree != nil: onFree()
proc blOpsFunc(offset: int): pointer =
  case offset
  of 0xB8: cast[pointer](heapAlloc)
  of 0xBC: cast[pointer](heapFree)
  else: nil
template platformFree(p: pointer) = heapFree(p)
proc rxMgtForget(p: pointer) = discard
proc keMsgExternalPayload(p: pointer): pointer = p
proc bl_rx_e2a_handler(p: pointer) = doAssert false
proc nimFwTrace(message: cstring) = discard
proc nimFwTrace2U32(message: cstring; a, b: uint32) = discard
proc nimFwTraceU32(message: cstring; value: uint32) = discard
proc rxMgtMessageCurrent(header: pointer): bool = true
proc keResumeSavedMessagesIfIdle() = discard
proc keUpdateMessageEventAfterSchedule() = discard
proc ke_task_local(task: uint8): bool = task < 9
proc keMsgHandlerDescAt(table: pointer; state: uint16): ptr KeMsgHandlerDesc = addr handlerDesc
proc mm_hw_config_handler*(param: pointer): cint {.exportc, cdecl.}
proc dispatchHandler(param: pointer): cint {.cdecl.} =
  result = mm_hw_config_handler(param)
  lastResult = result
proc ke_handler_search(id: uint16; descriptor: ptr KeMsgHandlerDesc): pointer =
  cast[pointer](dispatchHandler)
proc ke_evt_set(bits: uint32) =
  doAssert bits == KE_EVT_KE_MESSAGE
  if onEvent != nil: onEvent()
proc c_memset(p: pointer; value: cint; size: csize_t): pointer =
  zeroMem(p, size.int)
  p
proc ke_msg_free*(param: pointer) {.exportc, cdecl.}
'''


HELPERS = r'''
proc prepare(irq: bool) =
  doAssert live.len == 0 and keMsgQueueSent.first == nil and keMsgQueueSaved.first == nil
  reset(irq)
  vifs = default(typeof(vifs))
  for index in 0 ..< MAX_VIFS:
    channels[index] = ScanChannelEntry(prim20Freq: 2412, txPower: 17)
    vifs[index] = Vif(vifIdx: index.uint8, chanCtxt: addr contexts[index + 1],
      operChan: addr channels[index], channelFreqPair: 2422)
  rxVifEpochs = default(typeof(rxVifEpochs))
  chanCtxtLinkEpochs = default(typeof(chanCtxtLinkEpochs))
  mmBcnGeneration = 0
  replies = 0
  idleRequests = 0
  mm = default(typeof(mm))
  mmState = 0
  failAllocation = false
  heapCalls = 0
  onEvent = nil
  onFree = nil
  onRead = nil
  handlerDesc = KeMsgHandlerDesc(handlers: cast[pointer](1), numHandlers: 1)
  keTaskDescs[0] = TaskDesc(instanceCount: 1, stateCount: 3,
    statePtr: addr mmState, defaultHandler: addr handlerDesc)
proc issue(index = 1'u8; source = 9'u8): pointer =
  result = ke_msg_alloc(41, TASK_MM, source, MmChanCtxtUpdatePayloadSize)
  doAssert result != nil
  cast[ptr MmChanCtxtUpdatePayload](result)[] = request(index)
  let bytes = cast[ptr UncheckedArray[uint8]](result)
  for i in 12 ..< 16: doAssert bytes[i] == 0xA5
  doAssert keMsgHdrFromPayload(result).paramLen == 12
proc dispatchOne(): cint =
  doAssert keMsgQueueSent.first != nil
  lastResult = KeMsgConsumed
  ke_task_schedule()
  lastResult
proc resumeSaved() =
  mmState = 0
  while keMsgQueueSaved.first != nil:
    co_list_push_back(addr keMsgQueueSent, co_list_pop_front(addr keMsgQueueSaved))
proc finish() =
  while keMsgQueueSent.first != nil: ke_msg_free(co_list_pop_front(addr keMsgQueueSent))
  while keMsgQueueSaved.first != nil: ke_msg_free(co_list_pop_front(addr keMsgQueueSaved))
  doAssert live.len == 0 and interruptsEnabled == incomingIrq
  doAssert chanUpdateTags == nil
  if cached != nil:
    free(cached)
    cached = nil
'''


CASES = {
    "context_reuse": r'''
for irq in [false, true]:
  for saved in [false, true]:
    for replaceSlot in [true, false]:
      prepare(irq)
      let p = issue()
      ke_msg_send(p)
      if saved:
        mmState = 1
        doAssert dispatchOne() == KeMsgSaved
      if replaceSlot: inc chanCtxtEpochs[1]
      else: contexts[1].contextIndexOrMarker = 255
      contexts[1].channel = ChanCtxtDefView(primFreq: 2462, centerFreq1: 2462, txPower: 5)
      let replacement = contexts[1]
      if saved: resumeSaved()
      doAssert dispatchOne() == KeMsgConsumed
      doAssert contexts[1] == replacement, "delayed request changed a replacement context"
      doAssert events.len == 0 and replies == 0
      finish()
''',
    "binding_and_payload": r'''
for irq in [false, true]:
  for change in 0 .. 9:
    prepare(irq)
    let p = issue(source = 3)
    doAssert chanUpdateBindVif(p, 0)
    ke_msg_send(p)
    let before = contexts
    case change
    of 0: inc rxVifEpochs[0]
    of 1: chanCtxtLinkEpochs[0] += 2
    of 2: vifs[0].chanCtxt = addr contexts[2]
    of 3: cast[ptr MmChanCtxtUpdatePayload](p).primFreq = 2462
    of 4: keMsgHdrFromPayload(p).srcId = 9
    of 5: keMsgHdrFromPayload(p).paramLen = 13
    of 6: keMsgHdrFromPayload(p).id = 42
    of 7:
      inc chanCtxtEpochs[1]
      chanUpdateCaptureMessage(keMsgHdrFromPayload(p))
    of 8:
      inc rxVifEpochs[1]
      inc chanCtxtEpochs[2]
    else: discard
    doAssert dispatchOne() == KeMsgConsumed
    if change < 8:
      doAssert contexts == before and replies == 0
    else:
      doAssert contexts[1].channel == definition(request(1)) and replies == 1
    finish()

prepare(true)
let p = issue(source = 3)
doAssert chanUpdateBindVif(p, 0)
inc chanCtxtLinkEpochs[0]
doAssert not chanUpdateBindVif(p, 0), "rebound an old message to the replacement"
ke_msg_send(p)
doAssert dispatchOne() == KeMsgConsumed and replies == 0
finish()
''',
    "cleanup": r'''
for saved in [false, true]:
  prepare(true)
  let p = issue()
  ke_msg_send(p)
  if saved:
    mmState = 1
    doAssert dispatchOne() == KeMsgSaved
  finish()

prepare(true)
let p = issue()
ke_msg_free(keMsgHdrFromPayload(p))
finish()

prepare(true)
let original = issue()
ke_msg_send(original)
var replacement: pointer
onFree = proc() =
  onFree = nil
  replacement = issue(2)
  doAssert replacement == original, "allocator did not reuse the message address"
  ke_msg_send(replacement)
doAssert dispatchOne() == KeMsgConsumed
doAssert replies == 1 and live.len == 1
doAssert dispatchOne() == KeMsgConsumed
doAssert replies == 2 and contexts[2].channel == definition(request(2))
finish()

prepare(true)
doAssert ke_msg_try_alloc(41, TASK_MM, 9, high(uint32)) == nil
doAssert heapCalls == 0 and chanUpdateTags == nil
failAllocation = true
doAssert ke_msg_try_alloc(41, TASK_MM, 9, 12) == nil
doAssert chanUpdateTags == nil
finish()
''',
    "callback_admission": r'''
for irq in [false, true]:
  for stage in 0 .. 2:
    prepare(irq)
    env.currentCtxt = addr contexts[1]
    let p = issue()
    ke_msg_send(p)
    var replacement: Context
    proc replace() =
      inc chanCtxtEpochs[1]
      contexts[1].channel.primFreq = 2462
      replacement = contexts[1]
    case stage
    of 0: onRead = replace
    of 1: onRx = replace
    else: onPhy = replace
    doAssert dispatchOne() == KeMsgConsumed
    doAssert contexts[1] == replacement and replies == 0
    doAssert powerValues.len == 0
    finish()

prepare(true)
let p = issue()
onEvent = proc() =
  inc chanCtxtEpochs[1]
  doAssert dispatchOne() == KeMsgConsumed
ke_msg_send(p)
doAssert replies == 0 and live.len == 0
finish()
''',
    "beacon_producer": r'''
for irq in [false, true]:
  for changeBinding in [false, true]:
    prepare(irq)
    var frame = newSeq[uint8](36)
    frame.add([32'u8, 1, 3])
    if changeBinding:
      onEvent = proc() = chanCtxtLinkEpochs[0] += 2
    let before = contexts
    me_beacon_check(0, frame.len.uint16, addr frame[0])
    doAssert live.len == 1 and keMsgQueueSent.first != nil
    doAssert chanUpdateTags.vifBound and chanUpdateTags.vifIndex == 0
    doAssert dispatchOne() == KeMsgConsumed
    if changeBinding:
      doAssert contexts == before and replies == 0
    else:
      doAssert contexts[1].channel.chanType == 2 and replies == 1
      doAssert contexts[1].channel.primFreq == 2412
    finish()
''',
}


def source() -> str:
    handler = update.HANDLER_PLATFORM.replace("next: pointer", "next: ptr KeMsgHdr")
    handler = handler.replace(procedure(handler, "ke_msg_send"), "")
    handler = handler.replace(procedure(handler, "chanUpdateAdmit"), "")
    handler = handler.replace("  doAssert address == MACHW_STATE_CNTRL_REG\n  0\n",
                              "  doAssert address == MACHW_STATE_CNTRL_REG\n"
                              "  if onRead != nil: onRead()\n  0\n")
    handler = handler.replace("proc regRead", "var onRead: proc()\nproc regRead", 1)
    support = PLATFORM.replace("  onEvent, onFree, onRead: proc()", "  onEvent, onFree: proc()")
    code = (update.layouts("ScanChannelEntry", "VifBssStatusOverlay",
                           "PowerConstraintOutputOverlay", "MacIeView")
            + update.source() + handler + support + TIM_METADATA_STUBS)
    for name in ["chanUpdateStorageLength", "chanUpdateRegister", "chanUpdateCaptureMessage",
                 "chanUpdateForget", "chanUpdateAdmit"]:
        code = code.replace(procedure(code, name), "")
    code += (FW / "channel_update.nim").read_text()
    code += r'''
proc assertNoTag(header: pointer) =
  doAssert chanUpdateTagFor(cast[ptr KeMsgHdr](header)) == nil,
    "metadata remained linked at free"
'''
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    for name in ["co_list_push_back", "co_list_pop_front", "ke_msg_try_alloc", "ke_msg_alloc",
                 "ke_msg_free", "ke_msg_send", "ke_task_schedule"]:
        code += procedure(kernel, name)
    code += procedure((FW / "layout_types.nim").read_text(), "totalLen").split("\n\ntemplate", 1)[0]
    code += procedure((FW / "mac_config_debug.nim").read_text(), "mac_ie_find")
    scan = (FW / "scan_station_ap_me.nim").read_text()
    code += procedure(scan, "me_extract_power_constraint") + procedure(scan, "me_beacon_check")
    body = procedure((FW / "task_handlers.nim").read_text(), "mm_hw_config_handler")
    prefix = body.split("  # Main dispatch on msgId", 1)[0]
    branch = body.split("  of 41:", 1)[1].split("\n  else:", 1)[0]
    tail = body.split("  # Restore local MM state", 1)[1]
    code += (prefix + "  case msgId.int\n  of 41:" + branch
             + "\n  else: doAssert false\n  # Restore local MM state" + tail)
    return code + HELPERS


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("case", CASES)
def test_channel_request_lifetime(tmp_path: Path, mode: str, case: str) -> None:
    run_program(tmp_path, mode, source() + CASES[case])
