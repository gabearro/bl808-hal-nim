"""Exercise bounded authentication responses and connection-owned callbacks."""

from pathlib import Path

import pytest

from test_wifi_assoc_response import source as association_source
from test_wifi_auth_frames import layouts
from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program


EXTRA = r'''
const WLAN_FW_AUTHENTICATION_FAIILURE = 2
var
  wpa_cbs: pointer
  callbacks: array[16, pointer]
  saeResult: int32
  saeBodies: seq[seq[uint8]]
  authRequests: seq[tuple[sequence: uint16, challenge: seq[uint8]]]
  associations, warnings: int
  onSae, onLog: proc()
  nimFwDbgAuthHandler, nimFwDbgAuthHandlerLast, nimFwDbgAuthOpenSuccess: uint32
proc smAuthFrameView(p: pointer): ptr SmAuthFrameView = cast[ptr SmAuthFrameView](p)
proc smAuthSaeBodyPtr(p: ptr SmAuthFrameView): pointer = addr p.saeBodyFirst
proc smAuthSharedChallengePtr(p: ptr SmAuthFrameView): pointer = addr p.sharedChallengeFirst
proc saeHandler(body: pointer; length, sequence: uint16; context: pointer): int32 {.cdecl.} =
  doAssert context == nil
  var bytes = newSeq[uint8](length.int)
  if length > 0: copyMem(addr bytes[0], body, length.int)
  saeBodies.add(bytes)
  invoke(onSae)
  saeResult
proc authLog(a, b: uint32; text: pointer; line, value: uint32) {.cdecl.} = invoke(onLog)
proc getLogFunc(index: int): pointer = cast[pointer](authLog)
proc assert_warn(a, b: cstring; line: int) = inc warnings
proc sm_auth_send_pre(sequence: uint16; challenge: pointer) =
  var bytes: seq[uint8]
  if challenge != nil:
    bytes = newSeq[uint8](128)
    copyMem(addr bytes[0], challenge, 128)
  authRequests.add((sequence, bytes))
proc sm_assoc_req_send_pre() = inc associations
proc authResponse(algorithm, sequence: uint16; status = 0'u16;
                  body: openArray[uint8] = []): pointer =
  result = response(body, status)
  state = SmAuthenticatingState
  conn.authType = algorithm.uint8
  conn.authRetryGate = 0
  conn.retry = 7
  let frame = smAuthFrameView(result)
  frame.authAlgo = algorithm
  frame.authSeq = sequence
  frame.statusCode = status
  rxuMgtDispatchView(result).frameCtrl = 0xB0
  callbacks = default(typeof(callbacks))
  callbacks[15] = cast[pointer](saeHandler)
  wpa_cbs = addr callbacks
  saeResult = 0
  saeBodies.setLen(0)
  authRequests.setLen(0)
  associations = 0
  warnings = 0
  onSae = nil
  onLog = nil
'''


def source(trace: bool = False) -> str:
    code = association_source(trace).replace(
        "vifIdx, retry: uint8", "vifIdx, retry, authType, authRetryGate: uint8", 1,
    )
    code += layouts("SmAuthFrameView") + EXTRA
    code += procedure((FW / "station_tx_build.nim").read_text(), "smTxCapture")
    return code + procedure((FW / "scan_station_ap_me.nim").read_text(), "sm_auth_handler")


