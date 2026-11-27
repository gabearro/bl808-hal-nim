"""Exercise reconnect admission and the existing ME/MM cleanup transaction."""

from pathlib import Path

import pytest

from test_wifi_connect_rx_epoch import PLATFORM
from test_wifi_disconnect_tx import FW, ROOT, procedure
from test_wifi_message_allocation import run_program
from test_wifi_sm_cleanup import CASES as CLEANUP_CASES, DRIVER, program as cleanup_program


def admission_source() -> str:
    code = PLATFORM + r'''
var cleanupStarts = 0
var cleanupAllowed = true
var cleanupImmediate, cleanupReplaced, cleanupVifChanged: bool
proc smTeardown(p: pointer): bool =
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
    support = r'''
proc sm_connection_tlv_set() = discard
proc connectInfoHasChannelHint(req: ptr ConnectInfoView): bool = false
proc connectInfoChannelHint(p: pointer): pointer = nil
proc sm_get_bss_params(bss, channel: ptr pointer) = discard
proc scanu_prune_scanresult_raw_frames_except_bssid(p: pointer) = discard
proc scanu_prune_scanresult_raw_frames() = discard
proc sm_join_bss(mac, bss, channel: pointer; flags: bool) = inc reconnectJoins
proc sm_scan_bss(mac, bss, channel: pointer) =
  doAssert vifs[0].chanCtxt == nil and vifs[0].staIdx == 255
  doAssert smOwn.teardown == tdNone and smState == 0
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
    "channel_only": (False, True, False),
    "station_only": (True, False, False),
    "station_and_channel": (True, True, False),
    "allocation_retry": (True, True, True),
}


def delete_retry_transaction_source() -> str:
    code = transaction_source()
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    retry_platform = r'''
const STA_MGMT_FREE_STAS = 5
type
  RetryTimer = object
    callback: pointer
    env, expiry: uint32
  RetryDelivery = object
    cancelled: bool
var
  mmStaDelRetryTimer: RetryTimer
  mmStaDelRetryMask: uint8
  mmStaDelRetryReset: uint32
  mmStaDelRetryEpochs: array[STA_MGMT_FREE_STAS, uint32]
  retryNow: uint32
  retryArmed, failDeletion: bool
  deleteAttempts, deleteConfirmations: int
proc macTimeNow(): uint32 = retryNow
proc mmTimerActiveDelivery(timer: pointer): ptr RetryDelivery = nil
proc mmTimerSetLocked(timer: pointer; deadline, saved: uint32) =
  doAssert not interruptsEnabled and timer == (addr mmStaDelRetryTimer)
  mmStaDelRetryTimer.expiry = deadline
  retryArmed = true
proc mmStaDelRetryCb(env: pointer) {.cdecl.}
'''
    queue = procedure(kernel, "mmStaDelQueueRetryLocked")
    callback = procedure(kernel[kernel.index("proc mm_sta_del*"):], "mmStaDelRetryCb")
    pending = procedure(kernel, "mmStaDelRetryPending")
    code = code.replace(procedure(code, "mmStaDelTry"), retry_platform + r'''
proc mmStaDelTry(index: uint8; saved: uint32): bool =
  if index >= STA_MGMT_FREE_STAS.uint8: return true
  inc deleteAttempts
  if failDeletion: return false
  mm_sta_del(index)
  # staMgmtFinishRemoval: before the slot is free again, queued deletes of
  # it, the saved one being retried included, name no station.
  deleteStation(index)
  true
''')
    retry_stubs = procedure(code, "mmStaDelRetryPending")
    code = code.replace(retry_stubs + procedure(code, "mmStaDelQueueRetryLocked"),
                        pending + queue + callback)
    # Two MM timers: MM's station-delete retry and SM's cleanup retry.
    code = code.replace(procedure(code, "wifiMmTimerPendingWork"), r'''
proc deleteRetryDue(): bool =
  retryArmed and cast[int32](retryNow - mmStaDelRetryTimer.expiry) >= 0
proc wifiMmTimerPendingWork(): bool = deleteRetryDue() or retryDue()
''')
    code = code.replace(procedure(code, "wifiDispatchScheduledEvent"), r'''
proc wifiDispatchScheduledEvent(): bool =
  if deleteRetryDue():
    retryArmed = false
    cast[proc(env: pointer) {.cdecl.}](mmStaDelRetryTimer.callback)(nil)
    return true
  if retryDue():
    fireRetry()
    return true
  result = wifiEventPendingWork()
  if result: driveOne()
''')
    return code.replace(
        "    of MM_STA_DEL_CFM: result = smCleanupCfmHandler(p)\n",
        "    of MM_STA_DEL_CFM:\n"
        "      inc deleteConfirmations\n"
        "      result = smCleanupCfmHandler(p)\n",
    )


