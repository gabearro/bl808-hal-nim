"""Exercise production BL808 rate initialization through its policy output."""

from pathlib import Path
import os
import shutil
import subprocess

import pytest

from test_wifi_disconnect_tx import procedure

ROOT = Path(__file__).resolve().parents[1]
FW = ROOT / "src/bl808/wifi/fw"

PLATFORM = r"""
const
  MAX_STAS = 10
  MAX_VIFS = 2
  MACHW_TIMLO_REG = 0x24B00120'u
var
  rcStaStatsPool: array[2000, uint8]
  me_env: array[64, uint8]
  rcPrngState: uint32
  rxVifEpochs: array[2, uint32]
proc rcU8(p: pointer; offset: int): var uint8 =
  cast[ptr uint8](cast[uint](p) + offset.uint)[]
proc rcU16(p: pointer; offset: int): var uint16 =
  cast[ptr uint16](cast[uint](p) + offset.uint)[]
proc rcU32(p: pointer; offset: int): var uint32 =
  cast[ptr uint32](cast[uint](p) + offset.uint)[]
proc c_memset(dst: pointer; value: cint; size: csize_t): pointer =
  for i in 0 ..< size.int: rcU8(dst, i) = value.uint8
  dst
proc c_memcpy(dst, src: pointer; size: csize_t): pointer =
  copyMem(dst, src, size.int)
  dst
"""

DEVICES = r"""
type MockSta = object
  infoIdx, valid, instNbr: uint8
  rcStats, txPolicy, vif: pointer
  capabilityFlags: uint32
  supportedRates: array[13, uint8]
  vhtCaps: array[32, uint8]
  supportedRatesBitmap: uint16
  nssBwMax: uint8
  txPolicyUpdateFlags: array[4, uint8]
var
  sta: MockSta
  policy: TxPolicyView
  legacyMap: uint16
  peerNss, localNss: uint8
  phyCalls, errors, nssCalls: int
  publishedBeforePhy, forceNoSample: bool
  macTime: uint32
  stationEpochs: array[5, uint32]
template staInfoAt(p: pointer): ptr MockSta = cast[ptr MockSta](p)
template txPolicyAt(p: pointer): ptr TxPolicyView = cast[ptr TxPolicyView](p)
proc staInfoForIdx(index: uint8): ptr MockSta =
  doAssert index == sta.infoIdx
  addr sta
proc staDeleteEpoch(index: uint8): uint32 = stationEpochs[index]
proc staDeleteIsCurrent(index: uint8; epoch: uint32): bool =
  stationEpochs[index] == epoch and sta.valid != 0
proc assert_err(a, b: cstring; line: cint) = inc errors
proc phy_get_ntx(): uint8 =
  if phyCalls == 0:
    publishedBeforePhy = sta.rcStats == (addr rcStaStatsPool[sta.infoIdx.int * RC_STATS_SIZE])
  else:
    doAssert policy.status == 0xBADCAB1E'u32
    doAssert policy.controlInfo == 0xFFFF0704'u32
  inc phyCalls
  if phyCalls == 1: 1'u8 else: 2'u8
proc phy_ldpc_tx_supported(): bool = true
proc me_legacy_rate_bitfield_build(p: pointer; basic: uint32): uint32 =
  doAssert p == (addr sta.supportedRates[0]) and basic == 0
  legacyMap.uint32
proc me_legacy_ridx_min(rates: uint32): uint8 =
  for i in 0 ..< 12:
    if (rates and (1'u32 shl i)) != 0: return i.uint8
  12
proc me_legacy_ridx_max(rates: uint32): uint8 =
  for i in countdown(11, 0):
    if (rates and (1'u32 shl i)) != 0: return i.uint8
  12
proc me_11n_nss_max(p: pointer): uint8 =
  inc nssCalls
  if p == addr me_env[11]: return localNss
  doAssert p == addr sta.vhtCaps[3]
  peerNss
proc regRead(address: uint): uint32 =
  doAssert address == MACHW_TIMLO_REG
  macTime
"""

