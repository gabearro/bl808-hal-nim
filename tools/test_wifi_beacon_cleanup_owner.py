"""Exercise beacon cleanup's detached batches, generation checks and IRQ state."""

from pathlib import Path

import pytest

import test_wifi_beacon_update as beacon
from test_wifi_ap_teardown import procedure
from test_wifi_beacon_transmit import SETUP


CASES = {
    "dma_callback": r'''
# The old AC has finished draining before a callback installs a fresh pool.
install()
mm_bcn_transmit(0)
interruptsEnabled = INCOMING_IRQ
var replacement: Env
var replacementPool: typeof(pool.bytes)
var freshQueued: pointer
clearDoneHook = proc() =
  clearDoneHook = nil
  doAssert not interruptsEnabled
  mm_bcn_init()
  inc rxVifEpochs[0]
  vifs[0].beaconEnabled = 1
  mm_bcn_change(request(makeFrame(prefix = 5), prefix = 5))
  mm_bcn_transmit(0)
  mm_bcn_change(request(makeFrame(prefix = 7), prefix = 7))
  freshQueued = message(MM_TIM_UPDATE_REQ, TASK_MM, 5, 4)
  cast[ptr MmTimUpdatePayload](freshQueued)[] = MmTimUpdatePayload(aid: 33, setFlag: 1, vifIdx: 0)
  co_list_push_back(addr keMsgQueueSent, keMsgHdrFromPayload(freshQueued))
  replacement = env
  replacementPool = pool.bytes
doAssert mm_bcn_stop(addr vifs[0])
doAssert env == replacement, "old stop overwrote replacement pool"
doAssert pool.bytes == replacementPool
doAssert keMsgQueueSent.first == keMsgHdrFromPayload(freshQueued)
doAssert allocated.len == 2 and not mmBcnStopping
doAssert interruptsEnabled == INCOMING_IRQ
doAssert mm_bcn_stop(addr vifs[0])
doAssert allocated.len == 0
''',
    "private_batch": r'''
install()
env.pendingCount = 1
mm_bcn_change(request(makeFrame(prefix = 1), prefix = 1))
queueTim(17, 1)
interruptsEnabled = INCOMING_IRQ
mmBcnGeneration = high(uint32)
var replacement: Env
var replacementPool: typeof(pool.bytes)
freeHook = proc() =
  freeHook = nil
  doAssert interruptsEnabled == INCOMING_IRQ
  doAssert env.templatePtr == nil and env.timQueue.first == nil
  doAssert mmBcnGeneration == 0
  mm_bcn_init()
  mm_bcn_change(request(makeFrame(prefix = 8), prefix = 8))
  env.pendingCount = 1
  mm_bcn_change(request(makeFrame(prefix = 9), prefix = 9))
  queueTim(25, 1)
  replacement = env
  replacementPool = pool.bytes
mm_bcn_init()
doAssert env == replacement, "old init zeroed replacement pool"
doAssert pool.bytes == replacementPool
doAssert allocated.len == 2
doAssert interruptsEnabled == INCOMING_IRQ
mm_bcn_init()
doAssert allocated.len == 0
''',
    "kernel_batch": r'''
install()
let oldQueued = request(makeFrame(prefix = 4), prefix = 4)
co_list_push_back(addr keMsgQueueSent, keMsgHdrFromPayload(oldQueued))
let oldSaved = request(makeFrame(prefix = 3), prefix = 3)
co_list_push_back(addr keMsgQueueSaved, keMsgHdrFromPayload(oldSaved))
interruptsEnabled = INCOMING_IRQ
var replacement: Env
var freshSent, freshSaved: pointer
freeHook = proc() =
  freeHook = nil
  doAssert interruptsEnabled == INCOMING_IRQ
  doAssert keMsgQueueSent.first == nil and keMsgQueueSaved.first == nil
  mm_bcn_init()
  inc rxVifEpochs[0]
  vifs[0].beaconEnabled = 1
  freshSent = request(makeFrame(prefix = 6), prefix = 6)
  freshSaved = request(makeFrame(prefix = 7), prefix = 7)
  co_list_push_back(addr keMsgQueueSent, keMsgHdrFromPayload(freshSent))
  co_list_push_back(addr keMsgQueueSaved, keMsgHdrFromPayload(freshSaved))
  replacement = env
doAssert mm_bcn_stop(addr vifs[0])
doAssert env == replacement
doAssert keMsgQueueSent.first == keMsgHdrFromPayload(freshSent)
doAssert keMsgQueueSaved.first == keMsgHdrFromPayload(freshSaved)
doAssert allocated.len == 2 and not mmBcnStopping
doAssert beaconClears == 0, "stale stop entered the new DMA queue"
doAssert interruptsEnabled == INCOMING_IRQ
doAssert mm_bcn_stop(addr vifs[0])
doAssert allocated.len == 0
''',
    "vif_epoch": r'''
install()
let oldQueued = request(makeFrame())
co_list_push_back(addr keMsgQueueSent, keMsgHdrFromPayload(oldQueued))
interruptsEnabled = INCOMING_IRQ
var replacement: Env
var freshQueued: pointer
freeHook = proc() =
  freeHook = nil
  doAssert interruptsEnabled == INCOMING_IRQ
  inc rxVifEpochs[0]
  env.active = 1
  env.pendingCount = 17
  freshQueued = request(makeFrame(prefix = 6), prefix = 6)
  co_list_push_back(addr keMsgQueueSent, keMsgHdrFromPayload(freshQueued))
  replacement = env
doAssert mm_bcn_stop(addr vifs[0])
doAssert env == replacement
doAssert keMsgQueueSent.first == keMsgHdrFromPayload(freshQueued)
doAssert allocated.len == 1 and not mmBcnStopping
doAssert beaconClears == 0
doAssert interruptsEnabled == INCOMING_IRQ
ke_msg_free(co_list_pop_front(addr keMsgQueueSent))
env = default(Env)
''',
    "private_flush": r'''
install()
env.pendingCount = 1
mm_bcn_change(request(makeFrame(prefix = 1), prefix = 1))
queueTim(17, 1)
interruptsEnabled = INCOMING_IRQ
var replacement: Env
freeHook = proc() =
  freeHook = nil
  doAssert interruptsEnabled == INCOMING_IRQ
  doAssert env.templatePtr == nil and env.timQueue.first == nil
  mm_bcn_init()
  env.pendingCount = 1
  mm_bcn_change(request(makeFrame(prefix = 9), prefix = 9))
  queueTim(25, 1)
  replacement = env
mm_bcn_flush_updates(false)
doAssert env == replacement and allocated.len == 2
doAssert interruptsEnabled == INCOMING_IRQ
mm_bcn_init()
doAssert allocated.len == 0
''',
}


