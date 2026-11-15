"""Exercise complete probe construction, request epochs, and private IE DMA."""

from pathlib import Path
import re
import shutil
import subprocess

import pytest

from test_wifi_disconnect_tx import procedure
from test_wifi_frame_preparation import PLATFORM as FRAME_PLATFORM

ROOT = Path(__file__).resolve().parents[1]
FW = ROOT / "src/bl808/wifi/fw"


def platform_source() -> str:
    source = FRAME_PLATFORM.replace("  retired: bool", "  retired, rejectPush: bool")
    source = source.replace("proc txl_cntrl_push_int(p: pointer; ac: uint8): uint8 = submit(p, ac)", r"""
proc txl_cntrl_push_int(p: pointer; ac: uint8): uint8 =
  if rejectPush:
    txl_frame_release(p, false)
    return 0
  submit(p, ac)
""")
    source = source.replace(procedure(source, "nimFwTrace2U32"), r"""
proc nimFwTrace2U32(s: string; a, b: uint32) =
  if s == "[WIFI-SCAN] probe_tx ": observe("trace1")
  elif s == "[WIFI-SCAN] probe_fc ": observe("trace2")
""")
    return source + r"""
const IE_ID_SSID = 0'u8
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
  scanRequestEpoch: uint32
  request, otherRequest: ScanStartReqPayload
  freeCalls: int
  freeHook: proc()
proc scanStartReqView(p: pointer): ptr ScanStartReqPayload = cast[ptr ScanStartReqPayload](p)
proc scanSsidSlot(req: ptr ScanStartReqPayload; index: int): ptr ScanSsidSlotView =
  cast[ptr ScanSsidSlotView](addr req.ssidFilter[index * 34])
proc hostTxProbeReqFrame(link: ptr LinkDesc): ptr ProbeReqFrameView =
  cast[ptr ProbeReqFrameView](addr link.macHeader[0])
proc keMsgHdrFromPayload(p: pointer): pointer = p
proc ke_msg_free(p: pointer) =
  doAssert p == addr request
  doAssert scan_env.paramPtr == nil, "request was not detached before free"
  inc freeCalls
  if freeHook != nil: freeHook()
"""


