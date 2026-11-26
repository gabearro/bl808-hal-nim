"""Exercise queued station link-loss reports against a BL808 lifetime model."""

from itertools import product
import os
from pathlib import Path
import random

import pytest

from test_wifi_auth_frames import layouts
from test_wifi_disconnect_tx import FW, procedure
from test_wifi_handler_contracts import owned_disconnect_source
from test_wifi_message_allocation import run_program
from test_wifi_saved_reschedule import source as saved_queue_source


PLATFORM = r'''
const
  MM_CONNECTION_LOSS_IND = 0x31'u16
  SM_SA_QUERY_TIMEOUT_IND_MSG = 0x1009'u16
  MmConnectionLossIndPayloadSize = 4'u32
  KeMsgTailSlack = 4'u32
  KeMsgConsumed = 0.cint
  KeMsgSaved = 2.cint
  SmIdleState = 0'u16
  SmDisconnectingState = 10'u16
  VIF_TYPE_STA = 0'u8
type
  Vif = object
    vifIdx, staIdx, vifType, state: uint8
    beaconTimeoutBase: uint32
  Fault = enum
    noFault, oom
  Allocation = tuple[header: pointer, id: int]
var
  vifs: array[MAX_VIFS, Vif]
  rxVifEpochs, mmBeaconProbeEpochs, mmTrafficProbeEpochs: array[MAX_VIFS, uint32]
  stationEpochs: array[4, uint32]
  txResetEpoch, nimFwDbgConnLossInd, nimFwDbgDisconnectProcess: uint32
  sm: tuple[connectInfo, connectIndMsg: pointer, saQueryActive: uint8]
  allocations: seq[Allocation]
  publishingId, dispatchingId: int
  actualDisconnects: seq[int]
  fault: Fault
  mm: tuple[keepAliveLimit: uint32]
  macNow: uint32

const MmConnLossIndSize = sizeof(MmConnLossInd).uint32
proc mm_ap_traffic_probe_cfm*(vifEntry: pointer, status: uint32) {.exportc, cdecl.}
proc mmEnvView(): ptr typeof(mm) = addr mm
proc macTimeNow(): uint32 = macNow
proc txlFrameCallbackCurrent(): bool = true
proc keMsgHdrFromPayload(p: pointer): ptr KeMsgHdr =
  cast[ptr KeMsgHdr](cast[uint](p) - sizeof(KeMsgHdr).uint)
proc mmConnectionLossIndView(p: pointer): ptr MmConnectionLossIndPayload =
  cast[ptr MmConnectionLossIndPayload](p)
proc messageId(header: pointer): int =
  for allocation in allocations:
    if allocation.header == header: return allocation.id
  doAssert false, "queue used a retired allocation"
proc ke_msg_free(p: pointer) =
  for i in 0 ..< allocations.len:
    if allocations[i].header == p:
      allocations.del(i)
      dealloc(p)
      return
  doAssert false, "double free of a link-loss message"
proc ke_msg_free_payload(p: pointer) = ke_msg_free(keMsgHdrFromPayload(p))
proc ke_msg_alloc(id: uint16; dst, src: uint8; length: uint32): pointer =
  let action = fault
  fault = noFault
  if action == oom: return nil
  let header = cast[ptr KeMsgHdr](alloc0(sizeof(KeMsgHdr) + length.int))
  header[] = KeMsgHdr(id: id, destId: dst, srcId: src, paramLen: length)
  allocations.add((cast[pointer](header), publishingId))
  cast[pointer](cast[uint](header) + sizeof(KeMsgHdr).uint)
proc ke_msg_send(p: pointer) =
  let header = keMsgHdrFromPayload(p)
  doAssert header.paramLen == MmConnLossIndSize
  co_list_push_back(addr keMsgQueueSent, cast[ptr CoListHdr](header))
  ke_evt_set(KE_EVT_KE_MESSAGE)
proc vifChannelForIdx(i: uint8): ptr Vif = addr vifs[i]
proc vifChannelAt(p: pointer): ptr Vif = cast[ptr Vif](p)
proc staDeleteEpoch(i: uint8): uint32 =
  if i < stationEpochs.len.uint8: stationEpochs[i] else: 0
proc ke_state_get(task: uint8): uint16 = states[task]
proc sm_connection_tlv_set() = discard
proc smEnvView(): ptr typeof(sm) = addr sm
proc keTimerClearLocked(id: uint16; task: uint8; saved: uint32) =
  doAssert id == SM_SA_QUERY_TIMEOUT_IND_MSG and task == TASK_SM
  irqRestore(saved)
proc smCleanupBegin(vif: pointer; indication: pointer = nil; disconnected = false;
                    status = 0'u16; reason = 0'u16): bool =
  # The cleanup claims the link, then publishes state 10.
  doAssert states[TASK_SM] == SmIdleState and vif == (addr vifs[1])
  doAssert disconnected and indication == nil
  doAssert status in [16'u16, 22] and reason == 0xFFFF
  actualDisconnects.add(dispatchingId)
  ke_state_set(TASK_SM, SmDisconnectingState)
  true
'''


