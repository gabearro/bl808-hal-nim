"""Execute the production TX backup drain using descriptor and MMIO doubles."""

from pathlib import Path
import re
import shutil
import subprocess

import pytest
from test_wifi_frame_ownership import DMA_INVALIDATION_STUBS


ROOT = Path(__file__).resolve().parents[1]

PLATFORM = r"""
const NUM_TX_QUEUES = 5
type
  TxDmaOwner = object
    desc: pointer
    vif, station, ac: uint8
    cancelled: bool
  HostTxThdEntryView = object
    magic, payloadStart, payloadEnd, flags: uint32
    next: pointer
  HostTxRateTemplateView = object
    magic, ntxConfig, pendingCount, policyWord, bwMask, rateWord: uint32
    txPower: int32
    retryTxPowerControl0, retryTxPowerControl1, retryTxPowerControl2: uint32
    retryRateControl0, retryRateControl1, retryRateControl2: uint32
  HostTxLinkDescView = object
    next, txDesc: pointer
    headerLen, ackPolicyControl, retryLimitControl: uint32
    headerThd: HostTxThdEntryView
    payloadThd: array[4, HostTxThdEntryView]
    rateTemplate: HostTxRateTemplateView
    macHeader: array[128, uint8]
  HostTxHwDescView = object
    txConfirmDescPtr, magic, secondaryTxHwDescPtr: uint32
    secondaryDescToStatusPadding, payloadStart, payloadEnd, frameLen: uint32
    status, controlFlags, confirmStatus: uint32
    ackPolicyControl, retryLimitControl: uint32
    frameLenToRetryLimitPadding: uint32
    chainedThd: pointer
  HostTxDescView = object
    queueFirst, bufDesc, hwDesc, callback: pointer
    frameLen, seqPassthrough: uint16
    staIdx, vifIdx, staInfoIdx, hdrLen, qosExtLen, secTailLen: uint8
    bufferPtrs, bufferLens: array[4, uint32]
  MacDataFrameHeaderView {.packed.} = object
    frameControl, duration: uint16
    addr1, addr2, addr3: array[6, uint8]
    seqCtrl: uint16
  AcControl = object
    current: pointer
    packetCount: uint16
    pending: CoList
  CoListHdr = object
    next: pointer
  CoList = object
    first, last: pointer
  Vif = object
    timFlags: uint8
  BackupQueue = object
    first, last: pointer
var
  txActiveDmaOwner: ptr TxDmaOwner
  txActiveTriggerOwner: ptr TxDmaOwner
  txDmaRescan: bool
  controls: array[5, AcControl]
  queues: array[5, BackupQueue]
  vifs: array[2, Vif]
  links: array[3, HostTxLinkDescView]
  descs: array[3, HostTxDescView]
  hw: array[3, HostTxHwDescView]
  hwLinks: array[3, HostTxThdEntryView]
  previous: HostTxThdEntryView
  heads: array[5, pointer]
  triggers: seq[uint32]
  timers: seq[tuple[ac, deadline: uint32]]
  micCalls, formatCalls: seq[pointer]
  assertLines: seq[cint]
  dmaStatus, aggActive, aggSet: uint32
  timerBase = 0x12340000'u32
  txEnvironment: tuple[packetCounter: uint32]
  interruptsEnabled = true
  traffic: seq[tuple[vif, sta, rx: uint8]]
  powerSave: seq[tuple[sta, tid: uint8]]
  allocationCount: int

proc pointerAddrU32(p: pointer): uint32 = cast[uint32](cast[uint](p))
proc hostTxDescAt(p: pointer): ptr HostTxDescView = cast[ptr HostTxDescView](p)
proc txlCaptureSession(d: ptr HostTxDescView): int = 0
proc txlSessionCurrent(i: int; d: ptr HostTxDescView): bool = true
proc txSecurityCurrent(d: ptr HostTxDescView): bool = true
proc txuCancelFrame(p: pointer; ac: uint8) = doAssert false
proc txl_frame_release(p: pointer; callback: bool) = doAssert false
proc hostTxLinkDescAt(p: pointer): ptr HostTxLinkDescView =
  cast[ptr HostTxLinkDescView](p)
template hostTxBufferedLinkAt(p: pointer): ptr HostTxLinkDescView = hostTxLinkDescAt(p)
template hostTxInternalLinkNodeAt(p: pointer): ptr HostTxLinkDescView = hostTxLinkDescAt(p)
proc hostTxHwDescAt(p: pointer): ptr HostTxHwDescView = cast[ptr HostTxHwDescView](p)
proc hostTxThdAt(p: pointer): ptr HostTxThdEntryView =
  for i in 0 ..< hw.len:
    if p == cast[pointer](addr hw[i].magic): return addr hwLinks[i]
  cast[ptr HostTxThdEntryView](p)
proc hostTxRateTemplate(p: ptr HostTxLinkDescView): ptr HostTxRateTemplateView =
  addr p.rateTemplate
proc txControlAc(ac: uint32): ptr AcControl = addr controls[ac]
proc txBackupQueueHeadPtr(ac: uint32): ptr pointer = addr queues[ac].first
proc txBackupQueueTailPtr(ac: uint32): ptr pointer = addr queues[ac].last
proc vifChannelForIdx(vif: uint8): ptr Vif = addr vifs[vif]
proc lmacGateHalfword(x: uint16): uint16 = (x shr 8) or (x shl 8)
proc nimFwMgmtFcTrace(fc: uint8): bool = false
proc nimFwTrace2U32(s: string; a, b: uint32) = discard
proc nimFwConnectTrace2U32(s: string; a, b: uint32) = discard
proc nimFwConnectTraceBytes(s: string; p: pointer; length, limit: uint32) = discard
proc nimFwDbgDhcpTxFinalBreakpoint() = discard
proc captureDhcpTxRateRaw(p: ptr HostTxRateTemplateView) = discard
proc macAddrWord0(p: ptr array[6, uint8]): uint32 = 0
proc c_memcpy(dst, src: pointer; n: uint32): pointer =
  copyMem(dst, src, n.int)
  dst
proc txl_machdr_format(p: pointer) = formatCalls.add(p)
proc txu_cntrl_tkip_mic_append(p: pointer) = micCalls.add(p)
proc regRead(address: uint): uint32 =
  doAssert address == 0x24B00120'u
  timerBase
proc machwTxDmaStatus(): uint32 = dmaStatus
proc machwTxStatus(): uint32 = 0
proc machwTxAggActive(): uint32 = aggActive
proc machwTxAggSet(mask: uint32) = aggSet = aggSet or mask
proc machwTxAggActiveSet(mask: uint32) = aggActive = mask
proc machwTxSetHead(ac: uint32; head: pointer) = heads[ac] = head
proc machwTxHeadValue(ac: uint32): uint32 = pointerAddrU32(heads[ac])
proc machwTxTrigger(mask: uint32) = triggers.add(mask)
proc blmac_abs_timer_set(ac, deadline: uint32) = timers.add((ac, deadline))
proc assert_rec(file, text: cstring; line: cint) = assertLines.add(line)
proc txControlEnv(): ptr tuple[packetCounter: uint32] = addr txEnvironment
proc irqSave(): uint32 =
  result = interruptsEnabled.uint32 * 8
  interruptsEnabled = false
proc irqRestore(state: uint32) =
  doAssert state in [0'u32, 8'u32]
  interruptsEnabled = state == 8
proc co_list_push_back(list: ptr CoList; node: ptr CoListHdr) =
  doAssert not interruptsEnabled
  if list.first == nil: list.first = node
  list.last = node
proc td_pck_ind(vif, sta, rx: uint8) =
  doAssert not interruptsEnabled
  traffic.add((vif, sta, rx))
proc ps_check_tx_frame(sta, tid: uint8): uint8 =
  doAssert not interruptsEnabled
  powerSave.add((sta, tid))
  0
"""

