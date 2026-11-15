"""Check owned force-idle requests before channel-switch callbacks."""

from pathlib import Path
from textwrap import indent

import pytest

from test_wifi_channel_ownership import source as ownership_source
from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


def source() -> str:
    code = ("var mmState: uint16\nvar onMmState, onFree: proc()\nproc chanSwitchForget(header: pointer)\n"
            "proc chanProtectionInvalidate()\n"
            "proc chanProtectionCancel(target: pointer = nil): pointer {.discardable.}\n"
            "proc chanProtectionCallbackCurrent(): bool\n"
            "proc chanProtectionSelectTarget(target: pointer): bool\n" + ownership_source())
    code = code.replace("  elif id == 11:", "  elif id == 74:\n    discard\n  elif id == 11:", 1)
    code = code.replace("  smRegistrationForget(p)\n", "  chanSwitchForget(p)\n  smRegistrationForget(p)\n", 1)
    code = code.replace("  dealloc(p)\n", "  dealloc(p)\n  invoke(onFree)\n", 1)
    code = code.replace("    macAddr, bssid: array[6, uint8]", """    macAddr, bssid: array[6, uint8]
    next, postponedStaHead: pointer
    state: uint8""", 1)
    code = code.replace("    contextIndexOrMarker, invalidMarker, linkCount, status: uint8",
                        "    contextIndexOrMarker, invalidMarker, linkCount, status: uint8\n    schedSlot: uint16", 1)
    code = code.replace("    ctxtCount, flags, schedState: uint8",
                        "    ctxtCount, flags, schedState, switchPending, scanDelayCount, connlessDelayCount: uint8", 1)
    code = code.replace("chan_ctxt_pool: array[MAX_CHAN_CTXT, ChanCtxtView]",
                        "chan_ctxt_pool: array[5, ChanCtxtView]", 1)
    code = code.replace("  for context in chan_ctxt_pool.mitems:\n    markInvalid(addr context)\n    co_list_push_back(addr channelEnv.freeList, chanCtxtHdr(addr context))",
                        "  for index in 0..<MAX_CHAN_CTXT:\n    let context = addr chan_ctxt_pool[index]\n    markInvalid(context)\n    co_list_push_back(addr channelEnv.freeList, chanCtxtHdr(context))", 1)
    code = code.replace(procedure(code, "chanSwitchRetire"),
                        "proc chanSwitchRetire(target: pointer)\n", 1)
    code = code.replace("proc ke_state_get(task: uint8): uint16 =\n",
                        "proc ke_state_get(task: uint8): uint16 =\n  if task == 0: return mmState\n", 1)
    code = code.replace("proc ke_state_set(task: uint8; value: uint16) =\n",
                        "proc ke_state_set(task: uint8; value: uint16) =\n"
                        "  if task == 0:\n    mmState = value\n    invoke(onMmState)\n    return\n", 1)
    code += r'''
const
  MM_FORCE_IDLE_REQ_MSG = 74'u16
  TASK_NONE = 255'u8
  MM_IDLE = 0'u16
  MM_GOING_TO_IDLE = 2'u16
  HW_ACTIVE = 3'u16
  MACHW_STATE_CNTRL_REG = 0x24B00038'u
  VIF_TYPE_AP = 2'u8
var
  ps: tuple[enabled: uint8, statusFlags: uint32]
  mgmt: tuple[activeList: CoList]
  callbacks, forced, idleRequests, timerClears: int
  onIdle, onHal, onRead, onStatus: proc()
proc chan_goto_idle_cb*() {.exportc, cdecl.}
proc keMsgPayload(header: ptr KeMsgHdr): pointer =
  cast[pointer](cast[uint](header) + sizeof(KeMsgHdr).uint)
proc meCancelQueuedPayload(payload: pointer) =
  for index in 0..<queued.len:
    if queued[index] == payload:
      queued.delete(index)
      release(payload)
      return
proc psEnvView(): ptr typeof(ps) = addr ps
proc vifMgmtEnvView(): ptr typeof(mgmt) = addr mgmt
proc mm_force_idle_req(): bool =
  inc forced
  invoke(onIdle)
  true
proc hal_machw_idle_req() =
  inc idleRequests
  invoke(onHal)
proc regRead(address: uint): uint32 =
  doAssert address == MACHW_STATE_CNTRL_REG
  invoke(onRead)
  0
proc mm_active() = discard
proc blmac_pwr_mgt_setf(value: uint32) = discard
proc chan_pre_switch_channel() =
  inc callbacks
  channelEnv.currentCtxt = channelEnv.scheduledCtxt
  channelEnv.scheduledCtxt = nil
proc chan_sta_tx_cfm(p: pointer; status: uint32) {.cdecl.} = discard
proc chan_ap_tx_cfm(p: pointer; status: uint32) {.cdecl.} = discard
proc txl_frame_send_null_frame(index: uint8; callback: pointer; arg: uint32): uint8 = 1
proc txl_frame_send_selfcts_frame(p: pointer; duration: uint16; callback: pointer; arg: uint32): uint8 = 1
proc chan_upd_ctxt_status(p: pointer; status: uint8) =
  chanCtxtAt(p).status = status
  invoke(onStatus)
'''
    code += (FW / "channel_switch.nim").read_text()
    code += (FW / "channel_protection.nim").read_text()
    tasks = (FW / "task_handlers.nim").read_text()
    for name in ["chan_switch_start", "chan_goto_idle_cb", "mm_force_idle_req_handler"]:
        code += procedure(tasks, name)
    return code + r'''
proc resetSwitch() =
  doAssert live.len == 0 and queued.len == 0 and chanSwitchTags == nil
  setup()
  resetChannels()
  mmState = MM_IDLE
  mgmt = default(typeof(mgmt))
  ps = default(typeof(ps))
  callbacks = 0
  forced = 0
  idleRequests = 0
  onIdle = nil
  onHal = nil
  onRead = nil
  onStatus = nil
  onMmState = nil
  onFree = nil
proc newTarget(freq = 2412'u16): pointer =
  var definition = ChanCtxtDefView(primFreq: freq, centerFreq1: freq)
  var index: uint8
  doAssert chan_ctxt_add(addr definition, addr index) == 0
  cast[pointer](chanCtxtForIdx(index))
proc beginSwitch(target: pointer): pointer =
  chan_switch_start(target)
  doAssert queued.len == 1 and channelEnv.scheduledCtxt == target
  take()
proc finishSwitch() =
  chanSwitchCancel()
  while queued.len != 0: release(take())
  doAssert live.len == 0 and chanSwitchTags == nil
'''