DRIVER = r'''
proc deliverLoss() =
  keResumeSavedMessagesIfIdle()
  let node = co_list_pop_front(addr keMsgQueueSent)
  if node != nil:
    dispatchingId = messageId(node)
    let payload = cast[pointer](cast[uint](node) + sizeof(KeMsgHdr).uint)
    case mm_connection_loss_ind_handler(payload)
    of KeMsgConsumed: ke_msg_free(node)
    of KeMsgSaved: co_list_push_back(addr keMsgQueueSaved, node)
    else: doAssert false, "invalid dispatcher outcome"
  keUpdateMessageEventAfterSchedule()

proc queueIds(queue: CoList): seq[int] =
  var node = queue.first
  while node != nil:
    doAssert result.len < 8, "unexpected queue size or cycle"
    result.add(messageId(node))
    node = node.next

type
  Owner = tuple[association, station, reset, evidence: int]
  Report = tuple[id: int, owner: Owner, beaconProbe: bool]
  Model = object
    current: Owner
    ready, waiting: seq[Report]
    disconnected: seq[int]
    sm: uint16
    nextId: int
    nextFault: Fault

proc ids(reports: seq[Report]): seq[int] =
  for report in reports: result.add(report.id)

proc live(report: Report; now: Owner): bool =
  report.owner.association == now.association and report.owner.station == now.station and
    report.owner.reset == now.reset and
    (not report.beaconProbe or report.owner.evidence == now.evidence)

proc exercise(trace: string; initialBusy: bool): string =
  setup()
  fault = noFault
  actualDisconnects.setLen(0)
  vifs[1] = Vif(vifIdx: 1, staIdx: 2, state: 1)
  keTaskDescs[TASK_SM].stateCount = 11
  defer:
    ke_flush()
    doAssert allocations.len == 0
  var model: Model
  const busy = 1'u16
  proc stateChange(value: uint16; firmwareAlreadyChanged = false) =
    if model.sm != value:
      model.sm = value
      model.ready.add(model.waiting)
      model.waiting.setLen(0)
    if not firmwareAlreadyChanged: ke_state_set(TASK_SM, value)
  if initialBusy: stateChange(busy)
  # Keep at most six live indications so an explicit state transition makes
  # *all* saved indications ready; the queue domain separately tests batching.
  proc deliver() =
    if model.ready.len != 0:
      let pending = model.ready[0]
      model.ready.delete(0)
      if live(pending, model.current):
        if model.sm != SmIdleState:
          model.waiting.add(pending)
        else:
          model.disconnected.add(pending.id)
          stateChange(SmDisconnectingState, firmwareAlreadyChanged = true)
    deliverLoss()
  proc mismatch(): string =
    if actualDisconnects != model.disconnected: return "loss-outcome"
    if states[TASK_SM] != model.sm: return "sm-state"
    if queueIds(keMsgQueueSent) != ids(model.ready) or
        queueIds(keMsgQueueSaved) != ids(model.waiting):
      return "queue-order-or-retirement"
    if allocations.len != model.ready.len + model.waiting.len:
      return "allocation-ownership"
    if not interrupts: return "irq-state"
  proc becomeIdle() =
    if model.sm == SmDisconnectingState:
      inc model.current.association
      inc rxVifEpochs[1]
    stateChange(SmIdleState)
  for event in trace:
    case event
    of 'p', 'l':
      if model.ready.len + model.waiting.len >= 6: continue
      let report: Report = (model.nextId, model.current, event == 'p')
      inc model.nextId
      let action = model.nextFault
      model.nextFault = noFault
      if action != oom: model.ready.add(report)
      publishingId = report.id
      if event == 'p':
        var epoch = mmBeaconProbeEpochs[1]
        mmPublishConnectionLoss(addr vifs[1], 16, addr epoch)
      else:
        mm_send_connection_loss_ind(addr vifs[1], 22)
    of 'd': deliver()
    of 'b':
      if model.sm == SmIdleState: stateChange(busy)
    of 'i': becomeIdle()
    of 'h':
      inc model.current.evidence
      inc mmBeaconProbeEpochs[1]
    of 'u': inc mmBeaconProbeEpochs[0]
    of 'v':
      inc model.current.association
      inc rxVifEpochs[1]
    of 's':
      inc model.current.station
      inc stationEpochs[2]
    of 'o':
      fault = oom
      model.nextFault = fault
    of 'r':
      inc model.current.reset
      inc txResetEpoch
      ke_flush()
      model.ready.setLen(0)
      model.waiting.setLen(0)
      stateChange(SmIdleState)
    else: doAssert false
    let issue = mismatch()
    if issue != "": return issue
  # Fair delivery: no new faults, publication or retirement.
  for _ in 0 .. 12:
    becomeIdle()
    deliver()
    let issue = mismatch()
    if issue != "": return issue
    if model.ready.len + model.waiting.len == 0:
      if wifiMessagePendingWork(): return "event-left-pending"
      return ""
  "fair-delivery-stalled"

proc check(trace: string; initialBusy: bool) =
  let issue = exercise(trace, initialBusy)
  if issue == "": return
  var minimal = trace
  var i = 0
  while i < minimal.len:
    let candidate = minimal[0 ..< i] & minimal[i + 1 .. ^1]
    if exercise(candidate, initialBusy) == issue: minimal = candidate
    else: inc i
  doAssert false, issue & " initialBusy=" & $initialBusy &
    " trace=" & trace & " minimized=" & minimal
'''


