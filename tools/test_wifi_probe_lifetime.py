"""Exercise complete probe construction, the dwell stamp, and private IE DMA."""

from pathlib import Path
import os
import re
import shutil
import subprocess

import pytest

from test_wifi_disconnect_tx import procedure
from test_wifi_frame_preparation import PLATFORM as FRAME_PLATFORM

ROOT = Path(__file__).resolve().parents[1]
FW = ROOT / "src/bl808/wifi/fw"


def platform_source() -> str:
    source = FRAME_PLATFORM.replace("  retired: bool", "  retired, rejectPush: bool\n  pushResultOverride: uint8")
    source = source.replace("proc txl_cntrl_push_int(p: pointer; ac: uint8): uint8 = submit(p, ac)", r"""
proc txl_cntrl_push_int(p: pointer; ac: uint8): uint8 =
  if rejectPush:
    txl_frame_release(p, false)
    return 0
  let status = submit(p, ac)
  if pushResultOverride != 0: pushResultOverride else: status
""")
    source = source.replace(procedure(source, "nimFwTrace2U32"), r"""
proc nimFwTrace2U32(s: string; a, b: uint32) =
  if s == "[WIFI-SCAN] probe_tx ": observe("trace1")
  elif s == "[WIFI-SCAN] probe_fc ": observe("trace2")
""")
    return source + r"""
const
  IE_ID_SSID = 0'u8
  TASK_SCAN = 1'u8
  SCAN_DONE_IND = 0x402'u16
  ScanIdleState = 0'u16
  ScanChannelRunningState = 3'u16
type
  ScanEnv = object
    paramPtr: pointer
    channelIndex, requester, abortFlag: uint8
  ProbeIeStorage = object
    magic: uint32
    ieData: array[200, uint8]
var
  scan_env: ScanEnv
  scan_probe_req_ie: ProbeIeStorage
  request, otherRequest: ScanStartReqPayload
  freeCalls: int
  doneSends: int
  doneDest: uint8
  scanTaskState: uint16
  freeHook, sendHook: proc()
proc scanStartReqView(p: pointer): ptr ScanStartReqPayload = cast[ptr ScanStartReqPayload](p)
proc scanSsidSlot(req: ptr ScanStartReqPayload; index: int): ptr ScanSsidSlotView =
  cast[ptr ScanSsidSlotView](addr req.ssidFilter[index * 34])
proc hostTxProbeReqFrame(link: ptr LinkDesc): ptr ProbeReqFrameView =
  cast[ptr ProbeReqFrameView](addr link.macHeader[0])
proc ke_state_get(task: uint8): uint16 =
  doAssert task == TASK_SCAN
  scanTaskState
proc ke_state_set(task: uint8; state: uint16) =
  doAssert task == TASK_SCAN
  scanTaskState = state
"""


