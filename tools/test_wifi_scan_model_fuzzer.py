"""Stateful schedules for the actual BL808 lower scan and exchange handlers."""

from itertools import product
import os
from pathlib import Path
import random

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program
from test_wifi_scan_dwell_notices import source as dwell_source


DRIVER = r'''
proc scan_send_cancel_cfm(status, dest: uint8) =
  doAssert false, "test sends CANCEL only to an admitted scan"
'''

CHECKS = r'''
# Run one admitted request with deterministic radio order and a delayed
# confirmation outside the sent queue. Compare observations to the scenario
# oracle rather than to the firmware's dwell or request counters.
proc activeScan(channels, expectedVisits: int; outcome: string; order: int): string =
  let lower = newRequest(channels.uint8)
  if scan_start_req_handler(lower) != KeMsgNoFree: return "admit"
  let accepted = take()
  if statusCfmView(accepted).status != SCAN_STATUS_OK: return "start-status"
  var terminal = 0
  var visits = 0
  while terminal == 0:
    if visits >= channels: return "no-fair-progress"
    let slot = chanCtxtEpochs[3]
    if (order and 1) != 0:
      scanDwellPublish(MM_SCAN_CHANNEL_START_IND, slot - 1)
    if ((order shr (visits mod 5 + 1)) and 1) != 0:
      scanDwellPublish(MM_SCAN_CHANNEL_END_IND, slot)
    scanDwellPublish(MM_SCAN_CHANNEL_START_IND, slot)
    scanDwellPublish(MM_SCAN_CHANNEL_START_IND, slot)
    scanDwellPublish(MM_SCAN_CHANNEL_END_IND, slot)
    if queued.len != 2: return "radio-start-end-count"
    chanScanPoolOverlay().slot = 0xFF
    inc chanCtxtEpochs[3]
    let start = take()
    if keMsgHdrFromPayload(start).id != MM_SCAN_CHANNEL_START_IND: return "radio-order"
    discard mm_scan_channel_start_ind_handler(start)
    consume(start)
    if state != ScanChannelRunningState: return "start"
    inc visits
    if visits == expectedVisits:
      if outcome == "cancel":
        let cancel = ke_msg_alloc(0x403'u16, TASK_SCAN, TASK_SCANU, 0)
        discard scan_cancel_req_handler(cancel)
        consume(cancel)
      elif outcome == "reserve1": failAtCall = allocationCalls + 1
      elif outcome == "reserve2": failAtCall = allocationCalls + 2
    let finish = take()
    if keMsgHdrFromPayload(finish).id != MM_SCAN_CHANNEL_END_IND: return "radio-order"
    if mm_scan_channel_end_ind_handler(finish) == KeMsgConsumed: consume(finish)
    if queued.len > 1: return "duplicate-terminal"
    if queued.len == 1:
      let reply = take()
      let header = keMsgHdrFromPayload(reply)
      if header.id == SCAN_DONE_IND:
        if not scanuClaimLowerReply(reply, done = true):
          return "terminal-owner"
        if scanuClaimLowerReply(reply, done = true): return "duplicate-claim"
        terminal = 1
      elif header.id == SCAN_START_CFM and statusCfmView(reply).status == SCAN_STATUS_FAIL:
        if not scanuClaimLowerReply(reply, done = false): return "failure-owner"
        terminal = 2
      else: return "unexpected-terminal"
      consume(reply)
  if scanuClaimLowerReply(accepted, done = false):
    # Normal success may discard the delayed OK after claiming DONE; failure
    # replaced the OK with the terminal error under the same request.
    return "late-confirmation"
  consume(accepted)
  if visits != expectedVisits: return "visit-count"
  if terminal != (if outcome in ["reserve1", "reserve2"]: 2 else: 1):
    return "terminal-kind"
  if allocated.len != 0 or queued.len != 0 or state != ScanIdleState:
    return "unretired-request"

proc episode(channels, expectedVisits: int; scenario: string; order: int): string =
  fresh()
  if scenario in ["busy", "oom-cfm", "oom-start", "oom-end", "retired-request"]:
    let lower = newRequest(channels.uint8)
    case scenario
    of "busy": chanScanPoolOverlay().slot = 3
    of "oom-cfm": failAtCall = allocationCalls + 1
    of "oom-start": failAtCall = allocationCalls + 2
    of "oom-end": failAtCall = allocationCalls + 3
    else: inc scanuRequestEpoch
    if scan_start_req_handler(lower) == KeMsgConsumed: consume(lower)
    if scenario == "retired-request":
      if queued.len != 0 or scan_env.paramPtr != nil: return "retired-request-admitted"
    else:
      if queued.len != 1 or state != ScanIdleState: return "admission-terminal"
      let reply = take()
      let expected = if scenario == "busy": SCAN_STATUS_BUSY else: SCAN_STATUS_FAIL
      if statusCfmView(reply).status != expected or
          not scanuClaimLowerReply(reply, done = false): return "admission-status"
      consume(reply)
    chanScanPoolOverlay().slot = 0xFF
    if allocated.len != 0: return "admission-allocation-leak"
    return
  if scenario in ["reset-cfm", "reset-start"]:
    let lower = newRequest(2)
    if scan_start_req_handler(lower) != KeMsgNoFree: return "admit-before-reset"
    let conf = take()
    var oldStart: pointer
    if scenario == "reset-start":
      scanDwellPublish(MM_SCAN_CHANNEL_START_IND, chanCtxtEpochs[3])
      oldStart = take()
      scanDwellPublish(MM_SCAN_CHANNEL_END_IND, chanCtxtEpochs[3])
    resetDwell()
    chanScanPoolOverlay().slot = 0xFF
    inc scanuRequestEpoch
    if oldStart != nil:
      let handled = mm_scan_channel_start_ind_handler(oldStart)
      if handled != KeMsgConsumed or state != ScanIdleState: return "retired-dwell-start"
      consume(oldStart)
    if scanuClaimLowerReply(conf, done = false): return "retired-confirmation"
    consume(conf)
    if allocated.len != 0 or queued.len != 0: return "reset-ownership"
  activeScan(channels, expectedVisits, scenario, order)

proc check(channels, visits: int; scenario: string; order: int) =
  let failure = episode(channels, visits, scenario, order)
  if failure != "":
    # Keep the semantic fault and first failing observation; remove ordering
    # perturbations that are not needed for the same failure.
    var minimal = order
    for bit in 0 .. 5:
      let reduced = minimal and not (1 shl bit)
      # Only restart a replay when the failing state is fully drained. Other
      # failures already carry the shortest checked prefix (the first mismatch).
      if allocated.len == 0 and queued.len == 0 and
          episode(channels, visits, scenario, reduced) == failure:
        minimal = reduced
    doAssert false, failure & " scenario=" & scenario & " channels=" & $channels &
      " visits=" & $visits & " order=" & $order & " reduced-order=" & $minimal
'''


