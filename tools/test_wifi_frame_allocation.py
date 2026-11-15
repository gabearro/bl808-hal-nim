"""Exercise the real internal TX allocator across reuse and exhaustion."""

from pathlib import Path
import re
import shutil
import subprocess

import pytest

from test_wifi_frame_ownership import CALLBACK_STUBS, PLATFORM as OWNERSHIP_PLATFORM


ROOT = Path(__file__).resolve().parents[1]

PLATFORM = OWNERSHIP_PLATFORM.replace(CALLBACK_STUBS, "").replace(
    "proc txlFrameEndLease(d: ptr HostTxDescView) = discard\n", ""
).replace(
    "callback, callbackArg, bufDesc: pointer",
    "callback, callbackArg, bufDesc, hwDesc, queueFirst: pointer",
).replace(
    "    macHeader: array[24, uint8]",
    "    rateTemplate: array[52, uint8]\n    macHeader: array[512, uint8]",
)
PLATFORM += r"""
const TxlFramePayloadSize = 512'u32
const MAX_VIFS = 2
const STA_MGMT_FREE_STAS = 5
type
  TxFrameIdentity = object
    generation, resetEpoch: uint32
    leased: bool
    vifEpochs: array[MAX_VIFS, uint32]
    stationEpochs: array[STA_MGMT_FREE_STAS, uint32]
  TxFrameCallbackScope = object
    previous: ptr TxFrameCallbackScope
    identity: TxFrameIdentity
    vif, station: uint8
    tracked, beacon: bool
  HwDesc = object
    payloadStart, payloadEnd, frameLen: uint32
    chainedThd: pointer
    retryLimitControl, controlFlags, status: uint32
    confirmStatus: uint32
  RateTemplate = object
    prefix: array[5, uint32]
    rateWord: uint32
    retryRates: array[3, uint32]
    txPower: int32
    retryPowers: array[3, uint32]
var
  links: array[4, LinkDesc]
  hardware: array[4, HwDesc]
  txl_buffer_control_24G: array[52, uint8]
  flushes, agingCalls, powerCalls: int
  powerRate: uint32
  rxVifEpochs: array[MAX_VIFS, uint32]
  stationEpochs: array[STA_MGMT_FREE_STAS, uint32]
  txFrameIdentities: array[4, TxFrameIdentity]
  txFrameGeneration: uint32
  txResetEpoch: uint32
  mmBcnGeneration: uint32
  txActiveFrameCallback: ptr TxFrameCallbackScope
  onRecovery: proc()
  clearAllowed = true

proc hostTxHwDescAt(p: pointer): ptr HwDesc = cast[ptr HwDesc](p)
proc txlResetting(): bool = false
proc mm_bcn_transmitted(vifEntry: pointer) = discard
proc txlFrameLinkDescAt(i: uint32): ptr LinkDesc = addr links[i]
proc hostTxRateTemplate(p: ptr LinkDesc): ptr RateTemplate =
  cast[ptr RateTemplate](addr p.rateTemplate[0])
proc blOpsFunc(index: int): pointer = nil
proc staDeleteEpoch(station: uint8): uint32 =
  if station < STA_MGMT_FREE_STAS: stationEpochs[station] else: 0
proc nimFwTrace2U32(s: string; a, b: uint32) = discard
proc c_memcpy(dst, src: pointer; size: csize_t): pointer =
  copyMem(dst, src, size.int)
  dst
proc co_list_cnt(list: ptr CoList): uint32 =
  var node = list.first
  while node != nil:
    inc result
    doAssert result <= 4
    node = node.next
proc tpc_get_vif_tx_power_vs_rate(rate: uint32): int32 =
  inc powerCalls
  powerRate = rate
  -17
proc txl_cntrl_clear_ac(ac: uint8): bool =
  doAssert ac == 3
  inc flushes
  if onRecovery != nil: onRecovery()
  clearAllowed
proc sta_mgmt_aging_postponed_desc(sta: pointer; maxCount: uint32): uint32

proc initPool() =
  reset()
  links = default(typeof(links))
  hardware = default(typeof(hardware))
  flushes = 0
  agingCalls = 0
  powerCalls = 0
  rxVifEpochs = default(typeof(rxVifEpochs))
  stationEpochs = default(typeof(stationEpochs))
  txFrameIdentities = default(typeof(txFrameIdentities))
  txFrameGeneration = 0
  mmBcnGeneration = 0
  txActiveFrameCallback = nil
  onRecovery = nil
  clearAllowed = true
  for i in 0 ..< txl_buffer_control_24G.len:
    txl_buffer_control_24G[i] = (i * 3).uint8
  for i in 0'u32 ..< 4:
    txlFrameDescAt(i).bufDesc = addr links[i]
    txlFrameDescAt(i).hwDesc = addr hardware[i]
"""

