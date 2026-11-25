"""Compare channel-context update side effects with the vendor routine."""

from pathlib import Path

import pytest

from test_wifi_auth_frames import layouts
from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


PLATFORM = r'''
const MAX_CHAN_CTXT = 3
type
  Context = object
    channel: ChanCtxtDefView
    contextIndexOrMarker: uint8
  Env = object
    currentCtxt: pointer
  Event = tuple[name: string, irq: bool]
var
  env: Env
  contexts: array[MAX_CHAN_CTXT, Context]
  chanCtxtEpochs: array[MAX_CHAN_CTXT, uint32]
  events: seq[Event]
  phyChannels: seq[ChanCtxtDefView]
  powerValues: seq[uint8]
  interruptsEnabled, incomingIrq: bool
  onTimer, onRx, onPhy: proc()
proc chanEnvView(): ptr Env = addr env
proc chanCtxtForIdx(index: uint8): ptr Context =
  doAssert index < MAX_CHAN_CTXT
  addr contexts[index]
proc irqSave(): uint32 =
  result = if interruptsEnabled: 8'u32 else: 0'u32
  interruptsEnabled = false
proc irqRestore(saved: uint32) = interruptsEnabled = (saved and 8) != 0
proc c_memcpy(dst, src: pointer; size: csize_t): pointer =
  copyMem(dst, src, size.int)
  dst
proc chan_send_scanning_stop(p: pointer) =
  events.add(("scan-stop", interruptsEnabled))
proc rxl_timer_int_handler() =
  events.add(("timer", interruptsEnabled))
  if onTimer != nil: onTimer()
proc rxl_cntrl_evt() =
  events.add(("rx", interruptsEnabled))
  if onRx != nil: onRx()
proc phySetChannel(channel: ptr ChanCtxtDefView) =
  events.add(("phy", interruptsEnabled))
  phyChannels.add(channel[])
  if onPhy != nil: onPhy()
proc tpc_update_tx_power(power: uint8) =
  events.add(("power", interruptsEnabled))
  powerValues.add(power)
proc reset(irq: bool) =
  env = default(Env)
  contexts = default(typeof(contexts))
  for index in 0 ..< MAX_CHAN_CTXT:
    contexts[index].contextIndexOrMarker = index.uint8
    contexts[index].channel = ChanCtxtDefView(band: 0, primFreq: 2412,
      centerFreq1: 2412, txPower: 17)
  chanCtxtEpochs = default(typeof(chanCtxtEpochs))
  events.setLen(0)
  phyChannels.setLen(0)
  powerValues.setLen(0)
  incomingIrq = irq
  interruptsEnabled = irq
  onTimer = nil
  onRx = nil
  onPhy = nil
proc request(index: uint8): MmChanCtxtUpdatePayload =
  MmChanCtxtUpdatePayload(ctxtIdx: index, band: 1, secChan: 2,
    primFreq: 5180, centerFreq1: 5210, centerFreq2: 5530,
    txPower: 9, txPowerTailPadding: 0xA5)
proc definition(req: MmChanCtxtUpdatePayload): ChanCtxtDefView =
  ChanCtxtDefView(band: req.band, chanType: req.secChan,
    primFreq: req.primFreq, centerFreq1: req.centerFreq1,
    centerFreq2: req.centerFreq2, txPower: req.txPower,
    phyEnvFlags: req.txPowerTailPadding)
'''


