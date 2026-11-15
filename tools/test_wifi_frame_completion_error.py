"""Keep internal TX completion ownership consistent across callback errors."""

from pathlib import Path
import re

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_frame_allocation import PLATFORM
from test_wifi_message_allocation import run_program


def source(tx: str | None = None) -> str:
    tx = tx if tx is not None else (FW / "tx_layer.nim").read_text()
    code = PLATFORM + r'''
var txEnv: tuple[packetCounter: uint32]
var events: uint32
var expectedIrq: bool
var callbackCount: array[4, int]
proc txControlEnv(): ptr typeof(txEnv) = addr txEnv
proc ke_evt_set(bits: uint32) = events = events or bits
proc ke_evt_clear(bits: uint32) = events = events and not bits
proc nimFwMgmtFcTrace(fc: uint8): bool = false
proc noteMgmtTxConfirm(d: ptr HostTxDescView; status, phase: uint32) = discard
proc sta_mgmt_aging_postponed_desc(sta: pointer; maxCount: uint32): uint32 = 0
'''
    functions = "".join(procedure(tx, name) for name in [
        "txl_frame_desc_index", "txlCaptureFrameIdentity", "txlFrameBeginLease",
        "txlFrameEndLease", "txlFrameLeaseToken", "txlFrameLeaseMatches",
        "txlFrameIdentityCurrent", "txlFrameSessionCurrent", "txlCaptureFrameCallback",
        "txlFrameCallbackCurrent", "txlInvokeFrameCallback", "txl_frame_free_list_pop",
        "txl_frame_get", "txl_frame_release", "txlFrameConfirmPending", "txl_frame_evt",
    ])
    debug = "\nvar\n" + "".join(
        f"  {name}: uint32\n" for name in sorted(set(re.findall(r"\bnimFwDbg\w+", functions)))
    )
    return code + debug + functions + r'''
proc prepare(incoming: bool) =
  interruptsEnabled = true
  initPool()
  expectedIrq = incoming
  interruptsEnabled = incoming
  callbackCount = default(typeof(callbackCount))
  events = 0x1000
  txEnv.packetCounter = 0
proc allocate(): ptr HostTxDescView =
  result = hostTxDescAt(txl_frame_get(24))
  doAssert result != nil
  result.vifIdx = 0
  result.staInfoIdx = 255
proc enqueue(frame: ptr HostTxDescView) =
  inc txEnv.packetCounter
  co_list_push_back(addr frameEnv.usedList, addr frame.link)
  events = events or 0x80000
proc checkCallback(frame: ptr HostTxDescView) =
  doAssert interruptsEnabled == expectedIrq
  doAssert txActiveFrameCallback != nil
  doAssert txlFrameCallbackCurrent()
proc normalCompletion(argument: pointer; status: uint32) {.cdecl.} =
  checkCallback(hostTxDescAt(argument))
  inc callbackCount[1]
'''


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_callback_error_releases_old_frame_and_rearms_pending_work(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
proc failed(argument: pointer; status: uint32) {.cdecl, raises: [Exception].} =
  checkCallback(hostTxDescAt(argument))
  inc callbackCount[0]
  raise newException(ValueError, "completion stopped")
for incoming in [false, true]:
  prepare(incoming)
  let first = allocate()
  let second = allocate()
  first.callback = cast[pointer](failed)
  first.callbackArg = first
  second.callback = cast[pointer](normalCompletion)
  second.callbackArg = second
  enqueue(first)
  enqueue(second)
  let firstLease = txlFrameLeaseToken(first)
  var previous: TxFrameCallbackScope
  txActiveFrameCallback = addr previous
  var raised = false
  try: txl_frame_evt()
  except ValueError: raised = true
  doAssert raised and callbackCount == [1, 0, 0, 0]
  doAssert txEnv.packetCounter == 1 and interruptsEnabled == incoming
  doAssert txActiveFrameCallback == (addr previous)
  doAssert not txlFrameLeaseMatches(first, firstLease), "failed callback retained its completed lease"
  doAssert co_list_cnt(addr frameEnv.freeList) == 3, "completed frame was not returned"
  doAssert frameEnv.usedList.first == (addr second.link)
  doAssert frameEnv.usedList.last == (addr second.link)
  doAssert events == 0x81000, "pending completion lost its scheduler event"
  txl_frame_evt()
  doAssert callbackCount == [1, 1, 0, 0] and txEnv.packetCounter == 0
  doAssert frameEnv.usedList.first == nil and events == 0x1000
  doAssert co_list_cnt(addr frameEnv.freeList) == 4
  doAssert interruptsEnabled == incoming and txActiveFrameCallback == (addr previous)
  txActiveFrameCallback = nil
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_retry_ownership_survives_callback_error(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
proc retry(argument: pointer; status: uint32) {.cdecl, raises: [Exception].} =
  let frame = hostTxDescAt(argument)
  checkCallback(frame)
  inc callbackCount[0]
  frame.retryFlag = 1
  frame.callback = cast[pointer](normalCompletion)
  enqueue(frame)
  raise newException(ValueError, "retry callback stopped")
for incoming in [false, true]:
  prepare(incoming)
  let frame = allocate()
  frame.callback = cast[pointer](retry)
  frame.callbackArg = frame
  let generation = txlFrameLeaseToken(frame)
  enqueue(frame)
  var raised = false
  try: txl_frame_evt()
  except ValueError: raised = true
  doAssert raised and callbackCount == [1, 0, 0, 0]
  doAssert txlFrameLeaseMatches(frame, generation)
  doAssert frame.retryFlag == 0, "retry marker from the retired completion was not cleared"
  doAssert frameEnv.usedList.first == (addr frame.link)
  doAssert co_list_cnt(addr frameEnv.freeList) == 3
  doAssert txEnv.packetCounter == 1 and events == 0x81000
  doAssert interruptsEnabled == incoming and txActiveFrameCallback == nil
  txl_frame_evt()
  doAssert callbackCount == [1, 1, 0, 0] and txEnv.packetCounter == 0
  doAssert co_list_cnt(addr frameEnv.freeList) == 4 and events == 0x1000
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_replaced_lease_survives_callback_error(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
var replacement: ptr HostTxDescView
var replacementSnapshot: HostTxDescView
var replacementGeneration: uint32
proc replace(argument: pointer; status: uint32) {.cdecl, raises: [Exception].} =
  let frame = hostTxDescAt(argument)
  checkCallback(frame)
  inc callbackCount[0]
  txl_frame_release(frame, false)
  replacement = allocate()
  doAssert replacement == frame
  replacement.pendingMacTime = 0x12345678
  replacement.retryFlag = 1
  replacementSnapshot = replacement[]
  replacementGeneration = txlFrameLeaseToken(replacement)
  raise newException(ValueError, "replacement callback stopped")
for incoming in [false, true]:
  prepare(incoming)
  var held: array[4, ptr HostTxDescView]
  for frame in held.mitems: frame = allocate()
  held[0].callback = cast[pointer](replace)
  held[0].callbackArg = held[0]
  enqueue(held[0])
  var raised = false
  try: txl_frame_evt()
  except ValueError: raised = true
  doAssert raised and callbackCount == [1, 0, 0, 0]
  doAssert replacement[] == replacementSnapshot
  doAssert txlFrameLeaseMatches(replacement, replacementGeneration)
  doAssert frameEnv.freeList.first == nil and frameEnv.usedList.first == nil
  doAssert txEnv.packetCounter == 0 and events == 0x1000
  doAssert interruptsEnabled == incoming and txActiveFrameCallback == nil
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_nested_completion_error_returns_each_owned_frame_once(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
proc failed(argument: pointer; status: uint32) {.cdecl, raises: [Exception].} =
  checkCallback(hostTxDescAt(argument))
  inc callbackCount[1]
  raise newException(ValueError, "nested completion stopped")
proc nested(argument: pointer; status: uint32) {.cdecl, raises: [Exception].} =
  checkCallback(hostTxDescAt(argument))
  inc callbackCount[0]
  txl_frame_evt()
for incoming in [false, true]:
  prepare(incoming)
  let first = allocate()
  let second = allocate()
  first.callback = cast[pointer](nested)
  first.callbackArg = first
  second.callback = cast[pointer](failed)
  second.callbackArg = second
  enqueue(first)
  enqueue(second)
  var raised = false
  try: txl_frame_evt()
  except ValueError: raised = true
  doAssert raised and callbackCount == [1, 1, 0, 0]
  doAssert txEnv.packetCounter == 0 and events == 0x1000
  doAssert frameEnv.usedList.first == nil and co_list_cnt(addr frameEnv.freeList) == 4
  doAssert interruptsEnabled == incoming and txActiveFrameCallback == nil
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_external_frame_keeps_its_owner_after_callback_error(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, source() + r'''
var replaceOwner: bool
var externalSnapshot: HostTxDescView
proc failed(argument: pointer; status: uint32) {.cdecl, raises: [Exception].} =
  let frame = hostTxDescAt(argument)
  checkCallback(frame)
  inc callbackCount[0]
  if replaceOwner:
    inc mmBcnGeneration
    frame.retryFlag = 1
    frame.pendingMacTime = 123
  externalSnapshot = frame[]
  raise newException(ValueError, "external completion stopped")
for incoming in [false, true]:
  for replace in [false, true]:
    prepare(incoming)
    replaceOwner = replace
    var externalHw: HwDesc
    var external = HostTxDescView(usedFlag: 1, hwDesc: addr externalHw,
      callback: cast[pointer](failed), vifIdx: 0, staInfoIdx: 255)
    external.callbackArg = addr external
    enqueue(addr external)
    var raised = false
    try: txl_frame_evt()
    except ValueError: raised = true
    doAssert raised and callbackCount == [1, 0, 0, 0]
    doAssert external == externalSnapshot
    doAssert txEnv.packetCounter == 0 and events == 0x1000
    doAssert frameEnv.usedList.first == nil and co_list_cnt(addr frameEnv.freeList) == 4
    doAssert interruptsEnabled == incoming and txActiveFrameCallback == nil
''')
