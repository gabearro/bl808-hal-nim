"""Run SA Query TX/RX, retry, transaction and timeout logic on the host."""

from pathlib import Path
import shutil
import subprocess

import pytest

from test_wifi_disconnect_tx import FW, PLATFORM, ROOT, procedure
from test_wifi_traffic_probe_history import history_source


IRQ_STATE = r'''
var
  interruptsEnabled = true
  printfInterruptsEnabled, teardownInterruptsEnabled: bool
  onIrqRestore: proc()
'''


EXTENSION = r"""
from std/volatile import volatileLoad, volatileStore
{.pragma: wifiCtrl.}
const
  RC_PRNG_MULT = 1103515245'u32
  RC_PRNG_INCR = 12345'u32
  SM_SA_QUERY_TIMEOUT_IND_MSG = 0x1009'u16
  SmIdleState = 0'u8
  KeMsgConsumed = 0.cint
  KeMsgSaved = 2.cint
  VIF_TYPE_STA = 0'u8
  STA_MGMT_FREE_STAS = 5
type
  SaQueryActionBodyView {.packed.} = object
    category, action: uint8
    transId: uint16
  MessageHeader = object
    paramLen: uint32
    id: uint16
    destId, srcId: uint8
  MgtPrefix {.packed.} = object
    frameLen, frameCtrl, freq: uint16
    padding: array[19, uint8]
    rssi: int8
    tail: array[6, uint8]
    body: UncheckedArray[uint8]
  RxuMgtIndMsgView = MgtPrefix
  TimerCall = tuple[kind: string, id: uint16, delay: uint32, active: uint8]
  PlatformLogFunc = proc(level, severity: uint32; file: pointer;
                         line: uint32) {.cdecl, varargs.}
var
  messageHeader = MessageHeader(paramLen: 64)
  timers: seq[TimerCall]
  smQueryPrngState = 1'u32
  rcPrngCalls, printfCalls: int
  currentState: uint8
  macNow: uint32
  timerAllocFails: bool
  onTimerClear, onPrintf: proc()
  smConnecting: bool
  nimFwDbgDeauthHandler: uint32
  printfReason: uint32

proc saQueryActionBodyAt(p: pointer): ptr SaQueryActionBodyView = cast[ptr SaQueryActionBodyView](p)
proc smSaQueryFrameView(p: pointer): ptr SmSaQueryFrameView = cast[ptr SmSaQueryFrameView](p)
proc smDeauthFrameView(p: pointer): ptr SmDeauthFrameView = cast[ptr SmDeauthFrameView](p)
proc keMsgHdrFromPayload(p: pointer): ptr MessageHeader = addr messageHeader
proc rxuMgtIndMsgAt(p: pointer): ptr MgtPrefix = cast[ptr MgtPrefix](p)
proc macDataFrameAt(p: pointer): ptr Header = cast[ptr Header](p)
proc setFrameLen(p: pointer; length: uint16) = rxuMgtIndMsgAt(p).frameLen = length
proc KE_FIRST_MSG(task: uint16): uint16 = task shl 10
proc ke_state_get(task: uint8): uint8 = currentState
proc ke_state_set(task, state: uint8) =
  doAssert task == TASK_SM and state == SmDisconnectingState
  currentState = state
  events.add(("state", nil, 0'u16, 0'u16))
proc macTimeNow(): uint32 = macNow
proc ke_timer_try_set(id: uint16; task: uint8; delay: uint32;
                      guard: proc(context: pointer): bool; context: pointer;
                      stamp: uint32 = 0): bool =
  doAssert task == TASK_SM
  doAssert stamp == cast[ptr uint32](context)[] and stamp != 0
  if timerAllocFails or not guard(context): return false
  timers.add(("set", id, delay, env.saQueryActive))
  true
proc ke_timer_clear(id: uint16; task: uint8) =
  doAssert task == TASK_SM
  timers.add(("clear", id, 0'u32, env.saQueryActive))
  if onTimerClear != nil: onTimerClear()
proc rcPrngNext(): uint32 =
  inc rcPrngCalls
  0xABCD0000'u32
{.emit: "#include <stdarg.h>".}
proc testPrintf(fmt: cstring) {.cdecl, varargs.} =
  doAssert $fmt == "Deauth/Disassociate by AP, Wlan802.11 reason code = %d\r\n"
  var reason: cint
  {.emit: ["va_list args; va_start(args, ", fmt, "); ",
           reason, " = va_arg(args, int); va_end(args);"].}
  inc printfCalls
  printfReason = reason.uint32
  printfInterruptsEnabled = interruptsEnabled
  if onPrintf != nil: onPrintf()
proc blOpsFunc(offset: int): pointer =
  doAssert offset == 4
  cast[pointer](testPrintf)
proc setupSA(vif, sta: uint8) =
  reset(vif, sta)
  messageHeader.paramLen = 64
  env.saQueryActive = 0
  env.saQueryRetryCount = 0
  env.saQueryStaIdx = sta
  env.saQueryTransId = 0
  env.saQueryReason = 7
  stations[sta].instNbr = vif
  stations[sta].controlPortState = 2
  stations[sta].valid = 1
  vifs[vif].bssid = stations[sta].macAddr
  timers.setLen(0)
  currentState = 0
  smConnecting = false
  printfCalls = 0
  printfReason = 0
  interruptsEnabled = true
  printfInterruptsEnabled = false
  teardownInterruptsEnabled = false
  onIrqRestore = nil
  macNow = 0
  timerAllocFails = false
  onTimerClear = nil
  onPrintf = nil
  onAllocate = nil
  onPower = nil
  onProtect = nil
  frameLeased = false
  txResetEpoch = 0
"""

