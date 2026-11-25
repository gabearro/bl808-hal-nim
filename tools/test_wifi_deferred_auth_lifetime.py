"""Exercise SM's deferred auth/assoc request (states 5 and 7) with native allocations.

The harness runs the real deferred_auth.nim, sm_auth_assoc_send_according_chan,
chan_ctxt_set_auth_assoc_req, the publication branch of chan_pre_switch_channel
and station_sm.nim's smGo, smPark, smTakeAnswer and smAttemptStaVif. The frame
builders and the end of the attempt (sm_connect_ind, which leaves the state
through smGo) are modelled.
"""

from pathlib import Path
import shutil
import subprocess

import pytest

from test_wifi_deferred_auth import source_parts
from test_wifi_disconnect_tx import FW, ROOT, procedure, station_sm_source


PLATFORM = r'''
import bl808/wifi/fw_constants/states
{.pragma: wifiCtrl.}
const
  TASK_SM = 4'u8
  MAX_VIFS = 2
  MAX_CHAN_CTXT = 2
  VIF_TYPE_STA = 0'u8
  MACHW_TIMLO_REG = 0x24B00120'u
  KeMsgConsumed = 0.cint
  KeMsgTailSlack = 4'u32
  SM_CONNECT_AUTH_ASSOC_REQ_MSG = 0x100B'u16
  WLAN_FW_AUTH_OR_ASSOC_RESPONSE_TIMEOUT_FAILURE = 11'u16
type
  KeMsgHdr = object
    next: pointer
    id: uint16
    destId, srcId: uint8
    paramLen: uint32
  CoListHdr = object
    next: ptr CoListHdr
  CoList = object
    first, last: ptr CoListHdr
  TbttNode = object
    hdr: CoListHdr
    state: uint8
  Context = object
    hdr: CoListHdr
    contextIndexOrMarker, status, linkCount: uint8
  Vif = object
    chanCtxt: pointer
    vifIdx, vifType: uint8
    tbttNode: TbttNode
  SmEnv = object
    connectInfo: pointer
  ConnectInfo = object
    vifIdx: uint8
  ChanEnv = object
    activeList, tbttList: CoList
    deferredMsg, currentCtxt, scheduledCtxt, dominantCtxt: pointer
    slotPeriod, cdeStarted, remainingTimeTarget: uint32
    ctxtCount, flags, schedState: uint8
  SentFrame = object
    kind: uint16
    sequence: uint16
    challenge: seq[uint8]
var
  env: SmEnv
  conn, replacement: ConnectInfo
  vifs: array[2, Vif]
  chan: ChanEnv
  rxVifEpochs, chanCtxtLinkEpochs: array[MAX_VIFS, uint32]
  channels: array[MAX_CHAN_CTXT, Context]
  sm_reconn_dominant_flag, macTime: uint32
  channelCount: uint8
  dominant, allocFail: bool
  remainingTime: uint32
  currentState: uint16
  interruptsEnabled = true
  allocations, frees, failures, publications, remainingChecks: int
  endings: seq[tuple[status, reason: uint16]]
  sent: seq[SentFrame]
  live: seq[ptr KeMsgHdr]
  queue: seq[pointer]
  allocationHook, publicationHook, stateHook, freeHook: proc()
proc smDeferredCancel()
proc sm_connect_ind(status, reason: uint16)
proc sm_auth_send(sequence: uint16; challenge: pointer)
proc sm_assoc_req_send()
proc smEnvView(): ptr SmEnv = addr env
proc connectInfoView(p: pointer): ptr ConnectInfo = cast[ptr ConnectInfo](p)
proc vifChannelForIdx(index: uint8): ptr Vif = addr vifs[index]
proc vifChannelAt(p: pointer): ptr Vif = cast[ptr Vif](p)
proc chanEnvView(): ptr ChanEnv = addr chan
proc chanCtxtForIdx(index: uint8): ptr Context = addr channels[index]
proc chanCtxtAt(p: pointer): ptr Context = cast[ptr Context](p)
proc chanCtxtHdr(p: ptr Context): ptr CoListHdr = addr p.hdr
proc chanTbttHdr(p: ptr TbttNode): ptr CoListHdr = addr p.hdr
proc chanTbttPrimaryList(): ptr CoList = addr chan.tbttList
proc chan_ctxt_trigger(p: pointer) = discard
proc chan_update_tx_power(p: pointer) = discard
proc chanCtxtOpTimer(): pointer = nil
proc mm_timer_clear(p: pointer) = discard
proc chan_ctxt_op_evt(p: pointer) = chan.currentCtxt = nil
proc chan_cde_evt(p: pointer) = discard
proc chan_tbtt_schedule(p: pointer) = discard
proc chan_ctxt_del(index: uint8) =
  doAssert channels[index].linkCount == 0
  channels[index].contextIndexOrMarker = 255
proc assert_err(condition, file: cstring; line: cint) =
  doAssert false, "unexpected assertion at " & $line
proc regRead(address: uint): uint32 =
  doAssert address == MACHW_TIMLO_REG
  macTime
proc pointerAddrU32(p: pointer): uint32 = cast[uint32](cast[uint](p))
proc irqSave(): uint32 =
  result = interruptsEnabled.uint32
  interruptsEnabled = false
proc invoke(hook: var proc()) =
  if hook != nil:
    let action = hook
    hook = nil
    action()
proc irqRestore(saved: uint32) =
  interruptsEnabled = saved != 0
proc c_memcpy(dst, src: pointer; n: csize_t): pointer =
  copyMem(dst, src, n.int)
  dst
proc keMsgPayload(header: ptr KeMsgHdr): pointer =
  cast[pointer](cast[uint](header) + sizeof(KeMsgHdr).uint)
proc keMsgHdrFromPayload(payload: pointer): ptr KeMsgHdr =
  cast[ptr KeMsgHdr](cast[uint](payload) - sizeof(KeMsgHdr).uint)
proc ke_msg_free(header: pointer) =
  let index = live.find(cast[ptr KeMsgHdr](header))
  doAssert index >= 0, "message freed twice or by the wrong owner"
  live.delete(index)
  inc frees
  dealloc(header)
  invoke(freeHook)
proc ke_msg_try_alloc(id: uint16; dest, src: uint8; n: uint32): pointer =
  inc allocations
  if not allocFail:
    let header = cast[ptr KeMsgHdr](alloc0(sizeof(KeMsgHdr) + n.int + 4))
    header[] = KeMsgHdr(id: id, destId: dest, srcId: src, paramLen: n)
    live.add(header)
    result = keMsgPayload(header)
  invoke(allocationHook)
proc ke_msg_send(payload: pointer) =
  doAssert live.find(keMsgHdrFromPayload(payload)) >= 0
  inc publications
  queue.add(payload)
  invoke(publicationHook)
proc ke_state_get(task: uint8): uint16 = currentState
proc ke_state_set(task: uint8; state: uint16) =
  currentState = state
  invoke(stateHook)
proc chan_ctxt_cnt(): uint8 = channelCount
proc chan_ctxt_use_dominant_chan(): bool = dominant
proc chan_ctxt_get_remaining_time_ms(vif: pointer): uint32 =
  doAssert vif == addr vifs[1]
  inc remainingChecks
  remainingTime
'''

