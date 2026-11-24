"""Exercise executing beacon requests across reentrant reset and confirmation."""

from pathlib import Path

import pytest

import test_wifi_beacon_update as beacon
from test_wifi_ap_teardown import procedure
from test_wifi_beacon_transmit import SETUP


RESET_CASE = r'''
install(TestVif)
interruptsEnabled = IncomingIrq
var frame = makeFrame()
frame.add([32'u8, 1, 3])
let oldRequest = request(frame, TestVif)
var replacement: Env
var replacementVif: Vif
var replacementHw: Hw
var replacementBytes: typeof(pool.bytes)
powerHook = proc() =
  powerHook = nil
  doAssert interruptsEnabled == IncomingIrq
  mm_bcn_init()
  doAssert allocated.find(oldRequest) >= 0, "reset freed an executing request"
  mm_bcn_change(request(makeFrame(prefix = 4), TestVif, 4))
  mm_bcn_transmit(TestVif)
  mm_bcn_change(request(makeFrame(prefix = 7), TestVif, 7))
  replacement = env
  replacementVif = vifs[TestVif]
  replacementHw = descriptors[TestVif]
  replacementBytes = pool.bytes
SUBMIT_REQUEST
doAssert env == replacement and vifs[TestVif] == replacementVif
doAssert descriptors[TestVif] == replacementHw and pool.bytes == replacementBytes
doAssert allocated.len == 1 and confirmations == @[0'u8, 1]
doAssert interruptsEnabled == IncomingIrq and mmBcnActiveUpdate == nil
discard mm_bcn_stop(addr vifs[TestVif])
doAssert allocated.len == 0
'''