TX_BASELINE = r"""
setupSA(0, 1)
sm_send_sa_query(1, 1'u8, 0x34'u8)
doAssert pushCalls == 1 and desc.vifIdx == 0 and desc.staInfoIdx == 1
doAssert hostTxDataHeader(addr desc).frameControl == 0x40D0
doAssert link.macHeader[32] == 8 and link.macHeader[33] == 1
doAssert link.macHeader[34] == 0x34 and link.macHeader[35] == 0
"""

CHECKS = r"""
for vif in 0'u8 .. 1'u8:
  for station in 0'u8 .. 6'u8:
    for action in 0'u8 .. 1'u8:
      for transaction in [0'u16, 0x1234, 0xFFFF]:
        setupSA(vif, station)
        doAssert sm_send_sa_query(station, action, transaction) == 0
        doAssert getCalls == 1 and pushCalls == 1 and releases == 0
        doAssert desc.vifIdx == vif and desc.staInfoIdx == station
        doAssert desc.hdrLen == 8 and desc.secTailLen == 8
        let hdr = hostTxDataHeader(addr desc)
        doAssert hdr.frameControl == 0x40D0 and hdr.seqCtrl == 0x4560
        doAssert hdr.duration == 0 and hdr.addr1 == stations[station].macAddr
        doAssert hdr.addr2 == vifs[vif].macAddr and hdr.addr3 == hdr.addr1
        doAssert link.macHeader[32] == 8 and link.macHeader[33] == action
        doAssert link.macHeader[34] == (transaction and 255).uint8
        doAssert link.macHeader[35] == (transaction shr 8).uint8
        doAssert hw.payloadEnd == hw.payloadStart + 43 and hw.frameLen == 48
        for i in 0 ..< 16: doAssert link.before[i] == 0xA5 and link.after[i] == 0x5A
        doAssert events.len == 1 and events[0].kind == "power"

for failure in 0 .. 3:
  setupSA(1, 4)
  case failure
  of 0: allocFail = true
  of 1: noLink = true
  of 2: noHw = true
  else: protectionFail = true
  doAssert sm_send_sa_query(4, 0, 0xFFFF) == -1
  doAssert pushCalls == 0 and releases == (if failure == 0: 0 else: 1)
setupSA(1, 4)
pushFail = true
doAssert sm_send_sa_query(4, 0, 0xFFFF) == 0
doAssert releases == 1
setupSA(0, 0)
doAssert sm_send_sa_query(255, 0, 1) == -1
doAssert getCalls == 0

# Private random stream is not perturbed by rate-control calls.
smQueryPrngState = 1
var expectedPrng = 1'u32
for i in 0 ..< 32:
  setupSA(1, 4)
  seedSaQuery(1)
  discard rcPrngNext()
  let callsBefore = rcPrngCalls
  expectedPrng = expectedPrng * RC_PRNG_MULT + RC_PRNG_INCR
  sm_issue_sa_query_request()
  doAssert rcPrngCalls == callsBefore
  doAssert smQueryPrngState == expectedPrng
  doAssert env.saQueryTransId == (expectedPrng shr 16).uint16
  doAssert link.macHeader[33] == 0
  doAssert link.macHeader[34] == ((expectedPrng shr 16) and 255).uint8
  doAssert link.macHeader[35] == (expectedPrng shr 24).uint8
  doAssert timers == @[("set", 0x1009'u16, 100000'u32, 1'u8)]

# Requests must come from the connected AP on an active STA VIF. A response
# may only complete the pending query for that same peer and transaction.
for action in 0'u8 .. 2'u8:
  for scenario in 0 .. 8:
    setupSA(1, 4)
    seedSaQuery(1)
    env.saQueryTransId = 0xBEEF
    var message = SmSaQueryFrameView(staIdx: 4, vifIdx: 1, action: action, transId: 0xBEEF)
    setFrameLen(addr message, 4)
    case scenario
    of 1: vifs[1].state = 0
    of 2: vifs[1].vifType = 1
    of 3: vifs[1].vifType = 2
    of 4: message.staIdx = 3
    of 5: stations[4].controlPortState = 1
    of 6: message.transId = 0xBEEC
    of 7: env.saQueryStaIdx = 3
    of 8: stations[4].instNbr = 0
    else: discard
    sm_sa_query_handler(addr message)
    let validPeer = scenario in [0, 6, 7]
    if action == 0 and validPeer:
      doAssert pushCalls == 1 and link.macHeader[33] == 1
      doAssert link.macHeader[34] == (message.transId and 255).uint8
      doAssert timers.len == 0 and env.saQueryActive == 1
    elif action == 1 and scenario == 0:
      doAssert env.saQueryActive == 0 and pushCalls == 0
      doAssert timers == @[("clear", 0x1009'u16, 0'u32, 0'u8)]
    else:
      doAssert timers.len == 0 and pushCalls == 0 and env.saQueryActive == 1

setupSA(1, 4)
seedSaQuery(1, armed = true)
env.saQueryRetryCount = 2
env.saQueryReason = 0xBEEF
doAssert deliverSaExpiry() == 0
doAssert env.saQueryRetryCount == 1 and pushCalls == 1 and env.saQueryActive == 1
doAssert deliverSaExpiry() == 0
doAssert env.saQueryRetryCount == 1 and pushCalls == 1
macNow = smSaQuery.deadline
doAssert deliverSaExpiry() == 0
doAssert env.saQueryRetryCount == 0 and pushCalls == 2 and env.saQueryActive == 1
macNow = smSaQuery.deadline
doAssert deliverSaExpiry() == 0
doAssert env.saQueryActive == 0 and pushCalls == 2 and printfCalls == 1
doAssert printfReason == 0xBEEF
doAssert events[^1] == ("disconnect", cast[pointer](addr vifs[1]), 7'u16, 0xBEEF'u16)
let completedEvents = events.len
deliverSaExpiry()
doAssert events.len == completedEvents

# Drive the actual deauth-to-query initiation path and complete the exchange.
setupSA(1, 4)
var deauth = SmDeauthFrameView(vifIdx: 1, staIdx: 4, frameFlags: 1,
  sa: vifs[1].macAddr, bssid: vifs[1].bssid, reason: 6)
setFrameLen(addr deauth, 26)
sm_deauth_handler(addr deauth)
doAssert env.saQueryActive == 1 and env.saQueryRetryCount == 2
doAssert env.saQueryStaIdx == 4 and env.saQueryReason == 6
doAssert pushCalls == 1 and timers.len == 1 and timers[0].id == 0x1009
sm_deauth_handler(addr deauth)
doAssert pushCalls == 1
var response = SmSaQueryFrameView(vifIdx: 1, staIdx: 4, action: 1,
  transId: env.saQueryTransId)
setFrameLen(addr response, 4)
sm_sa_query_handler(addr response)
doAssert env.saQueryActive == 0 and timers[^1].kind == "clear"
let countAfterReply = events.len
deliverSaExpiry()
doAssert events.len == countAfterReply

setupSA(1, 4)
deauth.staIdx = 3
sm_deauth_handler(addr deauth)
doAssert env.saQueryActive == 0 and pushCalls == 0 and timers.len == 0
setupSA(1, 4)
deauth.staIdx = 4
deauth.frameFlags = 0
sm_deauth_handler(addr deauth)
doAssert env.saQueryActive == 0 and pushCalls == 0
doAssert printfReason == 6
doAssert events[^1] == ("disconnect", cast[pointer](addr vifs[1]), 7'u16, 6'u16)

# Transient allocation failure still gets the vendor's retry timer.
setupSA(0, 2)
seedSaQuery(0)
allocFail = true
sm_issue_sa_query_request()
doAssert timers == @[("set", 0x1009'u16, 100000'u32, 1'u8)]
doAssert pushCalls == 0
setupSA(1, 4)
response = SmSaQueryFrameView(vifIdx: 1, staIdx: 4, action: 1, transId: 0)
setFrameLen(addr response, 4)
sm_sa_query_handler(addr response)
doAssert env.saQueryActive == 0 and timers.len == 0
sm_sa_query_handler(nil)
response.vifIdx = 255
sm_sa_query_handler(addr response)
doAssert timers.len == 0 and pushCalls == 0

setupSA(1, 4)
seedSaQuery(1)
response = SmSaQueryFrameView(vifIdx: 1, staIdx: 4, action: 1,
  transId: env.saQueryTransId)
setFrameLen(addr response, 4)
messageHeader.paramLen = 35
sm_sa_query_handler(addr response)
doAssert env.saQueryActive == 1 and timers.len == 0
messageHeader.paramLen = 64
setFrameLen(addr response, 3)
sm_sa_query_handler(addr response)
doAssert env.saQueryActive == 1 and timers.len == 0
messageHeader.paramLen = 36
setFrameLen(addr response, 5)
sm_sa_query_handler(addr response)
doAssert env.saQueryActive == 1 and timers.len == 0

# The deadline is modular and a same-address replacement has a different epoch.
setupSA(1, 4)
seedSaQuery(1)
macNow = 0xFFFF0000'u32
env.saQueryRetryCount = 2
sm_issue_sa_query_request()
let originalDeadline = smSaQuery.deadline
macNow = originalDeadline - 51
deliverSaExpiry()
doAssert env.saQueryRetryCount == 2
macNow = originalDeadline - 49
deliverSaExpiry()
doAssert env.saQueryRetryCount == 1 and pushCalls == 2
let replacementEpoch = rxVifEpochs[1] + 1
rxVifEpochs[1] = replacementEpoch
macNow = smSaQuery.deadline
deliverSaExpiry()
doAssert env.saQueryRetryCount == 1 and pushCalls == 2 and printfCalls == 0

setupSA(1, 4)
seedSaQuery(1, armed = true)
response = SmSaQueryFrameView(vifIdx: 1, staIdx: 4, action: 1, transId: env.saQueryTransId)
setFrameLen(addr response, 4)
onTimerClear = proc() =
  inc rxVifEpochs[1]
  seedSaQuery(1, armed = true)
sm_sa_query_handler(addr response)
doAssert env.saQueryActive == 1 and smSaQuery.armed and smSaQuery.peer.epoch == rxVifEpochs[1]

setupSA(1, 4)
seedSaQuery(1)
timerAllocFails = true
sm_issue_sa_query_request()
doAssert env.saQueryActive == 0 and not smSaQuery.armed
doAssert printfCalls == 0

setupSA(1, 4)
seedSaQuery(1, armed = true)
onPrintf = proc() = inc rxVifEpochs[1]
deliverSaExpiry()
doAssert printfCalls == 1 and events.len == 0 and currentState == SmIdleState
"""


