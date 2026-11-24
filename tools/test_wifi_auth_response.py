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
  smAuthResponseExpectations: array[MAX_VIFS, SmAuthResponseExpectation]
  callbacks: array[16, pointer]
  saeResult: int32
  saeBodies: seq[seq[uint8]]
  authRequests: seq[tuple[sequence: uint16, challenge: seq[uint8]]]
  associations, warnings: int
  onSae, onLog: proc()
  authLogs: seq[tuple[line: cint, format: string, sequence: cint]]
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
{.emit: "#include <stdarg.h>".}
proc authLog(level: uint32; tag, file: cstring; line: cint;
             format: cstring) {.cdecl, varargs.} =
  doAssert level == 3 and tag == nil and $file == "sm.c"
  var sequence: cint
  {.emit: ["va_list args; va_start(args, ", format, "); ",
           sequence, " = va_arg(args, int); va_end(args);"].}
  authLogs.add((line, $format, sequence))
  invoke(onLog)
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
  var txSequence = 0'u16
  case algorithm
  of 0'u16:
    if sequence == 2: txSequence = 1
  of 1'u16:
    if sequence == 2: txSequence = 1
    elif sequence == 4: txSequence = 3
  of 3'u16:
    if sequence in [1'u16, 2'u16]: txSequence = sequence
  else: discard
  if txSequence != 0:
    smAuthResponseExpectations[1] = SmAuthResponseExpectation(
      connection: addr conn, serial: smTxSerials[1],
      identity: TxSessionIdentity(captured: true, vif: 1, station: 2,
        vifEpoch: rxVifEpochs[1], stationEpoch: stationEpochs[2],
        resetEpoch: txResetEpoch),
      algorithm: algorithm.uint8, txSequence: txSequence)
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
  authLogs.setLen(0)
'''


def source(trace: bool = False) -> str:
    code = association_source(trace).replace(
        "vifIdx, retry: uint8", "vifIdx, retry, authType, authRetryGate: uint8", 1,
    )
    code += layouts("SmAuthFrameView", "SmAuthResponseExpectation") + EXTRA
    code += procedure((FW / "station_tx_build.nim").read_text(), "smTxCapture")
    code += procedure((FW / "station_tx_build.nim").read_text(), "smAuthResponseMatches")
    code += procedure((FW / "station_tx_build.nim").read_text(), "smAuthConsumeResponse")
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
    "open_refusal_of_algorithm_or_sequence": r'''