CASES = {
    "reset_immediate": RESET_CASE.replace("SUBMIT_REQUEST", "mm_bcn_change(oldRequest)"),
    "reset_deferred": RESET_CASE.replace("SUBMIT_REQUEST", """
env.pendingCount = 1
mm_bcn_change(oldRequest)
doAssert env.templatePtr == oldRequest
mm_bcn_transmitted(addr vifs[TestVif])
"""),
    "vif_epoch": r'''
install(TestVif)
interruptsEnabled = IncomingIrq
var frame = makeFrame()
frame.add([32'u8, 1, 3])
let oldRequest = request(frame, TestVif)
var replacement: Env
var replacementVif: Vif
powerHook = proc() =
  powerHook = nil
  doAssert interruptsEnabled == IncomingIrq
  inc rxVifEpochs[TestVif]
  vifs[TestVif].beaconBodyLength = 177
  env.transmitRequested = 1
  replacement = env
  replacementVif = vifs[TestVif]
mm_bcn_change(oldRequest)
doAssert env == replacement and vifs[TestVif] == replacementVif
doAssert confirmations == @[1'u8] and allocated.len == 0
doAssert pushes == 0 and interruptsEnabled == IncomingIrq
doAssert mmBcnActiveUpdate == nil
mm_bcn_init()
''',
    "duplicate_scopes": r'''
install(TestVif)
interruptsEnabled = IncomingIrq
var frame = makeFrame()
frame.add([32'u8, 1, 3])
let oldRequest = request(frame, TestVif)
var innerRequest: pointer
var nestedCalls = 0
powerHook = proc() =
  powerHook = nil
  doAssert interruptsEnabled == IncomingIrq
  doAssert mmBcnRequestExecuting(oldRequest)
  mm_bcn_change(oldRequest)
confirmationHook = proc() =
  confirmationHook = nil
  doAssert interruptsEnabled == IncomingIrq and mmBcnRequestExecuting(oldRequest)
  env.transmitRequested = 0
  var innerFrame = makeFrame(prefix = 3)
  innerFrame.add([32'u8, 1, 4])
  innerRequest = request(innerFrame, TestVif, 3)
  powerHook = proc() =
    powerHook = nil
    inc nestedCalls
    doAssert mmBcnRequestExecuting(oldRequest) and mmBcnRequestExecuting(innerRequest)
    mm_bcn_change(oldRequest)
    mm_bcn_change(innerRequest)
  mm_bcn_change(innerRequest)
  doAssert not mmBcnRequestExecuting(innerRequest) and mmBcnRequestExecuting(oldRequest)
mm_bcn_change(oldRequest)
doAssert confirmations == @[0'u8, 0] and nestedCalls == 1
doAssert allocated.len == 0 and mmBcnActiveUpdate == nil
doAssert interruptsEnabled == IncomingIrq
''',
    "confirmation_transfer": r'''
install(TestVif)
interruptsEnabled = IncomingIrq
var replacement: Env
var replacementBytes: typeof(pool.bytes)
confirmationHook = proc() =
  confirmationHook = nil
  doAssert interruptsEnabled == IncomingIrq
  env.transmitRequested = 0
  mm_bcn_change(request(makeFrame(prefix = 7), TestVif, 7))
  env.transmitRequested = 1
  replacement = env
  replacementBytes = pool.bytes
mm_bcn_change(request(makeFrame(prefix = 4), TestVif, 4))
doAssert env == replacement and pool.bytes == replacementBytes
doAssert pushes == 0 and confirmations == @[0'u8, 0]
doAssert allocated.len == 0 and mmBcnActiveUpdate == nil
doAssert interruptsEnabled == IncomingIrq
''',
    "retire_before_free": r'''
install(TestVif)
interruptsEnabled = IncomingIrq
let oldRequest = request(makeFrame(), TestVif)
var requestFrees = 0
freeHook = proc() =
  doAssert interruptsEnabled == IncomingIrq
  if allocated.find(oldRequest) >= 0: return
  freeHook = nil
  inc requestFrees
  doAssert mmBcnActiveUpdate == nil, "freed request is still in the execution registry"
  mm_bcn_change(request(makeFrame(prefix = 6), TestVif, 6))
mm_bcn_change(oldRequest)
doAssert requestFrees == 1 and confirmations == @[0'u8, 0]
doAssert allocated.len == 0 and mmBcnActiveUpdate == nil
doAssert interruptsEnabled == IncomingIrq
''',
    "parser_power": r'''
for sta in [false, true]:
  install(TestVif)
  interruptsEnabled = IncomingIrq
  if sta: vifs[TestVif].vifType = 0
  var frame = makeFrame()
  frame.add([32'u8, 1, 3])
  newBandwidth = 2
  var allocations = 0
  allocationHook = proc(id: uint16) =
    if id == MM_CHAN_CTXT_UPDATE_REQ: inc allocations
  powerHook = proc() =
    powerHook = nil
    doAssert interruptsEnabled == IncomingIrq
    inc mmBcnGeneration
  me_beacon_check(TestVif, frame.len.uint16, addr frame[0])
  doAssert channelUpdates.len == sta.int and allocations == sta.int
  doAssert allocated.len == 0 and interruptsEnabled == IncomingIrq
''',
    "parser_allocation": r'''
for invalidateEpoch in [false, true]:
  install(TestVif)
  interruptsEnabled = IncomingIrq
  var frame = makeFrame()
  frame.add([32'u8, 1, 3])
  newBandwidth = 2
  var calls = 0
  allocationHook = proc(id: uint16) =
    if id != MM_CHAN_CTXT_UPDATE_REQ: return
    allocationHook = nil
    doAssert interruptsEnabled == IncomingIrq
    inc calls
    if invalidateEpoch: inc rxVifEpochs[TestVif]
    else: vifs[TestVif].chanCtxt = nil
    vifBssStatus(addr vifs[TestVif]).phyBandwidth = 7
  me_beacon_check(TestVif, frame.len.uint16, addr frame[0])
  doAssert calls == 1 and channelUpdates.len == 0 and allocated.len == 0
  doAssert vifBssStatus(addr vifs[TestVif]).phyBandwidth == 7
  doAssert interruptsEnabled == IncomingIrq
''',
    "completion_transfer": r'''
install(TestVif)
mm_bcn_transmit(TestVif)
queueTim(17, 1, TestVif)
queueTim(25, 1, TestVif)
interruptsEnabled = IncomingIrq
var replacement: Env
var replacementBitmap: typeof(txl_tim_bitmap_pool)
freeHook = proc() =
  freeHook = nil
  mm_bcn_init()
  mm_bcn_change(request(makeFrame(prefix = 4), TestVif, 4))
  mm_bcn_transmit(TestVif)
  queueTim(33, 1, TestVif)
  queueTim(41, 1, TestVif)
  replacement = env
  replacementBitmap = txl_tim_bitmap_pool
mm_bcn_transmitted(addr vifs[TestVif])
doAssert env == replacement and txl_tim_bitmap_pool == replacementBitmap
doAssert allocated.len == 2 and interruptsEnabled == IncomingIrq
discard mm_bcn_stop(addr vifs[TestVif])
doAssert allocated.len == 0
''',
    "admission_irq": r'''
install(TestVif)
interruptsEnabled = IncomingIrq
var copies = 0
copyHook = proc() =
  inc copies
  doAssert not interruptsEnabled, "template copy is not IRQ protected"
mmBcnGeneration = high(uint32)
mm_bcn_change(request(makeFrame(), TestVif))
doAssert copies == 1 and mmBcnGeneration == 0
doAssert confirmations == @[0'u8] and allocated.len == 0
doAssert interruptsEnabled == IncomingIrq and mmBcnActiveUpdate == nil
''',
    "completion_type": r'''
install(TestVif)
mm_bcn_transmit(TestVif)
interruptsEnabled = IncomingIrq
let before = env
vifs[TestVif].vifType = 0
mm_bcn_transmitted(addr vifs[TestVif])
doAssert env == before and interruptsEnabled == IncomingIrq
vifs[TestVif].vifType = VIF_TYPE_AP
discard mm_bcn_stop(addr vifs[TestVif])
doAssert allocated.len == 0
''',
}


