"""Execute SM dispatch/ownership decisions independently of the replay model."""

from pathlib import Path
import shutil
import subprocess

import pytest

from test_wifi_disconnect_tx import FW, ROOT, procedure


PLATFORM = r"""
import bl808/wifi/fw_constants/states
import bl808/wifi/fw_constants/status_codes
import bl808/wifi/fw/mgmt_replay
const
  TASK_SM = 4'u8
  SM_SA_QUERY_TIMEOUT_IND_MSG = 0x1009'u16
  MAX_VIFS = 2
  STA_INFO_TAB_ENTRIES = 7
  KeMsgConsumed = 0.cint
  KeMsgSaved = 2.cint
  SM_RSP_TIMEOUT_IND = 0x1006'u16
  MACHW_RX_CNTRL_REG = 0'u
type
  Vif = object
    macAddr, bssid: array[6, uint8]
    state, staIdx, vifIdx: uint8
  Sta = object
    instNbr: uint8
  ConnectInfo = object
    vifIdx: uint8
    authRetry: uint8
  Env = object
    connectInfo: pointer
    saQueryActive, saQueryRetryCount, saQueryStaIdx: uint8
    saQueryReason: uint16
    authRetryLimit: uint32
  TxContext = object
    connectFlags: uint8
  AuthContext = object
    authType: uint8
  WpaCallbacks = object
    authTimeout: pointer
  Event = tuple[kind: string, status, reason: uint16]
  MessageHeader = object
    paramLen: uint32
    id: uint16
    destId, srcId: uint8
  MgtPrefix {.packed.} = object
    frameLen, frameCtrl: uint16
    padding: array[28, uint8]
    body: UncheckedArray[uint8]
var
  header = MessageHeader(paramLen: 64)
  vifs: array[2, Vif]
  stas: array[7, Sta]
  env: Env
  conn: ConnectInfo
  currentState: uint16
  stateScript: seq[uint16]
  events: seq[Event]
  stateWrites: seq[uint16]
  smConnecting: bool
  rxMessageRetired: bool
  txResetEpoch: uint32
  nimFwDbgAuthSmDispatch, nimFwDbgAuthSmState, nimFwDbgDeauthHandler: uint32
  forcedDeauthResult: cint
  wpa_cbs: pointer
  wpa: WpaCallbacks
  nimFwDbgSmRspTimeout, nimFwDbgSmRspTimeoutState, nimFwDbgSmRspTimeoutRxCtrl: uint32

proc vifChannelForIdx(i: uint8): ptr Vif = addr vifs[i]
proc keMsgHdrFromPayload(p: pointer): ptr MessageHeader = addr header
proc rxMgtMessageCurrent(header: pointer): bool = not rxMessageRetired
proc rxuMgtIndMsgAt(p: pointer): ptr MgtPrefix = cast[ptr MgtPrefix](p)
proc managementReasonBodyAt(p: pointer): ptr ManagementReasonBodyView =
  cast[ptr ManagementReasonBodyView](p)
proc setFrameLen(p: pointer; length: uint16) = rxuMgtIndMsgAt(p).frameLen = length
proc staInfoForIdx(i: uint8): ptr Sta = addr stas[i]
proc smEnvView(): ptr Env = addr env
proc connectInfoView(p: pointer): ptr ConnectInfo = cast[ptr ConnectInfo](p)
proc connectInfoAuthRetry(p: pointer): ptr uint8 = addr connectInfoView(p).authRetry
proc wpaCallbacks(): ptr WpaCallbacks = addr wpa
proc regRead(address: uint): uint32 = 0
proc smDeauthFrameView(p: pointer): ptr SmDeauthFrameView = cast[ptr SmDeauthFrameView](p)
proc rxuMgtDispatchView(p: pointer): ptr RxuMgtDispatchView = cast[ptr RxuMgtDispatchView](p)
proc ke_state_get(task: uint8): uint16 =
  doAssert task == TASK_SM
  if stateScript.len != 0:
    result = stateScript[0]
    stateScript.delete(0)
  else: result = currentState
proc ke_state_set(task: uint8; state: uint16) =
  doAssert task == TASK_SM
  stateWrites.add(state)
  currentState = state
proc ke_timer_set(id: uint16; task: uint8; delay: uint32) =
  doAssert task == TASK_SM and id == SM_RSP_TIMEOUT_IND
proc smRspTimeoutCapture(p: pointer): tuple[captured: bool,
    owner: tuple[connection: pointer, state: uint16]] =
  (true, (env.connectInfo, ke_state_get(TASK_SM)))
proc smRspTimeoutCurrent(timeout: typeof(smRspTimeoutCapture(nil))): bool = true
proc sm_connect_ind(status, reason: uint16) = events.add(("connect", status, reason))
proc sm_disconnect_process(vif: pointer; status, reason: uint16) =
  events.add(("disconnect", status, reason))
proc sm_issue_sa_query_request() = events.add(("query", 0'u16, 0'u16))
proc testPrintf(fmt: cstring) {.cdecl, varargs.} = discard
proc blOpsFunc(offset: int): pointer = cast[pointer](testPrintf)
proc sm_auth_handler(p: pointer) = events.add(("auth", 0'u16, 0'u16))
proc sm_assoc_rsp_handler(p: pointer) = events.add(("assoc", 0'u16, 0'u16))
proc sm_auth_start() = events.add(("restart", 0'u16, 0'u16))
proc sm_sa_query_handler(p: pointer) = events.add(("sa", 0'u16, 0'u16))
proc sm_auth_send_pre(sequence: uint16; challenge: pointer) =
  doAssert sequence == 1 and challenge == nil
  events.add(("retry-auth", 0'u16, 0'u16))
proc sm_assoc_req_send_pre() = events.add(("retry-assoc", 0'u16, 0'u16))
proc reset(state: uint16) =
  header.paramLen = 64
  rxMessageRetired = false
  currentState = state
  stateScript.setLen(0)
  events.setLen(0)
  stateWrites.setLen(0)
  vifs = default(typeof(vifs))
  stas = default(typeof(stas))
  for i in 0 ..< 2:
    vifs[i].state = 1
    vifs[i].staIdx = i.uint8
    vifs[i].vifIdx = i.uint8
    vifs[i].macAddr = [2'u8, 1, 2, 3, 4, i.uint8]
    vifs[i].bssid = [4'u8, 5, 6, 7, 8, i.uint8]
    stas[i].instNbr = i.uint8
  conn.vifIdx = 0
  conn.authRetry = 0
  env = Env(connectInfo: addr conn, authRetryLimit: 3)
  smConnecting = true
"""