def schedules(seed: int, steps: int) -> list[tuple[int, int, str, int]]:
    # Oracle: normal work visits the requested channel list. An admitted stop
    # or a failed next-dwell reservation terminates at the first dwell boundary.
    simple = ("normal", "cancel", "reserve1", "reserve2", "busy", "oom-cfm",
              "oom-start", "oom-end", "retired-request", "reset-cfm", "reset-start")

    def visits(channels: int, scenario: str) -> int:
        return 1 if scenario in ("cancel", "reserve1", "reserve2") else channels

    short = [(channels, visits(channels, scenario), scenario, order)
             for channels, scenario, order in product((2, 3), simple, range(8))]
    rng = random.Random(seed ^ 0x574C414E)
    for _ in range(steps):
        n, scenario = rng.randint(2, 11), rng.choice(simple)
        short.append((n, visits(n, scenario), scenario, rng.randrange(64)))
    return short


@pytest.mark.parametrize("mutation", [False, True], ids=["firmware", "retired-request"])
def test_lower_scan_model(tmp_path: Path, mutation: bool) -> None:
    seed = int(os.environ.get("BL808_WIFI_MODEL_SEED", "808"))
    steps = int(os.environ.get("BL808_WIFI_MODEL_STEPS", "256"))
    tasks = (FW / "task_handlers.nim").read_text()
    target = dwell_source() + DRIVER + procedure(tasks, "scan_cancel_req_handler") + CHECKS
    if mutation:
        guard = ("  if requester == TASK_SCANU and not scanuLowerCurrent(param):\n"
                 "    return KeMsgConsumed\n")
        assert target.count(guard) == 1
        # Reproduce the earlier dequeue-time claim: an old queued request is
        # treated as current at every check within lower admission.
        lower = procedure(tasks, "scan_start_req_handler")
        target = target.replace(lower, lower.replace("and not scanuLowerCurrent(param)", "and false"))
    cases = schedules(seed, steps)
    target += f'\necho "scan seed={seed} cases={len(cases)}"\n'
    target += "\n".join(f'check({n}, {visits}, "{scenario}", {order})'
                        for n, visits, scenario, order in cases)
    if mutation:
        with pytest.raises(AssertionError, match=r"retired-request-admitted.*scenario="):
            run_program(tmp_path, "firmware", target)
    else:
        run_program(tmp_path, "firmware", target)
