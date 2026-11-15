"""Check RX-duration requests and completion against the pinned MM object."""

from pathlib import Path
import re

import pytest

from test_wifi_disconnect_tx import FW, ROOT, procedure
from test_wifi_message_allocation import run_program
from test_wifi_beacon_timing import deadline, source as beacon_source


PLATFORM = r'''
const
  MACHW_INTC_BASE = 0x24B08000'u
  WifiHwPollLimit = 7'u32
var
  writes: seq[tuple[address: uint, value: uint32]]
  pollValues: seq[uint32]
  settled: uint32
  reads, errors, recoveries, timeouts: int
  lastTimeoutReg, lastTimeoutMask: uint32
proc regWrite(address: uint; value: uint32) =
  writes.add((address, value))
proc regRead(address: uint): uint32 =
  doAssert address == MACHW_INTC_BASE + 0x168
  result = if reads < pollValues.len: pollValues[reads] else: settled
  inc reads
proc volatileLoad(p: ptr uint32): uint32 = regRead(cast[uint](p))
proc radioWaitRegMaskSet(reg: uint; mask, limit: uint32): bool
proc assert_err(condition, file: cstring; line: int) =
  doAssert line == 0x1A99
  inc errors
proc assert_rec(condition, file: cstring; line: int) =
  doAssert line == 249
  inc recoveries
proc noteHwWaitTimeout(reg, mask: uint32) =
  inc timeouts
  lastTimeoutReg = reg
  lastTimeoutMask = mask
proc setup(value = 0x40000140'u32) =
  writes.setLen(0)
  pollValues.setLen(0)
  settled = value
  reads = 0
  errors = 0
  recoveries = 0
  timeouts = 0
proc sample(rate: uint32; flags = 0'u32): array[64, uint8] =
  for value in result.mitems: value = 0xA5
  let rateWord = (0x87650FED'u32 and not 0xF000'u32) or (rate shl 12)
  for i in 0 .. 3:
    result[40 + i] = ((rateWord shr (i * 8)) and 255).uint8
    result[44 + i] = ((flags shr (i * 8)) and 255).uint8
'''


def declarations() -> str:
    layout = (FW / "layout_types.nim").read_text()
    code = "type\n"
    for name in ["PhyRxVectorView", "RxDurationDescView"]:
        match = re.search(r"(?ms)^  " + name + r"\b.*?(?=^  \w|\Z)", layout)
        if match:
            code += match.group(0)
    for name in ["phyRxVectorAt", "rxDurationDescAt"]:
        match = re.search(r"(?ms)^template " + name + r"\(.*?(?=^(?:proc|template|func) |\Z)", layout)
        if match:
            code += match.group(0)
    return code


def helper_source() -> str:
    return procedure((FW / "kernel_mac_channel.nim").read_text(), "hal_machw_rx_duration")


def source() -> str:
    radio = (ROOT / "src/bl808/radio_phy.nim").read_text()
    waits = (FW / "global_state/late_forward_decls.nim").read_text()
    return (
        declarations() + PLATFORM
        + procedure(radio, "radioWaitRegMaskSet")
        + "\nproc radioWaitRegMaskSet(reg: uint; mask, limit: uint32): bool =\n"
          "  radioWaitRegMaskSet(cast[ptr uint32](reg), mask, limit)\n"
        + procedure(waits, "waitRegMaskSet") + helper_source()
    )


