"""Check native singleton feedback against the submitted DMA rate policy."""

from pathlib import Path
import re

import pytest

from test_wifi_disconnect_tx import FW, procedure
from test_wifi_message_allocation import run_program
from test_wifi_rate_confirmation import PLATFORM as RATE_PLATFORM


DESCRIPTORS = r"""
type
  Hardware = object
    flags: uint32
  HostTxRateTemplateView = object
    magic, policyWord, rateWord: uint32
    retryRateControl0, retryRateControl1, retryRateControl2: uint32
  TxHardware = object
    head: ptr Hardware
    magic, ackPolicyControl, txConfirmDescPtr: uint32
    chainedThd: pointer
  HostTxDescView = object
    next: pointer
    aggDescPtr: TxHardware
    aggDescStorage: array[1, Hardware]
    rateTemplate: HostTxRateTemplateView
    policy: pointer
    hwDesc, queueFirst, bufDesc, cfmDst: pointer
    staInfoIdx, vifIdx: uint8
  IpcHostTxWrapperView = object
    prefix: array[12, uint8]
    txDesc: HostTxDescView
  CoListHdr = object
    next: pointer
  CoList = object
    first, last: ptr CoListHdr
  TxFlushBatch = object
    previous: ptr TxFlushBatch
    ac: uint8
    status: uint32
    confirmations: CoList
  TxSessionIdentity = object
    captured: bool
    station, vif: uint8
    resetEpoch, vifEpoch, stationEpoch: uint32
"""

SUPPORT = r"""
const
  WifiTxFrameSuccessfulBit = 1'u32 shl 23
  RCS_ANOTHER_FLAG = 176
var
  ipcSharedEnv: array[2359, uint32]
  rcTrialSerial: array[5, uint32]
  txRateTrialTag: array[4, uint32]
  rcRateSampleEpoch: array[5, uint16]
  txRateSampleTag: array[4, uint32]
  info, rotate: uint8
  onDump: proc()
  confirmList: CoList
  txActiveFlush: ptr TxFlushBatch
  done, noticed: int
  ke_env: array[1, uint32]
  txl_cfm_evt_bit = [1'u32, 2, 4, 8, 16]
  txCtrl: tuple[packetCounter: uint32]

proc hostTxHwDescAt(p: pointer): ptr TxHardware = cast[ptr TxHardware](p)
proc hostTxHeadThd(p: ptr TxHardware): ptr Hardware = p.head
proc hostTxInlineBufferedLink(p: ptr HostTxDescView): ptr HostTxRateTemplateView =
  addr p.rateTemplate
proc hostTxRateTemplate(p: ptr HostTxRateTemplateView): ptr HostTxRateTemplateView = p
proc rcTrialControl(p: pointer): tuple[status, info: uint8] =
  (rcStatsCounters(p).updateStage, info)
proc rcRetryStep(p: pointer; index: int): ptr tuple[rateIdx: uint16] =
  addr rcStatsCounters(p).retrySlots[index]
proc rcRateConfig(p: pointer; index: int): uint16 = rcRateEntry(p, index.uint16).rateConfig
proc rcRateStats(p: pointer; index: int): ptr RateEntry = rcRateEntry(p, index.uint16)
proc rcU16(p: pointer; off: int): uint16 =
  doAssert off == RCS_N_RATES
  rcRateCapabilities(p).sampleCount
proc rcThroughputArray(p: pointer): ptr array[RC_MAX_RATE_ENTRIES, uint32] =
  cast[ptr array[RC_MAX_RATE_ENTRIES, uint32]](p)
proc rcU8(p: pointer; off: int): uint8 =
  doAssert off == RCS_ANOTHER_FLAG
  rotate
proc txlCaptureSession(d: ptr HostTxDescView): TxSessionIdentity =
  doAssert not interrupts
  TxSessionIdentity(captured: true, station: d.staInfoIdx, vif: d.vifIdx,
    resetEpoch: txResetEpoch, stationEpoch: stationEpochs[d.staInfoIdx],
    vifEpoch: rxVifEpochs[d.vifIdx])
proc txlSessionCurrent(s: TxSessionIdentity; d: ptr HostTxDescView): bool =
  doAssert not interrupts
  s == txlCaptureSession(d)
proc rf_dump_status() =
  inc dumps
  if onDump != nil: onDump()
proc txControlEnv(): ptr tuple[packetCounter: uint32] = addr txCtrl
proc txCfmList(ac: uint32): ptr CoList = addr confirmList
proc ke_evt_clear(mask: uint32) = ke_env[0] = ke_env[0] and not mask
proc ke_evt_set(mask: uint32) = ke_env[0] = ke_env[0] or mask
proc co_list_pop_front(list: ptr CoList): ptr CoListHdr =
  doAssert not interrupts
  result = list.first
  list[] = default(CoList)
proc txlFlushScopeExit(previous: ptr TxFlushBatch) = txActiveFlush = previous
proc txu_cntrl_cfm(p: pointer) =
  doAssert not interrupts
  inc done
proc ipc_emb_txcfm(p: pointer) =
  doAssert not interrupts and done == 1 and txCtrl.packetCounter == 0
proc ipc_emb_txcfm_ind(mask: uint32) =
  doAssert interrupts
  inc noticed
proc nimFwTrace2U32(s: string; a, b: uint32) = discard
"""