def run_nim(tmp_path: Path, source: str, *defines: str) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("nim is not installed")
    path = tmp_path / "sa_query.nim"
    path.write_text(source)
    result = subprocess.run(
        [nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on", "--skipUserCfg:on",
         *[f"-d:{define}" for define in defines],
         "--checks:on", f"--nimcache:{tmp_path / 'nimcache'}", f"-o:{tmp_path / 'check'}", str(path)],
        cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
    )
    assert result.returncode == 0, result.stdout


def rx_ownership_source() -> str:
    layout = (FW / "layout_types.nim").read_text()
    rx = (FW / "rx_layer.nim").read_text()
    identity = "type\n"
    for name in ("RxMgtProtection", "RxStationIdentity", "RxMgtIdentityNode"):
        identity += "  " + name + layout.split("  " + name, 1)[1].split("\n\n", 1)[0] + "\n"
    return (identity + "\nvar rxMgtIdentities: ptr RxMgtIdentityNode\n"
            + procedure(rx, "rxIdentityCurrent") + procedure(rx, "rxMgtMessageCurrent"))


def ownership_source(*, real_rx: bool = True, tx_path: bool = True) -> str:
    layout = (FW / "layout_types.nim").read_text()
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    tx = (FW / "tx_layer.nim").read_text()
    identity = "type\n"
    for name in ("MmVifIdentity", "SmDisconnectHandoff"):
        identity += "  " + name + layout.split("  " + name, 1)[1].split("\n\n", 1)[0] + "\n"
    if tx_path:
        identity += "  TxSessionIdentity" + layout.split("  TxSessionIdentity", 1)[1].split("\n\n", 1)[0] + "\n"
    code = identity + r'''
var
  rxVifEpochs: array[MAX_VIFS, uint32]
  stationEpochs: array[STA_INFO_TAB_ENTRIES, uint32]
proc staDeleteEpoch(index: uint8): uint32 = stationEpochs[index]
proc vifChannelAt(p: pointer): ptr Vif = cast[ptr Vif](p)
proc irqSave(): uint32 =
  result = if interruptsEnabled: 8'u32 else: 0'u32
  interruptsEnabled = false
proc irqRestore(saved: uint32) =
  interruptsEnabled = (saved and 8) != 0
  if interruptsEnabled and onIrqRestore != nil:
    let action = onIrqRestore
    onIrqRestore = nil
    action()
proc smConnectIndLocked(status, reason: uint16; saved: uint32) =
  irqRestore(saved)
  sm_connect_ind(status, reason)
var
  queuedSaExpiry: seq[uint32]
  saExpiryStorage: uint32
  saExpiryFrees: int
  failSaExpiryAlloc: bool
  onSaExpiryAlloc: proc()
proc ke_msg_try_alloc(id: uint16; dst, src: uint8; size: uint32): pointer =
  doAssert id == SM_SA_QUERY_TIMEOUT_IND_MSG and dst == TASK_SM and src == 0xFF and size == 4
  if onSaExpiryAlloc != nil: onSaExpiryAlloc()
  if failSaExpiryAlloc: nil else: addr saExpiryStorage
proc ke_msg_send(message: pointer) =
  doAssert message == addr saExpiryStorage
  queuedSaExpiry.add(saExpiryStorage)
proc ke_msg_free(header: pointer) = inc saExpiryFrees
'''
    if tx_path:
        code += r'''
proc txlResetting(): bool = false
proc txlVifIsRetiring(vif: uint8): bool = false
proc txlFrameLeaseToken(p: ptr HostTxDescView): uint32 = frameGeneration
proc txlFrameSessionCurrent(p: ptr HostTxDescView): bool = frameLeased
proc txlFrameLeaseMatches(p: ptr HostTxDescView; generation: uint32): bool =
  frameLeased and generation == frameGeneration
''' + "".join(procedure(tx, name) for name in ("txlSessionCurrent", "txlStationAdmits", "txlFramePreparationCurrent"))
    return (code + procedure(kernel, "mmCaptureVif") + procedure(kernel, "mmVifCurrent") + r'''
proc smDisconnectHandoffCurrent(handoff: SmDisconnectHandoff): bool
proc smDisconnectOwned(handoff: SmDisconnectHandoff; status, reason: uint16) =
  doAssert smDisconnectHandoffCurrent(handoff)
  teardownInterruptsEnabled = interruptsEnabled
  ke_state_set(TASK_SM, SmDisconnectingState)
  sm_disconnect_process(handoff.peer.vif, status, reason)
''' +
        (rx_ownership_source() if real_rx else "") +
        (FW / "station_sa_query.nim").read_text().replace(" {.wifiCtrl.}", "") + "\n" +
        procedure((FW / "scan_station_ap_me.nim").read_text(), "smDisconnectHandoffCurrent"))