CASES = {
    "nested_switch_publication": r'''
for phase in 0..1:
  resetSwitch()
  let original = newTarget()
  let replacement = newTarget(2437)
  let replace = proc() =
    chanSwitchCancel(original)
    chan_switch_start(replacement)
  if phase == 0: onAlloc = replace
  else: onStatus = replace
  chan_switch_start(original)
  doAssert queued.len == 1 and channelEnv.scheduledCtxt == replacement
  let request = take()
  doAssert mm_force_idle_req_handler(request) == KeMsgConsumed
  doAssert callbacks == 1 and channelEnv.currentCtxt == replacement
  release(request)
  finishSwitch()
''',
    "retargeted_callback": r'''
for retireDestination in [false, true]:
  resetSwitch()
  let original = newTarget()
  let destination = newTarget(2437)
  let request = beginSwitch(original)
  onIdle = proc() =
    channelEnv.scheduledCtxt = destination
    doAssert chanSwitchSelectTarget(destination)
    let retired = if retireDestination: destination else: original
    chan_ctxt_del(chanCtxtAt(retired).contextIndexOrMarker)
  doAssert mm_force_idle_req_handler(request) == KeMsgConsumed
  doAssert callbacks == (not retireDestination).int
  if not retireDestination: doAssert channelEnv.currentCtxt == destination
  release(request)
  finishSwitch()
''',
    "cancel_untracked_pending_state": r'''
resetSwitch()
channelEnv.scheduledCtxt = newTarget()
channelEnv.switchPending = 1
channelEnv.scanDelayCount = 1
channelEnv.connlessDelayCount = 1
chanSwitchCancel()
doAssert channelEnv.scheduledCtxt == nil and channelEnv.switchPending == 0
doAssert channelEnv.scanDelayCount == 0 and channelEnv.connlessDelayCount == 0
finishSwitch()
''',
    "callback_generation_change": r'''
for changeSource in [false, true]:
  resetSwitch()
  let source = newTarget()
  let destination = newTarget(2437)
  channelEnv.currentCtxt = source
  let request = beginSwitch(destination)
  onIdle = proc() =
    let changed = if changeSource: source else: destination
    inc chanCtxtEpochs[chanCtxtAt(changed).contextIndexOrMarker]
  doAssert mm_force_idle_req_handler(request) == KeMsgConsumed
  doAssert forced == 1 and callbacks == 0
  doAssert channelEnv.scheduledCtxt == nil and chanSwitchActive == nil
  release(request)
  finishSwitch()
''',
    "retirement_free_reentry": r'''
resetSwitch()
let target = newTarget()
chan_switch_start(target)
var replacement: pointer
var replacementRequest: pointer
onFree = proc() =
  doAssert chanCtxtAt(target).contextIndexOrMarker == 255
  resetChannels()
  replacement = newTarget(2437)
  replacementRequest = beginSwitch(replacement)
  channelEnv.currentCtxt = replacement
chan_ctxt_del(chanCtxtAt(target).contextIndexOrMarker)
doAssert replacement == target and channelEnv.currentCtxt == replacement
doAssert chanCtxtAt(replacement).channel.primFreq == 2437
doAssert chanCtxtAt(replacement).contextIndexOrMarker != 255
doAssert mm_force_idle_req_handler(replacementRequest) == KeMsgConsumed
doAssert callbacks == 1
release(replacementRequest)
finishSwitch()
''',
    "stale_taken_message": r'''
resetSwitch()
let oldTarget = newTarget()
let old = beginSwitch(oldTarget)
chan_ctxt_del(chanCtxtAt(oldTarget).contextIndexOrMarker)
let replacement = newTarget(2437)
let current = beginSwitch(replacement)
doAssert mm_force_idle_req_handler(old) == KeMsgConsumed
doAssert forced == 0 and callbacks == 0 and channelEnv.scheduledCtxt == replacement
release(old)
doAssert mm_force_idle_req_handler(current) == KeMsgConsumed
doAssert forced == 1 and callbacks == 1 and channelEnv.currentCtxt == replacement
release(current)
finishSwitch()
''',
    "queued_and_saved_cancellation": r'''
for savedRequest in [false, true]:
  resetSwitch()
  let target = newTarget()
  let request = beginSwitch(target)
  if savedRequest:
    mmState = 1
    doAssert mm_force_idle_req_handler(request) == KeMsgSaved
    doAssert idleRequests == 1 and mmState == MM_GOING_TO_IDLE
  queued.add(request)
  chan_ctxt_del(chanCtxtAt(target).contextIndexOrMarker)
  doAssert queued.len == 0 and live.len == 0
  doAssert channelEnv.scheduledCtxt == nil and channelEnv.switchPending == 0
  finishSwitch()
''',
    "one_shot_callback": r'''
for initialIrq in [false, true]:
  resetSwitch()
  enabled = initialIrq
  let request = beginSwitch(newTarget())
  doAssert enabled == initialIrq
  doAssert mm_force_idle_req_handler(request) == KeMsgConsumed
  doAssert mm_force_idle_req_handler(request) == KeMsgConsumed
  doAssert forced == 1 and callbacks == 1 and enabled == initialIrq
  release(request)
  finishSwitch()
''',
    "lost_request": r'''
resetSwitch()
let target = newTarget()
let priorStatus = chanCtxtAt(target).status
release(beginSwitch(target))
doAssert channelEnv.scheduledCtxt == nil and channelEnv.switchPending == 0
doAssert chanCtxtAt(target).status == priorStatus
doAssert chanSwitchActive == nil
finishSwitch()
''',
    "preparation_replacement": r'''
for phase in 0..1:
  resetSwitch()
  let target = newTarget()
  let retire = proc() = chan_ctxt_del(chanCtxtAt(target).contextIndexOrMarker)
  if phase == 0: onAlloc = retire
  else: onStatus = retire
  chan_switch_start(target)
  doAssert live.len == 0 and queued.len == 0
  doAssert channelEnv.scheduledCtxt == nil and channelEnv.switchPending == 0
  finishSwitch()
''',
    "handler_replacement": r'''
for phase in 0..2:
  resetSwitch()
  let target = newTarget()
  let request = beginSwitch(target)
  let retire = proc() = chan_ctxt_del(chanCtxtAt(target).contextIndexOrMarker)
  if phase == 0: onRead = retire
  elif phase == 1: onMmState = retire
  else:
    mmState = 1
    onHal = retire
  doAssert mm_force_idle_req_handler(request) == KeMsgConsumed
  doAssert callbacks == 0 and forced == 0
  release(request)
  finishSwitch()
''',
    "callback_replacement": r'''
for retireSource in [false, true]:
  resetSwitch()
  let source = newTarget()
  let target = newTarget(2437)
  channelEnv.currentCtxt = source
  let request = beginSwitch(target)
  onIdle = proc() =
    let retired = if retireSource: source else: target
    chan_ctxt_del(chanCtxtAt(retired).contextIndexOrMarker)
  doAssert mm_force_idle_req_handler(request) == KeMsgConsumed
  doAssert forced == 1 and callbacks == 0
  release(request)
  finishSwitch()
''',
    "header_and_callback_contract": r'''
for mutation in 0..4:
  resetSwitch()
  let request = beginSwitch(newTarget())
  let header = keMsgHdrFromPayload(request)
  case mutation
  of 0: header.id = 0
  of 1: header.destId = 1
  of 2: header.srcId = 4
  of 3: header.paramLen = 3
  else: cast[ptr pointer](request)[] = nil
  doAssert mm_force_idle_req_handler(request) == KeMsgConsumed
  doAssert forced == 0 and callbacks == 0
  release(request)
  finishSwitch()
''',
    "legacy_callback": r'''
resetSwitch()
proc legacy() {.cdecl.} = inc callbacks
let request = ke_msg_alloc(74, TASK_MM, 255, 8)
cast[ptr pointer](request)[] = cast[pointer](legacy)
doAssert mm_force_idle_req_handler(request) == KeMsgConsumed
doAssert callbacks == 1 and chanSwitchTags == nil
release(request)
doAssert mm_force_idle_req_handler(nil) == KeMsgConsumed
finishSwitch()
''',
    "allocation_failure": r'''
resetSwitch()
let target = newTarget()
failAlloc = true
chan_switch_start(target)
doAssert queued.len == 0 and live.len == 0 and channelEnv.scheduledCtxt == nil
finishSwitch()
''',
}


@pytest.mark.parametrize("case", CASES)
@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_switch_request_lifetime(tmp_path: Path, case: str, mode: str) -> None:
    run_program(tmp_path, mode, source() + "\nblock:\n" + indent(CASES[case], "  "))


def test_switch_release_and_reset_hooks() -> None:
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    assert "chanSwitchForget(param)" in procedure(kernel, "ke_msg_free")
    assert "chanSwitchForget(cast[pointer](hdr))" in procedure(kernel, "ke_msg_send")
    for name in ["ke_init", "ke_flush", "chan_init"]:
        assert "chanSwitchCancel()" in procedure(kernel, name)
    assert "chanSwitchRetire(cast[pointer](ctxt))" in procedure(kernel, "chan_ctxt_del")