CASES = {
    "inactive": r'''
for irq in [false, true]:
  for index in 0'u8 .. 2:
    for noCurrent in [false, true]:
      reset(irq)
      if not noCurrent: env.currentCtxt = addr contexts[(index + 1) mod 3]
      let before = env
      var req = request(index)
      chan_ctxt_update(addr req)
      doAssert contexts[index].channel == definition(req)
      doAssert env == before, "updating an inactive context selected it"
      doAssert events.len == 0, "inactive context changed RX or global TX power"
      doAssert interruptsEnabled == irq
''',
    "active": r'''
for irq in [false, true]:
  for index in 0'u8 .. 2:
    reset(irq)
    env.currentCtxt = addr contexts[index]
    let before = env
    var req = request(index)
    let expected = definition(req)
    chan_ctxt_update(addr req)
    doAssert contexts[index].channel == expected and env == before
    doAssert events == @[("timer", false), ("rx", false),
      ("phy", irq), ("power", irq)], "channel update call order/IRQ differs"
    doAssert phyChannels == @[expected] and powerValues == @[req.txPower]
    doAssert interruptsEnabled == irq

for irq in [false, true]:
  reset(irq)
  env.currentCtxt = addr contexts[0]
  var req = request(0)
  onRx = proc() = contexts[0].channel.txPower = 5
  chan_ctxt_update(addr req)
  doAssert events == @[("timer", false), ("rx", false),
    ("phy", irq), ("power", irq)]
  doAssert powerValues == @[5'u8], "discarded the updated channel power limit"
  doAssert interruptsEnabled == irq
''',
    "replacement": r'''
for irq in [false, true]:
  for stage in 0 .. 2:
    for replaceSlot in [false, true]:
      reset(irq)
      env.currentCtxt = addr contexts[1]
      var req = request(1)
      var replacement: Context
      proc replace() =
        if replaceSlot:
          inc chanCtxtEpochs[1]
          contexts[1].channel.primFreq = 2462
          contexts[1].channel.centerFreq1 = 2462
        else:
          env.currentCtxt = addr contexts[2]
        replacement = contexts[1]
      case stage
      of 0: onTimer = replace
      of 1: onRx = replace
      else: onPhy = replace
      chan_ctxt_update(addr req)
      doAssert contexts[1] == replacement
      doAssert env.currentCtxt == (if replaceSlot: cast[pointer](addr contexts[1])
                                  else: cast[pointer](addr contexts[2]))
      doAssert events.len == stage + 1
      doAssert powerValues.len == 0
      doAssert interruptsEnabled == irq

# A newer update to this same allocation also supersedes the outer operation.
for irq in [false, true]:
  reset(irq)
  env.currentCtxt = addr contexts[0]
  var req = request(0)
  onRx = proc() =
    contexts[0].channel.centerFreq1 = 5290
  chan_ctxt_update(addr req)
  doAssert events == @[("timer", false), ("rx", false)]
  doAssert contexts[0].channel.centerFreq1 == 5290
  doAssert interruptsEnabled == irq
''',
    "invalid": r'''
for irq in [false, true]:
  reset(irq)
  let before = contexts
  chan_ctxt_update(nil)
  for index in [3'u8, 255]:
    var req = request(index)
    chan_ctxt_update(addr req)
  doAssert contexts == before and events.len == 0
  contexts[1].contextIndexOrMarker = 255
  let retired = contexts
  var req = request(1)
  chan_ctxt_update(addr req)
  doAssert contexts == retired and events.len == 0
  doAssert interruptsEnabled == irq
''',
}


def source() -> str:
    return (layouts("ChanCtxtDefView", "MmChanCtxtUpdatePayload") + PLATFORM
            + procedure((FW / "kernel_mac_channel.nim").read_text(), "chan_ctxt_update"))


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("case", CASES)
def test_channel_update(tmp_path: Path, mode: str, case: str) -> None:
    run_program(tmp_path, mode, source() + CASES[case])


