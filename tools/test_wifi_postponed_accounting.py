"""Check postponed accounting during callbacks and whole-table aging."""

from pathlib import Path
import re

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_frame_allocation import PLATFORM as ALLOCATION_PLATFORM
from test_wifi_frame_ownership import STA_QUEUE_STUBS
from test_wifi_message_allocation import run_program


PLATFORM = ALLOCATION_PLATFORM.replace(STA_QUEUE_STUBS, "").replace(
    "proc txlResetting(): bool = false",
    "var resetInProgress: bool\nproc txlResetting(): bool = resetInProgress",
).replace(
    "proc sta_mgmt_aging_postponed_desc(sta: pointer; maxCount: uint32): uint32",
    "proc sta_mgmt_aging_postponed_desc*(staEntry: pointer, maxCount: uint32): uint32 {.exportc, cdecl.}",
)
PLATFORM += r'''
var txRecoveryPostponed: CoList
proc configure() =
  initPool()
  resetInProgress = false
  txRecoveryPostponed = default(CoList)
  txActiveFlush = nil
  for i in 0 ..< stas.len:
    stas[i].instNbr = (i mod 2).uint8
    stas[i].valid = 1
'''


CASES = {
    "nested_reconcile": r'''
var callbackCount: int
var incoming: bool
proc confirmed(arg: pointer; status: uint32) {.cdecl.} =
  inc callbackCount
  doAssert interruptsEnabled == incoming and status == 0
  doAssert txActiveFlush != nil and txActiveFlush.previous != nil
  let pending = (3 - callbackCount).uint32
  doAssert frameEnv.postponedCount == pending
  wifi_nimfw_reconcile_postponed_count()
  doAssert frameEnv.postponedCount == pending,
    "reconciliation discarded frames held by the release batch"
for enabled in [false, true]:
  configure()
  incoming = enabled
  interruptsEnabled = enabled
  callbackCount = 0
  for i in 0 .. 2:
    let frame = hostTxDescAt(txl_frame_get(24))
    frame.vifIdx = 0
    frame.staInfoIdx = 0
    frame.postponeFlag = 1
    frame.callback = cast[pointer](confirmed)
    frame.pendingMacTime = 0
    co_list_push_back(addr stas[0].postponedList, addr frame.link)
  frameEnv.postponedCount = 3
  macTime = 120001
  let reconciles = nimFwDbgPostponedReconcile
  doAssert sta_mgmt_postponed_desc_release(addr stas[0], 0) == 3
  doAssert callbackCount == 3 and frameEnv.postponedCount == 0
  doAssert nimFwDbgPostponedReconcile == reconciles
  doAssert txActiveFlush == nil and interruptsEnabled == enabled
''',
    "recovery_and_public_reconcile": r'''
for enabled in [false, true]:
  configure()
  interruptsEnabled = enabled
  var frames: array[2, ptr HostTxDescView]
  for i in 0 .. 1:
    frames[i] = hostTxDescAt(txl_frame_get(24))
    frames[i].postponeFlag = 1
    co_list_push_back(addr txRecoveryPostponed, addr frames[i].link)
  frameEnv.postponedCount = 2
  let reconciles = nimFwDbgPostponedReconcile
  wifi_nimfw_reconcile_postponed_count()
  doAssert frameEnv.postponedCount == 2,
    "reconciliation discarded the recovery queue"
  doAssert nimFwDbgPostponedReconcile == reconciles
  txRecoveryPostponed = default(CoList)
  frames[0].link.next = nil
  frames[1].link.next = nil
  co_list_push_back(addr stas[0].postponedList, addr frames[0].link)
  co_list_push_back(addr stas[1].postponedList, addr frames[1].link)
  frameEnv.postponedCount = 99
  resetInProgress = true
  wifi_nimfw_reconcile_postponed_count()
  doAssert frameEnv.postponedCount == 99 and nimFwDbgPostponedReconcile == reconciles
  resetInProgress = false
  wifi_nimfw_reconcile_postponed_count()
  doAssert frameEnv.postponedCount == 2 and nimFwDbgPostponedReconcile == reconciles + 1
  doAssert nimFwDbgPostponedReconcileOld == 99 and nimFwDbgPostponedReconcileNew == 2
  wifi_nimfw_reconcile_postponed_count()
  doAssert nimFwDbgPostponedReconcile == reconciles + 1
  doAssert interruptsEnabled == enabled
''',
    "aging_lifetimes": r'''
var
  incoming, replaced: bool
  action, callbackCount: int
  replacement: ptr HostTxDescView
proc replaceNext(arg: pointer; status: uint32) {.cdecl.} =
  inc callbackCount
  doAssert status == 0 and interruptsEnabled == incoming
  case action
  of 0: inc stationEpochs[1]
  of 1: inc rxVifEpochs[1]
  of 2: inc txResetEpoch
  of 4: stas[1].instNbr = 0
  of 5: inc stationEpochs[3]
  else: discard
  if action in [0, 1, 2, 4]:
    txlDrainRetiredPostponed(addr stas[1].postponedList)
    replacement = hostTxDescAt(txl_frame_get(24))
    doAssert replacement != nil
    replacement.vifIdx = stas[1].instNbr
    replacement.staInfoIdx = 1
    replacement.postponeFlag = 1
    replacement.pendingMacTime = macTime
    co_list_push_back(addr stas[1].postponedList, addr replacement.link)
    inc frameEnv.postponedCount
    # A callback may take longer than the aging interval.
    macTime += 120001'u32
    replaced = true
for enabled in [false, true]:
  for change in 0 .. 5:
    configure()
    incoming = enabled
    interruptsEnabled = enabled
    action = change
    callbackCount = 0
    replaced = false
    replacement = nil
    macTime = 120001
    for i in 0 .. 3:
      let frame = hostTxDescAt(txl_frame_get(24))
      if i < 2:
        frame.vifIdx = i.uint8
        frame.staInfoIdx = i.uint8
        frame.postponeFlag = 1
        frame.pendingMacTime = 0
        co_list_push_back(addr stas[i].postponedList, addr frame.link)
        if i == 0: frame.callback = cast[pointer](replaceNext)
    frameEnv.postponedCount = 2
    let expected = if change in [0, 1, 2, 4]: 1'u32 else: 2'u32
    doAssert sta_mgmt_aging_postponed_desc(nil, 0) == expected
    doAssert callbackCount == 1 and interruptsEnabled == enabled
    doAssert frameEnv.postponedCount == (if replaced: 1'u32 else: 0'u32)
    if replaced:
      doAssert stas[1].postponedList.first == addr replacement.link
      doAssert replacement.postponeFlag == 1 and txlFrameSessionCurrent(replacement)
    else:
      doAssert stas[1].postponedList.first == nil
    doAssert txActiveFlush == nil
''',
}