BASELINE = r"""
reset(6)
var msg = RxuMgtDispatchView(frameCtrl: 0xB0)
setFrameLen(addr msg, 6)
rxu_mgt_ind_handler_sm(addr msg)
doAssert events.len == 1 and events[0].kind == "auth",
  "state 6 must receive authentication responses"
"""

DISPATCH_CHECKS = r"""
for state in 0'u16 .. 10'u16:
  for subtype in [0xB0'u16, 0x10, 0x30, 0xC0, 0xA0, 0xD0, 0x80, 0x40]:
    for category in [0'u8, 8]:
      reset(state)
      forcedDeauthResult = KeMsgSaved
      var msg = RxuMgtDispatchView(frameCtrl: subtype, category: category)
      let minimum =
        case subtype
        of 0xB0'u16, 0x10'u16, 0x30'u16: 6'u16
        of 0xC0'u16, 0xA0'u16: 26'u16
        of 0xD0'u16: 4'u16
        else: 0'u16
      setFrameLen(addr msg, minimum)
      let status = rxu_mgt_ind_handler_sm(addr msg)
      var expected = ""
      var expectedResult = KeMsgConsumed
      case subtype
      of 0xB0:
        if state == 6: expected = "auth"
      of 0x10, 0x30:
        if state == 8: expected = "assoc"
      of 0xC0, 0xA0:
        if state in [0'u16, 9'u16]:
          expected = "deauth"
          expectedResult = KeMsgSaved
        elif state == 6: expected = "restart"
      of 0xD0:
        if category == 8: expected = "sa"
      else: discard
      doAssert status == expectedResult
      doAssert events.len == (if expected == "": 0 else: 1)
      if expected != "": doAssert events[0].kind == expected
"""

