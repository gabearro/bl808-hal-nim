"""Run the production ME confirmation wrappers and RC counter distribution."""

from pathlib import Path
import re
import shutil
import subprocess

import pytest

from test_wifi_disconnect_tx import procedure

ROOT = Path(__file__).resolve().parents[1]
FW = ROOT / "src/bl808/wifi/fw"

PLATFORM = r"""
const
  MAX_VIFS = 2
  STA_INFO_TAB_ENTRIES = 7
  RC_MAX_RATE_ENTRIES = 10
  StaTxPolicyUpdateRateControl = 1'u8
type
  HostTxDescView = object
    staIdx, staInfoIdx, vifIdx: uint8
    frameLen: uint16
    hwDesc: pointer
  Hardware = object
    flags: uint32
  RateEntry = object
    attempts, successes, rateConfig: uint16
  RateCapabilities = object
    sampleCount: uint16
  Stats = object
    retrySlots: array[4, tuple[rateIdx: uint16]]
    entries: array[10, RateEntry]
    totalSuccess, totalAttempts: uint16
    updateStage, retryLimit: uint8
    legacyRateMap, currentAmsduLen: uint16
    capabilities: RateCapabilities
  Sta = object
    instNbr: uint8
    txPolicyUpdateFlags: array[1, uint8]
    rcStats: pointer
var
  stations: array[7, Sta]
  stats: array[7, Stats]
  stationReads: seq[uint8]
  assertionLines: seq[int]
  dumps: int
  txResetEpoch: uint32
  stationEpochs: array[7, uint32]
  rxVifEpochs: array[2, uint32]
  interrupts = true
proc staDeleteEpoch(index: uint8): uint32 = stationEpochs[index]
proc irqSave(): uint32 =
  result = interrupts.uint32 * 8
  interrupts = false
proc irqRestore(saved: uint32) = interrupts = (saved and 8) != 0
proc hostTxDescAt(p: pointer): ptr HostTxDescView = cast[ptr HostTxDescView](p)
proc hostTxHwDescAt(p: pointer): ptr Hardware = cast[ptr Hardware](p)
proc hostTxHeadThd(p: ptr Hardware): ptr Hardware = p
proc staInfoForIdx(index: uint8): ptr Sta =
  doAssert index < 7, "station lookup out of bounds"
  stationReads.add(index)
  addr stations[index]
proc rcStatsCounters(p: pointer): ptr Stats = cast[ptr Stats](p)
proc rcRateCapabilities(p: pointer): ptr RateCapabilities =
  addr cast[ptr Stats](p).capabilities
proc rcRateEntry(p: pointer; index: uint16): ptr RateEntry =
  doAssert index < 10
  addr cast[ptr Stats](p).entries[index]
proc rf_dump_status() = inc dumps
proc pointerAddrU32(p: pointer): uint32 = cast[uint32](cast[uint](p))
proc assert_err(file, cond: cstring; line: int) = assertionLines.add(line)
proc setup() =
  stations = default(typeof(stations))
  stats = default(typeof(stats))
  stationReads.setLen(0)
  assertionLines.setLen(0)
  dumps = 0
  for i in 0 ..< stations.len:
    stations[i].rcStats = addr stats[i]
    stats[i].capabilities.sampleCount = 4
    stats[i].legacyRateMap = (1000 + i).uint16
    stats[i].currentAmsduLen = (2000 + i).uint16
    for slot in 0 ..< 4: stats[i].retrySlots[slot].rateIdx = slot.uint16
"""

