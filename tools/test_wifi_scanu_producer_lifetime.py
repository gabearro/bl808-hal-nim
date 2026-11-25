"""SCANU's request producers: scanu_start, scanu_scan_next and the join.

The programs are tools/test_wifi_scan_table.py's harness: the real SCANU
handlers and request builder over the real scan machine.

The producer guard (scanuProducerRequest/Epoch), the abandoned-request free
in the admission handler and the request re-checks after the allocator,
logs, cache clears, state writes and sends are gone: none of those calls runs
SCANU code (the firmware step is not reentered), SCANU's state tables admit a
request only in state 0, and scanuComplete is the only end of a request.
"""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program
from test_wifi_scan_table import harness

MODES = ["checked", "asan"]


@pytest.mark.parametrize("mode", MODES)
def test_join_retries_band_0_until_found(tmp_path: Path, mode: str) -> None:
    """A join that finds nothing scans band 0 again, ten times (scanu.c line
    1163), then confirms; one that found its BSS confirms after the band."""
    run_program(tmp_path, mode, harness() + r'''
for found in [false, true]:
  scan_init()
  scanu_init()
  requests.setLen(0)
  answers.setLen(0)
  arrivals = 0
  let upper = newUpper(SCANU_JOIN_REQ, HostTask, 1)
  doAssert step() and states[TASK_SCANU] == ScanuJoiningState
  doAssert scanu_env.joinRetryCount == 10 and scanuOwn.lower != nil
  if found: scanu_env.directedFound = 1
  finish("join")
  doAssert arrivals == (if found: 1 else: 11)
  doAssert answers == @[(upper, SCANU_JOIN_CFM)]
''')


@pytest.mark.parametrize("mode", MODES)
def test_join_replay_needs_its_done_notice(tmp_path: Path, mode: str) -> None:
    """With the target cached, the join replays the frame and ends with the
    SCAN_DONE_IND it sends itself. Without memory for that notice the cached
    frame stays where it is and the join scans."""
    run_program(tmp_path, mode, harness() + r'''
for memory in [true, false]:
  scan_init()
  scanu_init()
  requests.setLen(0)
  answers.setLen(0)
  arrivals = 0
  cacheClears = 0
  replayedFrames = 0
  cacheHit = true
  let frame = ke_msg_try_alloc(0x1C00, TASK_SCANU, TASK_SCANU, 32)
  cache.cachedRxuMgtInd = frame
  if not memory: (failId, failCount) = (SCAN_DONE_IND, 1)
  let upper = newUpper(SCANU_JOIN_REQ, TASK_SM, 1)
  doAssert step()
  if memory:
    doAssert cache.cachedRxuMgtInd == nil and queue == @[frame, scanu_env.pendingJoinRxuMgtInd]
    doAssert scanuOwn.lower == nil
  else:
    doAssert cache.cachedRxuMgtInd == frame and scanuOwn.lower != nil
    scanu_env.directedFound = 1
    ke_msg_free(keMsgHdrFromPayload(frame))
  finish("replay")
  doAssert replayedFrames == memory.int and arrivals == int(not memory)
  doAssert cacheClears == memory.int    # the replay clears the results (pinned)
  doAssert answers == @[(upper, SCANU_JOIN_CFM)]
  cacheHit = false
''')


@pytest.mark.parametrize("mode", MODES)
def test_scan_clears_results_and_join_keeps_them(tmp_path: Path, mode: str) -> None:
    """Pinned scanu_start clears the cached results for a scan, not a join;
    the lower request's allocation failing ends the request with FAIL."""
    run_program(tmp_path, mode, harness() + r'''
for id in [SCANU_START_REQ, SCANU_JOIN_REQ]:
  scan_init()
  scanu_init()
  requests.setLen(0)
  answers.setLen(0)
  cacheClears = 0
  discard newUpper(id, HostTask, 1)
  doAssert step()
  doAssert cacheClears == int(id == SCANU_START_REQ)
  scanu_env.directedFound = 1
  finish("clears")
scan_init()
scanu_init()
requests.setLen(0)
answers.setLen(0)
(failId, failCount) = (SCAN_START_REQ, 1)
let upper = newUpper(SCANU_START_REQ, TASK_SM, 2)
doAssert step() and states[TASK_SCANU] == ScanuIdleState
doAssert delivered.len == 0 and kept == @[upper]
doAssert statusCfmView(upper).status == SCAN_STATUS_FAIL
finish("no lower")
''')


def test_producer_guard_is_gone() -> None:
    scan = (FW / "scan_station_ap_me.nim").read_text()
    tasks = (FW / "task_handlers.nim").read_text()
    sources = "".join(path.read_text() for path in FW.rglob("*.nim"))
    for gone in ["scanuProducerRequest", "scanuProducerEpoch", "cacheScanuStartRequest",
                 "nimFwDbgScanuParamOverwrite", "scanuReleaseCompletedOwner"]:
        assert gone not in sources, gone
    for name in ["scanu_start", "scanu_scan_next"]:
        body = procedure(scan, name)
        assert "irqSave" not in body and "scanuRequestCurrent" not in body, name
    for name in ["scanu_start_req_handler", "scanu_join_req_handler"]:
        body = procedure(tasks, name)
        assert "irqSave" not in body and "scanuRequestCurrent" not in body, name
