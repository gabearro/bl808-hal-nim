"""Explore SCANU completion and real kernel saved-queue schedules."""

from itertools import product
import os
from pathlib import Path
import random

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program
from test_wifi_saved_reschedule import source as saved_queue_source


def schedules(seed: int, steps: int) -> list[tuple[str, int]]:
    # The completion is a required event. All short legal schedules before it
    # are explored, followed by seeded bursts crossing the batch boundary.
    cases = [("".join(prefix) + "C", mode)
             for size in range(3) for prefix in product("sStow", repeat=size)
             for mode in range(16)]
    rng = random.Random(seed ^ 0x5343414E)
    for _ in range(steps):
        prefix = "".join(rng.choices("sStrow", k=rng.randint(1, 32)))
        suffix = "".join(rng.choices("tow", k=rng.randint(0, 10)))
        cases.append((prefix + "C" + suffix, rng.randrange(16)))
    return cases


PLATFORM = r'''
const
  SCANU_START_CFM = 0x801'u16
  SCANU_JOIN_REQ = 0x802'u16
  SCANU_JOIN_CFM = 0x803'u16
  StatusCfmPayloadSize = 1'u32
  ScanuIdleState = 0'u16
type
  StatusCfmPayload = object
    status: uint8
  Envelope = object
    header: KeMsgHdr
    payload: StatusCfmPayload
var
  scanu_env: tuple[paramPtr, pendingJoinRxuMgtInd: pointer,
                   requester, bssidFilterEnabled: uint8]
  scanuRequestEpoch: uint32
  request, reply, notice: Envelope
  scheduleMode: int
  actualStatuses: seq[uint8]
  optNotices: int
  allocHook: proc()

proc keMsgHdrFromPayload(p: pointer): ptr KeMsgHdr =
  addr cast[ptr Envelope](p).header
proc statusCfmView(p: pointer): ptr StatusCfmPayload =
  addr cast[ptr Envelope](p).payload
proc smScanOwnsRequest(p: pointer): bool = false
proc ke_msg_try_alloc(id: uint16; dest, src: uint8; size: uint32): pointer =
  if allocHook != nil and dest == TASK_SM:
    let hook = allocHook
    allocHook = nil
    hook()
  if dest == TASK_SM and (scheduleMode and 2) != 0: return nil
  let env = if dest == TASK_API: addr notice else: addr reply
  env[] = Envelope(header: KeMsgHdr(id: id, destId: dest, srcId: src, paramLen: size))
  env
proc smScanCompletionAlloc(p: pointer; id: uint16; dest: uint8): pointer =
  ke_msg_try_alloc(id, dest, TASK_SCANU, StatusCfmPayloadSize)
proc ke_msg_send(p: pointer) =
  let header = keMsgHdrFromPayload(p)
  if header.destId == TASK_API:
    inc optNotices
    if (scheduleMode shr 2) == 2: save(TASK_SCANU, 1)
  else:
    actualStatuses.add(statusCfmView(p).status)
    co_list_push_back(addr keMsgQueueSent, cast[ptr CoListHdr](header))
    ke_evt_set(KE_EVT_KE_MESSAGE)
'''