HANDLER_PLATFORM = r'''
const MM_SET_EDCA_REQ = 22'u16
const MmSetEdcaReqPayloadSize = 8'u32
var mmEdcaRefresh: tuple[message: pointer]
const
  KeMsgConsumed = 0.cint
  KeMsgSaved = 2.cint
  TaskIdleState = 0'u16
  MM_IDLE = TaskIdleState
  TaskGoingIdleState = 2'u16
  MM_GOING_TO_IDLE = TaskGoingIdleState
  MM_HOST_BYPASSED = 3'u8
  MM_REMOVE_IF_REQ = 8'u16
  MM_SET_VIF_STATE_REQ = 24'u16
  MM_CHAN_CTXT_UPDATE_REQ = 41'u16
  MM_CHAN_CTXT_UPDATE_CFM = 42'u16
  MmChanCtxtUpdatePayloadSize = sizeof(MmChanCtxtUpdatePayload).uint32
  MACHW_STATE_CNTRL_REG = 0x24B00038'u
type
  KeMsgHdr {.packed.} = object
    next: pointer
    id: uint16
    destId, srcId: uint8
    paramLen: uint32
  Packet = object
    header: KeMsgHdr
    payload: MmChanCtxtUpdatePayload
  MmRemoveIfReqPayload = object
    vifIdx: uint8
  MmSetVifStateReqPayload {.packed.} = object
    aid: uint16
    state, vifIdx: uint8
var
  mm: tuple[hardwareMode, previousState: uint8]
  mmState: uint16
  rxl: tuple[processingFlag: uint8]
  replies, idleRequests: int
proc keMsgHdrFromPayload(p: pointer): ptr KeMsgHdr =
  cast[ptr KeMsgHdr](cast[uint](p) - sizeof(KeMsgHdr).uint)
proc smStaleRequest(p: pointer): bool = false
proc chanUpdateAdmit(p: pointer): bool = true
proc apmPrepareVifRemoval(index: uint8): bool = true
proc mmEnvView(): ptr typeof(mm) = addr mm
proc ke_state_get(task: uint8): uint16 = mmState
proc ke_state_set(task: uint8; state: uint16) = mmState = state
var mmConfigTestEvents: uint32
proc ke_evt_field_get(): uint32 = mmConfigTestEvents
const KE_EVT_IDLE = 0x04000000'u32
proc ke_evt_clear(bits: uint32) = doAssert bits == KE_EVT_IDLE
proc regRead(address: uint): uint32 =
  doAssert address == MACHW_STATE_CNTRL_REG
  0
proc regWrite(address: uint; value: uint32) =
  doAssert address == MACHW_STATE_CNTRL_REG and value == 0
proc hal_machw_idle_req() = inc idleRequests
proc rxlCntrlEnvView(): ptr typeof(rxl) = addr rxl
proc assert_err(a, b: cstring; line: int) = doAssert false
proc ke_msg_send_basic_reply(p: pointer; id: uint16) =
  doAssert id == MM_CHAN_CTXT_UPDATE_CFM
  inc replies
proc ke_msg_send(p: pointer) = doAssert false
proc ke_msg_free_payload(p: pointer) = doAssert false
'''


def mm_config_idle_source() -> str:
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    return (kernel[kernel.index("type MmConfigIdlePhase"):kernel.index("proc mmEdcaForget(")]
            + procedure(kernel, "mmConfigResumeIdle")
            + procedure(kernel, "mmConfigResumeAbandonedIdle")
            + procedure(kernel, "mm_hw_idle_evt"))


HANDLER_CHECKS = r'''
for irq in [false, true]:
  for active in [false, true]:
    reset(irq)
    mm = default(typeof(mm))
    mmState = 0
    replies = 0
    idleRequests = 0
    mmConfigIdle = default(typeof(mmConfigIdle))
    if active: env.currentCtxt = addr contexts[1]
    else: env.currentCtxt = addr contexts[2]
    let original = contexts
    var packet = Packet(header: KeMsgHdr(id: 41, destId: 0, srcId: 3),
      payload: request(1))
    for state in [0'u16, 1, 2]:
      for length in 0'u32 ..< MmChanCtxtUpdatePayloadSize:
        mmState = state
        packet.header.paramLen = length
        doAssert mm_hw_config_handler(addr packet.payload) == KeMsgConsumed
        doAssert contexts == original and events.len == 0 and replies == 0
        doAssert mmState == state and idleRequests == 0
    packet.header.paramLen = MmChanCtxtUpdatePayloadSize
    mmState = 1
    doAssert mm_hw_config_handler(addr packet.payload) == KeMsgSaved
    doAssert mmState == TaskGoingIdleState and idleRequests == 1
    doAssert contexts == original and events.len == 0 and replies == 0
    mm_hw_idle_evt()
    doAssert mm_hw_config_handler(addr packet.payload) == KeMsgConsumed
    doAssert contexts[1].channel == definition(packet.payload)
    doAssert env.currentCtxt == (if active: cast[pointer](addr contexts[1])
                               else: cast[pointer](addr contexts[2]))
    doAssert events.len == (if active: 4 else: 0)
    doAssert mmState == 1 and replies == 1
    doAssert interruptsEnabled == irq
'''


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_mm_channel_update_request(tmp_path: Path, mode: str) -> None:
    handler = procedure((FW / "task_handlers.nim").read_text(), "mm_hw_config_handler")
    prefix = handler.split("  # Main dispatch on msgId", 1)[0]
    branch = handler.split("  of 41:", 1)[1].split("\n  else:", 1)[0]
    tail = handler.split("  # Restore local MM state", 1)[1]
    selected = (prefix + "  case msgId.int\n  of 41:" + branch
                + "\n  else: doAssert false\n  # Restore local MM state" + tail)
    run_program(tmp_path, mode, source() + "\nconst TASK_MM = 0'u8\n"
                + HANDLER_PLATFORM + mm_config_idle_source() + selected + HANDLER_CHECKS)
