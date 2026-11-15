"""Check crystal selection, PLL traces, and selected LO calibration banks."""

from pathlib import Path

import pytest

from test_wifi_disconnect_tx import procedure
from test_wifi_message_allocation import run_program
from test_wifi_rf_power_replay import RF, array_constant, object_type, source

VENDOR_DIV = (
    (0x21638E39, 0x2171C71C, 0x21800000, 0x218E38E4, 0x219C71C7, 0x21AAAAAB, 0x21B8E38E, 0x21C71C72, 0x21D55555, 0x21E38E39, 0x21F1C71C, 0x22000000, 0x220E38E4, 0x221C71C7, 0x222AAAAB, 0x2238E38E, 0x22471C72, 0x22555555, 0x22638E39, 0x2271C71C, 0x22800000),
    (0x1ED20D21, 0x1EDF2DF3, 0x1EEC4EC5, 0x1EF96F97, 0x1F069069, 0x1F13B13B, 0x1F20D20D, 0x1F2DF2DF, 0x1F3B13B1, 0x1F483483, 0x1F555555, 0x1F627627, 0x1F6F96F9, 0x1F7CB7CB, 0x1F89D89E, 0x1F96F970, 0x1FA41A42, 0x1FB13B14, 0x1FBE5BE6, 0x1FCB7CB8, 0x1FD89D8A),
    (0x190AAAAB, 0x19155555, 0x19200000, 0x192AAAAB, 0x19355555, 0x19400000, 0x194AAAAB, 0x19555555, 0x19600000, 0x196AAAAB, 0x19755555, 0x19800000, 0x198AAAAB, 0x19955555, 0x19A00000, 0x19AAAAAB, 0x19B55555, 0x19C00000, 0x19CAAAAB, 0x19D55555, 0x19E00000),
    (0x14DE38E4, 0x14E71C72, 0x14F00000, 0x14F8E38E, 0x1501C71C, 0x150AAAAB, 0x15138E39, 0x151C71C7, 0x15255555, 0x152E38E4, 0x15371C72, 0x15400000, 0x1548E38E, 0x1551C71C, 0x155AAAAB, 0x15638E39, 0x156C71C7, 0x15755555, 0x157E38E4, 0x15871C72, 0x15900000),
    (0x14088889, 0x14111111, 0x1419999A, 0x14222222, 0x142AAAAB, 0x14333333, 0x143BBBBC, 0x14444444, 0x144CCCCD, 0x14555555, 0x145DDDDE, 0x14666666, 0x146EEEEF, 0x14777777, 0x14800000, 0x14888889, 0x14911111, 0x1499999A, 0x14A22222, 0x14AAAAAB, 0x14B33333),
    (0xF690690, 0xF6F96F9, 0xF762762, 0xF7CB7CB, 0xF834835, 0xF89D89E, 0xF906907, 0xF96F970, 0xF9D89D9, 0xFA41A42, 0xFAAAAAB, 0xFB13B14, 0xFB7CB7D, 0xFBE5BE6, 0xFC4EC4F, 0xFCB7CB8, 0xFD20D21, 0xFD89D8A, 0xFDF2DF3, 0xFE5BE5C, 0xFEC4EC5),
)
VENDOR_CNT = (
    (42738, 42809, 42880, 42951, 43022, 43093, 43164, 43236, 43307, 43378, 43449, 43520, 43591, 43662, 43733, 43804, 43876, 43947, 44018, 44089, 44160),
    (42748, 42819, 42890, 42961, 43033, 43104, 43175, 43246, 43317, 43388, 43459, 43530, 43602, 43673, 43744, 43815, 43886, 43957, 44028, 44099, 44171),
    (42746, 42817, 42888, 42960, 43031, 43102, 43173, 43244, 43315, 43386, 43457, 43529, 43600, 43671, 43742, 43813, 43884, 43955, 44026, 44098, 44169),
    (42738, 42809, 42880, 42951, 43022, 43093, 43164, 43236, 43307, 43378, 43449, 43520, 43591, 43662, 43733, 43804, 43876, 43947, 44018, 44089, 44160),
    (42731, 42802, 42873, 42944, 43016, 43087, 43158, 43229, 43300, 43371, 43442, 43513, 43584, 43655, 43727, 43798, 43869, 43940, 44011, 44082, 44153),
    (42733, 42804, 42875, 42946, 43017, 43088, 43159, 43230, 43301, 43373, 43444, 43515, 43586, 43657, 43728, 43799, 43870, 43941, 44012, 44084, 44155),
)
VENDOR_RANGE = (
    (42663, 42727, 44263),
    (42673, 42737, 44274),
    (42671, 42735, 44272),
    (42663, 42727, 44263),
    (42656, 42720, 44256),
    (42658, 42722, 44258),
)
VENDOR_FRACTION = (
    (0, 20971520, 41943040),
    (0, 19358326, 38716652),
    (0, 15728640, 31457280),
    (0, 13107199, 26214398),
    (0, 12582912, 25165824),
    (0, 9679163, 19358326),
)
FCAL_DIV = (0x500, 0x56B, 0x6AB, 0x800, 0x855, 0xAD5)
REFDIV = (1, 1, 2, 2, 2, 0)


