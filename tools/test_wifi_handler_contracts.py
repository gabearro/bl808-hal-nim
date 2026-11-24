"""Check the registered message ABI and connection-loss replay behavior."""

from pathlib import Path
import re

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_auth_frames import layouts
from test_wifi_message_allocation import run_program


def owned_disconnect_source() -> str:
    scan = (FW / "scan_station_ap_me.nim").read_text()
    return "\nvar smSaQuery: tuple[serial: uint32]\n" + "".join(procedure(scan, name) for name in
                   ("smDisconnectHandoffCurrent", "smDisconnectOwned"))


@pytest.mark.parametrize("mode", ["checked", "release", "firmware"])
def test_sm_connection_tlv_stub_abi(tmp_path: Path, mode: str) -> None:
    source = (FW / "scan_station_ap_me.nim").read_text()
    stubs = "".join(procedure(source, name) for name in [
        "sm_connection_tlv_set", "sm_connection_tlv_pack",
        "sm_connection_tlv_desc_get", "sm_connection_sta_add_ind",
    ])
    run_program(tmp_path, mode, """
type CoList = object
  first, last: pointer
var stationReadyCalls = 0
proc smActivationNotifyCurrent(): bool =
  inc stationReadyCalls
  true
""" + stubs + """
let packTlv: proc(id, flag: uint8; data: pointer; len: uint16): cint
  {.cdecl.} = sm_connection_tlv_pack
let getTlvDesc: proc(list: ptr CoList) {.cdecl.} = sm_connection_tlv_desc_get
var list = CoList(first: cast[pointer](1), last: cast[pointer](2))
static:
  doAssert compiles(sm_connection_tlv_set())
  doAssert not compiles(sm_connection_tlv_set(0, nil, 0))
sm_connection_tlv_set()
doAssert packTlv(255, 1, nil, 65535) == 0
getTlvDesc(addr list)
doAssert list.first == cast[pointer](1) and list.last == cast[pointer](2)
static:
  doAssert compiles(sm_connection_sta_add_ind())
  doAssert not compiles(sm_connection_sta_add_ind(nil))
sm_connection_sta_add_ind()
doAssert stationReadyCalls == 1
""")


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_sm_hardware_key_index_error_and_slots(tmp_path: Path, mode: str) -> None:
    key_index = procedure((FW / "scan_station_ap_me.nim").read_text(),
                          "sm_get_set_machwkey_index")
    run_program(tmp_path, mode, layouts("VifMachwKeyIndexOverlay") + """
type Vif = array[1512, uint8]
static:
  doAssert offsetof(VifMachwKeyIndexOverlay, pairwise) == 510
  doAssert offsetof(VifMachwKeyIndexOverlay, group) == 511
  doAssert offsetof(VifMachwKeyIndexOverlay, management) == 512
var vifs: array[2, Vif]
proc vifChannelForIdx(index: uint8): ptr Vif = addr vifs[index]
proc vifMachwKeyIndexes(vif: ptr Vif): ptr VifMachwKeyIndexOverlay =
  cast[ptr VifMachwKeyIndexOverlay](vif)
""" + key_index + """
var value: uint8
doAssert sm_get_set_machwkey_index(false, 2, nil, 0) == -1
doAssert sm_get_set_machwkey_index(false, 0, nil, 3) == -1
doAssert sm_get_set_machwkey_index(true, 1, nil, 255) == -1
for vif in 0'u8 .. 1'u8:
  for kind in 0'u8 .. 2'u8:
    value = 17'u8 + kind + vif * 3
    doAssert sm_get_set_machwkey_index(false, vif, addr value, kind) == 0
    doAssert vifs[vif.int][510 + kind.int] == value
    doAssert vifs[vif.int][172] == 0
    value = 0
    doAssert sm_get_set_machwkey_index(true, vif, addr value, kind) == 0
    doAssert value == 17'u8 + kind + vif * 3
""")


def registered_handlers() -> list[str]:
    source = (FW / "dispatch_tables.nim").read_text()
    return sorted(set(re.findall(
        r"handler: (?:cast\[pointer\]|keMsgHandlerAddress)\((\w+)\)", source,
    )))