def mutate(program: str, mutation: str) -> str:
    if mutation == "generation":
        assert program.count("  inc mmBcnGeneration\n") == 4
        return program.replace("  inc mmBcnGeneration\n", "  discard\n")
    if mutation == "vif_epoch":
        old = " or\n      rxVifEpochs[vifIdx] != vifEpoch"
        assert old in program
        return program.replace(old, "", 1)
    if mutation == "init_guard":
        old = "  if mmBcnGeneration != poolEpoch:\n    return\n"
        assert old in program
        return program.replace(old, "", 1)
    if mutation == "stop_guard":
        old = "  if not mmBcnOwnerCurrent(vifIdx, vifEpoch, poolEpoch):\n    return true\n"
        assert program.count(old) == 2
        return program.replace(old, "")
    if mutation == "callback_irq":
        assert "  irqRestore(callbackIrq)\n" in program
        return program.replace("  irqRestore(callbackIrq)\n", "", 1)
    if mutation == "dma_irq":
        old = "  if not txl_cntrl_clear_bcn_ac(): return false\n"
        assert program.count(old) == 1
        return program.replace(old, "  irqRestore(saved)\n" + old, 1)
    assert mutation == "batch"
    old = procedure(program, "mmBcnCancelQueuedUpdates")
    # Deliberately drain the sent queue before detaching the saved queue.
    bad = old.replace(
        "    var detached: CoList\n    for queue in [addr keMsgQueueSent, addr keMsgQueueSaved]:\n",
        "    for queue in [addr keMsgQueueSent, addr keMsgQueueSaved]:\n      var detached: CoList\n",
    ).replace(
        "    if detached.first == nil:\n      return\n    while detached.first != nil:\n"
        "      let header = cast[ptr KeMsgHdr](co_list_pop_front(addr detached))\n"
        "      mmBcnReleaseUpdate(header, true, callbackIrq)\n",
        "      while detached.first != nil:\n"
        "        let header = cast[ptr KeMsgHdr](co_list_pop_front(addr detached))\n"
        "        mmBcnReleaseUpdate(header, true, callbackIrq)\n    return\n",
    )
    assert bad != old
    return program.replace(old, bad, 1)


MUTANTS = {
    "generation": "private_batch",
    "vif_epoch": "vif_epoch",
    "init_guard": "private_batch",
    "stop_guard": "dma_callback",
    "callback_irq": "private_flush",
    "dma_irq": "dma_callback",
    "batch": "kernel_batch",
}


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("incoming_irq", [False, True])
@pytest.mark.parametrize("case", CASES)
def test_beacon_cleanup_preserves_new_owner(tmp_path: Path, mode: str,
                                          incoming_irq: bool, case: str) -> None:
    checks = CASES[case].replace("INCOMING_IRQ", str(incoming_irq).lower())
    beacon.run(tmp_path, SETUP + checks, mode, transmit=True)


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("mutation", MUTANTS)
def test_beacon_cleanup_rejects_missing_guard(tmp_path: Path, monkeypatch,
                                            mode: str, mutation: str) -> None:
    program = mutate(beacon.source(transmit=True), mutation)
    monkeypatch.setattr(beacon, "source", lambda **_: program)
    checks = CASES[MUTANTS[mutation]].replace("INCOMING_IRQ", "true")
    with pytest.raises(AssertionError, match=r"AssertionDefect|AddressSanitizer"):
        beacon.run(tmp_path, SETUP + checks, mode, transmit=True)
