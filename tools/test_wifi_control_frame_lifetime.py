"""Verify PS-Poll and Block Ack frame construction with real frame leases."""

from pathlib import Path
import re
import shutil
import subprocess

import pytest

from test_wifi_disconnect_tx import procedure
from test_wifi_frame_preparation import PLATFORM as FRAME_PLATFORM

ROOT = Path(__file__).resolve().parents[1]
FW = ROOT / "src/bl808/wifi/fw"

PLATFORM = FRAME_PLATFORM.replace(
    "vifIdx, vifType, state: uint8", "vifIdx, vifType, state, staIdx: uint8"
).replace(
    "valid, instNbr: uint8", "valid, instNbr, infoIdx: uint8\n    aid: uint16"
).replace(
    "vifIdx, staInfoIdx: uint8", "vifIdx, staInfoIdx, hdrLen, secTailLen: uint8"
)
PLATFORM += r"""
const VIF_TYPE_AP = 2'u8
var
  protection: bool
  headerExtra, trailerExtra: uint8
  returnedBodyLength: uint32
  bodyCalls: int
proc hostTxPsPollHeader(desc: ptr HostTxDescView): ptr PsPollFrameHeaderView =
  cast[ptr PsPollFrameHeaderView](hostTxDataHeader(desc))
proc addBaRspActionBodyAt(p: pointer): ptr AddBaRspActionBodyView =
  cast[ptr AddBaRspActionBodyView](p)
proc mfp_protect_mgmt_frame(frame: pointer; fc, category: uint32): uint32 =
  doAssert fc == 0xD0 and category == 3
  currentFrame = hostTxDescAt(frame)
  observe("mfp")
  protection.uint32
proc txu_cntrl_protect_mgmt_frame(frame, header: pointer; length: uint32) =
  doAssert length == 24
  let desc = hostTxDescAt(frame)
  desc.hdrLen = headerExtra
  desc.secTailLen = trailerExtra
  cast[ptr MacDataFrameHeaderView](header).frameControl = 0x40D0
  observe("protect")
proc buildBaBody(buf, unused: pointer; baParams: uint16;
                  dialogToken: uint8; statusCode: uint16): uint32 {.cdecl.}
proc me_build_add_ba_rsp(buf, context: pointer; baParams: uint16;
                       dialogToken: uint8; statusCode: uint16): uint32 =
  discard buildBaBody(buf, context, baParams, dialogToken, statusCode)
  inc bodyCalls
  observe("body")
  returnedBodyLength
"""