DRIVER = r'''
proc exercise(trace: string; mode: int): string =
  setup()
  scheduleMode = mode
  actualStatuses.setLen(0)
  optNotices = 0
  allocHook = nil
  request = Envelope(header: KeMsgHdr(paramLen: 316))
  scanu_env = (cast[pointer](addr request), nil, TASK_SM, (mode and 1).uint8)
  states[TASK_SCANU] = 1
  let confirmation = if (mode and 1) != 0: SCANU_JOIN_CFM else: SCANU_START_CFM
  # Model just the causality contract, not the kernel's batching algorithm.
  var scanIds: seq[uint16]
  var modelNext = 0'u16
  var completed = false
  proc expectScanBatch(count: int) =
    for _ in 0 ..< count:
      scanIds.add(modelNext)
      inc modelNext
  proc prepareCompletion() =
    let phase = mode shr 2
    if phase == 1:
      expectScanBatch(1)
      allocHook = proc() = save(TASK_SCANU, 1)
    if phase == 2 and (mode and 1) != 0: expectScanBatch(1)
    if phase == 3:
      onEvent = proc() =
        onEvent = nil
        discard step()
  for event in trace:
    case event
    of 's', 'S':
      if completed: return ""
      let count = if event == 's': 1 else: 9
      expectScanBatch(count)
      save(TASK_SCANU, count)
    of 'o':
      inc modelNext, 7
      save(TASK_MM, 7)
    of 'w':
      ke_state_set(TASK_MM, if states[TASK_MM] == 1: 2 else: 1)
    of 't': discard step()
    of 'r':
      if completed: return ""
      # Reset discards earlier saved/sent envelopes; SCANU's new generation
      # and request are installed before another completion is admissible.
      ke_flush()
      inc scanuRequestEpoch
      scanIds.setLen(0)
      delivered.setLen(0)
    of 'C':
      if completed: return ""
      prepareCompletion()
      scanu_confirm(7)
      if scanu_env.paramPtr != nil or states[TASK_SCANU] != ScanuIdleState:
        return "completion-did-not-retire-owner"
      scanu_confirm(8) # Duplicate terminal outcome must be inert.
      completed = true
    else: return ""
  if not completed: return ""
  ke_state_set(TASK_MM, if states[TASK_MM] == 1: 2 else: 1)
  drain()
  var actual: seq[uint16]
  for id in delivered:
    if id == confirmation or id in scanIds: actual.add(id)
  if actual != @[confirmation] & scanIds: return "fifo-before-confirm"
  if actualStatuses != @[7'u8] or optNotices != (mode and 1):
    return "terminal-outcome-count"

proc check(trace: string; mode: int) =
  let failure = exercise(trace, mode)
  if failure == "": return
  var minimal = trace
  var index = 0
  while index < minimal.len:
    let reduced = minimal[0 ..< index] & minimal[index + 1 .. ^1]
    if exercise(reduced, mode) == failure: minimal = reduced
    else: inc index
  doAssert false, failure & " mode=" & $mode & " trace=" & trace & " minimized=" & minimal
'''


@pytest.mark.parametrize("mutation", [False, True], ids=["firmware", "early-idle"])
def test_scanu_saved_queue_model(tmp_path: Path, mutation: bool) -> None:
    seed = int(os.environ.get("BL808_WIFI_MODEL_SEED", "808"))
    steps = int(os.environ.get("BL808_WIFI_MODEL_STEPS", "256"))
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    scan = (FW / "scan_station_ap_me.nim").read_text()
    completion = procedure(scan, "scanu_confirm").split("\ntype ProbeIeWriter", 1)[0]
    if mutation:
        original = "  defer: scanuReleaseCompletedOwner(completion.epoch)"
        assert original in completion
        completion = completion.replace(original, original.replace("defer: ", ""))
    fixture = saved_queue_source().replace("    destId, srcId: uint8\n",
                                         "    destId, srcId: uint8\n    paramLen: uint32\n", 1)
    fixture = fixture.replace("array[80, KeMsgHdr]", "array[512, KeMsgHdr]")
    source = (fixture + PLATFORM + procedure(kernel, "ke_msg_forward_and_change_id")
              + procedure(scan, "scanuReleaseCompletedOwner")
              + procedure(scan, "scanuPublishCompletion") + completion + DRIVER)
    cases = schedules(seed, steps)
    source += f'echo "queue seed={seed} cases={len(cases)}"\n'
    source += "\n".join(f'check("{trace}", {mode})' for trace, mode in cases)
    if mutation:
        with pytest.raises(AssertionError, match=r"fifo-before-confirm.*minimized="):
            run_program(tmp_path, "firmware", source)
    else:
        run_program(tmp_path, "firmware", source)
