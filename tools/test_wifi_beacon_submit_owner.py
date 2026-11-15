"""Check beacon submission state across callbacks and replacement."""

from pathlib import Path

import pytest

import test_wifi_beacon_update as beacon
from test_wifi_ap_teardown import procedure
from test_wifi_beacon_transmit import SETUP


COMMON = r'''
type Snapshot = object
  environment: Env
  vif: Vif
  descriptor: Hw
  tim: typeof(txl_tim_ie_pool)
  bitmap: typeof(txl_tim_bitmap_pool)
  bytes: typeof(pool.bytes)
  counter: uint16
  station: typeof(stations[0])
proc snapshot(): Snapshot =
  Snapshot(environment: env, vif: vifs[TestVif], descriptor: descriptors[TestVif],
    tim: txl_tim_ie_pool, bitmap: txl_tim_bitmap_pool, bytes: pool.bytes,
    counter: txControl.seqCounter, station: stations[TestVif + 5])
proc replaceBeacon() =
  mm_bcn_init()
  mm_bcn_change(request(makeFrame(prefix = 4, dtim = 7), TestVif, 4))
  vifs[TestVif].timCountdown = 5
  txl_tim_ie_pool[2] = 5
  txControl.seqCounter = 888
  descriptors[TestVif].frameLen = 777
  stations[TestVif + 5].trafficFlags = 2
  stations[TestVif + 5].psStatus = 1234
install(TestVif)
interruptsEnabled = IncomingIrq
'''


REPLACEMENT = r'''
var replacement: Snapshot
proc replace() =
  doAssert interruptsEnabled == IncomingIrq
  replaceBeacon()
  replacement = snapshot()
HOOK_SETUP
mm_bcn_transmit(TestVif)
doAssert snapshot() == replacement, "earlier submission changed replacement state"
doAssert allocated.len == 0 and interruptsEnabled == IncomingIrq
FINAL_CHECK
'''


