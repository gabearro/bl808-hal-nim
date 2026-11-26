"""Keep beacon-triggered channel requests tied to their originating session."""

from pathlib import Path
import re

import pytest

from test_wifi_auth_frames import layouts
from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


PLATFORM = r'''
const
  MAX_VIFS = 2
  MAX_CHAN_CTXT = 3
  STA_INFO_TAB_ENTRIES = 7
  ChanConnLessDelayReqPayloadSize = sizeof(ChanConnLessDelayReqPayload).uint32
type
  Vif = object
    chanCtxt: pointer
    vifIdx, staIdx: uint8
  Context = object
    channel: ChanCtxtDefView
    contextIndexOrMarker: uint8
  Station = object
    valid, instNbr: uint8
    initialRateConfig: uint32
var
  vifs: array[MAX_VIFS, Vif]
  contexts: array[MAX_CHAN_CTXT, Context]
  stations: array[STA_INFO_TAB_ENTRIES, Station]
  rxVifEpochs, chanCtxtLinkEpochs: array[MAX_VIFS, uint32]
  stationEpochs: array[STA_INFO_TAB_ENTRIES, uint32]
  chanCtxtEpochs: array[5, uint32]
  txResetEpoch: uint32
  retiring: array[MAX_VIFS, bool]
  resetting, chanBcnDetectActive, interrupts, incomingIrq: bool
  env: tuple[flags, ctxtCount: uint8]
  request: ChanConnLessDelayReqPayload
  live, sent, freed, allocations: int
  failAllocation, allocationRaises, sendRaises: bool
  onAllocate, onSend, onFree: proc()
  assertionLines: seq[cint]
proc irqSave(): uint32 =
  result = interrupts.uint32 * 8
  interrupts = false
proc irqRestore(saved: uint32) = interrupts = (saved and 8) != 0
proc vifChannelForIdx(index: uint8): ptr Vif = addr vifs[index]
proc vifChannelAt(p: pointer): ptr Vif = cast[ptr Vif](p)
proc chanCtxtForIdx(index: uint8): ptr Context = addr contexts[index]
proc chanCtxtAt(p: pointer): ptr Context = cast[ptr Context](p)
proc staInfoForIdx(index: uint8): ptr Station = addr stations[index]
proc chanEnvView(): ptr typeof(env) = addr env
proc staDeleteEpoch(index: uint8): uint32 =
  if index < STA_INFO_TAB_ENTRIES.uint8: stationEpochs[index] else: 0
proc txlResetting(): bool = resetting
proc txlVifIsRetiring(index: uint8): bool = retiring[index]
proc assert_err(condition, file: cstring; line: cint) = assertionLines.add(line)
proc c_memcpy(dst, src: pointer; count: csize_t): pointer =
  copyMem(dst, src, count.int)
  dst
proc ke_msg_alloc(id: uint16; dest, src: uint8; length: uint32): pointer =
  doAssert interrupts == incomingIrq
  doAssert id == 52 and dest == 0 and src == 0 and length == 20
  inc allocations
  if onAllocate != nil: onAllocate()
  if allocationRaises: raise newException(ValueError, "allocation callback")
  if failAllocation: return nil
  doAssert live == 0
  live = 1
  request = default(ChanConnLessDelayReqPayload)
  addr request
proc ke_msg_free_payload(p: pointer) =
  doAssert interrupts == incomingIrq and p == (addr request) and live == 1
  live = 0
  inc freed
  if onFree != nil: onFree()
proc ke_msg_send(p: pointer) =
  doAssert interrupts == incomingIrq and p == (addr request) and live == 1
  live = 0
  inc sent
  if onSend != nil: onSend()
  if sendRaises: raise newException(ValueError, "publication callback")
proc chanBcnRequestAllocate(identity: MmVifIdentity; lease: ChanCtxtLease;
                          channel: ChanCtxtDefView; interval, resetEpoch: uint32): pointer =
  ke_msg_alloc(52, 0, 0, 20)
proc chanBcnRequestPrune() = discard
proc chanBcnRequestPublish(p: pointer): bool =
  env.flags = env.flags or 0x40
  true
proc setup(irq: bool) =
  vifs = default(typeof(vifs))
  contexts = default(typeof(contexts))
  stations = default(typeof(stations))
  rxVifEpochs = default(typeof(rxVifEpochs))
  chanCtxtLinkEpochs = default(typeof(chanCtxtLinkEpochs))
  chanCtxtEpochs = default(typeof(chanCtxtEpochs))
  stationEpochs = default(typeof(stationEpochs))
  retiring = default(typeof(retiring))
  resetting = false
  chanBcnDetectActive = false
  interrupts = irq
  incomingIrq = irq
  txResetEpoch = 0
  env = (0x80'u8, 2'u8)
  for i in 0 ..< MAX_CHAN_CTXT:
    contexts[i].contextIndexOrMarker = i.uint8
    contexts[i].channel = ChanCtxtDefView(primFreq: (2412 + 5 * i).uint16,
                                         centerFreq1: (2412 + 5 * i).uint16, txPower: 17)
  for i in 0 ..< STA_INFO_TAB_ENTRIES:
    stations[i] = Station(valid: 1, instNbr: i.uint8 mod 2,
                          initialRateConfig: (50000 + 10000 * i).uint32)
  for i in 0 ..< MAX_VIFS:
    vifs[i] = Vif(vifIdx: i.uint8, staIdx: (i + 4).uint8, chanCtxt: addr contexts[i])
  request = default(ChanConnLessDelayReqPayload)
  live = 0
  sent = 0
  freed = 0
  allocations = 0
  failAllocation = false
  allocationRaises = false
  sendRaises = false
  onAllocate = nil
  onSend = nil
  onFree = nil
  assertionLines.setLen(0)
'''