CHECKS = r"""
const
  ackFirst = 0x80800000'u32
  ackFourth = 0x80800300'u32
  ackFifth = 0x80800400'u32
  ackSixth = 0x80800500'u32
  exhausted = 0x80010700'u32

let d = cast[ptr IpcHostTxWrapperView](cast[uint](addr ipcSharedEnv[0]) + 6932).txDesc.addr
let node = cast[ptr CoListHdr](d)
var owner: TxFlushBatch

proc resetFrame(status: uint32; first = 0x1207'u32; second = 0x0400'u32) =
  setup()
  interrupts = false
  info = 0
  rotate = 0
  onDump = nil
  rcTrialSerial = default(typeof(rcTrialSerial))
  txRateTrialTag = default(typeof(txRateTrialTag))
  rcRateSampleEpoch = default(typeof(rcRateSampleEpoch))
  txRateSampleTag = default(typeof(txRateSampleTag))
  d[] = default(HostTxDescView)
  d.queueFirst = cast[pointer](1)
  d.hwDesc = addr d.aggDescPtr
  d.aggDescPtr = TxHardware(head: addr d.aggDescStorage[0], magic: 0xCAFE_BABE'u32,
                            ackPolicyControl: 0x2200, chainedThd: addr d.rateTemplate)
  d.aggDescStorage[0].flags = status
  d.rateTemplate = HostTxRateTemplateView(magic: 0xBADC_AB1E'u32, policyWord: 0xFFFF0704'u32,
    rateWord: 0x8000_0000'u32 or first, retryRateControl0: 0x8000_0000'u32 or second)
  stats[0].entries[0].rateConfig = 0x0400
  stats[0].entries[1].rateConfig = 0x040A
  stats[0].entries[2].rateConfig = 0x1207
  stats[0].entries[3].rateConfig = 0x0403
  stats[0].capabilities.fixedRate = 0xFFFF
  d.policy = addr d.rateTemplate
  stations[0].txPolicy = d.policy
  stats[0].retrySlots[0].rateIdx = 2
  stats[0].retrySlots[1].rateIdx = 0
  owner.confirmations.first = node

# rc.o:rc_init seeds two 2-Mbps samples. The cold chain chooses entry 1.
# The second physical slot can name entry 0 even with the same rate word.
proc duplicateRates(status: uint32; rotation = 0'u8) =
  resetFrame(status, first = 0x0001, second = 0x0001)
  stats[0].capabilities.sampleCount = 2
  stats[0].entries[0].rateConfig = 0x0001
  stats[0].entries[1].rateConfig = 0x0001
  rotate = rotation
  stats[0].retrySlots[rotation].rateIdx = 1
  stats[0].retrySlots[(rotation + 1) and 3].rateIdx = 0

for rotation in 0'u8 .. 3:
  for status in [ackFirst, ackFifth, ackSixth, exhausted]:
    duplicateRates(status, rotation)
    txlTagRateFeedback(d, addr d.rateTemplate)
    # Rebuilding the retry chain does not change the physical slots already queued.
    stats[0].retrySlots[rotation].rateIdx = 0
    stats[0].retrySlots[(rotation + 1) and 3].rateIdx = 1
    let feedback = txlCaptureRateFeedback(d)
    doAssert txRateSampleTag[0] == 0
    txlApplyRateFeedback(feedback, addr owner, node)
    doAssert stats[0].entries[1].attempts == (if status == ackFirst: 1'u16 else: 5'u16)
    doAssert stats[0].entries[1].successes == (status in [ackFirst, ackFifth]).uint16
    doAssert stats[0].entries[0].attempts == (if status == exhausted: 3'u16
      elif status == ackSixth: 1'u16 else: 0'u16)
    doAssert stats[0].entries[0].successes == (status == ackSixth).uint16

# The fifth ACK still belongs to the primary rate. The sixth is the first
# possible fallback ACK under the normal eight-attempt BL808 policy.
for attempts in 1'u32 .. 8:
  resetFrame(0x80800000'u32 or ((attempts - 1) shl 8))
  txlTagRateFeedback(d, addr d.rateTemplate)
  txlApplyRateFeedback(txlCaptureRateFeedback(d), addr owner, node)
  doAssert stats[0].entries[2] == RateEntry(rateConfig: 0x1207,
    attempts: min(attempts, 5).uint16, successes: (attempts <= 5).uint16)
  doAssert stats[0].entries[0] == RateEntry(rateConfig: 0x0400,
    attempts: (attempts - min(attempts, 5)).uint16, successes: (attempts > 5).uint16)

# Pending/foreign policies have no authoritative slot identity. The duplicate
# encoding is ambiguous, even if the current retry chain happens to select it.
for foreign in [false, true]:
  duplicateRates(ackFirst)
  if foreign: stations[0].txPolicy = nil
  else: stations[0].txPolicyUpdateFlags[0] = StaTxPolicyUpdateRateControl
  txlTagRateFeedback(d, addr d.rateTemplate)
  txlApplyRateFeedback(txlCaptureRateFeedback(d), addr owner, node)
  for i in 0 .. 1: doAssert stats[0].entries[i].attempts == 0

# Replacing a sample can reintroduce the exact same encoding. Test invalidation
# on both sides of the capture/IRQ boundary, including a now-unique encoding.
for afterCapture in [false, true]:
  duplicateRates(ackFirst)
  txlTagRateFeedback(d, addr d.rateTemplate)
  proc replaceSamples() =
    rcInvalidateRateSamples(addr stats[0])
    stats[0].entries[0].rateConfig = 0x0400
  if not afterCapture: replaceSamples()
  let feedback = txlCaptureRateFeedback(d)
  if afterCapture: replaceSamples()
  txlApplyRateFeedback(feedback, addr owner, node)
  for i in 0 .. 1: doAssert stats[0].entries[i].attempts == 0

# A sort can move a different equal-encoding sample into the submitted index.
duplicateRates(ackFirst)
stats[0].capabilities.sampleCount = 3
stats[0].entries[0].rateConfig = 0x0400
stats[0].entries[2].rateConfig = 0x0001
txlTagRateFeedback(d, addr d.rateTemplate)
let beforeSort = txlCaptureRateFeedback(d)
var duplicateTp: array[RC_MAX_RATE_ENTRIES, uint32]
duplicateTp[1] = 10
rc_sort_samples_tp(addr stats[0], addr duplicateTp)
doAssert rcRateSampleEpoch[0] == 1
txlApplyRateFeedback(beforeSort, addr owner, node)
for i in 0 .. 2: doAssert stats[0].entries[i].attempts == 0

# A pure sort can move a unique sample without invalidating the generation.
# Its submitted word remains authoritative even after a policy overwrite.
resetFrame(ackSixth)
txlTagRateFeedback(d, addr d.rateTemplate)
let captured = txlCaptureRateFeedback(d)
var uniqueTp = [0'u32, 5, 1, 10, 0, 0, 0, 0, 0, 0]
rc_sort_samples_tp(addr stats[0], addr uniqueTp)
doAssert rcRateSampleEpoch[0] == 0
d.rateTemplate.rateWord = 0x8000040A'u32
txlApplyRateFeedback(captured, addr owner, node)
doAssert stats[0].entries[1].attempts == 5 and stats[0].entries[1].successes == 0
doAssert stats[0].entries[0].attempts == 1 and stats[0].entries[0].successes == 1
doAssert stats[0].entries[2].attempts == 0 and stats[0].entries[3].attempts == 0
resetFrame(ackSixth, first = 0x1007'u32)
txlTagRateFeedback(d, addr d.rateTemplate)
txlApplyRateFeedback(txlCaptureRateFeedback(d), addr owner, node)
doAssert stats[0].entries[0].attempts == 1 and stats[0].entries[0].successes == 1
for i in 1 .. 3: doAssert stats[0].entries[i].attempts == 0
resetFrame(exhausted, first = 0x0400'u32)
txlTagRateFeedback(d, addr d.rateTemplate)
txlApplyRateFeedback(txlCaptureRateFeedback(d), addr owner, node)
doAssert stats[0].entries[0].attempts == 8 and stats[0].entries[0].successes == 0

# The pinned reference can end a new trial using a completion from an older
# policy. Only a frame that actually exercised the new trial may end it here.
for submittedTrial in [false, true]:
  resetFrame(exhausted, second = if submittedTrial: 0x040A'u32 else: 0x0400'u32)
  if not submittedTrial:
    txlTagRateFeedback(d, addr d.rateTemplate)
  stats[0].updateStage = 2
  stats[0].retrySlots[1].rateIdx = 1
  info = 2
  rcTrialSerial[0] = 7
  if submittedTrial:
    txlTagRateFeedback(d, addr d.rateTemplate)
  txlApplyRateFeedback(txlCaptureRateFeedback(d), addr owner, node)
  doAssert stats[0].updateStage == (if submittedTrial: 3'u8 else: 2'u8)
  doAssert stats[0].entries[2].attempts == 5
  doAssert stats[0].entries[0].attempts == (if submittedTrial: 0'u16 else: 3'u16)
  doAssert stats[0].entries[1].attempts == (if submittedTrial: 3'u16 else: 0'u16)
  for i in 0 .. 2: doAssert stats[0].entries[i].successes == 0

# Two in-flight frames can sample the same trial before either completes.
let late = cast[ptr IpcHostTxWrapperView](cast[uint](addr ipcSharedEnv[0]) + 6932 + 620).txDesc.addr
let lateNode = cast[ptr CoListHdr](late)
for change in ["none", "serial", "invalidated", "epoch", "pending policy", "policy owner", "rate word"]:
  resetFrame(exhausted)
  stats[0].updateStage = 2
  info = 2
  rcTrialSerial[0] = 7
  let otherStation = stats[1]
  late[] = d[]
  late.hwDesc = addr late.aggDescPtr
  late.aggDescPtr.head = addr late.aggDescStorage[0]
  late.aggDescPtr.chainedThd = addr late.rateTemplate
  txlTagRateFeedback(d, addr d.rateTemplate)
  txlTagRateFeedback(late, addr late.rateTemplate)
  doAssert txRateTrialTag[0] != 0 and txRateTrialTag[0] == txRateTrialTag[1]
  txlApplyRateFeedback(txlCaptureRateFeedback(d), addr owner, node)
  doAssert stats[0].updateStage == 3
  doAssert rcArmedRateTrial(0, addr stats[0]).tag == 0
  doAssert stats[0].entries[2].attempts == 5 and stats[0].entries[0].attempts == 3

  case change
  of "serial":
    inc rcTrialSerial[0]
    stats[0].updateStage = 2 # A replacement trial must not finish.
  of "invalidated": rcInvalidateTrialTag(0)
  of "epoch": rcInvalidateRateSamples(addr stats[0])
  of "pending policy": stations[0].txPolicyUpdateFlags[0] = StaTxPolicyUpdateRateControl
  of "policy owner": stations[0].txPolicy = addr late.rateTemplate
  of "rate word": late.rateTemplate.retryRateControl0 = 0x8000040A'u32
  else: discard

  owner.confirmations.first = lateNode
  txlApplyRateFeedback(txlCaptureRateFeedback(late), addr owner, lateNode)
  doAssert stats[0].totalAttempts == 2
  doAssert stats[0].updateStage == (if change == "serial": 2'u8 else: 3'u8)
  doAssert stats[0].entries[2].attempts == (if change == "epoch": 5'u16 else: 10'u16)
  doAssert stats[0].entries[0].attempts == (if change == "none": 6'u16 else: 3'u16),
    "incorrect credit for the second trial completion: " & change
  doAssert stats[0].entries[1].attempts == 0
  for entry in stats[0].entries: doAssert entry.successes == 0
  doAssert stats[1] == otherStation

for rotation in [0'u8, 1]:
  for status in [ackFirst, ackFourth, ackFifth, ackSixth]:
    for kind in 0 .. 5:
      resetFrame(status)
      # Logical slot one is the trial. Rotation can move it to slot zero.
      stats[0].updateStage = 2
      info = 2
      rotate = rotation
      stats[0].retrySlots[1].rateIdx = if rotation == 0: 0'u16 else: 2'u16
      rcTrialSerial[0] = 7
      if kind == 1:
        # A per-frame override changed the sampled slot before submission.
        if rotation == 0: d.rateTemplate.retryRateControl0 = 0x8000040A'u32
        else: d.rateTemplate.rateWord = 0x8000040A'u32
      txlTagRateFeedback(d, addr d.rateTemplate)
      doAssert (txRateTrialTag[0] != 0) == (kind != 1)
      if kind == 2: inc rcTrialSerial[0] # same rate and slot, a new generation
      if kind == 3:
        # A hardware preparation override changed the sampled word after tag.
        if rotation == 0: d.rateTemplate.retryRateControl0 = 0x8000040A'u32
        else: d.rateTemplate.rateWord = 0x8000040A'u32
      let feedback = txlCaptureRateFeedback(d)
      doAssert txRateTrialTag[0] == 0
      if kind == 4: owner.confirmations.first = nil
      if kind == 5: rcInvalidateTrialTag(0)
      txlApplyRateFeedback(feedback, addr owner, node)
      let reached = rotation == 1 or status == ackSixth
      doAssert stats[0].updateStage == (if kind == 0 and reached: 3'u8 else: 2'u8)
      doAssert stats[0].totalAttempts == uint16(kind != 4)
      if reached and kind == 1:
        doAssert stats[0].entries[1].attempts != 0
      if reached and kind in [2, 3, 5]:
        let retired = if rotation == 0: 0 else: 2
        doAssert stats[0].entries[retired].attempts == 0

# The station policy's MCS substitution is distinct from a per-frame override.
# At each rotation, only the trial's physical slot may keep the trial armed.
for rotation in 0'u8 .. 3:
  for wantMatch in [false, true]:
    resetFrame(exhausted, second = 0x1207)
    stats[0].entries[1].rateConfig = 0x1202
    stats[0].updateStage = 2
    stats[0].retrySlots[1].rateIdx = 1
    info = 2
    rotate = rotation
    rcTrialSerial[0] = 7
    var words = [0x80001207'u32, 0x80001207'u32, 0x80001202'u32, 0x80001207'u32]
    let physical = (5 - rotation.int) and 3
    if physical == 2: words[0] = 0x80001202'u32
    words[physical] = if wantMatch: 0x80001202'u32 else: 0x80001207'u32
    rcRejectUnprogrammedTrial(0, addr stats[0], words)
    doAssert stats[0].updateStage == (if wantMatch: 2'u8 else: 3'u8)
    doAssert rcTrialSerial[0] == (if wantMatch: 7'u32 else: 0x80000007'u32)
    doAssert stats[0].entries[1].attempts == 0
    if not wantMatch:
      txlTagRateFeedback(d, addr d.rateTemplate)
      doAssert txRateTrialTag[0] == 0
      txlApplyRateFeedback(txlCaptureRateFeedback(d), addr owner, node)
      doAssert stats[0].entries[1].attempts == 0 and stats[0].entries[2].attempts == 8

# The pinned confirmation counts every reported attempt as a failure on the
# retry-limit path, including a short completion. Only reached slots count.
for attempts in 1'u32 .. 8:
  resetFrame(0x80010000'u32 or ((attempts - 1) shl 8))
  stats[0].updateStage = 2
  info = 2
  rcTrialSerial[0] = 7
  txlTagRateFeedback(d, addr d.rateTemplate)
  let feedback = txlCaptureRateFeedback(d)
  doAssert feedback.attempts.uint32 == attempts and feedback.failed
  txlApplyRateFeedback(feedback, addr owner, node)
  doAssert stats[0].entries[2].attempts.uint32 == min(attempts, 5'u32)
  doAssert stats[0].entries[0].attempts.uint32 == attempts - min(attempts, 5'u32)
  doAssert stats[0].entries[0].successes == 0 and stats[0].entries[2].successes == 0
  doAssert stats[0].updateStage == (if attempts > 5: 3'u8 else: 2'u8)

# Software/unfinished, ambiguous completion, lifetime, RTS and unsupported
# retry budgets never update the sample table or consume a trial.
for status in [0x00000000'u32, 0x40000000'u32, 0xC0080000'u32, 0x80020000'u32,
               0x80000000'u32, 0x80810000'u32, 0x80800800'u32, 0x80010800'u32,
               0x80800001'u32]:
  resetFrame(status)
  let before = stats[0]
  txlApplyRateFeedback(txlCaptureRateFeedback(d), addr owner, node)
  doAssert stats[0] == before
for kind in 0 .. 6:
  resetFrame(ackSixth)
  case kind
  of 0: d.aggDescPtr.ackPolicyControl = 0
  of 1: d.aggDescPtr.chainedThd = nil
  of 2: d.rateTemplate.policyWord = 0xFFFF0304'u32
  of 3: d.aggDescPtr.head = nil
  of 4: d.rateTemplate.retryRateControl0 = 0
  of 5: d.rateTemplate.rateWord = 0xA0001207'u32
  else: d.rateTemplate.retryRateControl0 = 0xC0000400'u32
  doAssert txlCaptureRateFeedback(d).attempts == 0
resetFrame(ackFifth)
d.rateTemplate.retryRateControl0 = 0
doAssert txlCaptureRateFeedback(d).attempts == 5
var internal: HostTxDescView
doAssert txlCaptureRateFeedback(addr internal).attempts == 0

# Rate diagnostics can retire the completion or restart the link.
for caseIndex in 0 .. 3:
  resetFrame(exhausted)
  let feedback = txlCaptureRateFeedback(d)
  let before = stats[0]
  interrupts = true
  onDump = proc() =
    doAssert interrupts
    case caseIndex
    of 0: inc txResetEpoch
    of 1: inc stationEpochs[0]
    of 2: inc rxVifEpochs[0]
    else: owner.confirmations.first = nil
  txlApplyRateFeedback(feedback, addr owner, node)
  doAssert dumps == 1 and interrupts and stats[0] == before

# Exercise the deployed event branch, including the IRQ boundary. The
# submitted words and slot identities must survive a reentrant policy update.
resetFrame(ackSixth)
txlTagRateFeedback(d, addr d.rateTemplate)
confirmList = CoList(first: node, last: node)
txCtrl.packetCounter = 1
ke_env[0] = txl_cfm_evt_bit[0]
interrupts = true
onRestore = proc() =
  doAssert txActiveFlush != nil and txActiveFlush.confirmations.first == node
  onRestore = nil
  d.rateTemplate.rateWord = 0x8000040A'u32
  stats[0].retrySlots[1].rateIdx = 3
txl_cfm_evt(0)
doAssert interrupts and done == 1 and noticed == 1
doAssert txActiveFlush == nil and confirmList.first == nil
doAssert stats[0].entries[2].attempts == 5 and stats[0].entries[2].successes == 0
doAssert stats[0].entries[0].attempts == 1 and stats[0].entries[0].successes == 1
doAssert stats[0].entries[3].attempts == 0
"""


