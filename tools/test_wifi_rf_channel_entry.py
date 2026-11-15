"""Channel-entry modem/RF register contracts from the selected RF archive."""

from pathlib import Path
import re

import pytest

from test_wifi_disconnect_tx import procedure
from test_wifi_message_allocation import run_program
from test_wifi_rf_power_replay import RF, object_type, source
from test_wifi_rf_xtal_pll import xtal_source
from test_wifi_sta_tx_channel import source as sta_source


def rf_procedure(text: str, name: str) -> str:
    starts = list(re.finditer(rf"^proc {name}\*?\(", text, re.M))
    body = procedure(text[starts[-1].start():], name)
    return re.split(r"^(?:var|type|const|let)\b", body, maxsplit=1, flags=re.M)[0] + "\n"


def modem_source() -> str:
    rf = RF.read_text()
    code = source(real_io=True)
    for name in ("WifiModemBlock", "BbaAgcBlock", "MacPhyCtrlBlock"):
        code += object_type(rf, name)
    code += r'''
var
  modemWords: array[(0xB000 + sizeof(BbaAgcBlock) + 3) div 4, uint32]
  macWords: array[(sizeof(MacPhyCtrlBlock) + 3) div 4, uint32]
  resets: int
  assertions: seq[tuple[line, stores: int]]
proc wifiModemRegs(): ptr WifiModemBlock = cast[ptr WifiModemBlock](addr modemWords[0])
proc bbaAgcRegs(): ptr BbaAgcBlock = cast[ptr BbaAgcBlock](addr modemWords[0xB000 div 4])
proc macPhyCtrlRegs(): ptr MacPhyCtrlBlock = cast[ptr MacPhyCtrlBlock](addr macWords[0])
proc crm_mdm_reset() =
  doAssert mmioWrites.len == 0
  inc resets
proc wrapPhyAssertErr(condition, file: cstring; line: cint) =
  assertions.add((line.int, mmioWrites.len))
'''
    code += rf_procedure(rf, "bl808MdmSetChannel")
    return code + r'''
proc checkModem(primary, center, kind: uint32) =
  setup()
  for word in modemWords.mitems: word = randomWord()
  for word in macWords.mitems: word = randomWord()
  let beforeRf = registerStorage
  var wanted = modemWords
  var wantedMac = macWords
  var trace: seq[tuple[address: uint, value: uint32]]
  var warnings: seq[tuple[line, stores: int]]
  resets = 0
  assertions.setLen(0)
  template put(offset: int; keep, value: uint32) =
    wanted[offset div 4] = (wanted[offset div 4] and keep) or value
    trace.add((cast[uint](addr modemWords[offset div 4]), wanted[offset div 4]))
  template warn(line: int) = warnings.add((line, trace.len))
  let signedCenter = if center > 0x7FFFFFFF'u32: center.int64 - 4294967296'i64 else: center.int64
  let divider = (if center == 0: -1'i64 else: 67108864'i64 div signedCenter) and 65535
  if divider > 32767: warn(0x2A60)
  let ratio = if primary == 0: 65535'u32 else:
    ((((center.uint64 * 32768) and 0xFFFFFFFF'u64) div primary.uint64) and 65535).uint32
  put(0x84C, 0xFFFF8000'u32, divider.uint32)
  put(0x8EC, 0, ratio)
  let txBits = kind shl 24
  if kind == 1:
    let side = (primary >= center).uint32
    put(0xB080, 0, side + 1)
    put(0x848, 0, side)
  else:
    put(0xB080, 0, 0)
    put(0x848, 0, 0)
    if (txBits and 0xFCFFFFFF'u32) != 0: warn(0x20FA)
  put(0x824, 0xFCFFFFFF'u32, txBits)
  if ((kind shl 16) and 0xFFFCFFFF'u32) != 0: warn(0x307B)
  wantedMac[0x310 div 4] = (wantedMac[0x310 div 4] and 0xFFFCFFFF'u32) or (kind shl 16)
  trace.add((cast[uint](addr macWords[0x310 div 4]), wantedMac[0x310 div 4]))
  put(0x808, 0, 0xF7C0FBFF'u32)
  if (kind and 0xFFFFFFF0'u32) != 0: warn(0x16BA)
  put(0x800, 0xFFFFFFF0'u32, kind)
  if (txBits and 0xFCFFFFFF'u32) != 0: warn(0x1EEA)
  put(0x820, 0xFCFFFFFF'u32, txBits)
  put(0x890, 0xFFFFFFFD'u32, 0)
  put(0x894, 0x00FFFFFF'u32, 0)
  if kind == 0:
    put(0x838, 0, 0x180)
    put(0x81C, 0, 0x02000F0A)
    put(0x804, 0x00FFFFFF'u32, 0x19000000)
    put(0x834, 0x00FFFFFF'u32, 0x01000000)
    put(0xB374, 0xFCFFFFFF'u32, 0x03000000)
    put(0x870, 0x00FFFFFF'u32, 0x01000000)
    put(0x84C, 0xFDFFFFFF'u32, 0)
    put(0x88C, 0xFFFF00FF'u32, 0x2100)
    for offset in [0xB340, 0xB344, 0xB348]: put(offset, 0, 0)
  else:
    if kind == 1:
      put(0x838, 0, 0x180)
      put(0x81C, 0, 0x03001E1F)
      put(0x804, 0x00FFFFFF'u32, 0x18000000)
      put(0x804, 0xFFFFFF00'u32, 0xB)
      put(0x88C, 0xFFFF00FF'u32, 0x1100)
      put(0x890, 0xFFFFFFFF'u32, 2)
    put(0xB340, 0, 0x02040507)
    put(0xB344, 0, 1)
    put(0xB348, 0, 0)
    put(0xB378, 0x80FFFFFF'u32, 0x08000000)
    put(0xB374, 0xFCFFFFFF'u32, 0)
  put(0x894, 0, 7)
  bl808MdmSetChannel(primary, center, kind)
  doAssert resets == 1 and assertions == warnings, "modem assertions or their order differ"
  doAssert modemWords == wanted and macWords == wantedMac and registerStorage == beforeRf,
    "modem channel setup changed the wrong field or omitted its profile"
  doAssert mmioWrites == trace, "modem channel store order differs"
'''


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_modem_divider_ratio_sideband_and_profiles(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, modem_source() + r'''
for kind in 0'u32 .. 3:
  for pair in [(2412'u32, 2412'u32), (2412'u32, 2422'u32),
               (2432'u32, 2422'u32), (5180'u32, 5210'u32)]:
    for vector in 0 ..< 20: checkModem(pair[0], pair[1], kind)
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_modem_returning_asserts_keep_raw_field_values(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, modem_source() + r'''
for kind in [0'u32, 1, 4, 15, 16, 255, 65536, high(uint32)]:
  for pair in [(0'u32, 0'u32), (0'u32, 2412'u32), (2412'u32, 0'u32),
               (1'u32, 1'u32), (2412'u32, 0x80000000'u32), (2412'u32, high(uint32))]:
    checkModem(pair[0], pair[1], kind)
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
@pytest.mark.parametrize("initial", [False, True])
def test_phy_entrypoints_have_only_vendor_channel_calls(tmp_path: Path, mode: str, initial: bool) -> None:
    rf = RF.read_text()
    code = sta_source().replace(
        "proc rfPriApplyWb03RfcEntryBaseline() = discard",
        'proc rfPriApplyWb03RfcEntryBaseline() = calls.add("extra-baseline")',
    ).replace(
        "proc pulsePhyChannelRfWindow() = discard",
        'proc pulsePhyChannelRfWindow() = calls.add("extra-pulse")',
    ).replace(
        "proc rfc_config_channel(center: uint32) = programmed.add(center)",
        'proc rfc_config_channel(center: uint32) =\n  programmed.add(center)\n  calls.add("rf-channel")',
    )
    code += "var nimFwDbgPhyInitPhase: uint32\n" + rf_procedure(rf, "phyInitProgramInitialChannel")
    code += f"const Initial = {str(initial).lower()}\n"
    run_program(tmp_path, mode, code + r'''
setup()
let before = phy
when Initial:
  phyInitProgramInitialChannel()
  doAssert phy == before and programmed == @[2412'u32]
  doAssert calls == @["clock", "modem", "bandwidth", "rf-channel"]
else:
  var channel = ChanCtxtDefView(band: 1, chanType: 1, primFreq: 2412,
    centerFreq1: 2422, txPower: 17)
  phy_set_channel(addr channel, 0)
  doAssert programmed == @[2422'u32] and matches(channel)
  doAssert calls == @["clock", "modem", "bandwidth", "rf-channel", "rate-power"]
''')


def eventful(code: str) -> str:
    code = code.replace("proc volatileLoad(p: ptr uint32): uint32 =", r'''
var events: seq[tuple[address: uint, value: uint32]]
proc volatileLoad(p: ptr uint32): uint32 =''')
    return code.replace(
        "if recordWrites: mmioWrites.add((address, value))",
        "if recordWrites:\n    mmioWrites.add((address, value))\n    events.add((address, value))",
    )


def rfc_source() -> str:
    rf = RF.read_text()
    code = eventful(source(real_io=True)) + r'''
proc waitRfUs(us: uint32) = events.add((0'u, us))
proc rf_pri_update_param(freq: uint32) = events.add((1'u, freq))
proc rfPriApplyNotchParam(freq: uint32) = events.add((2'u, freq))
proc rf_pri_set_channel_pwr_comp(index: uint32) = events.add((3'u, index))
proc rf_pri_optimize(freq: uint32) = events.add((4'u, freq))
proc rfPhyTraceCheckpoint(tag: uint32) = discard
'''
    return code + rf_procedure(rf, "channelPowerIndex") + rf_procedure(rf, "rfc_config_channel")


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_rfc_strobes_delays_and_followup_match_vendor(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, rfc_source() + r'''
for freq in [0'u32, 2412, 2422, 2472, 2484, 5210, high(uint32)]:
  for vector in 0 ..< 100:
    setup()
    events.setLen(0)
    for word in registerStorage.mitems: word = randomWord()
    var wanted = registerStorage
    var trace: seq[tuple[address: uint, value: uint32]]
    template put(offset: int; keep, value: uint32) =
      wanted[offset div 4] = (wanted[offset div 4] and keep) or value
      trace.add((cast[uint](addr registerStorage[offset div 4]), wanted[offset div 4]))
    put(0x228, 0xFFFFFFFF'u32, 8)
    put(0x2C, 0xFFFFFFFF'u32, 0x40)
    put(0x2C, 0xFFFFFFFF'u32, 0x200)
    put(0x2C, 0xFFFFFFFF'u32, 1)
    put(0x264, 0xFFFFF000'u32, freq and 4095)
    put(0x268, 0xFFFDFFFF'u32, 0x20000)
    put(0x268, 0xFFFDFFFF'u32, 0)
    put(0x04, 0xFFFFFFFF'u32, 2)
    trace.add((0'u, 1'u32))
    put(0x26C, 0xFFFFFFF8'u32, 1)
    trace.add((0'u, 1'u32))
    put(0x26C, 0xFFFFFFFF'u32, 8)
    trace.add((0'u, 1'u32))
    put(0x26C, 0xFFFFFFF8'u32, 2)
    trace.add((0'u, 100'u32))
    put(0x26C, 0xFFFFFFF7'u32, 0)
    trace.add((0'u, 1'u32))
    put(0x228, 0xFFFFFFF7'u32, 0)
    trace.add((1'u, freq))
    trace.add((3'u, channelPowerIndex(freq)))
    trace.add((4'u, freq))
    rfc_config_channel(freq)
    doAssert registerStorage == wanted and events == trace,
      "RFC channel tune inserted a notch write, extra delay, or wrong strobe"
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_power_channel_index_uses_vendor_low_halfword_range_and_byte_result(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, rfc_source() + r'''
for highPart in [0'u32, 1, 32768, 65535]:
  for lowPart in 0'u32 .. 65535:
    let freq = (highPart shl 16) or lowPart
    let difference = (freq.uint64 + 4294967296'u64 - 2412) and 65535
    var wanted = 0'u32
    if difference <= 72:
      if freq == 2484: wanted = 14
      else:
        let shifted = (freq.uint64 + 4294967296'u64 - 2407) and 0xFFFFFFFF'u64
        let signed = if shifted > 0x7FFFFFFF'u64: shifted.int64 - 4294967296'i64 else: shifted.int64
        wanted = ((signed div 5) and 255).uint32
    doAssert channelPowerIndex(freq) == wanted
''')


def calibration_source() -> str:
    code = eventful(xtal_source()).replace("RfConfigChannelWaitLimit = 2", "RfConfigChannelWaitLimit = 5000")
    code = code.replace("proc waitRfUs(us: uint32) = discard", "proc waitRfUs(us: uint32) = events.add((0'u, us))")
    code = code.replace("proc volatileLoad(p: ptr uint32): uint32 =", r'''
var busyReads, statusReads: int
var busyMask: uint32
proc volatileLoad(p: ptr uint32): uint32 =
  if p == addr rf70.channelCalStatusB4:
    inc statusReads
    return (if statusReads <= busyReads: busyMask else: 0'u32)
''')
    return code + r'''
proc channelSetup(row: int) =
  crystalSetup()
  rfCalibDataGlobal = addr calibration[0]
  bl808RfPriXtalTableIndex = row.int8
  for word in registerStorage.mitems: word = randomWord()
  events.setLen(0)
  busyReads = 0
  statusReads = 0
  busyMask = 0x01100000
'''


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_private_channel_preserves_rfbc_bits_and_selected_calibration(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, calibration_source() + r'''
for row in 0 ..< 6:
  for channel in 0 ..< 21:
    for fcal in [0'u16, 16, 127, 255]:
      channelSetup(row)
      loFcalValues[channel] = fcal
      loAcalValues[channel] = (randomWord() and 63).uint16
      let before = registerStorage
      let acal = loAcalValues[channel].uint32
      var wanted = before
      wanted[0x30 div 4] = wanted[0x30 div 4] or 0xF00000
      wanted[0xA0 div 4] = (wanted[0xA0 div 4] and 0xFFC0FF00'u32) or fcal.uint32 or (acal shl 16)
      wanted[0xBC div 4] = (wanted[0xBC div 4] and 0xFF0FFFFF'u32) or ((fcal.uint32 shr 4) shl 20)
      wanted[0xC4 div 4] = (wanted[0xC4 div 4] and 0xC0000000'u32) or VendorDiv[row][channel]
      wanted[0xC0 div 4] = wanted[0xC0 div 4] and 0xFFFFEFFF'u32
      wanted[0xB8 div 4] = wanted[0xB8 div 4] and 0xFFFEFFFF'u32
      wanted[0xB0 div 4] = wanted[0xB0 div 4] and 0xEFFFFFFF'u32
      rfPriConfigChannelForCal(channel)
      doAssert registerStorage == wanted and statusReads == 1,
        "private channel configuration changed RFBC unowned bits or the saved LO fields"
''')


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_private_channel_waits_for_both_busy_bits_before_returning(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, calibration_source() + r'''
for mask in [0x00100000'u32, 0x01000000, 0x01100000]:
  for delay in [0, 1, 4999, 5000, 10001]:
    channelSetup(4)
    busyMask = mask
    busyReads = delay
    let previous = nim_wifi_rf_config_channel_wait_timeout_count
    rfPriConfigChannelForCal(9)
    doAssert statusReads == delay + 1 and nim_wifi_rf_last_config_channel_status == 0,
      "channel calibration returned while hardware remained busy"
    doAssert nim_wifi_rf_config_channel_wait_timeout_count == previous + (delay div 5000).uint32
    var waits: seq[uint32]
    for event in events:
      if event.address == 0: waits.add(event.value)
    doAssert waits.len == (delay + 1) * 4
    for i, wait in waits: doAssert wait == [10'u32, 50, 10, 50][i mod 4]
''')


def optimize_source() -> str:
    rf = RF.read_text()
    code = xtal_source().replace(
        "proc rfPriRf70ReplayWindow0Nibble(): uint32 = 9",
        "proc rfPriRf70ReplayWindow0Nibble(): uint32 = "
        "(cast[ptr UncheckedArray[uint32]](rfCalibDataGlobal)[3] shr 24) and 15",
    )
    code += "const RfPriStageSnapshotEntries = 8\nconst RfCalibRf70ReplayHighBandWordIndex = 4\n"
    for name in ("RfOptimizeMidBandMask", "RfOptimizeMidBandFirstMhz", "RfOptimizeMidBandLastMhz",
                 "RfOptimizeTxcalFirstMhz", "RfOptimizeTxcalLastMhz", "RfOptimizeWb03PllEdge0Mhz",
                 "RfOptimizeWb03PllEdge1Mhz"):
        code += "const\n" + next(line for line in rf.splitlines() if line.startswith("  " + name + " =")) + "\n"
    code += r'''
var
  bl808RfDeviceBl616, bl808RfDeviceWb03, bl808RfDeviceBl618m: uint8
  bl808RfChannelMhz, nim_wifi_rf_optimize_count: uint32
  nim_wifi_rf_optimize_channel_log, nim_wifi_rf_optimize_device_log: array[8, uint32]
  nim_wifi_rf_optimize_rfd0_log, nim_wifi_rf_optimize_nibble_log: array[8, uint32]
  nim_wifi_rf_optimize_rf70_log: array[8, uint32]
proc rfPriDeviceTraceWord(): uint32 = 0
'''
    for name in ("rfCalibRf70ReplayHighBandWord", "rfPriRf70ReplayWindow2Nibble",
                 "rfPriApplyWb03Non40OptimizePll", "rf_pri_optimize"):
        code += rf_procedure(rf, name)
    return code


@pytest.mark.parametrize("mode", ["checked", "asan", "firmware"])
def test_optimizer_gates_masks_wrapped_windows_and_store_order(tmp_path: Path, mode: str) -> None:
    run_program(tmp_path, mode, optimize_source() + r'''
for devices in 0 ..< 8:
  for flags in 0 ..< 4:
    for freq in [2451'u32, 2452, 2462, 2472, 2473, 2484, 2485,
                 67988, 0x80000994'u32, high(uint32)]:
      for vector in 0 ..< 10:
        crystalSetup()
        rfCalibDataGlobal = addr calibration[0]
        for word in calibration.mitems: word = randomWord()
        for word in registerStorage.mitems: word = randomWord()
        let pllWords = cast[ptr UncheckedArray[uint32]](addr pll)
        for i in 0 ..< sizeof(pll) div 4: pllWords[i] = randomWord()
        wb03 = (devices and 2) != 0
        bl808RfDeviceBl616 = (devices and 1).uint8
        bl808RfDeviceWb03 = ((devices shr 1) and 1).uint8
        bl808RfDeviceBl618m = ((devices shr 2) and 1).uint8
        bl808RfPriXtal40mFlag = (flags and 1).uint8
        bl808RfPriXtal26mFlag = ((flags shr 1) and 1).uint8
        bl808RfXtalIndex = if (flags and 1) != 0: 4'u32 else: 1'u32
        var wanted = registerStorage
        var wantedPll = pll
        var trace: seq[tuple[address: uint, value: uint32]]
        if devices != 0 and (flags and 1) != 0:
          let middle = (((freq.uint64 + 4294967296'u64 - 2452) and 65535) <= 20)
          wanted[0xD0 div 4] = (wanted[0xD0 div 4] and 0xFFFFFFFE'u32) or (not middle).uint32
          trace.add((cast[uint](addr rf70.optimizeCtrlD0), wanted[0xD0 div 4]))
        if (devices and 2) != 0 and flags == 2:
          let edge = freq in [2452'u32, 2472]
          wantedPll.loopFilter18 = (wantedPll.loopFilter18 and (if edge: 0xFFFFFE0F'u32 else: 0xFFFFFF0F'u32)) or
            (if edge: 0x20'u32 else: 0x140'u32)
          wantedPll.fractionalCtrl1c = (wantedPll.fractionalCtrl1c and (if edge: 0xFFF80FFE'u32 else: 0xFFF80EFF'u32)) or
            (if edge: 0x36100'u32 else: 0x5A001'u32)
          trace.add((cast[uint](addr pll.loopFilter18), wantedPll.loopFilter18))
          trace.add((cast[uint](addr pll.fractionalCtrl1c), wantedPll.fractionalCtrl1c))
        let highBand = (((freq.uint64 + 4294967296'u64 - 2462) and 65535) <= 22)
        let nibble = if highBand: (calibration[4] shr 4) and 15 else: (calibration[3] shr 24) and 15
        wanted[0x70 div 4] = (wanted[0x70 div 4] and 0xFFFFFFF0'u32) or nibble
        trace.add((cast[uint](addr rf70.txcalParam70), wanted[0x70 div 4]))
        rf_pri_optimize(freq)
        doAssert registerStorage == wanted and pll == wantedPll and mmioWrites == trace,
          "optimizer gate, PLL field, wrapped range, or PLL-before-RF70 order differs"
''')
