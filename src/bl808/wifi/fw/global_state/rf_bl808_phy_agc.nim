type Bl808AgcRc2Tail {.packed.} = object
  fromC80c: array[8, uint32]
  inbandPowerValidCountC82c: uint32
  toLna: array[8, uint32]
  lnaIndexGainC850: uint32
  toMaxGain: array[2, uint32]
  maxGainC85c: uint32

static:
  const origin = offsetof(BbaAgcBlock, agcCoreTableC80c)
  doAssert origin + offsetof(Bl808AgcRc2Tail, inbandPowerValidCountC82c) == 0x182C
  doAssert origin + offsetof(Bl808AgcRc2Tail, lnaIndexGainC850) == 0x1850
  doAssert origin + offsetof(Bl808AgcRc2Tail, maxGainC85c) == 0x185C

var bl808PhyRxGainOffset = -128'i8

proc configureBl808PhyRxGain(offset: int32) =
  # phy_config_rxgain+0x08..0x14 compares before narrowing. The first gain
  # uses the argument; each later byte reloads the cached signed offset.
  if volatileLoad(addr bl808PhyRxGainOffset).int32 == offset:
    return
  let narrowed = cast[int8](offset)
  volatileStore(addr bl808PhyRxGainOffset, narrowed)
  let mdm = wifiModemRegs()
  for i, base in [8'i32, 15, 22, 29, 35, 42, 48, 54, 60]:
    let delta = if i == 0: narrowed else: volatileLoad(addr bl808PhyRxGainOffset)
    let gain = cast[uint32](base + delta.int32) and 0xFF'u32
    let reg = if i < 4: addr mdm.rxGainTable0C080
              elif i < 8: addr mdm.rxGainTable1C084
              else: addr mdm.rxGainTable2C088
    let shift = (i mod 4) * 8
    updateReg32(reg, not (0xFF'u32 shl shift), gain shl shift)

proc programBl808PhyAgcRegisters() =
  # Pinned BL808 phy.o:agc_config; phy_init owns the surrounding RAM copies.
  let bba = bbaAgcRegs()
  let mdm = wifiModemRegs()
  let rc2 = cast[ptr Bl808AgcRc2Tail](addr bba.agcCoreTableC80c)
  updateReg32(addr bba.pdGain390, 0xFFFEFFFF'u32, 0'u32)
  updateReg32(addr bba.pdGain390, 0xFFFFFBFF'u32, 0'u32)
  updateReg32(addr bba.agcCoreWindow3a4, 0xFFFFFF00'u32, 0'u32)
  updateReg32(addr bba.agcCoreWindow3a4, 0xFFFF00FF'u32, 0'u32)
  updateReg32(addr bba.agcCoreDetect394, 0xFF00FFFF'u32, 0x00F80000'u32)
  updateReg32(addr bba.agcCoreDetect398, 0xFFFF00FF'u32, 0x00009E00'u32)
  updateReg32(addr bba.macActiveB3c4, 0xFFFFFF00'u32, 0xCE'u32)
  updateReg32(addr bba.agcCoreProfile364, 0xE0FFFFFF'u32, 0x08000000'u32)
  updateReg32(addr bba.agcCoreProfile364, 0xFFC0FFFF'u32, 0x003C0000'u32)
  updateReg32(addr bba.agcCoreProfile364, 0xFFFFC0FF'u32, 0x00003800'u32)
  updateReg32(addr bba.agcCoreProfile364, 0xFFFFFFC0'u32, 0x39'u32)
  updateReg32(addr bba.macActiveB368, 0xFFC00FFF'u32, 0x00070000'u32)
  updateReg32(addr bba.macActiveB368, 0xFFFFFC00'u32, 0x70'u32)
  updateReg32(addr bba.pdComp36c, 0xFFFFFF00'u32, 0x10'u32)
  updateReg32(addr bba.pdComp36c, 0xFFFFF8FF'u32, 0x00000500'u32)
  updateReg32(addr bba.pdComp36c, 0xFF00FFFF'u32, 0x00280000'u32)
  updateReg32(addr bba.pdComp36c, 0xF8FFFFFF'u32, 0x07000000'u32)
  updateReg32(addr bba.agcCoreProfile370, 0xFF80FFFF'u32, 0x00580000'u32)
  updateReg32(addr bba.pdSlope3c0, 0x00FFFFFF'u32, 0x18000000'u32)

  updateReg32(addr bba.agcCoreStage0B380, 0xFFF03FFF'u32, 0x000F8000'u32)
  updateReg32(addr bba.agcCoreStage0B380, 0xFC0FFFFF'u32, 0x03700000'u32)
  updateReg32(addr bba.agcCoreStage0B380, 0x03FFFFFF'u32, 0x04000000'u32)
  updateReg32(addr bba.agcCoreStage0B380, 0xFFFFDFFF'u32, 0'u32)
  updateReg32(addr bba.agcCoreStage0B380, 0xFFFFE3FF'u32, 0x00000400'u32)
  updateReg32(addr bba.macActiveB384, 0x03FFFFFF'u32, 0xE4000000'u32)
  updateReg32(addr bba.macActiveB384, 0xFC0FFFFF'u32, 0x03700000'u32)
  updateReg32(addr bba.macActiveB384, 0xFFF03FFF'u32, 0x00050000'u32)
  updateReg32(addr bba.macActiveB384, 0xFFFFDFFF'u32, 0'u32)
  updateReg32(addr bba.macActiveB384, 0xFFFFE3FF'u32, 0x00000800'u32)
  updateReg32(addr bba.agcCoreStage2B388, 0x03FFFFFF'u32, 0x3C000000'u32)
  updateReg32(addr bba.agcCoreStage2B388, 0xFC0FFFFF'u32, 0x01700000'u32)
  updateReg32(addr bba.agcCoreStage2B388, 0xFFF03FFF'u32, 0x000A8000'u32)
  updateReg32(addr bba.agcCoreStage2B388, 0xFFFFDFFF'u32, 0'u32)
  updateReg32(addr bba.agcCoreStage2B388, 0xFFFFE3FF'u32, 0x00001400'u32)
  updateReg32(addr bba.macActiveB38c, 0x03FFFFFF'u32, 0x64000000'u32)
  updateReg32(addr bba.macActiveB38c, 0xFC0FFFFF'u32, 0'u32)
  updateReg32(addr bba.macActiveB38c, 0xFFF03FFF'u32, 0x00038000'u32)
  updateReg32(addr bba.macActiveB38c, 0xFFFFE3FF'u32, 0x00000800'u32)
  updateReg32(addr bba.pdCompC830, 0x03FFFFFF'u32, 0xFC000000'u32)
  updateReg32(addr bba.pdCompC830, 0xFC0FFFFF'u32, 0x00100000'u32)
  updateReg32(addr bba.pdCompC830, 0xFFF03FFF'u32, 0x000D8000'u32)
  updateReg32(addr bba.pdCompC830, 0xFFFFE3FF'u32, 0x00001400'u32)

  updateReg32(addr mdm.lowPowerRxPathCtrlC814, 0xFFFFFFFC'u32, 0'u32)
  # +0x34a and +0x35a are two separate RMWs of the same field.
  updateReg32(addr mdm.lowPowerRxPathCtrlC814, 0xFFFFFFC3'u32, 0x08'u32)
  updateReg32(addr mdm.lowPowerRxPathCtrlC814, 0xFFFFFFC3'u32, 0x08'u32)
  updateReg32(addr mdm.rxGainInitC040, 0xFE0FFFFF'u32, 0x00C00000'u32)
  updateReg32(addr mdm.rxGainInitC040, 0xFFF07FFF'u32, 0x00018000'u32)
  updateReg32(addr mdm.rxGainTimingC044, 0xFFFF00FF'u32, 0x00000800'u32)
  updateReg32(addr mdm.rxGainTimingC044, 0xFFFFFF00'u32, 0'u32)
  configureBl808PhyRxGain(0'i32)

  updateReg32(addr bba.macActiveB3a0, 0xFFFFFF00'u32, 0x9E'u32)
  updateReg32(addr bba.pdSlope3c0, 0xFFFFFF00'u32, 0xB0'u32)
  updateReg32(addr bba.pdSlope3c0, 0xFFFF00FF'u32, 0x0000A300'u32)
  updateReg32(addr bba.pdCompRampC838, 0x7FFFFFFF'u32, 0x80000000'u32)
  updateReg32(addr bba.pdCompRampC838, 0xFFF80000'u32, 0x40'u32)
  updateReg32(addr bba.pdCompRampC83c, 0x7FFFFFFF'u32, 0x80000000'u32)
  updateReg32(addr bba.pdCompRampC83c, 0xFFF00000'u32, 0x40'u32)
  updateReg32(addr bba.pdCompRampC840, 0x7FFFFFFF'u32, 0x80000000'u32)
  updateReg32(addr bba.pdCompRampC840, 0xFFC00000'u32, 0x40'u32)
  updateReg32(addr rc2.inbandPowerValidCountC82c, 0xFF007FFF'u32, 0x00200000'u32)
  updateReg32(addr rc2.lnaIndexGainC850, 0x00FFFFFF'u32, 0x08000000'u32)
  updateReg32(addr rc2.lnaIndexGainC850, 0xFF00FFFF'u32, 0x003C0000'u32)
  updateReg32(addr bba.agcCoreLowPowerThreshold304, 0xFFFF80FF'u32, 0x4200'u32)
  updateReg32(addr rc2.maxGainC85c, 0xFF00FFFF'u32, 0x00300000'u32)
