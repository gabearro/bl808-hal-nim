"""Drive a dwell's START and END notices between slot 3 and TASK_SCAN.

Each dwell allocates both notices when it is asked for (scanDwellBegin) and
holds them until the channel scheduler posts them (scanDwellPost): START
when slot 3 becomes current, END when it is retired, START first if it was
still held. A notice carries the dwell's stamp; TASK_SCAN takes it only
while that dwell is live. Notices still held when the dwell ends are freed
there; posted ones are freed by the kernel after their handler.

The programs are tools/test_wifi_scan_table.py's harness.
"""

from pathlib import Path

import pytest

from test_wifi_message_allocation import run_program
from test_wifi_scan_table import harness

MODES = ["checked", "asan", "firmware"]


def source() -> str:
    """The real scan machine and handlers (tools/test_wifi_scan_table.py)."""
    return harness() + r'''
proc admitted(channels: int; source = HostTask): pointer =
  ## A scan of `channels` channels from `source`, run until TASK_SCAN waits
  ## in state 2 with nothing queued. Returns the upper request.
  scan_init()
  scanu_init()
  requests.setLen(0)
  answers.setLen(0)
  result = newUpper(SCANU_START_REQ, source, channels)
  while queue.len > 0 or states[TASK_SCAN] != ScanChannelPendingState: doAssert step()
proc stampOfNotice(p: pointer): uint32 = cast[ptr uint32](p)[]
'''


@pytest.mark.parametrize("mode", MODES)
def test_scan_dwell_notices(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
discard admitted(2)
let stamp = scanOwn.op.serial
let start = scanOwn.start
let ending = scanOwn.finish
doAssert start != nil and ending != nil
doAssert stampOfNotice(start) == stamp and stampOfNotice(ending) == stamp
for p in [start, ending]:
  let h = keMsgHdrFromPayload(p)
  doAssert h.destId == TASK_SCAN and h.srcId == TASK_NONE and h.paramLen == 4

# Each notice is posted once, START first.
scanDwellPost(MM_SCAN_CHANNEL_START_IND)
scanDwellPost(MM_SCAN_CHANNEL_START_IND)
doAssert queue == @[start] and scanOwn.start == nil
scanDwellPost(MM_SCAN_CHANNEL_END_IND)
scanDwellPost(MM_SCAN_CHANNEL_END_IND)
doAssert queue == @[start, ending] and scanOwn.finish == nil
scanSlot.slot = 0xFF                     # the scheduler retired the slot
doAssert step() and states[TASK_SCAN] == ScanChannelRunningState
doAssert step() and states[TASK_SCAN] == ScanChannelPendingState
doAssert scan_env.channelIndex == 1 and scanOwn.op.serial == stamp + 1

# END before START was posted (an immediate retire): START is posted first.
let start2 = scanOwn.start
let ending2 = scanOwn.finish
scanDwellPost(MM_SCAN_CHANNEL_END_IND)
doAssert queue == @[start2, ending2]
scanSlot.slot = 0xFF
finish("notices")
doAssert answers.len == 1 and allocations > 0
''')


@pytest.mark.parametrize("mode", MODES)
def test_dwell_end_frees_unposted_notices(tmp_path: Path, mode: str) -> None:
    """A dwell that ends while it holds notices frees them; a notice posted
    before the end is stale when it runs and is freed by the kernel."""
    run_program(tmp_path, mode, source() + r'''
for point in 0 .. 3:
  discard admitted(2)
  let stamp = scanOwn.op.serial
  if point >= 1: arrive()                     # START queued
  if point >= 2: doAssert step()              # START handled
  if point >= 3: scanDwellPost(MM_SCAN_CHANNEL_END_IND)   # END queued
  let held = int(scanOwn.start != nil) + int(scanOwn.finish != nil)
  let before = heap.len
  scan_init()                                 # MM reset of TASK_SCAN
  doAssert heap.len == before - held, "a held notice outlived its dwell"
  doAssert scanOwn.start == nil and scanOwn.finish == nil
  doAssert states[TASK_SCAN] == ScanIdleState and not opCurrent(scanOwn.op, stamp)
  scanSlot.slot = 0xFF                        # chan_init
  slotOn = false
  scanu_init()
  smRequest = nil
  finish("reset at " & $point)
''')


@pytest.mark.parametrize("mode", MODES)
def test_partial_dwell_reset(tmp_path: Path, mode: str) -> None:
    """MM_RESET_REQ at every point of a two-channel scan: me_init resets
    SCANU, freeing its request; mm_init answers TASK_SCAN's request in place
    and frees the dwell's held notices; chan_init frees slot 3. Whatever was
    queued is stale and dropped. A scan started afterwards runs normally."""
    run_program(tmp_path, mode, source() + r'''
for stop in 0 .. 30:
  discard admitted(2)
  var ran = 0
  while ran < stop and step(): inc ran
  if ran < stop:
    finish("short run")
    break
  mmReset()
  check("after reset")
  finish("reset at step " & $stop)
  let upper = admitted(1)
  finish("after reset at step " & $stop)
  doAssert answers == @[(upper, SCANU_START_CFM)]
''')
