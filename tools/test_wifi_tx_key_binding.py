"""Keep reserved TX packet numbers attached to their selected key revision."""

from pathlib import Path

import pytest

from test_wifi_message_allocation import run_program
from test_wifi_disconnect_tx import FW
from test_wifi_tx_counter_limit import SETUP
from test_wifi_tx_security import program_source


CASES = {
    "same_slot_replacement": r'''
setup(2, 41, true)
doAssert allocate() == 8
when declared(rxKeyRevision):
  inc rxKeyRevision
  rxKeyLastChanged[0] = rxKeyRevision
key.pnLow = 0
key.pnHigh = 0
let before = frame
doAssert txu_cntrl_sec_hdr_append(addr desc, addr frame[48], 1) == nil,
  "reserved packet number was used with a replacement key"
doAssert frame == before and counter() == 0
''',
    "selector_change": r'''
setup(2, 41, true)
doAssert allocate() == 8
var replacement = key
keys.pairwiseKey = addr replacement
let before = frame
doAssert txu_cntrl_sec_hdr_append(addr desc, addr frame[48], 1) == nil,
  "reserved packet number followed a different key pointer"
doAssert frame == before
''',
    "no_key_to_key": r'''
setup(2, 41, true)
keys.pairwiseKey = nil
doAssert allocate() == 0
keys.pairwiseKey = addr key
let before = frame
doAssert txu_cntrl_sec_hdr_append(addr desc, addr frame[48], 1) == nil
doAssert frame == before and counter() == 41
''',
    "unrelated_key": r'''
setup(2, 41, true)
doAssert allocate() == 8
when declared(rxKeyRevision):
  inc rxKeyRevision
  rxKeyLastChanged[1] = rxKeyRevision
doAssert txu_cntrl_sec_hdr_append(addr desc, addr frame[48], 1) == cast[pointer](addr frame[40])
''',
    "counter_advance": r'''
setup(2, 41, true)
doAssert allocate() == 8
var other = desc
doAssert txu_cntrl_sechdr_len_compute(addr other, addr tail) == 8
doAssert counter() == 43
doAssert txu_cntrl_sec_hdr_append(addr desc, addr frame[48], 1) == cast[pointer](addr frame[40])
doAssert desc.pnScratch[0] == 42 and other.pnScratch[0] == 43
''',
    "revision_wrap": r'''
setup(2, 41, true)
when declared(rxKeyRevision):
  rxKeyRevision = high(uint64)
  rxKeyLastChanged[0] = 1
doAssert allocate() == 8
when declared(rxKeyRevision):
  rxKeyRevision = 1
  rxKeyLastChanged[0] = 1
doAssert txu_cntrl_sec_hdr_append(addr desc, addr frame[48], 1) == nil
''',
    "capacity_and_release": r'''
setup(2, 41, true)
var frames: array[TxSecurityReservationCount + 1, HostTxDescView]
for i in 0..<TxSecurityReservationCount:
  frames[i] = desc
  doAssert txu_cntrl_sechdr_len_compute(addr frames[i], addr tail) == 8
let reservedPn = counter()
frames[^1] = desc
let before = frames[^1]
doAssert txu_cntrl_sechdr_len_compute(addr frames[^1], addr tail) == high(uint32)
doAssert counter() == reservedPn and frames[^1] == before and tail == 0
txSecurityForget(addr frames[3])
doAssert txu_cntrl_sechdr_len_compute(addr frames[^1], addr tail) == 8
doAssert counter() == reservedPn + 1
''',
    "reuse_after_release": r'''
setup(2, 41, true)
doAssert allocate() == 8
inc rxKeyRevision
rxKeyLastChanged[0] = rxKeyRevision
doAssert not txSecurityCurrent(addr desc)
txSecurityForget(addr desc)
doAssert allocate() == 8 and txSecurityCurrent(addr desc)
doAssert txu_cntrl_sec_hdr_append(addr desc, addr frame[48], 1) == cast[pointer](addr frame[40])
''',
    "bip_selection": r'''
setup(5, 41, true)
key.staIdx = 4
vifs[1].groupKeyPtr = addr key
doAssert txSecurityBind(addr desc, addr key, true)
doAssert txSecurityCurrent(addr desc)
keys.pairwiseKey = nil
doAssert txSecurityCurrent(addr desc)
inc rxKeyRevision
rxKeyLastChanged[0] = rxKeyRevision
doAssert not txSecurityCurrent(addr desc)
''',
    "descriptor_identity": r'''
setup(2, 41, true)
doAssert allocate() == 8
desc.vifIdx = 0
doAssert not txSecurityCurrent(addr desc)
desc.vifIdx = 1
desc.staInfoIdx = 2
doAssert not txSecurityCurrent(addr desc)
desc.staInfoIdx = 3
doAssert txSecurityCurrent(addr desc)
''',
    "metadata_transition": r'''
for cipher in [1'u8, 2'u8]:
  for newId in 0'u8..3'u8:
    for changeCipher in [false, true]:
      for enabled in [false, true]:
        setup(cipher, 41, enabled)
        if newId == key.staIdx and not changeCipher: continue
        for i in 0..<key.keyMaterial.len: key.keyMaterial[i] = (i + 31).uint8
        let material = key.keyMaterial
        doAssert allocate() == 8
        let oldCounter = counter()
        let beforeFrame = frame
        let beforePolicy = primary
        key.staIdx = newId
        if changeCipher: key.cipherType = (if cipher == 1: 2'u8 else: 1'u8)
        doAssert key.keyMaterial == material
        doAssert not txSecurityCurrent(addr desc), "old reservation followed changed key metadata"
        doAssert txu_cntrl_sec_hdr_append(addr desc, addr frame[48], 1) == nil
        doAssert frame == beforeFrame and primary == beforePolicy and counter() == oldCounter
        doAssert interrupts == enabled
        txSecurityForget(addr desc)
        doAssert allocate() == 8 and counter() == oldCounter + 1
        doAssert txSecurityCurrent(addr desc)
        doAssert txu_cntrl_sec_hdr_append(addr desc, addr frame[48], 1) == cast[pointer](addr frame[40])
        doAssert (frame[43] shr 6) == newId
        doAssert key.keyMaterial == material and interrupts == enabled
''',
}


