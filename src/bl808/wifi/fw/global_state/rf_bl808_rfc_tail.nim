proc programBl808RfcModemLateInit() =
  ## BL808 demo rfc.o:.text.rfc_init, immediately after the last VCO store.
  let rf = rfRegs()
  # This word is outside the RF and PHY register blocks.
  let ctrl41c = cast[ptr uint32](0x4000E41C'u)

  # +0x74e..+0x7f4: separate RMWs, including successive writes to RF[0x63c].
  updateReg32(addr rf.baseCtrl1, not 0x800'u32, 0'u32)
  updateReg32(addr rf.channelTuneCtrl26c, not 0x8'u32, 0'u32)
  updateReg32(addr rf.channelTuneStrobe268, 0xFFFF0000'u32, 0x1040'u32)
  updateReg32(addr rf.baseCtrl1, not 0'u32, 0x2'u32)
  updateReg32(addr rf.synthCtrl2c, not 0'u32, 0x4'u32)
  updateReg32(addr rf.synthDfePathControl63c, not 0'u32, 0x80'u32)
  updateReg32(addr rf.synthDfePathControl63c, not 0x8000'u32, 0x8000'u32)
  updateReg32(addr rf.synthDfePathControl63c, not 0x7F'u32, 0'u32)
  updateReg32(addr rf.synthDfePathControl63c, not 0x7F00'u32, 0'u32)
  updateReg32(addr rf.synthCtrl2c, not 0'u32, 0x2'u32)
  updateReg32(addr rf.synthCtrl2c, not 0x4000'u32, 0x4000'u32)
  updateReg32(addr rf.synthCtrl2c, not 0'u32, 0x20'u32)

  # +0x7f6..+0x884: change RF[0x04][3:2] while bit 6 of 0x4000e41c is low.
  updateReg32(addr rf.rxMode220, not 0x08000000'u32, 0'u32)
  updateReg32(addr rf.baseCtrl1, not 0xC'u32, 0'u32)
  updateReg32(ctrl41c, not 0x40'u32, 0'u32)
  waitBl808RfcUs(1)
  updateReg32(addr rf.baseCtrl1, not 0xC'u32, 0x4'u32)
  waitBl808RfcUs(1)
  updateReg32(ctrl41c, not 0'u32, 0x40'u32)
  updateReg32(addr rf.rxMode220, not 0x10'u32, 0'u32)
  updateReg32(addr rf.synthCtrl2c, not 0'u32, 0x4'u32)
  updateReg32(addr rf.synthDfePathControl63c, not 0'u32, 0x80'u32)
  updateReg32(addr rf.synthDfePathControl63c, not 0x8000'u32, 0x8000'u32)
  updateReg32(addr rf.synthCtrl2c, not 0x4000'u32, 0x4000'u32)
  updateReg32(addr rf.synthCtrl2c, not 0x20'u32, 0'u32)

  # +0x886/+0x894/+0x8aa: printf arguments (bits 14, 2, 1), not a poll.
  discard volatileLoad(addr rf.synthCtrl2c)
  discard volatileLoad(addr rf.synthCtrl2c)
  discard volatileLoad(addr rf.synthCtrl2c)

  # +0x8c0..+0x928: keep the two RF[0x220] edges on each side of release.
  updateReg32(addr rf.measureCtrl618, 0x3FFFFFFF'u32, 0x80000000'u32)
  rfc_rc_fsm_force(7)
  updateReg32(addr rf.rxMode220, not 0'u32, 0x2'u32)
  updateReg32(addr rf.rxMode220, not 0'u32, 0x1'u32)
  waitBl808RfcUs(1)
  rfc_rc_fsm_force(15)
  updateReg32(addr rf.rxMode220, not 0x2'u32, 0'u32)
  updateReg32(addr rf.rxMode220, not 0x1'u32, 0'u32)
  volatileStore(addr phyRegs().rfcSettlingTimerA8, 200'u32)