DEAUTH_CHECKS = r"""
for state in 0'u16 .. 10'u16:
  for vif in 0'u8 .. 1'u8:
    for connectVif in [0'u8, 1, 255]:
      reset(state)
      conn.vifIdx = connectVif
      if connectVif == 255: env.connectInfo = nil
      var msg = SmDeauthFrameView(vifIdx: vif, staIdx: vif,
        sa: vifs[vif].macAddr, bssid: vifs[vif].bssid, reason: 0xBEEF)
      setFrameLen(addr msg, 26)
      let status = sm_deauth_handler(addr msg)
      let save = state == 10 or (state != 0 and connectVif != vif)
      doAssert status == (if save: KeMsgSaved else: KeMsgConsumed)
      doAssert smConnecting, "message deferral must not alter connection ownership"
      if save: doAssert events.len == 0 and stateWrites.len == 0
      elif state == 0:
        doAssert events == @[("disconnect", 7'u16, 0xBEEF'u16)]
      else:
        doAssert events == @[("connect", 6'u16, 0xBEEF'u16)]

for mismatch in 0 .. 11:
  reset(10)
  var msg = SmDeauthFrameView(vifIdx: 0, sa: vifs[0].macAddr, bssid: vifs[0].bssid)
  setFrameLen(addr msg, 26)
  if mismatch < 6: msg.bssid[mismatch] = msg.bssid[mismatch] xor 0x80
  else: msg.sa[mismatch - 6] = msg.sa[mismatch - 6] xor 0x80
  doAssert sm_deauth_handler(addr msg) == KeMsgConsumed
  doAssert events.len == 0 and smConnecting

reset(9)
stateScript = @[9'u16, 10'u16]
var message: array[64, uint8]
cast[ptr SmDeauthFrameView](addr message[0])[] = SmDeauthFrameView(vifIdx: 0,
  sa: vifs[0].macAddr, bssid: vifs[0].bssid)
setFrameLen(addr message[0], 26)
cast[ptr RxuMgtDispatchView](addr message[0]).frameCtrl = 0xC0
doAssert rxu_mgt_ind_handler_sm(addr message[0]) == KeMsgSaved
doAssert events.len == 0 and smConnecting

reset(0)
var query = SmDeauthFrameView(vifIdx: 1, staIdx: 1, frameFlags: 1,
  sa: vifs[1].macAddr, bssid: vifs[1].bssid, reason: 6)
setFrameLen(addr query, 26)
doAssert sm_deauth_handler(addr query) == KeMsgConsumed
doAssert env.saQueryActive == 1 and env.saQueryStaIdx == 1
doAssert events == @[("query", 0'u16, 0'u16)]
doAssert sm_deauth_handler(nil) == KeMsgConsumed

reset(0)
var short = SmDeauthFrameView(vifIdx: 0, staIdx: 0,
  sa: vifs[0].macAddr, bssid: vifs[0].bssid, reason: 6)
setFrameLen(addr short, 26)
header.paramLen = 57
doAssert sm_deauth_handler(addr short) == KeMsgConsumed
doAssert events.len == 0
header.paramLen = 64
setFrameLen(addr short, 25)
doAssert sm_deauth_handler(addr short) == KeMsgConsumed
doAssert events.len == 0
header.paramLen = 58
setFrameLen(addr short, 27)
doAssert sm_deauth_handler(addr short) == KeMsgConsumed
doAssert events.len == 0

for subtype in [0xC0'u16, 0xA0'u16]:
  for needsQuery in [false, true]:
    reset(0)
    var extended: array[62, uint8]
    let ind = addr extended[0]
    smDeauthFrameView(ind)[] = SmDeauthFrameView(vifIdx: 1, staIdx: 1,
      frameFlags: needsQuery.uint8, sa: vifs[1].macAddr, bssid: vifs[1].bssid,
      reason: 0x1234) # This word is HT Control, not the reason.
    rxuMgtIndMsgAt(ind).frameCtrl = 0x8000 or subtype
    setFrameLen(ind, 29)
    doAssert sm_deauth_handler(ind) == KeMsgConsumed and events.len == 0
    currentState = 6
    doAssert rxu_mgt_ind_handler_sm(ind) == KeMsgConsumed and events.len == 0
    currentState = 0
    setFrameLen(ind, 30)
    header.paramLen = 61
    doAssert sm_deauth_handler(ind) == KeMsgConsumed and events.len == 0
    header.paramLen = 62
    extended[60] = 7
    doAssert rxu_mgt_ind_handler_sm(ind) == KeMsgConsumed
    if needsQuery:
      doAssert events == @[("query", 0'u16, 0'u16)] and env.saQueryReason == 7
    else:
      doAssert events == @[("disconnect", 7'u16, 7'u16)]
"""