# The modelled ends of states 5 and 7, written after station_sm.nim.
ENDS = r'''
proc sm_connect_ind(status, reason: uint16) =
  ## The attempt ends; its teardown leaves the state through smGo.
  endings.add((status, reason))
  inc failures
  env.connectInfo = nil
  discard smGo(10)
proc sm_auth_send(sequence: uint16; challenge: pointer) =
  var frame = SentFrame(kind: 5, sequence: sequence)
  if challenge != nil:
    let bytes = cast[ptr array[128, uint8]](challenge)
    for value in bytes[]: frame.challenge.add(value)
  sent.add(frame)
  discard smGo(6)
proc sm_assoc_req_send() =
  sent.add(SentFrame(kind: 7))
  discard smGo(8)
'''

HELPERS = r'''
proc drain() =
  while queue.len != 0:
    let payload = queue[0]
    queue.delete(0)
    doAssert sm_connect_auth_assoc_req(payload) == KeMsgConsumed
    ke_msg_free(keMsgHdrFromPayload(payload))
proc held(): bool = smOwn.request != nil
proc reset() =
  ## sm_init, then an attempt on VIF 1 in state 4.
  discard smGo(0)
  drain()
  doAssert live.len == 0 and chan.deferredMsg == nil
  env.connectInfo = addr conn
  conn.vifIdx = 1
  replacement.vifIdx = 1
  chan = default(ChanEnv)
  channels = [Context(contextIndexOrMarker: 0), Context(contextIndexOrMarker: 1)]
  vifs = [Vif(vifIdx: 0), Vif(vifIdx: 1)]
  chan_ctxt_link(1, 0)
  rxVifEpochs[1] = 1
  channelCount = 2
  dominant = false
  allocFail = false
  remainingTime = 300
  discard smGo(4)
  allocations = 0
  frees = 0
  failures = 0
  endings.setLen(0)
  publications = 0
  remainingChecks = 0
  sent.setLen(0)
proc schedule(kind = 5'u16; sequence = 1'u16) =
  sm_auth_assoc_send_according_chan(kind, sequence, nil)
proc publish() = activate(addr vifs[1])
proc finish() =
  discard smGo(0)
  drain()
  doAssert live.len == 0 and chan.deferredMsg == nil
'''