def test_registered_handlers_have_message_result(tmp_path: Path) -> None:
    sources = "\n".join(path.read_text() for path in FW.rglob("*.nim"))
    names = registered_handlers()
    assert len(names) >= 71
    declarations = []
    for name in names:
        match = re.search(r"(?ms)^proc " + re.escape(name) + r"\*?\(.*? =\n", sources)
        assert match, name
        declarations.append(match.group(0) + "  discard\n")
    checks = "\n".join(
        f'  doAssert compiles((block:\n'
        f'    let handler: MessageHandler = {name}\n'
        f'    discard)), "{name} has an incompatible message ABI"'
        for name in names
    )
    run_program(tmp_path, "checked", """
type MessageHandler = proc(param: pointer): cint {.cdecl.}
""" + "\n".join(declarations) + "\nstatic:\n" + checks)


def test_registration_checks_the_handler_type(tmp_path: Path) -> None:
    source = (FW / "dispatch_tables.nim").read_text()
    assert "handler: cast[pointer]" not in source
    helper = re.search(r"(?ms)^template keMsgHandlerAddress\(.*?(?=\n\S|\Z)", source)
    assert helper, "message registration needs an ABI type check"
    run_program(tmp_path, "checked", helper.group(0) + """
proc valid(param: pointer): cint {.cdecl.} = 0
proc noResult(param: pointer) {.cdecl.} = discard
proc wrongArgument(param: uint32): cint {.cdecl.} = 0
proc wrongResult(param: pointer): uint32 {.cdecl.} = 0
proc wrongConvention(param: pointer): cint {.nimcall.} = 0
static:
  doAssert compiles(keMsgHandlerAddress(valid))
  doAssert not compiles(keMsgHandlerAddress(noResult))
  doAssert not compiles(keMsgHandlerAddress(wrongArgument))
  doAssert not compiles(keMsgHandlerAddress(wrongResult))
  doAssert not compiles(keMsgHandlerAddress(wrongConvention))
doAssert keMsgHandlerAddress(valid) == cast[pointer](valid)
""")


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_connection_loss_is_saved_until_idle(tmp_path: Path, mode: str) -> None:
    source = """
const
  TASK_SM = 4'u8
  TASK_MM = 0'u8
  MAX_VIFS = 2
  MM_CONNECTION_LOSS_IND = 0x31'u16
  SM_SA_QUERY_TIMEOUT_IND_MSG = 0x1009'u16
  KeMsgTailSlack = 4'u32
  SmIdleState = 0'u16
  SmDisconnectingState = 10'u16
  KeMsgConsumed = 0.cint
  KeMsgSaved = 2.cint
  VIF_TYPE_STA = 0'u8
"""
    source += layouts("KeMsgHdr", "MmVifIdentity", "MmConnLossTag", "SmDisconnectHandoff",
                      "MmConnectionLossIndPayload")
    source += """
const MmConnectionLossIndPayloadSize = sizeof(MmConnectionLossIndPayload).uint32
type
  Vif = object
    vifIdx, staIdx, vifType, state: uint8
var
  vifs: array[2, Vif]
  rxVifEpochs: array[2, uint32]
  stationEpochs: array[16, uint32]
  mmBeaconProbeEpochs, mmTrafficProbeEpochs: array[MAX_VIFS, uint32]
  txResetEpoch: uint32
  mmConnLossTags: ptr MmConnLossTag
  sent: seq[pointer]
  onAlloc, onSmState: proc()
  interruptsEnabled = true
  nimFwDbgConnLossInd, nimFwDbgDisconnectProcess: uint32
  sm: tuple[connectInfo: pointer, saQueryActive: uint8]
  state: uint16
  disconnects, tlvCalls: int
  lastVif: pointer
  lastReason: uint16
proc irqSave(): uint32 =
  result = if interruptsEnabled: 8'u32 else: 0'u32
  interruptsEnabled = false
proc irqRestore(saved: uint32) = interruptsEnabled = (saved and 8) != 0
proc keMsgHdrFromPayload(p: pointer): ptr KeMsgHdr =
  cast[ptr KeMsgHdr](cast[uint](p) - sizeof(KeMsgHdr).uint)
proc mmConnectionLossIndView(p: pointer): ptr MmConnectionLossIndPayload =
  cast[ptr MmConnectionLossIndPayload](p)
proc mmConnLossForget(header: pointer)
proc ke_msg_alloc(id: uint16; destination, source: uint8; length: uint32): pointer =
  let header = cast[ptr KeMsgHdr](alloc0(sizeof(KeMsgHdr) + length.int + KeMsgTailSlack.int))
  header.id = id
  header.destId = destination
  header.srcId = source
  header.paramLen = length
  result = cast[pointer](cast[uint](header) + sizeof(KeMsgHdr).uint)
  if onAlloc != nil: onAlloc()
proc ke_msg_free_payload(p: pointer) =
  let header = keMsgHdrFromPayload(p)
  mmConnLossForget(cast[pointer](header))
  dealloc(header)
proc ke_msg_send(p: pointer) = sent.add(p)
proc vifChannelForIdx(index: uint8): ptr Vif = addr vifs[index]
proc vifChannelAt(p: pointer): ptr Vif = cast[ptr Vif](p)
proc staDeleteEpoch(index: uint8): uint32 =
  if index < stationEpochs.len.uint8: stationEpochs[index] else: 0'u32
proc ke_state_get(task: uint8): uint16 =
  doAssert task == TASK_SM
  state
proc ke_state_set(task: uint8; value: uint16) =
  doAssert task == TASK_SM
  state = value
  if onSmState != nil: onSmState()
proc sm_connection_tlv_set() =
  inc tlvCalls
proc smEnvView(): ptr typeof(sm) = addr sm
proc keTimerClearLocked(id: uint16; task: uint8; saved: uint32) = irqRestore(saved)
proc smCleanupBegin(vif: pointer; disconnected: bool; status, reason: uint16;
                    handoff: SmDisconnectHandoff): bool =
  doAssert disconnected and handoff.peer.vif == vif
  # The firmware stores the MM loss reason in the status field.
  doAssert state == SmDisconnectingState and reason == 0xFFFF
  lastVif = vif
  lastReason = status
  inc disconnects
  true
"""
    kernel = (FW / "kernel_mac_channel.nim").read_text()
    for name in ["mmCaptureVif", "mmVifCurrent", "mmConnLossTagAt", "mmConnLossProbeEpoch",
                 "mmConnLossTagFor", "mmPublishConnectionLoss", "mm_send_connection_loss_ind"]:
        source += procedure(kernel, name)
    source += procedure(kernel[kernel.index("proc mmConnLossForget(header: pointer) ="):],
                        "mmConnLossForget")
    source += owned_disconnect_source()
    source += procedure((FW / "task_handlers.nim").read_text(),
                        "mm_connection_loss_ind_handler")
    source += """
let handler: proc(param: pointer): cint {.cdecl.} = mm_connection_loss_ind_handler
vifs[1] = Vif(vifIdx: 1, staIdx: 2, vifType: VIF_TYPE_STA, state: 1)
proc nextIndication(): pointer =
  let oldLength = sent.len
  mm_send_connection_loss_ind(addr vifs[1], 0x1234)
  doAssert sent.len == oldLength + 1
  result = sent.pop()
  doAssert keMsgHdrFromPayload(result).paramLen == MmConnectionLossIndPayloadSize
  doAssert mmConnLossTags != nil
proc release(p: pointer) =
  ke_msg_free_payload(p)
  doAssert mmConnLossTags == nil

state = SmIdleState
let immediate = nextIndication()
doAssert handler(immediate) == KeMsgConsumed
doAssert state == SmDisconnectingState and disconnects == 1 and tlvCalls == 1
doAssert lastVif == cast[pointer](addr vifs[1]) and lastReason == 0x1234
doAssert handler(immediate) == KeMsgConsumed and disconnects == 1
release(immediate)

for invalidation in 0 .. 3:
  state = 6
  let pending = nextIndication()
  doAssert handler(pending) == KeMsgSaved
  let count = disconnects
  case invalidation
  of 0: inc rxVifEpochs[1]
  of 1: inc stationEpochs[2]
  else: vifs[1].staIdx = 3
  state = SmIdleState
  doAssert handler(pending) == KeMsgConsumed
  doAssert disconnects == count and state == SmIdleState
  release(pending)
  vifs[1].staIdx = 2

for busyState in 1'u16 .. 10'u16:
  state = busyState
  let pending = nextIndication()
  doAssert handler(pending) == KeMsgSaved
  let count = disconnects
  state = SmIdleState
  doAssert handler(pending) == KeMsgConsumed
  doAssert disconnects == count + 1 and state == SmDisconnectingState
  release(pending)

for mutation in 0 .. 6:
  state = SmIdleState
  let malformed = nextIndication()
  let header = keMsgHdrFromPayload(malformed)
  let ind = mmConnectionLossIndView(malformed)
  case mutation
  of 0: ind.reason = 0x4321
  of 1: ind.vifIdx = 255
  of 2: header.paramLen = 3
  of 3: header.id = 0
  of 4: header.destId = 0
  of 5: header.srcId = 1
  else: header.paramLen = 5
  let count = disconnects
  doAssert handler(malformed) == KeMsgConsumed
  doAssert disconnects == count and state == SmIdleState
  release(malformed)

state = SmIdleState
vifs[1].state = 0
let inactive = nextIndication()
let count = disconnects
doAssert handler(inactive) == KeMsgConsumed and disconnects == count
release(inactive)
vifs[1].state = 1

let untagged = ke_msg_alloc(MM_CONNECTION_LOSS_IND, TASK_SM, TASK_MM,
                            MmConnectionLossIndPayloadSize)
mmConnectionLossIndView(untagged).vifIdx = 1
doAssert handler(untagged) == KeMsgConsumed and disconnects == count
release(untagged)

onAlloc = proc() = inc rxVifEpochs[1]
mm_send_connection_loss_ind(addr vifs[1], 0x1234)
doAssert sent.len == 0 and mmConnLossTags == nil
onAlloc = nil
doAssert tlvCalls == disconnects

# A newer beacon or ACK retires a queued probe loss even on the same VIF.
# Keep a still-current control with a change to the other VIF.
for replay in [false, true]:
  for recoveredHere in [false, true]:
    mmBeaconProbeEpochs = [2'u32, 7]
    var probe = mmBeaconProbeEpochs[1]
    mmPublishConnectionLoss(addr vifs[1], 16, addr probe)
    doAssert sent.len == 1
    let pending = sent.pop()
    if replay:
      state = 6
      doAssert handler(pending) == KeMsgSaved
    if recoveredHere: inc mmBeaconProbeEpochs[1]
    else: inc mmBeaconProbeEpochs[0]
    let prior = disconnects
    state = SmIdleState
    doAssert handler(pending) == KeMsgConsumed
    doAssert disconnects == prior + (not recoveredHere).int
    doAssert state == (if recoveredHere: SmIdleState else: SmDisconnectingState)
    if not recoveredHere: doAssert lastReason == 16
    release(pending)

var probe = mmBeaconProbeEpochs[1]
onAlloc = proc() = inc mmBeaconProbeEpochs[1]
mmPublishConnectionLoss(addr vifs[1], 16, addr probe)
doAssert sent.len == 0 and mmConnLossTags == nil
onAlloc = nil

state = SmIdleState
let staleAtTransition = nextIndication()
let beforeTransition = disconnects
onSmState = proc() =
  doAssert state == SmDisconnectingState
  inc rxVifEpochs[1]
  state = 6
doAssert handler(staleAtTransition) == KeMsgConsumed
doAssert state == 6 and disconnects == beforeTransition
onSmState = nil
release(staleAtTransition)
"""
    run_program(tmp_path, mode, source)