for status in [13'u16, 14, 17]:
  for peer in [2'u8, 3, 255]:
    for connected in [false, true]:
      let p = authResponse(0, 2, status)
      smAuthFrameView(p).authSeq = 1
      rxuMgtDispatchView(p).staIdx = peer
      if not connected: smAuthResponseExpectations[1].txSequence = 0
      sm_auth_handler(p)
      let admitted = status in [13'u16, 14] and peer == 2 and connected
      doAssert failures == (if admitted: @[(2'u16, status)] else: @[])
      doAssert clears.len == admitted.int and associations == 0 and authRequests.len == 0
      finish(p)
''',
    "failure_requires_pending_exchange": r'''
for mutation in 0 .. 5:
  let p = authResponse(1, 2, 17)
  let expected = addr smAuthResponseExpectations[1]
  case mutation
  of 0: smAuthFrameView(p).authSeq = 4
  of 1: smAuthFrameView(p).authAlgo = 0
  of 2: expected.txSequence = 3
  of 3: inc expected.serial
  of 4: inc expected.identity.vifEpoch
  else: expected.connection = addr replacement
  let pendingSequence = expected.txSequence
  sm_auth_handler(p)
  doAssert clears.len == 0 and failures.len == 0
  doAssert authRequests.len == 0 and associations == 0
  doAssert expected.txSequence == pendingSequence and conn.authType == 1
  finish(p)
''',
    "matched_failure_consumes_exchange": r'''
for algorithm in [0'u16, 1'u16, 3'u16]:
  let sequence = if algorithm == 3: 1'u16 else: 2'u16
  let p = authResponse(algorithm, sequence, 17)
  sm_auth_handler(p)
  doAssert failures == @[(2'u16, 17'u16)]
  doAssert clears == @[SM_RSP_TIMEOUT_IND]
  doAssert smAuthResponseExpectations[1].txSequence == 0
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
    "open_success_requires_sequence_two": r'''
for sequence in [0'u16, 1, 3, 4, 65535]:
  let p = authResponse(0, sequence)
  sm_auth_handler(p)
  doAssert clears.len == 0 and associations == 0 and failures.len == 0
  doAssert conn.retry == 7 and authRequests.len == 0
  finish(p)
''',
    "success_requires_requested_algorithm": r'''
for requested in [0'u8, 1, 3]:
  for received in [0'u16, 1, 3]:
    if requested.uint16 == received: continue
    let sequence = if received == 1: 4'u16 else: 2'u16
    let p = authResponse(received, sequence)
    conn.authType = requested
    sm_auth_handler(p)
    doAssert clears.len == 0 and associations == 0 and failures.len == 0
    doAssert authRequests.len == 0 and saeBodies.len == 0 and conn.retry == 7
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
    "sae_error_log_arguments": r'''
for processed in [-8'i32, 7'i32]:
  for sequence in [1'u16, 2'u16]:
    let p = authResponse(3, sequence, body = [1'u8, 2, 3])
    saeResult = processed
    sm_auth_handler(p)
    doAssert authLogs.len == 1
    doAssert authLogs[0].line == (if processed == -8: 1302.cint else: 1307.cint)
    doAssert authLogs[0].format == (if processed == -8:
      "BL_SAE_INVALID_PACKET, auth seq num= %d\r\n"
    else:
      "SAE Authentication parse failure, auth seq num= %d\r\n")
    doAssert authLogs[0].sequence == sequence.cint
    finish(p)
''',
    "sae_success_and_retry": r'''
for sequence in 1'u16 .. 2'u16:
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
    "unexpected_success_sequences_keep_timer": r'''
for algorithm in [1'u16, 3'u16]:
  for sequence in [0'u16, 3, 5, 65535]:
    let p = authResponse(algorithm, sequence)
    sm_auth_handler(p)
    doAssert clears.len == 0 and associations == 0 and failures.len == 0
    doAssert authRequests.len == 0 and saeBodies.len == 0
    doAssert conn.retry == 7 and warnings == 0
    finish(p)
''',
    "shared_response_requires_matching_tx": r'''
for mutation in 0 .. 6:
  let p = authResponse(1, 4)
  let expected = addr smAuthResponseExpectations[1]
  case mutation
  of 0: expected.txSequence = 1
  of 1: inc expected.serial
  of 2: expected.connection = addr replacement
  of 3: inc expected.identity.vifEpoch
  of 4: inc expected.identity.stationEpoch
  of 5: inc expected.identity.resetEpoch
  else: expected.identity.station = 3
  sm_auth_handler(p)
  doAssert clears.len == 0 and associations == 0 and failures.len == 0
  doAssert expected.txSequence != 0 and conn.retry == 7
  finish(p)
''',
    "shared_response_consumed_once": r'''
let p = authResponse(1, 4)
sm_auth_handler(p)
doAssert associations == 1 and clears == @[SM_RSP_TIMEOUT_IND]
doAssert smAuthResponseExpectations[1].txSequence == 0
sm_auth_handler(p)
doAssert associations == 1 and clears == @[SM_RSP_TIMEOUT_IND]
finish(p)
''',
    "open_and_sae_require_matching_tx": r'''
for algorithm in [0'u16, 3'u16]:
  let sequence = if algorithm == 0: 2'u16 else: 1'u16
  for mutation in 0 .. 3:
    let p = authResponse(algorithm, sequence)
    let expected = addr smAuthResponseExpectations[1]
    case mutation
    of 0: expected.txSequence = 3
    of 1: expected.algorithm = 1
    of 2: inc expected.serial
    else: inc expected.identity.vifEpoch
    sm_auth_handler(p)
    doAssert clears.len == 0 and associations == 0 and failures.len == 0
    doAssert saeBodies.len == 0 and authRequests.len == 0
    doAssert conn.retry == 7
    finish(p)
''',
    "sae_retry_preserves_expectation": r'''
let p = authResponse(3, 1)
saeResult = -8
sm_auth_handler(p)
doAssert clears.len == 0 and authRequests.len == 0
doAssert smAuthResponseExpectations[1].txSequence == 1
saeResult = 0
sm_auth_handler(p)
doAssert clears == @[SM_RSP_TIMEOUT_IND]
doAssert authRequests.len == 1 and authRequests[0].sequence == 2
doAssert smAuthResponseExpectations[1].txSequence == 0
finish(p)
''',
    "open_response_consumed_once": r'''
for rxPeer in [2'u8, 0xFF]:
  let p = authResponse(0, 2)
  rxuMgtDispatchView(p).staIdx = rxPeer
  sm_auth_handler(p)
  doAssert associations == 1 and clears == @[SM_RSP_TIMEOUT_IND]
  sm_auth_handler(p)
  doAssert associations == 1 and clears == @[SM_RSP_TIMEOUT_IND]
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
proc rxMgtMessageCurrent(header: pointer): bool = true
proc sm_auth_start() = discard
proc sm_sa_query_handler(p: pointer) = discard
'''
    code += layouts("RxuMgtIndMsgView") + r'''
proc rxuMgtIndMsgAt(p: pointer): ptr RxuMgtIndMsgView =
  cast[ptr RxuMgtIndMsgView](p)
'''
    code += procedure((FW / "scan_station_ap_me.nim").read_text(), "smRxFrameFits")
    code += procedure((FW / "layout_types.nim").read_text(), "rxMacHeaderLen")
    code += procedure((FW / "task_handlers.nim").read_text(), "rxu_mgt_ind_handler_sm")
    code += r'''
let initial = authResponse(0, 2)
finish(initial)
for length in 0'u32 .. 8'u32:
  let p = newMessage(length)
  doAssert rxu_mgt_ind_handler_sm(p) == KeMsgConsumed
  doAssert clears.len == 0 and associations == 0
  finish(p)
for frameLength in [5'u16, 7'u16]:
  let malformed = authResponse(0, 2)
  smAuthFrameView(malformed).frameLen = frameLength
  doAssert rxu_mgt_ind_handler_sm(malformed) == KeMsgConsumed
  doAssert associations == 0 and clears.len == 0
  finish(malformed)
let valid = authResponse(0, 2)
doAssert rxu_mgt_ind_handler_sm(valid) == KeMsgConsumed
doAssert associations == 1
finish(valid)
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
var build = smTxCapture(sm.connectInfo)
doAssert smTxBindStation(build, 2)
'''
    code += injection + "\ndoAssert associations == 1 and clears == @[SM_RSP_TIMEOUT_IND]\nfinish(p)\n"
    run_program(tmp_path, mode, code)
