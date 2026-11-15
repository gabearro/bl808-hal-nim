"""Check AP management-frame preparation against frame/session replacement."""

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
    "vifIdx, staInfoIdx: uint8", "vifIdx, staInfoIdx, hdrLen, secTailLen: uint8"
)
PLATFORM = PLATFORM.replace("proc submit(p: pointer; ac: uint8): uint8 =",
    "var rejectSubmission: bool\nproc submit(p: pointer; ac: uint8): uint8 =").replace(
    "proc txl_cntrl_push_int(p: pointer; ac: uint8): uint8 = submit(p, ac)",
    "proc txl_cntrl_push_int(p: pointer; ac: uint8): uint8 =\n"
    "  if rejectSubmission:\n    txl_frame_release(p, false)\n    return 0\n"
    "  submit(p, ac)")
PLATFORM += r"""
type Apm = object
  securityIe: array[64, uint8]
  cryptoType: uint8
var
  apm: Apm
  destination: array[6, uint8]
  context: uint32
  bodyCalls, customerCalls, failureCalls: int
  probeCapacity, probeLength, associationLength: uint32
  bodyIrqEnabled: bool
  expectedType: uint16
  expectedArgument: pointer
  retained: ApmAssocStaAddIndPayload
  retainedPending: bool
  retainedFreed, retainedSent, aidDeletes: int
  apmPendingAssociations: array[1, tuple[meQueued: bool]]
proc apmEnvView(): ptr Apm = addr apm
proc body(buf: pointer; length: uint32): uint32 =
  inc bodyCalls
  bodyIrqEnabled = interruptsEnabled
  for i in 0 ..< length.int:
    cast[ptr UncheckedArray[uint8]](buf)[i] = (0xA0 + i).uint8
  currentFrame = txlFrameDescAt(3)
  if stage == "body": observe("body")
  length
proc me_build_authenticate(buf: pointer; algorithm, sequence, status: uint16;
                           challenge: pointer): uint32 =
  doAssert expectedType == 0xB0
  doAssert algorithm == 0 and sequence == 2 and status == 0 and challenge == nil
  body(buf, 6)
proc me_build_deauthenticate(buf: pointer; reason: uint16): uint32 =
  doAssert expectedType == 0xC0 and reason == 0x9876
  body(buf, 2)
proc me_build_associate_rsp(buf: pointer; vif: uint8; status: uint16;
                            request: pointer): uint32 =
  doAssert expectedType in [0x10'u16, 0x30] and vif == 1
  doAssert status == 0x9876 and request == expectedArgument
  if associationLength == 0: return 0
  body(buf, associationLength)
proc meBuildProbeResponse(buf: pointer; vif: uint8; capacity: uint32;
                          length: ptr uint16): uint32 =
  doAssert expectedType == 0x50 and vif == 1 and length == nil
  probeCapacity = capacity
  if probeLength > capacity: return 0
  body(buf, probeLength)
proc me_add_ie_customer(buf: pointer; data: pointer; length: uint32): uint32 =
  inc customerCalls
  doAssert data == (addr apm.securityIe[0]) and length == apm.cryptoType.uint32
  for i in 0 ..< length.int:
    cast[ptr UncheckedArray[uint8]](buf)[i] = apm.securityIe[i]
  if stage == "customer": observe("customer")
  length
proc failed(arg: pointer; status: uint32) {.cdecl.} =
  doAssert arg == (addr context) and status == 0x40000000'u32
  inc failureCalls
proc apmPendingRequestSlot(request: pointer; queued: bool): int =
  if request == (addr retained) and retainedPending and not queued: 0 else: -1
proc aidListDelete(request: pointer) =
  doAssert request == (addr retained)
  inc aidDeletes
  retainedPending = false
proc keMsgHdrFromPayload(request: pointer): pointer = request
proc ke_msg_free(header: pointer) =
  doAssert header == (addr retained) and retainedFreed == 0
  inc retainedFreed
proc ke_msg_send(request: pointer) =
  doAssert request == (addr retained) and retainedPending
  inc retainedSent
"""

