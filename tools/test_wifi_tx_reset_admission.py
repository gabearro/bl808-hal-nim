"""Do not publish new transmissions or queued cancellations during reset."""

from pathlib import Path
import re

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_internal_preparation import CHECKS as INTERNAL_CHECKS, platform_source
from test_wifi_lower_preparation import CHECKS as LOWER_CHECKS, build_program
from test_wifi_message_allocation import run_program


def reset_gate(code: str) -> str:
    gate = "proc txlResetting(): bool = resetBlocked\n"
    if "proc txlResetting(" in code:
        code = code.replace(procedure(code, "txlResetting"), gate, 1)
    else:
        code = code.replace("proc txlCaptureSession", gate + "proc txlCaptureSession", 1)
    return "var resetBlocked = false\n" + code


def host_source() -> str:
    code = reset_gate(build_program().split(LOWER_CHECKS, 1)[0])
    code = code.replace("  HostTxDescView = object\n",
                        "  HostTxDescView = object\n    cfmDst: pointer\n    active: uint32\n", 1)
    code = code.replace(procedure(code, "txl_payload_handle_backup"),
                        "proc txl_payload_handle_backup(p: pointer) = inc publications\n", 1)
    if "proc txlConfirmUnqueuedHost(" in code:
        code = code.replace(procedure(code, "txlConfirmUnqueuedHost"), "", 1)
    platform = r'''
type HeadThd = object
  flags: uint32
  confirmType: uint16
var
  heads: array[2, HeadThd]
  hostStatuses: array[2, uint32]
  hostPublished: seq[pointer]
  hostIndications: seq[uint32]
  onPublish: proc()
proc hostTxHeadThd(p: ptr Hardware): ptr HeadThd =
  for i in 0 .. 1:
    if p == addr hw[i]: return addr heads[i]
  doAssert false
proc hostTxThdConfirmAt(p: ptr HeadThd): ptr HeadThd = p
proc hostTxConfirmLinkWord(p: ptr HostTxDescView): ptr uint32 = addr p.active
proc txlInvalidateDmaFrame(p: pointer) = discard
proc ipc_emb_txcfm(p: pointer) =
  doAssert not interrupts
  hostPublished.add(p)
  if onPublish != nil: onPublish()
proc ipc_emb_txcfm_ind(mask: uint32) = hostIndications.add(mask)
'''
    tx = (FW / "tx_layer.nim").read_text()
    helper = procedure((FW / "tx_upper.nim").read_text(), "txu_cntrl_cfm")
    helper += procedure(tx, "txlConfirmUnqueuedHost")
    return code.replace("proc txuCancelFrame", platform + helper + "proc txuCancelFrame", 1)


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_host_rejection_bypasses_reset_queues(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, host_source() + r'''
for lower in [true, false]:
  for enabled in [false, true]:
    for ac in 0'u8 .. 4:
      reset()
      frames = default(typeof(frames))
      links = default(typeof(links))
      hw = default(typeof(hw))
      heads = default(typeof(heads))
      backup = default(typeof(backup))
      txEnv = default(TxEnv)
      frames[0] = HostTxDescView(vifIdx: 1, staInfoIdx: 0, staIdx: 0,
        hdrLen: 34, frameLen: 0x8E88, seqPassthrough: 100,
        hwDesc: addr hw[0], queueFirst: cast[pointer](1), policy: addr templateBytes,
        cfmDst: addr hostStatuses[0], active: 1)
      frames[0].bufferPtrs[0] = 0x20000000
      frames[0].bufferLens[0] = 100
      resetBlocked = true
      interrupts = enabled
      txEnv.packetCounter = 7
      publications = 0
      invalidated = false
      calls.setLen(0)
      hostPublished.setLen(0)
      hostIndications.setLen(0)
      onPublish = nil
      if lower: discard txl_cntrl_push(addr frames[0], ac)
      else: doAssert not txu_cntrl_push(addr frames[0], ac)
      doAssert interrupts == enabled
      doAssert hostPublished == @[cast[pointer](addr frames[0])]
      doAssert hostIndications == @[(1'u32 shl ac)]
      doAssert heads[0].flags == 0xC0020001'u32
      doAssert hostStatuses[0] == 0xC0020001'u32 and frames[0].active == 0
      doAssert heads[0].confirmType == 0x0101
      doAssert frames[0].staInfoIdx == 255 and frames[0].bufDesc == nil
      doAssert txEnv.packetCounter == 7 and publications == 0
      doAssert "drop-count" notin calls and "confirm" notin calls
      doAssert "security" notin calls and "rate" notin calls
      for i in 0 .. 4:
        doAssert backup[i].first == nil and txEnv.ac[i].pending.first == nil
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_standalone_buffer_is_not_published_during_reset(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, host_source() + r'''
reset()
resetBlocked = true
invalidated = false
frames[0] = HostTxDescView(vifIdx: 1, staInfoIdx: 0, staIdx: 0,
  hdrLen: 34, frameLen: 0x8E88, policy: addr templateBytes)
links = default(typeof(links))
backup = default(typeof(backup))
let before = links[0]
doAssert txl_buffer_alloc(addr frames[0], 2, 0) == nil
doAssert backup[2].first == nil and links[0] == before and interrupts
''')


def internal_source() -> str:
    tx = (FW / "tx_layer.nim").read_text()
    names = [
        "txl_frame_desc_index", "txlCaptureFrameIdentity", "txlFrameBeginLease",
        "txlFrameEndLease", "txlFrameLeaseToken", "txlFrameLeaseMatches",
        "txlFrameIdentityCurrent", "txlFrameSessionCurrent", "txlCaptureFrameCallback",
        "txlFrameCallbackCurrent", "txlInvokeFrameCallback", "txlStationAdmits",
        "txlCaptureSession", "txlSessionCurrent", "txl_frame_free_list_pop", "txl_frame_get",
        "txl_frame_release", "txl_cntrl_push_int", "txl_cntrl_push_int_force",
    ]
    fake = procedure((FW / "task_handlers.nim").read_text(), "txl_int_fake_transfer")
    functions = fake + "".join(procedure(tx, name) for name in names)
    debug = "\nvar\n" + "".join(
        f"  {name}: uint32\n" for name in sorted(set(re.findall(r"\bnimFwDbg\w+", functions)))
    )
    setup = INTERNAL_CHECKS.split("\nfor ac in 0 .. 4:", 1)[0]
    return reset_gate(platform_source() + debug + functions + setup)


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_internal_submission_is_rejected_during_reset(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, internal_source() + r'''
for force in [false, true]:
  for enabled in [false, true]:
    for ac in 0 .. 4:
      resetBlocked = false
      initialize(0, ac)
      watching = false
      resetBlocked = true
      interruptsEnabled = enabled
      let accepted = if force: txl_cntrl_push_int_force(held[0], ac.uint8)
                     else: txl_cntrl_push_int(held[0], ac.uint8)
      doAssert accepted == 0 and interruptsEnabled == enabled
      doAssert drainCalls == 0 and postponeCalls == 0
      doAssert txEnv.packetCounter == 0 and frameEnv.postponedCount == 0
      doAssert co_list_cnt(addr frameEnv.freeList) == 1
      for i in 0 .. 4:
        doAssert backups[i] == nil and acs[i].pending.first == nil
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_host_wrapper_can_be_reused_at_publication(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, host_source() + r'''
reset()
resetBlocked = true
txEnv.packetCounter = 3
frames[0] = HostTxDescView(staInfoIdx: 0, active: 1,
  hwDesc: addr hw[0], cfmDst: addr hostStatuses[0], bufDesc: cast[pointer](1))
onPublish = proc() =
  doAssert frames[0].active == 0 and frames[0].bufDesc == nil
  doAssert hostStatuses[0] == 0xC0020001'u32
  frames[0] = HostTxDescView(staInfoIdx: 2, active: 9, bufDesc: cast[pointer](0x1234))
  heads[0].flags = 0x12345678
txuCancelFrame(addr frames[0], 2)
doAssert frames[0].active == 9 and frames[0].staInfoIdx == 2
doAssert frames[0].bufDesc == cast[pointer](0x1234)
doAssert heads[0].flags == 0x12345678 and txEnv.packetCounter == 3
doAssert hostPublished == @[cast[pointer](addr frames[0])]
doAssert hostIndications == @[4'u32]
''')


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_reset_gate_follows_flag(tmp_path: Path, mode: str) -> None:
    tx = (FW / "tx_layer.nim").read_text()
    run_program(tmp_path, mode, r'''
var control: tuple[resetInProgress: uint8]
proc txControlEnv(): ptr typeof(control) = addr control
''' + procedure(tx, "txlResetting") + r'''
for value in [0'u8, 1, 2, 255, 0]:
  control.resetInProgress = value
  doAssert txlResetting() == (value != 0)
''')
