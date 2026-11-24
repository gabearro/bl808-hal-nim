## BL808 WiFi demo rf_pri.o: rf_pri_rccal and rf_pri_rccal.part.0.

proc stageBl808RccalTone(reference: bool) =
  let rf = rfRegs()
  let tone = if reference: 0x3100'u32 else: 0x6200'u32
  let frequency = if reference: 0x00030000'u32 else: 0x00B50000'u32
  updateReg32(addr rf.rccalTone48, 0xFFFF8CFF'u32, tone)
  updateReg32(addr rf.calSingenCtrl20c, 0xFC00FFFF'u32, frequency)
  updateReg32(addr rf.calSingenAmpLo214, 0x003FFFFF'u32, 0'u32)
  updateReg32(addr rf.calSingenAmpHi218, 0x003FFFFF'u32, 0xC0000000'u32)
  if reference:
    updateReg32(addr rf.calSingenAmpLo214, 0xFFFFF800'u32, 0xFF'u32)
    updateReg32(addr rf.calSingenAmpHi218, 0xFFFFF800'u32, 0xFF'u32)
  updateReg32(addr rf.calSingenCtrl20c, 0x7FFFFFFF'u32, 0'u32)
  updateReg32(addr rf.calSingenCtrl20c, not 0'u32, 0x80000000'u32)
  startRfPriTxDfeForCal()
  let measure = if reference: 0xC00'u32 else: 0x2D400'u32
  updateReg32(addr rf.measureCtrl618, 0xFFF00000'u32, measure)

proc prepareBl808Rccal() =
  let rf = rfRegs()
  programRfPriModeRegisters(0x2DF8F8FF'u32, 0x2DF87800'u32)
  waitBl808RfCalUs(0'u32)
  startRfPriTxDfeForCal()
  updateReg32(addr rf.rxMode220, not 0x60'u32, 0'u32)
  updateReg32(addr rf.rxMode220, not 0'u32, 0x21'u32)
  updateReg32(addr rf.rxMode220, not 0'u32, 0x40'u32)
  updateReg32(addr rf.rccalReplay84, not 0x30000'u32, 0'u32)
  updateReg32(addr rf.rccalReplay84, 0xFCFFFFFF'u32, 0x02000000'u32)
  updateReg32(addr rf.calPathConfig8c, not 0'u32, 0x1000'u32)
  updateReg32(addr rf.calCtrl1c, not 0'u32, 0x800'u32)
  updateReg32(addr rf.calMeasurePrep60c, not 0x400'u32, 0'u32)
  updateReg32(addr rf.calMeasurePrep60c, not 0'u32, 0x04000000'u32)
  stageBl808RccalTone(true)

  # The priming trigger reads I only; the following reference sample reads I/Q.
  updateReg32(addr rf.measureCtrl618, not RfMeasureRccalTriggerMask, 0'u32)
  updateReg32(addr rf.measureMode61c, 0x0000FFFF'u32, 0x04000000'u32)
  updateReg32(addr rf.measureCtrl618, not 0'u32, RfMeasureStartMask)
  discard waitRfRccalMeasurementReady()
  discard volatileLoad(addr rf.measureI620)
  updateReg32(addr rf.measureCtrl618, not RfMeasureRccalTriggerMask, 0'u32)

proc searchBl808Rccal(): bool =
  let rf = rfRegs()
  let baseline = sampleRfRccalPower()
  # +0x2e2..0x302: truncate unsigned power * binary64 0.81. Across the
  # signed-16 I/Q power range this is floor(power * 81 / 100), without wrap.
  let target = (baseline div 100) * 81 + ((baseline mod 100) * 81) div 100
  nim_wifi_rf_last_rccal_baseline = baseline
  nim_wifi_rf_last_rccal_target = target
  nim_wifi_rf_rccal_search_log = default(typeof(nim_wifi_rf_rccal_search_log))
  nim_wifi_rf_rccal_power_log = default(typeof(nim_wifi_rf_rccal_power_log))
  var logIndex = 0
  template aboveTarget(candidate: int32): bool =
    let raw = cast[uint32](candidate)
    # The fine walk can cross 0 or 63. Both shifts use the full RV32
    # candidate before the store; the extracted result lanes are six bits.
    updateReg32(addr rf.rbbRccalCtrl80, 0xC0FFC0FF'u32, (raw shl 24) or (raw shl 8))
    let power = sampleRfRccalPower()
    nim_wifi_rf_last_rccal_code = raw and 63
    nim_wifi_rf_last_rccal_power = power
    logRfRccalSearch(logIndex, raw, power)
    power > target

  stageBl808RccalTone(false)
  var code = 0'i32
  for bit in countdown(5, 0):
    let candidate = code + (1'i32 shl bit)
    if aboveTarget(candidate):
      code = candidate
  var history = 0
  for _ in 0 ..< 63:
    let above = aboveTarget(code)
    history = ((history shl 1) or ord(above)) and 15
    if history == 5 or history == 10:
      return true
    code += (if above: 1'i32 else: -1'i32)
  false

proc publishBl808Rccal() =
  let rf80 = addr rfRegs().rbbRccalCtrl80
  let records = cast[ptr UncheckedArray[uint32]](rfCalibDataGlobal)
  let word = addr records[RfCalibRccalReplayWordIndex]
  let lanes = volatileLoad(rf80)
  # +0x554/+0x568/+0x57c/+0x592: pack the two measured lanes, then
  # duplicate each from its saved field, leaving the upper byte untouched.
  updateReg32(word, 0xFFFFFFC0'u32, (lanes shr 24) and 63)
  updateReg32(word, 0xFFFC0FFF'u32, ((lanes shr 8) and 63) shl 12)
  let upper = volatileLoad(word) and 63
  updateReg32(word, 0xFFFFF03F'u32, upper shl 6)
  let lower = (volatileLoad(word) shr 12) and 63
  updateReg32(word, 0xFF03FFFF'u32, lower shl 18)
  let iq0 = volatileLoad(word) and 63
  updateReg32(rf80, 0xC0FFC0FF'u32, (iq0 shl 24) or (iq0 shl 8))
  let iq1 = (volatileLoad(word) shr 6) and 63
  updateReg32(rf80, 0xFFC0FFC0'u32, (iq1 shl 16) or iq1)
  # +0x5ec..0x5f2: result readback for the demo diagnostic, before restore.
  for _ in 0 ..< 4:
    discard volatileLoad(word)

proc runBl808Rccal() =
  let rf = rfRegs()
  if (volatileLoad(addr rf.capability20) and RfRccalCapabilityMask) == 0:
    updateReg32(addr rf.calMode14, not RfRccalModeMask, 0'u32)
    return
  if rfCalibDataGlobal == nil:
    return
  inc nim_wifi_rf_pri_rccal_count
  updateReg32(addr rf.calMode14, not RfRccalModeMask, RfRccalStartMode)
  let saved = saveBl808CalibrationState()
  prepareBl808Rccal()
  let converged = searchBl808Rccal()
  publishBl808Rccal()
  restoreBl808CalibrationState(saved)
  updateReg32(addr rf.calPathConfig8c, not 0x1000'u32, 0'u32)
  if converged:
    updateReg32(addr rf.calMode14, not 0'u32, RfRccalDoneMode)
  else:
    updateReg32(addr rf.calMode14, not RfRccalModeMask, RfRccalFailMode)