CASES = {
    "failure_status_order": r'''
let p = authResponse(0, 2, 17)
sm_auth_handler(p)
doAssert failures == @[(2'u16, 17'u16)]
doAssert associations == 0 and authRequests.len == 0
finish(p)
''',
    "status_13_does_not_start_association": r'''
let p = authResponse(0, 2, 13)
sm_auth_handler(p)
doAssert failures == @[(2'u16, 13'u16)] and associations == 0
finish(p)
''',
    "sae_failure_finishes_attempt": r'''
for status in [-9'i32, -1, 1, 7]:
  let p = authResponse(3, 2, body = [1'u8, 2, 3])
  saeResult = status
  sm_auth_handler(p)
  doAssert failures == @[(2'u16, 0'u16)]
  doAssert clears == @[SM_RSP_TIMEOUT_IND] and associations == 0
  finish(p)
''',
    "missing_sae_callback": r'''
for missingTable in [false, true]:
  let p = authResponse(3, 2)
  if missingTable: wpa_cbs = nil
  else: callbacks[15] = nil
  sm_auth_handler(p)
  doAssert failures == @[(2'u16, 0'u16)] and associations == 0
  finish(p)
''',
    "open_and_shared_completion": r'''
for algorithm in [0'u16, 1]:
  let p = authResponse(algorithm, if algorithm == 0: 2'u16 else: 4'u16)
  sm_auth_handler(p)
  doAssert associations == 1 and conn.retry == 0
  doAssert clears == @[SM_RSP_TIMEOUT_IND] and failures.len == 0
  finish(p)
''',
    "shared_fallback": r'''
let p = authResponse(1, 2, 13)
conn.authRetryGate = 1
sm_auth_handler(p)
doAssert conn.authType == 0 and authRequests.len == 1
doAssert authRequests[0].sequence == 1 and associations == 0 and failures.len == 0
finish(p)
''',
    "sae_success_and_retry": r'''
for sequence in 1'u16 .. 3'u16:
  let p = authResponse(3, sequence, body = [9'u8, 8, 7])
  sm_auth_handler(p)
  doAssert saeBodies == @[@[9'u8, 8, 7]] and failures.len == 0
  doAssert clears == @[SM_RSP_TIMEOUT_IND]
  doAssert authRequests.len == (if sequence == 1: 1 else: 0)
  doAssert associations == (if sequence == 2: 1 else: 0)
  if sequence == 1: doAssert authRequests[0].sequence == 2
  if sequence == 2: doAssert conn.retry == 0
  finish(p)
let p = authResponse(3, 1)
saeResult = -8
let generation = smTxSerials[1]
sm_auth_handler(p)
doAssert clears.len == 0 and failures.len == 0 and associations == 0
doAssert smTxSerials[1] == generation
finish(p)
''',
    "actual_truncated_storage": r'''
let initial = authResponse(0, 2)
finish(initial)
for length in 0'u32 .. 37'u32:
  let p = newMessage(length)
  if length >= 2: cast[ptr uint16](p)[] = 6
  sm_auth_handler(p)
  doAssert clears.len == 0 and associations == 0 and failures.len == 0
  finish(p)
''',
    "declared_body_exceeds_payload": r'''
let p = authResponse(3, 2)
smAuthFrameView(p).frameLen = 7
sm_auth_handler(p)
doAssert saeBodies.len == 0 and clears.len == 0 and associations == 0
finish(p)
''',
    "short_body": r'''
for length in 0'u16 .. 5'u16:
  let p = authResponse(0, 2)
  smAuthFrameView(p).frameLen = length
  sm_auth_handler(p)
  doAssert clears.len == 0 and associations == 0 and failures.len == 0
  finish(p)
''',
    "wrong_route_or_owner": r'''
for mutation in 0 .. 6:
  let p = authResponse(0, 2)
  case mutation
  of 0: rxuMgtDispatchView(p).vifIdx = 0
  of 1: rxuMgtDispatchView(p).staIdx = 3
  of 2: rxuMgtDispatchView(p).frameCtrl = 0x10
  of 3: state = SmAssocRspState
  of 4: sm.connectInfo = nil
  of 5: sm.connectIndMsg = nil
  else: vif.staIdx = 7
  sm_auth_handler(p)
  doAssert clears.len == 0 and associations == 0 and failures.len == 0
  finish(p)
''',
    "timer_callback_replaces_owner": r'''
for mutation in 0 .. 4:
  let p = authResponse(0, 2)
  onClear = proc() =
    case mutation
    of 0: replaceOwner()
    of 1: inc rxVifEpochs[1]
    of 2: inc stationEpochs[2]
    of 3: inc smTxSerials[1]
    else: sm.connectIndMsg = addr otherInd
  sm_auth_handler(p)
  doAssert associations == 0 and conn.retry == 7 and failures.len == 0
  finish(p)
''',
    "sae_callback_replaces_owner": r'''
let p = authResponse(3, 2)
onSae = replaceOwner
sm_auth_handler(p)
doAssert saeBodies.len == 1 and clears.len == 0 and associations == 0
doAssert conn.retry == 7 and failures.len == 0
finish(p)
''',
    "failure_log_replaces_owner": r'''
let p = authResponse(3, 2)
saeResult = 7
onLog = replaceOwner
sm_auth_handler(p)
doAssert failures.len == 0 and associations == 0
finish(p)
''',
    "owned_shared_challenge": r'''
var challenge: array[130, uint8]
challenge[0] = 16
challenge[1] = 128
for i in 2 ..< challenge.len: challenge[i] = (i xor 0xA5).uint8
let p = authResponse(1, 2, body = challenge)
onClear = proc() = zeroMem(cast[pointer](cast[uint](p) + 40), 128)
sm_auth_handler(p)
doAssert authRequests.len == 1 and authRequests[0].sequence == 3
for i in 0 ..< 128: doAssert authRequests[0].challenge[i] == challenge[i + 2]
finish(p)
''',
    "invalid_shared_challenge_keeps_timer": r'''
for length in [0, 1, 129, 130]:
  var challenge = newSeq[uint8](length)
  if length > 0: challenge[0] = 16
  if length > 1: challenge[1] = 127
  let p = authResponse(1, 2, body = challenge)
  let generation = smTxSerials[1]
  sm_auth_handler(p)
  doAssert clears.len == 0 and authRequests.len == 0 and associations == 0
  doAssert smTxSerials[1] == generation
  finish(p)
''',
    "unsupported_algorithm_keeps_timer": r'''
for algorithm in [2'u16, 4, 255, 65535]:
  let p = authResponse(algorithm, 2)
  let generation = smTxSerials[1]
  sm_auth_handler(p)
  doAssert clears.len == 0 and failures.len == 0 and associations == 0
  doAssert smTxSerials[1] == generation
  finish(p)
''',
}


