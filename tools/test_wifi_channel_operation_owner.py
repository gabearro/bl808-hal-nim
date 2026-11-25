"""Keep reused channel slots separate from older switch/completion callbacks."""

from pathlib import Path
import re

import pytest

from test_wifi_auth_frames import layouts
from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


PLATFORM = r'''
const
  MAX_CHAN_CTXT = 3
  MACHW_TIMLO_REG = 0x24B00120'u
type
  Header = object
    next: pointer
  Context = object
    hdr: Header
    channel: ChanCtxtDefView
    status, contextIndexOrMarker, invalidMarker: uint8
    opSlot: uint16
  Environment = object
    activeList: tuple[first: pointer]
    currentCtxt, scheduledCtxt, dominantCtxt: pointer
    flags, ctxtCount, switchPending, scanDelayCount, connlessDelayCount, surveySnapshot: uint8
    lastMacTime: uint32
var
  contexts: array[5, Context]
  chanCtxtEpochs: array[5, uint32]
  env: Environment
  scan: ChanScanPoolOverlay
  roc: ChanRocOverlay
  ps: tuple[statusFlags: uint32]
  txResetEpoch: uint32
  interrupts, incomingIrq: bool
  chanScanPending: bool
  nimFwDbgChanScanChanMeta, nimFwDbgChanScanChanFreq: uint32
  actions: seq[string]
  onPower, onNotify, onRetire, onClock, onForce, onCancel: proc()
  onTrace: proc()
  traceCalls: int
proc irqSave(): uint32 =
  result = interrupts.uint32 * 8
  interrupts = false
proc irqRestore(saved: uint32) = interrupts = (saved and 8) != 0
proc chanEnvView(): ptr Environment = addr env
proc chanCtxtForIdx(index: uint8): ptr Context = addr contexts[index]
proc chanCtxtAt(p: pointer): ptr Context = cast[ptr Context](p)
proc psEnvView(): ptr typeof(ps) = addr ps
proc invoke(hook: var proc()) =
  if hook != nil:
    let action = hook
    hook = nil
    action()
proc chan_switch_start(p: pointer) =
  doAssert interrupts == incomingIrq
  actions.add("switch")
proc chan_goto_idle_cb() = actions.add("goto")
proc chanProtectionCancel(p: pointer): pointer = nil
proc chan_get_dominant_chan(): pointer = env.dominantCtxt
proc chan_get_next_chan(): pointer = addr contexts[1]
proc blmac_pwr_mgt_setf(value: uint32) =
  doAssert interrupts == incomingIrq
  actions.add("pm")
  invoke(onPower)
proc regRead(address: uint): uint32 =
  doAssert address == MACHW_TIMLO_REG
  actions.add("clock")
  invoke(onClock)
  10240
const MM_SCAN_CHANNEL_END_IND = 77'u16
proc scanDwellPublish(id: uint16; slot: uint32) =
  doAssert interrupts == incomingIrq and id == 77 and slot == chanCtxtEpochs[3]
  actions.add("message")
  invoke(onNotify)
proc chanSwitchRetire(p: pointer) =
  doAssert interrupts == incomingIrq
  actions.add("retire")
  if env.scheduledCtxt == p: env.scheduledCtxt = nil
  invoke(onRetire)
proc chan_conn_less_delay_prog() = actions.add("delay")
proc chan_cde_evt(p: pointer) = actions.add("cde")
proc mm_force_idle_req(): bool =
  doAssert interrupts == incomingIrq
  actions.add("force")
  inc txResetEpoch # mm_force_idle_req calls txl_reset before returning success.
  invoke(onForce)
  true
proc chanForceIdle(): bool = mm_force_idle_req()
proc mm_back_to_host_idle() = actions.add("host")
proc chanBcnRequestClaim(p: pointer; taskId: uint8): bool = true
proc chanBcnRequestFinish(p: pointer; status: uint8) = discard
proc mmRemainOnChannelReqView(p: pointer): ptr MmRemainOnChannelReqPayload =
  cast[ptr MmRemainOnChannelReqPayload](p)
template chanRocOverlay(): ptr ChanRocOverlay = addr roc
template chanScanPoolOverlay(): ptr ChanScanPoolOverlay = addr scan
proc chanSwitchCancel(p: pointer) =
  actions.add("cancel")
  invoke(onCancel)
proc chanCtxtOpTimer(): pointer = nil
proc mm_timer_clear(p: pointer) = discard
proc assert_err(a, b: cstring; line: cint) = doAssert false
proc nimFwTrace2U32(s: cstring; a, b: uint32) =
  doAssert interrupts == incomingIrq
  inc traceCalls
  if onTrace != nil: onTrace()
proc encodedArgU32(p: pointer): uint32 = cast[uint](p).uint32
proc packChannelMeta(p: ptr ChanCtxtDefView): uint32 = 0
proc packChannelFreq(p: ptr ChanCtxtDefView): uint32 = p.primFreq.uint32
proc c_memcpy(dst, src: pointer; count: csize_t): pointer =
  copyMem(dst, src, count.int)
  dst
proc chan_ctxt_op_evt*(ctxtPtr: pointer) {.exportc, cdecl.}
proc setup(index = 4; irq = true) =
  env = default(Environment)
  contexts = default(typeof(contexts))
  for i in 0 ..< contexts.len:
    contexts[i].contextIndexOrMarker = i.uint8
    contexts[i].channel = ChanCtxtDefView(primFreq: 2412, centerFreq1: 2412)
  contexts[index].status = 4
  env.currentCtxt = addr contexts[index]
  env.activeList.first = addr contexts[0]
  env.ctxtCount = 1
  env.flags = if index == 3: 0x88 else: 0xC4
  scan = ChanScanPoolOverlay(slot: 255)
  roc = ChanRocOverlay(slot: 255)
  chanCtxtEpochs = default(typeof(chanCtxtEpochs))
  txResetEpoch = 0
  ps.statusFlags = 3
  interrupts = irq
  incomingIrq = irq
  actions.setLen(0)
  onPower = nil
  onNotify = nil
  onRetire = nil
  onClock = nil
  onForce = nil
  onCancel = nil
  onTrace = nil
  traceCalls = 0
  chanScanPending = false
'''


