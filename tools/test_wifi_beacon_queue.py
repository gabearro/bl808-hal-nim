"""Exercise beacon request ownership through real allocation, queueing, and MM."""

from pathlib import Path

import pytest

from test_wifi_auth_frames import layouts
from test_wifi_beacon_channel_request import source as producer_source
from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import TIM_METADATA_STUBS, run_program


DECLARATIONS = r'''
proc chanBcnRequestAllocate(identity: MmVifIdentity; lease: ChanCtxtLease;
                          channel: ChanCtxtDefView; interval, resetEpoch: uint32): pointer
proc chanBcnRequestPublish(p: pointer): bool
proc chanBcnRequestPrune()
proc chanBcnRequestAdmit(p: pointer): bool
proc chanBcnRequestClaim(p: pointer; taskId: uint8): bool
proc chanBcnRequestFinish(p: pointer; status: uint8)
proc chanBcnRequestForget(header: pointer)
proc chanBcnRequestReset()
'''

SUPPORT = r'''
{.pragma: wifiCtrl.}
type
  KeMsgHdr = object
    next: ptr KeMsgHdr
    id: uint16
    destId, srcId: uint8
    paramLen: uint32
  CoListHdr = KeMsgHdr
  CoList = object
    first, last: ptr CoListHdr
const
  KeMsgHdrSize = sizeof(KeMsgHdr).uint
  KeMsgTailSlack = 4'u32
  TASK_MM = 0'u8
  TASK_MAX = 10'u8
  TASK_LAST_EMB = 8'u8
  KE_EVT_KE_MESSAGE = 0x08000000'u32
  KeMsgConsumed = 0.cint
  MmRemainOnChannelReqPayloadSize = sizeof(MmRemainOnChannelReqPayload).uint32
  MmRemainOnChannelCfmPayloadSize = sizeof(MmRemainOnChannelCfmPayload).uint32
  MM_REMAIN_ON_CHANNEL_CFM = 53'u16
var
  keMsgQueueSent: CoList
  pointers: seq[pointer]
  cached: pointer
  cachedSize, lastSize: uint32
  switches, delays: int
  onSwitch: proc()
  roc: ChanRocOverlay
proc malloc(n: csize_t): pointer {.importc, header: "<stdlib.h>".}
proc free(p: pointer) {.importc, header: "<stdlib.h>".}
proc keMsgPayload(h: ptr KeMsgHdr): pointer = cast[pointer](cast[uint](h) + KeMsgHdrSize)
proc keMsgHdrFromPayload(p: pointer): ptr KeMsgHdr = cast[ptr KeMsgHdr](cast[uint](p) - KeMsgHdrSize)
proc keMsgExternalPayload(p: pointer): pointer = p
proc bl_rx_e2a_handler(p: pointer) = discard
proc nimFwTrace(s: cstring) = discard
proc nimFwTrace2U32(s: cstring; a, b: uint32) = discard
proc heapAlloc(size: uint32): pointer {.cdecl.} =
  doAssert size < 1024
  inc allocations
  if onAllocate != nil: onAllocate()
  if failAllocation: return nil
  if cached != nil and cachedSize >= size:
    result = cached
    cached = nil
  else:
    if cached != nil: free(cached)
    cached = nil
    result = malloc(size.csize_t)
  doAssert result != nil
  lastSize = size
  pointers.add(result)
  live = pointers.len
proc heapFree(p: pointer) {.cdecl.} =
  let index = pointers.find(p)
  doAssert index >= 0, "duplicate or foreign free"
  pointers.delete(index)
  live = pointers.len
  inc freed
  if cached != nil: free(cached)
  cached = p
  cachedSize = lastSize
  if onFree != nil: onFree()
proc blOpsFunc(offset: int): pointer =
  case offset
  of 184: cast[pointer](heapAlloc)
  of 188: cast[pointer](heapFree)
  else: nil
template platformFree(p: pointer) = heapFree(p)
proc c_memset(p: pointer; value: cint; length: csize_t): pointer =
  doAssert value == 0
  zeroMem(p, length.int)
  p
proc ke_evt_set(bits: uint32) =
  doAssert bits == KE_EVT_KE_MESSAGE
  inc sent
  if onSend != nil: onSend()
proc mmRemainOnChannelReqView(p: pointer): ptr MmRemainOnChannelReqPayload =
  cast[ptr MmRemainOnChannelReqPayload](p)
template chanRocOverlay(): ptr ChanRocOverlay = addr roc
proc chan_switch_start(p: pointer) =
  doAssert p == cast[pointer](addr contexts[4])
  doAssert interrupts == incomingIrq
  inc switches
  if onSwitch != nil: onSwitch()
proc chan_conn_less_delay_prog() =
  doAssert interrupts == incomingIrq
  inc delays
proc ke_msg_alloc*(id: uint16; destId, srcId: uint8; paramLen: uint32): pointer {.exportc, cdecl.}
proc ke_msg_send*(param: pointer) {.exportc, cdecl, noinline.}
proc ke_msg_free_payload(param: pointer) {.inline.}
'''


