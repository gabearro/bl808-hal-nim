const Bl808RfCalMixerWordIndex = 3

proc writeBl808TxcalAmplitude(amplitude: uint32) =
  # rf_pri_singen_pwrmx_dc+0x46..0xa8. Restart DFE after the generator edge.
  let rf = rfRegs()
  updateReg32(addr rf.calSingenAmpLo214, 0xFFFFF800'u32, amplitude)
  updateReg32(addr rf.calSingenAmpHi218, 0xFFFFF800'u32, amplitude)
  updateReg32(addr rf.calSingenCtrl20c, not 0x80000000'u32, 0'u32)
  updateReg32(addr rf.calSingenCtrl20c, not 0'u32, 0x80000000'u32)
  startRfPriTxDfeForCal()

proc tuneBl808TxcalAmplitude(initialAmp: uint32; adcMeanMax, adcMeanMin: int32) =
  var amplitude = initialAmp
  var step = initialAmp shr 1
  while true:
    writeBl808TxcalAmplitude(amplitude)
    waitBl808RfCalUs(10'u32)
    let mean = sampleRfTxcalAdcMean().value
    if (mean >= adcMeanMin and mean <= adcMeanMax) or step == 0:
      return
    if mean < adcMeanMin:
      amplitude += step
    else:
      amplitude -= step
    step = step shr 1

proc calibrateBl808TxcalMixer() =
  # rf_pri_txcal+0x2da..0x3be. RF6C is a result, not a temporary register.
  let mixer = addr rfRegs().txcalDc6c
  var winner = 5'u32
  var best = -2048'i32
  for candidate in 0'u32 ..< 8'u32:
    updateReg32(mixer, not 7'u32, candidate)
    let sample = sampleRfTxcalAverage().value
    if sample > best:
      best = sample
      winner = candidate
  if rfCalibDataGlobal != nil:
    let prior = rfCalibWord(Bl808RfCalMixerWordIndex)
    rfCalibSetWord(Bl808RfCalMixerWordIndex, (prior and 0xF8FFFFFF'u32) or (winner shl 24))
  updateReg32(mixer, not 7'u32, winner)

proc beginBl808Txcal(): Bl808RfCalibrationSnapshot =
  # rf_pri_txcal+0x20..0x3be, through channel 9 and mixer calibration.
  let rf = rfRegs()
  updateReg32(addr rf.calMode14, not RfTxcalModeMask, RfTxcalStartMode)
  result = saveBl808CalibrationState()
  programRfPriModeRegisters(0xCEFFF8FF'u32, 0xCEFF7800'u32)
  waitBl808RfCalUs(0'u32)
  startRfPriTxDfeForCal()
  updateReg32(addr rf.rxMode220, not 0x60'u32, 0'u32)
  updateReg32(addr rf.rxMode220, not 0'u32, 0x21'u32)
  updateReg32(addr rf.rxMode220, not 0'u32, 0x40'u32)
  rfPriConfigChannelForCal(9)
  updateReg32(addr rf.calCtrl1c, not 0'u32, 0x00003000'u32)
  updateReg32(addr rf.rccalReplay84, not 0'u32, 0x80000000'u32)
  updateReg32(addr rf.txcalGain64, not 0'u32, 0x00400000'u32)
  updateReg32(addr rf.txcalDc6c, not 7'u32, 4'u32)
  updateReg32(addr rf.calSingenCtrl20c, 0xFC00FFFF'u32, 0x000B0000'u32)
  updateReg32(addr rf.calSingenAmpLo214, 0x003FFFFF'u32, 0'u32)
  updateReg32(addr rf.calSingenAmpHi218, 0x003FFFFF'u32, 0xC0000000'u32)
  updateReg32(addr rf.txcalGain64, 0x0FC3FFFF'u32, 0x50000000'u32)
  updateReg32(addr rf.txcalBias58, 0xFFF8FFFF'u32, 0x00040000'u32)
  updateReg32(addr rf.rccalTone48, 0xCE08FFFF'u32, 0x00870000'u32)
  tuneBl808TxcalAmplitude(128'u32, 128'i32, 64'i32)
  calibrateBl808TxcalMixer()

type Bl808TxcalParam = enum
  bl808TxcalIqI, bl808TxcalIqQ, bl808TxcalOffsetI, bl808TxcalOffsetQ

proc writeBl808TxcalParam(param: Bl808TxcalParam; value: int32) =
  case param
  of bl808TxcalIqI, bl808TxcalIqQ:
    let shift = if param == bl808TxcalIqI: 24 else: 16
    let mask = 0x3F'u32 shl shift
    updateReg32(addr rfRegs().txcalParam70, not mask,
                (cast[uint32](value) shl shift) and mask)
  of bl808TxcalOffsetI, bl808TxcalOffsetQ:
    writeRfTxcalParam(ord(param).uint32, value)

proc measureBl808TxcalCandidate(param: Bl808TxcalParam; value: int32;
                                first = false): uint32 =
  writeBl808TxcalParam(param, value)
  waitBl808RfCalUs(10'u32)
  if first:
    # Demo rf_pri_txcal_search_core+0x56..0x66 and the caller's a3 values.
    let frequency = if param <= bl808TxcalIqQ: 0x3D'u32 else: 0x7A'u32
    updateReg32(addr rfRegs().measureCtrl618, 0xFFF00000'u32, frequency shl 10)
  sampleRfTxcalPower(0'u32).power

proc searchBl808TxcalParam(param: Bl808TxcalParam; center, delta: int32): int32 =
  ## The row coordinator writes the returned winner; the last sample may differ.
  let (minimum, maximum) = case param
    of bl808TxcalIqI, bl808TxcalIqQ: (0'i32, 63'i32)
    of bl808TxcalOffsetI: (0'i32, 2047'i32)
    of bl808TxcalOffsetQ: (-512'i32, 511'i32)
  result = center
  var bestPower = measureBl808TxcalCandidate(param, center, true)
  var step = delta
  while true:
    let left = max(minimum, result - step)
    let right = min(maximum, result + step)
    step = ashr(step, 1)
    let leftPower = measureBl808TxcalCandidate(param, left)
    if leftPower < bestPower:
      result = left
      bestPower = leftPower
    else:
      let rightPower = measureBl808TxcalCandidate(param, right)
      if rightPower < bestPower:
        result = right
        bestPower = rightPower
    if step == 0:
      return

const Bl808TxcalRecordCount = 8

type
  Bl808TxcalSlot = range[0 .. Bl808TxcalRecordCount - 1]
  Bl808TxcalResult = array[Bl808TxcalParam, int32]

proc prepareBl808TxcalRows() =
  # rf_pri_txcal+0x3c2..0x44e switches from mixer averaging to the I/Q tone.
  let rf = rfRegs()
  updateReg32(addr rf.calSingenCtrl20c, 0xFC00FFFF'u32, 0x003D0000'u32)
  updateReg32(addr rf.calSingenAmpLo214, 0x003FFFFF'u32, 0'u32)
  updateReg32(addr rf.calSingenAmpHi218, 0x003FFFFF'u32, 0xC0000000'u32)
  updateReg32(addr rf.txcalGain64, 0x0FC3FFFF'u32, 0x90300000'u32)
  updateReg32(addr rf.txcalBias58, 0xFFF8FFFF'u32, 0x00040000'u32)
  updateReg32(addr rf.rccalTone48, 0xCE0FFFFF'u32, 0x00770000'u32)
  updateReg32(addr rf.calPathConfig8c, 0xFFFFFFCF'u32, 0x00000010'u32)

proc prepareBl808TxcalRow(slot: Bl808TxcalSlot; mixerGain, toneGain: int16) =
  # rf_pri_txcal+0x486..0x50c. Only the tone route (txcal_para[][4])
  # varies across the eight rows; the two gains come from the selected row.
  let rf = rfRegs()
  updateReg32(addr rf.txcalGain64, 0x0FC3FFFF'u32, 0x60100000'u32)
  updateReg32(addr rf.txcalBias58, 0xFFF8FFFF'u32, 0x00040000'u32)
  let toneRoute = if slot < 2: 0x00030000'u32 else: 0x00070000'u32
  updateReg32(addr rf.rccalTone48, 0xCE08FFFF'u32,
              (cast[uint32](mixerGain.int32) shl 28) or
              (cast[uint32](toneGain.int32) shl 20) or toneRoute)
  waitBl808RfCalUs(10'u32)
  tuneBl808TxcalAmplitude(192'u32, 256'i32, 128'i32)

proc searchBl808TxcalRow(): Bl808TxcalResult =
  # rf_pri_txcal+0x514..0x700: prime, then program each winner before the
  # next search. The final sample from a search is not necessarily its winner.
  discard sampleRfTxcalAverage()
  template refine(param: Bl808TxcalParam; center, step: int32) =
    result[param] = searchBl808TxcalParam(param, center, step)
    writeBl808TxcalParam(param, result[param])
  refine(bl808TxcalIqI, 0x20, 0x10)
  refine(bl808TxcalIqQ, 0x20, 0x10)
  refine(bl808TxcalIqI, result[bl808TxcalIqI], 0x08)
  refine(bl808TxcalIqQ, result[bl808TxcalIqQ], 0x08)
  refine(bl808TxcalOffsetI, 0x400, 0x80)
  refine(bl808TxcalOffsetQ, 0, 0x40)
  refine(bl808TxcalOffsetI, result[bl808TxcalOffsetI], 0x40)
  refine(bl808TxcalOffsetQ, result[bl808TxcalOffsetQ], 0x20)

proc bl808TxcalRecord(slot: Bl808TxcalSlot): ptr UncheckedArray[uint32] {.inline.} =
  let words = cast[ptr UncheckedArray[uint32]](rfCalibDataGlobal)
  cast[ptr UncheckedArray[uint32]](addr words[RfCalibTxcalRecordBaseWord + 2 * slot.int])

proc storeBl808TxcalRecord(slot: Bl808TxcalSlot; measured: Bl808TxcalResult) =
  if rfCalibDataGlobal == nil:
    return
  # rf_pri_txcal+0x720/+0x738/+0x748/+0x756 writes four packed fields.
  let words = bl808TxcalRecord(slot)
  updateReg32(addr words[0], 0xFFFFFFC0'u32,
              cast[uint32](measured[bl808TxcalIqI]) and 0x3F'u32)
  updateReg32(addr words[0], 0xFFFFF03F'u32,
              (cast[uint32](measured[bl808TxcalIqQ]) and 0x3F'u32) shl 6)
  updateReg32(addr words[0], 0xFF800FFF'u32,
              (cast[uint32](measured[bl808TxcalOffsetI]) and 0x7FF'u32) shl 12)
  updateReg32(addr words[1], 0xFFFFFC00'u32,
              cast[uint32](measured[bl808TxcalOffsetQ]) and 0x3FF'u32)

proc replayBl808TxcalCorrections() =
  if rfCalibDataGlobal == nil:
    return
  # rf_pri_txcal+0x776..0xcd0 replays eight records in each bank.
  let table = rfTxPowerCompTableRegs()
  for bankStart in [(0x708 - 0x700) div 4, (0x764 - 0x700) div 4]:
    for slot in low(Bl808TxcalSlot) .. high(Bl808TxcalSlot):
      let words = bl808TxcalRecord(slot)
      let index = bankStart + 2 * slot.int
      let gain = addr table.txPowerCompWords700[index]
      let correction = addr table.txPowerCompWords700[index + 1]
      let oldGain = volatileLoad(gain)
      volatileStore(gain, (oldGain and 0xFFFFF800'u32) or
                    ((volatileLoad(addr words[0]) shr 12) and 0x7FF'u32))
      let oldCorrection = volatileLoad(correction)
      let phase = volatileLoad(addr words[1]) and 0x3FF'u32
      let iqI = volatileLoad(addr words[0]) and 0x3F'u32
      let iqQ = (volatileLoad(addr words[0]) shr 6) and 0x3F'u32
      volatileStore(correction, (oldCorrection and 0xFF000003'u32) or
                    (phase shl 14) or (iqI shl 8) or (iqQ shl 2))

proc publishBl808TxcalActiveRecord() =
  if rfCalibDataGlobal == nil:
    return
  # rf_pri_txcal+0xcfc..0xd5c uses record 3 after restoring the scratch state.
  let rf = rfRegs()
  let words = bl808TxcalRecord(3)
  let oldIq = volatileLoad(addr rf.txcalParam70)
  let iqI = volatileLoad(addr words[0]) and 0x3F'u32
  let iqQ = (volatileLoad(addr words[0]) shr 6) and 0x3F'u32
  volatileStore(addr rf.txcalParam70, (oldIq and 0xC0C0FFFF'u32) or
                (iqI shl 24) or (iqQ shl 16))
  let oldOffsets = volatileLoad(addr rf.txcalTosdac600)
  let gain = volatileLoad(addr words[0]) and 0x007FF000'u32
  let phase = volatileLoad(addr words[1]) and 0x3FF'u32
  volatileStore(addr rf.txcalTosdac600, (oldOffsets and 0xFF800C00'u32) or gain or phase)

proc finishBl808Txcal(saved: Bl808RfCalibrationSnapshot) =
  let rf = rfRegs()
  replayBl808TxcalCorrections()
  updateReg32(addr rf.calCtrl1c, not 0x00003000'u32, 0'u32)
  restoreBl808CalibrationState(saved)
  updateReg32(addr rf.calMode14, not 0'u32, RfTxcalDoneMode)
  publishBl808TxcalActiveRecord()

proc runBl808Txcal() =
  if rfCalibDataGlobal == nil:
    return
  inc nim_wifi_rf_pri_txcal_count
  let saved = beginBl808Txcal()
  prepareBl808TxcalRows()
  for slot in low(Bl808TxcalSlot) .. high(Bl808TxcalSlot):
    let gain = bl808TxGainRow(slot.int)
    prepareBl808TxcalRow(slot, gain[0], gain[3])
    storeBl808TxcalRecord(slot, searchBl808TxcalRow())
  finishBl808Txcal(saved)
