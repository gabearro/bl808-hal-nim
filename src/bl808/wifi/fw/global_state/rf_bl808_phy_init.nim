proc pulseBl808PhyReset() =
  let pulse = addr wifiModemRegs().phyChannelPulse888
  var ticks = 10'u8
  volatileStore(pulse, 0x1111'u32)
  while true:
    # The demo polls the old byte and decrements it even on the final pass.
    let old = volatileLoad(addr ticks)
    volatileStore(addr ticks, old - 1'u8)
    if old == 0: break
  volatileStore(pulse, 0'u32)

proc initializeBl808Phy(cfg: pointer) =
  ## BL808 demo phy.o:phy_init+0x10..0x294. Channel tuning belongs to MM_START.
  let mdm = wifiModemRegs()
  let bba = bbaAgcRegs()
  inc nimFwDbgPhyInitCount
  nimFwDbgPhyInitPhase = 2'u32
  volatileStore(addr mdm.versionFeatureCtrl800, 0'u32)
  pulseBl808PhyReset()
  volatileStore(addr mdm.bandwidth20MProfile820, 0x130D'u32)
  updateReg32(addr mdm.preAgcCtrl3024, 0xFFC0FFFF'u32, 0x002D0000'u32)
  volatileStore(addr mdm.channelMask89c, 0xFFFFFFFF'u32)
  volatileStore(addr mdm.channelTypeCtrl824, 0x10D'u32)
  updateReg32(addr mdm.bandwidth20MEnable834, not 0'u32, 1'u32)
  updateReg32(addr mdm.channelBias818, 0xFFFBFFFF'u32, 0'u32)
  updateReg32(addr mdm.bandwidth20MProfile830, 0xFFFF00FF'u32, 0x1B00'u32)
  updateReg32(addr mdm.bandwidth20MProfile830, 0xFFFFFF00'u32, 0x0F'u32)
  volatileStore(addr mdm.bandwidth20MSignal83c, 0x04920492'u32)
  updateReg32(addr mdm.bandwidth20MGate874, 0xF7FFFFFF'u32, 0x08000000'u32)
  updateReg32(addr bba.agcPath500, 0xFFFFCFFF'u32, 0x2000'u32)
  updateReg32(addr bba.agcCoreTableC80c, 0x00FFFFFF'u32, 0x97000000'u32)
  volatileStore(addr bba.agcCoreEnable004, 1'u32)
  updateReg32(addr bba.pdGain390, 0xFFFFFFFC'u32, 1'u32)
  volatileStore(addr bba.macActiveB3bc, 0x003D0900'u32)
  updateReg32(addr bba.agcCoreTimeout414, not 0'u32, 0x100'u32)
  programBl808PhyAgcRegisters()

  nimFwDbgPhyInitPhase = 3'u32
  programBl808PhyAgcTable()
  inc nimFwDbgPhyAgcCopyCount
  nimFwDbgPhyWifiLdpcAbsent = 0'u32
  volatileStore(addr mdm.channelTiming838, 0xB4'u32)
  volatileStore(addr mdm.channelFilter88c, 0x1C13'u32)
  volatileStore(addr mdm.channelTiming898, 0x02D00438'u32)
  updateReg32(addr mdm.channelFilterControl858, 0xFFFFFF00'u32, 0'u32)
  volatileStore(addr mdm.channelProfile81c, 0x0F0F'u32)
  updateReg32(addr mdm.bandwidth20MEnable834, 0x00FFFFFF'u32, 0x06000000'u32)
  volatileStore(addr mdm.channelBias818, 0x01880C06'u32)
  volatileStore(addr mdm.bandwidth20MFilter860, 0x7F03'u32)
  programBl808PhyLdpcTable()

  nimFwDbgPhyInitPhase = 4'u32
  updateReg32(addr rfRegs().channelTuneCtrl26c, 0xC00FFFFF'u32, 0x05000000'u32)
  updateReg32(addr mdm.rxGainTailCtrlC018, 0xFFFFFC00'u32, 0x50'u32)
  copyPhyInitCfg(cfg, native = true)
  trpc_init()
  nimFwDbgPhyInitPhase = 6'u32

proc setBl808PhyChannel(channel: ptr ChanCtxtDefView) =
  ## Translate the descriptor ABI to demo phy.o:phy_set_channel+0x1e..0xb0.
  if channel.band > 1 or
      (channel.band == 0 and channel.centerFreq1 notin 2412'u16 .. 2484'u16):
    return
  let env = phyEnvViewPtr()
  let bandType = channel.band.uint16 or (channel.chanType.uint16 shl 8)
  let sameTune = volatileLoad(addr env.channelBandType) == bandType and
    volatileLoad(addr env.primaryFreq) == channel.primFreq and
    volatileLoad(addr env.centerFreq1) == channel.centerFreq1
  if not sameTune:
    pulseBl808PhyReset()
    rfc_config_channel(channel.centerFreq1.uint32)
    rfPhyTraceCheckpoint(0x41'u32)
    volatileStore(addr env.centerFreq1, channel.centerFreq1)
    volatileStore(addr env.channelBandType, bandType)
    volatileStore(addr env.primaryFreq, channel.primFreq)
  # Keep HAL metadata current without treating it as part of the RF cache.
  volatileStore(addr env.centerFreq2, channel.centerFreq2)
  volatileStore(addr env.txPowerAndFlags,
                channel.txPower.uint16 or (channel.phyEnvFlags.uint16 shl 8))
  if not sameTune: rfPhyTraceCheckpoint(0x42'u32)