CASES = {
    # Direct for one channel, a dominant one, or 0 or 41..199 ms left;
    # otherwise parked in state 5 or 7 and sent when the channel is active.
    "matrix": r'''
for kind in [5'u16, 7]:
  for count in [0'u8, 1, 2, 4]:
    for dom in [false, true]:
      for remaining in [0'u32, 1, 40, 41, 42, 199, 200, 201, 1000, high(uint32) div 1000]:
        reset()
        channelCount = count
        dominant = dom
        remainingTime = remaining
        let direct = count <= 1 or dom or remaining == 0 or remaining in 41'u32..199'u32
        schedule(kind, 0x1234)
        doAssert sent.len == direct.int and allocations == (not direct).int
        if not direct:
          let request = cast[ptr SmConnectAuthAssocReqPayload](chan.deferredMsg)
          doAssert keMsgHdrFromPayload(request).paramLen == 8
          doAssert request.nextState == kind and request.authSequence == 0x1234
          doAssert currentState == kind and smOwn.request == request
          publish()
          publish()
          doAssert publications == 1 and chan.deferredMsg == nil
          drain()
        doAssert sent.len == 1 and sent[0].kind == kind and failures == 0
        doAssert currentState == kind + 1 and not held()
        if kind == 5: doAssert sent[0].sequence == 0x1234
finish()
''',
    # The attempt ends (abort, failure, sm_init) while its request is parked:
    # leaving the state frees it, and nothing is sent.
    "attempt_ended_while_parked": r'''
for kind in [5'u16, 7]:
  reset()
  schedule(kind)
  doAssert chan.deferredMsg != nil and live.len == 1
  sm_connect_ind(24, 3)
  doAssert live.len == 0 and frees == 1 and chan.deferredMsg == nil and not held()
  publish()
  drain()
  doAssert sent.len == 0 and publications == 0 and endings == @[(24'u16, 3'u16)]
''',
    # ... or after the channel scheduler sent it: SM ignores it when it comes.
    "attempt_ended_while_queued": r'''
for kind in [5'u16, 7]:
  reset()
  schedule(kind)
  publish()
  sm_connect_ind(24, 3)
  doAssert live.len == 1 and frees == 0
  drain()
  doAssert sent.len == 0 and frees == 1 and currentState == 10
  doAssert endings == @[(24'u16, 3'u16)]
''',
    # The attempt's STA VIF is retired before the request comes back: the
    # attempt ends instead of the frame builder returning silently.
    "vif_retired_while_queued": r'''
for kind in [5'u16, 7]:
  reset()
  schedule(kind)
  publish()
  vifs[1].vifType = 4
  drain()
  doAssert sent.len == 0 and endings == @[(11'u16, 0xFFFF'u16)] and currentState == 10
''',
    # ... or before the request is sent or parked (a retry from state 6 or 8,
    # the next auth step, or the start of authentication in state 4).
    "vif_retired_before_schedule": r'''
for kind in [5'u16, 7]:
  for count in [1'u8, 2]:
    for state in [4'u16, 6, 8]:
      reset()
      discard smGo(state)
      channelCount = count
      vifs[1].vifType = 4
      schedule(kind)
      doAssert sent.len == 0 and allocations == 0 and chan.deferredMsg == nil
      doAssert endings == @[(11'u16, 0xFFFF'u16)] and currentState == 10
''',
    # A request SM did not park, or one delivered twice, changes nothing.
    "forged_request": r'''
var request = SmConnectAuthAssocReqPayload(nextState: 5, authSequence: 1)
discard smGo(5)
discard sm_connect_auth_assoc_req(addr request)
discard sm_connect_auth_assoc_req(nil)
doAssert sent.len == 0 and failures == 0 and currentState == 5
''',
    "duplicate_dispatch": r'''
schedule()
publish()
let payload = queue[0]
queue.delete(0)
discard sm_connect_auth_assoc_req(payload)
discard sm_connect_auth_assoc_req(payload)
ke_msg_free(keMsgHdrFromPayload(payload))
doAssert sent.len == 1 and currentState == 6
''',
    "wrong_vif": r'''
schedule()
activate(addr vifs[0])
doAssert chan.deferredMsg != nil and publications == 0
publish()
drain()
doAssert sent.len == 1
''',
    # No other state is entered while the request is parked; an unlink of the
    # VIF's channel does not send it.
    "unlink_keeps_parked": r'''
schedule()
chan_ctxt_unlink(1)
doAssert publications == 0 and chan.deferredMsg != nil and currentState == 5 and held()
''',
    "allocation_failure": r'''
for kind in [5'u16, 7]:
  reset()
  allocFail = true
  schedule(kind)
  doAssert endings == @[(11'u16, 0xFFFF'u16)] and sent.len == 0
  doAssert chan.deferredMsg == nil and currentState == 10 and not held()
''',
    # The parked request carries its own copy of a shared-key challenge: the
    # RX frame it came from is gone when the channel comes back.
    "owned_challenge": r'''
var challenge: array[128, uint8]
for i in 0..<128: challenge[i] = (i xor 0xA5).uint8
let expected = challenge
sm_auth_assoc_send_according_chan(5, 3, addr challenge[0])
zeroMem(addr challenge[0], 128)
let payload = chan.deferredMsg
doAssert keMsgHdrFromPayload(payload).paramLen == 136
publish()
drain()
doAssert sent.len == 1 and sent[0].sequence == 3 and sent[0].challenge == @expected
''',
    "direct_challenge": r'''
var challenge: array[128, uint8]
for i in 0..<128: challenge[i] = (i xor 0x5A).uint8
channelCount = 1
sm_auth_assoc_send_according_chan(5, 3, addr challenge[0])
doAssert allocations == 0 and sent.len == 1 and sent[0].challenge == @challenge
''',
    "invalid_request": r'''
env.connectInfo = nil
schedule()
env.connectInfo = addr conn
sm_auth_assoc_send_according_chan(6, 1, nil)
doAssert sent.len == 0 and allocations == 0 and failures == 0 and currentState == 4
''',
    "remaining_time": r'''
let vif = addr vifs[1]
macTime = 100_000
chan.remainingTimeTarget = 170_000
chan.currentCtxt = addr channels[1]
doAssert realRemainingTime(vif) == 0
chan.currentCtxt = vif.chanCtxt
doAssert realRemainingTime(vif) == 70
chan.remainingTimeTarget = macTime
doAssert realRemainingTime(vif) == 0
chan.remainingTimeTarget = macTime - 1000'u32
doAssert realRemainingTime(vif) == (high(uint32) - 999'u32) div 1000'u32
macTime = high(uint32) - 999'u32
chan.remainingTimeTarget = 40_000
doAssert realRemainingTime(vif) == 41
''',
    "disabled_interrupts": r'''
interruptsEnabled = false
schedule()
doAssert not interruptsEnabled
publish()
drain()
doAssert not interruptsEnabled and sent.len == 1
interruptsEnabled = true
''',
}