CHECKS = r"""
# Failure counts consume four attempts per retry stage, then credit the final
# stage with its successes. Repeated rate indexes accumulate in the same entry.
for repeated in [false, true]:
  for attempts in 0'u32 .. 32'u32:
    for failures in 0'u32 .. attempts:
      for staIndex in 0'u8 .. 4'u8:
        setup()
        if repeated:
          for slot in 0 ..< 4: stats[staIndex].retrySlots[slot].rateIdx = 2
        var expected: array[10, RateEntry]
        var attemptsLeft = attempts
        var failuresLeft = failures
        for slot in 0 ..< 4:
          if attemptsLeft == 0: break
          let rateIndex = if repeated: 2 else: slot
          let consumed = if failuresLeft >= 4: 4'u32 else: attemptsLeft
          let failed = min(failuresLeft, consumed)
          expected[rateIndex].attempts += consumed.uint16
          expected[rateIndex].successes += (consumed - failed).uint16
          attemptsLeft -= consumed
          failuresLeft -= failed
        rc_update_counters(staIndex, attempts, failures, false, false)
        doAssert stats[staIndex].entries == expected
        doAssert stats[staIndex].totalAttempts == 1 and stats[staIndex].totalSuccess == 1
        doAssert assertionLines.len == 0

for stage in 0'u8 .. 3'u8:
  for limit in [0'u8, 1, 255]:
    for policyPending in [false, true]:
      setup()
      stats[0].updateStage = stage
      stats[0].retryLimit = limit
      stations[0].txPolicyUpdateFlags[0] = policyPending.uint8
      rc_update_counters(0, 1, 0, true, true)
      let expectedStage = if stage == 0 and limit == 0: 1'u8
        elif stage == 2 and not policyPending: 3'u8
        else: stage
      doAssert stats[0].updateStage == expectedStage
      doAssert stats[0].retryLimit == (if stage == 0 and limit > 0: limit - 1 else: limit)

# The compiled vendor body ignores the aggregate/retry-required flags.
for aggregate in [false, true]:
  for retry in [false, true]:
    setup()
    rc_update_counters(0, 7, 5, aggregate, retry)
    doAssert stats[0].entries[0] == RateEntry(attempts: 4, successes: 0)
    doAssert stats[0].entries[1] == RateEntry(attempts: 3, successes: 2)

# The archive increments 32-bit registers then stores halfwords, so each
# counter wraps independently at 65536 rather than saturating or trapping.
setup()
stats[0].totalSuccess = high(uint16)
stats[0].totalAttempts = high(uint16)
stats[0].entries[0] = RateEntry(attempts: high(uint16), successes: high(uint16))
rc_update_counters(0, 1, 0, false, false)
doAssert stats[0].totalSuccess == 0 and stats[0].totalAttempts == 0
doAssert stats[0].entries[0] == RateEntry(attempts: 0, successes: 0)
doAssert assertionLines.len == 0
setup()
stats[0].entries[0].attempts = 65534
rc_update_counters(0, 4, 4, false, false)
doAssert stats[0].entries[0] == RateEntry(attempts: 2, successes: 0)
doAssert assertionLines.len == 0

# Malformed confirmations cannot reach an out-of-table retry index or wrap
# the attempt count. Unused retry slots do not affect a valid confirmation.
for badSlot in [0, 1]:
  setup()
  stats[0].retrySlots[badSlot].rateIdx = 10
  let before = stats[0]
  rc_update_counters(0, 7, 5, false, false)
  doAssert stats[0] == before
setup()
stats[0].capabilities.sampleCount = 1
stats[0].retrySlots[1].rateIdx = 1
let beforeStaleSlot = stats[0]
rc_update_counters(0, 7, 5, false, false)
doAssert stats[0] == beforeStaleSlot
for invalidCount in [0'u16, 11'u16]:
  setup()
  stats[0].capabilities.sampleCount = invalidCount
  let beforeInvalidCount = stats[0]
  rc_update_counters(0, 1, 0, false, false)
  doAssert stats[0] == beforeInvalidCount
setup()
stats[0].retrySlots[2].rateIdx = 10
rc_update_counters(0, 7, 5, false, false)
doAssert stats[0].entries[0] == RateEntry(attempts: 4, successes: 0)
doAssert stats[0].entries[1] == RateEntry(attempts: 3, successes: 2)
setup()
let beforeBadFailures = stats[0]
rc_update_counters(0, 2, 5, false, false)
doAssert stats[0] == beforeBadFailures
setup()
let beforeBadAmpdu = stats[0]
me_tx_cfm_ampdu(0, 2, 3, false)
doAssert stats[0] == beforeBadAmpdu

# Every retry count and terminal-status bit combination follows the vendor
# formula; ACK bit 23 is independent of retry-limit bit 16.
for retries in 0'u32 .. 255'u32:
  for exhausted in [false, true]:
    for acknowledged in [false, true]:
      setup()
      var hw = Hardware(flags: retries shl 8)
      if exhausted: hw.flags = hw.flags or 0x10000
      if acknowledged: hw.flags = hw.flags or 0x800000
      var desc = HostTxDescView(staIdx: 3, staInfoIdx: 1, hwDesc: addr hw)
      me_tx_cfm_singleton(addr desc)
      let expectedFailures = retries + exhausted.uint32
      var afterSingleton = stats[1]
      setup()
      rc_update_counters(1, retries + 1, expectedFailures, false, false)
      doAssert stats[1] == afterSingleton

# Control-port attempts used a per-frame retry policy, not these station slots.
for proto in [0x8E88'u16, 0x888E'u16]:
  for status in [0x80800400'u32, 0x80010700'u32]:
    setup()
    let beforeEapol = stats[1]
    var hw = Hardware(flags: status)
    var eapol = HostTxDescView(staInfoIdx: 1, frameLen: proto, hwDesc: addr hw)
    me_tx_cfm_singleton(addr eapol)
    doAssert stats[1] == beforeEapol and stationReads.len == 0

# Software cancellation and deferral never reached the radio. Neither the
# sample estimates nor the trial countdown should advance.
for status in [0x40000000'u32, 0xC0020000'u32, 0xC0080000'u32, 0xC0100000'u32]:
  for stage in 0'u8 .. 3'u8:
    setup()
    stats[1].updateStage = stage
    stats[1].retryLimit = 1
    let before = stats[1]
    var hw = Hardware(flags: status)
    var desc = HostTxDescView(staIdx: 3, staInfoIdx: 1, hwDesc: addr hw)
    me_tx_cfm_singleton(addr desc)
    doAssert stats[1] == before and stationReads.len == 0 and dumps == 0

for attempts in 0'u32 .. 16'u32:
  for acknowledged in 0'u32 .. attempts:
    setup()
    me_tx_cfm_ampdu(2, attempts, acknowledged, false)
    let afterAggregate = stats[2]
    setup()
    rc_update_counters(2, attempts, attempts - acknowledged, true, false)
    doAssert stats[2] == afterAggregate

# TID (host +42 / descriptor +46) is only a sentinel, never the STA index.
for staIndex in 0'u8 .. 6'u8:
  for tid in 0'u8 .. 7'u8:
    setup()
    var desc = HostTxDescView(staIdx: tid, staInfoIdx: staIndex)
    doAssert me_tx_cfm_amsdu(addr desc) == 2000'u16 + staIndex.uint16
    doAssert stationReads == @[staIndex]
setup()
var desc = HostTxDescView(staIdx: 0xFF, staInfoIdx: 0)
doAssert me_tx_cfm_amsdu(addr desc) == 0 and stationReads.len == 0
for invalid in [7'u8, 8, 255]:
  setup()
  desc = HostTxDescView(staIdx: 0, staInfoIdx: invalid)
  doAssert me_tx_cfm_amsdu(addr desc) == 0 and stationReads.len == 0
setup()
desc = HostTxDescView(staIdx: 0, staInfoIdx: 1)
stations[1].instNbr = 0xFF
doAssert me_tx_cfm_amsdu(addr desc) == 0
stations[1].instNbr = 0
stations[1].rcStats = nil
doAssert me_tx_cfm_amsdu(addr desc) == 0
doAssert me_tx_cfm_amsdu(nil) == 0

for invalid in [5'u8, 6, 255]:
  setup()
  rc_update_counters(invalid, 3, 2, false, false)
  doAssert stationReads.len == 0
setup()
stations[1].instNbr = 0xFF
rc_update_counters(1, 3, 2, false, false)
doAssert stats[1].totalAttempts == 0
setup()
stations[1].rcStats = nil
rc_update_counters(1, 3, 2, false, false)
doAssert assertionLines == @[1998]
"""