def source() -> str:
    code = producer_source()
    for name in ("ke_msg_alloc", "ke_msg_free_payload", "ke_msg_send",
                 "chanBcnRequestAllocate", "chanBcnRequestPrune", "chanBcnRequestPublish"):
        code = code.replace(procedure(code, name), "", 1)
    code = code.replace("env: tuple[flags, ctxtCount: uint8]", "env: tuple[flags, ctxtCount: uint8, scheduledCtxt: pointer]")
    code = code.replace("env = (0x80'u8, 2'u8)", "env = (0x80'u8, 2'u8, nil)")
    code = code.replace("contexts: array[MAX_CHAN_CTXT, Context]", "contexts: array[5, Context]")
    layout = layouts("MmRemainOnChannelReqPayload", "MmRemainOnChannelCfmPayload", "ChanRocOverlay")
    code = code.replace("proc chan_bcn_detect_start*(", layout + SUPPORT + DECLARATIONS + "proc chan_bcn_detect_start*(", 1)
    stubs = TIM_METADATA_STUBS
    if "proc chanBcnRequestForget(" in stubs:
        stubs = stubs.replace(procedure(stubs, "chanBcnRequestForget"), "")
    code = code.replace("proc chan_bcn_detect_start*(", stubs + "proc rxMgtForget(p: pointer) = discard\nproc chan_bcn_detect_start*(", 1)
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    for name in ("co_list_push_back", "co_list_pop_front", "ke_msg_try_alloc", "ke_msg_alloc",
                 "ke_msg_free", "ke_msg_free_payload", "ke_msg_send"):
        code += procedure(kernel, name)
    metadata = FW / "channel_beacon_request.nim"
    if metadata.exists():
        code += metadata.read_text()
        code += "\nproc tagCount(): int =\n  var tag = chanBcnRequestTags\n  while tag != nil:\n    inc result\n    doAssert result < 10\n    tag = tag.next\n"
    else:
        code += r'''
proc chanBcnRequestAllocate(identity: MmVifIdentity; lease: ChanCtxtLease;
                          channel: ChanCtxtDefView; interval, resetEpoch: uint32): pointer =
  ke_msg_alloc(52, 0, 0, 20)
proc chanBcnRequestPublish(p: pointer): bool = true
proc chanBcnRequestPrune() = discard
proc chanBcnRequestAdmit(p: pointer): bool = true
proc chanBcnRequestClaim(p: pointer; taskId: uint8): bool = true
proc chanBcnRequestFinish(p: pointer; status: uint8) = discard
proc chanBcnRequestForget(header: pointer) = discard
proc chanBcnRequestReset() = discard
proc tagCount(): int = 0
'''
    code += procedure(kernel, "chan_roc_req")
    code += procedure((FW / "task_handlers.nim").read_text(), "mm_remain_on_channel_req_handler")
    return code + r'''
proc prepare(irq = true) =
  doAssert pointers.len == 0 and keMsgQueueSent.first == nil
  setup(irq)
  switches = 0
  delays = 0
  onSwitch = nil
  roc = ChanRocOverlay(slot: 255)
  chanBcnRequestReset()
proc pending(): pointer =
  doAssert keMsgQueueSent.first != nil
  keMsgPayload(keMsgQueueSent.first)
proc dispatch() =
  let header = co_list_pop_front(addr keMsgQueueSent)
  doAssert header != nil
  try: doAssert mm_remain_on_channel_req_handler(keMsgPayload(header)) == KeMsgConsumed
  finally: ke_msg_free(header)
proc finish() =
  onFree = nil
  onSend = nil
  while keMsgQueueSent.first != nil:
    ke_msg_free(co_list_pop_front(addr keMsgQueueSent))
  doAssert pointers.len == 0 and tagCount() == 0
  if cached != nil:
    free(cached)
    cached = nil
'''


