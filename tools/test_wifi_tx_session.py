"""Keep caller-held internal frames bound to their allocation-time session."""

from pathlib import Path
import re
import shutil
import subprocess

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_frame_allocation import PLATFORM as ALLOCATION_PLATFORM

ROOT = Path(__file__).resolve().parents[1]

PLATFORM = ALLOCATION_PLATFORM + r"""
const NUM_TX_QUEUES = 5
type StaInfoView = Sta
var
  txEnv: tuple[packetCounter: uint32]
  transfers, callbacks: int
  statuses: seq[uint32]
  replacement: pointer
  callbackMode: int
proc txControlEnv(): ptr typeof(txEnv) = addr txEnv
proc txlHaltVifQueues(vif: uint8; selected: var uint8): bool = true
proc txl_retire_vif(vif: uint8; selected: uint8) = discard
proc txlVifIsRetiring(vif: uint8): bool = false
proc txl_int_fake_transfer(p: pointer; ac: uint32) = inc transfers
proc txl_payload_handle_backup(p: pointer) = discard
proc ke_evt_clear(bits: uint32) = discard
proc ke_evt_set(bits: uint32) = discard
proc nimFwMgmtFcTrace(fc: uint8): bool = false
proc noteMgmtTxConfirm(d: ptr HostTxDescView; status, phase: uint32) = discard
proc setup() =
  initPool()
  txEnv.packetCounter = 0
  transfers = 0
  callbacks = 0
  statuses.setLen(0)
  replacement = nil
  callbackMode = 0
  for i in 0 ..< stas.len:
    stas[i].valid = 1
    stas[i].instNbr = (i mod 2).uint8
proc sta_mgmt_aging_postponed_desc(sta: pointer; maxCount: uint32): uint32 = 0
"""

CHECKS = r"""
proc allocated(station, vif: uint8): ptr HostTxDescView =
  result = hostTxDescAt(txl_frame_get(24))
  doAssert result != nil
  result.staInfoIdx = station
  result.vifIdx = vif

proc completion(arg: pointer; status: uint32) {.cdecl.} =
  inc callbacks
  statuses.add(status)
  let frame = hostTxDescAt(arg)
  if callbackMode == 1:
    txl_frame_release(frame, false)
    replacement = txl_frame_get(24)
    doAssert replacement == arg
  elif callbackMode == 2:
    if callbacks == 1:
      frame.retryFlag = 1
      inc txEnv.packetCounter
      co_list_push_back(addr frameEnv.usedList, addr frame.link)

# Unbound management TX and associated TX both carry VIF identity. Reusing
# a station slot on the same VIF must also invalidate its caller-held frames.
for vif in 0'u8 .. 1:
  for station in [255'u8, vif, 5'u8]:
    for change in 0 .. 3:
      setup()
      if station == 5: stas[station].instNbr = vif
      let frame = allocated(station, vif)
      case change
      of 0: discard
      of 1: discard rxInvalidateVif(vif)
      of 2: discard rxInvalidateVif(vif xor 1)
      else:
        if station < 5: inc stationEpochs[station]
      let valid = change != 1 and not (change == 3 and station < 5)
      doAssert txlStationAdmits(frame) == valid
      doAssert (txl_cntrl_push_int_force(frame, 3) != 0) == valid
      doAssert transfers == valid.int
      doAssert txEnv.packetCounter == valid.uint32

# Capture happens before allocator recovery invokes callbacks, not when it
# eventually obtains a descriptor from the callback's freed slot.
for changeStation in [false, true]:
  setup()
  var held: array[4, ptr HostTxDescView]
  for i in 0 ..< 4: held[i] = allocated(0, 0)
  onRecovery = proc() =
    if changeStation: inc stationEpochs[0]
    else: discard rxInvalidateVif(0)
    txl_frame_release(held[0], false)
  let recovered = allocated(0, 0)
  doAssert recovered == held[0]
  doAssert not txlStationAdmits(recovered)
  doAssert txl_cntrl_push_int_force(recovered, 0) == 0
  doAssert transfers == 0 and txEnv.packetCounter == 0

# A late ACK must not advance callbacks belonging to an earlier session.
for invalidated in [false, true]:
  setup()
  let frame = allocated(255, 0)
  frame.callback = cast[pointer](completion)
  frame.callbackArg = frame
  hostTxHwDescAt(frame.hwDesc).confirmStatus = 0x80800000'u32
  if invalidated: discard rxInvalidateVif(0)
  txEnv.packetCounter = 1
  co_list_push_back(addr frameEnv.usedList, addr frame.link)
  txl_frame_evt()
  doAssert statuses == @[(if invalidated: 0x40000000'u32 else: 0x80800000'u32)]
  doAssert txEnv.packetCounter == 0 and co_list_cnt(addr frameEnv.freeList) == 4

# The old completion must not free a new lease of the same physical slot.
setup()
var held: array[4, ptr HostTxDescView]
for i in 0 ..< 4: held[i] = allocated(0, 0)
held[0].callback = cast[pointer](completion)
held[0].callbackArg = held[0]
callbackMode = 1
txEnv.packetCounter = 1
co_list_push_back(addr frameEnv.usedList, addr held[0].link)
txl_frame_evt()
doAssert callbacks == 1 and replacement == cast[pointer](held[0])
doAssert frameEnv.freeList.first == nil and txlStationAdmits(held[0])
doAssert txl_frame_get(24) == nil

# A legal retry stays in the same lease and is freed exactly once afterward.
setup()
let retried = allocated(0, 0)
retried.callback = cast[pointer](completion)
retried.callbackArg = retried
callbackMode = 2
txEnv.packetCounter = 1
co_list_push_back(addr frameEnv.usedList, addr retried.link)
txl_frame_evt()
doAssert callbacks == 2 and co_list_cnt(addr frameEnv.freeList) == 4
doAssert txEnv.packetCounter == 0 and retried.retryFlag == 0
"""


