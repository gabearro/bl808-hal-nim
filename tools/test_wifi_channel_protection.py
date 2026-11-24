"""Exercise protection TX completion ownership across channel switches."""

from pathlib import Path
from textwrap import indent

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program
from test_wifi_switch_request import source as switch_source


def source() -> str:
    code = switch_source()
    for name in ["chan_sta_tx_cfm", "chan_ap_tx_cfm"]:
        code = code.replace(procedure(code, name),
                            f"proc {name}*(param: pointer; status: uint32) {{.exportc, cdecl.}}\n", 1)
    support = r'''
type ProtectionFrame = object
  callback: pointer
  token: uint32
  ap: bool
var
  protectionFrames: seq[ProtectionFrame]
  synchronous, secondStation: bool
  nullResult, ctsResult: uint8
  onProtectionSend, onActive, onPre: proc()
  protectedSource, protectedTarget: pointer
  frameEpoch: uint32
  frameTracked: bool
  frameCurrent = true
proc txlFrameCallbackCurrent(resetEpoch = txResetEpoch): bool =
  not frameTracked or (frameCurrent and frameEpoch == resetEpoch)
proc invokeProtectionFrame(callback: pointer; token: uint32) =
  let previous = (frameTracked, frameEpoch)
  frameTracked = true
  frameEpoch = txResetEpoch
  defer: (frameTracked, frameEpoch) = previous
  cast[proc(p: pointer; status: uint32) {.cdecl.}](callback)(cast[pointer](token.uint), 0)
proc emitProtection(callback: pointer; token: uint32; ap: bool): uint8 =
  doAssert chanProtectionTagged(cast[pointer](token.uint))
  protectionFrames.add(ProtectionFrame(callback: callback, token: token, ap: ap))
  invoke(onProtectionSend)
  result = if ap: ctsResult else: nullResult
  if synchronous and result == 0:
    invokeProtectionFrame(callback, token)
'''
    code += support
    code = code.replace(procedure(code, "txl_frame_send_null_frame"), r'''
proc emitProtection(callback: pointer; token: uint32; ap: bool): uint8
proc txl_frame_send_null_frame(index: uint8; callback: pointer; arg: uint32): uint8 =
  emitProtection(callback, arg, false)
''', 1)
    code = code.replace(procedure(code, "txl_frame_send_selfcts_frame"), r'''
proc txl_frame_send_selfcts_frame(p: pointer; duration: uint16; callback: pointer; arg: uint32): uint8 =
  emitProtection(callback, arg, true)
''', 1)
    # The real completion routines below replace the fixture's no-op callbacks.
    tasks = (FW / "task_handlers.nim").read_text()
    for name in ["chan_sta_tx_cfm", "chan_ap_tx_cfm"]:
        code += procedure(tasks, name)
    code = code.replace(procedure(code, "mm_active"), r'''
proc protectionActiveHook()
proc mm_active() = protectionActiveHook()
''', 1)
    code = code.replace(procedure(code, "chan_pre_switch_channel"), r'''
proc protectionPreHook(): bool
proc chan_pre_switch_channel() =
  if not protectionPreHook(): return
  inc callbacks
  channelEnv.currentCtxt = channelEnv.scheduledCtxt
  channelEnv.scheduledCtxt = nil
''', 1)
    return code + r'''
proc protectionActiveHook() = invoke(onActive)
proc protectionPreHook(): bool =
  invoke(onPre)
  chanSwitchCallbackCurrent()
proc resetProtectionTest() =
  resetSwitch()
  protectionFrames.setLen(0)
  synchronous = false
  secondStation = false
  nullResult = 0
  ctsResult = 0
  onProtectionSend = nil
  onActive = nil
  onPre = nil
  frameCurrent = true
proc configureProtection(target: pointer) =
  channelEnv.ctxtCount = 2
  chanCtxtAt(protectedSource).schedSlot = 50
  vifs[0].vifType = 0
  vifs[0].state = 1
  vifs[0].staIdx = 0
  vifs[0].chanCtxt = protectedSource
  vifs[0].next = addr vifs[1]
  vifs[1].vifType = if secondStation: 0 else: 2
  vifs[1].state = 1
  vifs[1].staIdx = 1
  vifs[1].chanCtxt = protectedSource
  vifs[1].postponedStaHead = cast[pointer](1)
  vifs[1].next = nil
  mgmt.activeList.first = cast[ptr CoListHdr](addr vifs[0])
proc beginProtection() =
  protectedSource = newTarget(2412)
  protectedTarget = newTarget(2437)
  chanCtxtAt(protectedSource).status = 4
  channelEnv.currentCtxt = protectedSource
  configureProtection(protectedTarget)
  let request = beginSwitch(protectedTarget)
  doAssert mm_force_idle_req_handler(request) == KeMsgConsumed
  release(request)
  doAssert chanSwitchTags == nil
proc completeFrame(index: int) =
  let frame = protectionFrames[index]
  invokeProtectionFrame(frame.callback, frame.token)
proc finishProtectionTest() =
  finishSwitch()
  doAssert not chanProtectionActive()
'''