SHORT_MGT = r"""
for sample in [(0xB0'u16, 6'u16, 6'u16),
               (0x10'u16, 6'u16, 8'u16),
               (0x30'u16, 6'u16, 8'u16),
               (0xC0'u16, 26'u16, 6'u16),
               (0xA0'u16, 26'u16, 6'u16),
               (0xD0'u16, 4'u16, 6'u16)]:
  for malformed in 0 .. 2:
    reset(sample[2])
    var msg = RxuMgtDispatchView(frameCtrl: sample[0], category: 8)
    setFrameLen(addr msg, sample[1])
    case malformed
    of 0: header.paramLen = 32'u32 + sample[1].uint32 - 1
    of 1: setFrameLen(addr msg, sample[1] - 1)
    else:
      header.paramLen = 32'u32 + sample[1].uint32
      setFrameLen(addr msg, sample[1] + 1)
    doAssert rxu_mgt_ind_handler_sm(addr msg) == KeMsgConsumed
    doAssert events.len == 0 and stateWrites.len == 0

reset(6)
var msg = RxuMgtDispatchView(frameCtrl: 0xB0)
setFrameLen(addr msg, 6)
for length in 0'u32 .. 8'u32:
  header.paramLen = length
  doAssert rxu_mgt_ind_handler_sm(addr msg) == KeMsgConsumed
  doAssert events.len == 0
"""

STATE_CHECKS = r"""
var auth = newSeq[uint8](38)
auth[2] = 0xB0
auth[34] = 2
var assoc = newSeq[uint8](38)
assoc[2] = 0x10
assoc[36] = 7
for state in 0'u16 .. 10'u16:
  doAssert (replayClassifyRxuMgtInd(auth, state).kind == wrAuthOpenSuccess) == (state == 6)
  doAssert (replayClassifyRxuMgtInd(assoc, state).kind == wrAssocSuccess) == (state == 8)
  for retries in [0'u32, 3]:
    reset(state)
    conn.authRetry = retries.uint8
    doAssert sm_rsp_timeout_ind_handler(nil) == KeMsgConsumed
    let model = replayMgmtTimeoutAction(state, retries, 3)
    if state in [6'u16, 8'u16]:
      if retries == 3:
        doAssert model == wrTimeoutFail
        doAssert events == @[("connect", 11'u16, 0xFFFF'u16)]
      else:
        doAssert conn.authRetry == 1
        doAssert model == (if state == 6: wrTimeoutRetryAuth else: wrTimeoutRetryAssoc)
        doAssert events == @[((if state == 6: "retry-auth" else: "retry-assoc"), 0'u16, 0'u16)]
    else:
      doAssert model == wrTimeoutIgnored
      doAssert events.len == 0 and conn.authRetry == retries.uint8
"""