def matrix(name: str, rows: tuple, nim_type: str, suffix: str) -> str:
    entries = ",\n".join("  [" + ", ".join(f"{v}'{suffix}" for v in row) + "]" for row in rows)
    return f"const {name}: array[{len(rows)}, array[{len(rows[0])}, {nim_type}]] = [\n{entries}\n]\n"


def xtal_source() -> str:
    rf = RF.read_text()
    code = r'''
const
  RfLoChannelCount = 21
  RfCalibLoVcoHalfwordBase = 14
  WlXtal24M = 24000000'u32
  WlXtal26M = 26000000'u32
  WlXtal32M = 32000000'u32
  WlXtal38P4M = 38400000'u32
  WlXtal52M = 52000000'u32
  RfConfigChannelWaitLimit = 2
  RfCtrlTuneEnableMask = 2'u32
  RfFcalCodeMask = 255'u32
  RfAcalCodeMask = 0x003F0000'u32
  RfAcalComparatorMask = 0x00001000'u32
  RfLoFcalLowCount = 0xA6A0'u16
  RfLoFcalHighCount = 0xA6E0'u16
  RfLoFcalStopCount = 0xACE0'u16
  RfLoFcalDiv = 0x855'u16
'''
    code += source(real_io=True).replace(
        "proc xtalIndex(hz: uint32): uint32 = 4", procedure(rf, "xtalIndex").rstrip()
    )
    code += object_type(rf, "RfPllBlock")
    code += matrix("VendorDiv", VENDOR_DIV, "uint32", "u32")
    code += matrix("VendorCnt", VENDOR_CNT, "uint16", "u16")
    code += matrix("VendorRange", VENDOR_RANGE, "uint16", "u16")
    code += matrix("VendorFraction", VENDOR_FRACTION, "uint32", "u32")
    for name in (
        "RfChannelDivTable40M", "RfChannelCntTable40M",
        "RfChannelDivTables", "RfChannelCntTables", "RfChannelCntRanges",
        "RfPriPllFractionWords",
        "RfPriFcalDivByXtal", "RfPriPllRefdivByXtal",
    ):
        if f"  {name}:" in rf:
            code += array_constant(rf, name)
    code += r'''
var
  bl808RfPriXtal24mFlag, bl808RfPriXtal26mFlag, bl808RfPriXtal32mFlag: uint8
  bl808RfPriXtal38p4mFlag, bl808RfPriXtal40mFlag, bl808RfPriXtal52mFlag: uint8
  bl808RfPriXtalTableIndex: int8 = -1
  bl808RfPriPllRefdivRatio = 1'u16
  bl808RfPriFcalDiv = 0x85'u16
  pll: RfPllBlock
  sampleCount: uint16
  sampleValues: seq[uint16]
  sampleIndex: int
  loFcalValues, loAcalValues: array[21, uint16]
  nim_wifi_rf_fcal_search_log: array[16, uint32]
  nim_wifi_rf_pri_lo_fcal_count, nim_wifi_rf_pri_lo_acal_count: uint32
  nim_wifi_rf_last_lo_fcal, nim_wifi_rf_last_lo_acal: uint32
  nim_wifi_rf_last_config_channel_index, nim_wifi_rf_last_config_channel_fcal: uint32
  nim_wifi_rf_last_config_channel_acal, nim_wifi_rf_last_config_channel_sdm2: uint32
  nim_wifi_rf_last_config_channel_b8, nim_wifi_rf_last_config_channel_b0: uint32
  nim_wifi_rf_last_config_channel_status, nim_wifi_rf_config_channel_wait_timeout_count: uint32
type RfPriCalState = object
  unused: uint32
proc rfPllRegs(): ptr RfPllBlock = addr pll
proc waitRfUs(us: uint32) = discard
proc saveRfPriCalState(): RfPriCalState = default(RfPriCalState)
proc restoreRfPriCalState(state: RfPriCalState) = discard
proc rfLoFcal(index: int): uint16 = loFcalValues[index]
proc rfLoAcal(index: int): uint16 = loAcalValues[index]
proc setRfLoFcal(index: int; value: uint16) = loFcalValues[index] = value
proc setRfLoAcal(index: int; value: uint16) = loAcalValues[index] = value
proc sampleRfFcalCount(): uint16 =
  result = if sampleValues.len == 0: sampleCount
           else: sampleValues[min(sampleIndex, sampleValues.high)]
  inc sampleIndex
proc rfPriWifiPllConfig()
'''
    for name in (
        "rfPriXtalTablesReady", "rfPriChannelDivValue", "rfPriChannelCntValue",
        "rfPriLoFcalCountBound", "rf_pri_input_xtalfreq", "rf_pri_get_xtalfreq",
        "rf_pri_xtalfreq", "rfPriXtalRefdivRatio", "rfPriXtalTenthsMhz",
        "rfPriWifiPllFractionWord", "rfPriWifiPllConfig",
        "writeRfFcalCode", "writeRfAcalCode",
        "prepareRfPriLoFcal", "chooseRfBaseFcalCode", "runRfPriLoFcal",
        "prepareRfPriLoAcal", "runRfPriLoAcal", "rfPriConfigChannelForCal",
    ):
        if f"proc {name}(" in rf:
            body = procedure(rf[rf.rindex("\nproc " + name + "(") + 1:], name)
            for marker in ("\nvar ", "\nvar\n", "\ntype\n", "\nconst\n"):
                body = body.split(marker, 1)[0]
            code += body + "\n"
    return code + r'''
const
  Frequencies = [WlXtal24M, WlXtal26M, WlXtal32M, WlXtal38P4M, WlXtal40M, WlXtal52M]
  ReferenceDividers = [1'u16, 1, 2, 2, 2, 0]
  FcalDividers = [0x500'u16, 0x56B, 0x6AB, 0x800, 0x855, 0xAD5]
proc setFlags(mask: int) =
  bl808RfPriXtal24mFlag = ((mask shr 0) and 1).uint8
  bl808RfPriXtal26mFlag = ((mask shr 1) and 1).uint8
  bl808RfPriXtal32mFlag = ((mask shr 2) and 1).uint8
  bl808RfPriXtal38p4mFlag = ((mask shr 3) and 1).uint8
  bl808RfPriXtal40mFlag = ((mask shr 4) and 1).uint8
  bl808RfPriXtal52mFlag = ((mask shr 5) and 1).uint8
proc crystalSetup() =
  setup()
  setFlags(16)
  bl808RfPriPllRefdivRatio = 1
  bl808RfPriFcalDiv = 0x85
  bl808RfPriXtalTableIndex = -1
  sampleValues.setLen(0)
  sampleIndex = 0
  for i in 0 ..< 21:
    loFcalValues[i] = (0x80 + i).uint16
    loAcalValues[i] = (8 + i mod 8).uint16
proc seedPll() =
  let words = cast[ptr UncheckedArray[uint32]](addr pll)
  for i in 0 ..< sizeof(pll) div 4: words[i] = randomWord()
  for word in registerStorage.mitems: word = randomWord()
  mmioWrites.setLen(0)
  mmioReads.setLen(0)
proc frequencySlot(mask: int): int =
  if (mask and 8) != 0: 3
  elif (mask and 1) != 0: 0
  elif (mask and 2) != 0: 1
  elif (mask and 4) != 0: 2
  elif (mask and 16) != 0: 4
  elif (mask and 32) != 0: 5
  else: 4
proc checkPll(mask: int; ratio: uint16; board: bool) =
  var want = pll
  var wantRf = rf70
  var trace: seq[tuple[address: uint, value: uint32]]
  var reads: seq[uint]
  template put(model, actual: untyped; keep, value: uint32) =
    model = (model and keep) or value
    trace.add((cast[uint](addr actual), model))
    reads.add(cast[uint](addr actual))
  put(want.refdivCtrl14, pll.refdivCtrl14, 0xFFFFF0FF'u32, (ratio.uint32 shl 8) and 0xF00)
  put(want.fractionalDividerWord28, pll.fractionalDividerWord28, 0xFC000000'u32,
      VendorFraction[frequencySlot(mask)][ratio.int] and 0x3FFFFFF)
  if board and (mask and 2) != 0:
    put(want.fractionalDividerWord28, pll.fractionalDividerWord28, 0x7BFFFFFF'u32, 0)
    put(want.modeCtrl2c, pll.modeCtrl2c, 0xFFFFFECF'u32, 0)
    put(wantRf.optimizeCtrlD0, rf70.optimizeCtrlD0, 0xFFFFFFF0'u32, 0)
    put(want.loopFilter18, pll.loopFilter18, 0xFFFFFE0F'u32, 0x20)
    put(want.fractionalCtrl1c, pll.fractionalCtrl1c, 0xFFF80FFE'u32, 0x36100)
  elif not board or (mask and 16) != 0:
    put(want.fractionalDividerWord28, pll.fractionalDividerWord28, 0xFFFFFFFF'u32, 0x84000000'u32)
    put(want.modeCtrl2c, pll.modeCtrl2c, 0xFFFFFFFF'u32, 0x130)
    put(wantRf.optimizeCtrlD0, rf70.optimizeCtrlD0, 0xFFFFFFFE'u32, 0xE)
    put(want.loopFilter18, pll.loopFilter18, 0xFFFFFE0F'u32, 0x20)
    put(want.fractionalCtrl1c, pll.fractionalCtrl1c, 0xFFF80FFE'u32, 0x36100)
    put(want.modeCtrl2c, pll.modeCtrl2c, 0xFFFCFFFF'u32, 0x10000)
  put(want.pllReset10, pll.pllReset10, 0xFFFFFFFA'u32, 0)
  put(want.pllReset10, pll.pllReset10, 0xFFFFFFFF'u32, 1)
  put(want.pllReset10, pll.pllReset10, 0xFFFFFFFF'u32, 4)
  put(want.enableCtrl30, pll.enableCtrl30, 0xFFFFFFF3'u32, 0x1FF3)
  for i in 0 ..< 12: reads.add(cast[uint](addr pll.enableCtrl30))
  wb03 = board
  rfPriWifiPllConfig()
  doAssert pll == want and rf70 == wantRf, "PLL fields differ from vendor operations"
  doAssert mmioWrites == trace, "PLL writes differ in value or order"
  doAssert mmioReads == reads, "PLL read order or settling-read count differs"
'''

