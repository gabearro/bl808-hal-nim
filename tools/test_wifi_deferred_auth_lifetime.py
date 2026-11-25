"""Exercise deferred SM commands with native allocations and callback reentry."""

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
  sent: seq[SentFrame]
  live: seq[ptr KeMsgHdr]
  queue: seq[pointer]
  allocationHook, publicationHook, stateHook, freeHook, authHook, restoreHook: proc()
proc smDeferredCancel()
proc smDeferredForget(header: pointer)
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
  if interruptsEnabled: invoke(restoreHook)
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
  smDeferredForget(header)
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
proc sm_connect_ind(status, reason: uint16) =
  doAssert status == 11 and reason == 0xFFFF
  inc failures
  currentState = 10
  smDeferredCancel()
proc sm_auth_send(sequence: uint16; challenge: pointer) =
  var frame = SentFrame(kind: 5, sequence: sequence)
  if challenge != nil:
    let bytes = cast[ptr array[128, uint8]](challenge)
    for value in bytes[]: frame.challenge.add(value)
  sent.add(frame)
  currentState = 6
  invoke(authHook)
proc sm_assoc_req_send() =
  sent.add(SentFrame(kind: 7))
  currentState = 8
  invoke(authHook)
'''

HELPERS = r'''
proc drain() =
  while queue.len != 0:
    let payload = queue[0]
    queue.delete(0)
    doAssert sm_connect_auth_assoc_req(payload) == KeMsgConsumed
    ke_msg_free(keMsgHdrFromPayload(payload))
proc reset() =
  smDeferredCancel()
  drain()
  doAssert live.len == 0 and smDeferredTags == nil
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
  currentState = 4
  allocations = 0
  frees = 0
  failures = 0
  publications = 0
  remainingChecks = 0
  sent.setLen(0)
proc schedule(kind = 5'u16; sequence = 1'u16) =
  sm_auth_assoc_send_according_chan(kind, sequence, nil)
proc publish() = activate(addr vifs[1])
proc finish() =
  smDeferredCancel()
  drain()
  doAssert live.len == 0 and smDeferredTags == nil and chan.deferredMsg == nil
'''

CASES = {
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
          doAssert currentState == kind
          publish()
          publish()
          doAssert publications == 1 and chan.deferredMsg == nil
          drain()
        doAssert sent.len == 1 and sent[0].kind == kind
        if kind == 5: doAssert sent[0].sequence == 0x1234
finish()
''',
    "replacement_connection": r'''
schedule()
publish()
env.connectInfo = addr replacement
drain()
doAssert sent.len == 0
''',
    "same_address_new_epoch": r'''
schedule()
publish()
inc rxVifEpochs[1]
drain()
doAssert sent.len == 0
''',
    "channel_replacement": r'''
for kind in [5'u16, 7]:
  for alreadyQueued in [false, true]:
    for rebind in [-1, 0, 1]:
      reset()
      # Hold the original context on another VIF so a relink can reuse the
      # identical address without reallocating the context slot.
      chan_ctxt_link(0, 0)
      schedule(kind)
      if alreadyQueued: publish()
      chan_ctxt_unlink(1)
      doAssert publications == 1 and chan.deferredMsg == nil and frees == 0
      doAssert failures == 0 and smDeferredAbortable(1, kind)
      if rebind >= 0: chan_ctxt_link(1, rebind.uint8)
      drain()
      doAssert failures == 1 and sent.len == 0 and frees == 1 and currentState == 10
      publish()
      drain()
      doAssert failures == 1
''',
    "unrelated_unlink": r'''
chan_ctxt_link(0, 0)
schedule()
chan_ctxt_unlink(0)
doAssert publications == 0 and chan.deferredMsg != nil
publish()
drain()
doAssert sent.len == 1 and failures == 0
''',
    "binding_changes_during_dispatch": r'''
chan_ctxt_link(0, 0)
schedule()
publish()
restoreHook = proc() =
  chan_ctxt_unlink(1)
  chan_ctxt_link(1, 0)
drain()
doAssert sent.len == 0 and failures == 1 and frees == 1
''',
    "binding_changes_during_build": r'''
for phase in 0..2:
  reset()
  chan_ctxt_link(0, 0)
  proc rebind() =
    chan_ctxt_unlink(1)
    chan_ctxt_link(1, 0)
  if phase == 0: allocationHook = rebind
  elif phase == 1:
    # Force the direct path, then rebind when the owner snapshot is unlocked.
    channelCount = 1
    restoreHook = rebind
  else: chan_ctxt_unlink(1)
  schedule()
  doAssert sent.len == 0 and failures == 1 and live.len == 0 and chan.deferredMsg == nil
''',
    "retired_binding_new_state": r'''
schedule()
chan_ctxt_unlink(1)
doAssert publications == 1
currentState = 6
drain()
doAssert sent.len == 0 and failures == 0 and frees == 1 and currentState == 6
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
    "wrong_vif": r'''
