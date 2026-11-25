"""Exercise the station-manager/MM registration exchange and reply ownership."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import FW, procedure, station_sm_source
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
    code = "var stationEpochs: array[5, uint32]\n" + code
    support = r'''
const
  STA_MGMT_FREE_STAS = 5
  STA_INFO_TAB_ENTRIES = 7
  MM_STA_ADD_CFM = 11'u16
  MmStaAddCfmPayloadSize = 3'u32
type Station = object
  valid, instNbr, infoIdx: uint8
  listed: bool  ## on its VIF's station list (vif_mgmt_unregister clears it)
  supportedRates: array[13, uint8]
  capabilityFlags: uint32
  vhtCaps: array[32, uint8]
var
  stations: array[5, Station]
  registrations, deletions, unlistedDeletes, bssCalls, htCalls: int
  registerStatus: uint8
  onRegister, onRegistered, onHt, onBss, onDelete: proc()
  nimFwDbgPreauthStaCfm, nimFwDbgPreauthStaCfmMeta: uint32
proc staInfoForIdx(index: uint8): ptr Station =
  doAssert index < stations.len.uint8
  addr stations[index]
proc staDeleteEpoch(index: uint8): uint32 =
  if index < 5: stationEpochs[index] else: 0
proc staDeleteIsCurrent(index: uint8; epoch: uint32): bool =
  index < 5 and stations[index].valid != 0 and stationEpochs[index] == epoch
proc mm_sta_del(index: uint8) =
  doAssert index < 5 and stations[index].valid != 0
  if not stations[index].listed:
    # A station of a removed VIF is on no list: MM's delete is done and
    # leaves it valid (mmStaDelTry; test_wifi_station_lifetime).
    inc unlistedDeletes
    return
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
      stations[index] = Station(valid: 1, instNbr: vif, infoIdx: index, listed: true)
      vifs[vif].staIdx = index
      logical[] = index
      hardware[] = index + 8
      invoke(onRegistered)
      return 0
  1
proc sm_set_bss_param() =
  inc bssCalls
  state = 4
  invoke(onBss)
proc me_set_sta_ht_vht_param(station, caps: pointer) =
  let index = cast[ptr Station](station).instNbr
  doAssert caps == cast[pointer](addr vifs[index].ht)
  inc htCalls
  invoke(onHt)
'''
    support += (FW / "station_registration.nim").read_text()
    tasks = (FW / "task_handlers.nim").read_text()
    code += support + procedure(tasks, "mm_sta_add_req_handler") + procedure(tasks, "mm_sta_add_cfm_handler")
    code += station_sm_source("smAbandon", "smStaVifRetired", record=False)
    return code + r'''
proc parkedMessage(size: int): pointer =
  ## A message SM keeps, tracked as the fixture's allocator tracks one.
  let header = cast[ptr Header](alloc0(sizeof(Header) + size))
  live.add(header)
  cast[pointer](cast[uint](header) + sizeof(Header).uint)
proc allocateAttempt() =
  ## The attempt's SM_CONNECT_REQ and SM_CONNECT_IND as allocated messages,
  ## which smAbandon frees.
  let info = parkedMessage(sizeof(ConnectInfoView))
  cast[ptr ConnectInfoView](info)[] = connectInfoView(sm.connectInfo)[]
  sm.connectInfo = info
  sm.connectIndMsg = parkedMessage(4)
proc removeVif(readded = false) =
  ## vif_mgmt_unregister frees the attempt's STA VIF and tells SM; the host
  ## may register a STA VIF at the same index again.
  let index = conn.vifIdx
  vifs[index] = Vif(vifIdx: 127, vifType: 4, staIdx: 0xFF)
  for station in stations.mitems:
    if station.valid != 0 and station.instNbr == index: station.listed = false
  smStaVifRetired(index)
  if readded: vifs[index] = Vif(vifIdx: index, staIdx: 0xFF)
proc issue(): pointer =
  let reply = ready()
  doAssert scanu_join_cfm_handler(reply) == 0
  release(reply)
  doAssert state == 3 and queued.len == 1
  take()
proc completeRegistration(request: pointer): pointer =
  ## MM handles the request; returns the answer queued for SM, if any.
  let handled = mm_sta_add_req_handler(request)
  if handled == KeMsgNoFree:
    doAssert queued.len == 1
    result = take()
    doAssert result == request, "SM's request was not answered in place"
  else:
    doAssert handled == KeMsgConsumed
    release(request)
    if queued.len != 0:
      doAssert queued.len == 1
      result = take()
proc finishExchange() =
  finish()
proc resetExchange() =
  stations = default(typeof(stations))
  registrations = 0
  deletions = 0
  unlistedDeletes = 0
  bssCalls = 0
  htCalls = 0
  registerStatus = 0
  onRegister = nil
  onRegistered = nil
  onHt = nil
  onBss = nil
  onDelete = nil
'''


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_unrelated_registration_confirmation(tmp_path: Path, mode: str) -> None:
    """An MM_STA_ADD_CFM that is not SM's live answer changes nothing; one
    without the station epoch (the pinned three-byte form) deletes nothing."""
    run_program(tmp_path, mode, source() + r'''
setup()
state = 3
stations[0] = Station(valid: 1, instNbr: conn.vifIdx)
vifs[conn.vifIdx].staIdx = 0
let unrelated = ke_msg_alloc(MM_STA_ADD_CFM, TASK_SM, TASK_MM, MmStaAddCfmPayloadSize)
cast[ptr MmStaAddCfmPayload](unrelated)[] = MmStaAddCfmPayload(status: 0, staIdx: 0, hwStaIdx: 8)
doAssert mm_sta_add_cfm_handler(unrelated) == 0
doAssert bssCalls == 0 and state == 3 and deletions == 0 and stations[0].valid == 1
release(unrelated)
''')


CASES = {
    "only_a_new_operation_ends_the_exchange": r'''
# A TX reset or channel switch is not SM's operation; only SM changing state
# makes the request or its answer stale.
for beforeReply in [false, true]:
  for replaced in [false, true]:
    resetExchange()
    let request = issue()
    var reply = if beforeReply: completeRegistration(request) else: nil
    if replaced: replaceOwner()
    if not beforeReply: reply = completeRegistration(request)
    if reply != nil:
      doAssert mm_sta_add_cfm_handler(reply) == 0
      release(reply)
    doAssert bssCalls == (if replaced: 0 else: 1)
    # A request SM no longer waits on is not applied; a station registered
    # for an answer SM no longer waits on is deleted.
    doAssert registrations == (if beforeReply or not replaced: 1 else: 0)
    doAssert deletions == (if beforeReply and replaced: 1 else: 0)
    doAssert failures.len == 0
    finishExchange()
''',
    "answer_needs_no_allocation": r'''
resetExchange()
let request = issue()
let count = allocations
failAlloc = true
let reply = completeRegistration(request)
doAssert reply == request and allocations == count and registrations == 1
doAssert keMsgHdrFromPayload(reply).id == MM_STA_ADD_CFM
doAssert keMsgHdrFromPayload(reply).srcId == TASK_MM and keMsgHdrFromPayload(reply).destId == TASK_SM
doAssert keMsgHdrFromPayload(reply).paramLen == sizeof(SmStaAddAnswer).uint32
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
    "stale_reply": r'''
for status in [0'u8, 7'u8]:
  resetExchange()
  registerStatus = status
  let reply = completeRegistration(issue())
  replaceOwner()
  doAssert mm_sta_add_cfm_handler(reply) == 0 and bssCalls == 0
  release(reply)
  doAssert deletions == (if status == 0: 1 else: 0) and failures.len == 0
  finishExchange()
''',
    "recycled_station": r'''
for live in [false, true]:
  resetExchange()
  let reply = completeRegistration(issue())
  inc stationEpochs[0]
  stations[0].capabilityFlags = 0xABCD
  if not live: replaceOwner()
  doAssert mm_sta_add_cfm_handler(reply) == 0 and bssCalls == 0
  release(reply)
  # The station is no longer the one MM registered: nothing is deleted, and
  # the live attempt fails.
  doAssert deletions == 0 and stations[0].valid == 1
  doAssert stations[0].capabilityFlags == 0xABCD
  doAssert failures == (if live: @[(15'u16, 0xFFFF'u16)] else: @[])
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
# Taking the answer ends the wait (a message is delivered once).
resetExchange()
let reply = completeRegistration(issue())
doAssert smAwaits(reply)
doAssert mm_sta_add_cfm_handler(reply) == 0 and bssCalls == 1
doAssert not smAwaits(reply) and smOwn.request == nil
release(reply)
doAssert deletions == 0
finishExchange()
''',
    "answer_fields": r'''
for mutation in 0 .. 1:
  resetExchange()
  let reply = completeRegistration(issue())
  case mutation
  of 0: keMsgHdrFromPayload(reply).paramLen = MmStaAddCfmPayloadSize
  else: cast[ptr MmStaAddCfmPayload](reply).staIdx = 255
  doAssert mm_sta_add_cfm_handler(reply) == 0 and bssCalls == 0
  release(reply)
  doAssert failures == @[(15'u16, 0xFFFF'u16)]
  finishExchange()
''',
    "handoff_callback": r'''
resetExchange()
let reply = completeRegistration(issue())
onBss = replaceOwner
doAssert mm_sta_add_cfm_handler(reply) == 0 and bssCalls == 1
release(reply)
doAssert deletions == 0
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
doAssert keMsgHdrFromPayload(reply).paramLen == MmStaAddCfmPayloadSize
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
    "host_request_allocation_failure": r'''
# The blob allocates the host's confirmation first; without one nothing is applied.
resetExchange()
setup()
let request = ke_msg_alloc(MM_STA_ADD_REQ, TASK_MM, TASK_SM, MmStaAddReqPayloadSize)
keMsgHdrFromPayload(request).srcId = 9
failAlloc = true
doAssert completeRegistration(request) == nil and registrations == 0
finishExchange()
''',
    "older_reply_does_not_delete_a_newer_station": r'''
resetExchange()
let oldReply = completeRegistration(issue())
# The cleanup of that attempt deleted its station; a new attempt joins.
stations[0].valid = 0
inc stationEpochs[0]
vifs[conn.vifIdx].staIdx = 255
state = SmWaitingState
sm_join_bss(addr localMac[0], addr target[0], addr channel, true)
let scanReply = complete(take())
doAssert scanu_join_cfm_handler(scanReply) == 0
release(scanReply)
let newReply = completeRegistration(take())
doAssert stations[0].valid == 1
doAssert mm_sta_add_cfm_handler(oldReply) == 0
release(oldReply)
doAssert deletions == 0 and stations[0].valid == 1 and bssCalls == 0
doAssert mm_sta_add_cfm_handler(newReply) == 0 and bssCalls == 1
release(newReply)
doAssert failures.len == 0
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


def test_registration_answer_replaces_the_loss_machinery() -> None:
    """MM answers SM's request in place and checks SM only at handler
    entry; nothing forgets, records or services a lost registration."""
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    sender = procedure(kernel, "ke_msg_send")
    # A message delivered to the host is retired by ke_msg_free.
    assert "ke_msg_free(hdr)" in sender.split("bl_rx_e2a_handler(", 1)[1]
    assert "smRegistration" not in procedure(kernel, "ke_msg_free")
    assert "smRegistration" not in procedure(kernel, "mm_sta_add")
    handler = procedure((FW / "task_handlers.nim").read_text(), "mm_sta_add_req_handler")
    assert "requester == TASK_SM and not smAwaits(param)" in handler
    assert "smStaAddAnswer(param, status, staIdx, hwStaIdx)" in handler
    sources = "".join(path.read_text() for path in FW.rglob("*.nim"))
    for gone in ["smRegistrationForget", "smRegistrationNeedsService", "smRegistrationService",
                 "smRegistrationTags", "smRegistrationLoss", "smRegistrationChannels"]:
        assert gone not in sources, gone