@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_selector_is_state_only_and_preserves_unknown_selection(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, xtal_source() + r'''
crystalSetup()
for mask in 0 ..< 64:
  setFlags(mask)
  seedPll()
  let before = registerStorage
  let beforePll = pll
  let oldRow = bl808RfPriXtalTableIndex
  let oldRatio = bl808RfPriPllRefdivRatio
  let oldFcal = bl808RfPriFcalDiv
  rf_pri_xtalfreq()
  doAssert registerStorage == before and pll == beforePll
  doAssert mmioWrites.len == 0 and mmioReads.len == 0, "selector performed MMIO"
  var row = -1
  for i in 0 ..< 6:
    if (mask and (1 shl i)) != 0: row = i; break
  doAssert bl808RfPriXtalTableIndex == (if row < 0: oldRow else: row.int8)
  doAssert bl808RfPriPllRefdivRatio == (if row < 0: oldRatio else: ReferenceDividers[row])
  doAssert bl808RfPriFcalDiv == (if row < 0: oldFcal else: FcalDividers[row])
''')

@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_pll_exact_fields_trace_and_float32_results(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, xtal_source() + r'''
let frequencies = [24'f32, 26, 32, 38.4, 40, 52]
for slot in 0 ..< 6:
  for ratio in 0 ..< 3:
    doAssert VendorFraction[slot][ratio] ==
      uint32(float32((ratio * 15) shl 25) / frequencies[slot])
for board in [false, true]:
  for mask in 0 ..< 64:
    crystalSetup()
    setFlags(mask)
    var row = -1
    for i in 0 ..< 6:
      if (mask and (1 shl i)) != 0: row = i; break
    let ratio = if row < 0: 1'u16 else: ReferenceDividers[row]
    rf_pri_xtalfreq()
    seedPll()
    checkPll(mask, ratio, board)
''')

