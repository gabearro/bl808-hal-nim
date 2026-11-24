"""Exercise the station-manager/MM registration exchange and reply ownership."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_join_registration import submission_source
from test_wifi_message_allocation import run_program


def source() -> str:
    code = submission_source()
    layout = (FW / "layout_types.nim").read_text()
    declaration = "  MmStaAddCfmPayload" + layout.split("  MmStaAddCfmPayload", 1)[1].split("\n\n  ", 1)[0]
    code = code.replace("type\n", "type\n" + declaration + "\n", 1)
    code = code.replace("    ampduParams: uint8", "    ampduParams: uint8\n    storage: array[32, uint8]", 1)
    code = code.replace("    channelFreqPair: uint32", "    channelFreqPair: uint32\n    basicRates: array[13, uint8]", 1)
    code = code.replace("size == sizeof(MmStaAddReqPayload).uint32", "size >= sizeof(MmStaAddReqPayload).uint32", 1)
    code = code.replace("  else:\n    doAssert id in [SCANU_START_CFM, SCANU_JOIN_CFM]", """  elif id == 11:
    doAssert dst in [4'u8, 9'u8] and src in [0'u8, 7'u8] and size >= 3
  else:
    doAssert id in [SCANU_START_CFM, SCANU_JOIN_CFM]""", 1)
    code = code.replace(procedure(code, "staDeleteEpoch"), """
proc staDeleteEpoch(index: uint8): uint32 =
  if index < 5: stationEpochs[index] else: 0
