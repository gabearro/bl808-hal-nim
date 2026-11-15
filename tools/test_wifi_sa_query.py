"""Run SA Query TX/RX, retry, transaction and timeout logic on the host."""

from pathlib import Path
import shutil
import subprocess

import pytest

from test_wifi_disconnect_tx import FW, PLATFORM, ROOT, procedure


EXTENSION = r"""
const
  RC_PRNG_MULT = 1103515245'u32
  RC_PRNG_INCR = 12345'u32
  SM_SA_QUERY_TIMEOUT_IND_MSG = 0x1009'u16
  SmIdleState = 0'u8
  KeMsgConsumed = 0.cint
  KeMsgSaved = 2.cint
type
  SaQueryActionBodyView {.packed.} = object
    category, action: uint8
    transId: uint16
  TimerCall = tuple[kind: string, id: uint16, delay: uint32, active: uint8]
  PlatformLogFunc = proc(level, severity: uint32; file: pointer;
                         line: uint32) {.cdecl, varargs.}
var
  timers: seq[TimerCall]
  smQueryPrngState = 1'u32
  rcPrngCalls, printfCalls: int
  currentState: uint8
  smConnecting: bool
  nimFwDbgDeauthHandler: uint32
  printfReason: uint32

proc saQueryActionBodyAt(p: pointer): ptr SaQueryActionBodyView = cast[ptr SaQueryActionBodyView](p)
proc smSaQueryFrameView(p: pointer): ptr SmSaQueryFrameView = cast[ptr SmSaQueryFrameView](p)
proc smDeauthFrameView(p: pointer): ptr SmDeauthFrameView = cast[ptr SmDeauthFrameView](p)
proc KE_FIRST_MSG(task: uint16): uint16 = task shl 10
proc ke_state_get(task: uint8): uint8 = currentState
proc ke_timer_set(id: uint16; task: uint8; delay: uint32) =
  doAssert task == TASK_SM
  timers.add(("set", id, delay, env.saQueryActive))
proc ke_timer_clear(id: uint16; task: uint8) =
  doAssert task == TASK_SM
  timers.add(("clear", id, 0'u32, env.saQueryActive))
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
proc blOpsFunc(offset: int): pointer =
  doAssert offset == 4
  cast[pointer](testPrintf)
proc setupSA(vif, sta: uint8) =
  reset(vif, sta)
  env.saQueryActive = 0
  env.saQueryRetryCount = 0
  env.saQueryStaIdx = sta
  env.saQueryTransId = 0
  env.saQueryReason = 7
  stations[sta].instNbr = vif
  stations[sta].controlPortState = 2
  vifs[vif].bssid = stations[sta].macAddr
  timers.setLen(0)
  currentState = 0
  smConnecting = false
  printfCalls = 0
  printfReason = 0
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
discard sm_send_sa_query(4, 0, 0xFFFF)
doAssert releases == 1
setupSA(0, 0)
doAssert sm_send_sa_query(255, 0, 1) == -1
doAssert getCalls == 0

# Private random stream is not perturbed by rate-control calls.
smQueryPrngState = 1
var expectedPrng = 1'u32
for i in 0 ..< 32:
  setupSA(1, 4)
  env.saQueryActive = 1
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
    env.saQueryActive = 1
    env.saQueryTransId = 0xBEEF
    var message = SmSaQueryFrameView(staIdx: 4, vifIdx: 1, action: action, transId: 0xBEEF)
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
      doAssert timers == @[("clear", 0x1009'u16, 0'u32, 1'u8)]
    else:
      doAssert timers.len == 0 and pushCalls == 0 and env.saQueryActive == 1

setupSA(1, 4)
env.saQueryActive = 1
env.saQueryRetryCount = 2
env.saQueryReason = 0xBEEF
doAssert sm_sa_query_timeout_ind_handler(nil) == 0
doAssert env.saQueryRetryCount == 1 and pushCalls == 1 and env.saQueryActive == 1
doAssert sm_sa_query_timeout_ind_handler(nil) == 0
doAssert env.saQueryRetryCount == 0 and pushCalls == 2 and env.saQueryActive == 1
doAssert sm_sa_query_timeout_ind_handler(nil) == 0
doAssert env.saQueryActive == 0 and pushCalls == 2 and printfCalls == 1
doAssert printfReason == 0xBEEF
doAssert events[^1] == ("disconnect", cast[pointer](addr vifs[1]), 7'u16, 0xBEEF'u16)
let completedEvents = events.len
sm_sa_query_timeout_ind_handler(nil)
doAssert events.len == completedEvents

# Drive the actual deauth-to-query initiation path and complete the exchange.
setupSA(1, 4)
var deauth = SmDeauthFrameView(vifIdx: 1, staIdx: 4, frameFlags: 1,
  sa: vifs[1].macAddr, bssid: vifs[1].bssid, reason: 6)
sm_deauth_handler(addr deauth)
doAssert env.saQueryActive == 1 and env.saQueryRetryCount == 2
doAssert env.saQueryStaIdx == 4 and env.saQueryReason == 6
doAssert pushCalls == 1 and timers.len == 1 and timers[0].id == 0x1009
sm_deauth_handler(addr deauth)
doAssert pushCalls == 1
var response = SmSaQueryFrameView(vifIdx: 1, staIdx: 4, action: 1,
  transId: env.saQueryTransId)
sm_sa_query_handler(addr response)
doAssert env.saQueryActive == 0 and timers[^1].kind == "clear"
let countAfterReply = events.len
sm_sa_query_timeout_ind_handler(nil)
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
env.saQueryActive = 1
allocFail = true
sm_issue_sa_query_request()
doAssert timers == @[("set", 0x1009'u16, 100000'u32, 1'u8)]
doAssert pushCalls == 0
setupSA(1, 4)
response = SmSaQueryFrameView(vifIdx: 1, staIdx: 4, action: 1, transId: 0)
sm_sa_query_handler(addr response)
doAssert env.saQueryActive == 0 and timers.len == 0
sm_sa_query_handler(nil)
response.vifIdx = 255
sm_sa_query_handler(addr response)
doAssert timers.len == 0 and pushCalls == 0
"""