@pytest.mark.parametrize("mode", ["checked", "asan"])
def test_saved_reconnect_progresses_after_station_delete_retry(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, delete_retry_transaction_source() + r'''
failDeletion = true
retryNow = high(uint32) - 1000
sm_disconnect_process(addr vifs[0], 19, 3)
while keMsgQueueSent.first != nil and keMsgQueueSent.first.id != MM_STA_DEL_REQ:
  driveOne()
doAssert keMsgQueueSent.first != nil
let deletion = keMsgQueueSent.first
driveOne()
doAssert smOwn.answer != nil and smCleanup.step == 2
doAssert keMsgQueueSaved.first == deletion and keMsgQueueSaved.last == deletion
doAssert retryArmed and mmStaDelRetryMask == 4 and deleteAttempts == 1
doAssert deleteConfirmations == 0

request = newMessage(SM_CONNECT_REQ, TASK_SM, TASK_API, 192)
connectInfoView(request)[] = ConnectInfoView(vifIdx: 0)
ke_msg_send(request)
driveOne()
doAssert keMsgQueueSaved.last == keMsgHdrFromPayload(request)
doAssert reconnectScans == 0 and reconnectConfirmations.len == 0
retryNow = mmStaDelRetryTimer.expiry
for _ in 0 ..< 10: discard wifiDrainScheduledWork()
doAssert not wifiMainHasPendingWork()
doAssert deleteAttempts == 2, "waking the saved command polled a busy MAC twice"
doAssert retryArmed and deleteConfirmations == 0
doAssert keMsgQueueSaved.first == keMsgHdrFromPayload(request)
doAssert keMsgQueueSaved.last == deletion

failDeletion = false
retryNow = mmStaDelRetryTimer.expiry - 1
doAssert not wifiMainHasPendingWork() and smState == SmDisconnectingState
inc retryNow
drain() # The real retry callback wakes MM; the final SM reply wakes reconnect.
doAssert deleteAttempts == 3 and deleteConfirmations == 1 and removed == @[2'u8]
doAssert not retryArmed and mmStaDelRetryMask == 0 and keMsgQueueSaved.first == nil
doAssert reconnectScans == 1 and reconnectJoins == 0
doAssert reconnectConfirmations == @[0'u8] and sm.connectInfo == request
doAssert not requestFreed and sm.connectIndMsg != nil
doAssert unlinks == 1
doAssert commands == @[ME_SET_PS_DISABLE_REQ, MM_SET_VIF_STATE_REQ,
                       MM_STA_DEL_REQ, MM_STA_DEL_REQ, MM_STA_DEL_REQ, ME_SET_ACTIVE_REQ]
let admitted = smConnectIndPayloadAt(sm.connectIndMsg)
var connectStatus = 0xFFFF'u16
indicationHook = proc() = connectStatus = admitted.statusCode
sm_connect_ind(0, 0) # Model one successful association on a later turn.
doAssert connectStatus == 0 and controlReplies[^1].id == SM_CONNECT_IND_MSG
doAssert controlReplies.len == 3 # Disconnect indication, connect CFM, connect IND.
doAssert sm.connectInfo == nil and sm.connectIndMsg == nil
doAssert keMsgQueueSent.first == nil and keMsgQueueSaved.first == nil
doAssert allocated.len == 0
''')


def cleanup_pump_source() -> str:
    pump = ROOT / "src/bl808/wifi/facade_parts/service_futures_parts/pump.nim"
    return delete_retry_transaction_source() + r'''
type PumpFuture = ref object
  finished: bool
var
  wifiApEnabled, wifiDisconnectIssuePending: bool
  wifiScanFuture, wifiConnectFuture, wifiStaIdleFuture, wifiDisconnectFuture: PumpFuture
  hostConnected = true
  polls = 0
proc wifiBackendConnected(): bool = hostConnected
proc wifiBackendPoll(count: uint32) =
  inc polls
  for i in 0'u32 ..< count:
    discard wifiDrainScheduledWork()
proc wifiNimFirmwareServiceTx(count: uint32) = discard
proc wifiCompletePendingEvents() = discard
''' + procedure(pump.read_text(), "wifiServiceWanted") + \
        procedure(pump.read_text(), "wifiServicePump")


@pytest.mark.parametrize("mode", ["checked", "asan"])
def test_scheduler_polls_peer_cleanup_without_api_waiter(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, cleanup_pump_source() + r'''
failDeletion = true
retryNow = high(uint32) - 1000
indicationHook = proc() = hostConnected = false
sm_disconnect_process(addr vifs[0], 7, 7)
doAssert not hostConnected and notifications.len == 1
doAssert smState == SmDisconnectingState

wifiServicePump()
doAssert polls == 1, "link-down stopped firmware polling during cleanup"
doAssert smOwn.answer != nil and smCleanup.step == 2 and retryArmed
doAssert mmStaDelRetryMask == 4 and deleteAttempts == 1
doAssert deleteConfirmations == 0

failDeletion = false
retryNow = mmStaDelRetryTimer.expiry - 1
wifiServicePump()
doAssert deleteAttempts == 1 and smState == SmDisconnectingState
inc retryNow
wifiServicePump()
doAssert deleteAttempts == 2 and deleteConfirmations == 1 and removed == @[2'u8]
doAssert not retryArmed and smOwn.teardown == tdNone and smState == 0
doAssert keMsgQueueSaved.first == nil and allocated.len == 0
doAssert notifications.len == 1

let finalPolls = polls
wifiServicePump()
doAssert polls == finalPolls, "quiescent station did not stop polling"
''')


@pytest.mark.parametrize("case", ADMISSION_CASES)
@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_connect_admission(tmp_path: Path, case: str, mode: str) -> None:
    run_program(tmp_path, mode, admission_source() + ADMISSION_CASES[case])


@pytest.mark.parametrize("case", TRANSACTION_CASES)
@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_reconnect_cleanup(tmp_path: Path, case: str, mode: str) -> None:
    station, channel, allocation_failure = TRANSACTION_CASES[case]
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
let outcome = sm_connect_req_handler(request)
# Internal messages are only queued, so the cleanup cannot finish inside
# the handler: the reconnect is saved behind it.
doAssert outcome == KeMsgSaved
co_list_push_back(addr keMsgQueueSaved, keMsgHdrFromPayload(request))
doAssert sm.connectInfo == nil and not requestFreed
doAssert reconnectScans == 0 and reconnectConfirmations.len == 0
doAssert rxVifEpochs == before and smState == 10
if failEveryAllocation:
  doAssert smGuardArmed and commands.len == 0
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
doAssert allocated.len == 0
'''
    run_program(tmp_path, mode, transaction_source() + checks)