@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_reference_divider_is_latched_until_selection(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, xtal_source() + r'''
crystalSetup()
seedPll()
checkPll(16, 1, false)
for row in 0 ..< 6:
  let old = bl808RfPriPllRefdivRatio
  rf_pri_input_xtalfreq(Frequencies[row])
  doAssert rf_pri_get_xtalfreq() == Frequencies[row]
  doAssert rfPriXtalRefdivRatio() == old.uint32, "input flags changed latched reference divider"
  seedPll()
  checkPll(1 shl row, old, false)
  rf_pri_xtalfreq()
  doAssert rfPriXtalRefdivRatio() == ReferenceDividers[row].uint32
  rf_pri_input_xtalfreq(123)
  doAssert rf_pri_get_xtalfreq() == 0
  rf_pri_xtalfreq()
  doAssert rfPriXtalRefdivRatio() == ReferenceDividers[row].uint32
  seedPll()
  checkPll(0, ReferenceDividers[row], false)
''')

@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_calibration_channel_uses_selected_divider_bank(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, xtal_source() + r'''
for row in 0 ..< 6:
  crystalSetup()
  rf_pri_input_xtalfreq(Frequencies[row])
  rf_pri_xtalfreq()
  rfCalibDataGlobal = addr calibration[0]
  rf70.channelCalStatusB4 = 0
  for channel in 0 ..< 21:
    rf70.sdmDivC4 = randomWord()
    let high = rf70.sdmDivC4 and 0xC0000000'u32
    rfPriConfigChannelForCal(channel)
    doAssert rf70.sdmDivC4 == (high or (VendorDiv[row][channel] and 0x3FFFFFFF))
    doAssert nim_wifi_rf_last_config_channel_sdm2 == VendorDiv[row][channel]
  rf_pri_input_xtalfreq(123)
  rf_pri_xtalfreq()
  rfPriConfigChannelForCal(0)
  doAssert (rf70.sdmDivC4 and 0x3FFFFFFF) == (VendorDiv[row][0] and 0x3FFFFFFF)
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_lo_consumers_wait_for_a_valid_table_selection(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, xtal_source() + r'''
crystalSetup()
rfCalibDataGlobal = addr calibration[0]
rf_pri_input_xtalfreq(123)
rf_pri_xtalfreq()
let before = registerStorage
mmioWrites.setLen(0)
mmioReads.setLen(0)
runRfPriLoFcal()
runRfPriLoAcal()
rfPriConfigChannelForCal(0)
doAssert registerStorage == before
doAssert mmioWrites.len == 0 and mmioReads.len == 0
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_fcal_setup_uses_selected_divider_and_count_bounds(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, xtal_source() + r'''
for row in 0 ..< 6:
  crystalSetup()
  rf_pri_input_xtalfreq(Frequencies[row])
  rf_pri_xtalfreq()
  rf70.calResultA8 = randomWord()
  let high = rf70.calResultA8 and 0xFFFF0000'u32
  prepareRfPriLoFcal()
  doAssert rf70.calResultA8 == (high or FcalDividers[row].uint32)
  sampleCount = VendorRange[row][1] - 1
  sampleIndex = 0
  doAssert chooseRfBaseFcalCode() == 0x80
  doAssert sampleIndex == 1, "coarse search used another crystal's count range"
''')

@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_lo_calibration_consumes_selected_count_and_divider_tables(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, xtal_source() + r'''
for row in 0 ..< 6:
  crystalSetup()
  rf_pri_input_xtalfreq(Frequencies[row])
  rf_pri_xtalfreq()
  rfCalibDataGlobal = addr calibration[0]
  let limits = VendorRange[row]
  sampleValues = @[(limits[0] + (limits[1] - limits[0]) div 2).uint16,
                   VendorCnt[row][0] - 1, VendorCnt[row][0] + 1,
                   limits[2] + 1]
  runRfPriLoFcal()
  doAssert sampleIndex == 4, "FCAL stop threshold came from another bank"
  doAssert loFcalValues[0] == 0x81
  mmioWrites.setLen(0)
  runRfPriLoAcal()
  var dividers: seq[uint32]
  for event in mmioWrites:
    if event.address == cast[uint](addr rf70.sdmDivC4): dividers.add(event.value)
  doAssert dividers.len == 21
  for i in 0 ..< 21: doAssert dividers[i] == VendorDiv[row][i]
''')