schedule()
activate(addr vifs[0])
doAssert chan.deferredMsg != nil and publications == 0
publish()
drain()
doAssert sent.len == 1
''',
    "publication_replacement": r'''
schedule()
publicationHook = proc() = schedule(5, 2)
publish()
doAssert chan.deferredMsg != nil and currentState == 5
drain()
doAssert sent.len == 0
publish()
drain()
doAssert sent.len == 1 and sent[0].sequence == 2
''',
    "publication_irq_replacement": r'''
schedule()
restoreHook = proc() = schedule(7, 2)
publish()
drain()
doAssert sent.len == 0 and chan.deferredMsg != nil
publish()
drain()
doAssert sent.len == 1 and sent[0].kind == 7
''',
    "dispatch_irq_replacement": r'''
schedule()
publish()
restoreHook = proc() = schedule(7, 2)
drain()
doAssert sent.len == 0 and chan.deferredMsg != nil
publish()
drain()
doAssert sent.len == 1 and sent[0].kind == 7
''',
    "allocation_replacement": r'''
allocationHook = proc() = schedule(5, 2)
schedule()
doAssert live.len == 1 and frees == 1
publish()
drain()
doAssert sent.len == 1 and sent[0].sequence == 2
''',
    "free_replacement": r'''
schedule()
freeHook = proc() = schedule(5, 3)
schedule(5, 2)
publish()
drain()
doAssert sent.len == 1 and sent[0].sequence == 3
''',
    "state_publication": r'''
stateHook = proc() =
  publish()
  drain()
schedule()
doAssert sent.len == 1 and currentState == 6 and chan.deferredMsg == nil
''',
    "state_replacement": r'''
stateHook = proc() = schedule(7, 2)
schedule()
publish()
drain()
doAssert sent.len == 1 and sent[0].kind == 7 and currentState == 8
''',
    "parked_cancel": r'''
schedule()
smDeferredCancel()
doAssert live.len == 0 and frees == 1 and chan.deferredMsg == nil
''',
    "queued_cancel": r'''
schedule()
publish()
smDeferredCancel()
doAssert live.len == 1 and frees == 0
drain()
doAssert sent.len == 0 and frees == 1
''',
    "executing_cancel": r'''
schedule()
publish()
authHook = proc() =
  smDeferredCancel()
  doAssert live.len == 1 and frees == 0
drain()
doAssert sent.len == 1 and frees == 1
''',
    "duplicate_dispatch": r'''
schedule()
publish()
let payload = queue[0]
authHook = proc() =
  currentState = 5
  discard sm_connect_auth_assoc_req(payload)
drain()
doAssert sent.len == 1
''',
    "allocation_failure": r'''
allocFail = true
schedule()
doAssert failures == 1 and sent.len == 0 and chan.deferredMsg == nil
''',
    "old_allocation_failure": r'''
allocFail = true
allocationHook = proc() =
  allocFail = false
  schedule(7, 2)
schedule()
doAssert failures == 0
publish()
drain()
doAssert sent.len == 1 and sent[0].kind == 7
''',
    "owned_challenge": r'''
var challenge: array[128, uint8]
for i in 0..<128: challenge[i] = (i xor 0xA5).uint8
let expected = challenge
allocationHook = proc() = zeroMem(addr challenge[0], 128)
sm_auth_assoc_send_according_chan(5, 3, addr challenge[0])
let payload = chan.deferredMsg
doAssert keMsgHdrFromPayload(payload).paramLen == 136
publish()
drain()
doAssert sent.len == 1 and sent[0].challenge == @expected
''',
    "direct_owned_challenge": r'''
schedule()
let challenge = cast[ptr array[128, uint8]](alloc(128))
for i in 0..<128: challenge[i] = (i xor 0xA5).uint8
let expected = challenge[]
channelCount = 1
freeHook = proc() = dealloc(challenge)
sm_auth_assoc_send_according_chan(5, 3, challenge)
doAssert sent.len == 1 and sent[0].challenge == @expected
''',
    "forged_request": r'''