CHECKS = r"""
proc replaceCurrent() =
  let desc = currentFrame
  txl_frame_release(desc, false)
  replacement = hostTxDescAt(txl_frame_get(24))
  doAssert replacement == desc
  replacement.vifIdx = 0
  replacement.staInfoIdx = 0
  replacement.hdrLen = 7
  replacement.secTailLen = 9
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
  fired = true
  case action
  of 0: discard
  of 1: inc rxVifEpochs[1]
  of 2: inc txResetEpoch
  of 3: replaceCurrent()
  of 4: retired = true
  of 5: inc rxVifEpochs[0]
  of 6: destination = [0x90'u8, 0x91, 0x92, 0x93, 0x94, 0x95]
  of 7:
    let callback = currentFrame.callback
    let argument = currentFrame.callbackArg
    txl_frame_release(currentFrame, false)
    cast[proc(arg: pointer; status: uint32) {.cdecl.}](callback)(argument, 0x800000)
  else: doAssert false

proc setup(irq: bool; allocatedCount = 3) =
  stage = ""
  initPool()
  retired = false
  fired = false
  pushes = 0
  powers = 0
  bodyCalls = 0
  customerCalls = 0
  failureCalls = 0
  rejectSubmission = false
  expectedArgument = addr context
  retained = ApmAssocStaAddIndPayload(aid: 1)
  retainedPending = true
  retainedFreed = 0
  retainedSent = 0
  aidDeletes = 0
  apmPendingAssociations[0].meQueued = false
  probeCapacity = 0
  probeLength = 12
  associationLength = 6
  bodyIrqEnabled = false
  pushed.setLen(0)
  currentFrame = nil
  replacement = nil
  sequence = 0x1000
  txResetEpoch = 0
  apm.cryptoType = 3
  apm.securityIe[0..2] = [0xDD'u8, 1, 0x42]
  destination = [0x10'u8, 0x11, 0x12, 0x13, 0x14, 0x15]
  interruptsEnabled = irq
  for i in 0 .. 1:
    vifs[i] = Vif(vifIdx: i.uint8, vifType: 2, state: 1)
    for j in 0 .. 5: vifs[i].macAddr[j] = (0x20 + i * 16 + j).uint8
  for i in 0 ..< stas.len:
    stas[i].valid = 1
    stas[i].instNbr = 1
  stas[0].instNbr = 0
  for i in 0 ..< allocatedCount:
    held[i] = hostTxDescAt(txl_frame_get(24))
    held[i].vifIdx = 1
    held[i].staInfoIdx = 2

proc build(frameType: uint16) =
  expectedType = frameType
  apm_send_mlme(addr vifs[1], frameType, addr destination[0],
                cast[pointer](failed), addr context, cast[pointer](0x12349876'u))

proc sendAssociation() =
  expectedType = 0x10
  expectedArgument = addr retained
  apm_send_mlme(addr vifs[1], 0x10, addr destination[0],
    cast[pointer](apm_tx_cfm_handler), addr retained, cast[pointer](0x12349876'u))

# A cancelled request stays owned by the caller until TX accepts or completes it.
setup(true, 4)
onRecovery = proc() =
  inc rxVifEpochs[1]
  retainedPending = false
  txl_frame_release(held[3], false)
sendAssociation()
doAssert retainedFreed == 1 and retainedSent == 0 and aidDeletes == 0,
  "association request was not released after cancelled frame preparation"
doAssert co_list_cnt(addr frameEnv.freeList) == 1 and pushes == 0

# Pool recovery may release the receive storage that supplied the destination.
setup(true, 4)
let originalDestination = destination
stage = "recovery"
action = 6
onRecovery = proc() =
  observe("recovery")
  txl_frame_release(held[3], false)
build(0xC0)
doAssert fired and pushes == 1
doAssert hostTxDataHeader(currentFrame).addr1 == originalDestination,
  "AP frame used destination storage changed by allocation recovery"

for irq in [false, true]:
  for frameType in [0xB0'u16, 0xC0, 0x50, 0x10, 0x30, 0]:
    setup(irq)
    build(frameType)
    doAssert pushes == 1 and interruptsEnabled == irq and not bodyIrqEnabled
    doAssert powers == 0 and failureCalls == 0
    let desc = currentFrame
    let header = hostTxDataHeader(desc)
    doAssert header.frameControl == frameType and header.duration == 0
    doAssert header.addr1 == destination
    doAssert header.addr2 == vifs[1].macAddr and header.addr3 == vifs[1].macAddr
    doAssert header.seqCtrl == 0x1010
    doAssert desc.vifIdx == 1 and desc.staInfoIdx == 255
    doAssert desc.hdrLen == 0 and desc.secTailLen == 0
    doAssert desc.callback == cast[pointer](failed) and desc.callbackArg == (addr context)
    let length = case frameType
      of 0xC0: 26
      of 0x50: 39
      of 0: 24
      else: 30
    let hw = hostTxHwDescAt(desc.hwDesc)
    doAssert hw.frameLen == (length + 4).uint32
    doAssert hw.payloadEnd == hw.payloadStart + length.uint32 - 1
    doAssert customerCalls == (frameType == 0x50).int
    if frameType == 0x50:
      doAssert probeCapacity == 485
      doAssert hostTxLinkDescAt(desc.bufDesc).macHeader[36..38] == [0xDD'u8, 1, 0x42]

  # The original session is captured before allocator recovery runs.
  for change in [0, 1, 2, 4, 5]:
    setup(irq, 4)
    action = change
    stage = "recovery"
    onRecovery = proc() =
      observe("recovery")
      txl_frame_release(held[3], false)
    build(0xB0)
    let current = change in [0, 5]
    doAssert fired and pushes == current.int and bodyCalls == current.int
    doAssert failureCalls == (not current).int
    doAssert interruptsEnabled == irq
    doAssert co_list_cnt(addr frameEnv.freeList) == (not current).uint32

  # A builder callback cannot make the old preparation own a replacement frame.
  for point in ["body", "customer"]:
    for change in [0, 1, 2, 3, 4, 5]:
      setup(irq)
      stage = point
      action = change
      build(0x50)
      let current = change in [0, 5]
      doAssert fired and pushes == current.int and interruptsEnabled == irq
      doAssert failureCalls == (not current).int
      if point == "body" and not current:
        doAssert customerCalls == 0
      if change == 3:
        doAssert replacement[] == replacementDesc
        doAssert hostTxHwDescAt(replacement.hwDesc)[] == replacementHw
        doAssert hostTxLinkDescAt(replacement.bufDesc)[] == replacementLink
        doAssert co_list_cnt(addr frameEnv.freeList) == 0
      elif not current:
        doAssert co_list_cnt(addr frameEnv.freeList) == 1

  setup(irq, 4)
  build(0x10)
  doAssert failureCalls == 1 and pushes == 0 and bodyCalls == 0
  doAssert interruptsEnabled == irq

  for subtype in [0x10'u16, 0x30]:
    setup(irq)
    expectedType = subtype
    expectedArgument = addr retained
    associationLength = 0
    apm_send_mlme(addr vifs[1], subtype, addr destination[0],
      cast[pointer](apm_tx_cfm_handler), addr retained, cast[pointer](0x9876))
    doAssert pushes == 0 and retainedFreed == 1 and aidDeletes == 1,
      "failed association body was sent as a header-only response"
    doAssert bodyCalls == 0 and co_list_cnt(addr frameEnv.freeList) == 1

  for failure in 0 .. 1:
    setup(irq, if failure == 0: 4 else: 3)
    rejectSubmission = failure == 1
    sendAssociation()
    doAssert retainedFreed == 1 and retainedSent == 0 and aidDeletes == 1
    doAssert interruptsEnabled == irq

  # Enqueue may complete synchronously; success must suppress fallback failure.
  setup(irq)
  stage = "handoff"
  action = 7
  sendAssociation()
  doAssert fired and pushes == 1 and retainedSent == 1 and retainedFreed == 0
  doAssert aidDeletes == 0 and apmPendingAssociations[0].meQueued
  doAssert interruptsEnabled == irq

  for invalid in 0 .. 2:
    setup(irq, 0)
    if invalid == 2: vifs[1].vifIdx = 255
    let vifArgument: pointer = if invalid == 0: nil else: addr vifs[1]
    let destinationArgument: pointer = if invalid == 1: nil else: addr destination[0]
    apm_send_mlme(vifArgument, 0x10, destinationArgument,
      cast[pointer](apm_tx_cfm_handler), addr retained, nil)
    doAssert retainedFreed == 1 and aidDeletes == 1 and retainedSent == 0
    doAssert co_list_cnt(addr frameEnv.freeList) == 4 and pushes == 0
    doAssert interruptsEnabled == irq

  # Reserve the customer tail before serialization; reject an invalid source length.
  for customerLength in [0'u8, 3, 64, 65, 255]:
    for extraByte in [0'u32, 1]:
      setup(irq)
      apm.cryptoType = customerLength
      if customerLength <= 64:
        probeLength = 488 - customerLength.uint32 + extraByte
      build(0x50)
      let accepted = customerLength <= 64 and extraByte == 0
      doAssert pushes == accepted.int and failureCalls == (not accepted).int
      doAssert customerCalls == (accepted and customerLength != 0).int
      doAssert interruptsEnabled == irq
      if accepted:
        doAssert hostTxHwDescAt(currentFrame.hwDesc).frameLen == 516
      else:
        doAssert bodyCalls == 0 and co_list_cnt(addr frameEnv.freeList) == 1

  # Invalid bindings must not allocate, inspect a body, or publish a frame.
  setup(irq, 0)
  apm_send_mlme(nil, 0xB0, addr destination[0], nil, nil, nil)
  apm_send_mlme(addr vifs[1], 0xB0, nil, nil, nil, nil)
  vifs[1].vifIdx = 255
  apm_send_mlme(addr vifs[1], 0xB0, addr destination[0], nil, nil, nil)
  vifs[1].vifIdx = 0
  apm_send_mlme(addr vifs[1], 0xB0, addr destination[0], nil, nil, nil)
  doAssert co_list_cnt(addr frameEnv.freeList) == 4 and pushes == 0 and bodyCalls == 0
  doAssert interruptsEnabled == irq
"""


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_ap_mlme_preparation(tmp_path: Path, mode: str) -> None:
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
    functions += procedure(management, "apm_tx_cfm_handler")
    functions += procedure(management, "apm_send_mlme")
    layout = (FW / "layout_types.nim").read_text()
    declarations = "type\n"
    for name in ["TxSessionIdentity", "MacDataFrameHeaderView", "ApmAssocStaAddIndPayload"]:
        declarations += "  " + name + layout.split("  " + name, 1)[1].split("\n\n  ", 1)[0] + "\n"
    # The base platform also declares accessors for these headers.
    for name in ["MacQosDataFrameHeaderView", "MacCtsFrameHeaderView"]:
        declarations += "  " + name + layout.split("  " + name, 1)[1].split("\n\n  ", 1)[0] + "\n"
    debug = "\nvar\n" + "".join(
        f"  {name}: uint32\n" for name in sorted(set(re.findall(r"\bnimFwDbg\w+", functions)))
    )
    split = PLATFORM.index("const NUM_TX_QUEUES")
    source = tmp_path / "ap_mlme_preparation.nim"
    source.write_text(PLATFORM[:split] + declarations + PLATFORM[split:] + debug + functions + CHECKS)
    flags = {"checked": [], "release": ["-d:release", "--assertions:on"],
             "asan": ["--cc:clang", "--passC:-fsanitize=address", "--passL:-fsanitize=address"]}
    result = subprocess.run([
        nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on", "--skipUserCfg:on",
        f"--nimcache:{tmp_path / 'cache'}", f"-o:{tmp_path / 'test'}", *flags[mode], str(source),
    ], cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=120)
    assert result.returncode == 0, result.stdout