def source() -> str:
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    code = layouts("ChanCtxtDefView", "ChanScanPoolOverlay", "ChanScanReqPayload",
                   "ChanRocOverlay", "MmRemainOnChannelReqPayload") + PLATFORM
    code += procedure(kernel, "chanScanDurationTicks")
    code += re.search(r"(?ms)^template chanScanChannel\(.*?(?=^proc )", kernel).group()
    for name in ("chan_scan_req", "chan_roc_req", "chanCtxtOpEvent", "chan_ctxt_op_evt"):
        code += procedure(kernel, name)
    return code


CASES = {
    "slot_creation": r'''
for index in [3, 4]:
  setup(index)
  let original = chanCtxtEpochs[index]
  if index == 3:
    var request = ChanScanReqPayload(prim20Freq: 2412, center1Freq: 2412)
    chan_scan_req(addr request)
  else:
    var request = MmRemainOnChannelReqPayload(channel: contexts[index].channel)
    doAssert chan_roc_req(addr request, 9) == 0
  doAssert chanCtxtEpochs[index] == original + 1
''',
    "completion_replacement": r'''
for index in [3, 4]:
  for irq in [false, true]:
    for boundary in 0 .. 2:
      if index == 4 and boundary == 1: continue
      setup(index, irq)
      var snapshot: tuple[context: Context, environment: Environment]
      var callsAtReplacement: int
      let replace = proc() =
        inc chanCtxtEpochs[index]
        contexts[index].status = 2
        contexts[index].opSlot = 71
        env.flags = 0x94
        env.currentCtxt = addr contexts[index]
        env.scheduledCtxt = addr contexts[1]
        snapshot = (contexts[index], env)
        callsAtReplacement = actions.len
      if boundary == 0: onPower = replace
      elif boundary == 1: onNotify = replace
      else: onRetire = replace
      chan_ctxt_op_evt(addr contexts[index])
      doAssert (contexts[index], env) == snapshot, "old completion changed its replacement"
      doAssert actions.len == callsAtReplacement and interrupts == irq
''',
    "completion_normal": r'''
for index in [3, 4]:
  for irq in [false, true]:
    for count in 0'u8 .. 3'u8:
      setup(index, irq)
      env.ctxtCount = count
      let flags = env.flags
      chan_ctxt_op_evt(addr contexts[index])
      doAssert contexts[index].contextIndexOrMarker == 255 and env.currentCtxt == nil
      doAssert chanCtxtEpochs[index] == 1 and ps.statusFlags == 1
      doAssert env.flags == (flags and (if index == 3: 0xE7'u8 else: 0xAB'u8))
      var expected = @["pm"]
      if index == 3: expected.add("message")
      expected.add("retire")
      if count == 0: expected.add("force"); expected.add("host")
      elif count == 1: expected.add("switch")
      else: expected.add("cde")
      doAssert actions == expected and interrupts == irq
      doAssert txResetEpoch == (count == 0).uint32
''',
    "idle_reset_epoch": r'''
for irq in [false, true]:
  for change in 0 .. 3:
    setup(3, irq)
    env.ctxtCount = 0
    txResetEpoch = high(uint32)
    onForce = proc() =
      doAssert txResetEpoch == 0 # The one expected reset wrapped.
      case change
      of 1: inc txResetEpoch # Another reset during the callback.
      of 2: env.ctxtCount = 1 # A new home channel now needs scheduling.
      of 3: env.scheduledCtxt = addr contexts[1]
      else: discard
    chan_ctxt_op_evt(addr contexts[3])
    var expected = @["pm", "message", "retire", "force"]
    if change == 0: expected.add("host")
    doAssert actions == expected and interrupts == irq
''',
    "clock_and_idle_replacement": r'''
for irq in [false, true]:
  setup(0, irq)
  env.ctxtCount = 2
  contexts[0].opSlot = 20
  onClock = proc() =
    inc chanCtxtEpochs[0]
    contexts[0].status = 2
    contexts[0].opSlot = 77
    env.lastMacTime = 99
  chan_ctxt_op_evt(addr contexts[0])
  doAssert contexts[0].status == 2 and contexts[0].opSlot == 77 and env.lastMacTime == 99
  doAssert actions == @["clock"] and interrupts == irq
  setup(4, irq)
  env.ctxtCount = 0
  onForce = proc() =
    inc chanCtxtEpochs[4]
    contexts[4].contextIndexOrMarker = 4
    contexts[4].status = 2
    env.flags = 0x94
  chan_ctxt_op_evt(addr contexts[4])
  doAssert contexts[4].contextIndexOrMarker == 4 and contexts[4].status == 2 and env.flags == 0x94
  doAssert actions == @["pm", "retire", "force"] and interrupts == irq
''',
    "invalid_identity": r'''
for index in [3, 4]:
  setup(index)
  contexts[index].contextIndexOrMarker = 255
  let before = (contexts, env, ps)
  chan_ctxt_op_evt(addr contexts[index])
  doAssert (contexts, env, ps) == before and actions.len == 0
setup()
chan_ctxt_op_evt(nil)
chan_ctxt_op_evt(cast[pointer](1))
doAssert actions.len == 0 and interrupts
''',
    # Slot 3 is free (its retirement ended any switch to it), so admission
    # has no switch to cancel.
    "scan_admission_cancels_nothing": r'''
setup(3)
let epoch = chanCtxtEpochs[3]
var request = ChanScanReqPayload(duration: 8192, prim20Freq: 2462)
chan_scan_req(addr request)
doAssert actions == @["delay"] and scan.slot == 3 and chanCtxtEpochs[3] == epoch + 1
doAssert (env.flags and 0x02) != 0 and scan.channel.primFreq == 2462
''',
    "same_slot_state_change": r'''
for change in 0 .. 3:
  setup()
  var snapshot: tuple[value: Context, environment: Environment]
  onPower = proc() =
    case change
    of 0: inc txResetEpoch
    of 1: contexts[4].status = 2
    of 2: contexts[4].channel.primFreq = 2462
    else: env.currentCtxt = addr contexts[1]
    snapshot = (contexts[4], env)
  chan_ctxt_op_evt(addr contexts[4])
  doAssert (contexts[4], env) == snapshot and actions == @["pm"]
''',
    "scan_trace_replacement": r'''
for irq in [false, true]:
  for boundary in 1 .. 4:
    setup(3, irq)
    var snapshot: tuple[value: ChanScanPoolOverlay, environment: Environment]
    onTrace = proc() =
      if traceCalls != boundary: return
      inc chanCtxtEpochs[3]
      scan = ChanScanPoolOverlay(slot: 3, durationTicks: 77, requestVifIdx: 1)
      env.flags = 0x94
      snapshot = (scan, env)
    var request = ChanScanReqPayload(duration: 8192, prim20Freq: 2462)
    chan_scan_req(addr request)
    doAssert (scan, env) == snapshot and traceCalls == boundary
    doAssert interrupts == irq and "delay" notin actions
''',
    "completion_exceptions": r'''
for irq in [false, true]:
  for boundary in 0 .. 2:
    setup(4, irq)
    env.ctxtCount = 0
    let fail = proc() = raise newException(ValueError, "completion callback")
    if boundary == 0: onPower = fail
    elif boundary == 1: onRetire = fail
    else: onForce = fail
    var raised = false
    try: chan_ctxt_op_evt(addr contexts[4])
    except ValueError: raised = true
    doAssert raised and interrupts == irq and "host" notin actions
    doAssert chanCtxtEpochs[4] == (if boundary == 2: 1'u32 else: 0'u32)
''',
    "short_scan_control": r'''
proc malloc(size: csize_t): pointer {.importc, header: "<stdlib.h>".}
proc free(p: pointer) {.importc, header: "<stdlib.h>".}
for length in [1, 20]:
  for operation in [1'u8, 2]:
    setup(3)
    contexts[3].status = 0
    let payload = malloc(length.csize_t)
    doAssert payload != nil
    cast[ptr uint8](payload)[] = operation
    chan_scan_req(payload)
    doAssert interrupts and actions.len == 0
    free(payload)
''',
}


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
@pytest.mark.parametrize("case", CASES)
def test_channel_operation_owner(tmp_path: Path, mode: str, case: str) -> None:
    run_program(tmp_path, mode, source() + CASES[case])