COMMON_CHECKS = r"""
proc checkGeometry(desc: ptr HostTxDescView; length: uint32) =
  let hw = hostTxHwDescAt(desc.hwDesc)
  let link = hostTxLinkDescAt(desc.bufDesc)
  let start = pointerAddrU32(addr link.macHeader[0])
  doAssert hw.payloadStart == start
  doAssert hw.payloadEnd == start + length - 1
  doAssert hw.frameLen == length + 4
  doAssert hw.chainedThd == cast[pointer](hostTxRateTemplate(link))
  doAssert hw.retryLimitControl == 0 and hw.controlFlags == 0 and hw.status == 0
  doAssert desc.callback == nil and desc.callbackArg == nil
  doAssert desc.usedFlag == 0 and desc.queueFirst == nil
  var expected = txl_buffer_control_24G
  cast[ptr RateTemplate](addr expected[0]).txPower = -17
  doAssert link.rateTemplate == expected
  doAssert powerRate == cast[ptr RateTemplate](addr expected[0]).rateWord
"""

CHECKS = {
    "halt_failure": r"""
initPool()
var held: pointer
for i in 0'u32 ..< 4:
  held = txl_frame_get(24)
let before = hostTxDescAt(held)[]
let powers = powerCalls
clearAllowed = false
onRecovery = proc() =
  co_list_push_back(addr frameEnv.freeList, cast[ptr CoListHdr](held))
doAssert txl_frame_get(24) == nil
doAssert hostTxDescAt(held)[] == before and powerCalls == powers
doAssert frameEnv.freeList.first == cast[ptr CoListHdr](held)
doAssert flushes == 1 and interruptsEnabled
""",
    "reuse": r"""
for expired in [false, true]:
  for oldTime in [1'u32, 0xFFFFFF00'u32]:
    initPool()
    var leased: array[4, pointer]
    for i in 0 ..< 4:
      leased[i] = txl_frame_get(24)
      doAssert leased[i] == cast[pointer](txlFrameDescAt(i.uint32))
    let reused = hostTxDescAt(leased[0])
    reused.pendingMacTime = oldTime
    reused.postponeFlag = 1
    reused.retryFlag = 1
    hardware[0].payloadStart = 7
    hardware[0].retryLimitControl = 123
    hardware[0].controlFlags = 456
    hardware[0].status = 789
    reused.callback = cast[pointer](1)
    reused.callbackArg = cast[pointer](2)
    if expired:
      # Release through the actual station aging path, as pool pressure does.
      reused.callback = nil
      co_list_push_back(addr stas[0].postponedList, addr reused.link)
      frameEnv.postponedCount = 1
      macTime = oldTime + 120001'u32
      doAssert sta_mgmt_postponed_desc_release(addr stas[0], 0) == 1
    else:
      txl_frame_release(reused, false)
    doAssert txl_frame_get(26) == cast[pointer](reused)
    doAssert reused.pendingMacTime == 0, "recycled frame retains prior TX age"
    doAssert reused.postponeFlag == 0, "free frame retains postponed ownership"
    doAssert reused.retryFlag == 0, "recycled frame retains prior retry ownership"
    checkGeometry(reused, 26)
    doAssert frameEnv.postponedCount == 0
    doAssert frameEnv.freeList.first == nil
    doAssert flushes == 0
""",
    "bounds": r"""
for invalid in [0'u32, 513, 65535, 0xFFFFFFFC'u32, 0xFFFFFFFF'u32]:
  initPool()
  let first = frameEnv.freeList.first
  let last = frameEnv.freeList.last
  doAssert txl_frame_get(invalid) == nil, "invalid internal frame length accepted"
  doAssert frameEnv.freeList.first == first and frameEnv.freeList.last == last
  doAssert co_list_cnt(addr frameEnv.freeList) == 4
  doAssert flushes == 0 and agingCalls == 0 and powerCalls == 0
  # Invalid requests must not run recovery callbacks even when exhausted.
  for i in 0 ..< 4: discard txl_frame_free_list_pop(addr frameEnv.freeList)
  frameEnv.postponedCount = 1
  doAssert txl_frame_get(invalid) == nil
  doAssert flushes == 0 and agingCalls == 0 and powerCalls == 0
""",
    "geometry": r"""
for length in 1'u32 .. 512'u32:
  initPool()
  for i in 0'u32 ..< 4:
    # Preserve the existing repair for an internal descriptor's lost link.
    if i == 2: txlFrameDescAt(i).bufDesc = nil
    let desc = hostTxDescAt(txl_frame_get(length))
    doAssert desc == txlFrameDescAt(i)
    checkGeometry(desc, length)
  doAssert powerCalls == 4
  doAssert txl_frame_get(length) == nil
  doAssert flushes == 1 and powerCalls == 4
""",
    "pressure": r"""
for age in [120000'u32, 120001]:
  initPool()
  for i in 0'u32 ..< 4:
    let frame = hostTxDescAt(txl_frame_get(24))
    frame.pendingMacTime = 0xFFFFFF00'u32
    frame.postponeFlag = 1
    frame.retryFlag = 1
  let expired = txlFrameDescAt(0)
  co_list_push_back(addr stas[0].postponedList, addr expired.link)
  frameEnv.postponedCount = 1
  macTime = expired.pendingMacTime + age
  let frame = txl_frame_get(512)
  doAssert agingCalls == 1
  if age == 120000:
    doAssert frame == nil and frameEnv.postponedCount == 1
    doAssert stas[0].postponedList.first == addr expired.link
    doAssert expired.pendingMacTime == 0xFFFFFF00'u32
    doAssert expired.postponeFlag == 1 and expired.retryFlag == 1
    doAssert flushes == 1
  else:
    doAssert frame == cast[pointer](expired)
    doAssert expired.pendingMacTime == 0 and expired.postponeFlag == 0
    doAssert expired.retryFlag == 0
    doAssert stas[0].postponedList.first == nil and frameEnv.postponedCount == 0
    doAssert flushes == 0
    checkGeometry(expired, 512)
  for i in 1'u32 ..< 4:
    let held = txlFrameDescAt(i)
    doAssert held.pendingMacTime == 0xFFFFFF00'u32
    doAssert held.postponeFlag == 1 and held.retryFlag == 1
""",
}


