"""Exercise reconnect admission and the existing ME/MM cleanup transaction."""

from pathlib import Path

import pytest

from test_wifi_connect_rx_epoch import PLATFORM
from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program
from test_wifi_sm_cleanup import CASES as CLEANUP_CASES, DRIVER, program as cleanup_program


def admission_source() -> str:
    code = PLATFORM + r'''
var cleanupStarts = 0
var cleanupAllowed = true
var cleanupImmediate, cleanupReplaced, cleanupVifChanged: bool
proc smCleanupBegin(p: pointer): bool =
  inc cleanupStarts
  doAssert sm.connectInfo == nil and sm.connectIndMsg == nil
  if not cleanupAllowed: return false
  if cleanupImmediate:
    let vif = cast[ptr Vif](p)
    vif.staIdx = 255
    vif.chanCtxt = nil
    if cleanupReplaced: sm.connectInfo = cast[pointer](1)
    if cleanupVifChanged: vif.vifType = 2
  else:
    currentState = 10
  true
proc resetAdmission(vif: uint8 = 0) =
  reset(vif)
  cleanupStarts = 0
  cleanupAllowed = true
  cleanupImmediate = false
  cleanupReplaced = false
  cleanupVifChanged = false
'''
    tasks = (FW / "task_handlers.nim").read_text()
    code += procedure((FW / "rx_layer.nim").read_text(), "rxInvalidateQuiescentVif")
    code += procedure((FW / "rx_layer.nim").read_text(), "rxInvalidateVif")
    code += procedure(tasks, "smConnectReqHasSpecificBssid")
    return code + procedure(tasks, "sm_connect_req_handler")


ADMISSION_CASES = {
    "immediate_cleanup": r'''
for replacement in [0, 1, 2]:
  resetAdmission()
  cleanupImmediate = true
  cleanupReplaced = replacement == 1
  cleanupVifChanged = replacement == 2
  vifs[0].chanCtxt = cast[pointer](3)
  let before = rxVifEpochs
  let status = sm_connect_req_handler(addr request)
  doAssert cleanupStarts == 1
  if replacement == 0:
    doAssert status == KeMsgNoFree and scans == 1 and confirmationStatus == 0
    doAssert sm.connectInfo == addr request
    doAssert rxVifEpochs[0] == before[0] + 1
  else:
    doAssert status == KeMsgConsumed and scans == 0
    doAssert confirmationStatus == (if replacement == 1: 8'u8 else: 9'u8)
    doAssert rxVifEpochs == before
''',
    "orphan_channel": r'''
resetAdmission()
vifs[0].chanCtxt = cast[pointer](1)
let before = rxVifEpochs
doAssert sm_connect_req_handler(addr request) == KeMsgSaved
doAssert cleanupStarts == 1 and currentState == 10
doAssert vifs[0].chanCtxt == cast[pointer](1) and vifs[0].staIdx == 255
doAssert sm.connectInfo == nil and sm.connectIndMsg == nil
doAssert allocations == 0 and scans == 0 and joins == 0
doAssert rxVifEpochs == before
''',
    "leftover_resources": r'''
for vif in 0'u8..1:
  for station in [false, true]:
    for channel in [false, true]:
      if not station and not channel: continue
      resetAdmission(vif)
      if station: vifs[vif].staIdx = 3
      if channel: vifs[vif].chanCtxt = cast[pointer](1)
      let original = vifs
      let before = rxVifEpochs
      doAssert sm_connect_req_handler(addr request) == KeMsgSaved
      doAssert cleanupStarts == 1 and currentState == 10
      doAssert vifs == original and rxVifEpochs == before
      doAssert sm.connectInfo == nil and allocations == 0
      doAssert sm_connect_req_handler(addr request) == KeMsgSaved
      doAssert cleanupStarts == 1 and allocations == 0
      vifs[vif].staIdx = 255
      vifs[vif].chanCtxt = nil
      currentState = 0
      doAssert sm_connect_req_handler(addr request) == KeMsgNoFree
      doAssert sm.connectInfo == (addr request) and scans == 1
      doAssert rxVifEpochs[vif] == before[vif] + 1
      doAssert rxVifEpochs[vif xor 1] == before[vif xor 1]
''',
    "cleanup_unavailable": r'''
resetAdmission()
cleanupAllowed = false
vifs[0].staIdx = 3
vifs[0].chanCtxt = cast[pointer](1)
let before = rxVifEpochs
doAssert sm_connect_req_handler(addr request) == KeMsgConsumed
doAssert cleanupStarts == 1 and confirmationStatus == 8
doAssert vifs[0].staIdx == 3 and vifs[0].chanCtxt == cast[pointer](1)
doAssert sm.connectInfo == nil and rxVifEpochs == before
''',
    "retained_owner": r'''
for connection in [false, true]:
  for indication in [false, true]:
    if not connection and not indication: continue
    resetAdmission()
    if connection: sm.connectInfo = cast[pointer](1)
    if indication: sm.connectIndMsg = cast[pointer](2)
    vifs[0].staIdx = 3
    vifs[0].chanCtxt = cast[pointer](3)
    let original = sm
    let before = rxVifEpochs
    doAssert sm_connect_req_handler(addr request) == KeMsgConsumed
    doAssert confirmationStatus == 8 and cleanupStarts == 0
    doAssert sm == original and rxVifEpochs == before
    doAssert vifs[0].staIdx == 3 and vifs[0].chanCtxt == cast[pointer](3)
    doAssert scans == 0 and joins == 0
''',
    "vif_admission_matrix": r'''
for kind in [0'u8, 1, 2, 255]:
  for active in [0'u8, 1]:
    for auth in [0'u8, 2]:
      resetAdmission()
      vifs[0].vifType = kind
      vifs[0].state = active
      request.authType = auth
      let before = rxVifEpochs
      let allowed = (kind == 0 and active == 0) or auth == 2
      let result = sm_connect_req_handler(addr request)
      doAssert result == (if allowed: KeMsgNoFree else: KeMsgConsumed)
      doAssert confirmationStatus == (if allowed: 0'u8 else: 9'u8)
      doAssert scans == allowed.int and cleanupStarts == 0
      doAssert rxVifEpochs[0] == before[0] + allowed.uint32
''',
}