CASES = {
    "rate_table": r'''
const table = [0'u32, 1, 2, 3, 255, 255, 255, 255, 10, 8, 6, 4, 11, 9, 7, 5]
for rate in 0'u32 .. 15:
  setup()
  var descriptor = sample(rate)
  let before = descriptor
  let duration = hal_machw_rx_duration(addr descriptor, 321)
  doAssert descriptor == before
  if rate in 4'u32 .. 7'u32:
    doAssert duration == 500 and errors == 1
    doAssert writes.len == 0 and reads == 0,
      "reserved RX rate was submitted to the duration engine"
  else:
    doAssert duration == 320 and errors == 0
    doAssert writes == @[(MACHW_INTC_BASE + 0x164, table[rate]),
      (MACHW_INTC_BASE + 0x160, 321'u32),
      (MACHW_INTC_BASE + 0x168, 0x80000000'u32)],
      "RX rate code was not translated through the vendor table"
''',
    "length_and_preamble": r'''
for preamble in 0'u32 .. 1:
  for noise in [0'u32, 0x7FFF, 0xFFFF0000'u32, 0xFFFF7FFF'u32]:
    for length in [0'u32, 24, 127, 4095, 65535]:
      setup()
      var descriptor = sample(11, noise or (preamble shl 15))
      doAssert hal_machw_rx_duration(addr descriptor, length) == 320
      doAssert writes[1] == (MACHW_INTC_BASE + 0x160,
        length or (preamble shl 24)),
        "duration request used unrelated vector bits instead of bit 15"
''',
    "completion": r'''
for duration in [0'u32, 1, 320, 500, 65535]:
  setup(0x43FF0000'u32 or duration)
  pollValues = @[0x80000000'u32, 0x80040000'u32, settled]
  var descriptor = sample(0)
  doAssert hal_machw_rx_duration(addr descriptor, 24) == duration,
    "duration query accepted the wrong ready bit or rejected a valid zero"
  doAssert reads >= 4 and timeouts == 0 and recoveries == 0 and errors == 0
''',
    "failure_paths": r'''
setup(0x0004007B)
var descriptor = sample(1)
doAssert hal_machw_rx_duration(addr descriptor, 24) == 500
doAssert reads == WifiHwPollLimit.int + 1 and timeouts == 1
doAssert lastTimeoutReg == (MACHW_INTC_BASE + 0x168).uint32
doAssert lastTimeoutMask == 0x40000000'u32
doAssert recoveries == 0

# The completion flag may disappear between the poll and result read.
setup(0x03FFFFFF)
pollValues = @[0x40000000'u32]
doAssert hal_machw_rx_duration(addr descriptor, 24) == 500
doAssert recoveries == 1 and timeouts == 0
''',
}


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
@pytest.mark.parametrize("case", CASES)
def test_rx_duration(tmp_path: Path, mode: str, case: str) -> None:
    run_program(tmp_path, mode, source() + CASES[case])


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_beacon_deadline_uses_duration_engine(tmp_path: Path, mode: str) -> None:
    engine = source().replace("proc setup(value", "proc setupDuration(value")
    engine = engine.replace(procedure(engine, "volatileLoad"), "")
    engine = engine.replace(procedure(engine, "regWrite"), r'''
proc regWrite(address: uint; value: uint32) =
  writes.add((address, value))
  if address == MACHW_INTC_BASE + 0x160:
    settled = 0x40000000'u32 or (if (value and 0xFFFF) == 24: 48'u32 else: 320'u32)
''')
    beacon = beacon_source()
    beacon = beacon.replace(procedure(beacon, "hal_machw_rx_duration"), "")
    # Keep target offsets while allowing the native fixture's pointer width.
    beacon = beacon.replace("payloadDescToFrameLenPadding*: array[16, uint8]",
                            "payloadDescToFrameLenPadding*: array[20 - sizeof(pointer), uint8]")
    beacon = beacon.replace(procedure(beacon, "volatileLoad"), r'''
proc volatileLoad(p: ptr uint32): uint32 =
  if cast[uint](p) == MACHW_INTC_BASE + 0x168: regRead(cast[uint](p))
  elif cast[uint](p) == 0x24B080A4'u: descriptorAccess
  else: clock
''')
    # The actual wait helper uses the combined MMIO reader above.
    engine = "proc volatileLoad(p: ptr uint32): uint32\n" + engine
    expected = deadline(234567, 231000, 100, 3, 9, 320, 48, 240000, 4000, 57)
    run_program(tmp_path, mode, engine + beacon + f'''
static: doAssert offsetof(BeaconRxDescView, timestampRssiPadding) == 40
prepare(234567, 231000, 100, 3, 9, 320, 48, 240000, 4000, 57)
setupDuration()
let vector = addr rxDurationDescAt(addr rx).vector
vector.mcsBitsWord = 8'u32 shl 12
vector.formatBitsWord = 1'u32 shl 15
process()
doAssert vif.tbttTimer.expiry == {expected}'u32 and timerSets == 1
doAssert writes == @[(MACHW_INTC_BASE + 0x164, 10'u32),
  (MACHW_INTC_BASE + 0x160, 0x01000024'u32),
  (MACHW_INTC_BASE + 0x168, 0x80000000'u32),
  (MACHW_INTC_BASE + 0x164, 10'u32),
  (MACHW_INTC_BASE + 0x160, 0x01000018'u32),
  (MACHW_INTC_BASE + 0x168, 0x80000000'u32)]
doAssert errors == 0 and recoveries == 0 and timeouts == 0
''')