def run_nim(tmp_path: Path, source: str) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("nim is not installed")
    path = tmp_path / "sa_query.nim"
    path.write_text(source)
    result = subprocess.run(
        [nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on", "--skipUserCfg:on",
         "--checks:on", f"--nimcache:{tmp_path / 'nimcache'}", f"-o:{tmp_path / 'check'}", str(path)],
        cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
    )
    assert result.returncode == 0, result.stdout


def platform() -> str:
    layout = (FW / "layout_types.nim").read_text()
    declarations = "type\n"
    for name in ["SmSaQueryFrameView", "SmDeauthFrameView"]:
        declarations += "  " + name + layout.split("  " + name, 1)[1].split("\n\n  ", 1)[0] + "\n"
    return PLATFORM + declarations + EXTENSION


def test_sa_query_tx_contract(tmp_path: Path) -> None:
    source = (FW / "scan_station_ap_me.nim").read_text()
    run_nim(tmp_path, platform() + procedure(source, "sm_send_sa_query") + TX_BASELINE)


def test_sa_query_exchange_and_timeout(tmp_path: Path) -> None:
    source = (FW / "scan_station_ap_me.nim").read_text()
    tasks = (FW / "task_handlers.nim").read_text()
    procedures = "".join(procedure(source, name) for name in [
        "sm_send_sa_query", "sm_issue_sa_query_request", "sm_sa_query_handler",
    ])
    procedures += procedure(tasks, "sm_sa_query_timeout_ind_handler")
    procedures += procedure(source, "sm_deauth_handler")
    run_nim(tmp_path, platform() + procedures + CHECKS)