def transaction_source() -> str:
    code = cleanup_program("disconnect").removesuffix(CLEANUP_CASES["disconnect"])
    prefix = r'''
const SM_CONNECT_REQ = 0x1000'u16
const SM_CONNECT_CFM = 0x1001'u16
type ConnectInfoView = object
  vifIdx, authType: uint8
  channelDuration: uint32
  bssid: array[6, uint8]
var reconnectScans, reconnectJoins: int
var reconnectConfirmations: seq[uint8]
var immediateCleanup = false
proc reconnectDriveSent()
proc sm_connect_req_handler*(param: pointer): cint {.exportc, cdecl.}
'''
    code = prefix + code
    code = code.replace("    connectInfo, connectIndMsg: pointer\n",
                        "    connectInfo, connectIndMsg: pointer\n"
                        "    connectFlags, connectModeFlags: uint8\n"
                        "    vendorIeLen: uint16\n", 1)
    code = code.replace(procedure(code, "connectInfoView"),
                        "proc connectInfoView(p: pointer): ptr ConnectInfoView = cast[ptr ConnectInfoView](p)\n")
    code = code.replace("proc captureNotification(p: pointer) =\n",
                        "proc captureNotification(p: pointer) =\n"
                        "  if keMsgHdrFromPayload(p).id == SM_CONNECT_CFM:\n"
                        "    reconnectConfirmations.add(cast[ptr StatusCfmPayload](p).status)\n")
    code = code.replace("    co_list_push_back(addr keMsgQueueSent, h)\n",
                        "    co_list_push_back(addr keMsgQueueSent, h)\n"
                        "    reconnectDriveSent()\n", 1)
    support = r'''
proc reconnectDriveSent() =
  if immediateCleanup:
    while keMsgQueueSent.first != nil: driveOne()
proc sm_connection_tlv_set(vif: uint8; p: pointer; length: uint16) = discard
proc connectInfoHasChannelHint(req: ptr ConnectInfoView): bool = false
proc connectInfoChannelHint(p: pointer): pointer = nil
proc sm_get_bss_params(bss, channel: ptr pointer): bool = false
proc scanu_prune_scanresult_raw_frames_except_bssid(p: pointer) = discard
proc scanu_prune_scanresult_raw_frames() = discard
proc sm_join_bss(mac, bss, channel: pointer; flags: uint32) = inc reconnectJoins
proc sm_scan_bss(mac, bss, channel: pointer) =
  doAssert vifs[0].chanCtxt == nil and vifs[0].staIdx == 255
  doAssert not smCleanup.active and smState == 0
  inc reconnectScans
'''
    tasks = (FW / "task_handlers.nim").read_text()
    support += procedure(tasks, "smConnectReqHasSpecificBssid")
    support += procedure(tasks, "sm_connect_req_handler")
    driver = DRIVER.replace(
        "  if h.destId == TASK_SM:\n",
        "  if h.destId == TASK_SM and h.id == SM_CONNECT_REQ:\n"
        "    result = sm_connect_req_handler(p)\n"
        "  elif h.destId == TASK_SM:\n", 1)
    return code.replace(DRIVER, support + driver, 1)