@pytest.mark.parametrize("case", CASES)
@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_tx_key_binding(tmp_path: Path, case: str, mode: str) -> None:
    run_program(tmp_path, mode, program_source() + SETUP + CASES[case])


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_key_change_stops_software_handoff(tmp_path: Path, mode: str) -> None:
    from test_wifi_aes_cmac import procedure
    from test_wifi_lower_preparation import CHECKS, build_program

    code = build_program().split(CHECKS, 1)[0]
    old = procedure(code, "txSecurityCurrent")
    code = code.replace(old, "var keyCurrent = true\n"
                        "proc txSecurityCurrent(d: ptr HostTxDescView): bool = keyCurrent\n", 1)
    checks = r'''
for stage in ["lower", "append", "copy", "buffer_trace", "header", "traffic", "ps"]:
  reset()
  keyCurrent = true
  invalidated = false
  publications = 0
  var fired = false
  frames = default(typeof(frames))
  links = default(typeof(links))
  hw = default(typeof(hw))
  txEnv = default(TxEnv)
  backup = default(typeof(backup))
  frames[0] = HostTxDescView(vifIdx: 1, staInfoIdx: 0, staIdx: 0,
    hdrLen: 34, frameLen: (if stage == "header": 0x0008'u16 else: 0x8E88'u16),
    seqPassthrough: 100, hwDesc: addr hw[0], queueFirst: cast[pointer](1),
    policy: addr templateBytes)
  frames[0].bufferPtrs[0] = 0x20000000
  frames[0].bufferLens[0] = 100
  backup[3] = Queue(first: addr links[1], last: addr links[1])
  txEnv.ac[3].pending = CoList(first: addr frames[1].link, last: addr frames[1].link)
  txEnv.packetCounter = 1
  onStage = proc(actual: string) =
    if actual == stage:
      fired = true
      keyCurrent = false
  discard txl_cntrl_push(addr frames[0], 3)
  doAssert fired, "missing handoff hook: " & stage
  doAssert publications == 0, "stale key reached software publication"
  doAssert links[1].next == nil and frames[0].bufDesc == nil and interrupts
  doAssert txEnv.ac[3].pending.last == addr frames[1].link
'''
    run_program(tmp_path, mode, "{.define: bl808WifiConnectTrace.}\n" + code + checks)