def program_source(mutation: str = "") -> str:
    types, constants, tasks = source_parts()
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    sm = (FW / "scan_station_ap_me.nim").read_text()
    start = kernel.index("        if vif.vifType == 0:\n          # Blob 0x1de")
    end = kernel.index("        # Send postponed frames", start)
    fragment = "\n".join(line[8:] for line in kernel[start:end].splitlines())
    # The production branch publishes for this VIF after activating its channel.
    activation = "\nproc activate(vif3: pointer) =\n  let vif = cast[ptr Vif](vif3)\n"
    activation += "\n".join("  " + line for line in fragment.splitlines()) + "\n"
    source = (types + constants + PLATFORM
              + procedure(kernel, "chan_ctxt_set_auth_assoc_req")
              + station_sm_source("smGo", "smPark", "smTakeAnswer", "smAttemptStaVif")
              + ENDS + (FW / "deferred_auth.nim").read_text()
              + procedure(kernel, "co_list_push_back") + procedure(kernel, "co_list_extract")
              + procedure(kernel, "chan_ctxt_link") + procedure(kernel, "chan_ctxt_unlink")
              + procedure(kernel, "chan_is_on_operational_channel")
              + procedure(kernel, "chan_ctxt_get_remaining_time_ms").replace(
                  "chan_ctxt_get_remaining_time_ms", "realRemainingTime", 1)
              + procedure(tasks, "sm_auth_assoc_send_according_chan")
              + procedure(sm, "sm_connect_auth_assoc_req") + activation + HELPERS)
    if mutation:
        old, new = MUTATIONS[mutation][0:2]
        assert source.count(old) == 1, mutation
        source = source.replace(old, new, 1)
    return source