CHECKS = r"""
proc newDwell(p: pointer; requester: uint8) =
  ## TASK_SCAN admits `p` (same or another address) and starts its dwell.
  cacheScanStartContext(p, requester)
  discard opGo(scanOwn.op)

proc replaceCurrent() =
  let desc = currentFrame
  txl_frame_release(desc, false)
  replacement = hostTxDescAt(txl_frame_get(26))
  doAssert replacement == desc
  replacement.vifIdx = 0
  replacement.staInfoIdx = 0
  replacement.pendingMacTime = 0x12345678
  replacement.callback = cast[pointer](0x1122)
  hostTxHwDescAt(replacement.hwDesc).frameLen = 99
  for byte in hostTxLinkDescAt(replacement.bufDesc).macHeader.mitems: byte = 0xBE
  replacementDesc = replacement[]
  replacementHw = hostTxHwDescAt(replacement.hwDesc)[]
  replacementLink = hostTxLinkDescAt(replacement.bufDesc)[]

proc observe(point: string) =
  if point != stage or fired: return
  fired = true
  doAssert not interruptsEnabled
  case action
  of 0: discard
  of 1: inc rxVifEpochs[1]
  of 2: replaceCurrent()
  of 3: newDwell(addr request, 7) # Same address, new request.
  of 4: newDwell(addr otherRequest, 7)
  of 5: scan_env.abortFlag = 1
  of 6:
    for byte in scan_probe_req_ie.ieData.mitems: byte = 0xCE
  of 7: inc rxVifEpochs[0]
  of 9: inc scan_env.channelIndex
  else: retired = true

proc setup(irq: bool; count: int = 3) =
  stage = ""
  fired = false
  retired = false
  rejectPush = false
  pushResultOverride = 0
  onRecovery = nil
  interruptsEnabled = true
  initPool()
  replacement = nil
  pushes = 0
  scanTaskState = ScanChannelRunningState
  pushed.setLen(0)
  sequence = 0x120
  request = default(ScanStartReqPayload)
  request.vifIdx = 1
  request.scanType = 1
  request.ieBodyLen = 31
  request.localMac = [2'u8, 3, 4, 5, 6, 7]
  request.bssid = [0x10'u8, 0x20, 0x30, 0x40, 0x50, 0x60]
  let ssid = scanSsidSlot(addr request, 0)
  ssid.length = 5
  for i in 0 ..< ssid.ssidBytes.len: ssid.ssidBytes[i] = (i + 0x41).uint8
  scan_env = default(ScanEnv)
  newDwell(addr request, 2)
  for i in 0 ..< scan_probe_req_ie.ieData.len:
    scan_probe_req_ie.ieData[i] = (i xor 0xA5).uint8
  for i in 0 .. 1: vifs[i] = Vif(vifIdx: i.uint8, state: 1)
  for i in 0 ..< count:
    held[i] = hostTxDescAt(txl_frame_get(24))
    held[i].vifIdx = 0
    held[i].staInfoIdx = 0xFF
  currentFrame = txlFrameDescAt(count.uint32 mod 4)
  interruptsEnabled = irq

proc checkFrame(desc: ptr HostTxDescView; ssidLen, ieLen: int) =
  let hw = hostTxHwDescAt(desc.hwDesc)
  let link = hostTxLinkDescAt(desc.bufDesc)
  let probe = hostTxProbeReqFrame(link)
  doAssert desc.vifIdx == 1 and desc.staInfoIdx == 0xFF
  doAssert desc.callback == nil and desc.callbackArg == nil
  doAssert probe.fixed.frameControl == 0x40 and probe.fixed.duration == 0
  doAssert probe.fixed.addr1 == [0x10'u8, 0x20, 0x30, 0x40, 0x50, 0x60]
  doAssert probe.fixed.addr2 == [2'u8, 3, 4, 5, 6, 7]
  doAssert probe.fixed.addr3 == probe.fixed.addr1
  doAssert probe.fixed.seqCtrl == 0x130
  doAssert probe.fixed.ssidIeId == 0 and probe.fixed.ssidLen == ssidLen.uint8
  let total = 26 + ssidLen + ieLen
  doAssert hw.payloadStart == pointerAddrU32(addr link.macHeader[0])
  doAssert hw.payloadEnd == hw.payloadStart + total.uint32 - 1
  doAssert hw.frameLen == total.uint32 + 4 and hw.status == 0
  for i in 0 ..< ssidLen: doAssert probe.ssidData[i] == (i + 0x41).uint8
  for i in 0 ..< ieLen: doAssert probe.ssidData[ssidLen + i] == (i xor 0xA5).uint8

# The traces run no firmware code: nothing is re-checked after them (they
# still run with interrupts masked). The handoff may complete synchronously.
for irq in [false, true]:
  for trigger in ["trace1", "trace2", "handoff"]:
    for change in 0 .. (if trigger == "handoff": 9 else: 0):
      setup(irq)
      stage = trigger
      action = change
      let rc = scan_probe_req_tx()
      doAssert fired and interruptsEnabled == irq
      doAssert pushes == 1
      doAssert rc == 0 # Vendor clears its initial 1 for an accepted push.
      if replacement != nil:
        doAssert replacement[] == replacementDesc
        doAssert hostTxHwDescAt(replacement.hwDesc)[] == replacementHw
        doAssert hostTxLinkDescAt(replacement.bufDesc)[] == replacementLink
      else:
        checkFrame(currentFrame, 5, 31)

# The pool's recovery runs TX callbacks, none of which runs TASK_SCAN code:
# they cannot end or abort the dwell, so it is not re-checked. A change of
# the frame's identity (here its VIF's generation) still drops the frame, and
# shared IEs rewritten meanwhile do not reach it.
for irq in [false, true]:
  for change in 0 .. 1:
    setup(irq, 4)
    onRecovery = proc() =
      onRecovery = nil
      if change == 0: inc rxVifEpochs[1]
      else:
        for byte in scan_probe_req_ie.ieData.mitems: byte = 0xDD
      txl_frame_release(held[0], false)
    currentFrame = held[0]
    let rc = scan_probe_req_tx()
    doAssert interruptsEnabled == irq
    doAssert pushes == change
    if change == 1:
      doAssert rc == 0
      checkFrame(currentFrame, 5, 31)

# Exact on-wire bytes at both endpoints, with private IEs surviving a later
# request/channel write to the global buffer after this frame is queued.
for irq in [false, true]:
  for ssidLen in [0, 1, 31, 32]:
    for ieLen in [0, 1, 199, 200]:
      setup(irq)
      scanSsidSlot(addr request, 0).length = ssidLen.uint8
      request.ieBodyLen = ieLen.uint16
      doAssert scan_probe_req_tx() == 0
      doAssert pushes == 1 and interruptsEnabled == irq
      checkFrame(currentFrame, ssidLen, ieLen)
      let original = hostTxLinkDescAt(currentFrame.bufDesc)[]
      for byte in scan_probe_req_ie.ieData.mitems: byte = 0
      newDwell(addr otherRequest, 5)
      doAssert hostTxLinkDescAt(currentFrame.bufDesc)[] == original

for irq in [false, true]:
  for invalid in 0 .. 6:
    setup(irq)
    case invalid
    of 0: request.scanType = 2
    of 1: request.scanType = 255
    of 2: scanSsidSlot(addr request, 0).length = 33
    of 3: request.ieBodyLen = 201
    of 4: request.ieBodyLen = 0xFFFF
    of 5: request.vifIdx = 2
    else: scan_env.abortFlag = 1
    let before = frameEnv.freeList.first
    doAssert scan_probe_req_tx() == 0
    doAssert pushes == 0 and frameEnv.freeList.first == before
    doAssert interruptsEnabled == irq
  setup(irq)
  request.scanType = 0
  doAssert scan_probe_req_tx() == 1 and pushes == 0
  scan_env.paramPtr = nil
  doAssert scan_probe_req_tx() == 1 and pushes == 0
  setup(irq, 4)
  doAssert scan_probe_req_tx() == 1 and pushes == 0
  setup(irq)
  rejectPush = true
  doAssert scan_probe_req_tx() == 1 and pushes == 0
  doAssert co_list_cnt(addr frameEnv.freeList) == 1
  setup(irq)
  pushResultOverride = 2
  doAssert scan_probe_req_tx() == 0 and pushes == 1

"""


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("mutation", [None, "count", "ssid", "ies", "binding",
                                      "snapshot", "handoff", "unlocked"])