def platform() -> str:
    layout = (FW / "layout_types.nim").read_text()
    declarations = "type\n"
    for name in ["SmSaQueryFrameView", "SmDeauthFrameView"]:
        declarations += "  " + name + layout.split("  " + name, 1)[1].split("\n\n  ", 1)[0] + "\n"
    source = (FW / "scan_station_ap_me.nim").read_text()
    base = PLATFORM.replace(procedure(PLATFORM, "ke_state_set"),
                            "proc ke_state_set(task, state: uint8)\n")
    base = r'''
var
  frameGeneration, txResetEpoch: uint32
  frameLeased: bool
  onAllocate, onPower, onProtect: proc()
''' + base.replace("instNbr, controlPortState: uint8", "instNbr, controlPortState, valid: uint8")
    base = base.replace("  addr desc\nproc txl_frame_release",
                        "  inc frameGeneration\n  frameLeased = true\n"
                        "  if onAllocate != nil: onAllocate()\n  addr desc\nproc txl_frame_release")
    base = base.replace("  inc releases\nproc txl_frame_push",
                        "  doAssert frameLeased\n  frameLeased = false\n"
                        "  inc releases\nproc txl_frame_push")
    base = base.replace("  inc pushCalls\n",
                        "  doAssert frameLeased\n  frameLeased = false\n  inc pushCalls\n")
    base = base.replace('  events.add(("power", vif, 0\'u16, 0\'u16))\n',
                        '  events.add(("power", vif, 0\'u16, 0\'u16))\n'
                        "  if onPower != nil: onPower()\n")
    base = base.replace("  desc.secTailLen = 8\nproc mfp_add_mgmt_mic",
                        "  desc.secTailLen = 8\n"
                        "  if onProtect != nil: onProtect()\nproc mfp_add_mgmt_mic")
    return (IRQ_STATE + base + declarations + EXTENSION + ownership_source() + procedure(layout, "rxMacHeaderLen")
            + procedure(source, "smRxFrameFits") + r'''
proc keTimerClearLocked(id: uint16; task: uint8; saved: uint32) =
  doAssert not interruptsEnabled
  timers.add(("clear", id, 0'u32, env.saQueryActive))
  irqRestore(saved)
  if onTimerClear != nil: onTimerClear()
proc seedSaQuery(vif: uint8; armed = false) =
  inc smSaQuery.serial
  smSaQuery.peer = mmCaptureVif(addr vifs[vif])
  smSaQuery.deadline = macNow
  smSaQuery.armed = armed
  env.saQueryActive = 1
''')