@pytest.mark.parametrize("mode", CHECKS)
@pytest.mark.parametrize("release", [False, True])
def test_internal_frame_allocator(tmp_path: Path, mode: str, release: bool) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("Nim is required")
    base = ROOT / "src/bl808/wifi/fw"
    tx = (base / "tx_layer.nim").read_text()
    station = (base / "sta_management.nim").read_text()

    def procedure(source: str, name: str) -> str:
        match = re.search(
            r"(?ms)^proc " + re.escape(name) + r"(?=[*(]).*?(?=^proc |\Z)", source
        )
        assert match, name
        return match.group(0)

    functions = "\n".join(procedure(tx, name) for name in [
        "txl_frame_desc_index", "txlCaptureFrameIdentity", "txlFrameBeginLease",
        "txlFrameEndLease", "txlFrameLeaseToken", "txlFrameLeaseMatches",
        "txlFrameIdentityCurrent", "txlFrameSessionCurrent",
        "txlCaptureFrameCallback", "txlFrameCallbackCurrent", "txlInvokeFrameCallback",
        "txl_frame_free_list_pop", "txl_frame_get",
        "txl_frame_release",
    ])
    functions += procedure(station, "staPostponedListValid")
    functions += procedure(station, "staReleasePostponed")
    functions += procedure(station, "sta_mgmt_postponed_desc_release")
    functions += r"""
proc sta_mgmt_aging_postponed_desc(sta: pointer; maxCount: uint32): uint32 =
  inc agingCalls
  for index in 0 ..< stas.len:
    result += sta_mgmt_postponed_desc_release(addr stas[index], 0)
"""
    debug = "\nvar\n" + "".join(
        f"  {name}: uint32\n"
        for name in sorted(set(re.findall(r"\bnimFwDbg\w+", functions)))
    )
    source = tmp_path / "frame_allocation.nim"
    source.write_text(PLATFORM + debug + functions + COMMON_CHECKS + CHECKS[mode])
    command = [nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on",
               "--skipUserCfg:on", "--checks:on"]
    if release:
        command += ["-d:release", "--checks:on"]
    command += [f"--nimcache:{tmp_path / 'nimcache'}", f"-o:{tmp_path / 'test'}", str(source)]
    result = subprocess.run(command, cwd=ROOT, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    assert result.returncode == 0, result.stdout
