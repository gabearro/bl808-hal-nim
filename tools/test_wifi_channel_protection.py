"""Exercise protection-frame counting and the departure it gates.

Built on the channel switch harness in test_wifi_switch_request: the real
chan_goto_idle_cb sends a PM=1 null per associated STA and a self-CTS per AP
on the source channel, chan_sta_tx_cfm/chan_ap_tx_cfm count them down, and
the last one departs (forced idle, then chan_pre_switch_channel).
"""

from pathlib import Path

import pytest

from test_wifi_switch_request import run_case


SETUP = r'''
var home, away: pointer
proc beginProtection(ap = true; secondStation = false) =
  ## STA (VIF 0) and, unless `ap` is false, an AP (VIF 1) on `home`; a switch
  ## to `away` reaches its protection wait. Call resetSwitch() first.
  home = newTarget(2412)
  away = newTarget(2437)
  linkHome(home, VIF_TYPE_STA, 0)
  linkHome(home, (if secondStation: VIF_TYPE_STA else: VIF_TYPE_AP), 1)
  if not ap and not secondStation: vifs[1].state = 0
  vifs[1].postponedStaHead = cast[pointer](1)
  chanCtxtAt(home).schedSlot = 50
  channelEnv.ctxtCount = 2
  activateVifs(2)
  operate(home)
  chan_switch_start(away)
  settle()
proc departures(): int = tuned.len
'''