def test_sa_query_tx_contract(tmp_path: Path) -> None:
    source = (FW / "scan_station_ap_me.nim").read_text()
    run_nim(tmp_path, platform() + procedure(source, "smTrySubmitSaQuery")
            + procedure(source, "sm_send_sa_query") + TX_BASELINE)


def exchange_source() -> str:
    source = (FW / "scan_station_ap_me.nim").read_text()
    tasks = (FW / "task_handlers.nim").read_text()
    procedures = "".join(procedure(source, name) for name in [
        "smTrySubmitSaQuery", "sm_send_sa_query", "sm_issue_sa_query_request", "sm_sa_query_handler",
    ])
    procedures += procedure(tasks, "sm_sa_query_timeout_ind_handler")
    procedures += procedure(source, "sm_deauth_handler")
    return platform() + procedures + deliver_timeout_source()


def deliver_timeout_source() -> str:
    return r'''
proc deliverSaExpiry(serial = smSaQuery.serial): cint {.discardable.} =
  let previous = messageHeader
  defer: messageHeader = previous
  messageHeader = MessageHeader(id: SM_SA_QUERY_TIMEOUT_IND_MSG, destId: TASK_SM,
    srcId: 0xFF, paramLen: 4)
  var payload = serial
  sm_sa_query_timeout_ind_handler(addr payload)
'''


def test_queued_expiry_keeps_its_own_query_serial(tmp_path: Path) -> None:
    run_nim(tmp_path, exchange_source() + r'''
setupSA(1, 4)
seedSaQuery(1, armed = true)
let old = smSaQuery.serial
smSaQueryQueueTimeout(old)
doAssert queuedSaExpiry == @[old]
var reply = SmSaQueryFrameView(vifIdx: 1, staIdx: 4, action: 1,
  transId: env.saQueryTransId)
setFrameLen(addr reply, 4)
sm_sa_query_handler(addr reply)
doAssert env.saQueryActive == 0
seedSaQuery(1, armed = true)
env.saQueryRetryCount = 2
macNow = smSaQuery.deadline
let replacement = smSaQuery.serial
discard sm_sa_query_timeout_ind_handler(nil)
deliverSaExpiry(queuedSaExpiry[0])
doAssert pushCalls == 0 and env.saQueryRetryCount == 2 and smSaQuery.armed
doAssert smSaQuery.serial == replacement and timers.len == 1 and printfCalls == 0
deliverSaExpiry(replacement)
doAssert pushCalls == 1 and env.saQueryRetryCount == 1 and smSaQuery.armed
deliverSaExpiry(replacement)
doAssert pushCalls == 1 and env.saQueryRetryCount == 1

for completeInLogger in [false, true]:
  setupSA(1, 4)
  seedSaQuery(1, armed = true)
  onPrintf = proc() =
    seedSaQuery(1, armed = true)
    if completeInLogger:
      env.saQueryActive = 0
      smSaQuery.armed = false
  deliverSaExpiry()
  doAssert printfCalls == 1 and events.len == 0 and currentState == SmIdleState
  doAssert (env.saQueryActive != 0) == not completeInLogger
''')


def test_expiry_allocation_failure_only_retires_its_owner(tmp_path: Path) -> None:
    run_nim(tmp_path, exchange_source() + r'''
for replace in [false, true]:
  setupSA(1, 4)
  seedSaQuery(1, armed = true)
  let original = smSaQuery.serial
  failSaExpiryAlloc = true
  if replace:
    onSaExpiryAlloc = proc() = seedSaQuery(1, armed = true)
  smSaQueryQueueTimeout(original)
  doAssert smSaQuery.armed == replace and (env.saQueryActive != 0) == replace
  doAssert (smSaQuery.serial != original) == replace and queuedSaExpiry.len == 0
  doAssert events.len == 0 and currentState == SmIdleState
  onSaExpiryAlloc = nil
''')