CHECKS = r"""
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
  of 3: cacheScanStartContext(addr request, 7) # Same address, new request.
  of 4: cacheScanStartContext(addr otherRequest, 7)
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
  onRecovery = nil
  freeHook = nil
  interruptsEnabled = true
  initPool()
  replacement = nil
  pushes = 0
  freeCalls = 0
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
  scanRequestEpoch = 0
  cacheScanStartContext(addr request, 2)
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

# Both trace calls can retire the session, replace the same request allocation,
# or recycle the frame. The handoff itself may complete synchronously.
for irq in [false, true]:
  for trigger in ["trace1", "trace2", "handoff"]:
    for change in 0 .. 9:
      setup(irq)
      stage = trigger
      action = change
      let rc = scan_probe_req_tx(nil)
      doAssert fired and interruptsEnabled == irq
      let submitted = trigger == "handoff" or change in [0, 6, 7]
      doAssert pushes == submitted.int
      doAssert rc == 0 # Vendor clears its initial 1 for an accepted push.
      if replacement != nil:
        doAssert replacement[] == replacementDesc
        doAssert hostTxHwDescAt(replacement.hwDesc)[] == replacementHw
        doAssert hostTxLinkDescAt(replacement.bufDesc)[] == replacementLink
      elif submitted:
        checkFrame(currentFrame, 5, 31)
      else:
        doAssert co_list_cnt(addr frameEnv.freeList) == 1

# The pool's recovery callback can publish a new request at the same address,
# or change shared IEs without replacing this request. Only the latter is valid.
for irq in [false, true]:
  for change in 0 .. 3:
    setup(irq, 4)
    onRecovery = proc() =
      onRecovery = nil
      case change
      of 0: cacheScanStartContext(addr request, 9)
      of 1: cacheScanStartContext(addr otherRequest, 9)
      of 2: inc rxVifEpochs[1]
      else:
        for byte in scan_probe_req_ie.ieData.mitems: byte = 0xDD
      txl_frame_release(held[0], false)
    currentFrame = held[0]
    let rc = scan_probe_req_tx(nil)
    doAssert interruptsEnabled == irq
    doAssert pushes == (change == 3).int
    if change == 3:
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
      doAssert scan_probe_req_tx(nil) == 0
      doAssert pushes == 1 and interruptsEnabled == irq
      checkFrame(currentFrame, ssidLen, ieLen)
      let original = hostTxLinkDescAt(currentFrame.bufDesc)[]
      for byte in scan_probe_req_ie.ieData.mitems: byte = 0
      cacheScanStartContext(addr otherRequest, 5)
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
    doAssert scan_probe_req_tx(nil) == 0
    doAssert pushes == 0 and frameEnv.freeList.first == before
    doAssert interruptsEnabled == irq
  setup(irq)
  request.scanType = 0
  doAssert scan_probe_req_tx(nil) == 1 and pushes == 0
  scan_env.paramPtr = nil
  doAssert scan_probe_req_tx(nil) == 1 and pushes == 0
  setup(irq, 4)
  doAssert scan_probe_req_tx(nil) == 1 and pushes == 0
  setup(irq)
  rejectPush = true
  doAssert scan_probe_req_tx(nil) == 1 and pushes == 0
  doAssert co_list_cnt(addr frameEnv.freeList) == 1

# Detach before free; a free hook can install the next request without being
# overwritten by the old completion. Releasing an unrelated request is inert.
for irq in [false, true]:
  setup(irq)
  let epoch = scanRequestEpoch
  freeHook = proc() = cacheScanStartContext(addr otherRequest, 8)
  releaseCompletedScanRequest(addr request)
  doAssert freeCalls == 1 and scan_env.paramPtr == addr otherRequest
  doAssert scanRequestEpoch == epoch + 2 and interruptsEnabled == irq
  releaseCompletedScanRequest(addr request)
  doAssert freeCalls == 1 and scan_env.paramPtr == addr otherRequest
"""


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
@pytest.mark.parametrize("mutation", [None, "count", "ssid", "ies", "binding", "request",
                                      "trace2", "snapshot", "handoff", "release", "epoch", "unlocked"])
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
        "txl_frame_free_list_pop", "txl_frame_get", "txl_frame_release", "txl_frame_push",
    ])
    management = (FW / "scan_station_ap_me.nim").read_text()
    handlers = (FW / "task_handlers.nim").read_text()
    probe = procedure(management, "scan_probe_req_tx")
    cache = procedure(handlers, "cacheScanStartContext")
    release = procedure(handlers, "releaseCompletedScanRequest")
    if mutation == "count":
        probe = probe.replace("numSsids != 1 or ", "")
    elif mutation == "ssid":
        probe = probe.replace("ssid.length > 32 or\n      ", "")
    elif mutation == "ies":
        probe = probe.replace("ieLen > scan_probe_req_ie.ieData.len.uint32", "false")
    elif mutation == "binding":
        probe = probe.replace("  frameDesc.vifIdx = vifIdx\n  frameDesc.staInfoIdx = 0xFF\n", "")
    elif mutation == "request":
        probe = probe.replace("scanRequestEpoch != requestEpoch", "false")
    elif mutation == "trace2":
        marker = '    nimFwTrace2U32("[WIFI-SCAN] probe_fc ", 0x40, addressWord)\n'
        assert marker + "    ensureProbeCurrent()\n" in probe
        probe = probe.replace(marker + "    ensureProbeCurrent()\n", marker)
    elif mutation == "snapshot":
        probe = probe.replace("unsafeAddr ieBytes[0]", "addr scan_probe_req_ie.ieData[0]")
    elif mutation == "handoff":
        probe = probe.replace("  (txl_frame_push(frame, 3) xor 1'u8) and 0xFF'u8",
                              "  result = (txl_frame_push(frame, 3) xor 1'u8) and 0xFF'u8\n"
                              "  frameDesc.pendingMacTime = 0")
    elif mutation == "release":
        release = release.replace("  scan_env.paramPtr = nil\n", "")
    elif mutation == "epoch":
        cache = cache.replace("  inc scanRequestEpoch\n", "")
    elif mutation == "unlocked":
        probe = probe.replace("  let saved = irqSave()\n  defer: irqRestore(saved)\n", "")
    functions += cache + release + probe
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
    source.write_text(platform[:split] + types + platform[split:] + debug + functions + CHECKS)
    flags = {"checked": [], "release": ["-d:release", "--assertions:on"],
             "asan": ["--cc:clang", "--passC:-fsanitize=address", "--passL:-fsanitize=address"]}
    result = subprocess.run([nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on", "--skipUserCfg:on",
        "-d:bl808WifiScanTrace", f"--nimcache:{tmp_path / 'cache'}", f"-o:{tmp_path / 'test'}",
        *flags[mode], str(source)], cwd=ROOT, text=True, stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT, timeout=120)
    if mutation is None:
        assert result.returncode == 0, result.stdout
    else:
        assert result.returncode != 0 and any(marker in result.stdout for marker in
            ["AssertionDefect", "IndexDefect", "AddressSanitizer"]), result.stdout