def run_case(tmp_path: Path, case: str, mode: str = "checked", mutation: str = "") -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("nim is not installed")
    path = tmp_path / "deferred.nim"
    path.write_text(program_source(mutation) + "\nreset()\n" + CASES[case] + "\nfinish()\n")
    flags = {"checked": [], "release": ["-d:release", "--assertions:on"],
             "asan": ["--cc:clang", "--passC:-fsanitize=address", "--passL:-fsanitize=address"]}[mode]
    result = subprocess.run([nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on",
        "--skipUserCfg:on", "--checks:on", *flags, f"--path:{ROOT / 'src'}",
        f"--nimcache:{tmp_path / 'cache'}", f"-o:{tmp_path / 'check'}", str(path)],
        cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=90)
    if mutation:
        assert result.returncode != 0 and "AssertionDefect" in result.stdout, result.stdout
    else:
        assert result.returncode == 0, result.stdout


# The guard each mutation removes, and the case that must then fail.
MUTATIONS = {
    "take_answer": ("  if not smTakeAnswer(payload): return KeMsgConsumed",
                    "  discard smTakeAnswer(payload)", "attempt_ended_while_queued"),
    "dispatch_vif": ("  if connection == nil or not smAttemptStaVif(connectInfoView(connection).vifIdx):",
                     "  if connection == nil:", "vif_retired_while_queued"),
    "send_vif": ("  if not smAttemptStaVif(vifIdx):\n    sm_connect_ind(WLAN_FW_AUTH_OR_ASSOC_RESPONSE_TIMEOUT_FAILURE, 0xFFFF)\n    return\n",
                 "", "vif_retired_before_schedule"),
    "publication": ("  env.deferredMsg = nil\n  ke_msg_send(request)", "  ke_msg_send(request)", "matrix"),
    "publish_vif": ("cast[pointer](vifChannelForIdx(connectInfoView(connection).vifIdx)) != vifEntry",
                    "false", "wrong_vif"),
    "go_frees_parked": ("  if reserved != nil: ke_msg_free(keMsgHdrFromPayload(reserved))\n  smDeferredCancel()\n",
                        "  if reserved != nil: ke_msg_free(keMsgHdrFromPayload(reserved))\n",
                        "attempt_ended_while_parked"),
}


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("case", CASES)
def test_deferred_lifetime(tmp_path: Path, case: str, mode: str) -> None:
    run_case(tmp_path, case, mode)


@pytest.mark.parametrize("mutation", MUTATIONS)
def test_deferred_lifetime_guards(tmp_path: Path, mutation: str) -> None:
    run_case(tmp_path, MUTATIONS[mutation][2], mutation=mutation)


def test_parked_request_has_one_owner() -> None:
    """smGo frees a parked request; nothing else tracks, forgets or cancels it."""
    assert "smDeferredCancel()" in procedure((FW / "station_sm.nim").read_text(), "smGo")
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    for name in ["chan_init", "chan_ctxt_unlink", "ke_msg_free"]:
        assert "smDeferred" not in procedure(kernel, name), name
    assert "chanEnvView().deferredMsg = msg" in procedure(kernel, "chan_ctxt_set_auth_assoc_req")
    sm = (FW / "scan_station_ap_me.nim").read_text()
    assert "smDeferredCancel()" not in procedure(sm, "sm_init")
    deferred = (FW / "deferred_auth.nim").read_text()
    assert "SmDeferredOwner" not in deferred and "Forget" not in deferred
    assert "smDeferredAbortable" not in (FW / "task_handlers.nim").read_text()