def reset_boundary_source() -> str:
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    platform = (FW / "platform_bl.nim").read_text()
    forwards = (FW / "global_state/forward_decls_mac.nim").read_text()
    source = exchange_source().replace("  doAssert offset == 4\n", "  if offset == 188: return nil\n  doAssert offset == 4\n")
    scope = forwards[forwards.index("template smSaQueryResetScope()"):].split("\n\n", 1)[0]
    source += "\n" + scope + "\n"
    source += r'''
const
  TASK_MM = 0'u8
  TASK_NONE = 0xFF'u8
  HW_ACTIVE = 3'u8
type TestQueue = object
  first: pointer
var
  keMsgQueueSent, keMsgQueueSaved, keTimerQueue: TestQueue
  keSavedReschedTask: uint8
  keSavedReschedMask: uint32
  keSavedReschedRemaining: array[10, uint32]
  mm: tuple[previousState, hardwareMode: uint8]
  onResetBoundary: proc()
  recoveryReady = true
proc runResetHook() =
  if onResetBoundary != nil:
    let hook = onResetBoundary
    onResetBoundary = nil
    hook()
proc co_list_init(q: ptr TestQueue) = q.first = nil
proc co_list_pop_front(q: ptr TestQueue): pointer = nil
proc ke_evt_clear(mask: uint32) = discard
proc mmConfigCancelIdle() = runResetHook()
proc scanDwellReset() = discard
proc smActivationCancel() = discard
proc chanSwitchReset() = discard
proc keTimerCancelMutations(all: bool) = discard
proc smRspTimerReset() = discard
proc smBssCancel() = discard
proc smCleanupCancel() = discard
proc smDeferredCancel() = discard
proc mmPsModeCancel() = discard
proc meControlReset() = discard
proc apmCancelPendingForVif(i: uint8) = discard
proc mm_bcn_flush_updates(send: bool) = discard
proc waitMacSoftResetClear(): bool =
  runResetHook()
  recoveryReady
proc hal_machw_reset(): bool = true
proc rxl_reset(): bool = true
proc txl_reset(): bool =
  inc txResetEpoch
  true
proc mmEnvView(): ptr typeof(mm) = addr mm
proc ke_state_set(task: uint8; state: uint16) = doAssert task == TASK_MM and state == HW_ACTIVE
proc mm_reset() = discard
proc vif_mgmt_reset() = discard
proc apmResumeHaltRollback() = discard
proc mmPsModeRetryAfterReset() = discard
proc ke_reschedule_saved_messages(task: uint8): bool = false
'''
    return (source + procedure(kernel, "ke_init") + procedure(kernel, "ke_flush")
            + ("\nwhen not declared(mmConfigCancelIdle):\n  proc mmConfigCancelIdle() = discard\n" + procedure(kernel, "mm_force_idle_req")) + procedure(platform, "bl_reset_evt"))


def test_query_reset_boundaries_retire_without_readmitting_work(tmp_path: Path) -> None:
    run_nim(tmp_path, reset_boundary_source() + r'''
proc startPeerQuery() =
  var indication = SmDeauthFrameView(vifIdx: 1, staIdx: 4, frameFlags: 1,
    sa: vifs[1].macAddr, bssid: vifs[1].bssid, reason: 7)
  setFrameLen(addr indication, 26)
  discard sm_deauth_handler(addr indication)

for boundary in 0 .. 3:
  setupSA(1, 4)
  seedSaQuery(1, armed = true)
  let retired = smSaQuery.serial
  recoveryReady = boundary != 3
  onResetBoundary = proc() =
    doAssert env.saQueryActive == 0 and not smSaQuery.armed
    startPeerQuery()
    doAssert pushCalls == 0 and env.saQueryActive == 0
    # A nested queue drain cannot release the outer reset's admission fence.
    ke_flush()
    startPeerQuery()
    doAssert pushCalls == 0 and env.saQueryActive == 0
  case boundary
  of 0: ke_init()
  of 1: ke_flush()
  else: bl_reset_evt()
  doAssert env.saQueryActive == 0 and not smSaQuery.armed and interruptsEnabled
  doAssert timers.len == (if boundary == 2: 1 else: 0)
  if boundary == 2:
    doAssert timers[0] == ("clear", SM_SA_QUERY_TIMEOUT_IND_MSG, 0'u32, 0'u8)
  deliverSaExpiry(retired)
  doAssert pushCalls == 0 and printfCalls == 0
  startPeerQuery()
  doAssert pushCalls == 1 and smSaQuery.serial != retired and smSaQuery.armed

setupSA(1, 4)
seedSaQuery(1, armed = true)
let current = smSaQuery.serial
doAssert mm_force_idle_req()
doAssert smSaQuery.serial == current and env.saQueryActive == 1 and smSaQuery.armed

setupSA(1, 4)
seedSaQuery(1, armed = true)
let old = smSaQuery.serial
onSaExpiryAlloc = proc() = ke_flush()
smSaQueryQueueTimeout(old)
doAssert env.saQueryActive == 0 and not smSaQuery.armed
doAssert queuedSaExpiry.len == 0 and saExpiryFrees == 1
onSaExpiryAlloc = nil
startPeerQuery()
doAssert pushCalls == 1 and smSaQuery.armed

setupSA(1, 4)
onAllocate = proc() = ke_flush()
doAssert smTrySubmitSaQuery(4, 1, 0x1234) == saQueryBuildRejected
doAssert pushCalls == 0 and not frameLeased
onAllocate = nil
doAssert smTrySubmitSaQuery(4, 1, 0x1234) == saQuerySubmitted
doAssert pushCalls == 1
''')


def test_sa_query_exchange_and_timeout(tmp_path: Path) -> None:
    run_nim(tmp_path, exchange_source() + CHECKS)


def test_peer_disconnect_preserves_dispatch_irq(tmp_path: Path) -> None:
    run_nim(tmp_path, exchange_source() + r'''
proc trigger(timeout: bool) =
  if timeout:
    seedSaQuery(1, armed = true)
    env.saQueryReason = 7
    deliverSaExpiry()
  else:
    var indication = SmDeauthFrameView(vifIdx: 1, staIdx: 4,
      sa: vifs[1].macAddr, bssid: vifs[1].bssid, reason: 7)
    setFrameLen(addr indication, 26)
    discard sm_deauth_handler(addr indication)

for timeout in [false, true]:
  for incoming in [false, true]:
    setupSA(1, 4)
    interruptsEnabled = incoming
    trigger(timeout)
    doAssert printfCalls == 1 and printfInterruptsEnabled == incoming
    doAssert teardownInterruptsEnabled == incoming
    doAssert events[^1] == ("disconnect", cast[pointer](addr vifs[1]), 7'u16, 7'u16)
    doAssert interruptsEnabled == incoming

  setupSA(1, 4)
  onIrqRestore = proc() =
    inc rxVifEpochs[1]
    env.saQueryActive = 1
  trigger(timeout)
  doAssert printfCalls == 0 and events.len == 0 and interruptsEnabled
  doAssert currentState == SmIdleState and env.saQueryActive == 1
''')