TRANSACTION_CASES = {
    "channel_only": (False, True, False, False),
    "station_only": (True, False, False, False),
    "station_and_channel": (True, True, False, False),
    "allocation_retry": (True, True, True, False),
    "immediate_cleanup": (True, True, False, True),
}


@pytest.mark.parametrize("case", ADMISSION_CASES)
@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_connect_admission(tmp_path: Path, case: str, mode: str) -> None:
    run_program(tmp_path, mode, admission_source() + ADMISSION_CASES[case])


@pytest.mark.parametrize("case", TRANSACTION_CASES)
@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_reconnect_cleanup(tmp_path: Path, case: str, mode: str) -> None:
    station, channel, allocation_failure, immediate = TRANSACTION_CASES[case]
    checks = f'''
ke_msg_free(keMsgHdrFromPayload(sm.connectInfo))
sm.connectInfo = nil
smState = 0
vifs[0].state = 0
vifs[0].staIdx = {2 if station else 255}
vifs[0].chanCtxt = {'addr cleanupChannel' if channel else 'nil'}
request = newMessage(SM_CONNECT_REQ, TASK_SM, TASK_API, 192)
connectInfoView(request)[] = ConnectInfoView(vifIdx: 0)
let before = rxVifEpochs
failEveryAllocation = {str(allocation_failure).lower()}
immediateCleanup = {str(immediate).lower()}
let outcome = sm_connect_req_handler(request)
if immediateCleanup:
  doAssert outcome == KeMsgNoFree and reconnectScans == 1
else:
  doAssert outcome == KeMsgSaved
  co_list_push_back(addr keMsgQueueSaved, keMsgHdrFromPayload(request))
  doAssert sm.connectInfo == nil and not requestFreed
  doAssert reconnectScans == 0 and reconnectConfirmations.len == 0
  doAssert rxVifEpochs == before and smState == 10
if failEveryAllocation:
  doAssert smCleanupNeedsService() and commands.len == 0
  discard wifiDrainScheduledWork()
  doAssert not requestFreed and keMsgQueueSaved.first == keMsgHdrFromPayload(request)
failEveryAllocation = false
drain()
doAssert reconnectScans == 1 and reconnectJoins == 0
doAssert reconnectConfirmations == @[0'u8]
doAssert sm.connectInfo == request and sm.connectIndMsg != nil
doAssert not requestFreed and keMsgQueueSaved.first == nil
doAssert removed.len == {int(station)} and unlinks == {int(channel)}
doAssert commands == @[{('ME_SET_PS_DISABLE_REQ, MM_STA_DEL_REQ, ME_SET_ACTIVE_REQ' if station else 'ME_SET_PS_DISABLE_REQ, ME_SET_ACTIVE_REQ')}]
doAssert rxVifEpochs[0] == before[0] + 1 and rxVifEpochs[1] == before[1]
doAssert me.activeMask == 2 and me.psDisableMask == 2
doAssert vifs[1].vifType == VIF_TYPE_AP and vifs[1].state == 1
doAssert vifs[1].staIdx == 6 and vifs[1].chanCtxt == cast[pointer](2)
ke_msg_free(keMsgHdrFromPayload(sm.connectInfo))
sm.connectInfo = nil
ke_msg_free(keMsgHdrFromPayload(sm.connectIndMsg))
sm.connectIndMsg = nil
doAssert allocated.len == 0 and smCleanupTags == nil
'''
    run_program(tmp_path, mode, transaction_source() + checks)