PLATFORM += DMA_INVALIDATION_STUBS

ALLOCATOR = r"""
proc txlPrepareBuffer(param: pointer; ac, arg: uint32): pointer =
  doAssert not interruptsEnabled and arg == 0
  inc allocationCount
  # Preparation returns a private link; the lower caller commits it later.
  hostTxDescAt(param).bufDesc
"""

CHECKS = r"""
proc reset(ac: int; count: int; existing, hasPayload: bool;
           fcHigh, flags: uint8; tid = 0'u8) =
  controls = default(typeof(controls))
  queues = default(typeof(queues))
  vifs = default(typeof(vifs))
  links = default(typeof(links))
  descs = default(typeof(descs))
  hw = default(typeof(hw))
  hwLinks = default(typeof(hwLinks))
  previous = default(HostTxThdEntryView)
  heads = default(typeof(heads))
  triggers.setLen(0)
  timers.setLen(0)
  micCalls.setLen(0)
  formatCalls.setLen(0)
  assertLines.setLen(0)
  dmaStatus = 0
  aggActive = 0x80
  aggSet = 0
  txEnvironment.packetCounter = 10
  interruptsEnabled = true
  traffic.setLen(0)
  powerSave.setLen(0)
  allocationCount = 0
  vifs[1].timFlags = flags
  for i in 0 ..< controls.len: controls[i].packetCount = 7
  if existing: controls[ac].current = addr previous
  for i in 0 ..< count:
    links[i].macHeader[0] = 0x80
    links[i].macHeader[1] = fcHigh
    links[i].txDesc = addr descs[i]
    links[i].ackPolicyControl = 0x11223344'u32 + i.uint32
    links[i].retryLimitControl = 0x55667788'u32 + i.uint32
    descs[i].bufDesc = addr links[i]
    descs[i].hwDesc = addr hw[i]
    descs[i].vifIdx = 1
    descs[i].staIdx = tid
    descs[i].frameLen = 0x0608
    if hasPayload: descs[i].queueFirst = cast[pointer](1)
    if i + 1 < count: links[i].next = addr links[i + 1]
    hw[i].ackPolicyControl = 0xAABBCCDD'u32
    hw[i].retryLimitControl = 0xEEFF0011'u32
  queues[ac].first = addr links[0]
  queues[ac].last = addr links[count - 1]

const ResumeMasks = [2'u32, 4, 8, 16, 1]
const StartMasks = [512'u32, 1024, 2048, 4096, 256]
const TimerDelays = [200000'u32, 2000000, 400000, 200000, 50000]
const AssertLineByAc = [539.cint, 533, 527, 521, 514]
const DmaShifts = [4, 8, 12, 16, 0]

proc checkDrain(ac, count: int; existing, hasPayload: bool;
                fcHigh, flags: uint8; tid = 0'u8; blocked = false) =
  reset(ac, count, existing, hasPayload, fcHigh, flags, tid)
  if blocked: dmaStatus = 2'u32 shl DmaShifts[ac]
  txl_payload_handle_backup(nil)
  let expectedFlags = if ac == 4 and hasPayload:
      (flags and not 2'u8) or (if (fcHigh and 0x20) != 0: 2'u8 else: 0'u8)
    else: flags
  doAssert vifs[1].timFlags == expectedFlags, "beacon More Data flag"
  doAssert queues[ac].first == nil
  doAssert queues[ac].last == cast[pointer](addr links[count - 1])
  doAssert controls[ac].packetCount == (7 + count).uint16
  doAssert controls[ac].current == cast[pointer](addr hw[count - 1].magic)
  for other in 0 ..< 5:
    if other != ac:
      doAssert controls[other].packetCount == 7
      doAssert controls[other].current == nil
  for i in 0 ..< count:
    let next = if i + 1 < count: cast[pointer](addr hw[i + 1].magic) else: nil
    doAssert hwLinks[i].next == next, "hardware descriptor chain"
    if hasPayload:
      doAssert hw[i].ackPolicyControl == links[i].ackPolicyControl
      doAssert hw[i].retryLimitControl == links[i].retryLimitControl
      doAssert hw[i].chainedThd == cast[pointer](addr links[i].rateTemplate)
    else:
      doAssert hw[i].ackPolicyControl == 0xAABBCCDD'u32
      doAssert hw[i].retryLimitControl == 0xEEFF0011'u32
      doAssert hw[i].chainedThd == nil
  doAssert micCalls.len == (if hasPayload: count else: 0)
  doAssert formatCalls.len == (if hasPayload and tid == 0xFF: count else: 0)
  if existing:
    doAssert previous.next == cast[pointer](addr hw[0].magic)
    doAssert timers.len == 0 and aggSet == 0 and aggActive == 0x80
  elif not blocked:
    doAssert heads[ac] == cast[pointer](addr hw[0].magic)
    doAssert timers == @[(ac.uint32, timerBase + TimerDelays[ac])]
    doAssert aggSet == (1'u32 shl ac)
    doAssert aggActive == (0x80'u32 or (1'u32 shl ac))
  else:
    doAssert heads[ac] == nil and timers.len == 0 and aggSet == 0
    doAssert assertLines == @[AssertLineByAc[ac]]
  var expectedTriggers: seq[uint32]
  if not existing and not blocked: expectedTriggers.add(StartMasks[ac])
  for i in (if existing: 0 else: 1) ..< count: expectedTriggers.add(ResumeMasks[ac])
  doAssert triggers == expectedTriggers, "start/resume trigger ordering"
  if not blocked: doAssert assertLines.len == 0

# Exhaustively distinguish More Data from every other high-byte FC flag,
# preserving all unrelated bits in the VIF's TIM state.
for fcHigh in 0 .. 255:
  for flags in 0 .. 255:
    checkDrain(4, 1, true, true, fcHigh.uint8, flags.uint8)

for ac in 0 ..< 5:
  for count in 1 .. 3:
    for existing in [false, true]:
      for hasPayload in [false, true]:
        for tid in [0'u8, 7'u8, 0xFF'u8]:
          checkDrain(ac, count, existing, hasPayload, 0x20, 0xA5, tid)
  for fcHigh in 0 .. 255:
    checkDrain(ac, 1, false, false, fcHigh.uint8, 0xA5)
    checkDrain(ac, 1, true, true, fcHigh.uint8, 0xA5)
  checkDrain(ac, 1, false, true, 0, 0, blocked = true)

# Empty backup lists have no effects, including on DMA registers/timers.
queues = default(typeof(queues))
triggers.setLen(0)
timers.setLen(0)
let before = controls
txl_payload_handle_backup(nil)
doAssert controls == before and triggers.len == 0 and timers.len == 0

# Exercise the real lower submission path, including the real fake-transfer
# enqueue and payload THD construction, before the backup list is drained.
for ac in 0 ..< 5:
  for hasPayload in [false, true]:
    for segmentCount in 1 .. 4:
      reset(ac, 1, false, hasPayload, 0x20, 0xA5, tid = 7)
      queues[ac] = default(BackupQueue)
      descs[0].staInfoIdx = 3
      descs[0].seqPassthrough = (250 * segmentCount).uint16
      descs[0].hdrLen = 34
      descs[0].secTailLen = 12
      links[0].headerLen = 34
      for i in 0 ..< segmentCount:
        descs[0].bufferPtrs[i] = 0x20000000'u32 + i.uint32 * 0x800
        descs[0].bufferLens[i] = 250
      let retval = txl_cntrl_push(addr descs[0], ac.uint8)
      doAssert retval == 0
      doAssert interruptsEnabled
      doAssert traffic == @[(1'u8, 3'u8, 0'u8)]
      doAssert powerSave == @[(3'u8, 7'u8)]
      doAssert allocationCount == (if hasPayload: 1 else: 0)
      doAssert txEnvironment.packetCounter == 11
      doAssert controls[ac].pending.first == cast[pointer](addr descs[0])
      doAssert controls[ac].pending.last == cast[pointer](addr descs[0])
      doAssert controls[ac].packetCount == 8
      doAssert queues[ac].first == nil
      doAssert hw[0].frameLen == (250 * segmentCount + 50).uint32
      doAssert hw[0].magic == 0xCAFEBABE'u32
      doAssert hw[0].confirmStatus == 0
      doAssert hw[0].payloadStart == 0 and hw[0].payloadEnd == 0
      doAssert links[0].headerThd.magic == 0xCAFEFADE'u32
      if hasPayload:
        doAssert hw[0].controlFlags == 256
        doAssert hw[0].status == pointerAddrU32(addr links[0].headerThd)
        doAssert links[0].headerThd.next == cast[pointer](addr links[0].payloadThd[0])
        for i in 0 ..< segmentCount:
          let thd = addr links[0].payloadThd[i]
          doAssert thd.payloadStart == descs[0].bufferPtrs[i]
          doAssert thd.payloadEnd == descs[0].bufferPtrs[i] + 249
          doAssert thd.flags == 0
          let next = if i + 1 < segmentCount:
              cast[pointer](addr links[0].payloadThd[i + 1]) else: nil
          doAssert thd.next == next
      else:
        doAssert hw[0].controlFlags == 0 and hw[0].status == 0
"""


