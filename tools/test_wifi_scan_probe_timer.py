"""Check TASK_SCAN's handlers, timer and probe ordering against the vendor.

The programs are tools/test_wifi_scan_table.py's harness: the real
scan_machine.nim and the real TASK_SCAN and SCANU handlers over a kernel
queue and a model of slot 3. The platform calls record their order in
`events`.
"""

from pathlib import Path

import pytest

from test_wifi_auth_frames import layouts
from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program
from test_wifi_scan_table import harness

MODES = ["checked", "asan", "firmware"]

# A host scan of `channels` channels, run until TASK_SCAN waits in state 2
# with its notices held and nothing queued.
BEGIN = r'''
proc begin(channels: int; passive = false): pointer =
  scan_init()
  scanu_init()
  requests.setLen(0)
  answers.setLen(0)
  result = newUpper(SCANU_START_REQ, HostTask, channels)
  if passive:
    for i in 0 ..< channels: scanuStartReqView(result).channelList[i].flags = 1
  while queue.len > 0 or states[TASK_SCAN] != ScanChannelPendingState: doAssert step()
  events.setLen(0)
  logs.setLen(0)
proc startDwell() =
  ## The radio reaches slot 3 and START runs.
  arrive()
  doAssert step()
proc endDwell() =
  ## The slot is retired and END runs.
  retire()
  doAssert step()
proc reset() =
  finish("reset")
  events.setLen(0)
  logs.setLen(0)
  probes = 0
  terminations = 0
  probeStatus = 0
  scanDuration = 200_000
'''


@pytest.mark.parametrize("mode", MODES)
def test_scan_start_probes_then_arms_then_runs(tmp_path: Path, mode: str) -> None:
    """Pinned scan_task.o's START handler: RX filter, probe (logging a
    failure), duration, half-duration repeat timer, then state 3. A passive
    channel only filters; a duration whose half is 0 or above the kernel's
    limit arms nothing. The timer carries the dwell's stamp."""
    run_program(tmp_path, mode, harness() + BEGIN + r'''
logging = true
discard begin(1)
let stamp = scanOwn.op.serial
startDwell()
doAssert events == @["filter", "tx", "duration", "timer"] and logs.len == 0
doAssert states[TASK_SCAN] == ScanChannelRunningState and timer == (true, stamp)
reset()

discard begin(1)
probeStatus = 1
startDwell()
doAssert events == @["filter", "tx", "duration", "timer"]
doAssert logs == @["scan_probe_req_tx f\r\n"]
reset()

discard begin(1, passive = true)
startDwell()
doAssert events == @["filter"] and not timer.armed
doAssert states[TASK_SCAN] == ScanChannelRunningState
reset()

for duration in [1'u32, (KE_TIMER_MAX_DELAY + 1) * 2]:
  discard begin(1)
  scanDuration = duration
  startDwell()
  doAssert events == @["filter", "tx", "duration"] and not timer.armed
  reset()
''')


@pytest.mark.parametrize("mode", MODES)
def test_scan_start_takes_only_the_live_dwell(tmp_path: Path, mode: str) -> None:
    """A START of an earlier dwell, of none, or for a dwell already on its
    channel changes nothing (the blob asserts the state); a dwell started
    with the stop flag set leaves its channel at once, without probing."""
    run_program(tmp_path, mode, harness() + BEGIN + r'''
discard begin(2)
let stamp = scanOwn.op.serial
for wrong in [stamp - 1, 0'u32]:
  discard stale(MM_SCAN_CHANNEL_START_IND, wrong)
  doAssert step()
doAssert events.len == 0 and states[TASK_SCAN] == ScanChannelPendingState
startDwell()
events.setLen(0)
discard stale(MM_SCAN_CHANNEL_START_IND, stamp)   # the live stamp, wrong state
doAssert step() and events.len == 0 and states[TASK_SCAN] == ScanChannelRunningState
reset()

for stop in ["abort", "cancel", "scanu"]:
  discard begin(2)
  case stop
  of "abort": ke_msg_send(ke_msg_try_alloc(SCAN_ABORT_REQ, TASK_SCAN, HostTask, 0))
  of "cancel": ke_msg_send(ke_msg_try_alloc(SCAN_CANCEL_REQ, TASK_SCAN, HostTask, 0))
  else: scanStopAfterDwell()
  while queue.len > 0: doAssert step()
  doAssert scan_env.abortFlag == 1 and terminations == 0
  events.setLen(0)
  startDwell()
  doAssert events == @["filter", "terminate"] and probes == 0 and not timer.armed
  doAssert scanSlot.slot == 0xFF and queue.len == 1, "the dwell stayed on its channel"
  doAssert step() and states[TASK_SCAN] == ScanIdleState and scan_env.channelIndex == 1
  reset()
''')