def test_retired_queued_management_is_not_readmitted(tmp_path: Path) -> None:
    run_nim(tmp_path, exchange_source() + r'''
for kind in 0 .. 3:
  for replaced in 0 .. 2:
    setupSA(1, 4)
    var ticket = RxMgtIdentityNode(message: addr messageHeader,
      identity: RxStationIdentity(captured: true, associated: true, station: 4,
        vif: 1, epoch: stationEpochs[4], vifEpochs: rxVifEpochs))
    rxMgtIdentities = addr ticket
    doAssert rxMgtMessageCurrent(addr messageHeader) # Scheduler admitted it.
    case replaced
    of 1: inc rxVifEpochs[1]
    of 2: inc stationEpochs[4]
    else: discard
    # Same addresses, indexes, and association bits after slot reuse.
    if kind < 2:
      var indication = SmDeauthFrameView(vifIdx: 1, staIdx: 4, frameFlags: kind.uint8,
        sa: vifs[1].macAddr, bssid: vifs[1].bssid, reason: 7)
      setFrameLen(addr indication, 26)
      doAssert sm_deauth_handler(addr indication) == KeMsgConsumed
      doAssert printfCalls == (kind == 0 and replaced == 0).int
      doAssert pushCalls == (kind == 1 and replaced == 0).int
    else:
      seedSaQuery(1, armed = true)
      env.saQueryTransId = 0x3412
      var indication = SmSaQueryFrameView(vifIdx: 1, staIdx: 4,
        action: (kind - 2).uint8, transId: env.saQueryTransId)
      setFrameLen(addr indication, 4)
      sm_sa_query_handler(addr indication)
      doAssert pushCalls == (kind == 2 and replaced == 0).int
      doAssert timers.len == (kind == 3 and replaced == 0).int
      doAssert smSaQuery.armed == not (kind == 3 and replaced == 0)
    doAssert interruptsEnabled
    rxMgtIdentities = nil
''')


def test_sa_query_keeps_its_peer_and_frame_lease_across_callbacks(tmp_path: Path) -> None:
    run_nim(tmp_path, exchange_source() + r'''
for boundary in 0 .. 2:
  for retirement in 0 .. 2:
    setupSA(1, 4)
    let change = proc() =
      case retirement
      of 0: inc rxVifEpochs[1]
      of 1: inc stationEpochs[4]
      else: inc txResetEpoch
    case boundary
    of 0: onAllocate = change
    of 1: onPower = change
    else: onProtect = change
    doAssert sm_send_sa_query(4, 1, 0x1234) == -1
    doAssert pushCalls == 0 and getCalls == 1 and releases == 1
    doAssert not frameLeased
    doAssert protectCalls == (boundary == 2).int

for atProtection in [false, true]:
  setupSA(1, 4)
  let reuse = proc() =
    inc frameGeneration
    desc.staInfoIdx = 5
    desc.vifIdx = 0
    hw.frameLen = 123
    for byteValue in link.macHeader.mitems: byteValue = 0xA5
  if atProtection: onProtect = reuse
  else: onPower = reuse
  doAssert sm_send_sa_query(4, 1, 0x1234) == -1
  doAssert frameLeased and pushCalls == 0 and releases == 0
  doAssert desc.staInfoIdx == 5 and desc.vifIdx == 0 and hw.frameLen == 123
  for byteValue in link.macHeader: doAssert byteValue == 0xA5

# A matching response can retire the pending query during preparation.
for atProtection in [false, true]:
  setupSA(1, 4)
  seedSaQuery(1)
  let cancel = proc() =
    var response = SmSaQueryFrameView(staIdx: 4, vifIdx: 1, action: 1,
      transId: env.saQueryTransId)
    setFrameLen(addr response, 4)
    sm_sa_query_handler(addr response)
  if atProtection: onProtect = cancel
  else: onPower = cancel
  sm_issue_sa_query_request()
  doAssert env.saQueryActive == 0 and not smSaQuery.armed
  doAssert pushCalls == 0 and getCalls == 1 and releases == 1
  doAssert timers == @[("clear", 0x1009'u16, 0'u32, 0'u8)]
''')