@pytest.mark.parametrize("mode", ["checked", "firmware", "asan"])
def test_native_frame_rate_feedback(tmp_path: Path, mode: str) -> None:
    source = (FW / "tx_layer.nim").read_text()
    rates = (FW / "rate_control.nim").read_text()
    consts = "when defined(bl808m0):\n  const\n    TxFeedbackRateMask"
    feedback = "when defined(bl808m0):\n  type TxRateFeedback"
    bodies = consts + source.split(consts, 1)[1].split("proc txlPrepareBuffer", 1)[0]
    bodies += feedback + source.split(feedback, 1)[1].split("proc txlCfmPending", 1)[0]
    bodies += procedure(source, "txlCfmPending") + procedure(source, "txl_cfm_evt")
    invalidation = "when defined(bl808m0):\n  proc rcInvalidateTrialTag"
    bodies = invalidation + rates.split(invalidation, 1)[1].split("proc rcTryInitStation", 1)[0] + bodies
    epochs = "when defined(bl808m0):\n  proc rcInvalidateRateSamples"
    bodies = (epochs + rates.split(epochs, 1)[1].split("proc rc_count_samples", 1)[0]
              + procedure(rates, "rc_sort_samples_tp") + bodies)
    bodies = procedure(rates, "rcAccountCounters") + bodies
    names = sorted(set(re.findall(r"\bnimFwDbg\w+\b", bodies)))
    debug = "\nvar\n" + "".join(f"  {name}: uint32\n" for name in names)
    code = RATE_PLATFORM.split("type\n", 1)[0] + DESCRIPTORS + "type\n  RateEntry"
    code += RATE_PLATFORM.split("  RateEntry", 1)[1].replace(
        "sampleCount: uint16", "sampleCount, fixedRate: uint16", 1).replace(
        "rcStats: pointer", "rcStats, txPolicy: pointer", 1)
    code = code.replace(procedure(code, "hostTxHwDescAt"), "")
    code = code.replace(procedure(code, "hostTxHeadThd"), "")
    code = code.replace(procedure(code, "rf_dump_status"), "")
    code = code.replace(procedure(code, "irqRestore"), r"""
var onRestore: proc()
proc irqRestore(saved: uint32) =
  interrupts = (saved and 8) != 0
  if interrupts and onRestore != nil: onRestore()
""", 1)
    run_program(tmp_path, mode, code + "\nconst RC_STATS_SIZE = sizeof(Stats)\n"
                "const RCS_N_RATES = 192\ntemplate rcStaStatsPool: untyped =\n"
                "  bind stats\n  stats\n"
                + SUPPORT + debug + bodies + CHECKS, defines=("bl808m0",))