CASES = {
    "channel_replace": REPLACEMENT.replace("HOOK_SETUP", """
channelHook = proc() =
  channelHook = nil
  replace()
""").replace("FINAL_CHECK", "doAssert framePowerCalls == 1 and pushes == 0"),
    "power_replace": REPLACEMENT.replace("HOOK_SETUP", """
framePowerHook = proc() =
  framePowerHook = nil
  replace()
""").replace("FINAL_CHECK", "doAssert pushes == 0 and channelCalls == 0"),
    "push_reject_replace": REPLACEMENT.replace("HOOK_SETUP", """
pushHook = proc() =
  pushHook = nil
  replace()
  pushAccept = false
""").replace("FINAL_CHECK", "doAssert multicastRequests == 0 and postponed == 0"),
    "push_accept_replace": REPLACEMENT.replace("HOOK_SETUP", """
pushHook = proc() =
  pushHook = nil
  replace()
""").replace("FINAL_CHECK", "doAssert multicastRequests == 0 and postponed == 0"),
    "allocate_replace": REPLACEMENT.replace("HOOK_SETUP", """
vifs[TestVif].timFlags = 1
allocationHook = proc(id: uint16) =
  if id == MM_TRAFFIC_REQ_IND:
    allocationHook = nil
    replace()
""").replace("FINAL_CHECK", "doAssert multicastRequests == 0 and postponed == 0"),
    "send_replace": REPLACEMENT.replace("HOOK_SETUP", """
vifs[TestVif].timFlags = 1
allocationHook = proc(id: uint16) =
  if id == MM_TRAFFIC_REQ_IND:
    allocationHook = nil
    freeHook = proc() =
      freeHook = nil
      replace()
""").replace("FINAL_CHECK", "doAssert multicastRequests == 1 and postponed == 0"),
    "postponed_replace": REPLACEMENT.replace("HOOK_SETUP", """
vifs[TestVif].timFlags = 1
stations[TestVif + 5].trafficFlags = 2
postponedHook = proc() =
  postponedHook = nil
  replace()
  stations[TestVif + 5].psStatus = 9
  replacement = snapshot()
""").replace("FINAL_CHECK", "doAssert postponed == 1"),
    "prepare_repeat": r'''
channelHook = proc() =
  channelHook = nil
  doAssert env.active == 1 and not mmBeaconPoolIdle()
  doAssert interruptsEnabled == IncomingIrq
  mm_bcn_transmit(TestVif)
framePowerHook = proc() =
  framePowerHook = nil
  doAssert env.active == 1 and not mmBeaconPoolIdle()
  mm_bcn_transmit(TestVif)
  mm_bcn_change(request(makeFrame(), TestVif))
mm_bcn_transmit(TestVif)
doAssert pushes == 1 and framePowerCalls == 1 and assertions == 0
doAssert env.pendingCount == 1 and env.active == 0 and env.transmitRequested == 0
doAssert confirmations == @[8'u8] and allocated.len == 0
doAssert interruptsEnabled == IncomingIrq
''',
    "other_sequence": r'''
txControl.seqCounter = 65534
let oldCount = vifs[TestVif].timCountdown
let oldTim = txl_tim_ie_pool
let oldSequence = beaconFrameFixedView(cast[pointer](descriptors[TestVif].payloadStart)).seqCtrl
let oldLength = descriptors[TestVif].frameLen
pushHook = proc() =
  pushHook = nil
  discard nextTxSeqCtrl()
  pushAccept = false
mm_bcn_transmit(TestVif)
doAssert txControl.seqCounter == 0, "failed beacon rewound another frame's sequence"
doAssert txl_tim_ie_pool == oldTim and vifs[TestVif].timCountdown == oldCount
doAssert descriptors[TestVif].frameLen == oldLength
doAssert beaconFrameFixedView(cast[pointer](descriptors[TestVif].payloadStart)).seqCtrl == oldSequence
doAssert env.pendingCount == 0 and interruptsEnabled == IncomingIrq
''',
    "completed_rejection": r'''
var replacement: Snapshot
pushHook = proc() =
  pushHook = nil
  queueTim(25, 1, TestVif)
  mm_bcn_transmitted(addr vifs[TestVif])
  pushAccept = false
  replacement = snapshot()
mm_bcn_transmit(TestVif)
doAssert snapshot() == replacement
doAssert env.pendingCount == 0 and vifs[TestVif].timCount == 1
doAssert allocated.len == 0 and interruptsEnabled == IncomingIrq
''',
    "nested_submission": r'''
var replacement: Snapshot
pushHook = proc() =
  pushHook = nil
  mm_bcn_transmitted(addr vifs[TestVif])
  mm_bcn_transmit(TestVif)
  pushAccept = false
  replacement = snapshot()
mm_bcn_transmit(TestVif)
doAssert snapshot() == replacement
doAssert env.pendingCount == 1 and pushes == 2
doAssert allocated.len == 0 and interruptsEnabled == IncomingIrq
''',
    "vif_epoch": r'''
var replacement: Snapshot
framePowerHook = proc() =
  framePowerHook = nil
  inc rxVifEpochs[TestVif]
  env.active = 2
  vifs[TestVif].timCountdown = 7
  replacement = snapshot()
mm_bcn_transmit(TestVif)
doAssert snapshot() == replacement and pushes == 0
doAssert interruptsEnabled == IncomingIrq
''',
    "descriptor_changed": r'''
var replacement: Snapshot
framePowerHook = proc() =
  framePowerHook = nil
  vifs[TestVif].beaconTxDesc = addr descriptors[TestVif xor 1]
  replacement = snapshot()
  replacement.environment.active = 0
mm_bcn_transmit(TestVif)
doAssert snapshot() == replacement and pushes == 0
doAssert interruptsEnabled == IncomingIrq
''',
    "allocation_failed": r'''
vifs[TestVif].timFlags = 1
stations[TestVif + 5].trafficFlags = 2
failAllocation = true
mm_bcn_transmit(TestVif)
doAssert pushes == 1 and env.pendingCount == 1
doAssert multicastRequests == 0 and postponed == 1
doAssert allocated.len == 0 and stations[TestVif + 5].psStatus == 0
doAssert interruptsEnabled == IncomingIrq
''',
    "channel_changed": r'''
let before = snapshot()
framePowerHook = proc() =
  framePowerHook = nil
  onChannel = false
mm_bcn_transmit(TestVif)
doAssert snapshot() == before
doAssert framePowerCalls == 1 and channelCalls == 1 and pushes == 0
doAssert interruptsEnabled == IncomingIrq
''',
}