var request = SmConnectAuthAssocReqPayload(nextState: 5, authSequence: 1)
currentState = 5
discard sm_connect_auth_assoc_req(addr request)
discard sm_connect_auth_assoc_req(nil)
doAssert sent.len == 0
''',
    "altered_request": r'''
for field in 0..5:
  reset()
  schedule()
  let payload = chan.deferredMsg
  let request = cast[ptr SmConnectAuthAssocReqPayload](payload)
  let header = keMsgHdrFromPayload(payload)
  case field
  of 0: request.nextState = 7
  of 1: request.authSequence = 2
  of 2: request.challengeAddress = 0x12345678
  of 3: header.id = 0
  of 4: header.destId = 0
  else: header.paramLen = 0
  publish()
  drain()
  doAssert sent.len == 0
''',
    "direct_supersedes": r'''
schedule()
channelCount = 1
schedule(7, 2)
doAssert frees == 1 and chan.deferredMsg == nil and sent.len == 1
''',
    "reset_cleared_slot": r'''
schedule()
chan = default(ChanEnv)
smDeferredCancel()
doAssert live.len == 0 and frees == 1
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
    source = (types + constants + PLATFORM + station_sm_source() + (FW / "deferred_auth.nim").read_text()
            + procedure(kernel, "co_list_push_back") + procedure(kernel, "co_list_extract")
            + procedure(kernel, "chan_ctxt_link") + procedure(kernel, "chan_ctxt_unlink")
            + procedure(kernel, "chan_is_on_operational_channel")
            + procedure(kernel, "chan_ctxt_get_remaining_time_ms").replace(
                "chan_ctxt_get_remaining_time_ms", "realRemainingTime", 1)
            + procedure(kernel, "chan_ctxt_set_auth_assoc_req")
            + procedure(tasks, "sm_auth_assoc_send_according_chan")
            + procedure(sm, "sm_connect_auth_assoc_req") + activation + HELPERS)
    if mutation:
        old, new = MUTATIONS[mutation][0:2]
        assert source.count(old) == 1
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


MUTATIONS = {
    "connection": ("smEnvView().connectInfo == owner.connection and", "true and",
                   "replacement_connection"),
    "epoch": ("rxVifEpochs[owner.vifIndex] == owner.vifEpoch and", "true and",
              "same_address_new_epoch"),
    "link_epoch": ("chanCtxtLinkEpochs[owner.vifIndex] == owner.linkEpoch and", "true and",
                   "channel_replacement"),
    "unlink_wake": ("  smDeferredChannelUnlinked(vifIdx)\n", "  discard\n",
                    "channel_replacement"),
    "publication": ("  ke_msg_send(payload)\n", "  ke_msg_send(payload)\n  chanEnvView().deferredMsg = nil\n",
                    "publication_replacement"),
    "dispatch": ("tag.location != smDeferredQueued or", "false or", "duplicate_dispatch"),
    "state": ("  tag.location = smDeferredParked\n  chanEnvView().deferredMsg = payload",
              "  ke_state_set(TASK_SM, tag.state)\n  tag.location = smDeferredParked\n  chanEnvView().deferredMsg = payload",
              "state_publication"),
}


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("case", CASES)
def test_deferred_lifetime(tmp_path: Path, case: str, mode: str) -> None:
    run_case(tmp_path, case, mode)


@pytest.mark.parametrize("mutation", MUTATIONS)
def test_deferred_lifetime_guards(tmp_path: Path, mutation: str) -> None:
    run_case(tmp_path, MUTATIONS[mutation][2], mutation=mutation)


def test_reset_and_release_hooks() -> None:
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    for name in ["ke_flush", "chan_init"]:
        assert "smDeferredCancel()" in procedure(kernel, name)
    assert "smDeferredForget(param)" in procedure(kernel, "ke_msg_free")
    # A message delivered to the host is retired by ke_msg_free, which forgets it.
    assert "ke_msg_free(hdr)" in procedure(kernel, "ke_msg_send").split("bl_rx_e2a_handler(", 1)[1]
    sm = (FW / "scan_station_ap_me.nim").read_text()
    assert "smDeferredCancel()" in procedure(sm, "sm_init")
    assert "smDeferredCancel()" in procedure((FW / "station_cleanup.nim").read_text(), "smCleanupBegin")