CASES = r"""
proc setup(ht: bool; rates: uint16; preamble, bandwidth: uint8; htCap: uint16;
           remoteStreams: uint8 = 2; localStreams: uint8 = 1) =
  sta = default(MockSta)
  stationEpochs = default(typeof(stationEpochs))
  rxVifEpochs = default(typeof(rxVifEpochs))
  for i in 0 ..< rcStaStatsPool.len: rcStaStatsPool[i] = 0xA5
  for i in 0 ..< sizeof(policy): rcU8(addr policy, i) = 0xA5
  phyCalls = 0
  errors = 0
  nssCalls = 0
  publishedBeforePhy = false
  forceNoSample = false
  macTime = 0x98765432'u32
  rcPrngState = 12345
  legacyMap = rates
  peerNss = remoteStreams
  localNss = localStreams
  sta.infoIdx = 2
  sta.valid = 1
  sta.instNbr = 1
  sta.txPolicy = addr policy
  sta.vif = cast[pointer](0x12345678'u)
  sta.capabilityFlags = if ht: 2'u32 else: 0
  sta.supportedRatesBitmap = 0x800'u16 or (preamble.uint16 shl 10)
  sta.nssBwMax = bandwidth
  rcU16(addr sta.vhtCaps[0], 0) = htCap
  sta.vhtCaps[3] = 3
  sta.vhtCaps[4] = 15
  sta.vhtCaps[5] = 1
  sta.vhtCaps[6] = 128
  sta.txPolicyUpdateFlags = [0x80'u8, 0x81, 0x82, 0x83]

proc expectedCount(ht: bool; rates: uint16; preamble, gi: uint8): int =
  result = (rates and 1).int
  for i in 1 .. 3:
    if (rates and (1'u16 shl i)) != 0:
      result += (if preamble == 0: 2 else: 1)
  if ht:
    result += 8 * (1 + gi.int)
  else:
    for i in 4 .. 11:
      result += ((rates shr i) and 1).int
  result = min(result, 10)

proc verify(ht: bool; rates: uint16; preamble, bw: uint8; htCap: uint16;
            countOverride: int = 0) =
  rc_init(addr sta)
  doAssert errors == 0
  doAssert phyCalls == 2 and publishedBeforePhy
  let start = sta.infoIdx.int * RC_STATS_SIZE
  let stats = addr rcStaStatsPool[start]
  doAssert sta.rcStats == stats
  let caps = rcRateCapabilities(stats)
  let gi = if ht and ((bw == 0 and (htCap and 0x20) != 0) or
    (bw == 1 and (htCap and 0x40) != 0)): 1'u8 else: 0'u8
  let expected = if countOverride > 0: countOverride else: expectedCount(ht, rates, preamble, gi)
  doAssert rcU16(stats, RCS_N_RATES) == expected.uint16, "incorrect sample count"
  doAssert rcU32(stats, 0) == 0x98765432'u32, "initial timestamp was not stored"
  doAssert caps.formatMod == (if ht: 2'u8 else: 0'u8)
  doAssert caps.legacyRateMap == rates, "legacy capabilities were fabricated"
  doAssert caps.preambleType == preamble and caps.maxBandwidth == bw
  doAssert caps.shortGi == gi
  if ht:
    doAssert caps.maxNss == min(peerNss, localNss)
    doAssert caps.mcsBitmaps == [0xFF'u8, 15, 1, 128]
    doAssert caps.maxMcs == 7
    doAssert rcU16(stats, 194) == (if (htCap and 0x800) != 0: 0x1EFF'u16 else: 0xEFF'u16)
    doAssert nssCalls == 2
  else:
    doAssert caps.maxMcs == 255 and nssCalls == 0
  doAssert rcStatsCounters(stats).retryLimit == 5
  doAssert rcStatsCounters(stats).fixedRate == 0xFFFF
  doAssert rcAmpduStats(stats).averageLengthQ16 == 65536
  for i in 0 ..< expected:
    let config = rcRateStats(stats, i).rateConfig
    doAssert config != 0xFFFF and rc_check_valid_rate(stats, config) != 0
    for j in 0 ..< i: doAssert config != rcRateStats(stats, j).rateConfig
  for step in 0 ..< 4:
    let index = rcRetryStep(stats, step).rateIdx.int
    doAssert index < expected
    doAssert policy.retryRate[step] == (0x80000000'u32 or rcRateStats(stats, index).rateConfig.uint32)
    doAssert policy.txPower[step] == 0xA5A5A5A5'u32
  doAssert policy.status == 0xBADCAB1E'u32
  doAssert policy.bufferAddr == ((1'u32 shl 14) or (if ht and (htCap and 1) != 0: 64'u32 else: 0'u32))
  doAssert policy.bufferMask == 7 and policy.packetType == (sta.infoIdx.uint32 + 8) shl 10
  doAssert policy.controlInfo == 0xFFFF0704'u32
  doAssert policy.edcaParam0 == 0x2200 and policy.edcaParam1 == 0x12345678
  doAssert sta.txPolicyUpdateFlags == [0x91'u8, 0x81, 0x82, 0x83]
  for i in 0 ..< rcStaStatsPool.len:
    if i < start or i >= start + 200: doAssert rcStaStatsPool[i] == 0xA5

var countState: array[200, uint8]
let countStats = addr countState[0]
let countCaps = rcRateCapabilities(countStats)
for bitmap in 0'u32 .. 65535'u32:
  for preamble in [0'u8, 1]:
    countCaps.formatMod = 0
    countCaps.legacyRateMap = bitmap.uint16
    countCaps.preambleType = preamble
    let cck = (bitmap and 1).int + countSetBits(bitmap and 14) * (2 - preamble.int)
    doAssert rc_count_samples(countStats) == min(cck + countSetBits(bitmap and 0xFF0), 10).uint16
for cck in 0'u16 .. 15'u16:
  for bitmap in 0'u16 .. 255'u16:
    for preamble in [0'u8, 1]:
      for gi in [0'u8, 1]:
        countCaps.formatMod = 2
        countCaps.legacyRateMap = cck or 0xFFF0
        countCaps.preambleType = preamble
        countCaps.shortGi = gi
        countCaps.maxBandwidth = 3
        countCaps.maxNss = 3
        countCaps.mcsBitmaps = [bitmap.uint8, 255'u8, 255'u8, 255'u8]
        let expected = (cck and 1).int + countSetBits(cck and 14) * (2 - preamble.int) +
          countSetBits(bitmap) * (1 + gi.int)
        doAssert rc_count_samples(countStats) == min(expected, 10).uint16
doAssert rc_count_samples(nil) == 0 and not rc_seed_rate_table(nil)
countCaps.sampleCount = 11
let beforeInvalidSeed = countState
doAssert not rc_seed_rate_table(countStats)
doAssert countState == beforeInvalidSeed

for ht in [false, true]:
  for rates in [0xF'u16, 2, 0xFF0, 0xFFF]:
    for preamble in [0'u8, 1]:
      for bandwidth in 0'u8 .. (if ht: 3'u8 else: 0'u8):
        for htCap in [0'u16, 0x21, 0x40, 0x861]:
          setup(ht, rates, preamble, bandwidth, htCap)
          verify(ht, rates, preamble, bandwidth, htCap)
setup(true, 0, 0, 0, 0)
verify(true, 0, 0, 0, 0)
for remote in 0'u8 .. 3'u8:
  for local in 0'u8 .. 3'u8:
    setup(true, 0xFF0, 0, 1, 0x861, remote, local)
    verify(true, 0xFF0, 0, 1, 0x861)
for index in 0'u8 .. 4'u8:
  setup(false, 0xFFF, 0, 0, 0)
  sta.infoIdx = index
  verify(false, 0xFFF, 0, 0, 0)
setup(false, 0xFFF, 0, 0, 0)
forceNoSample = true
verify(false, 0xFFF, 0, 0, 0, 2)
setup(false, 2, 0, 0, 0)
forceNoSample = true
verify(false, 2, 0, 0, 0, 1)

setup(false, 0, 0, 0, 0)
rc_init(addr sta)
doAssert errors > 0 and rcU16(sta.rcStats, RCS_N_RATES) == 0
doAssert policy.status == 0xA5A5A5A5'u32
setup(true, 0xFFF, 0, 0, 0, 4, 4)
rc_init(addr sta)
doAssert errors > 0 and policy.status == 0xA5A5A5A5'u32
setup(false, 0xFFF, 0, 0, 0)
sta.infoIdx = 5
rc_init(addr sta)
doAssert errors > 0 and phyCalls == 0 and sta.rcStats == nil
for value in rcStaStatsPool: doAssert value == 0xA5
setup(false, 0xFFF, 0, 0, 0)
sta.txPolicy = nil
rc_init(addr sta)
doAssert errors > 0 and phyCalls == 0
rc_init(nil)

# Use the real generation/math/update stack across a complete probe/restore
# cycle and the next periodic update; device/parser boundaries remain mocked.
for ht in [false, true]:
  setup(ht, 0xFFF, 0, 0, 0x21)
  rc_init(addr sta)
  let stats = sta.rcStats
  let oldFirst = rcRetryStep(stats, 0)[]
  let oldSecond = rcRetryStep(stats, 1)[]
  rcTrialControl(stats).status = 1
  rcRateStats(stats, 1).sampleSkipped = 32
  sta.txPolicyUpdateFlags[0] = 0
  rcPrngState = ((1'u32 shl 16) - 0x3039'u32) * 0xEEB9EB65'u32
  rc_check(sta.infoIdx)
  doAssert rcTrialControl(stats).status == 2
  doAssert sta.txPolicyUpdateFlags[0] == StaTxPolicyUpdateRateControl
  rcTrialControl(stats).status = 3
  sta.txPolicyUpdateFlags[0] = 0
  rc_check(sta.infoIdx)
  doAssert rcRetryStep(stats, 0)[] == oldFirst and rcRetryStep(stats, 1)[] == oldSecond
  doAssert rcTrialControl(stats).status == 0
  macTime += RC_UPDATE_INTERVAL + 1
  rc_check(sta.infoIdx)
  doAssert rcU32(stats, 0) == macTime
  doAssert rcTrialControl(stats).status == 0 and rcTrialControl(stats).softwareRetryStep == 0
  for slot in 0 ..< 4:
    doAssert rcRetryStep(stats, slot).rateIdx < rcRateCapabilities(stats).sampleCount
  doAssert errors == 0
"""