@pytest.mark.parametrize("release", [False, True])
@pytest.mark.parametrize("mutation", [None, "admission", "late_capture", "completion", "lease"])
def test_internal_tx_session_identity(tmp_path: Path, release: bool, mutation: str | None) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("Nim is required")
    tx = (FW / "tx_layer.nim").read_text()
    functions = "".join(procedure(tx, name) for name in [
        "txl_frame_desc_index", "txlCaptureFrameIdentity", "txlFrameBeginLease",
        "txlFrameEndLease", "txlFrameLeaseToken", "txlFrameLeaseMatches",
        "txlFrameIdentityCurrent", "txlFrameSessionCurrent",
        "txlCaptureFrameCallback", "txlFrameCallbackCurrent", "txlInvokeFrameCallback",
        "txlStationAdmits", "txl_frame_free_list_pop",
        "txl_frame_get", "txl_frame_release", "txlFrameConfirmPending",
        "txl_frame_evt", "txl_cntrl_push_int_force",
    ])
    functions += procedure((FW / "rx_layer.nim").read_text(), "rxInvalidateQuiescentVif")
    functions += procedure((FW / "rx_layer.nim").read_text(), "rxInvalidateVif")
    if mutation == "admission":
        old = "  if txlVifIsRetiring(desc.vifIdx) or not txlFrameSessionCurrent(desc):\n    return false\n"
        assert functions.count(old) == 1
        functions = functions.replace(old, "")
    elif mutation == "late_capture":
        old = "  let identity = txlCaptureFrameIdentity()\n"
        assert functions.count(old) == 1
        functions = functions.replace(old, "").replace(
            "    txlFrameBeginLease(desc, identity)",
            "    let identity = txlCaptureFrameIdentity()\n    txlFrameBeginLease(desc, identity)",
        )
    elif mutation == "completion":
        old = "    if not txlFrameSessionCurrent(desc) and desc.hwDesc != nil:"
        assert functions.count(old) == 1
        functions = functions.replace(old, "    if false:")
    elif mutation == "lease":
        old = "      if callbackPtr == nil or txlFrameLeaseMatches(desc, generation):\n"
        assert functions.count(old) == 1
        functions = functions.replace(old, "      if true:\n")
    debug = "\nvar\n" + "".join(
        f"  {name}: uint32\n"
        for name in sorted(set(re.findall(r"\bnimFwDbg\w+", functions)))
    )
    source = tmp_path / "tx_session.nim"
    source.write_text(PLATFORM + debug + functions + CHECKS)
    command = [nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on", "--skipUserCfg:on"]
    if release:
        command += ["-d:release"]
    command += ["--checks:on", f"--nimcache:{tmp_path / 'nimcache'}",
                f"-o:{tmp_path / 'test'}", str(source)]
    result = subprocess.run(command, cwd=ROOT, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT)
    if mutation is None:
        assert result.returncode == 0, result.stdout
    else:
        assert result.returncode != 0 and "AssertionDefect" in result.stdout, result.stdout
