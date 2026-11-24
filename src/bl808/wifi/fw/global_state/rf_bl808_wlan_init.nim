proc stopBl808CalibrationDfe() {.inline.} =
  let rf = rfRegs()
  updateReg32(addr rf.rxMode220, 0xFFFFE67D'u32, 0'u32)
  updateReg32(addr rf.rxMode220, 0xFFFFFF9E'u32, 0'u32)

proc runBl808WlanFullCal() =
  ## BL808 demo rf_pri_full_cal+0x0..0xac. No BZ TXCAL or RXCAL records.
  stopBl808CalibrationDfe()
  runRfPriLoFcal()
  rfPriSnapshotStage(0xF310'u32)
  runRfPriLoAcal()
  rfPriSnapshotStage(0xF311'u32)
  runBl808Roscal()
  rfPriSnapshotStage(0xF312'u32)
  runBl808Rccal()
  rfPriSnapshotStage(0xF313'u32)
  runBl808Txcal()
  stopBl808CalibrationDfe()
  rfPriSnapshotStage(0xF300'u32)

proc finishBl808WlanRfInit() =
  ## BL808 demo rf_pri_init+0x2de..0x3be. The mirror gain defaults must
  ## preserve the low bits written by the eight TXCAL correction records.
  programBl808TxGainTable()
  let rf = rfRegs()
  updateReg32(addr rf.rfGainTable760, 0xFF000000'u32, 0x00003189'u32)
  updateReg32(addr rf.rfGainTable75c, 0xFF000000'u32, 0x0030F495'u32)
  updateReg32(addr rf.rfGainTable79c, 0xC00007FF'u32, 0xD037D000'u32)
  updateReg32(addr rf.rfGainTable794, 0xC00007FF'u32, 0xD06FF000'u32)
  updateReg32(addr rf.rfGainTable78c, 0xC00007FF'u32, 0xD077E000'u32)
  updateReg32(addr rf.rfGainOrBzTempComp784, 0xC00007FF'u32, 0x10940000'u32)
  updateReg32(addr rf.rfGainTable77c, 0xC00007FF'u32, 0x109C0000'u32)
  updateReg32(addr rf.rfGainTable774, 0xC00007FF'u32, 0x11180000'u32)
  updateReg32(addr rf.rfGainTable76c, 0xC00007FF'u32, 0x115C0000'u32)
  updateReg32(addr rf.rfGainTable764, 0xC00007FF'u32, 0x11FC0000'u32)
  updateReg32(addr rf.synthCtrl2c, not 0'u32, 0x6'u32)
  updateReg32(addr rf.synthCtrl2c, not 0'u32, 0x4001'u32)
  updateReg32(addr rf.synthDfePathControl63c, not 0'u32, 0x8080'u32)

proc initializeBl808WlanRf() =
  beginManagedRfCalibration(rfCalBl808Wlan)
  bl808WlanCalibrationInProgress = true
  defer: bl808WlanCalibrationInProgress = false
  rfPriSnapshotStage(0xF400'u32)
  rf_pri_xtalfreq()
  prepareBl808RfColdRegisters()
  rfPriSnapshotStage(0xF403'u32)
  runBl808WlanFullCal()
  rfPriSnapshotStage(0xF404'u32)
  finishBl808WlanRfInit()
  managedRfCalibration = rfCalBl808Wlan
  rfPriSnapshotStage(0xF40B'u32)
  rfPhyTraceCheckpoint(0x22'u32)

proc programBl808ChannelNotch() =
  # BL808 demo rfc_config_channel+0xfc..0x1a2: the notch provider
  # returns disabled with a zero frequency, but these stores still run.
  let notch = addr rfRegs().notchCtrl680
  updateReg32(notch, 0x87FFFFFF'u32, 0x08000000'u32)
  updateReg32(notch, 0xF800FFFF'u32, 0'u32)
  updateReg32(notch, 0x7FFFFFFF'u32, 0'u32)