@pytest.mark.parametrize("release_mode", [False, True])
def test_rate_confirmation_and_counters(release_mode: bool, tmp_path: Path) -> None:
    nim = shutil.which("nim")
    if nim is None:
        pytest.skip("nim is not installed")
    rate_source = (FW / "rate_control.nim").read_text()
    me_source = (FW / "scan_station_ap_me.nim").read_text()
    source = procedure(rate_source, "rcAccountCounters") + procedure(rate_source, "rc_update_counters")
    for name in ["me_tx_cfm_singleton", "me_tx_cfm_ampdu", "me_tx_cfm_amsdu"]:
        source += procedure(me_source, name)
    names = sorted(set(re.findall(r"\bnimFwDbg\w+\b", source)))
    declarations = "\nvar\n" + "\n".join(f"  {name}: uint32" for name in names) + "\n"
    path = tmp_path / "rate_confirmation.nim"
    path.write_text(PLATFORM + declarations + source + CHECKS)
    command = [nim, "c", "-r", "--skipParentCfg:on", "--skipProjCfg:on",
               "--skipUserCfg:on", f"--nimcache:{tmp_path / 'cache'}", f"-o:{tmp_path / 'test'}"]
    command += ["-d:release", "--checks:off"] if release_mode else ["--checks:on"]
    result = subprocess.run(command + [str(path)], cwd=ROOT, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    assert result.returncode == 0, result.stdout