def test_key_binding_lifecycle_hooks() -> None:
    from test_wifi_aes_cmac import procedure

    tx = (FW / "tx_layer.nim").read_text()
    for name in ["txlFrameBeginLease", "txlFrameEndLease"]:
        assert "txSecurityForget(desc)" in procedure(tx, name)
    init = procedure(tx, "txl_cntrl_init")
    assert init.index("txSecurityReset()") < init.index("txl_frame_init(0)")
    cfm = procedure((FW / "ipc_embedded.nim").read_text(), "ipc_emb_txcfm")
    assert cfm.index("txSecurityForget(desc)") < cfm.index("\n  utils_list_push_back(")
    push = procedure((FW / "tx_upper.nim").read_text(), "txu_cntrl_push")
    assert push.index("txSecurityForget(param)") < push.index("txlCaptureSession(desc)")


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_binding_released_before_reuse(tmp_path: Path, mode: str) -> None:
    from test_wifi_aes_cmac import procedure
    from test_wifi_auth_frames import layouts

    code = program_source() + SETUP + "\nconst STA_MGMT_FREE_STAS = 5\n"
    code += layouts("TxFrameIdentity") + r'''
const InvalidFrameDescIndex = high(uint32)
type
  Wrapper = object
    link: uint32
  IpcEnv = object
    hostTxCfmList: pointer
var
  tracked: pointer
  txFrameGeneration: uint32
  txFrameIdentities: array[1, TxFrameIdentity]
  wrapper: Wrapper
  ipcEnv: IpcEnv
  published: bool
proc txl_frame_desc_index(p: pointer): uint32 =
  if p == tracked: 0'u32 else: InvalidFrameDescIndex
proc ipcHostTxWrapperFromDesc(d: ptr HostTxDescView): ptr Wrapper = addr wrapper
proc ipcEmbEnvView(): ptr IpcEnv = addr ipcEnv
proc utils_list_push_back(list, node: pointer) =
  doAssert not interrupts
  doAssert txSecurityCurrent(addr desc), "binding survived IPC ownership publication"
  published = true
'''
    tx = (FW / "tx_layer.nim").read_text()
    code += procedure(tx, "txlFrameBeginLease") + procedure(tx, "txlFrameEndLease")
    code += procedure((FW / "ipc_embedded.nim").read_text(), "ipc_emb_txcfm")
    code += r'''
for enabled in [false, true]:
  setup(2, 41, enabled)
  tracked = addr desc
  for operation in 0..<3:
    doAssert allocate() == 8
    inc rxKeyRevision
    rxKeyLastChanged[0] = rxKeyRevision
    doAssert not txSecurityCurrent(addr desc)
    case operation
    of 0: txlFrameEndLease(addr desc)
    of 1: txlFrameBeginLease(addr desc, TxFrameIdentity())
    else:
      published = false
      ipc_emb_txcfm(addr desc)
      doAssert published
    doAssert txSecurityCurrent(addr desc) and interrupts == enabled
'''
    run_program(tmp_path, mode, code)