@pytest.mark.parametrize("mode", MODES)
def test_scan_end_clears_probe_timer_before_next_channel(tmp_path: Path, mode: str) -> None:
    """Pinned END handler: clear SCAN_PROBE_TIMER (0x407), clear the RX
    filter, advance, then request the next channel. On the last channel the
    request is answered in place: the lower request becomes SCAN_DONE_IND.
    An END of an earlier dwell changes nothing (the blob asserts)."""
    run_program(tmp_path, mode, harness() + BEGIN + r'''
discard begin(2)
let lower = scan_env.paramPtr
let first = scanOwn.op.serial
startDwell()
events.setLen(0)
discard stale(MM_SCAN_CHANNEL_END_IND, first - 1)
doAssert step() and events.len == 0
endDwell()
doAssert events == @["clear", "unfilter", "next"] and scan_env.channelIndex == 1
doAssert states[TASK_SCAN] == ScanChannelPendingState and scanOwn.op.serial == first + 1
doAssert scan_env.paramPtr == lower and timer.armed == false
discard stale(MM_SCAN_CHANNEL_END_IND, first)     # the first dwell's END again
doAssert step() and states[TASK_SCAN] == ScanChannelPendingState
startDwell()
events.setLen(0)
endDwell()
doAssert events == @["clear", "unfilter"] and states[TASK_SCAN] == ScanIdleState
doAssert queue == @[lower] and keMsgHdrFromPayload(lower).id == SCAN_DONE_IND
doAssert keMsgHdrFromPayload(lower).paramLen == 0 and keMsgHdrFromPayload(lower).destId == TASK_SCANU
reset()

# The next dwell's notices cannot be allocated: the request is answered in
# place as a failing SCAN_START_CFM, which SCANU takes as its end.
discard begin(2)
let failing = scan_env.paramPtr
startDwell()
failId = MM_SCAN_CHANNEL_END_IND
failCount = 1
endDwell()
doAssert states[TASK_SCAN] == ScanIdleState and queue == @[failing]
doAssert keMsgHdrFromPayload(failing).id == SCAN_START_CFM
doAssert statusCfmView(failing).status == SCAN_STATUS_FAIL
doAssert heap.len == 2, "the next dwell's START notice was not freed"  # upper and lower
reset()
''')


@pytest.mark.parametrize("mode", MODES)
def test_scan_probe_timer_reports_tx_failure(tmp_path: Path, mode: str) -> None:
    """Pinned scan_probe_req_handler probes in state 3 and logs a failure.
    Only the live dwell's expiry probes."""
    run_program(tmp_path, mode, harness() + BEGIN + r'''
logging = true
discard begin(2)
let stamp = scanOwn.op.serial
discard stale(SCAN_PROBE_TIMER, stamp)                 # state 2
doAssert step() and probes == 0
startDwell()
probes = 0
discard stale(SCAN_PROBE_TIMER, stamp)
doAssert step() and probes == 1 and logs.len == 0
probeStatus = 1
discard stale(SCAN_PROBE_TIMER, stamp)
doAssert step() and probes == 2 and logs == @["scan_probe_req_tx failed!\r\n"]
logging = false
discard stale(SCAN_PROBE_TIMER, stamp)
doAssert step() and probes == 3 and logs.len == 1
discard stale(SCAN_PROBE_TIMER, stamp - 1)
doAssert step() and probes == 3
endDwell()                                             # the next dwell is pending
discard stale(SCAN_PROBE_TIMER, stamp)
doAssert step() and probes == 3
startDwell()
probes = 0
discard stale(SCAN_PROBE_TIMER, stamp)                 # the first dwell's expiry
doAssert step() and probes == 0
reset()
''')