@pytest.mark.parametrize("trace", [False, True])
def test_tx_backup_drain(tmp_path: Path, trace: bool) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("nim is not installed")
    tx = (ROOT / "src/bl808/wifi/fw/tx_layer.nim").read_text()
    handler = "proc txl_payload_handle_backup*" + tx.split(
        "proc txl_payload_handle_backup*", 1
    )[1].split("\nproc txl_transmit_trigger*", 1)[0]
    lower_push = "proc txl_cntrl_push*" + tx.split(
        "proc txl_cntrl_push*", 1
    )[1].split("\nproc txl_cntrl_push_int*", 1)[0]
    thd_builder = "proc txlBuildBufferThd" + tx.split(
        "proc txlBuildBufferThd", 1
    )[1].split("\n# TX Confirm", 1)[0]
    tasks = (ROOT / "src/bl808/wifi/fw/task_handlers.nim").read_text()
    fake_transfer = "proc txl_int_fake_transfer*" + tasks.split(
        "proc txl_int_fake_transfer*", 1
    )[1].split("\nproc cfm_raw_send*", 1)[0]
    from test_wifi_disconnect_tx import procedure
    enqueue = procedure(tx, "txlEnqueuePrepared")
    all_procedures = handler + fake_transfer + ALLOCATOR + thd_builder + enqueue + lower_push
    debug_types = {"nimFwDbgProbePayRaw": "array[64, uint8]"}
    debug_names = set(re.findall(r"\bnimFwDbg\w+", all_procedures))
    debug_names.remove("nimFwDbgDhcpTxFinalBreakpoint")
    debug_vars = "\nvar\n" + "".join(
        f"  {name}: {debug_types.get(name, 'uint32')}\n"
        for name in sorted(debug_names)
    )
    source = tmp_path / "tx_backup_test.nim"
    source.write_text(PLATFORM + debug_vars + all_procedures + CHECKS)
    command = [nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on",
               "--skipUserCfg:on", "--checks:on", f"--nimcache:{tmp_path / 'nimcache'}",
               f"-o:{tmp_path / 'tx_backup_test'}"]
    if trace:
        command.append("-d:bl808WifiConnectTrace")
    result = subprocess.run(command + [str(source)], cwd=ROOT, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    assert result.returncode == 0, result.stdout
