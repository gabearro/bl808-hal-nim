"""Run frame builders and submission wrappers across session/lease changes."""

from pathlib import Path
import re
import shutil
import subprocess

import pytest

from test_wifi_disconnect_tx import procedure
from test_wifi_frame_allocation import PLATFORM as ALLOCATION_PLATFORM

ROOT = Path(__file__).resolve().parents[1]
FW = ROOT / "src/bl808/wifi/fw"

PLATFORM = ALLOCATION_PLATFORM.replace(
    "    valid, instNbr: uint8", "    valid, instNbr: uint8\n    macAddr: array[6, uint8]"
).replace(
    "    confirmStatus: uint32",
    "    confirmStatus, secondaryTxHwDescPtr, secondaryDescToStatusPadding, ackPolicyControl: uint32",
).replace(
    "    prefix: array[5, uint32]", "    prefix: array[4, uint32]\n    policyWord: uint32"
)
PLATFORM = PLATFORM.replace(procedure(PLATFORM, "nimFwTrace2U32"), "")
PLATFORM += r"""
const NUM_TX_QUEUES = 5
type
  Vif = object
    vifIdx, vifType, state: uint8
    macAddr: array[6, uint8]
var
  vifs: array[2, Vif]
  retired: bool
  currentFrame: ptr HostTxDescView
  held: array[4, ptr HostTxDescView]
  replacement: ptr HostTxDescView
  replacementDesc: HostTxDescView
  replacementHw: HwDesc
  replacementLink: LinkDesc
  stage: string
  action, pushes, powers, warnings, kind: int
  fired: bool
  sequence: uint16
  pushed: seq[pointer]
proc observe(point: string)
proc txlStationAdmits(desc: ptr HostTxDescView): bool
proc txl_frame_release*(param: pointer; doCallback: bool) {.exportc, cdecl.}
proc vifChannelForIdx(index: uint8): ptr Vif =
  doAssert index < 2
  addr vifs[index]
proc vifChannelAt(p: pointer): ptr Vif = cast[ptr Vif](p)
proc txlVifIsRetiring(vif: uint8): bool = retired
proc hostTxDataHeader(d: ptr HostTxDescView): ptr MacDataFrameHeaderView =
  cast[ptr MacDataFrameHeaderView](addr hostTxLinkDescAt(d.bufDesc).macHeader[0])
proc hostTxQosDataHeader(d: ptr HostTxDescView): ptr MacQosDataFrameHeaderView =
  cast[ptr MacQosDataFrameHeaderView](hostTxDataHeader(d))
proc hostTxCtsHeader(d: ptr HostTxDescView): ptr MacCtsFrameHeaderView =
  cast[ptr MacCtsFrameHeaderView](hostTxDataHeader(d))
proc macDataFrameAt(p: pointer): ptr MacDataFrameHeaderView =
  for link in links.mitems:
    if pointerAddrU32(addr link.macHeader[0]) == pointerAddrU32(p):
      return cast[ptr MacDataFrameHeaderView](addr link.macHeader[0])
  doAssert false, "header pointer escaped the live pool"
proc hostTxRateTemplateAt(p: pointer): ptr RateTemplate = cast[ptr RateTemplate](p)
proc nextTxSeqCtrl(): uint16 =
  sequence += 16
  sequence
proc tpc_update_frame_tx_power(vif, p: pointer) =
  doAssert not interruptsEnabled
  currentFrame = hostTxDescAt(p)
  inc powers
  observe("power")
  if not fired or action != 3:
    # Exercise the wrapper's pointer-repair trace after builder preparation.
    hostTxHwDescAt(currentFrame.hwDesc).payloadStart = 0x12345678
proc nimFwTrace2U32(s: string; a, b: uint32) =
  if s == "[WIFI-NIMFW] frame_push_fix " or s == "[WIFI-NIMFW] frame_force_fix ":
    observe("trace")
proc assert_err(file, condition: cstring; line: int) = inc warnings
proc submit(p: pointer; ac: uint8): uint8 =
  doAssert not interruptsEnabled and ac == 3
  currentFrame = hostTxDescAt(p)
  doAssert txlStationAdmits(currentFrame)
  inc pushes
  pushed.add(p)
  observe("handoff")
  1
proc txl_cntrl_push_int(p: pointer; ac: uint8): uint8 = submit(p, ac)
proc txl_cntrl_push_int_force(p: pointer; ac: uint8): uint8 = submit(p, ac)
proc sta_mgmt_aging_postponed_desc(sta: pointer; maxCount: uint32): uint32 = 0
"""