def source() -> str:
    layout = (FW / "layout_types.nim").read_text()
    helpers = (FW / "runtime_helpers.nim").read_text()
    source = (FW / "rate_control.nim").read_text()
    code = "import std/bitops\n" + (FW.parent / "fw_constants/rate_control.nim").read_text()
    code += layout.split("# Linked list node", 1)[0]
    code += PLATFORM + "\ntype\n  RcRateEntryView" + layout.split("  RcRateEntryView", 1)[1].split("  TxFrameEnvView", 1)[0]
    code += "\ntype\n  TxPolicyView" + layout.split("  TxPolicyView", 1)[1].split("  MichaelMicContextView", 1)[0]
    code += DEVICES
    code += "\ntemplate rcPrngNext" + helpers.split("template rcPrngNext", 1)[1].split("proc rcRateEntryPtr", 1)[0]
    code += "\ntemplate rcRateEntryAt" + helpers.split("template rcRateEntryAt", 1)[1].split("proc rcClearRateEntryTransientStats", 1)[0]
    for name in ["rcRateConfig", "rcSetRateConfig", "rcHighestBit"]:
        code += procedure(helpers, name)
    code += (FW / "rate_duration_tables.nim").read_text()
    for name in ["rc_get_mcs_index", "rc_get_nss", "rc_get_duration", "rc_calc_prob_ewma",
                 "rc_get_initial_rate_config", "rc_get_lowest_rate_config", "rc_new_random_rate",
                 "rc_check_valid_rate", "rc_check_rate_duplicated", "rc_set_next_mcs_index", "rc_set_previous_mcs_index"]:
        code += procedure(source, name)
    code += procedure(helpers, "rc_pick_non_duplicate_rate").replace("proc rc_pick_non_duplicate_rate", "proc real_pick_non_duplicate_rate")
    code += "\nproc rc_pick_non_duplicate_rate(stats: pointer): uint16 =\n  if forceNoSample: 0xFFFF'u16 else: real_pick_non_duplicate_rate(stats)\n"
    code += procedure((FW / "kernel_mac_channel.nim").read_text(), "is_cck_group")
    for name in ["rc_calc_tp", "rc_sort_samples_tp", "rc_update_retry_chain", "rc_get_new_sample_rates",
                 "rc_get_new_samples", "rc_update_stats", "rc_count_samples", "rc_seed_rate_table",
                 "rcTryInitStation", "rc_init",
                 "rc_install_trial", "rc_check"]:
        if f"proc {name}(" in source or f"proc {name}*(" in source:
            code += procedure(source, name)
    return code


@pytest.mark.parametrize("mode", ["checked", "release", "asan"])
def test_rate_init(mode: str, tmp_path: Path) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("nim is not installed")
    code = source()
    path = tmp_path / "rate_init.nim"
    path.write_text(code + CASES)
    command = [nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on", "--skipUserCfg:on",
               f"--nimcache:{tmp_path / 'cache'}", f"-o:{tmp_path / 'test'}"]
    command += ["--checks:on"] if mode == "checked" else ["-d:release", "--checks:off"]
    if mode == "asan":
        command += ["--passC:-fsanitize=address", "--passC:-fno-omit-frame-pointer", "--passL:-fsanitize=address"]
    result = subprocess.run(command + [str(path)], cwd=ROOT, text=True,
                            env={**os.environ, "ASAN_OPTIONS": "detect_leaks=0"},
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    assert result.returncode == 0, result.stdout