@pytest.mark.parametrize("mode", MODES)
def test_scan_abort_logs_function_name(tmp_path: Path, mode: str) -> None:
    """Pinned scan_abort_req_handler: in a busy state it sets the abort flag,
    in state 3 it leaves the channel, and it always logs."""
    run_program(tmp_path, mode, harness() + BEGIN + r'''
logging = true
const Done = "%s: scan_abort_req_handler done\r\n"
proc abort() =
  logs.setLen(0)
  ke_msg_send(ke_msg_try_alloc(SCAN_ABORT_REQ, TASK_SCAN, HostTask, 0))
  doAssert step()
abort()
doAssert scan_env.abortFlag == 0 and terminations == 0 and logs == @[Done]
discard begin(2)
abort()
doAssert scan_env.abortFlag == 1 and terminations == 0 and logs == @[Done]
startDwell()
doAssert terminations == 1
reset()
discard begin(2)
startDwell()
abort()
doAssert scan_env.abortFlag == 1 and terminations == 1 and queue.len == 1 and logs == @[Done]
reset()
logging = false
abort()
doAssert logs.len == 0
''')


@pytest.mark.parametrize("mode", MODES)
def test_scan_dwell_slot_conversion(tmp_path: Path, mode: str) -> None:
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    run_program(tmp_path, mode, layouts("ChanScanReqPayload") +
                procedure(kernel, "chanScanDurationTicks") + r'''
for (duration, slots) in [(0'u32, 0'u16), (1'u32, 1'u16), (1000'u32, 1'u16),
    (1024'u32, 1'u16), (2047'u32, 1'u16), (2048'u32, 2'u16),
    (220000'u32, 214'u16), (0x03ffffff'u32, 0xffff'u16),
    (0x04000000'u32, 0xffff'u16), (high(uint32), 0xffff'u16)]:
  var request = ChanScanReqPayload(duration: duration)
  doAssert chanScanDurationTicks(addr request) == slots
''')


@pytest.mark.parametrize("mode", MODES)
def test_idle_scan_cancel_confirms_to_requester(tmp_path: Path, mode: str) -> None:
    """Pinned scan_cancel_req_handler: idle confirms with status 1 to the
    requester (scan_send_cancel_cfm(1, src_id)); busy only sets the flag."""
    scan_source = (FW / "scan_station_ap_me.nim").read_text()
    handler_source = (FW / "task_handlers.nim").read_text()
    confirmation = procedure(scan_source, "scan_send_cancel_cfm")
    handler = procedure(handler_source, "scan_cancel_req_handler")
    run_program(tmp_path, mode, r'''
type
  ScanEnv = object
    paramPtr: pointer
    abortFlag: uint8
  MsgHdr = object
    srcId: uint8
  StatusCfmPayload = object
    status: uint8
const
  TASK_SCAN = 1'u8
  ScanIdleState = 0'u8
  SCAN_CANCEL_CFM = 1028'u16
  StatusCfmPayloadSize = 1'u32
  KeMsgConsumed = 0.cint
var
  scan_env: ScanEnv
  requestBody: uint8
  requestHeader = MsgHdr(srcId: 7)
  confirmationBody: StatusCfmPayload
  scanState: uint8
  allocations, sends: int
proc ke_state_get(task: uint8): uint8 =
  doAssert task == TASK_SCAN
  scanState
proc keMsgHdrFromPayload(p: pointer): ptr MsgHdr =
  doAssert p == (addr requestBody)
  addr requestHeader
proc ke_msg_alloc(id: uint16; dest, src: uint8; size: uint32): pointer =
  doAssert id == SCAN_CANCEL_CFM and dest == requestHeader.srcId
  doAssert src == TASK_SCAN and size == StatusCfmPayloadSize
  inc allocations
  addr confirmationBody
proc ke_msg_send(p: pointer) =
  doAssert p == (addr confirmationBody) and confirmationBody.status == 1
  inc sends
''' + confirmation + handler + r'''
doAssert scan_cancel_req_handler(addr requestBody) == KeMsgConsumed
doAssert allocations == 1 and sends == 1 and scan_env.abortFlag == 0
requestHeader.srcId = 9
doAssert scan_cancel_req_handler(addr requestBody) == KeMsgConsumed
doAssert allocations == 2 and sends == 2
for busy in [2'u8, 3]:
  scanState = busy
  scan_env.abortFlag = 0
  doAssert scan_cancel_req_handler(addr requestBody) == KeMsgConsumed
  doAssert allocations == 2 and sends == 2 and scan_env.abortFlag == 1
scan_env.abortFlag = 0
doAssert scan_cancel_req_handler(nil) == KeMsgConsumed
doAssert allocations == 2 and sends == 2 and scan_env.abortFlag == 0
''')