def source() -> str:
    tx = (FW / "tx_layer.nim").read_text()
    sta = (FW / "sta_management.nim").read_text()
    layout = (FW / "layout_types.nim").read_text()
    identity = "type\n  StaQueueIdentity = object" + layout.split(
        "  StaQueueIdentity = object", 1
    )[1].split("\n  TxDmaOwner", 1)[0]
    code = "".join(procedure(tx, name) for name in [
        "txl_frame_desc_index", "txlCaptureFrameIdentity", "txlFrameBeginLease",
        "txlFrameEndLease", "txlFrameLeaseToken", "txlFrameLeaseMatches",
        "txlFrameIdentityCurrent", "txlFrameSessionCurrent", "txlCaptureFrameCallback",
        "txlFrameCallbackCurrent", "txlInvokeFrameCallback", "txl_frame_free_list_pop",
        "txl_frame_get", "txl_frame_release", "txlDrainRetiredPostponed",
        "wifi_nimfw_actual_postponed_count", "wifi_nimfw_reconcile_postponed_count",
    ])
    code += "".join(procedure(sta, name) for name in [
        "staPostponedOwner", "staPostponedOwnerCurrent", "staPostponedListValid",
        "staReleasePostponed", "sta_mgmt_postponed_desc_release",
        "sta_mgmt_aging_postponed_desc",
    ])
    names = sorted(set(re.findall(r"\bnimFwDbg\w+", code)))
    declarations = "var\n" + "".join(f"  {name}: uint32\n" for name in names)
    return PLATFORM + identity + declarations + code


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
@pytest.mark.parametrize("case", CASES)
def test_postponed_accounting(tmp_path: Path, mode: str, case: str) -> None:
    run_program(tmp_path, mode, source() + CASES[case])