def checks(case: str, vif: int, irq: bool) -> str:
    return (SETUP + f"\nconst TestVif = {vif}'u8\n"
            + f"const IncomingIrq = {str(irq).lower()}\n" + COMMON + CASES[case])


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("vif", [0, 1])
@pytest.mark.parametrize("irq", [False, True])
@pytest.mark.parametrize("case", CASES)
def test_beacon_submission_preserves_state(tmp_path: Path, mode: str, vif: int,
                                           irq: bool, case: str) -> None:
    beacon.run(tmp_path, checks(case, vif, irq), mode, transmit=True)


MUTANTS = {
    "channel": "channel_replace",
    "power": "power_replace",
    "push": "nested_submission",
    "generation": "nested_submission",
    "preparation": "prepare_repeat",
    "sequence": "other_sequence",
    "reservation": "completed_rejection",
    "allocation": "allocate_replace",
    "publication": "send_replace",
    "postponed": "postponed_replace",
    "identity": "descriptor_changed",
    "epoch": "vif_epoch",
}


def mutate(program: str, mutation: str) -> str:
    start = program.index("proc mm_bcn_transmit*(", program.index("proc co_list_init"))
    old = procedure(program[start:], r"mm_bcn_transmit\b")
    if mutation == "channel":
        target, replacement = "if not current() or not onChannel:", "if not onChannel:"
    elif mutation == "power":
        target = "  if not current():\n    return\n  {.emit:"
        replacement = "  {.emit:"
    elif mutation == "push":
        target = "  if not ownsPreparation():\n    return\n  if pushResult == 0:"
        replacement = "  if pushResult == 0:"
    elif mutation == "generation":
        target, replacement = "  inc mmBcnGeneration\n", "  discard\n"
    elif mutation == "preparation":
        target, replacement = "  env.active = 1\n", ""
    elif mutation == "sequence":
        assert "  frame.seqCtrl = nextTxSeqCtrl()\n" in old
        bad = old.replace("  frame.seqCtrl = nextTxSeqCtrl()\n",
            "  let oldCounter = txControlEnv().seqCounter\n  frame.seqCtrl = nextTxSeqCtrl()\n", 1)
        bad = bad.replace("      frame.seqCtrl = oldSequence\n",
            "      frame.seqCtrl = oldSequence\n      txControlEnv().seqCounter = oldCounter\n", 1)
        assert bad != old
        return program.replace(old, bad, 1)
    elif mutation == "reservation":
        target, replacement = "    if env.pendingCount == 1:\n", "    if true:\n"
    elif mutation == "allocation":
        target, replacement = "    if not current():\n      if trafficMsg != nil:", "    if false:\n      if trafficMsg != nil:"
    elif mutation == "publication":
        target, replacement = "      if not current():\n        return\n    let bcnSta", "    let bcnSta"
    elif mutation == "postponed":
        target, replacement = "if current() and bcnSta.psStatus == 9:", "if bcnSta.psStatus == 9:"
    elif mutation == "identity":
        target, replacement = "vif.beaconTxDesc == txDescPtr and hwDesc.payloadStart == frameStart", "true"
    else:
        target, replacement = "mmBcnOwnerCurrent(staHwIdx, vifEpoch, poolEpoch) and", "mmBcnGeneration == poolEpoch and"
    assert old.count(target) == 1, mutation
    return program.replace(old, old.replace(target, replacement, 1), 1)


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("mutation", MUTANTS)
def test_beacon_submission_detects_missing_guard(tmp_path: Path, monkeypatch,
                                                mode: str, mutation: str) -> None:
    program = mutate(beacon.source(transmit=True), mutation)
    monkeypatch.setattr(beacon, "source", lambda **_: program)
    with pytest.raises(AssertionError, match=r"AssertionDefect|AddressSanitizer"):
        beacon.run(tmp_path, checks(MUTANTS[mutation], 0, True), mode, transmit=True)