@pytest.mark.parametrize("mode", MODES)
def test_scan_start_confirms_after_channel_request(tmp_path: Path, mode: str) -> None:
    """Pinned scan_start_req_handler submits the first dwell (scan_ie_download)
    before it sends SCAN_START_CFM. A refused request is answered in place,
    as SCAN_START_CFM with BUSY (busy task or slot 3 taken), BAD_PARAM, or
    FAIL (no confirmation or notice memory); the blob allocates that answer
    and frees the request."""
    run_program(tmp_path, mode, harness() + BEGIN + r'''
proc lower(channels = 1): pointer =
  result = ke_msg_try_alloc(SCAN_START_REQ, TASK_SCAN, HostTask, ScanStartReqPayloadSize)
  scanStartReqView(result).channelCount = channels.uint8
proc refuse(request: pointer; status: uint8) =
  doAssert scan_start_req_handler(request) == KeMsgNoFree
  doAssert delivered == @[request] and statusCfmView(request).status == status
  let h = keMsgHdrFromPayload(request)
  doAssert (h.id, h.destId, h.srcId, h.paramLen) == (SCAN_START_CFM, HostTask, TASK_SCAN, 1'u32)
  delivered.setLen(0)
  ke_msg_free(h)

scan_init()
let accepted = lower(2)
doAssert scan_start_req_handler(accepted) == KeMsgNoFree
doAssert events == @["next"] and states[TASK_SCAN] == ScanChannelPendingState
doAssert delivered.len == 1 and delivered[0] != accepted
doAssert statusCfmView(delivered[0]).status == SCAN_STATUS_OK
ke_msg_free(keMsgHdrFromPayload(delivered.pop()))
refuse(lower(), SCAN_STATUS_BUSY)                    # TASK_SCAN busy
scan_init()                                          # answers the admitted one
doAssert delivered == @[accepted] and keMsgHdrFromPayload(accepted).id == SCAN_DONE_IND
ke_msg_free(keMsgHdrFromPayload(delivered.pop()))
scanSlot.slot = 0xFF
slotOn = false
scanSlot.slot = 4
refuse(lower(), SCAN_STATUS_BUSY)                    # slot 3 taken
scanSlot.slot = 0xFF
refuse(lower(0), SCAN_STATUS_BAD_PARAM)
for failing in [SCAN_START_CFM, MM_SCAN_CHANNEL_START_IND, MM_SCAN_CHANNEL_END_IND]:
  failId = failing
  failCount = 1
  refuse(lower(), SCAN_STATUS_FAIL)
  doAssert states[TASK_SCAN] == ScanIdleState and scan_env.paramPtr == nil
doAssert heap.len == 0
''')