def source() -> str:
    code = layouts("ChanCtxtDefView", "ChanConnLessDelayReqPayload")
    layout = (FW / "layout_types.nim").read_text()
    code += "type\n" + "".join(
        re.search(rf"(?ms)^  {name}\b.*?(?=^  \w|\Z)", layout).group()
        for name in ["MmVifIdentity", "ChanCtxtLease"]
    )
    code += PLATFORM
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    for name in ["mmCaptureVif", "mmVifCurrent", "mmStaOwnerCurrent", "mmStaTimerCurrent", "chanLeaseCurrent",
                 "chan_bcn_detect_start"]:
        code += procedure(kernel, name)
    return code


CASES = {
    "station_timing": r'''
for irq in [false, true]:
  for vifIndex in 0'u8 .. 1'u8:
    for stationIndex in 0'u8 .. 6'u8:
      for interval in [5000'u32, 6000, 102400, 0xFFFFF000'u32]:
        setup(irq)
        vifs[vifIndex].staIdx = stationIndex
        stations[stationIndex].instNbr = vifIndex
        stations[stationIndex].initialRateConfig = interval
        chan_bcn_detect_start(addr vifs[vifIndex])
        doAssert sent == 1 and allocations == 1 and live == 0 and freed == 0
        doAssert request.durationMs == (interval - 5000'u32) div 1000'u32
        doAssert request.band == vifIndex and request.remainingCount == 0
        doAssert equalMem(addr request.chanDef[0], addr contexts[vifIndex].channel, 10)
        doAssert env.flags == 0xC0 and interrupts == irq and not chanBcnDetectActive
''',
    "short_beacon_interval": r'''
for irq in [false, true]:
  for interval in [0'u32, 1'u32, 4999'u32]:
    setup(irq)
    stations[4].initialRateConfig = interval
    chan_bcn_detect_start(addr vifs[0])
    doAssert sent == 0 and allocations == 0 and live == 0
    doAssert env.flags == 0x80 and interrupts == irq and not chanBcnDetectActive
''',
    "allocation_replacement": r'''
for irq in [false, true]:
  for change in 0 .. 13:
    setup(irq)
    onAllocate = proc() =
      case change
      of 0: inc rxVifEpochs[0]
      of 1: inc stationEpochs[4]
      of 2: inc txResetEpoch
      of 3: resetting = true
      of 4: retiring[0] = true
      of 5: stations[4].valid = 0
      of 6: stations[4].instNbr = 1
      of 7: inc chanCtxtLinkEpochs[0]
      of 8: inc chanCtxtEpochs[0]
      of 9: contexts[0].channel.primFreq = 2462
      of 10: env.ctxtCount = 1
      of 11: env.flags = env.flags or 0x40
      of 12: inc stations[4].initialRateConfig
      else: vifs[0].staIdx = 5
    chan_bcn_detect_start(addr vifs[0])
    doAssert allocations == 1 and sent == 0 and freed == 1 and live == 0
    doAssert interrupts == irq and not chanBcnDetectActive
    doAssert env.flags == (if change == 11: 0xC0'u8 else: 0x80'u8)
''',
    "allocation_reentry": r'''
for irq in [false, true]:
  setup(irq)
  var nested = false
  onAllocate = proc() =
    if nested: return
    nested = true
    chan_bcn_detect_start(addr vifs[1])
  chan_bcn_detect_start(addr vifs[0])
  doAssert nested and sent == 1 and allocations == 1 and request.band == 0
  doAssert env.flags == 0xC0 and interrupts == irq and not chanBcnDetectActive
''',
    "publication_order": r'''
for irq in [false, true]:
  for action in 0 .. 2:
    setup(irq)
    onSend = proc() =
      doAssert (env.flags and 0x40) != 0, "pending flag was not visible at publication"
      case action
      of 0: env.flags = env.flags and not 0x40'u8
      of 1:
        inc txResetEpoch
        env.flags = 0x20
      else:
        inc rxVifEpochs[0]
        env.flags = 0x10
    chan_bcn_detect_start(addr vifs[0])
    doAssert env.flags == [0x80'u8, 0x20, 0x10][action]
    doAssert sent == 1 and allocations == 1 and live == 0 and freed == 0
    doAssert interrupts == irq and not chanBcnDetectActive
''',
    "invalid_and_gated": r'''
for irq in [false, true]:
  for gate in 0 .. 11:
    setup(irq)
    var foreign = vifs[0]
    let p = case gate
            of 0: nil
            of 1: cast[pointer](addr foreign)
            else: cast[pointer](addr vifs[0])
    case gate
    of 2: resetting = true
    of 3: retiring[0] = true
    of 4: vifs[0].staIdx = 255
    of 5: stations[4].valid = 0
    of 6: stations[4].instNbr = 1
    of 7: env.flags = env.flags or 0x40
    of 8: env.ctxtCount = 1
    of 9: vifs[0].chanCtxt = nil
    of 10: contexts[0].contextIndexOrMarker = 255
    of 11: vifs[0].chanCtxt = cast[pointer](1)
    else: discard
    let before = (vifs, contexts, stations, env)
    chan_bcn_detect_start(p)
    doAssert allocations == 0 and sent == 0 and live == 0
    doAssert (vifs, contexts, stations, env) == before and interrupts == irq
    doAssert not chanBcnDetectActive
    doAssert assertionLines == (if gate == 9: @[0xC5E.cint] else: newSeq[cint]())
''',
    "callback_exceptions": r'''
for irq in [false, true]:
  for phase in 0 .. 2:
    setup(irq)
    if phase == 0: allocationRaises = true
    elif phase == 1:
      onAllocate = proc() = inc rxVifEpochs[0]
      onFree = proc() = raise newException(ValueError, "free callback")
    else: sendRaises = true
    var raised = false
    try: chan_bcn_detect_start(addr vifs[0])
    except ValueError: raised = true
    doAssert raised and interrupts == irq and not chanBcnDetectActive and live == 0
    doAssert sent == (phase == 2).int and freed == (phase == 1).int
    doAssert env.flags == (if phase == 2: 0xC0'u8 else: 0x80'u8)
    onAllocate = nil
    onFree = nil
    allocationRaises = false
    sendRaises = false
    if phase != 2:
      chan_bcn_detect_start(addr vifs[0])
      doAssert sent == 1, "exception left the producer permanently active"
''',
    "allocation_failure": r'''
for irq in [false, true]:
  setup(irq)
  failAllocation = true
  chan_bcn_detect_start(addr vifs[0])
  doAssert allocations == 1 and sent == 0 and freed == 0 and live == 0
  doAssert env.flags == 0x80 and interrupts == irq and not chanBcnDetectActive
  failAllocation = false
  chan_bcn_detect_start(addr vifs[0])
  doAssert sent == 1 and allocations == 2 and env.flags == 0xC0
''',
}


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
@pytest.mark.parametrize("case", CASES)
def test_beacon_channel_request(tmp_path: Path, mode: str, case: str) -> None:
    run_program(tmp_path, mode, source() + CASES[case])


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_real_queue_publication(tmp_path: Path, mode: str) -> None:
    code = source().replace("var\n  vifs:", r'''
  KeMsgHdr = object
    next: ptr KeMsgHdr
    id: uint16
    destId, srcId: uint8
    paramLen: uint32
  CoListHdr = KeMsgHdr
  CoList = object
    first, last: ptr CoListHdr
  BeaconMessage = object
    header: KeMsgHdr
    payload: ChanConnLessDelayReqPayload
var
  vifs:''', 1)
    code = code.replace("  request: ChanConnLessDelayReqPayload\n", "  message: BeaconMessage\n", 1)
    code = code.replace("proc irqSave(): uint32 =", "template request: untyped = message.payload\nproc irqSave(): uint32 =", 1)
    code = code.replace("  live = 1\n", "  live = 1\n  message.header = KeMsgHdr(id: id, destId: dest, srcId: src, paramLen: length)\n", 1)
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    support = r'''
const
  TASK_MAX = 10'u8
  TASK_LAST_EMB = 8'u8
  KE_EVT_KE_MESSAGE = 0x08000000'u32
var keMsgQueueSent: CoList
proc keMsgHdrFromPayload(p: pointer): ptr KeMsgHdr =
  cast[ptr KeMsgHdr](cast[uint](p) - sizeof(KeMsgHdr).uint)
proc keMsgExternalPayload(p: pointer): pointer = p
proc bl_rx_e2a_handler(p: pointer) = doAssert false
proc blOpsFunc(offset: int): pointer = nil
proc ke_msg_free(p: pointer) = doAssert false
proc nimFwTrace(s: cstring) = discard
proc nimFwTrace2U32(s: cstring; a, b: uint32) = discard
proc ke_evt_set(bits: uint32) =
  doAssert not interrupts and bits == KE_EVT_KE_MESSAGE
  doAssert keMsgQueueSent.first == (addr message.header)
  doAssert (env.flags and 0x40) != 0, "queue notification preceded the pending state"
  keMsgQueueSent = default(CoList)
  live = 0
  inc sent
  if onSend != nil: onSend()
  if sendRaises: raise newException(ValueError, "notifier callback")
'''
    for name in ("mmTimCaptureMessage", "smDisconnectStamp", "chanUpdateCaptureMessage",
                 "mmTimForget", "rxMgtForget",
                 "chanUpdateForget", "smRspTimerForget",
                 "smDisconnectForget", "chanBcnRequestForget"):
        support += f"proc {name}(p: pointer) = discard\n"
    support += procedure(kernel, "co_list_push_back")
    code = code.replace(procedure(code, "ke_msg_send"), support + procedure(kernel, "ke_msg_send"), 1)
    run_program(tmp_path, mode, code + r'''
for irq in [false, true]:
  for failure in [false, true]:
    setup(irq)
    sendRaises = failure
    onSend = proc() = env.flags = env.flags and not 0x40'u8
    var raised = false
    try: chan_bcn_detect_start(addr vifs[0])
    except ValueError: raised = true
    doAssert raised == failure
    doAssert allocations == 1 and sent == 1 and freed == 0 and live == 0
    doAssert env.flags == 0x80 and keMsgQueueSent.first == nil
    doAssert interrupts == irq and not chanBcnDetectActive
''')