CHECKS = r"""
proc replaceCurrent() =
  let d = currentFrame
  txl_frame_release(d, false)
  replacement = hostTxDescAt(txl_frame_get(26))
  doAssert replacement == d
  replacement.vifIdx = 0
  replacement.staInfoIdx = 0
  replacement.callback = cast[pointer](0x1234)
  replacement.callbackArg = cast[pointer](0x5678)
  replacement.pendingMacTime = 0x76543210
  for value in hostTxLinkDescAt(replacement.bufDesc).macHeader.mitems: value = 0xA7
  hostTxHwDescAt(replacement.hwDesc).controlFlags = 0xDEAD1234'u32
  replacementDesc = replacement[]
  replacementHw = hostTxHwDescAt(replacement.hwDesc)[]
  replacementLink = hostTxLinkDescAt(replacement.bufDesc)[]

proc observe(point: string) =
  if stage != point or fired: return
  doAssert not interruptsEnabled
  fired = true
  case action
  of 0: discard
  of 1: inc rxVifEpochs[1]
  of 2: inc stationEpochs[2]
  of 3: replaceCurrent()
  of 4: stas[2].valid = 0
  of 5: stas[2].instNbr = 0
  of 6: inc rxVifEpochs[0]
  else: retired = true

proc setup(irq: bool; allocatedCount: int) =
  initPool()
  retired = false
  fired = false
  stage = ""
  pushes = 0
  powers = 0
  warnings = 0
  pushed.setLen(0)
  replacement = nil
  currentFrame = nil
  sequence = 0x1000
  interruptsEnabled = irq
  for i in 0 .. 1:
    vifs[i] = Vif(vifIdx: i.uint8, vifType: 0, state: 1)
    for j in 0 .. 5: vifs[i].macAddr[j] = (0x20 + i * 16 + j).uint8
  for i in 0 ..< stas.len:
    stas[i].valid = 1
    stas[i].instNbr = 1
    for j in 0 .. 5: stas[i].macAddr[j] = (0x40 + i * 8 + j).uint8
  stas[0].instNbr = 0
  for i in 0 ..< allocatedCount:
    held[i] = hostTxDescAt(txl_frame_get(26))
    held[i].vifIdx = 1
    held[i].staInfoIdx = 2

proc build(): uint8 =
  case kind
  of 0: txl_frame_send_null_frame(2, cast[pointer](0xFACE), 0xDEADBEEF'u32)
  of 1: txl_frame_send_qosnull_frame(2, 0x8765, cast[pointer](0xFACE), 0xDEADBEEF'u32)
  else: txl_frame_send_selfcts_frame(addr vifs[1], 0x9876, cast[pointer](0xFACE), 0xDEADBEEF'u32)

proc verifyReplacement() =
  doAssert replacement != nil and replacement[] == replacementDesc
  doAssert hostTxHwDescAt(replacement.hwDesc)[] == replacementHw
  doAssert hostTxLinkDescAt(replacement.bufDesc)[] == replacementLink,
    "old preparation changed the replacement frame"
  doAssert co_list_cnt(addr frameEnv.freeList) == 0

for irq in [false, true]:
  for frameKind in 0 .. 2:
    kind = frameKind
    for trigger in ["power", "trace", "handoff"]:
      for change in 0 .. 7:
        setup(irq, 3)
        stage = trigger
        action = change
        let rc = build()
        doAssert fired and interruptsEnabled == irq
        let peerChange = change in [2, 4, 5] and frameKind != 2
        let invalidated = change in [1, 3, 7] or peerChange
        let shouldSubmit = trigger == "handoff" or not invalidated
        doAssert pushes == shouldSubmit.int
        doAssert rc == (if shouldSubmit: 0'u8 else: 1'u8)
        if change == 3:
          verifyReplacement()
        elif not shouldSubmit:
          doAssert co_list_cnt(addr frameEnv.freeList) == 1
        else:
          doAssert pushed == @[cast[pointer](currentFrame)]

    # Normal wire geometry and callbacks, including AP QoS direction.
    for ap in [false, true]:
      setup(irq, 3)
      vifs[1].vifType = if ap: 2 else: 0
      doAssert build() == 0 and pushes == 1 and interruptsEnabled == irq
      doAssert currentFrame.callback == cast[pointer](0xFACE)
      doAssert currentFrame.callbackArg == cast[pointer](0xDEADBEEF'u)
      doAssert currentFrame.vifIdx == 1
      if frameKind == 2:
        let header = hostTxCtsHeader(currentFrame)
        doAssert header.frameControl == 0xC4 and header.duration == 0x9876
        doAssert header.receiverAddr == vifs[1].macAddr
        doAssert currentFrame.staInfoIdx == 255
      else:
        let header = hostTxDataHeader(currentFrame)
        doAssert header.duration == 0 and header.addr1 == stas[2].macAddr
        doAssert header.addr2 == vifs[1].macAddr
        if frameKind == 0:
          doAssert header.frameControl == 0x148 and header.seqCtrl == 0x1010
          doAssert header.addr3 == stas[2].macAddr
        else:
          doAssert header.frameControl == (if ap: 0x2C8 else: 0x1C8)
          doAssert header.seqCtrl == 0 and hostTxQosDataHeader(currentFrame).qosCtrl == 0x8765
          doAssert header.addr3 == (if ap: vifs[1].macAddr else: stas[2].macAddr)

    # Allocation recovery may replace the session before returning a free slot.
    for change in [1, 2, 6]:
      setup(irq, 4)
      action = change
      onRecovery = proc() =
        stage = "recovery"
        observe("recovery")
        txl_frame_release(held[0], false)
      let rc = build()
      let invalidated = change == 1 or (change == 2 and frameKind != 2)
      doAssert fired and pushes == (not invalidated).int
      doAssert rc == invalidated.uint8 and interruptsEnabled == irq

  # Submission wrappers validate before touching malformed descriptor resources.
  for forced in [false, true]:
    for change in [1, 2, 3, 6]:
      setup(irq, 4)
      currentFrame = held[0]
      hostTxDataHeader(currentFrame).frameControl = 0x148
      hostTxHwDescAt(currentFrame.hwDesc).payloadStart = 0x12345678
      stage = "trace"
      action = change
      if forced: txl_frame_push_force(currentFrame, 3)
      else: doAssert txl_frame_push(currentFrame, 3) == (change == 6).uint8
      doAssert fired and pushes == (change == 6).int and interruptsEnabled == irq
      if change == 3: verifyReplacement()
    for change in [1, 2]:
      setup(irq, 4)
      var foreign = HostTxDescView(bufDesc: held[0].bufDesc, hwDesc: held[0].hwDesc,
        vifIdx: 1, staInfoIdx: 2, usedFlag: 1)
      currentFrame = addr foreign
      hostTxHwDescAt(foreign.hwDesc).payloadStart = 0x12345678
      stage = "trace"
      action = change
      if forced: txl_frame_push_force(addr foreign, 3)
      else: doAssert txl_frame_push(addr foreign, 3) == 0
      doAssert fired and pushes == 0 and interruptsEnabled == irq
      doAssert co_list_cnt(addr frameEnv.freeList) == 0
    for invalid in 0 .. 5:
      setup(irq, 4)
      currentFrame = held[0]
      case invalid
      of 0: currentFrame.bufDesc = nil
      of 1: currentFrame.hwDesc = nil
      of 2: currentFrame.vifIdx = 255
      of 3: currentFrame.staInfoIdx = 7
      of 4: stas[2].valid = 0
      else: retired = true
      if forced: txl_frame_push_force(currentFrame, 3)
      else: doAssert txl_frame_push(currentFrame, 3) == 0
      doAssert pushes == 0 and interruptsEnabled == irq
      doAssert co_list_cnt(addr frameEnv.freeList) == 1
    for ac in [5'u8, 255]:
      setup(irq, 4)
      if forced: txl_frame_push_force(held[0], ac)
      else: doAssert txl_frame_push(held[0], ac) == 0
      doAssert pushes == 0 and co_list_cnt(addr frameEnv.freeList) == 1

  setup(irq, 0)
  doAssert txl_frame_send_null_frame(255, nil, 0) == 1
  doAssert txl_frame_send_qosnull_frame(7, 0, nil, 0) == 1
  stas[2].instNbr = 255
  doAssert txl_frame_send_null_frame(2, nil, 0) == 1
  doAssert txl_frame_send_qosnull_frame(2, 0, nil, 0) == 1
  doAssert txl_frame_send_selfcts_frame(nil, 0, nil, 0) == 1
  vifs[1].vifIdx = 255
  doAssert txl_frame_send_selfcts_frame(addr vifs[1], 0, nil, 0) == 1
  doAssert pushes == 0 and co_list_cnt(addr frameEnv.freeList) == 4
"""


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("mutation", [None, "lease", "session", "admission", "power", "post_handoff", "trace", "bounds"])
def test_frame_preparation(tmp_path: Path, mode: str, mutation: str | None) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("Nim is required")
    tx = (FW / "tx_layer.nim").read_text()
    functions = "".join(procedure(tx, name) for name in [
        "txl_frame_desc_index", "txlCaptureFrameIdentity", "txlFrameBeginLease", "txlFrameEndLease",
        "txlFrameLeaseToken", "txlFrameLeaseMatches", "txlFrameIdentityCurrent", "txlFrameSessionCurrent",
        "txlCaptureFrameCallback", "txlFrameCallbackCurrent", "txlInvokeFrameCallback",
        "txlCaptureSession", "txlSessionCurrent", "txlStationAdmits", "txlFramePreparationCurrent",
        "txl_frame_free_list_pop", "txl_frame_get", "txl_frame_release",
        "txl_frame_push", "txl_frame_try_push_force", "txl_frame_push_force", "txl_frame_send_null_frame",
        "txl_frame_send_qosnull_frame", "txl_frame_send_selfcts_frame",
    ])
    if mutation == "lease":
        functions = functions.replace("desc == nil or not txlFrameLeaseMatches(desc, generation)", "desc == nil")
    elif mutation == "session":
        functions = functions.replace("not txlSessionCurrent(identity, desc) or ", "")
    elif mutation == "admission":
        functions = functions.replace("not txlStationAdmits(desc) or\n      ", "")
    elif mutation == "power":
        for vif in ["vifEntry", "vifInfo"]:
            old = f"  tpc_update_frame_tx_power({vif}, frame)\n  if not txlFramePreparationCurrent(desc, identity, generation):\n    return 1\n"
            functions = functions.replace(old, f"  tpc_update_frame_tx_power({vif}, frame)\n")
    elif mutation == "post_handoff":
        functions = functions.replace("  nimFwDbgNullFrameReturn = publicRc.uint32\n",
            "  nimFwDbgNullFrameReturn = publicRc.uint32\n  desc.pendingMacTime = 0\n")
    elif mutation == "trace":
        functions = functions.replace("      if not txlFramePreparationCurrent(desc, identity, generation):\n        return 0\n", "").replace(
            "      if not txlFramePreparationCurrent(desc, identity, generation):\n        return\n", "")
    elif mutation == "bounds":
        functions = functions.replace("  if ac >= NUM_TX_QUEUES.uint8:\n    txl_frame_release(desc, false)\n    return 0\n", "").replace(
            "  if ac >= NUM_TX_QUEUES.uint8:\n    txl_frame_release(desc, false)\n    return\n", "")
    layout = (FW / "layout_types.nim").read_text()
    types = "type\n"
    for name in ["TxSessionIdentity", "MacDataFrameHeaderView", "MacQosDataFrameHeaderView", "MacCtsFrameHeaderView"]:
        types += "  " + name + layout.split("  " + name, 1)[1].split("\n\n  ", 1)[0] + "\n"
    debug = "\nvar\n" + "".join(f"  {name}: uint32\n" for name in sorted(set(re.findall(r"\bnimFwDbg\w+", functions))))
    # Header types are needed by platform accessors; session identity is a value type.
    split = PLATFORM.index("const NUM_TX_QUEUES")
    source = tmp_path / "frame_preparation.nim"
    source.write_text(PLATFORM[:split] + types + PLATFORM[split:] + debug + functions + CHECKS)
    flags = {"checked": [], "release": ["-d:release", "--assertions:on"],
             "asan": ["--cc:clang", "--passC:-fsanitize=address", "--passL:-fsanitize=address"]}
    result = subprocess.run([nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on", "--skipUserCfg:on",
        f"--nimcache:{tmp_path / 'cache'}", f"-o:{tmp_path / 'test'}", *flags[mode], str(source)],
        cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=120)
    if mutation is None:
        assert result.returncode == 0, result.stdout
    else:
        assert result.returncode != 0 and "AssertionDefect" in result.stdout, result.stdout