def real_push_program() -> str:
    program = beacon.source(transmit=True)
    program = program.replace("  Vif = object\n", r'''
  RealFrame = object
    vifIdx, staInfoIdx: uint8
    hwDesc, bufDesc: pointer
  HostTxDescView = RealFrame
  RealLink = object
    macHeader: array[32, uint8]
  RealHeader = object
    frameControl, duration: uint16
    addr1: array[6, uint8]
  TxSessionIdentity = object
    vifEpoch, stationEpoch, resetEpoch: uint32
    vif, station: uint8
    captured: bool
  Vif = object
''', 1).replace("frame: tuple[vifIdx, staInfoIdx: uint8]", "frame: RealFrame", 1)
    program = program.replace("    chainedThd: pointer\n", "    chainedThd: pointer\n"
        "    secondaryTxHwDescPtr, secondaryDescToStatusPadding, ackPolicyControl, confirmStatus: uint32\n", 1)
    old = procedure(program, r"txl_frame_push\b")
    actual = procedure((beacon.FW / "tx_layer.nim").read_text(), r"txl_frame_push\b")
    # Native pointers are wider than the target's RV32 pointers. The test
    # exits at the real post-trace identity check, before header processing.
    target = "cast[uint32](cast[uint](addr linkDesc.macHeader[0]))"
    assert target in actual
    actual = actual.replace(target, "cast[uint](addr linkDesc.macHeader[0])", 1)
    platform = r'''
const
  NUM_TX_QUEUES = 5
  STA_INFO_TAB_ENTRIES = 7
var
  realLinks: array[2, RealLink]
  actualTraceHook: proc()
  nimFwDbgTxPushCalls: uint32
  realHandoffs: int
proc assert_err(a, b: cstring; line: cint)
proc hostTxDescAt(p: pointer): ptr HostTxDescView = cast[ptr HostTxDescView](p)
proc hostTxLinkDescAt(p: pointer): ptr RealLink = cast[ptr RealLink](p)
proc macDataFrameAt(p: pointer): ptr RealHeader = cast[ptr RealHeader](p)
proc staDeleteEpoch(station: uint8): uint32 = 0
proc txlVifIsRetiring(vif: uint8): bool = false
proc txlResetting(): bool = false
# Beacon descriptors are outside the four private frame slots.
proc txlFrameLeaseToken(d: ptr HostTxDescView): uint32 = 0
proc txlFrameLeaseMatches(d: ptr HostTxDescView; generation: uint32): bool = generation == 0
proc txlStationAdmits(d: ptr HostTxDescView): bool = true
proc txl_frame_release(d: ptr HostTxDescView; notify: bool) = discard
proc txl_cntrl_push_int(p: pointer; ac: uint8): uint8 =
  inc realHandoffs
  1
proc nimFwTrace2U32(s: string; a: auto; b: auto) =
  if actualTraceHook != nil: actualTraceHook()
'''
    tx = (beacon.FW / "tx_layer.nim").read_text()
    session = "".join(procedure(tx, name) for name in [
        "txlCaptureSession", "txlSessionCurrent", "txlFramePreparationCurrent"])
    return program.replace(old, platform + session + actual, 1)


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("remove_guard", [False, True])
def test_real_frame_push_rejection(tmp_path: Path, monkeypatch, mode: str,
                                   remove_guard: bool) -> None:
    program = real_push_program()
    if remove_guard:
        program = mutate(program, "push")
    monkeypatch.setattr(beacon, "source", lambda **_: program)
    code = SETUP + r'''
const TestVif = 0'u8
const IncomingIrq = true
''' + COMMON + r'''
for i in 0 .. 1:
  vifs[i].frame.hwDesc = addr descriptors[i]
  vifs[i].frame.bufDesc = addr realLinks[i]
var replacement: Snapshot
var traceCalls = 0
actualTraceHook = proc() =
  actualTraceHook = nil
  inc traceCalls
  doAssert not interruptsEnabled
  replaceBeacon()
  inc rxVifEpochs[TestVif]
  vifs[TestVif].frame.bufDesc = addr pool.bytes[348]
  mm_bcn_transmit(TestVif)
  replacement = snapshot()
mm_bcn_transmit(TestVif)
doAssert traceCalls == 1 and nimFwDbgTxPushCalls == 2
doAssert realHandoffs == 1 and env.pendingCount == 1
doAssert snapshot() == replacement, "old frame-push return changed replacement state"
doAssert allocated.len == 0 and interruptsEnabled
'''
    if remove_guard:
        with pytest.raises(AssertionError, match=r"AssertionDefect|AddressSanitizer"):
            beacon.run(tmp_path, code, mode, transmit=True)
    else:
        beacon.run(tmp_path, code, mode, transmit=True)