def test_disconnect_provenance_separates_query_submission_from_peer_evidence(tmp_path: Path) -> None:
    run_nim(tmp_path, exchange_source() + r'''
proc prepareFrame(needsQuery: bool): SmDeauthFrameView =
  setupSA(1, 4)
  result = SmDeauthFrameView(vifIdx: 1, staIdx: 4, frameFlags: needsQuery.uint8,
    sa: vifs[1].macAddr, bssid: vifs[1].bssid, reason: 7)
  let frame = rxuMgtIndMsgAt(addr result)
  frame.frameLen = 26
  frame.frameCtrl = if needsQuery: 0xA0'u16 else: 0xC0'u16
  frame.freq = 2462
  frame.rssi = -42
  macDataFrameAt(addr frame.body[0]).seqCtrl = 0x1270

var incoming = prepareFrame(false)
macNow = 123
sm_deauth_handler(addr incoming)
doAssert nimFwDbgPeerDisconnect == [0x50454552'u32, 123, 0x04010007,
  0x127000C0, 0x01D6099E, 0]
incoming = prepareFrame(false)
macNow = 456
sm_deauth_handler(addr incoming)
doAssert nimFwDbgPeerDisconnect[1] == 123, "late event overwrote the first decision"

nimFwDbgPeerDisconnect = default(typeof(nimFwDbgPeerDisconnect))
incoming = prepareFrame(false)
onPrintf = proc() = inc rxVifEpochs[1]
sm_deauth_handler(addr incoming)
doAssert nimFwDbgPeerDisconnect[0] == 0
doAssert events.len == 0 and currentState == SmIdleState, "a retired peer reached teardown"

incoming = prepareFrame(true)
allocFail = true
sm_deauth_handler(addr incoming)
doAssert nimFwDbgPeerDisconnect[0] == 0 and env.saQueryActive == 1
allocFail = false
pushFail = true
macNow = smSaQuery.deadline
deliverSaExpiry()
pushFail = false
macNow = smSaQuery.deadline
deliverSaExpiry()
doAssert nimFwDbgPeerDisconnect[0] == 0
macNow = smSaQuery.deadline
deliverSaExpiry()
doAssert nimFwDbgPeerDisconnect == [0x50454552'u32, macNow, 0x04010007,
  0x127000A0, 0x02D6099E, 0x00000201]
''', "bl808WifiDiagLinkDrop")


def test_disconnect_record_retains_initiating_rx_protection(tmp_path: Path) -> None:
    run_nim(tmp_path, exchange_source() + r'''
for protection in [rxMgtProtectionUnknown, rxMgtVerifiedCcmp, rxMgtVerifiedBip, rxMgtWithoutProtection]:
  setupSA(1, 4)
  nimFwDbgPeerDisconnect = default(typeof(nimFwDbgPeerDisconnect))
  let viaQuery = protection == rxMgtWithoutProtection
  var msg = SmDeauthFrameView(vifIdx: 1, staIdx: 4, frameFlags: viaQuery.uint8,
    sa: vifs[1].macAddr, bssid: vifs[1].bssid, reason: 7)
  setFrameLen(addr msg, 26)
  var ticket = RxMgtIdentityNode(message: addr messageHeader,
    identity: RxStationIdentity(captured: true, associated: true, station: 4, vif: 1,
      epoch: stationEpochs[4], vifEpochs: rxVifEpochs, mgmtProtection: protection))
  rxMgtIdentities = if protection == rxMgtProtectionUnknown: nil else: addr ticket
  sm_deauth_handler(addr msg)
  rxMgtIdentities = nil
  if viaQuery:
    doAssert nimFwDbgPeerDisconnect[0] == 0
    # Another indication can reuse the storage before the query expires.
    ticket.identity.mgmtProtection = rxMgtVerifiedBip
    rxMgtIdentities = addr ticket
    for _ in 0 .. 2:
      macNow = smSaQuery.deadline
      deliverSaExpiry()
    rxMgtIdentities = nil
  doAssert nimFwDbgPeerDisconnect[0] == 0x50454552'u32
  doAssert nimFwDbgPeerDisconnect[4] shr 24 == (if viaQuery: 2'u32 else: 1'u32)
  doAssert nimFwDbgPeerDisconnect[5] shr 16 == protection.uint32
''', "bl808WifiDiagLinkDrop", "bl808WifiDiagPeerRxAdmission")


def test_peer_disconnect_freezes_keepalive_history_at_commit(tmp_path: Path) -> None:
    run_nim(tmp_path, exchange_source() + history_source() + r'''
for retireBeforeDecision in [false, true]:
  setupSA(1, 4)
  nimFwDbgPeerDisconnect = default(typeof(nimFwDbgPeerDisconnect))
  nimFwDbgTrafficProbeHistory = default(typeof(nimFwDbgTrafficProbeHistory))
  macNow = 90
  mmRecordTrafficProbeCompletion(0x80800000'u32)
  var msg = SmDeauthFrameView(vifIdx: 1, staIdx: 4,
    sa: vifs[1].macAddr, bssid: vifs[1].bssid, reason: 7)
  setFrameLen(addr msg, 26)
  var observedCommit = false
  onPrintf = proc() =
    macNow = 100
    mmRecordTrafficProbeCompletion(0x80010700'u32)
    if retireBeforeDecision:
      inc rxVifEpochs[1]
    else:
      onIrqRestore = proc() =
        observedCommit = true
        doAssert nimFwDbgPeerDisconnect[0..1] == [0x50454552'u32, 100]
        macNow = 110
        mmRecordTrafficProbeCompletion(0x40000000'u32)
  sm_deauth_handler(addr msg)
  doAssert observedCommit == not retireBeforeDecision
  doAssert nimFwDbgTrafficProbeHistory[0..6] ==
    [4'u32, 1, 0, 90, 0x80800000'u32, 100, 0x80010700'u32]

  # A replacement association must not overwrite the first valid trace.
  setupSA(1, 4)
  macNow = 200
  mmRecordTrafficProbeCompletion(0x80800000'u32)
  if retireBeforeDecision:
    doAssert nimFwDbgPeerDisconnect[0] == 0
    doAssert nimFwDbgTrafficProbeHistory[0] == 6
    doAssert nimFwDbgTrafficProbeHistory[7..8] == [200'u32, 0x80800000'u32]
  else:
    doAssert nimFwDbgPeerDisconnect[0..1] == [0x50454552'u32, 100]
    doAssert nimFwDbgTrafficProbeHistory[0] == 4
  doAssert interruptsEnabled
''', "bl808WifiDiagLinkDrop", "bl808WifiDiagTrafficProbeHistory")