CASES = {
    "stale_queue": r'''
for irq in [false, true]:
  for change in 0 .. 10:
    if change == 4: continue # an in-place edit of the context: see below
    prepare(irq)
    chan_bcn_detect_start(addr vifs[0])
    doAssert live == 1 and keMsgHdrFromPayload(pending()).paramLen == 20
    case change
    of 0: inc rxVifEpochs[0]
    of 1: inc stationEpochs[4]
    of 2: inc chanCtxtEpochs[0]
    of 3: inc chanCtxtLinkEpochs[0]
    of 5: retiring[0] = true
    of 6: stations[4].valid = 0
    of 7: inc stations[4].initialRateConfig
    of 8:
      inc txResetEpoch
      env.flags = 0x20
    of 9: env.ctxtCount = 1
    else: env.flags = env.flags and not 0x40'u8
    let before = roc
    dispatch()
    doAssert roc == before and switches == 0 and delays == 0
    doAssert env.flags == (if change == 8: 0x20'u8 else: 0x80'u8)
    doAssert interrupts == irq and live == 0 and freed == 1
    finish()
  # The context is its slot and allocation epoch: a TPC or bandwidth edit
  # does not retire the request (it dwells on the channel it carries).
  prepare(irq)
  chan_bcn_detect_start(addr vifs[0])
  let requested = contexts[0].channel
  contexts[0].channel.txPower = 3
  dispatch()
  doAssert switches == 1 and roc.channel == requested
  doAssert interrupts == irq and live == 0
  finish()
''',
    "valid_and_busy": r'''
for irq in [false, true]:
  for busy in [false, true]:
    prepare(irq)
    chan_bcn_detect_start(addr vifs[1])
    if busy: roc.slot = 4
    dispatch()
    doAssert switches == (not busy).int and delays == 0
    doAssert env.flags == (if busy: 0x80'u8 else: 0xD4'u8)
    if not busy:
      doAssert roc.requestVifIdx == 1 and roc.durationTicks == 92
      doAssert roc.channel == contexts[1].channel
    doAssert interrupts == irq and live == 0
    finish()
''',
    "replacement_pending": r'''
prepare()
chan_bcn_detect_start(addr vifs[0])
inc rxVifEpochs[0]
chan_bcn_detect_start(addr vifs[0])
doAssert allocations == 2 and live == 2
dispatch()
doAssert switches == 0 and env.flags == 0xC0 and live == 1
dispatch()
doAssert switches == 1 and env.flags == 0xD4 and live == 0
finish()
''',
    "discard_reuse": r'''
prepare()
chan_bcn_detect_start(addr vifs[0])
let old = co_list_pop_front(addr keMsgQueueSent)
onFree = proc() =
  onFree = nil
  chan_bcn_detect_start(addr vifs[0])
ke_msg_free(old)
doAssert allocations == 2 and live == 1 and env.flags == 0xC0
doAssert cast[pointer](keMsgQueueSent.first) == cast[pointer](old)
dispatch()
doAssert switches == 1 and live == 0
finish()
''',
    "mutated_request": r'''
for change in 0 .. 8:
  prepare()
  chan_bcn_detect_start(addr vifs[0])
  let p = pending()
  case change
  of 0: mmRemainOnChannelReqView(p).vifIdx = 1
  of 1: mmRemainOnChannelReqView(p).durationMs = 1234
  of 2: keMsgHdrFromPayload(p).srcId = 9
  of 3: keMsgHdrFromPayload(p).paramLen = 19
  of 4: mmRemainOnChannelReqView(p).opCode = 1
  of 5: keMsgHdrFromPayload(p).id = 123
  of 6: mmRemainOnChannelReqView(p).vifIdxDurationPadding = 1
  of 7: mmRemainOnChannelReqView(p).channelTailPadding = 1
  else: mmRemainOnChannelReqView(p).channel.band = 1
  let before = roc
  dispatch()
  doAssert switches == 0 and roc == before and env.flags == 0x80 and live == 0
  finish()
''',
    "publication_and_switch_errors": r'''
for phase in 0 .. 1:
  prepare()
  if phase == 0: onSend = proc() = raise newException(ValueError, "queue callback")
  else: onSwitch = proc() = raise newException(ValueError, "switch callback")
  var raised = false
  try:
    chan_bcn_detect_start(addr vifs[0])
    dispatch()
  except ValueError: raised = true
  doAssert raised and interrupts and not chanBcnDetectActive
  if phase == 0:
    doAssert live == 1 and env.flags == 0xC0
    inc rxVifEpochs[0]
    onSend = nil
    dispatch()
    doAssert switches == 0 and env.flags == 0x80
  else:
    doAssert switches == 1 and live == 0 and env.flags == 0xD4
  finish()
''',
    "admission_recheck": r'''
prepare()
chan_bcn_detect_start(addr vifs[0])
let redirected = pending()
let original = roc
doAssert chan_roc_req(redirected, 9) == 1
doAssert roc == original and delays == 0 and env.flags == 0x80
finish()
prepare()
chan_bcn_detect_start(addr vifs[0])
let p = pending()
doAssert chanBcnRequestAdmit(p)
inc stationEpochs[4]
let before = roc
doAssert chan_roc_req(p, 0) == 1
doAssert roc == before and switches == 0 and env.flags == 0x80
finish()
''',
    "nested_dispatch": r'''
prepare()
chan_bcn_detect_start(addr vifs[0])
let p = pending()
onSwitch = proc() =
  onSwitch = nil
  doAssert mm_remain_on_channel_req_handler(p) == KeMsgConsumed
dispatch()
doAssert switches == 1 and live == 0 and env.flags == 0xD4
finish()
''',
    "reset_and_host_request": r'''
prepare()
chan_bcn_detect_start(addr vifs[0])
chanBcnRequestReset()
env.flags = 0x20
dispatch()
doAssert switches == 0 and live == 0 and env.flags == 0x20
finish()
for irq in [false, true]:
  prepare(irq)
  let p = ke_msg_alloc(52, 0, 9, 20)
  let request = mmRemainOnChannelReqView(p)
  request.durationMs = 10
  request.vifIdx = 1
  request.channel = contexts[1].channel
  doAssert chan_roc_req(p, 9) == 0
  doAssert delays == 1 and switches == 0 and env.flags == 0x81
  doAssert roc.requestVifIdx == 1 and roc.durationTicks == 9 and interrupts == irq
  ke_msg_free_payload(p)
  finish()
''',
    "unpublished_cleanup": r'''
for irq in [false, true]:
  for failed in [false, true]:
    prepare(irq)
    failAllocation = failed
    if not failed: onAllocate = proc() = inc rxVifEpochs[0]
    chan_bcn_detect_start(addr vifs[0])
    doAssert allocations == 1 and sent == 0 and live == 0
    doAssert freed == (not failed).int and tagCount() == 0
    doAssert env.flags == 0x80 and interrupts == irq and not chanBcnDetectActive
    finish()
''',
}


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
@pytest.mark.parametrize("case", CASES)
def test_beacon_queue(tmp_path: Path, mode: str, case: str) -> None:
    run_program(tmp_path, mode, source() + CASES[case])