CASES = {
    "invalidated_during_pause": r'''
for powerSaveBypass in [false, true]:
  resetProtectionTest()
  secondStation = powerSaveBypass
  onProtectionSend = proc() =
    if powerSaveBypass: ps.enabled = 1
    onStatus = proc() = inc chanCtxtEpochs[chanCtxtAt(protectedTarget).contextIndexOrMarker]
  protectedSource = newTarget(2412)
  protectedTarget = newTarget(2437)
  channelEnv.currentCtxt = protectedSource
  channelEnv.scheduledCtxt = protectedTarget
  configureProtection(protectedTarget)
  chan_goto_idle_cb()
  doAssert callbacks == 0 and not chanProtectionActive()
  doAssert channelEnv.scheduledCtxt == nil
  for index in 0..<protectionFrames.len: completeFrame(index)
  doAssert callbacks == 0
  finishProtectionTest()
''',
    "power_save_after_pending_submission": r'''
resetProtectionTest()
secondStation = true
var resumed = false
onActive = proc() = resumed = true
onProtectionSend = proc() = ps.enabled = 1
beginProtection()
doAssert protectionFrames.len == 1 and callbacks == 0
doAssert channelEnv.scanDelayCount == 1 and channelEnv.connlessDelayCount == 0
doAssert resumed and chanCtxtAt(protectedTarget).status == 3
completeFrame(0)
doAssert callbacks == 1 and channelEnv.currentCtxt == protectedTarget
finishProtectionTest()
''',
    "power_save_after_immediate_completion": r'''
resetProtectionTest()
secondStation = true
synchronous = true
protectedSource = newTarget(2412)
protectedTarget = newTarget(2437)
channelEnv.currentCtxt = protectedSource
channelEnv.scheduledCtxt = protectedTarget
configureProtection(protectedTarget)
onProtectionSend = proc() =
  ps.enabled = 1
  onIdle = proc() = inc chanCtxtEpochs[chanCtxtAt(protectedTarget).contextIndexOrMarker]
chan_goto_idle_cb()
doAssert protectionFrames.len == 1 and callbacks == 0
doAssert not chanProtectionActive() and channelEnv.scheduledCtxt == nil
finishProtectionTest()
''',
    "invalidated_during_final_idle": r'''
for invalidateFrame in [false, true]:
  resetProtectionTest()
  beginProtection()
  completeFrame(0)
  onIdle = proc() =
    if invalidateFrame: frameCurrent = false
    else: inc chanCtxtEpochs[chanCtxtAt(protectedTarget).contextIndexOrMarker]
  completeFrame(1)
  doAssert callbacks == 0 and not chanProtectionActive()
  doAssert channelEnv.scheduledCtxt == nil
  finishProtectionTest()
''',
    "power_save_bypass": r'''
resetProtectionTest()
ps.enabled = 1
beginProtection()
doAssert protectionFrames.len == 0 and callbacks == 1 and forced == 1
doAssert not chanProtectionActive()
finishProtectionTest()
''',
    "two_station_tickets": r'''
resetProtectionTest()
secondStation = true
beginProtection()
doAssert channelEnv.scanDelayCount == 2 and channelEnv.connlessDelayCount == 0
completeFrame(0)
completeFrame(0)
doAssert channelEnv.scanDelayCount == 1 and callbacks == 0
completeFrame(1)
doAssert callbacks == 1
finishProtectionTest()
''',
    "mixed_immediate_and_delayed": r'''
resetProtectionTest()
onProtectionSend = proc() =
  synchronous = true
  onProtectionSend = proc() = synchronous = false
beginProtection()
doAssert channelEnv.scanDelayCount == 0 and channelEnv.connlessDelayCount == 1
doAssert callbacks == 0
completeFrame(1)
doAssert callbacks == 1
finishProtectionTest()
''',
    "cancel_during_submission": r'''
for ap in [false, true]:
  for retireSource in [false, true]:
    resetProtectionTest()
    let cancel = proc() =
      doAssert protectionFrames[^1].ap == ap
      chanSwitchCancel(protectedTarget)
      if retireSource:
        inc chanCtxtEpochs[chanCtxtAt(protectedSource).contextIndexOrMarker]
    if ap:
      onProtectionSend = proc() = onProtectionSend = cancel
    else:
      onProtectionSend = cancel
    beginProtection()
    doAssert protectionFrames.len == (if ap: 2 else: 1) and callbacks == 0
    doAssert chanCtxtAt(protectedSource).status == (if retireSource: 6 else: 4)
    doAssert channelEnv.scanDelayCount == 0 and channelEnv.connlessDelayCount == 0
    for index in 0..<protectionFrames.len: completeFrame(index)
    doAssert callbacks == 0
    finishProtectionTest()
''',
    "new_switch_during_final_idle": r'''
resetProtectionTest()
beginProtection()
completeFrame(0)
var replacement: pointer
onIdle = proc() =
  chanSwitchCancel(protectedTarget)
  replacement = newTarget(2462)
  let request = beginSwitch(replacement)
  mmState = MM_IDLE
  doAssert mm_force_idle_req_handler(request) == KeMsgConsumed
  release(request)
completeFrame(1)
doAssert callbacks == 0 and protectionFrames.len == 4
doAssert channelEnv.scanDelayCount == 1 and channelEnv.connlessDelayCount == 1
completeFrame(2)
completeFrame(3)
doAssert callbacks == 1 and channelEnv.currentCtxt == replacement
finishProtectionTest()
''',
    "ordered_and_duplicate_completions": r'''
for reverse in [false, true]:
  resetProtectionTest()
  beginProtection()
  doAssert protectionFrames.len == 2 and callbacks == 0 and forced == 1
  doAssert channelEnv.scanDelayCount == 1 and channelEnv.connlessDelayCount == 1
  let first = if reverse: 1 else: 0
  let last = 1 - first
  completeFrame(first)
  completeFrame(first)
  doAssert callbacks == 0 and forced == 1
  doAssert channelEnv.scanDelayCount + channelEnv.connlessDelayCount == 1
  completeFrame(last)
  doAssert callbacks == 1 and forced == 2
  doAssert channelEnv.currentCtxt == protectedTarget
  completeFrame(first)
  completeFrame(last)
  doAssert callbacks == 1 and forced == 2
  finishProtectionTest()
''',
    "immediate_completions": r'''
resetProtectionTest()
synchronous = true
onProtectionSend = proc() =
  doAssert callbacks == 0 and chanProtection.building
beginProtection()
doAssert protectionFrames.len == 2 and callbacks == 1 and forced == 2
doAssert channelEnv.scanDelayCount == 0 and channelEnv.connlessDelayCount == 0
finishProtectionTest()
''',
    "submission_failure_matrix": r'''
for nullFailure in 0'u8..1:
  for ctsFailure in 0'u8..1:
    resetProtectionTest()
    nullResult = nullFailure
    ctsResult = ctsFailure
    beginProtection()
    doAssert channelEnv.scanDelayCount == 1 - nullFailure
    doAssert channelEnv.connlessDelayCount == 1 - ctsFailure
    for index in 0..<protectionFrames.len: completeFrame(index)
    doAssert callbacks == 1
    doAssert forced == (if nullFailure == 1 and ctsFailure == 1: 1 else: 2)
    finishProtectionTest()
''',
    "late_old_switch_completions": r'''
resetProtectionTest()
beginProtection()
let oldToken0 = protectionFrames[0].token
chanSwitchCancel(protectedTarget)
let replacement = newTarget(2462)
let request = beginSwitch(replacement)
mmState = MM_IDLE
doAssert mm_force_idle_req_handler(request) == KeMsgConsumed
release(request)
doAssert protectionFrames.len == 4 and protectionFrames[2].token != oldToken0
completeFrame(0)
completeFrame(1)
doAssert callbacks == 0 and channelEnv.scanDelayCount == 1 and channelEnv.connlessDelayCount == 1
completeFrame(2)
completeFrame(3)
doAssert callbacks == 1 and channelEnv.currentCtxt == replacement
finishProtectionTest()
''',
    "retired_context": r'''
for retireSource in [false, true]:
  resetProtectionTest()
  beginProtection()
  let retired = if retireSource: protectedSource else: protectedTarget
  inc chanCtxtEpochs[chanCtxtAt(retired).contextIndexOrMarker]
  completeFrame(0)
  completeFrame(1)
  doAssert callbacks == 0 and forced == 1 and not chanProtectionActive()
  doAssert channelEnv.scheduledCtxt == nil
  finishProtectionTest()
''',
    "retired_frame_session": r'''
resetProtectionTest()
beginProtection()
frameCurrent = false
completeFrame(0)
frameCurrent = true
completeFrame(1)
doAssert callbacks == 0 and forced == 1 and not chanProtectionActive()
finishProtectionTest()
''',
    "cancel_during_final_idle": r'''
resetProtectionTest()
beginProtection()
completeFrame(0)
onIdle = proc() = chanSwitchCancel(protectedTarget)
completeFrame(1)
doAssert callbacks == 0 and forced == 2 and not chanProtectionActive()
finishProtectionTest()
''',
    "completion_during_reactivation": r'''
resetProtectionTest()
onActive = proc() =
  completeFrame(0)
  completeFrame(1)
beginProtection()
doAssert callbacks == 1 and forced == 2
finishProtectionTest()
''',
    "retarget_during_resume": r'''
resetProtectionTest()
beginProtection()
let priorityTarget = newTarget(2462)
onPre = proc() =
  channelEnv.scheduledCtxt = priorityTarget
  doAssert chanSwitchSelectTarget(priorityTarget)
completeFrame(0)
completeFrame(1)
doAssert callbacks == 1 and channelEnv.currentCtxt == priorityTarget
finishProtectionTest()
''',
    "wrong_kind_and_unrelated_completion": r'''
resetProtectionTest()
beginProtection()
let staToken = cast[pointer](protectionFrames[0].token.uint)
chan_ap_tx_cfm(staToken, 0)
chan_sta_tx_cfm(nil, 0)
doAssert channelEnv.scanDelayCount == 1 and channelEnv.connlessDelayCount == 1
completeFrame(0)
completeFrame(1)
doAssert callbacks == 1
finishProtectionTest()
''',
}


@pytest.mark.parametrize("case", CASES)
@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_protection_completion(tmp_path: Path, case: str, mode: str) -> None:
    run_program(tmp_path, mode, source() + "\nblock:\n" + indent(CASES[case], "  "))