def platform() -> str:
    layout = (FW / "layout_types.nim").read_text()
    declarations = "type\n"
    for name in ["SmDeauthFrameView", "RxuMgtDispatchView", "ManagementReasonBodyView"]:
        declarations += "  " + name + layout.split("  " + name, 1)[1].split("\n\n  ", 1)[0] + "\n"
    # Host helpers reference the real fixed-width message structures.
    return (PLATFORM.replace("type\n  Vif", declarations + "\ntype\n  Vif", 1)
            + procedure(layout, "rxMacHeaderLen"))


def run_nim(tmp_path: Path, code: str) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("nim is not installed")
    path = tmp_path / "sm_dispatch.nim"
    path.write_text(code)
    result = subprocess.run(
        [nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on", "--skipUserCfg:on",
         "--checks:on", f"--path:{ROOT / 'src'}", f"--nimcache:{tmp_path / 'nimcache'}",
         f"-o:{tmp_path / 'check'}", str(path)],
        cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
    )
    assert result.returncode == 0, result.stdout


def test_sm_auth_dispatch_wait_state(tmp_path: Path) -> None:
    task = (FW / "task_handlers.nim").read_text()
    scan = (FW / "scan_station_ap_me.nim").read_text()
    stub = "\nproc sm_deauth_handler(p: pointer): cint {.discardable.} = KeMsgSaved\n"
    run_nim(tmp_path, platform() + stub + procedure(scan, "smRxFrameFits")
            + procedure(task, "rxu_mgt_ind_handler_sm") + BASELINE)


def test_sm_management_dispatch_matrix(tmp_path: Path) -> None:
    task = (FW / "task_handlers.nim").read_text()
    scan = (FW / "scan_station_ap_me.nim").read_text()
    stub = """
proc sm_deauth_handler(p: pointer): cint {.discardable.} =
  events.add(("deauth", 0'u16, 0'u16))
  forcedDeauthResult
"""
    run_nim(tmp_path, platform() + stub + procedure(scan, "smRxFrameFits")
            + procedure(task, "rxu_mgt_ind_handler_sm") + DISPATCH_CHECKS + SHORT_MGT + r'''
for subtype in [0xA0'u16, 0xC0'u16]:
  reset(SmAuthenticatingState)
  rxMessageRetired = true
  var stale = RxuMgtDispatchView(frameCtrl: subtype)
  setFrameLen(addr stale, 26)
  doAssert rxu_mgt_ind_handler_sm(addr stale) == KeMsgConsumed
  doAssert events.len == 0 and stateWrites.len == 0
''')


def test_deauth_message_retention(tmp_path: Path) -> None:
    from test_wifi_sa_query import IRQ_STATE, ownership_source

    task = (FW / "task_handlers.nim").read_text()
    sm = (FW / "scan_station_ap_me.nim").read_text()
    run_nim(tmp_path, IRQ_STATE + platform() + """
proc macTimeNow(): uint32 = 0
proc ke_timer_clear(id: uint16; task: uint8) = discard
"""
            + ownership_source(real_rx=False, tx_path=False) + procedure(sm, "smRxFrameFits")
            + procedure(sm, "sm_deauth_handler")
            + procedure(task, "rxu_mgt_ind_handler_sm") + DEAUTH_CHECKS)


def test_sm_wait_states_and_timeouts(tmp_path: Path) -> None:
    task = (FW / "task_handlers.nim").read_text()
    # Full builder publication is exercised in test_wifi_station_tx_build.py.
    run_nim(tmp_path, platform()
            + procedure(task, "sm_rsp_timeout_ind_handler") + STATE_CHECKS)