@pytest.mark.parametrize("case", CASES)
@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_auth_response(tmp_path: Path, case: str, mode: str) -> None:
    run_program(tmp_path, mode, source() + CASES[case])


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_auth_trace_replaces_owner(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source(trace=True) + r'''
let p = authResponse(0, 2)
onTrace = replaceOwner
sm_auth_handler(p)
doAssert associations == 0 and conn.retry == 7 and clears.len == 0
finish(p)
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_auth_dispatch_bounds_and_trace(tmp_path: Path, mode: str) -> None:
    code = source(trace=True) + r'''
const KeMsgConsumed = 0.cint
const SmIdleState = 0'u16
var nimFwDbgAuthSmDispatch, nimFwDbgAuthSmState: uint32
proc sm_deauth_handler(p: pointer): cint = 0
proc sm_auth_start() = discard
proc sm_sa_query_handler(p: pointer) = discard
'''
    code += procedure((FW / "task_handlers.nim").read_text(), "rxu_mgt_ind_handler_sm")
    code += r'''
let initial = authResponse(0, 2)
finish(initial)
for length in 0'u32 .. 8'u32:
  let p = newMessage(length)
  doAssert rxu_mgt_ind_handler_sm(p) == KeMsgConsumed
  doAssert clears.len == 0 and associations == 0
  finish(p)
let p = authResponse(0, 2)
onTrace = replaceOwner
doAssert rxu_mgt_ind_handler_sm(p) == KeMsgConsumed
doAssert associations == 0 and clears.len == 0
finish(p)
'''
    run_program(tmp_path, mode, code)


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_synthetic_auth_message_layout(tmp_path: Path, mode: str) -> None:
    sender = procedure((FW / "scan_station_ap_me.nim").read_text(), "sm_auth_send")
    injection = sender.split("  when defined(bl808WifiInjectAuthSuccess):", 1)[1]
    injection = "\n".join(line[4:] if line.startswith("    ") else line for line in injection.splitlines())
    code = source() + r'''
let p = authResponse(0, 2)
var build = smTxBegin(sm.connectInfo)
doAssert smTxBindStation(build, 2)
'''
    code += injection + "\ndoAssert associations == 1 and clears == @[SM_RSP_TIMEOUT_IND]\nfinish(p)\n"
    run_program(tmp_path, mode, code)
