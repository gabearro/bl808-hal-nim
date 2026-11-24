type Bl808RfCalibrationSnapshot = array[27, uint32]

template forEachBl808CalibrationRegister(visit: untyped) =
  # Demo rf_pri_save_state_before_cal / rf_pri_restore_state_after_cal.
  let rf = rfRegs()
  visit(addr rf.baseCtrl1)
  visit(addr rf.synthCtrl2c)
  visit(addr rf.calCtrl1c)
  visit(addr rf.priModeCtrl30)
  visit(addr rf.txcalCtrlB8)
  visit(addr rf.sdmCtrlC0)
  visit(addr rf.sdmDivC4)
  visit(addr rfDfeInitRegs().hbnCtrl30)
  visit(addr rf.rccalReplay84)
  visit(addr rf.calPathConfig8c)
  visit(addr rf.txcalTosdac600)
  visit(addr rf.calMeasurePrep60c)
  visit(addr rf.measureCtrl618)
  visit(addr rf.measureMode61c)
  visit(addr rf.rccalTone48)
  visit(addr rf.calSingenCtrl20c)
  visit(addr rf.calSingenAmpLo214)
  visit(addr rf.calSingenAmpHi218)
  visit(addr rf.calDfeGate23c)
  visit(addr rf.calDfeState240)
  visit(addr rf.calDfeState244)
  visit(addr rf.calMixerStateF0)
  visit(addr rf.txcalGain64)
  visit(addr rf.txcalBias58)
  visit(addr rf.rxMode220)
  visit(addr rf.txcalParam70)
  visit(addr rf.acalCtrlA4)

proc saveBl808CalibrationState(): Bl808RfCalibrationSnapshot =
  var index = 0
  template save(reg: ptr uint32) =
    result[index] = volatileLoad(reg)
    inc index
  forEachBl808CalibrationRegister(save)

proc restoreBl808CalibrationState(state: Bl808RfCalibrationSnapshot) =
  var index = 0
  template restore(reg: ptr uint32) =
    volatileStore(reg, state[index])
    inc index
  forEachBl808CalibrationRegister(restore)