def loss_firmware_source(mutation: bool = False) -> str:
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    tasks = (FW / "task_handlers.nim").read_text()
    fixture = saved_queue_source().replace("    destId, srcId: uint8\n",
                                          "    destId, srcId: uint8\n    paramLen: uint32\n")
    fixture = fixture.replace("proc ke_msg_free(p: pointer) = inc freed\n",
                              "proc ke_msg_free(p: pointer)\n")
    # owned_disconnect_source below supplies the real smAbandon.
    fixture = fixture.replace("proc smAbandon() = discard\n", "proc smAbandon()\n")
    current = procedure(kernel, "mmConnLossCurrent")
    if mutation:
        old = (" and\n    (not ind.tracksProbe or\n"
               "     mmConnLossProbeEpoch(ind.wire.reason, index) == ind.probeEpoch)")
        assert current.count(old) == 1
        current = current.replace(old, "")
    source = fixture + layouts("MmVifIdentity", "MmConnectionLossIndPayload", "MmConnLossInd") + PLATFORM
    source += "".join(procedure(kernel, name) for name in
                      ("mmCaptureVif", "mmVifCurrent", "mmConnLossProbeEpoch"))
    source += current + procedure(kernel, "mmPublishConnectionLoss")
    source += procedure(kernel, "mm_send_connection_loss_ind")
    source += procedure((FW / "power_save.nim").read_text(), "mm_ap_traffic_probe_cfm")
    source += owned_disconnect_source()
    source += procedure(tasks, "mm_connection_loss_ind_handler") + DRIVER
    return source


def test_traffic_ack_retires_only_matching_loss(tmp_path: Path) -> None:
    run_program(tmp_path, "firmware", loss_firmware_source() + r'''
proc checkTrafficLoss(recovery: int; saved: bool) =
  setup()
  actualDisconnects.setLen(0)
  vifs[0] = Vif(vifIdx: 0, staIdx: 1, state: 1)
  vifs[1] = Vif(vifIdx: 1, staIdx: 2, state: 1)
  keTaskDescs[TASK_SM].stateCount = 11
  defer:
    ke_flush()
    doAssert allocations.len == 0
  if saved: ke_state_set(TASK_SM, 1)
  mm.keepAliveLimit = 0
  publishingId = 140
  mm_ap_traffic_probe_cfm(addr vifs[1], 0x80010700'u32)
  doAssert queueIds(keMsgQueueSent) == @[140] and mm.keepAliveLimit == 10
  if saved:
    deliverLoss()
    doAssert queueIds(keMsgQueueSaved) == @[140]
  macNow = 100
  case recovery
  of 1: mm_ap_traffic_probe_cfm(addr vifs[1], 0x80800000'u32)
  of 2: mm_ap_traffic_probe_cfm(addr vifs[0], 0x80800000'u32)
  of 3: inc mmBeaconProbeEpochs[1]
  else: discard
  if recovery == 1:
    doAssert vifs[1].beaconTimeoutBase == macNow and mm.keepAliveLimit == 10
  if saved: ke_state_set(TASK_SM, SmIdleState)
  deliverLoss()
  if recovery == 1:
    doAssert actualDisconnects.len == 0, "fresh traffic ACK did not retire queued loss"
    doAssert states[TASK_SM] == SmIdleState
  else:
    doAssert actualDisconnects == @[140], "retired loss without a matching traffic ACK"
  doAssert allocations.len == 0
  doAssert not wifiMessagePendingWork()

for saved in [false, true]:
  for recovery in 0 .. 3:
    checkTrafficLoss(recovery, saved)
''')


@pytest.mark.parametrize("mutation", [False, True], ids=["firmware", "stale-probe"])
def test_station_loss_queue_model(tmp_path: Path, mutation: bool) -> None:
    source = loss_firmware_source(mutation)
    seed = int(os.environ.get("BL808_WIFI_MODEL_SEED", "808"))
    steps = int(os.environ.get("BL808_WIFI_MODEL_STEPS", "256"))
    rng = random.Random(seed ^ 0x4C4F5353)
    short = [(f"p{''.join(suffix)}", busy) for busy in (False, True)
             for n in range(4) for suffix in product("dhbuivsrl", repeat=n)]
    random_cases = [("".join(rng.choices("ppllddddhbisvruo", k=rng.randint(8, 64))),
                     bool(rng.getrandbits(1)))
                    for _ in range(steps)]
    source += f'echo "link loss seed={seed} cases={len(short) + len(random_cases)}"\n'
    source += "\n".join(f'check("{trace}", {str(busy).lower()})'
                        for trace, busy in short + random_cases)
    if mutation:
        with pytest.raises(AssertionError, match=r"loss-outcome.*minimized="):
            run_program(tmp_path, "firmware", source)
    else:
        run_program(tmp_path, "firmware", source)
