"""Exercise LO search decisions and MMIO sequencing recovered from rf_pri.c.o."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import procedure
from test_wifi_message_allocation import run_program
from test_wifi_rf_power_replay import RF
from test_wifi_rf_xtal_pll import xtal_source


def lo_source() -> str:
    code = xtal_source().replace(
        "proc waitRfUs(us: uint32) = discard",
        "var delays: seq[uint32]\n"
        "var events: seq[tuple[address: uint, value: uint32]]\n"
        "proc waitRfUs(us: uint32) =\n"
        "  delays.add(us)\n  events.add((0'u, us))",
    )
    code = code.replace(
        "proc volatileLoad(p: ptr uint32): uint32 =",
        "var comparatorBits: seq[uint32]\nvar comparatorIndex, lastComparatorEventCount: int\n"
        "proc volatileLoad(p: ptr uint32): uint32 =",
    ).replace(
        "  p[]\nproc volatileStore",
        "  if p == (addr rf70.acalCtrlA4) and comparatorBits.len != 0 and\n"
        "      events.len >= 2 and events.len != lastComparatorEventCount and\n"
        "      events[^1] == (0'u, 1'u32) and\n"
        "      events[^2].address == cast[uint](addr rf70.fcalCtrlA0):\n"
        "    doAssert comparatorIndex < comparatorBits.len\n"
        "    result = (p[] and not 0x1000'u32) or comparatorBits[comparatorIndex]\n"
        "    lastComparatorEventCount = events.len\n"
        "    inc comparatorIndex\n"
        "  else: result = p[]\nproc volatileStore",
    )
    # The volatile-store procedure precedes the delay recorder in the fixture.
    code = code.replace(
        "var events: seq[tuple[address: uint, value: uint32]]\n", ""
    ).replace(
        "var comparatorBits:",
        "var events: seq[tuple[address: uint, value: uint32]]\nvar comparatorBits:",
    ).replace(
        "  if recordWrites: mmioWrites.add((address, value))",
        "  if recordWrites:\n"
        "    mmioWrites.add((address, value))\n"
        "    events.add((address, value))",
    )
    code += r'''
proc loSetup(row: int) =
  crystalSetup()
  rf_pri_input_xtalfreq(Frequencies[row])
  rf_pri_xtalfreq()
  rfCalibDataGlobal = addr calibration[0]
  for word in registerStorage.mitems: word = randomWord()
  comparatorBits.setLen(0)
  comparatorIndex = 0
  lastComparatorEventCount = 0
  delays.setLen(0)
  mmioWrites.setLen(0)
  mmioReads.setLen(0)
  events.setLen(0)
'''
    return code


def packed_lo_source() -> str:
    rf = RF.read_text()
    code = lo_source()
    for name in ("rfLoFcal", "rfLoAcal", "setRfLoFcal", "setRfLoAcal"):
        start = code.index("proc " + name + "(")
        end = code.index("\nproc ", start + 1)
        code = code[:start] + procedure(rf, name).rstrip() + code[end:]
    tables = "var\n" + "".join(
        next(line for line in rf.splitlines() if line.startswith("  " + name + " ")) + "\n"
        for name in ("channelFcalTable", "channelAcalTable")
    )
    return code.replace(
        "proc rfLoFcal(", tables + procedure(rf, "rfCalibSetHalf") + "proc rfLoFcal(", 1
    )


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_acal_all_comparator_histories_and_exact_mmio(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, lo_source() + r'''
for row in 0 ..< 6:
  for pattern in 0 ..< 32:
    loSetup(row)
    let initial = registerStorage
    var expected = initial
    var trace: seq[tuple[address: uint, value: uint32]]
    var reads: seq[uint]
    var expectedDelays: seq[uint32]
    var expectedEvents: seq[tuple[address: uint, value: uint32]]
    template put(member: untyped; keep, value: uint32) =
      let offset = (cast[uint](addr member) - cast[uint](addr registerStorage[0])).int div 4
      expected[offset] = (expected[offset] and keep) or value
      reads.add(cast[uint](addr member))
      trace.add((cast[uint](addr member), expected[offset]))
      expectedEvents.add(trace[^1])
    template settle() =
      expectedDelays.add(1)
      expectedEvents.add((0'u, 1'u32))
    put(rf70.calMode14, 0xFFFFFF3F'u32, 0x40)
    put(rf70.baseCtrl1, 0xFFFFFFFD'u32, 0)
    put(rf70.synthCtrl2c, 0, 0)
    # A plain store, unlike the field updates, does not read first.
    reads.setLen(reads.len - 1)
    put(rf70.priModeCtrl30, 0xFFFFFFFF'u32, 2)
    # BL808 demo rf_pri_lo_acal+0x3a,+0x3e,+0x72.
    put(rf70.priModeCtrl30, (0xCF09'u32 shl 12) + 0xFF, 0xCF00'u32 shl 12)
    put(rf70.calCtrl1c, 0xFFFFFFFF'u32, 0x10)
    var wanted: array[21, uint16]
    for channel in 0 ..< 21:
      put(rf70.acalCtrlA4, 0xFFFFF8FF'u32, 0x400)
      put(rf70.fcalCtrlA0, 0xFFE0FFFF'u32, 0x100000)
      put(rf70.fcalCtrlA0, 0xFFFFFF00'u32, loFcalValues[channel].uint32)
      put(rf70.sdmDivC4, 0, VendorDiv[row][channel])
      reads.setLen(reads.len - 1)
      settle()
      var value = 16
      for bit in countdown(3, 0):
        put(rf70.fcalCtrlA0, 0xFFE0FFFF'u32, value.uint32 shl 16)
        settle()
        reads.add(cast[uint](addr rf70.acalCtrlA4))
        let comparator = if (pattern and (1 shl (3 - bit))) != 0: 0x1000'u32 else: 0'u32
        comparatorBits.add(comparator)
        value += (if comparator == 0: 1 shl bit else: -(1 shl bit))
      put(rf70.fcalCtrlA0, 0xFFE0FFFF'u32, value.uint32 shl 16)
      settle()
      reads.add(cast[uint](addr rf70.acalCtrlA4))
      let finalComparator = if (pattern and 16) != 0: 0x1000'u32 else: 0'u32
      comparatorBits.add(finalComparator)
      if finalComparator == 0 and value <= 30: inc value
      wanted[channel] = value.uint16
    put(rf70.calMode14, 0xFFFFFFFF'u32, 0xC0)
    runRfPriLoAcal()
    doAssert comparatorIndex == 105, "ACAL must consume four search samples and one final sample per channel"
    doAssert loAcalValues == wanted, "ACAL result differs from comparator decisions"
    doAssert registerStorage == expected, "ACAL touched an unrelated field"
    doAssert mmioWrites == trace, "ACAL write ordering differs from vendor"
    doAssert mmioReads == reads, "ACAL read ordering differs from vendor"
    doAssert delays == expectedDelays, "ACAL settling intervals differ from vendor"
    doAssert events == expectedEvents, "ACAL delays occur at a different MMIO boundary"
    doAssert nim_wifi_rf_last_lo_acal == wanted[20].uint32
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_fcal_setup_matches_vendor_fields_order_and_delays(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, lo_source() + r'''
for row in 0 ..< 6:
  for vector in 0 ..< 100:
    loSetup(row)
    var expected = registerStorage
    var trace: seq[tuple[address: uint, value: uint32]]
    var reads: seq[uint]
    var expectedEvents: seq[tuple[address: uint, value: uint32]]
    template put(member: untyped; keep, value: uint32; read = true) =
      let offset = (cast[uint](addr member) - cast[uint](addr registerStorage[0])).int div 4
      expected[offset] = (expected[offset] and keep) or value
      if read: reads.add(cast[uint](addr member))
      trace.add((cast[uint](addr member), expected[offset]))
      expectedEvents.add(trace[^1])
    put(rf70.baseCtrl1, 0xFFFFFFFD'u32, 0)
    put(rf70.synthCtrl2c, 0, 0, false)
    put(rf70.priModeCtrl30, 0xFFFFFFFF'u32, 2)
    # BL808 demo libbl606p_phyrf.a:rf_pri.o, rf_pri_lo_fcal+0x4a..0x136.
    put(rf70.priModeCtrl30, (0xCF09'u32 shl 12) + 0xFF, 0xCF00'u32 shl 12)
    put(rf70.calCtrl1c, 0xFFFFFFFF'u32, 8)
    put(rf70.fcalCtrlA0, 0xFFFFFF00'u32, 0x80)
    put(rf70.txcalCtrlB8, 0xFFFFCFFF'u32, 0)
    put(rf70.calResultA8, 0xFFFF0000'u32, FcalDividers[row].uint32)
    put(rf70.sdmDivC4, 0, 0x01000000, false)
    put(rf70.sdmCtrlC0, 0xFFFFFFFF'u32, 0x1000)
    put(rf70.sdmCtrlC0, 0xFFFEFFFF'u32, 0)
    put(rf70.txcalCtrlB8, 0xFFFFFFFF'u32, 0x10000)
    expectedEvents.add((0'u, 10'u32))
    put(rf70.sdmCtrlC0, 0xFFFFFFFF'u32, 0x10000)
    put(rf70.txcalCtrlB8, 0xFFFEFFFF'u32, 0)
    expectedEvents.add((0'u, 50'u32))
    put(rf70.acalCtrlA4, 0xFFFFFFFC'u32, 2)
    expectedEvents.add((0'u, 50'u32))
    prepareRfPriLoFcal()
    doAssert registerStorage == expected, "FCAL setup fields differ from vendor"
    doAssert mmioWrites == trace, "FCAL setup writes differ in order or value"
    doAssert mmioReads == reads, "FCAL setup reads differ in order"
    doAssert delays == @[10'u32, 50, 50], "FCAL setup settling intervals differ"
    doAssert events == expectedEvents, "FCAL delays occur at a different MMIO boundary"
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_acal_publishes_five_bit_results_without_replacing_fcal(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, packed_lo_source() + r'''
for row in 0 ..< 6:
  for pattern in 0 ..< 32:
    loSetup(row)
    for word in calibration.mitems: word = randomWord()
    let initial = calibration
    let halves = cast[ptr UncheckedArray[uint16]](addr calibration[0])
    var wanted = initial
    let wantedHalves = cast[ptr UncheckedArray[uint16]](addr wanted[0])
    for channel in 0 ..< 21:
      let history = (pattern + channel) mod 32
      var value = 16
      for bit in countdown(3, 0):
        let comparator = if (history and (1 shl (3 - bit))) != 0: 0x1000'u32 else: 0'u32
        comparatorBits.add(comparator)
        value += (if comparator == 0: 1 shl bit else: -(1 shl bit))
      let finalComparator = if (history and 16) != 0: 0x1000'u32 else: 0'u32
      comparatorBits.add(finalComparator)
      if finalComparator == 0 and value <= 30: inc value
      wantedHalves[14 + channel] = (halves[14 + channel] and 0xFF00'u16) or value.uint16
    runRfPriLoAcal()
    doAssert calibration == wanted, "ACAL packed-record publication altered FCAL or adjacent calibration data"
    for channel in 0 ..< 21:
      doAssert rfLoAcal(channel) == (wantedHalves[14 + channel] and 0x3F'u16)
      doAssert rfLoFcal(channel) == (wantedHalves[14 + channel] shr 8)
      doAssert channelAcalTable[channel] == rfLoAcal(channel)
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_lo_halfword_tables_and_restore_boundary(tmp_path: Path, mode: str) -> None:
    # rf_pri.c.o: FCAL +34a calls restore before +37e/+382; ACAL
    # +162/+16a publishes in the channel loop, before the call at +176.
    code = packed_lo_source().replace(
        "proc restoreRfPriCalState(state: RfPriCalState) = discard",
        "proc observeRestore()\nproc restoreRfPriCalState(state: RfPriCalState) = observeRestore()",
    )
    store = procedure(RF.read_text(), "rfCalibSetHalf").rstrip()
    code = code.replace(store, "proc observePacked(index: int)\n" + store + "\n  observePacked(index)", 1)
    run_program(tmp_path, mode, code + r'''
const Unwritten = 0xCAFE'u16
var
  isAcal, restored: bool
  published: int
  before, wanted: typeof(calibration)
  codes: array[21, uint16]
template activeTable: untyped = (if isAcal: channelAcalTable else: channelFcalTable)
proc observePacked(index: int) =
  doAssert index == 14 + published and restored != isAcal
  doAssert rfCalibHalf(index) == cast[ptr UncheckedArray[uint16]](addr wanted[0])[index]
  doAssert activeTable[published] == Unwritten, "packed store must precede table store"
  if published > 0: doAssert activeTable[published - 1] == codes[published - 1]
  if isAcal: doAssert comparatorIndex == 5 * (published + 1)
  let modeBits = if isAcal: (0xC0'u32, 0x40'u32) else: (0x30'u32, 0x10'u32)
  doAssert (rf70.calMode14 and modeBits[0]) == modeBits[1]
  inc published
proc observeRestore() =
  doAssert not restored
  if isAcal:
    doAssert published == 21 and activeTable == codes and calibration == wanted
  else:
    doAssert published == 0 and calibration == before
    for value in activeTable: doAssert value == Unwritten
  restored = true

for row in 0 ..< 6:
  loSetup(row)
  for word in calibration.mitems: word = randomWord()
  for value in channelFcalTable.mitems: value = Unwritten
  for value in channelAcalTable.mitems: value = Unwritten
  let bounds = VendorRange[row]
  # Reach base 15; put the 21 exact targets at sweep indices 16..36.
  sampleValues = @[bounds[0]-1, bounds[0]-1, bounds[0]-1, bounds[0]-1,
                   bounds[1]+1, bounds[1]+1, bounds[1]+1]
  for i in countdown(16, 1): sampleValues.add(VendorCnt[row][0] - i.uint16)
  for target in VendorCnt[row]: sampleValues.add(target)
  sampleValues.add(bounds[2]+1)
  for acalPhase in [false, true]:
    isAcal = acalPhase
    restored = false
    published = 0
    before = calibration
    wanted = before
    let other = (if isAcal: channelFcalTable else: channelAcalTable)
    let halves = cast[ptr UncheckedArray[uint16]](addr wanted[0])
    for i in 0 ..< 21:
      if isAcal:
        # Alternating clear/set decisions give 31 or 1, then a clear final sample.
        for bit in 0 ..< 4: comparatorBits.add(if i mod 2 == 0: 0'u32 else: 0x1000'u32)
        comparatorBits.add(0)
        codes[i] = if i mod 2 == 0: 31 else: 2
        halves[14+i] = (halves[14+i] and 0xFF00) or codes[i]
      else:
        codes[i] = uint16((1 - i) and 0xFFFF)
        halves[14+i] = (halves[14+i] and 255) or ((codes[i] and 255) shl 8)
    if isAcal: runRfPriLoAcal()
    else: runRfPriLoFcal()
    doAssert restored and published == 21 and calibration == wanted
    doAssert activeTable == codes
    doAssert other == (if isAcal: channelFcalTable else: channelAcalTable)
    doAssert sampleIndex == sampleValues.len
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_fcal_sample_preserves_ready_and_unowned_bits(tmp_path: Path, mode: str) -> None:
    rf = RF.read_text()
    code = lo_source()
    start = code.index("proc sampleRfFcalCount(): uint16 =")
    end = code.index("proc rfPriWifiPllConfig()", start)
    code = code[:start] + "proc sampleRfFcalCount(): uint16\n" + code[end:]
    code += r'''
const
  RfFcalWaitLimit = 2
  RfFcalReadyMask = 0x100000'u32
  RfFcalStartMask = 0x10'u32
var nim_wifi_rf_fcal_wait_timeout_count: uint32
'''
    code += procedure(rf, "waitRfFcalReady") + procedure(rf, "sampleRfFcalCount")
    run_program(tmp_path, mode, code + r'''
for vector in 0 ..< 100:
  loSetup(4)
  rf70.fcalAc = (randomWord() and not RfFcalStartMask) or RfFcalReadyMask
  rf70.calResultA8 = randomWord()
  let before = registerStorage
  let wanted = (rf70.calResultA8 shr 16).uint16
  let stalls = nim_wifi_rf_fcal_wait_timeout_count
  doAssert sampleRfFcalCount() == wanted
  doAssert registerStorage == before
  doAssert mmioWrites == @[
    (cast[uint](addr rf70.fcalAc), before[0xAC div 4] or 0x10'u32),
    (cast[uint](addr rf70.fcalAc), before[0xAC div 4])],
    "sampling must only set and clear START, never software-clear READY"
  doAssert nim_wifi_rf_fcal_wait_timeout_count == stalls
  doAssert delays.len == 0
''')
