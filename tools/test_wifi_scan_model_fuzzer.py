"""Seeded schedules for the real lower scan (TASK_SCAN) and its SCANU exchange.

The program is tools/test_wifi_scan_table.py's harness: the real
scan_machine.nim and handlers, dispatched through the per-state tables of
dispatch_tables.nim, over a model of slot 3. Each episode starts one host or
SM scan, then interleaves at random: dispatching the queue head, the radio
reaching slot 3 (START) and retiring it (END). Once, at a random step, it
applies the scenario's disturbance. The harness's invariants are checked
after every step; at quiescence each request has exactly one answer, nothing
is allocated and every stamp is stale. The scenario oracle adds the number of
dwells the radio ran.
"""

import os
from pathlib import Path
import random

import pytest

from test_wifi_message_allocation import run_program
from test_wifi_scan_table import harness

EPISODES = r'''
import std/random

proc dispatchHead() =
  let active = if queue[0] in requests: queue[0] else: scanu_env.paramPtr
  let p = queue[0]
  queue.delete(0)
  dispatch(p)
  collect(active)

var retired: pointer   # a lower request SCANU no longer waits on

proc episode(scenario: string; channels, seed: int): string =
  var r = initRand(seed)
  try:
    doAssert heap.len == 0 and kept.len == 0
    answers.setLen(0)
    requests.setLen(0)
    stamps.setLen(0)
    scanSlot.slot = 0xFF
    slotOn = false
    failCount = 0
    arrivals = 0
    timer.armed = false
    retired = nil
    scan_init()
    scanu_init()
    smRequest = nil
    let source = if scenario == "abort-sm": TASK_SM else: HostTask
    discard newUpper(SCANU_START_REQ, source, channels)
    case scenario
    of "oom-cfm": (failId, failCount) = (SCAN_START_CFM, 1)
    of "oom-start": (failId, failCount) = (MM_SCAN_CHANNEL_START_IND, 1)
    of "oom-end": (failId, failCount) = (MM_SCAN_CHANNEL_END_IND, 1)
    of "busy": scanSlot.slot = 4
    else: discard
    let at = r.rand(4 * channels + 6)
    var injected = false
    var steps = 0
    while true:
      if not injected and (steps >= at or scenario == "retired-request"):
        injected = true
        case scenario
        of "cancel":
          ke_msg_send(ke_msg_try_alloc(SCAN_CANCEL_REQ, TASK_SCAN, HostTask, 0))
        of "abort-host":
          ke_msg_send(ke_msg_try_alloc(SCAN_ABORT_REQ, TASK_SCAN, HostTask, 0))
        of "abort-sm": smQueueOwnedScanAbort()
        of "early-end": scanEarlyEndRequest()
        of "stop": scanStopAfterDwell()
        of "stale":
          for id in [MM_SCAN_CHANNEL_START_IND, MM_SCAN_CHANNEL_END_IND,
                     MM_SCAN_CHANNEL_END_EARLY, SCAN_PROBE_TIMER]:
            discard stale(id, scanOwn.op.serial - 1)
        of "probe":
          if timer.armed:
            timer.armed = false
            discard stale(SCAN_PROBE_TIMER, timer.stamp)
        of "reset": mmReset()
        of "retired-request":
          # SCANU is reset while its SCAN_START_REQ waits in the queue.
          if scanuOwn.lower != nil and scanuOwn.lower in queue:
            retired = scanuOwn.lower
            scanu_init()
            smRequest = nil
          else: injected = false
        of "busy": scanSlot.slot = 0xFF  # the other slot user leaves
        else: discard
      let canArrive = scanSlot.slot == 3 and not slotOn
      let canRetire = scanSlot.slot == 3 and slotOn
      if queue.len == 0 and not canArrive and not canRetire:
        if injected: break
        # At rest before the scenario's moment: disturb the idle tasks now,
        # unless the disturbance needs a run in progress.
        if scenario == "retired-request": injected = true
        else: steps = at
        continue
      case r.rand(2)
      of 0:
        if queue.len > 0: dispatchHead()
      of 1:
        if canArrive: arrive()
      else:
        if canRetire: retire()
      if retired != nil and scan_env.paramPtr == retired:
        return "retired-request-admitted"
      check(scenario)
      inc steps
      doAssert steps < 2000, "no quiescence"
    finish(scenario)
    if scanSlot.slot == 4: scanSlot.slot = 0xFF
    case scenario
    of "normal", "probe", "stale":
      doAssert arrivals == channels, "dwells " & $arrivals & " of " & $channels
    of "oom-cfm", "oom-start":
      doAssert arrivals == 0
    else:
      doAssert arrivals <= channels
    ""
  except AssertionDefect as e:
    e.msg

proc check(scenario: string; channels, seed: int) =
  let failure = episode(scenario, channels, seed)
  doAssert failure == "", failure & " scenario=" & scenario & " channels=" &
    $channels & " seed=" & $seed
'''

SCENARIOS = ("normal", "cancel", "abort-host", "abort-sm", "early-end", "stop", "stale",
             "probe", "reset", "retired-request", "busy", "oom-cfm", "oom-start", "oom-end")


def schedules(seed: int, steps: int) -> list[tuple[str, int, int]]:
    rng = random.Random(seed ^ 0x574C414E)
    cases = [(scenario, channels, rng.randrange(1 << 30))
             for scenario in SCENARIOS for channels in (1, 2, 3)]
    for _ in range(steps):
        cases.append((rng.choice(SCENARIOS), rng.randint(1, 11), rng.randrange(1 << 30)))
    return cases


@pytest.mark.parametrize("mutation", [False, True], ids=["checked", "retired-request"])
def test_lower_scan_model(tmp_path: Path, mutation: bool) -> None:
    seed = int(os.environ.get("BL808_WIFI_MODEL_SEED", "808"))
    steps = int(os.environ.get("BL808_WIFI_MODEL_STEPS", "256"))
    target = harness()
    if mutation:
        # TASK_SCAN admits a SCAN_START_REQ SCANU no longer waits on.
        guard = "  if requester == TASK_SCANU and not scanuAwaits(param):\n"
        assert target.count(guard) == 1
        target = target.replace(guard, "  if false:\n", 1)
    cases = schedules(seed, steps)
    target += EPISODES + f'\necho "scan seed={seed} cases={len(cases)}"\n'
    target += "\n".join(f'check("{scenario}", {channels}, {case_seed})'
                        for scenario, channels, case_seed in cases)
    if mutation:
        # A reset or a retired request exposes it: TASK_SCAN runs a request
        # SCANU does not wait on.
        with pytest.raises(AssertionError,
                           match=r"(retired-request-admitted|SCANU no longer waits on).* scenario="):
            run_program(tmp_path, "checked", target)
    else:
        run_program(tmp_path, "checked", target)


def test_stale_notice_mutation_is_caught(tmp_path: Path) -> None:
    """Second control: TASK_SCAN takes a START whatever its stamp."""
    seed = int(os.environ.get("BL808_WIFI_MODEL_SEED", "808"))
    target = harness()
    old = "  if not scanCurrent(param, ScanChannelPendingState): return KeMsgConsumed\n"
    assert target.count(old) == 1
    target = target.replace(
        old, "  if ke_state_get(TASK_SCAN) != ScanChannelPendingState: return KeMsgConsumed\n", 1)
    rng = random.Random(seed)
    target += EPISODES + "\n".join(f'check("stale", {channels}, {rng.randrange(1 << 30)})'
                                   for channels in (1, 2, 3) for _ in range(8))
    with pytest.raises(AssertionError, match=r"scenario=stale"):
        run_program(tmp_path, "checked", target)