""", 1)
    code = "var stationEpochs: array[5, uint32]\n" + code
    support = r'''
const
  STA_MGMT_FREE_STAS = 5
  STA_INFO_TAB_ENTRIES = 7
  MM_STA_ADD_CFM = 11'u16
  MmStaAddCfmPayloadSize = 3'u32
type Station = object
  valid, instNbr, infoIdx: uint8
  supportedRates: array[13, uint8]
  capabilityFlags: uint32
  vhtCaps: array[32, uint8]
var
  stations: array[5, Station]
  registrations, deletions, bssCalls, htCalls: int
  registerStatus: uint8
  onRegister, onRegistered, onHt, onBss, onDelete: proc()
  nimFwDbgPreauthStaCfm, nimFwDbgPreauthStaCfmMeta: uint32
proc staInfoForIdx(index: uint8): ptr Station =
  doAssert index < stations.len.uint8
  addr stations[index]
proc staDeleteIsCurrent(index: uint8; epoch: uint32): bool =
  index < 5 and stations[index].valid != 0 and stationEpochs[index] == epoch
proc mm_sta_del(index: uint8) =
  doAssert index < 5 and stations[index].valid != 0
  inc deletions
  let vif = stations[index].instNbr
  stations[index].valid = 0
  inc stationEpochs[index]
  if vifs[vif].staIdx == index: vifs[vif].staIdx = 255
  invoke(onDelete)
proc mm_sta_add(request: pointer; logical, hardware: ptr uint8): uint8 =
  inc registrations
  logical[] = 255
  hardware[] = 255
  invoke(onRegister)
  if registerStatus != 0: return registerStatus
  let vif = cast[ptr MmStaAddReqPayload](request).vifIdx
  for index in 0'u8 ..< 5:
    if stations[index].valid == 0:
      stations[index] = Station(valid: 1, instNbr: vif, infoIdx: index)
      vifs[vif].staIdx = index
      logical[] = index
      hardware[] = index + 8
      invoke(onRegistered)
      return 0
  1
proc me_set_sta_ht_vht_param(station, caps: pointer) =
  let index = cast[ptr Station](station).instNbr
  doAssert caps == cast[pointer](addr vifs[index].ht)
  inc htCalls
  invoke(onHt)
proc sm_set_bss_param() =
  inc bssCalls
  state = 4
  invoke(onBss)
'''
    module = FW / "station_registration.nim"
    if module.exists():
        for name in ["smRegistrationAllocate", "smRegistrationPublish", "smRegistrationOwnChannel"]:
            if f"proc {name}(" in code:
                declaration = {
                    "smRegistrationAllocate": "proc smRegistrationAllocate(owner: SmTxBuildContext; indication: pointer): pointer\n",
                    "smRegistrationPublish": "proc smRegistrationPublish(request: pointer): bool\n",
                    "smRegistrationOwnChannel": "proc smRegistrationOwnChannel(request: pointer; lease: var ChanCtxtLease): bool\n",
                }[name]
                code = code.replace(procedure(code, name), declaration, 1)
        code = code.replace("  smScanForget(p)\n", "  smRegistrationForget(p)\n  smScanForget(p)\n", 1)
        code = code.replace("proc resetScanTracking()\n", "proc resetScanTracking()\nproc smRegistrationForget(header: pointer)\n", 1)
        owner = (FW / "station_tx_build.nim").read_text()
        support += procedure(owner, "smTxBindStation")
        support += "\n{.pragma: wifiCtrl.}\n" + module.read_text()
        support += r'''
var chanTbttTimerOwner, chanConnlessTimerOwner: tuple[valid: bool, resetEpoch: uint32]
var failChannelReset: bool
proc mm_force_idle_req(): bool =
  doAssert not enabled
  inc txResetEpoch
  not failChannelReset
'''
        support += procedure((FW / "channel_timer.nim").read_text(), "chanForceIdle")
    tasks = (FW / "task_handlers.nim").read_text()
    code += support + procedure(tasks, "mm_sta_add_req_handler") + procedure(tasks, "mm_sta_add_cfm_handler")
    return code + r'''
proc issue(): pointer =
  let reply = ready()
  doAssert scanu_join_cfm_handler(reply) == 0
  release(reply)
  doAssert state == 3 and queued.len == 1
  take()
proc completeRegistration(request: pointer): pointer =
  doAssert mm_sta_add_req_handler(request) == 0
  release(request)
  if queued.len != 0:
    doAssert queued.len == 1
    result = take()
proc finishExchange() =
  smRegistrationService()
  finish()
  doAssert smRegistrationTags == nil and not smRegistrationNeedsService()
proc resetExchange() =
  doAssert smRegistrationTags == nil and not smRegistrationNeedsService()
  stations = default(typeof(stations))
  registrations = 0
  deletions = 0
  bssCalls = 0
  htCalls = 0
  registerStatus = 0
  failChannelReset = false
  onRegister = nil
  onRegistered = nil
  onHt = nil
  onBss = nil
  onDelete = nil
'''


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_unrelated_registration_confirmation(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
setup()
state = 3
stations[0] = Station(valid: 1, instNbr: conn.vifIdx)
vifs[conn.vifIdx].staIdx = 0
var unrelated = MmStaAddCfmPayload(status: 0, staIdx: 0, hwStaIdx: 8)
doAssert mm_sta_add_cfm_handler(addr unrelated) == 0
doAssert bssCalls == 0 and state == 3
''')


CASES = {
    "channel_reset_before_request_or_reply": r'''
for beforeReply in [false, true]:
  for resetKind in 0..4:
    resetExchange()
    let request = issue()
    var reply = if beforeReply: completeRegistration(request) else: nil
    if beforeReply: doAssert reply != nil
    case resetKind
    of 0:
      doAssert chanForceIdle()
    of 1:
      inc txResetEpoch
    of 2:
      inc txResetEpoch
      doAssert chanForceIdle()
    of 3:
      failChannelReset = true
      doAssert not chanForceIdle()
    else:
      replaceOwner()
      doAssert chanForceIdle()
    if not beforeReply: reply = completeRegistration(request)
    if reply != nil:
      doAssert mm_sta_add_cfm_handler(reply) == 0
      release(reply)
    # Only a replaced owner (kind 4) ends the exchange; a TX reset does not.
    doAssert bssCalls == (if resetKind != 4: 1 else: 0)
    doAssert registrations == (if beforeReply or resetKind != 4: 1 else: 0)
    finishExchange()
''',
    "reserved_completion": r'''
resetExchange()
let request = issue()
let count = allocations
failAlloc = true
let reply = completeRegistration(request)
doAssert reply != nil and allocations == count and registrations == 1
doAssert keMsgHdrFromPayload(reply).paramLen == 3
doAssert mm_sta_add_cfm_handler(reply) == 0 and bssCalls == 1 and state == 4
release(reply)
doAssert deletions == 0
finishExchange()
''',
    "stale_queued_request": r'''
resetExchange()
let request = issue()
replaceOwner()
doAssert completeRegistration(request) == nil
doAssert registrations == 0 and failures.len == 0
finishExchange()
''',
    "replacement_during_registration": r'''
resetExchange()
let request = issue()
onRegistered = replaceOwner
doAssert completeRegistration(request) == nil
doAssert registrations == 1 and bssCalls == 0
smRegistrationService()
doAssert deletions == 1 and failures.len == 0
finishExchange()
''',
    "stale_reply": r'''
resetExchange()
let reply = completeRegistration(issue())
replaceOwner()
doAssert mm_sta_add_cfm_handler(reply) == 0 and bssCalls == 0
release(reply)
smRegistrationService()
doAssert deletions == 1 and failures.len == 0
finishExchange()
''',
    "recycled_station": r'''
resetExchange()
let reply = completeRegistration(issue())
inc stationEpochs[0]
stations[0].capabilityFlags = 0xABCD
doAssert mm_sta_add_cfm_handler(reply) == 0 and bssCalls == 0
release(reply)
smRegistrationService()
doAssert deletions == 0 and stations[0].valid == 1
doAssert stations[0].capabilityFlags == 0xABCD
finishExchange()
''',
    "lost_request": r'''
resetExchange()
release(issue())
doAssert smRegistrationNeedsService()
smRegistrationService()
smRegistrationService()
doAssert failures == @[(15'u16, 0xFFFF'u16)] and registrations == 0
finishExchange()
''',
    "lost_reply": r'''
resetExchange()
release(completeRegistration(issue()))
smRegistrationService()
smRegistrationService()
doAssert failures == @[(15'u16, 0xFFFF'u16)] and deletions == 1
finishExchange()
''',
    "registration_failure": r'''
resetExchange()
let request = issue()
registerStatus = 7
let reply = completeRegistration(request)
doAssert mm_sta_add_cfm_handler(reply) == 0
doAssert mm_sta_add_cfm_handler(reply) == 0
doAssert failures == @[(15'u16, 0xFFFF'u16)] and bssCalls == 0
release(reply)
doAssert deletions == 0
finishExchange()
''',
    "one_shot_reply": r'''
resetExchange()
let reply = completeRegistration(issue())
doAssert mm_sta_add_cfm_handler(reply) == 0 and bssCalls == 1
state = 3
doAssert mm_sta_add_cfm_handler(reply) == 0 and bssCalls == 1
release(reply)
doAssert deletions == 0
finishExchange()
''',
    "reply_fields": r'''
for mutation in 0 .. 5:
  resetExchange()
  let reply = completeRegistration(issue())
  let header = keMsgHdrFromPayload(reply)
  case mutation
  of 0: inc header.id
  of 1: header.srcId = 2
  of 2: header.destId = 9
  of 3: header.paramLen = 2
  of 4: cast[ptr MmStaAddCfmPayload](reply).staIdx = 255
  else: cast[ptr MmStaAddCfmPayload](reply).hwStaIdx = 255
  doAssert mm_sta_add_cfm_handler(reply) == 0 and bssCalls == 0
  release(reply)
  smRegistrationService()
  doAssert deletions == 1 and failures == @[(15'u16, 0xFFFF'u16)]
  finishExchange()
''',
    "ht_callback_replacement": r'''
resetExchange()
let reply = completeRegistration(issue())
onHt = replaceOwner
doAssert mm_sta_add_cfm_handler(reply) == 0 and bssCalls == 0 and htCalls == 1
release(reply)
smRegistrationService()
doAssert deletions == 1 and failures.len == 0
finishExchange()
''',
    "handoff_callback": r'''
resetExchange()
let reply = completeRegistration(issue())
onBss = replaceOwner
doAssert mm_sta_add_cfm_handler(reply) == 0 and bssCalls == 1
release(reply)
doAssert not smRegistrationNeedsService() and deletions == 0
finishExchange()
''',
    "reply_reservation_failure": r'''
resetExchange()
let reply = ready()
onAlloc = proc() = failAlloc = true
doAssert scanu_join_cfm_handler(reply) == 0
doAssert queued.len == 0 and registrations == 0 and contextAdds == 0
doAssert failures == @[(14'u16, 0xFFFF'u16)]
release(reply)
finishExchange()
''',
    "reply_reservation_replacement": r'''
resetExchange()
let reply = ready()
onAlloc = proc() = onAlloc = replaceOwner
doAssert scanu_join_cfm_handler(reply) == 0
doAssert queued.len == 0 and failures.len == 0 and contextAdds == 0
release(reply)
finishExchange()
''',
    "synchronous_exchange": r'''
resetExchange()
let scanReply = ready()
onSend = proc() =
  let reply = completeRegistration(take())
  doAssert mm_sta_add_cfm_handler(reply) == 0
  release(reply)
doAssert scanu_join_cfm_handler(scanReply) == 0
doAssert state == 4 and bssCalls == 1 and registrations == 1
release(scanReply)
finishExchange()
''',
    "untagged_api_request": r'''
resetExchange()
setup()
let request = ke_msg_alloc(MM_STA_ADD_REQ, TASK_MM, TASK_SM, MmStaAddReqPayloadSize)
cast[ptr MmStaAddReqPayload](request).vifIdx = conn.vifIdx
keMsgHdrFromPayload(request).srcId = 9
let reply = completeRegistration(request)
doAssert keMsgHdrFromPayload(reply).destId == 9 and registrations == 1
release(reply)
doAssert deletions == 0
finishExchange()
''',
    "untagged_forwarded_request": r'''
resetExchange()
setup()
let request = ke_msg_alloc(MM_STA_ADD_REQ, TASK_MM, TASK_SM, MmStaAddReqPayloadSize)
cast[ptr MmStaAddReqPayload](request).vifIdx = conn.vifIdx
let header = keMsgHdrFromPayload(request)
header.srcId = 9
header.destId = 7
let reply = completeRegistration(request)
doAssert reply != nil and registrations == 1
doAssert keMsgHdrFromPayload(reply).destId == 9
doAssert keMsgHdrFromPayload(reply).srcId == 7
release(reply)
doAssert deletions == 0
finishExchange()
''',
    "request_fields": r'''
for mutation in 0 .. 4:
  resetExchange()
  let request = issue()
  let header = keMsgHdrFromPayload(request)
  case mutation
  of 0: inc header.id
  of 1: header.srcId = 9
  of 2: header.destId = 9
  of 3: header.paramLen = 2
  else: cast[ptr MmStaAddReqPayload](request).vifIdx = 255
  doAssert completeRegistration(request) == nil and registrations == 0
  smRegistrationService()
  doAssert failures == @[(15'u16, 0xFFFF'u16)]
  finishExchange()
''',
    "duplicate_request": r'''
resetExchange()
let request = issue()
doAssert mm_sta_add_req_handler(request) == 0
doAssert mm_sta_add_req_handler(request) == 0
doAssert registrations == 1 and queued.len == 1
release(request)
let reply = take()
doAssert mm_sta_add_cfm_handler(reply) == 0 and bssCalls == 1
release(reply)
finishExchange()
''',
    "station_recycled_during_registration": r'''
resetExchange()
let request = issue()
onRegistered = proc() =
  inc stationEpochs[0]
  stations[0].capabilityFlags = 0x1234
let reply = completeRegistration(request)
doAssert cast[ptr MmStaAddCfmPayload](reply).status != 0
doAssert mm_sta_add_cfm_handler(reply) == 0
release(reply)
doAssert deletions == 0 and stations[0].capabilityFlags == 0x1234
finishExchange()
''',
    "older_reply_does_not_replace_pending_cleanup": r'''
resetExchange()
let oldReply = completeRegistration(issue())
stations[0].valid = 0
inc stationEpochs[0]
vifs[conn.vifIdx].staIdx = 255
state = SmWaitingState
sm_join_bss(addr localMac[0], addr target[0], addr channel, true)
let scanReply = complete(take())
doAssert scanu_join_cfm_handler(scanReply) == 0
release(scanReply)
let newReply = completeRegistration(take())
release(newReply)
release(oldReply)
smRegistrationService()
doAssert deletions == 1 and stations[0].valid == 0
doAssert failures == @[(15'u16, 0xFFFF'u16)]
finishExchange()
''',
    "cleanup_callback_replaces_connection": r'''
resetExchange()
release(completeRegistration(issue()))
onDelete = replaceOwner
smRegistrationService()
doAssert deletions == 1 and failures.len == 0 and state == 6
finishExchange()
''',
    "interrupt_state": r'''
for incoming in [false, true]:
  resetExchange()
  let request = issue()
  enabled = incoming
  let reply = completeRegistration(request)
  doAssert enabled == incoming
  doAssert mm_sta_add_cfm_handler(reply) == 0
  doAssert enabled == incoming
  release(reply)
  finishExchange()
''',
}


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("case", CASES)
def test_registration_exchange(tmp_path: Path, mode: str, case: str) -> None:
    run_program(tmp_path, mode, source() + CASES[case])


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_main_loop_services_lost_registration(tmp_path: Path, mode: str) -> None:
    code = source() + r'''
proc wifiEventPendingWork(): bool = false
proc wifiKernelTimerPendingWork(): bool = false
proc wifiMmTimerPendingWork(): bool = false
proc wifiMessagePendingWork(): bool = false
proc wifiResetEventPending(): bool = false
proc smBssNeedsService(): bool = false
proc smCleanupNeedsService(): bool = false
proc smActivationNeedsService(): bool = false
proc smBssService() = discard
proc smCleanupService() = discard
proc smActivationService() = discard
proc wifiDispatchScheduledEvent(): bool = false
'''
    runtime = (FW / "task_init_main.nim").read_text()
    code += procedure(runtime, "wifiMainHasPendingWork") + procedure(runtime, "wifiDrainScheduledWork")
    run_program(tmp_path, mode, code + r'''
resetExchange()
release(issue())
doAssert wifiMainHasPendingWork()
doAssert wifiDrainScheduledWork()
doAssert not wifiMainHasPendingWork()
doAssert failures == @[(15'u16, 0xFFFF'u16)]
finishExchange()
''')


def test_registration_message_release_hooks() -> None:
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    sender = procedure(kernel, "ke_msg_send")
    assert "smRegistrationForget(param)" in procedure(kernel, "ke_msg_free")
    assert sender.index("smRegistrationForget(cast[pointer](hdr))") < sender.index("opsFn(cast[pointer](hdr))")
    assert "smRegistrationAdmitRequest(param)" in procedure(kernel, "mm_sta_add")