def checks(case: str, vif: int, irq: bool) -> str:
    return (SETUP + f"\nconst TestVif = {vif}'u8\n"
            + f"const IncomingIrq = {str(irq).lower()}\n" + CASES[case])


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("vif", [0, 1])
@pytest.mark.parametrize("irq", [False, True])
@pytest.mark.parametrize("case", CASES)
def test_beacon_update_ownership(tmp_path: Path, mode: str, vif: int,
                                 irq: bool, case: str) -> None:
    beacon.run(tmp_path, checks(case, vif, irq), mode, transmit=True)


MUTANTS = {
    "detach": "reset_deferred",
    "commit_guard": "vif_epoch",
    "post_confirm": "confirmation_transfer",
    "ancestors": "duplicate_scopes",
    "retire": "retire_before_free",
    "parser_power": "parser_power",
    "parser_allocation": "parser_allocation",
    "completion": "completion_transfer",
    "irq": "admission_irq",
    "completion_type": "completion_type",
}


def mutate(program: str, mutation: str) -> str:
    name = {"parser_power": "me_beacon_check", "parser_allocation": "me_beacon_check",
            "ancestors": "mmBcnRequestExecuting", "retire": "mmBcnFinishUpdate",
            "completion": "mm_bcn_transmitted", "completion_type": "mm_bcn_transmitted",
            "irq": "mm_bcn_change"}.get(
                mutation, "mmBcnApplyUpdate")
    # The test platform contains forward declarations of these two routines.
    if name in {"mmBcnApplyUpdate", "mm_bcn_transmitted"}:
        start = program.index("proc " + name, program.index("proc co_list_init"))
        old = procedure(program[start:], name)
    else:
        old = procedure(program, name)
    if mutation == "detach":
        target = "  if env.templatePtr == request:\n    env.templatePtr = nil\n    env.deferredChange = 0\n"
        replacement = ""
    elif mutation == "commit_guard":
        target = "if not mmBcnOwnerCurrent(vifIdx, vifEpoch, poolEpoch) or\n"
        replacement = "if false or\n"
    elif mutation == "post_confirm":
        target = "if status == 0 and mmBcnOwnerCurrent(vifIdx, vifEpoch, poolEpoch) and\n"
        replacement = "if status == 0 and\n"
    elif mutation == "ancestors":
        target, replacement = "    scope = scope.previous\n", "    return false\n"
    elif mutation == "retire":
        target = "  mmBcnActiveUpdate = scope.previous\n  scope.request = nil\n"
        assert target in old
        bad = old.replace(target, "").replace("  ke_msg_free(header)\n", "  ke_msg_free(header)\n" + target)
        return program.replace(old, bad, 1)
    elif mutation == "parser_power":
        target, replacement = "    if not current():\n      return\n", ""
    elif mutation == "parser_allocation":
        target, replacement = "let valid = current() and vif.chanCtxt == contextPtr", "let valid = true"
    elif mutation == "completion":
        target = "    if not mmBcnOwnerCurrent(vifIdx, vifEpoch, poolEpoch):\n      return\n"
        replacement = ""
    elif mutation == "completion_type":
        target, replacement = " or\n      vif.vifType != VIF_TYPE_AP", ""
    else:
        target, replacement = "let saved = irqSave()", "let saved = if interruptsEnabled: 8'u32 else: 0'u32"
    assert old.count(target) == 1, mutation
    return program.replace(old, old.replace(target, replacement, 1), 1)


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("mutation", MUTANTS)
def test_beacon_update_detects_missing_guard(tmp_path: Path, monkeypatch,
                                             mode: str, mutation: str) -> None:
    program = mutate(beacon.source(transmit=True), mutation)
    monkeypatch.setattr(beacon, "source", lambda **_: program)
    with pytest.raises(AssertionError, match=r"AssertionDefect|AddressSanitizer"):
        beacon.run(tmp_path, checks(MUTANTS[mutation], 0, True), mode, transmit=True)
