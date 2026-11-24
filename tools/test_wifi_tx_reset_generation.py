"""Keep pre-reset TX preparation and frame contexts from crossing a reset."""

from pathlib import Path
import re

import pytest

from test_wifi_message_allocation import run_program
from test_wifi_disconnect_tx import ROOT
from test_wifi_station_tx_build import program_source as station_source
from test_wifi_tx_reset_admission import host_source, internal_source
from test_wifi_tx_reset_owner import source as reset_source


def with_epoch(code: str) -> str:
    if not re.search(r"(?m)^\s*txResetEpoch:\s*uint32", code):
        code = "var txResetEpoch: uint32\n" + code
    return code


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_host_preparation_stops_after_completed_reset(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, with_epoch(host_source()) + r'''
for lower in [true, false]:
  let stages = if lower: @["lower", "append", "copy", "buffer_trace", "traffic", "ps"]
               else: @["security", "rate", "policy"]
  var keyValue: uint32
  var keys: KeyList
  keys.pairwiseKey = addr keyValue
  for stage in stages:
    reset()
    resetBlocked = false
    txResetEpoch = 7
    frames = default(typeof(frames))
    links = default(typeof(links))
    hw = default(typeof(hw))
    backup = default(typeof(backup))
    txEnv = default(TxEnv)
    frames[0] = HostTxDescView(vifIdx: 1, staInfoIdx: 0, staIdx: 0,
      hdrLen: 34, qosExtLen: 8, frameLen: 0x8E88, seqPassthrough: 100,
      hwDesc: addr hw[0], queueFirst: cast[pointer](1), policy: addr templateBytes,
      cfmDst: addr hostStatuses[0], active: 1)
    frames[0].bufferPtrs[0] = 0x20000000
    frames[0].bufferLens[0] = 100
    staInfoForIdx(0).keyMat = addr keys
    publications = 0
    invalidated = false
    onPublish = nil
    calls.setLen(0)
    hostPublished.setLen(0)
    var fired = false
    onStage = proc(current: string) =
      if fired or current != stage: return
      fired = true
      inc txResetEpoch
      # The reset has finished before this preparation resumes.
      resetBlocked = false
      txEnv = default(TxEnv)
      backup = default(typeof(backup))
    if lower: discard txl_cntrl_push(addr frames[0], 3)
    else: doAssert not txu_cntrl_push(addr frames[0], 3)
    doAssert fired and publications == 0,
      "lower=" & $lower & " stage=" & stage & " publications=" & $publications
    doAssert txEnv.packetCounter == 1 and droppedStatus == 0xC0020000'u32
    doAssert hostPublished.len == 0 and interrupts
    for ac in 0 .. 4:
      doAssert backup[ac].first == nil and txEnv.ac[ac].pending.first == nil
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_held_frames_and_callbacks_keep_reset_epoch(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, with_epoch(internal_source()) + r'''
var expectedCurrent: bool
proc checkCallback(p: pointer; status: uint32) {.cdecl.} =
  doAssert txlFrameCallbackCurrent() == expectedCurrent
for force in [false, true]:
  txResetEpoch = 7
  resetBlocked = false
  initialize(0, 2)
  watching = false
  let oldContext = txlCaptureFrameCallback(held[0])
  inc txResetEpoch
  expectedCurrent = false
  txlInvokeFrameCallback(cast[pointer](checkCallback), nil, 0, oldContext)
  let accepted = if force: txl_cntrl_push_int_force(held[0], 2)
                 else: txl_cntrl_push_int(held[0], 2)
  doAssert accepted == 0 and drainCalls == 0 and postponeCalls == 0
  doAssert txEnv.packetCounter == 0 and co_list_cnt(addr frameEnv.freeList) == 1
  held[0] = hostTxDescAt(txl_frame_get(24))
  held[0].vifIdx = 1
  held[0].staInfoIdx = 1
  held[0].staIdx = 2
  expectedCurrent = true
  txlInvokeFrameCallback(cast[pointer](checkCallback), nil, 0,
                        txlCaptureFrameCallback(held[0]))
  doAssert txl_cntrl_push_int_force(held[0], 2) == 1
  doAssert drainCalls == 1 and txEnv.packetCounter == 1
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_reset_advances_epoch_once_per_outer_call(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, with_epoch(reset_source()) + r'''
setup()
resetMode = true
txResetEpoch = high(uint32) - 1
var nested = false
onFlush = proc(ac: uint8) =
  doAssert txResetEpoch == high(uint32)
  if nested: return
  nested = true
  txl_reset()
  doAssert txResetEpoch == high(uint32)
txl_reset()
doAssert nested and txResetEpoch == high(uint32)
setup()
resetMode = true
txl_reset()
doAssert txResetEpoch == 0 and not txResetActive
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_station_owner_is_not_current_after_reset(tmp_path: Path, mode: str) -> None:
    code = with_epoch(station_source())
    for name in ["states", "status_codes"]:
        code = code.replace(f"import bl808/wifi/fw_constants/{name}",
                            f'import "{ROOT}/src/bl808/wifi/fw_constants/{name}"')
    run_program(tmp_path, mode, code + r'''
setup(0)
txResetEpoch = 7
let before = smTxCapture(addr conn)
doAssert smTxOwnerCurrent(before)
inc txResetEpoch
doAssert not smTxOwnerCurrent(before)
let after = smTxCapture(addr conn)
doAssert smTxOwnerCurrent(after)
doAssert smTxBeginForVif(1).identity.captured
''')