def test_probe_lifetime(tmp_path: Path, mode: str, mutation: str | None) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("Nim is required")
    tx = (FW / "tx_layer.nim").read_text()
    functions = "".join(procedure(tx, name) for name in [
        "txl_frame_desc_index", "txlCaptureFrameIdentity", "txlFrameBeginLease", "txlFrameEndLease",
        "txlFrameLeaseToken", "txlFrameLeaseMatches", "txlFrameIdentityCurrent", "txlFrameSessionCurrent",
        "txlCaptureFrameCallback", "txlFrameCallbackCurrent", "txlInvokeFrameCallback",
        "txlCaptureSession", "txlSessionCurrent", "txlStationAdmits", "txlFramePreparationCurrent",
        "txl_frame_free_list_pop", "txl_frame_get", "txl_frame_release", "txlFramePushPrepared",
        "txl_frame_push",
    ])
    management = (FW / "scan_station_ap_me.nim").read_text()
    handlers = (FW / "task_handlers.nim").read_text()
    probe = procedure(management, "scan_probe_req_tx")
    cache = procedure(handlers, "cacheScanStartContext")
    if mutation == "count":
        probe = probe.replace("numSsids != 1 or ", "")
    elif mutation == "ssid":
        probe = probe.replace("ssid.length > 32 or\n      ", "")
    elif mutation == "ies":
        probe = probe.replace("ieLen > scan_probe_req_ie.ieData.len.uint32", "false")
    elif mutation == "binding":
        probe = probe.replace("  frameDesc.vifIdx = vifIdx\n  frameDesc.staInfoIdx = 0xFF\n", "")
    elif mutation == "snapshot":
        probe = probe.replace("unsafeAddr ieBytes[0]", "addr scan_probe_req_ie.ieData[0]")
    elif mutation == "handoff":
        probe = probe.replace("  if txl_frame_push(frame, 3) != 0: 0'u8 else: 1'u8",
                              "  result = (if txl_frame_push(frame, 3) != 0: 0'u8 else: 1'u8)\n"
                              "  frameDesc.pendingMacTime = 0")
    elif mutation == "unlocked":
        probe = probe.replace("  let saved = irqSave()\n  defer: irqRestore(saved)\n", "")
    functions += cache + probe
    layout = (FW / "layout_types.nim").read_text()
    types = "type\n"
    for name in ["TxSessionIdentity", "MacDataFrameHeaderView", "MacQosDataFrameHeaderView",
                 "MacCtsFrameHeaderView", "ScanChannelEntry", "ScanSsidSlotView", "ScanStartReqPayload",
                 "ProbeReqFixedFrame", "ProbeReqFrameView"]:
        types += "  " + name + layout.split("  " + name, 1)[1].split("\n\n  ", 1)[0] + "\n"
    debug = "\nvar\n" + "".join(
        f"  {name}: {'array[64, uint8]' if name == 'nimFwDbgProbeIeRaw' else 'uint32'}\n"
        for name in sorted(set(re.findall(r"\bnimFwDbg\w+", functions))))
    platform = platform_source()
    split = platform.index("const NUM_TX_QUEUES")
    source = tmp_path / "probe.nim"
    op = (FW / "op.nim").read_text() + "\nvar scanOwn: tuple[op: Op]\n"
    source.write_text(platform[:split] + types + platform[split:] + debug + op + functions + CHECKS)
    flags = {"checked": [], "release": ["-d:release", "--assertions:on"],
             "asan": ["--cc:clang", "--passC:-fsanitize=address", "--passL:-fsanitize=address"]}
    result = subprocess.run([nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on", "--skipUserCfg:on",
        "-d:bl808WifiScanTrace", f"--nimcache:{tmp_path / 'cache'}", f"-o:{tmp_path / 'test'}",
        *flags[mode], str(source)], cwd=ROOT, text=True, stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT, timeout=120,
        env={**os.environ, "ASAN_OPTIONS": "symbolize=0"} if mode == "asan" else None)
    if mutation is None:
        assert result.returncode == 0, result.stdout
    else:
        assert result.returncode != 0 and any(marker in result.stdout for marker in
            ["AssertionDefect", "IndexDefect", "AddressSanitizer"]), result.stdout