CASES = {
    "counts_every_frame_then_departs": r'''
for reverse in [false, true]:
  resetSwitch()
  beginProtection()
  doAssert frames.len == 2 and not frames[0].ap and frames[1].ap
  doAssert channelEnv.scanDelayCount == 1 and channelEnv.connlessDelayCount == 1
  doAssert chanSw.phase == swProtecting and chanCtxtAt(away).status == 3
  doAssert mmState == MM_ACTIVE_STATE and (pmRegister and 4) != 0 and forced == 1
  let first = if reverse: 1 else: 0
  completeFrame(first)
  completeFrame(first)               # a duplicate counts for nothing
  doAssert departures() == 0 and forced == 1
  completeFrame(1 - first, 0x00800000'u32)
  doAssert departures() == 1 and forced == 2 and channelEnv.currentCtxt == away
  doAssert idleSwitch() and mmState == MM_ACTIVE_STATE
  completeFrame(0)
  completeFrame(1)
  doAssert departures() == 1 and forced == 2
  finishSwitch()
''',
    "flushed_frames_count": r'''
resetSwitch()
beginProtection()
completeFrame(0, 0x40000000'u32)     # retired by a TX flush: finished all the same
completeFrame(1, 0x40000000'u32)
doAssert departures() == 1 and channelEnv.currentCtxt == away
finishSwitch()
''',
    "last_completion_inside_tx_reset_departs_after_it": r'''
resetSwitch()
beginProtection(ap = false)
doAssert frames.len == 1
# bl_reset_evt: txl_reset's drain retires the frame with 0x40000000.
inc txResetEpoch
txResetActive = true
completeFrame(0, 0x40000000'u32)
txResetActive = false
doAssert departures() == 0 and forced == 1, "departed inside the reset window"
doAssert chanSw.phase == swDeparting and requestLinked()
settle()
doAssert departures() == 1 and forced == 2 and channelEnv.currentCtxt == away
doAssert idleSwitch() and mmState == MM_ACTIVE_STATE
finishSwitch()
''',
    "refused_frames_are_not_counted": r'''
for nullRefused in 0'u8 .. 1:
  for ctsRefused in 0'u8 .. 1:
    resetSwitch()
    nullResult = nullRefused
    ctsResult = ctsRefused
    beginProtection()
    doAssert frames.len == 2
    doAssert channelEnv.scanDelayCount == 1 - nullRefused
    doAssert channelEnv.connlessDelayCount == 1 - ctsRefused
    if nullRefused == 1 and ctsRefused == 1:
      doAssert departures() == 1 and forced == 1, "nothing to wait for"
    else:
      doAssert departures() == 0
      for index in 0 ..< frames.len: completeFrame(index)
      doAssert departures() == 1 and forced == 2
    finishSwitch()
''',
    "frames_finishing_during_submission": r'''
for allSynchronous in [false, true]:
  resetSwitch()
  synchronous = true
  if not allSynchronous:
    onFrame = proc() =
      onFrame = proc() = synchronous = false
  beginProtection()
  doAssert frames.len == 2
  if allSynchronous:
    # Both finished while chan_goto_idle_cb was still sending.
    doAssert departures() == 1 and forced == 2 and idleSwitch()
  else:
    doAssert departures() == 0 and channelEnv.scanDelayCount == 0
    doAssert channelEnv.connlessDelayCount == 1
    completeFrame(1)
    doAssert departures() == 1
  finishSwitch()
''',
    "power_save_station_stops_sending": r'''
for afterFirst in [false, true]:
  resetSwitch()
  if afterFirst:
    onFrame = proc() = ps.enabled = 1
  else:
    ps.enabled = 1
  beginProtection(secondStation = true)
  if afterFirst:
    # The first null was sent before PS was seen; it is still waited for.
    doAssert frames.len == 1 and departures() == 0
    completeFrame(0)
  else:
    doAssert frames.len == 0
  doAssert departures() == 1 and channelEnv.currentCtxt == away
  finishSwitch()
''',
    "timed_out_protection_restarts_departure": r'''
for flushed in [false, true]:
  resetSwitch()
  beginProtection()
  # chan_ctxt_op_evt on the paused destination: flag 0x20, then a new attempt.
  channelEnv.flags = channelEnv.flags or 0x20
  chanCtxtAt(away).status = 2
  if flushed:
    onDrain = proc() =
      completeFrame(0, 0x40000000'u32)
      completeFrame(1, 0x40000000'u32)
  chan_goto_idle_cb()
  doAssert departures() == 1 and frames.len == 2 and channelEnv.currentCtxt == away
  onDrain = nil
  completeFrame(0)
  completeFrame(1)
  doAssert departures() == 1 and forced == 2 and idleSwitch()
  finishSwitch()
''',
    "retired_destination_during_wait": r'''
resetSwitch()
beginProtection()
chan_ctxt_del(slot(away))
doAssert idleSwitch() and channelEnv.currentCtxt == home
doAssert mmState == MM_ACTIVE_STATE and (pmRegister and 4) == 0, "PM bit left set"
completeFrame(0)
completeFrame(1)
doAssert departures() == 0 and forced == 1
let next = newTarget(2462)
chan_switch_start(next)
settle()
doAssert frames.len == 4
completeFrame(2)
completeFrame(3)
doAssert tuned == @[next]
finishSwitch()
''',
    "retired_source_during_wait": r'''
resetSwitch()
beginProtection(ap = false)
chan_ctxt_unlink(0)                  # the STA leaves before its null is confirmed
chan_ctxt_unlink(1)
doAssert channelEnv.currentCtxt == nil and channelEnv.scheduledCtxt == away
completeFrame(0)
doAssert departures() == 1 and channelEnv.currentCtxt == away and idleSwitch()
finishSwitch()
''',
    "unrelated_and_earlier_tokens": r'''
resetSwitch()
beginProtection()
let oldFrames = frames
chan_ctxt_del(slot(away))
let next = newTarget(2462)
chan_switch_start(next)
settle()
doAssert frames.len == 4
chan_sta_tx_cfm(nil, 0)
chan_ap_tx_cfm(nil, 0)
for frame in oldFrames:
  cast[proc(p: pointer; status: uint32) {.cdecl.}](frame.callback)(
    cast[pointer](frame.token.uint), 0)
doAssert channelEnv.scanDelayCount == 1 and channelEnv.connlessDelayCount == 1
completeFrame(2)
completeFrame(3)
doAssert tuned == @[next]
finishSwitch()
''',
    "switch_replaced_during_final_forced_idle": r'''
resetSwitch()
beginProtection()
completeFrame(0)
var replacement: pointer
onIdle = proc() =
  onIdle = nil
  chan_ctxt_del(slot(away))
  replacement = newTarget(2462)
  chan_switch_start(replacement)
completeFrame(1)
doAssert departures() == 0 and mmState != HW_ACTIVE
doAssert channelEnv.scheduledCtxt == replacement and chanSw.phase == swQueued
settle()
doAssert frames.len == 4
completeFrame(2)
completeFrame(3)
doAssert tuned == @[replacement] and idleSwitch()
finishSwitch()
''',
    "completion_during_reactivation": r'''
resetSwitch()
onActive = proc() =
  if chanSw.phase == swProtecting and frames.len == 2:
    onActive = nil
    completeFrame(0)
    completeFrame(1)
beginProtection()
doAssert departures() == 1 and forced == 2 and idleSwitch()
finishSwitch()
''',
}


@pytest.mark.parametrize("case", CASES)
@pytest.mark.parametrize("mode", ["checked", "asan"])
def test_protection_completion(tmp_path: Path, case: str, mode: str) -> None:
    run_case(tmp_path, CASES[case], mode, SETUP)