CHECKS = r"""
var
  context: uint32
  isBa: bool

proc replaceCurrent() =
  let desc = currentFrame
  txl_frame_release(desc, false)
  replacement = hostTxDescAt(txl_frame_get(24))
  doAssert replacement == desc
  replacement.vifIdx = 0
  replacement.staInfoIdx = 0
  replacement.pendingMacTime = 0xAABBCCDD'u32
  replacement.callback = cast[pointer](0x1234)
  replacement.callbackArg = cast[pointer](0x5678)
  for value in hostTxLinkDescAt(replacement.bufDesc).macHeader.mitems: value = 0xB7
  hostTxHwDescAt(replacement.hwDesc).frameLen = 17
  replacementDesc = replacement[]
  replacementHw = hostTxHwDescAt(replacement.hwDesc)[]
  replacementLink = hostTxLinkDescAt(replacement.bufDesc)[]

proc observe(point: string) =
  if point != stage or fired: return
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

proc setup(irq: bool; allocatedCount = 3) =
  stage = ""
  initPool()
  retired = false
  fired = false
  pushes = 0
  powers = 0
  warnings = 0
  bodyCalls = 0
  pushed.setLen(0)
  currentFrame = nil
  replacement = nil
  protection = true
  headerExtra = 8
  trailerExtra = 8
  returnedBodyLength = 9
  interruptsEnabled = irq
  for i in 0 .. 1:
    vifs[i] = Vif(vifIdx: i.uint8, vifType: 0, staIdx: 2, state: 1)
    for j in 0 .. 5: vifs[i].macAddr[j] = (0x20 + i * 16 + j).uint8
  for i in 0 ..< stas.len:
    stas[i].valid = 1
    stas[i].instNbr = 1
    stas[i].infoIdx = i.uint8
    stas[i].aid = (100 + i).uint16
    for j in 0 .. 5: stas[i].macAddr[j] = (0x40 + i * 8 + j).uint8
  stas[0].instNbr = 0
  for i in 0 ..< allocatedCount:
    held[i] = hostTxDescAt(txl_frame_get(24))
    held[i].vifIdx = 1
    held[i].staInfoIdx = 2

proc build(): uint8 =
  if isBa:
    bam_send_air_action_frame(2, addr context, 1, 0xAF, 0x1234, 0xFEDC,
                             cast[pointer](0xFACE))
    return (pushes == 0).uint8
  ps_send_pspoll(addr vifs[1])

for irq in [false, true]:
  for ba in [false, true]:
    isBa = ba
    let points = if ba: @["power", "mfp", "protect", "body", "trace", "handoff"]
                 else: @["power", "trace", "handoff"]
    for point in points:
      for change in 0 .. 7:
        setup(irq)
        stage = point
        action = change
        let rc = build()
        doAssert fired and interruptsEnabled == irq
        let valid = change in [0, 6] or point == "handoff"
        doAssert pushes == valid.int and rc == (not valid).uint8
        if change == 3:
          doAssert replacement != nil and replacement[] == replacementDesc
          doAssert hostTxHwDescAt(replacement.hwDesc)[] == replacementHw
          doAssert hostTxLinkDescAt(replacement.bufDesc)[] == replacementLink
          doAssert frameEnv.freeList.first == nil
        elif not valid:
          doAssert co_list_cnt(addr frameEnv.freeList) == 1

    for change in [1, 2, 6]:
      setup(irq, 4)
      action = change
      onRecovery = proc() =
        stage = "recovery"
        observe("recovery")
        txl_frame_release(held[0], false)
      doAssert build() == (change != 6).uint8
      doAssert pushes == (change == 6).int and interruptsEnabled == irq

  # PS-Poll byte layout and descriptor routing exactly match the vendor.
  isBa = false
  for aid in [1'u16, 42, 2007]:
    setup(irq)
    stas[2].aid = aid
    doAssert build() == 0
    let header = hostTxPsPollHeader(currentFrame)
    doAssert header.frameControl == 0xA4 and header.aid == (aid or 0xC000)
    doAssert header.bssid == stas[2].macAddr and header.transmitterAddr == vifs[1].macAddr
    doAssert hardware[3].frameLen == 20 and hardware[3].ackPolicyControl == 0
    doAssert (hardware[3].controlFlags and 0x10000053'u32) == 0x10000053'u32
    doAssert currentFrame.vifIdx == 1 and currentFrame.staInfoIdx == 2

  # Protected/unprotected BA bodies retain the exact fields and bounded length.
  isBa = true
  for ap in [false, true]:
    for protected in [false, true]:
      setup(irq)
      protection = protected
      vifs[1].vifType = if ap: 2 else: 0
      doAssert build() == 0
      let offset = if protected: 32 else: 24
      let header = hostTxDataHeader(currentFrame)
      doAssert header.frameControl == (if protected: 0x40D0 else: 0xD0)
      doAssert header.addr1 == stas[2].macAddr and header.addr2 == vifs[1].macAddr
      doAssert header.addr3 == (if ap: vifs[1].macAddr else: stas[2].macAddr)
      let body = addBaRspActionBodyAt(addr links[3].macHeader[offset])
      doAssert body.category == 3 and body.action == 1 and body.dialogToken == 0xAF
      doAssert body.baParams == 0x1234 and body.statusCode == 0xFEDC and body.timeout == 0
      doAssert hardware[3].frameLen == (offset + 9 + (if protected: 8 else: 0) + 4).uint32
      doAssert currentFrame.callback == cast[pointer](0xFACE)
      doAssert currentFrame.callbackArg == cast[pointer](addr context)

  for oversizedBody in [false, true]:
    setup(irq)
    if oversizedBody: returnedBodyLength = high(uint32)
    else:
      headerExtra = 255
      trailerExtra = 255
    doAssert build() == 1 and pushes == 0
    doAssert co_list_cnt(addr frameEnv.freeList) == 1

  for invalid in [(0'u8, 0'u8), (4'u8, 4'u8), (8'u8, 0'u8),
                  (8'u8, 12'u8), (0'u8, 8'u8), (255'u8, 8'u8)]:
    setup(irq)
    headerExtra = invalid[0]
    trailerExtra = invalid[1]
    doAssert build() == 1 and pushes == 0,
      "Block Ack submitted a frame without complete CCMP protection"
    doAssert bodyCalls == 0 and co_list_cnt(addr frameEnv.freeList) == 1
    doAssert interruptsEnabled == irq

  setup(irq)
  doAssert ps_send_pspoll(nil) == 1
  vifs[1].staIdx = 255
  doAssert ps_send_pspoll(addr vifs[1]) == 1
  vifs[1].vifIdx = 255
  doAssert ps_send_pspoll(addr vifs[1]) == 1
  bam_send_air_action_frame(255, nil, 1, 0, 0, 0, nil)
  bam_send_air_action_frame(2, nil, 0, 0, 0, 0, nil)
  doAssert pushes == 0 and interruptsEnabled == irq
"""


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("mutation", [None, "power", "mfp", "protect", "body", "length", "binding", "handoff"])
def test_control_frame_lifetime(tmp_path: Path, mode: str, mutation: str | None) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("Nim is required")
    tx = (FW / "tx_layer.nim").read_text()
    functions = "".join(procedure(tx, name) for name in [
        "txl_frame_desc_index", "txlCaptureFrameIdentity", "txlFrameBeginLease", "txlFrameEndLease",
        "txlFrameLeaseToken", "txlFrameLeaseMatches", "txlFrameIdentityCurrent", "txlFrameSessionCurrent",
        "txlCaptureFrameCallback", "txlFrameCallbackCurrent", "txlInvokeFrameCallback",
        "txlCaptureSession", "txlSessionCurrent", "txlStationAdmits", "txlFramePreparationCurrent",
        "txl_frame_free_list_pop", "txl_frame_get", "txl_frame_release", "txl_frame_push",
    ])
    management = (FW / "scan_station_ap_me.nim").read_text()
    functions += procedure(management, "me_build_add_ba_rsp").replace(
        "proc me_build_add_ba_rsp*", "proc buildBaBody").replace(
        "{.exportc, cdecl, noinline.}", "")
    ps = procedure((FW / "power_save.nim").read_text(), "ps_send_pspoll")
    ba = procedure((FW / "block_ack.nim").read_text(), "bam_send_air_action_frame")
    if mutation == "power":
        ps = ps.replace("  if not txlFramePreparationCurrent(desc, identity, generation):\n    return 1\n  let hdr", "  let hdr")
        ba = ba.replace("  if not txlFramePreparationCurrent(desc, identity, generation):\n    return\n\n  # The MAC", "\n  # The MAC")
    elif mutation == "mfp":
        ba = ba.replace("  if not txlFramePreparationCurrent(desc, identity, generation):\n    return\n  if mfpResult", "  if mfpResult")
    elif mutation == "protect":
        ba = ba.replace("    if not txlFramePreparationCurrent(desc, identity, generation):\n      return\n", "")
    elif mutation == "body":
        ba = ba.replace("  if not txlFramePreparationCurrent(desc, identity, generation):\n    return\n\n  # Compute", "\n  # Compute")
    elif mutation == "length":
        ba = ba.replace("  if bodyLen > TxlFramePayloadSize - hdrLen or\n      extraPad > TxlFramePayloadSize - hdrLen - bodyLen:", "  if false:")
    elif mutation == "binding":
        ps = ps.replace("  desc.vifIdx = vifIdx\n  desc.staInfoIdx = staIdx\n", "")
        ba = ba.replace("  desc.staInfoIdx = staIdx\n  desc.vifIdx = vifIdx\n", "", 1)
    elif mutation == "handoff":
        ps = ps.replace("  return (pushRc xor 1'u8)", "  desc.pendingMacTime = 0\n  return (pushRc xor 1'u8)")
        ba += "  desc.pendingMacTime = 0\n"
    functions += ps + ba
    layout = (FW / "layout_types.nim").read_text()
    types = "type\n"
    for name in ["TxSessionIdentity", "MacDataFrameHeaderView", "MacQosDataFrameHeaderView",
                 "MacCtsFrameHeaderView", "PsPollFrameHeaderView", "AddBaRspActionBodyView"]:
        types += "  " + name + layout.split("  " + name, 1)[1].split("\n\n  ", 1)[0] + "\n"
    debug = "\nvar\n" + "".join(f"  {name}: uint32\n" for name in sorted(set(re.findall(r"\bnimFwDbg\w+", functions))))
    split = PLATFORM.index("const NUM_TX_QUEUES")
    source = tmp_path / "control_frames.nim"
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
