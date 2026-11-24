proc sampleBl808RoscalCode(iBranch: bool; code: int32): RfRoscalSample =
  # rf_pri_roscal_iq.constprop.0 updates RF7C, not legacy RF80. The
  # candidate is ORed untruncated, including when the fine search leaves 0..63.
  let shift = if iBranch: 8 else: 0
  updateReg32(addr rfRegs().roscalCtrl7c, not (RfRoscalCodeMask shl shift),
              cast[uint32](code) shl shift)
  sampleRfRoscalMeasurement(iBranch)

proc searchBl808RoscalCode(iBranch: bool): int32 =
  var step = 32'i32
  var logIndex = if iBranch: 0 else: 8
  while step != 0:
    let candidate = result + step
    let sample = sampleBl808RoscalCode(iBranch, candidate)
    logRfRoscalSearch(logIndex, iBranch, cast[uint32](candidate), sample)
    if sample.signed <= 0:
      result = candidate
    step = step shr 1

  var history = 0'u32
  for attempt in 0 ..< 63:
    let sample = sampleBl808RoscalCode(iBranch, result)
    if attempt < 2:
      logRfRoscalSearch(logIndex, iBranch, cast[uint32](result), sample)
    history = ((history shl 1) or uint32(sample.signed > 0)) and 0xF'u32
    if sample.signed > 0: dec result
    else: inc result
    if history == 5 or history == 10:
      break

proc publishBl808RoscalCode(iBranch: bool; code: int32) =
  let rf = rfRegs()
  let raw = cast[uint32](code)
  let packedShift = if iBranch: 0 else: 6
  let byteShift = if iBranch: 0 else: 8
  # rf_pri_roscal.part.0+0x118..0x2c4 interleaves each packed store with
  # its live lane write. Only the RAM field receives an explicitly masked code.
  for slot, index in [24, 22, 20, 18]:
    let words = cast[ptr UncheckedArray[uint32]](rfCalibDataGlobal)
    updateReg32(addr words[index], not (RfRoscalCodeMask shl packedShift),
                (raw and RfRoscalCodeMask) shl packedShift)
    let reg = if slot < 2: addr rf.roscalCal1 else: addr rf.roscalCal0
    let shift = byteShift + (if (slot and 1) == 0: 16 else: 0)
    updateReg32(reg, not (RfRoscalCodeMask shl shift), raw shl shift)
  if iBranch: nim_wifi_rf_last_roscal_i = raw and RfRoscalCodeMask
  else: nim_wifi_rf_last_roscal_q = raw and RfRoscalCodeMask

proc runBl808Roscal() =
  let rf = rfRegs()
  if (volatileLoad(addr rf.capability20) and RfRoscalCapabilityMask) == 0:
    updateReg32(addr rf.calMode14, not RfRoscalModeMask, 0'u32)
    return
  if rfCalibDataGlobal == nil:
    return
  inc nim_wifi_rf_pri_roscal_count
  updateReg32(addr rf.calMode14, not RfRoscalModeMask, RfRoscalStartMode)
  let saved = saveBl808CalibrationState()
  programRfPriModeRegisters(0x21F0FEFF'u32, 0x21F06E00'u32)
  waitBl808RfCalUs(0'u32)
  startRfPriTxDfeForCal()
  updateReg32(addr rf.rxMode220, not 0x60'u32, 0'u32)
  updateReg32(addr rf.rxMode220, not 0'u32, 0x21'u32)
  updateReg32(addr rf.rxMode220, not 0'u32, 0x40'u32)
  updateReg32(addr rf.calCtrl1c, not 0'u32, 0x200'u32)
  updateReg32(addr rf.rccalTone48, 0xFFFF8CFF'u32, 0x3137'u32)
  updateReg32(addr rf.roscalCtrl7c, 0x7FFFFFFF'u32, 0'u32)
  publishBl808RoscalCode(true, searchBl808RoscalCode(true))
  publishBl808RoscalCode(false, searchBl808RoscalCode(false))
  restoreBl808CalibrationState(saved)
  updateReg32(addr rf.calMode14, not 0'u32, RfRoscalDoneMode)
