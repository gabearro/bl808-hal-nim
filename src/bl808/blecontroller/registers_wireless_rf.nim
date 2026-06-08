# ---------------------------------------------------------------------------
# BLE register offsets (from BLE_BASE)
# ---------------------------------------------------------------------------

const
  BLE_RWBLECNTL_OFFSET* = 0x00'u32
  BLE_VERSION_OFFSET* = 0x04'u32
  BLE_INTCNTL_OFFSET* = 0x0C'u32
  BLE_INTSTAT_OFFSET* = 0x10'u32
  BLE_INTRAWSTAT_OFFSET* = 0x14'u32
  BLE_INTACK_OFFSET* = 0x18'u32
  BLE_BASETIMECNT_OFFSET* = 0x1C'u32
  BLE_FINETIMECNT_OFFSET* = 0x20'u32
  BLE_BDADDR_OFFSET* = 0x24'u32
  BLE_DEEPSLCNTL_OFFSET* = 0x30'u32
  BLE_DEEPSLSTAT_OFFSET* = 0x34'u32
  BLE_ENBPRESET_OFFSET* = 0x38'u32
  BLE_FINECNTCORR_OFFSET* = 0x3C'u32
  BLE_SLOTCLK_OFFSET* = 0x1C'u32
  BLE_FINETIMTGT_OFFSET* = 0x24'u32

  GlbBase = 0x20000000'u32
  AonBase = 0x2000F000'u32
  HbnBase = 0x2000F000'u32
  MmGlbBase = 0x30007000'u32

  BTBLE_INTMASK_OFFSET = 0x18'u32
  BTBLE_INTSTAT_OFFSET = 0x1C'u32
  BTBLE_INTACK_OFFSET = 0x20'u32
  BTBLE_INTDETAIL_OFFSET = 0x24'u32
  BtbleIntAesDone = 0x00000004'u32
  BtbleIntSw = 0x00000008'u32
  BtbleIntEventTarget = 0x00000020'u32
  BtbleEventTargetEnableBit = 0x00004000'u32
  BtbleIntLegacyScheduler = 0x0000800E'u32
  BtbleIntAdvertising = 0x00008026'u32
  BtbleIntConnection = 0x00008026'u32
  BleLegacyAdvDelayMaxHalfUs = 20_000'u32

  BtbleAdvSlotTail: array[10, uint32] = [
    0xBF3D0C00'u32, 0x5FF80C00'u32, 0x9FFD0C00'u32, 0xFF0D0C00'u32,
    0xBF280C00'u32, 0x7F530C00'u32, 0x7FA00C00'u32, 0xDF830C00'u32,
    0x9F710C00'u32, 0x1FC20C00'u32
  ]
  BtbleAdvDataOffset = 0x0A2C'u32
  BtbleScanRspDataOffset = 0x0A4C'u32
  BtbleLegacyAdvEventHeaderBase = 0x0020'u16
  BtbleLegacyAdvEventWord124 = 0xE3F5'u16
  BtbleLegacyAdvWord138 = 0xF102'u16
  BtbleLegacyAdvWord13C = 0xBD86'u16
  BtbleLegacyAdvControl = 0x11842182'u32
  BtbleLegacyAdvTimingHigh = 0x1338'u16
  BtbleLegacyAdvTimingLow = 0x3FD1'u16
  BtbleLegacyAdvTail = 0xE745'u16
  BtbleLegacyAdvTxDescFlags = 0xF84F'u16
  BtbleLegacyAdvTxTailLow = 0x4592'u16
  BtbleLegacyAdvTxTailHigh = 0x7B9F'u16
  BtbleLegacyAdvRxTailLow = 0x8EEC'u16
  BtbleLegacyAdvRxTailHigh = 0x51FB'u16
  BtbleLegacyScanRspEmptyPtr = 0x0000'u16
  BtbleLegacyScanRspEmptyTail = 0x2601'u16
  BtbleLegacyScanRspDataTail = 0x2601'u16

proc btbleAdvSlotTail(slot: uint32): uint32 {.inline.} =
  BtbleAdvSlotTail[int(slot mod uint32(BtbleAdvSlotTail.len))]

proc regOr(regAddr: uint32, mask: uint32) {.inline.} =
  regWrite(regAddr.uint, regRead(regAddr.uint) or mask)

proc regClear32(regAddr: uint32, mask: uint32) {.inline.} =
  regWrite(regAddr.uint, regRead(regAddr.uint) and not mask)

proc regUpdate(regAddr: uint32, mask: uint32, value: uint32) {.inline.} =
  let current = regRead(regAddr.uint)
  regWrite(regAddr.uint, (current and not mask) or (value and mask))

type
  BlePhyMemoryRegs {.packed.} = object
    reserved000*: array[0x824, uint8]
    memMode*: uint32
    reserved828*: array[0x0C, uint8]
    ldpcMode*: uint32
    reserved838*: array[0x3C, uint8]
    agcMemGate*: uint32
    reserved878*: array[0xAAC8, uint8]
    ldpcLoadAddress*: uint32
    ldpcLoadLength*: uint32
    ldpcLoadControl*: uint32
    reservedB34c*: array[0x44, uint8]
    agcLoad*: uint32

static:
  doAssert offsetof(BlePhyMemoryRegs, memMode) == 0x824
  doAssert offsetof(BlePhyMemoryRegs, ldpcMode) == 0x834
  doAssert offsetof(BlePhyMemoryRegs, agcMemGate) == 0x874
  doAssert offsetof(BlePhyMemoryRegs, ldpcLoadAddress) == 0xB340
  doAssert offsetof(BlePhyMemoryRegs, ldpcLoadLength) == 0xB344
  doAssert offsetof(BlePhyMemoryRegs, ldpcLoadControl) == 0xB348
  doAssert offsetof(BlePhyMemoryRegs, agcLoad) == 0xB390

template blePhyMemoryRegs(): ptr BlePhyMemoryRegs =
  cast[ptr BlePhyMemoryRegs](0x24C00000'u)

proc bleRegLoadPtr(reg: ptr uint32): uint32 {.inline.} =
  regRead(cast[uint](reg))

proc bleRegStorePtr(reg: ptr uint32, value: uint32) {.inline.} =
  regWrite(cast[uint](reg), value)

proc bleRegOrPtr(reg: ptr uint32, mask: uint32) {.inline.} =
  bleRegStorePtr(reg, bleRegLoadPtr(reg) or mask)

proc bleRegClearPtr(reg: ptr uint32, mask: uint32) {.inline.} =
  bleRegStorePtr(reg, bleRegLoadPtr(reg) and not mask)

proc bleRegUpdatePtr(reg: ptr uint32, mask: uint32, value: uint32) {.inline.} =
  let current = bleRegLoadPtr(reg)
  bleRegStorePtr(reg, (current and not mask) or (value and mask))

proc disableM0ClicDeliveryForPolledBle() {.inline.} =
  when defined(bl808m0) and not bl808BleNimRuntimeClicIrq:
    core.csrWriteMie(core.csrReadMie() and not (1'u shl 11))
    core.disableInterrupts()

proc quiesceM0PolledBleClicSources() {.inline.} =
  ## Polled BLE owns the BTBLE/RF work from foreground service calls.  Keep the
  ## GLB mux and CLIC delivery state quiet so stale RF_TOP/BTBLE latches cannot
  ## enter the trap path between HCI reset and the next controller command.
  when defined(bl808m0) and not bl808BleNimRuntimeClicIrq:
    disableM0ClicDeliveryForPolledBle()
    nimDisableM0RfClicIrq()
    nimDisableM0BleClicIrq()

proc btbleIrqSave(): uint {.inline.} =
  let saved = core.csrReadMstatus()
  core.disableInterrupts()
  saved

proc btbleIrqRestore(saved: uint) {.inline.} =
  when defined(bl808m0) and not bl808BleNimRuntimeClicIrq:
    disableM0ClicDeliveryForPolledBle()
  else:
    core.csrWriteMstatus(saved)

proc swResetCfg0(bit: uint32) =
  let resetReg = GlbBase + 0x540'u32
  let mask = 1'u32 shl bit
  regWrite(resetReg.uint, regRead(resetReg.uint) and not mask)
  discard regRead(resetReg.uint)
  regWrite(resetReg.uint, regRead(resetReg.uint) or mask)
  discard regRead(resetReg.uint)
  regWrite(resetReg.uint, regRead(resetReg.uint) and not mask)

proc enableWirelessClocks() =
  regOr(GlbBase + 0x580'u32, (1'u32 shl 5) or (1'u32 shl 6) or (1'u32 shl 7))
  regOr(GlbBase + 0x584'u32, 1'u32 shl 1)
  regOr(GlbBase + 0x588'u32, (1'u32 shl 4) or (1'u32 shl 8) or (1'u32 shl 10))
  regUpdate(GlbBase + 0x3B0'u32, 0x0F'u32, 1'u32)

proc configureBleEm() =
  ## Select 32 KiB BLE exchange memory, matching the SDK controller setup.
  regUpdate(GlbBase + 0x60C'u32, 0xFF'u32, 0x0F'u32)

proc configureDigClock() =
  let digReg = GlbBase + 0x250'u32
  var v = regRead(digReg.uint)
  let dig32En = v and (1'u32 shl 12)

  v = v and not ((1'u32 shl 24) or (1'u32 shl 12))
  regWrite(digReg.uint, v)

  v = regRead(digReg.uint)
  v = (v and not (3'u32 shl 28)) or (1'u32 shl 28)
  regWrite(digReg.uint, v)

  v = regRead(digReg.uint)
  v = v and not (0x7F'u32 shl 16)
  v = v or (0x4E'u32 shl 16) or (1'u32 shl 25) or (1'u32 shl 24) or dig32En
  regWrite(digReg.uint, v)

proc powerOnXtalWifiPll() =
  let hbnRsv3 = HbnBase + 0x10C'u32

  regOr(AonBase + 0x880'u32,
        (1'u32 shl 0) or (1'u32 shl 1) or (1'u32 shl 2) or
        (1'u32 shl 4) or (1'u32 shl 5))
  delayUs(120)

  regWrite(hbnRsv3.uint, (regRead(hbnRsv3.uint) and 0xFFFF0000'u32) or 0x5804'u32)

  if (regRead((GlbBase + 0x810'u32).uint) and (1'u32 shl 10)) != 0:
    regOr(GlbBase + 0x824'u32, 1'u32 shl 12)
    regOr(GlbBase + 0x830'u32,
          (1'u32 shl 31) or (1'u32 shl 1) or (1'u32 shl 2) or
          (1'u32 shl 3) or (1'u32 shl 4) or (1'u32 shl 5))
    regOr(GlbBase + 0x090'u32, 1'u32 shl 0)
    regOr(MmGlbBase + 0x000'u32, 1'u32 shl 0)
    return

  regUpdate(GlbBase + 0x810'u32, (1'u32 shl 10) or (1'u32 shl 9), 0)
  regUpdate(GlbBase + 0x814'u32, (0x0F'u32 shl 8) or (0x03'u32 shl 16),
            (2'u32 shl 8) or (1'u32 shl 16))
  regUpdate(GlbBase + 0x818'u32, (1'u32 shl 8) or (0x03'u32 shl 6) or (0x03'u32 shl 4),
            2'u32 shl 4)
  regUpdate(GlbBase + 0x81C'u32,
            (1'u32 shl 0) or (1'u32 shl 8) or (0x03'u32 shl 12) or
            (0x03'u32 shl 14) or (0x07'u32 shl 16),
            (1'u32 shl 8) or (2'u32 shl 12) or (1'u32 shl 14) or (3'u32 shl 16))
  regUpdate(GlbBase + 0x820'u32, 0x03'u32 shl 0, 1'u32 shl 0)
  regUpdate(GlbBase + 0x824'u32, 0x07'u32 shl 0, 5'u32 shl 0)
  regUpdate(GlbBase + 0x828'u32,
            (0x03FFFFFF'u32 shl 0) or (1'u32 shl 28) or (1'u32 shl 31),
            0x01800000'u32 or (1'u32 shl 28) or (1'u32 shl 31))

  regOr(GlbBase + 0x810'u32, 1'u32 shl 9)
  delayUs(3)
  regOr(GlbBase + 0x810'u32, 1'u32 shl 10)
  delayUs(3)

  regOr(GlbBase + 0x810'u32, 1'u32 shl 0)
  delayUs(2)
  regWrite((GlbBase + 0x810'u32).uint,
           regRead((GlbBase + 0x810'u32).uint) and not (1'u32 shl 0))
  delayUs(2)
  regOr(GlbBase + 0x810'u32, 1'u32 shl 0)

  regOr(GlbBase + 0x810'u32, 1'u32 shl 2)
  delayUs(2)
  regWrite((GlbBase + 0x810'u32).uint,
           regRead((GlbBase + 0x810'u32).uint) and not (1'u32 shl 2))
  delayUs(2)
  regOr(GlbBase + 0x810'u32, 1'u32 shl 2)

  regOr(GlbBase + 0x824'u32, 1'u32 shl 12)
  regOr(GlbBase + 0x830'u32,
        (1'u32 shl 31) or (1'u32 shl 1) or (1'u32 shl 2) or
    (1'u32 shl 3) or (1'u32 shl 4) or (1'u32 shl 5))
  delayUs(75)

  regOr(GlbBase + 0x090'u32, 1'u32 shl 0)
  regOr(MmGlbBase + 0x000'u32, 1'u32 shl 0)

var bleRf1MConfigured: bool

proc invalidateBleRf1MConfig() {.inline.} =
  ## Wireless-domain resets can invalidate the RF/PHY register plane even if
  ## the controller state still believes BLE 1M was configured.
  bleRf1MConfigured = false

proc wifiMacLooksActive(): bool {.inline.} =
  ## The BL808 WiFi MAC and BLE controller share the wireless reset/RF domain.
  ## Preserve it only when this firmware instance has explicitly enabled
  ## coexistence.  MACHW/PTA registers can remain set across JTAG-flashed test
  ## images; treating those stale bits as live WiFi leaves BLE on the wrong RF
  ## state in BLE-only firmware.
  when defined(bl808m0):
    if nim_ble_wlcoex_enabled == 0'u32:
      nim_ble_wireless_last_wifi_state = 0
      return false
    const
      MachwBcnStatus = 0x24B00400'u32
      MachwIntcUnmask = 0x24B08074'u32
      PtaCtrl = 0x24920004'u32
    let bcn = regRead(MachwBcnStatus.uint)
    let intc = regRead(MachwIntcUnmask.uint)
    let pta = regRead(PtaCtrl.uint)
    nim_ble_wireless_last_wifi_state =
      (bcn and 0xFF'u32) or ((intc shr 16) and 0xFF00'u32) or
      ((pta shl 16) and 0x00FF0000'u32)
    ((bcn and 0x1'u32) != 0'u32) or
      ((intc and 0x80000000'u32) != 0'u32) or
      ((pta and 0x1'u32) != 0'u32)
  else:
    false

proc prepareWirelessDomain() =
  inc nim_ble_wireless_prepare_count
  let preserveWifi = wifiMacLooksActive()
  configureBleEm()
  powerOnXtalWifiPll()
  configureDigClock()
  enableWirelessClocks()
  if preserveWifi:
    inc nim_ble_wireless_preserve_wifi_count
  else:
    swResetCfg0(4)
    swResetCfg0(8)
    swResetCfg0(10)
    configureDigClock()
    enableWirelessClocks()
    invalidateBleRf1MConfig()
    inc nim_ble_wireless_reset_count

proc configureBtPriorityPta() =
  ## Match the WiFi firmware's BT-priority PTA mode without linking WiFi FW.
  when defined(bl808m0):
    const
      PtaCtrl = 0x24920004'u
      PtaClear = 0x24920428'u

    template ptaReg(regAddr: uint): ptr uint32 =
      cast[ptr uint32](regAddr)

    proc updatePtaCtrl(keepMask, setMask: uint32) {.inline.} =
      let reg = (volatileLoad(ptaReg(PtaCtrl)) and keepMask) or setMask
      volatileStore(ptaReg(PtaCtrl), reg)

    volatileStore(ptaReg(PtaClear), 0'u32)
    updatePtaCtrl(not 1'u32, 0'u32)
    updatePtaCtrl(0xFFF7FFFF'u32, 0x00080000'u32)
    updatePtaCtrl(0xFFFBFFFF'u32, 0x00040000'u32)
    updatePtaCtrl(0xFFFDFFFF'u32, 0'u32)
    updatePtaCtrl(0xFFFEFFFF'u32, 0'u32)

type
  BleRegInit = object
    address: uint32
    value: uint32

  BleRegMaskInit = object
    address: uint32
    keepMask: uint32
    setMask: uint32

  BleRfRegBlock {.packed.} = object
    baseCtrl0: uint32
    baseCtrl1: uint32
    reserved008: array[5, uint32]
    calCtrl1c: uint32
    capability20: uint32
    reserved024: array[2, uint32]
    synthCtrl2c: uint32
    priModeCtrl30: uint32
    reserved034: array[5, uint32]
    rccalTone48: uint32
    reserved04c: array[3, uint32]
    txcalBias58: uint32
    reserved05c: array[2, uint32]
    txcalGain64: uint32
    txcalGain68: uint32
    txcalDc6c: uint32
    txcalParam70: uint32
    reserved074: array[3, uint32]
    rbbRccalCtrl80: uint32
    rccalReplay84: uint32
    txcalDfe88: uint32
    calPathConfig8c: uint32
    reserved090: array[4, uint32]
    fcalCtrlA0: uint32
    acalCtrlA4: uint32
    calResultA8: uint32
    fcalAc: uint32
    channelCalStrobeB0: uint32
    channelCalStatusB4: uint32
    txcalCtrlB8: uint32
    channelFcalConfigBc: uint32
    sdmCtrlC0: uint32
    sdmDivC4: uint32
    reserved0c8: uint32
    rfPriBiasTrimCc: uint32
    optimizeCtrlD0: uint32
    rfBiasTrimD4: uint32
    reserved0d8: array[6, uint32]
    calMixerStateF0: uint32
    reserved0f4: array[18, uint32]
    vcoPairTable13c: array[10, uint32]
    vcoPair2484Mhz164: uint32
    roscalCal0: uint32
    roscalCal1: uint32
    reserved170: array[39, uint32]
    calSingenCtrl20c: uint32
    reserved210: uint32
    calSingenAmpLo214: uint32
    calSingenAmpHi218: uint32
    reserved21c: uint32
    rxMode220: uint32
    reserved224: array[6, uint32]
    calDfeGate23c: uint32
    calDfeState240: uint32
    calDfeState244: uint32
    reserved248: array[238, uint32]
    txcalTosdac600: uint32
    reserved604: array[2, uint32]
    calMeasurePrep60c: uint32
    reserved610: array[2, uint32]
    measureCtrl618: uint32
    measureMode61c: uint32
    measureI620: uint32
    measureQ624: uint32

  BleRfDfeInitBlock {.packed.} = object
    reserved000: array[12, uint32]
    hbnCtrl30: uint32

const
  BleRfBase = 0x20001000'u
  BleRfDfeInitBase = 0x2000F000'u
  BleRfDefaultChannelMhz = 2402'u16
  BleRfCtrlReg = 0x20001004'u32
  BleRfSynthCtrlReg = 0x2000102C'u32
  BleRfChannelReg = 0x20001264'u32
  BleRfTuneReg = 0x20001268'u32
  BleRfModeReg = 0x2000126C'u32
  BleRfOptimizeReg = 0x200010D0'u32
  BleRfCalModeReg = 0x20001014'u32
  BleRfCalCtrlReg = 0x2000101C'u32
  BleRfCalResultReg = 0x200010A8'u32
  BleRfFcalCtrlReg = 0x200010A0'u32
  BleRfAcalCtrlReg = 0x200010A4'u32
  BleRfPriModeCtrlReg = 0x20001030'u32
  BleRfSdm1Reg = 0x200010C0'u32
  BleRfSdm2Reg = 0x200010C4'u32
  BleRfRxModeReg = 0x20001220'u32
  BleRfRetuneReg = 0x20001228'u32
  BleRfNotchReg = 0x20001680'u32
  BleRfFcalReg = 0x200010AC'u32
  BleRfTxPowerReg = 0x200010B4'u32
  BleRfTxcalCtrlReg = 0x200010B8'u32
  BleRfRoscalCtrlReg = 0x2000107C'u32
  BleRfRbbRccalReg = 0x20001080'u32
  BleRfRccalReplayReg = 0x20001084'u32
  BleRfRoscalReg0 = 0x20001168'u32
  BleRfRoscalReg1 = 0x2000116C'u32
  BleRfMeasureCtrlReg = 0x20001618'u32
  BleRfMeasureModeReg = 0x2000161C'u32
  BleRfMeasureIReg = 0x20001620'u32
  BleRfMeasureQReg = 0x20001624'u32
  BleRfTxcalParamReg = 0x20001070'u32
  BleRfTxcalTosdacReg = 0x20001600'u32
  BleRfPriRccalSingenReg0 = 0x2000120C'u32
  BleRfPriRccalSingenReg1 = 0x20001214'u32
  BleRfPriRccalSingenReg2 = 0x20001218'u32
  BleRfPriCalDfeGateReg = 0x2000123C'u32
  BleRfPriCalDfeState0Reg = 0x20001240'u32
  BleRfPriCalDfeState1Reg = 0x20001244'u32
  BleRfPriRccalMeasurePrepReg = 0x2000160C'u32
  BleRfPriRccalToneReg = 0x20001048'u32
  BleRfPllEnableReg = 0x20000830'u32
  BleRfDfeHbnCtrlReg = 0x2000F030'u32
  BleRfDfeStaticCtrlReg = 0x2000F820'u32
  BleRfDfeFixedDefault884Reg = 0x2000F884'u32
  BleRfTxcalBiasReg = 0x20001058'u32
  BleRfBiasTrimD4Reg = 0x200010D4'u32
  BleRfTxcalGain64Reg = 0x20001064'u32
  BleRfTxcalGain68Reg = 0x20001068'u32
  BleRfPriTxcalDfeReg = 0x20001088'u32
  BleRfCalPathConfigReg = 0x2000108C'u32
  BleRfPriTxcalDcReg = 0x2000106C'u32
  BleRfCalPathCtrlReg = 0x20001090'u32
  BleRfPriBiasTrimReg = 0x200010CC'u32
  BleRfPriCalMixerStateReg = 0x200010F0'u32
  BleRfTxcalDefaultProfile128Reg = 0x20001128'u32
  BleRfTxcalDefaultProfile12cReg = 0x2000112C'u32
  BleRfTxcalDefaultProfile130Reg = 0x20001130'u32
  BleRfCalModeDefaultReg = 0x20001138'u32
  BleRfAverageMeasureCtrlReg = 0x20001618'u32
  BleRfSynthDfePathControlReg = 0x2000163C'u32
  BleRfCtrlIdleEnableMask = 0x00000006'u32
  BleRfCtrlTuneEnableMask = 0x00000002'u32
  BleRfSynthIdleClearMask = 0x00000020'u32
  BleRfSynthChannelPrepareMask = 0x00000040'u32
  BleRfSynthChannelLatchMask = 0x00000200'u32
  BleRfSynthChannelRequestMask = 0x00000001'u32
  BleRfChannelMask = 0x00000FFF'u32
  BleRfTuneStrobeMask = 0x00020000'u32
  BleRfModeStateMask = 0x00000007'u32
  BleRfModeTuneStartState = 0x00000001'u32
  BleRfModeIdleState = 0x00000002'u32
  BleRfModeLowBitsMask = 0x0000000F'u32
  BleRfModeTuneBusyMask = 0x00000008'u32
  BleRfIdle1MMode = 0x00028002'u32
  BleRfRxModeIdleClearMask = 0x00000010'u32
  BleRfRetuneHoldMask = 0x00000008'u32
  BleRfOptimizeMidBandMask = 0x00000001'u32
  BleRfOptimizeMidBandFirstMhz = 2452'u16
  BleRfOptimizeMidBandLastMhz = 2472'u16
  BleRfPower4DbmTxCal = 0x0010C222'u32
  BleRfNotchDisabledWord = 0x08000000'u32
  BleRfFcalStartMask = 0x00000010'u32
  BleRfFcalReadyMask = 0x00100000'u32
  BleRfTxcalLatchMask = 0x01100000'u32
  BleRfFcalCodeMask = 0x000000FF'u32
  BleRfAcalCodeMask = 0x001F0000'u32
  BleRfAcalComparatorMask = 0x00001000'u32
  BleRfRoscalCapabilityMask = 0x00000100'u32
  BleRfRoscalModeMask = 0x0000C000'u32
  BleRfRoscalStartMode = 0x00004000'u32
  BleRfRoscalDoneMode = 0x0000C000'u32
  BleRfRoscalCodeMask = 0x0000003F'u32
  BleRfRoscalIRegMask = 0x00003F00'u32
  BleRfRoscalQRegMask = 0x0000003F'u32
  BleRfRoscalRegisterKeepMask = 0xC0C0C0C0'u32
  BleRfRccalCapabilityMask = 0x00000400'u32
  BleRfRccalModeMask = 0x000C0000'u32
  BleRfRccalStartMode = 0x00040000'u32
  BleRfRccalDoneMode = 0x000C0000'u32
  BleRfRccalFailMode = 0x00080000'u32
  BleRfRccalCodeMask = 0x0000003F'u32
  BleRfRccalRegisterKeepMask = 0xC0C0C0C0'u32
  BleRfRccalBaselineCode = 0x20'u32
  BleRfRccalTargetNumerator = 81'u64
  BleRfRccalTargetDenominator = 100'u64
  BleRfRccalFallbackTargetNumerator = 5'u64
  BleRfRccalFallbackTargetDenominator = 3'u64
  BleRfRccalMinReferencePower = 64'u32
  BleRfRccalReferenceMeasureCtrl = 0x00001000'u32
  BleRfRccalToneMeasureCtrl = 0x0002D400'u32
  BleRfMeasureRccalTriggerMask = 0x20100000'u32
  BleRfTxcalModeMask = 0x00F00000'u32
  BleRfTxcalStartMode = 0x00500000'u32
  BleRfTxcalDoneMode = 0x00F00000'u32
  BleRfTxcalParam0Mask = 0x3F000000'u32
  BleRfTxcalParam1Mask = 0x003F0000'u32
  BleRfTxcalParam2Mask = 0x007FF000'u32
  BleRfTxcalParam2EnableBit = 0x00800000'u32
  BleRfTxcalParam3Mask = 0x000003FF'u32
  BleRfTxcalParam3SignBit = 0x00000400'u32
  BleRfTxcalSingenAmplitudeMask = 0x000007FF'u32
  BleRfTxcalMixerCsMask = 0x00000007'u32
  BleRfTxcalAverageMeasureMode = 0x04000000'u32
  BleRfTxcalInitialAmp = 128'u32
  BleRfTxcalInitialAdcMax = 128'i32
  BleRfTxcalInitialAdcMin = 64'i32
  BleRfTxcalGainAmp = 192'u32
  BleRfTxcalGainAdcMax = 256'i32
  BleRfTxcalGainAdcMin = 128'i32
  BleRfTxcalSearchRecords = 8
  BleRfTxcalMixerCsCount = 8
  BleRfMeasureTriggerClearMask = 0x20100000'u32
  BleRfMeasureModeKeepMask = 0x0000FFFF'u32
  BleRfMeasureRoscalMode = 0x04000000'u32
  BleRfMeasureFrequencyShift = 10
  BleRfMeasureStartMask = 0x20000000'u32
  BleRfMeasureReadyMask = 0x10000000'u32
  BleRfLoChannelCount = 21
  BleRfFcalWaitLimit = 5000
  BleRfRoscalWaitLimit = 10000
  BleRfRccalWaitLimit = 10000
  BleRfTxcalWaitLimit = 10000
  BleRfLoFcalLowCount = 0xA6A0'u16
  BleRfLoFcalHighCount = 0xA6E0'u16
  BleRfLoFcalStopCount = 0xACE0'u16
  BleRfLoFcalDiv = 0x0855'u16
  BlePhyMemModeReg = 0x24C00824'u32
  BlePhyLdpcModeReg = 0x24C00834'u32
  BlePhyAgcMemGateReg = 0x24C00874'u32
  BlePhyAgcLoadReg = 0x24C0B390'u32
  BlePhyLdpcMemSelectMask = 0x03000000'u32
  BlePhyLdpcLoadModeMask = 0xFF000000'u32
  BlePhyLdpcLoadMode = 0x06000000'u32
  BlePhyAgcMemGateMask = 0x20000000'u32
  BlePhyAgcLoadEnableMask = 0x00001000'u32
  BleLdpcInitWords = 190

static:
  doAssert offsetof(BleRfRegBlock, baseCtrl1) == 0x04
  doAssert offsetof(BleRfRegBlock, calCtrl1c) == 0x1C
  doAssert offsetof(BleRfRegBlock, capability20) == 0x20
  doAssert offsetof(BleRfRegBlock, synthCtrl2c) == 0x2C
  doAssert offsetof(BleRfRegBlock, priModeCtrl30) == 0x30
  doAssert offsetof(BleRfRegBlock, rccalTone48) == 0x48
  doAssert offsetof(BleRfRegBlock, txcalBias58) == 0x58
  doAssert offsetof(BleRfRegBlock, txcalGain64) == 0x64
  doAssert offsetof(BleRfRegBlock, txcalGain68) == 0x68
  doAssert offsetof(BleRfRegBlock, txcalParam70) == 0x70
  doAssert offsetof(BleRfRegBlock, rbbRccalCtrl80) == 0x80
  doAssert offsetof(BleRfRegBlock, txcalDfe88) == 0x88
  doAssert offsetof(BleRfRegBlock, rccalReplay84) == 0x84
  doAssert offsetof(BleRfRegBlock, calPathConfig8c) == 0x8C
  doAssert offsetof(BleRfRegBlock, fcalCtrlA0) == 0xA0
  doAssert offsetof(BleRfRegBlock, acalCtrlA4) == 0xA4
  doAssert offsetof(BleRfRegBlock, calResultA8) == 0xA8
  doAssert offsetof(BleRfRegBlock, fcalAc) == 0xAC
  doAssert offsetof(BleRfRegBlock, channelCalStrobeB0) == 0xB0
  doAssert offsetof(BleRfRegBlock, channelCalStatusB4) == 0xB4
  doAssert offsetof(BleRfRegBlock, txcalCtrlB8) == 0xB8
  doAssert offsetof(BleRfRegBlock, channelFcalConfigBc) == 0xBC
  doAssert offsetof(BleRfRegBlock, sdmCtrlC0) == 0xC0
  doAssert offsetof(BleRfRegBlock, sdmDivC4) == 0xC4
  doAssert offsetof(BleRfRegBlock, rfPriBiasTrimCc) == 0xCC
  doAssert offsetof(BleRfRegBlock, optimizeCtrlD0) == 0xD0
  doAssert offsetof(BleRfRegBlock, rfBiasTrimD4) == 0xD4
  doAssert offsetof(BleRfRegBlock, calMixerStateF0) == 0xF0
  doAssert offsetof(BleRfRegBlock, vcoPairTable13c) == 0x13C
  doAssert offsetof(BleRfRegBlock, vcoPair2484Mhz164) == 0x164
  doAssert offsetof(BleRfRegBlock, calSingenCtrl20c) == 0x20C
  doAssert offsetof(BleRfRegBlock, calSingenAmpLo214) == 0x214
  doAssert offsetof(BleRfRegBlock, calSingenAmpHi218) == 0x218
  doAssert offsetof(BleRfRegBlock, rxMode220) == 0x220
  doAssert offsetof(BleRfRegBlock, calDfeGate23c) == 0x23C
  doAssert offsetof(BleRfRegBlock, calDfeState240) == 0x240
  doAssert offsetof(BleRfRegBlock, calDfeState244) == 0x244
  doAssert offsetof(BleRfRegBlock, txcalTosdac600) == 0x600
  doAssert offsetof(BleRfRegBlock, calMeasurePrep60c) == 0x60C
  doAssert offsetof(BleRfRegBlock, measureCtrl618) == 0x618
  doAssert offsetof(BleRfRegBlock, measureMode61c) == 0x61C
  doAssert offsetof(BleRfDfeInitBlock, hbnCtrl30) == 0x30

template bleRfRegs(): ptr BleRfRegBlock =
  cast[ptr BleRfRegBlock](BleRfBase)

template bleRfDfeInitRegs(): ptr BleRfDfeInitBlock =
  cast[ptr BleRfDfeInitBlock](BleRfDfeInitBase)

const
  BlePhyAgcInit: array[88, BleRegInit] = [
    BleRegInit(address: 0x24C00800'u32, value: 0x00000000'u32),
    BleRegInit(address: 0x24C00820'u32, value: 0x0000130D'u32),
    BleRegInit(address: 0x24C0089C'u32, value: 0xFFFFFFFF'u32),
    BleRegInit(address: 0x24C00824'u32, value: 0x0000010D'u32),
    BleRegInit(address: 0x24C00830'u32, value: 0x00001B0F'u32),
    BleRegInit(address: 0x24C0083C'u32, value: 0x04920492'u32),
    BleRegInit(address: 0x24C00838'u32, value: 0x000000B4'u32),
    BleRegInit(address: 0x24C0088C'u32, value: 0x00001C13'u32),
    BleRegInit(address: 0x24C00898'u32, value: 0x02D00438'u32),
    BleRegInit(address: 0x24C00818'u32, value: 0x01880C06'u32),
    BleRegInit(address: 0x24C0081C'u32, value: 0x00000F0F'u32),
    BleRegInit(address: 0x24C00840'u32, value: 0x03310000'u32),
    BleRegInit(address: 0x24C00860'u32, value: 0x00007F03'u32),
    BleRegInit(address: 0x24C0B004'u32, value: 0x00000001'u32),
    BleRegInit(address: 0x24C0B304'u32, value: 0x42004200'u32),
    BleRegInit(address: 0x24C0B340'u32, value: 0x02040507'u32),
    BleRegInit(address: 0x24C0B344'u32, value: 0x00000001'u32),
    BleRegInit(address: 0x24C0B34C'u32, value: 0x090B0D10'u32),
    BleRegInit(address: 0x24C0B350'u32, value: 0x02030305'u32),
    BleRegInit(address: 0x24C0B354'u32, value: 0x00000101'u32),
    BleRegInit(address: 0x24C0B358'u32, value: 0x181B1D20'u32),
    BleRegInit(address: 0x24C0B35C'u32, value: 0x0E0F1014'u32),
    BleRegInit(address: 0x24C0B360'u32, value: 0x0000080A'u32),
    BleRegInit(address: 0x24C0B364'u32, value: 0x083C3839'u32),
    BleRegInit(address: 0x24C0B368'u32, value: 0x00288288'u32),
    BleRegInit(address: 0x24C0B36C'u32, value: 0x05200710'u32),
    BleRegInit(address: 0x24C0B370'u32, value: 0x08540308'u32),
    BleRegInit(address: 0x24C0B374'u32, value: 0x13111400'u32),
    BleRegInit(address: 0x24C0B378'u32, value: 0x08020002'u32),
    BleRegInit(address: 0x24C0B37C'u32, value: 0x00020000'u32),
    BleRegInit(address: 0x24C0B380'u32, value: 0xFB704402'u32),
    BleRegInit(address: 0x24C0B384'u32, value: 0x51004405'u32),
    BleRegInit(address: 0x24C0B388'u32, value: 0x5573C808'u32),
    BleRegInit(address: 0x24C0B38C'u32, value: 0x6403880B'u32),
    BleRegInit(address: 0x24C0B390'u32, value: 0x00010403'u32),
    BleRegInit(address: 0x24C0B394'u32, value: 0x0CF8B500'u32),
    BleRegInit(address: 0x24C0B398'u32, value: 0x00009C00'u32),
    BleRegInit(address: 0x24C0B3A0'u32, value: 0x0BF3009C'u32),
    BleRegInit(address: 0x24C0B3A4'u32, value: 0x00000303'u32),
    BleRegInit(address: 0x24C0B3A8'u32, value: 0x00550909'u32),
    BleRegInit(address: 0x24C0B3AC'u32, value: 0x1B5BF3C2'u32),
    BleRegInit(address: 0x24C0B3B0'u32, value: 0xAAAA0377'u32),
    BleRegInit(address: 0x24C0B3B4'u32, value: 0x00D406FE'u32),
    BleRegInit(address: 0x24C0B3B8'u32, value: 0x00000080'u32),
    BleRegInit(address: 0x24C0B3BC'u32, value: 0x00088B80'u32),
    BleRegInit(address: 0x24C0B3C0'u32, value: 0x2828B0B5'u32),
    BleRegInit(address: 0x24C0B3C4'u32, value: 0xDDDBBFBE'u32),
    BleRegInit(address: 0x24C0B3D4'u32, value: 0x1B0B50B8'u32),
    BleRegInit(address: 0x24C0B3D8'u32, value: 0x1B0B50B8'u32),
    BleRegInit(address: 0x24C0B500'u32, value: 0x00041010'u32),
    BleRegInit(address: 0x24C0C000'u32, value: 0x00000010'u32),
    BleRegInit(address: 0x24C0C008'u32, value: 0x00043121'u32),
    BleRegInit(address: 0x24C0C00C'u32, value: 0x00043121'u32),
    BleRegInit(address: 0x24C0C010'u32, value: 0x00263063'u32),
    BleRegInit(address: 0x24C0C014'u32, value: 0x00260060'u32),
    BleRegInit(address: 0x24C0C018'u32, value: 0x00050190'u32),
    BleRegInit(address: 0x24C0C01C'u32, value: 0x00050050'u32),
    BleRegInit(address: 0x24C0C020'u32, value: 0x00050050'u32),
    BleRegInit(address: 0x24C0C028'u32, value: 0x00000050'u32),
    BleRegInit(address: 0x24C0C02C'u32, value: 0x00000008'u32),
    BleRegInit(address: 0x24C0C030'u32, value: 0x00A00000'u32),
    BleRegInit(address: 0x24C0C034'u32, value: 0x0000001A'u32),
    BleRegInit(address: 0x24C0C03C'u32, value: 0x00420003'u32),
    BleRegInit(address: 0x24C0C040'u32, value: 0x68C18000'u32),
    BleRegInit(address: 0x24C0C044'u32, value: 0x00000800'u32),
    BleRegInit(address: 0x24C0C080'u32, value: 0x1C150D05'u32),
    BleRegInit(address: 0x24C0C084'u32, value: 0x37302923'u32),
    BleRegInit(address: 0x24C0C088'u32, value: 0x0000003D'u32),
    BleRegInit(address: 0x24C0C800'u32, value: 0x0000080F'u32),
    BleRegInit(address: 0x24C0C80C'u32, value: 0x20000000'u32),
    BleRegInit(address: 0x24C0C814'u32, value: 0x00000088'u32),
    BleRegInit(address: 0x24C0C82C'u32, value: 0x000FD2C4'u32),
    BleRegInit(address: 0x24C0C830'u32, value: 0xFCF0440D'u32),
    BleRegInit(address: 0x24C0C834'u32, value: 0x00000002'u32),
    BleRegInit(address: 0x24C0C838'u32, value: 0x80000100'u32),
    BleRegInit(address: 0x24C0C83C'u32, value: 0x80000020'u32),
    BleRegInit(address: 0x24C0C840'u32, value: 0x80000020'u32),
    BleRegInit(address: 0x24C0C844'u32, value: 0x00300018'u32),
    BleRegInit(address: 0x24C0C848'u32, value: 0x00000048'u32),
    BleRegInit(address: 0x24C0C84C'u32, value: 0x00100C08'u32),
    BleRegInit(address: 0x24C0C850'u32, value: 0x083B020A'u32),
    BleRegInit(address: 0x24C0C854'u32, value: 0x42EDEFEF'u32),
    BleRegInit(address: 0x24C0C858'u32, value: 0x00EAF1F1'u32),
    BleRegInit(address: 0x24C0C85C'u32, value: 0x003E0504'u32),
    BleRegInit(address: 0x24C0C860'u32, value: 0x00001FAE'u32),
    BleRegInit(address: 0x24C0C904'u32, value: 0x00060000'u32),
    BleRegInit(address: 0x24C0C908'u32, value: 0x0500002D'u32),
    BleRegInit(address: 0x2000126C'u32, value: 0x05000000'u32)
  ]

  BleRf1MInit: array[11, BleRegInit] = [
    BleRegInit(address: 0x200010A0'u32, value: 0x070B8B97'u32),
    BleRegInit(address: 0x200010A4'u32, value: 0x00001301'u32),
    BleRegInit(address: 0x200010A8'u32, value: 0x00000855'u32),
    BleRegInit(address: 0x200010B0'u32, value: 0x00011100'u32),
    BleRegInit(address: 0x200010B4'u32, value: BleRfPower4DbmTxCal),
    BleRegInit(address: 0x200010B8'u32, value: 0x00001111'u32),
    BleRegInit(address: 0x200010BC'u32, value: 0x10911100'u32),
    BleRegInit(address: 0x200010C0'u32, value: 0x00130101'u32),
    BleRegInit(address: 0x200010C4'u32, value: 0x1501C71C'u32),
    BleRegInit(address: 0x200010C8'u32, value: 0x14A7FFF9'u32),
    BleRegInit(address: BleRfPriBiasTrimReg, value: 0x50000002'u32)
  ]

  BleRfPriStaticInit: array[23, BleRegMaskInit] = [
    BleRegMaskInit(address: BleRfPllEnableReg,
                   keepMask: 0xFFFFF9FF'u32, setMask: 0x000001FC'u32),
    BleRegMaskInit(address: BleRfPllEnableReg,
                   keepMask: 0xFFFFFFFF'u32, setMask: 0x00000002'u32),
    BleRegMaskInit(address: BleRfPllEnableReg,
                   keepMask: 0xFFFFFFFF'u32, setMask: 0x00000001'u32),
    BleRegMaskInit(address: BleRfRxModeReg,
                   keepMask: 0xFFFFE67D'u32, setMask: 0x00000000'u32),
    BleRegMaskInit(address: BleRfRxModeReg,
                   keepMask: 0xFFFFFF9E'u32, setMask: 0x00000000'u32),
    BleRegMaskInit(address: BleRfDfeStaticCtrlReg,
                   keepMask: 0xFF0FFFFF'u32, setMask: 0x00300000'u32),
    BleRegMaskInit(address: BleRfDfeHbnCtrlReg,
                   keepMask: 0xF0FFFFFF'u32, setMask: 0x08000000'u32),
    BleRegMaskInit(address: BleRfPriModeCtrlReg,
                   keepMask: 0xFFFFFFFF'u32, setMask: 0x00001003'u32),
    BleRegMaskInit(address: BleRfDfeFixedDefault884Reg,
                   keepMask: 0xF000FFFF'u32, setMask: 0x082000F4'u32),
    BleRegMaskInit(address: BleRfPriBiasTrimReg,
                   keepMask: 0xFFFFFFFF'u32, setMask: 0x10000000'u32),
    BleRegMaskInit(address: BleRfSynthDfePathControlReg,
                   keepMask: 0x00000000'u32, setMask: 0x00000000'u32),
    BleRegMaskInit(address: BleRfTxcalGain64Reg,
                   keepMask: 0xFFFE0008'u32, setMask: 0x00004C2C'u32),
    BleRegMaskInit(address: BleRfTxcalDefaultProfile128Reg,
                   keepMask: 0xFF800800'u32, setMask: 0x004C2491'u32),
    BleRegMaskInit(address: BleRfTxcalDefaultProfile12cReg,
                   keepMask: 0xFF800800'u32, setMask: 0x004C2582'u32),
    BleRegMaskInit(address: BleRfTxcalDefaultProfile130Reg,
                   keepMask: 0xFF800FFF'u32, setMask: 0x00491000'u32),
    BleRegMaskInit(address: BleRfBiasTrimD4Reg,
                   keepMask: 0xFFF0F00F'u32, setMask: 0x00F013C1'u32),
    BleRegMaskInit(address: BleRfCalPathCtrlReg,
                   keepMask: 0xFFFFFFFF'u32, setMask: 0x00010000'u32),
    BleRegMaskInit(address: BleRfTxcalCtrlReg,
                   keepMask: 0xFFFFFFFF'u32, setMask: 0x00000010'u32),
    BleRegMaskInit(address: BleRfCalModeDefaultReg,
                   keepMask: 0xFFFFFFFF'u32, setMask: 0x00000003'u32),
    BleRegMaskInit(address: BleRfTxcalDefaultProfile130Reg,
                   keepMask: 0xFFFFFE92'u32, setMask: 0x00000092'u32),
    BleRegMaskInit(address: BleRfCalPathConfigReg,
                   keepMask: 0xFFFFFFF8'u32, setMask: 0x00000002'u32),
    BleRegMaskInit(address: BleRfAverageMeasureCtrlReg,
                   keepMask: 0x3FFFFFFF'u32, setMask: 0x00000000'u32),
    BleRegMaskInit(address: BleRfRxModeReg,
                   keepMask: 0xFFFFFFEF'u32, setMask: 0x00000000'u32)
  ]

  BleRfPriGainInit: array[12, BleRegMaskInit] = [
    BleRegMaskInit(address: 0x20001760'u32,
                   keepMask: 0xFF000000'u32, setMask: 0x00003189'u32),
    BleRegMaskInit(address: 0x2000175C'u32,
                   keepMask: 0xFF000000'u32, setMask: 0x0030F495'u32),
    BleRegMaskInit(address: 0x2000179C'u32,
                   keepMask: 0xC00007FF'u32, setMask: 0xD037D000'u32),
    BleRegMaskInit(address: 0x20001794'u32,
                   keepMask: 0xC00007FF'u32, setMask: 0xD06FF000'u32),
    BleRegMaskInit(address: 0x2000178C'u32,
                   keepMask: 0xC00007FF'u32, setMask: 0xD077E000'u32),
    BleRegMaskInit(address: 0x20001784'u32,
                   keepMask: 0xC00007FF'u32, setMask: 0x10940000'u32),
    BleRegMaskInit(address: 0x2000177C'u32,
                   keepMask: 0xC00007FF'u32, setMask: 0x109C0000'u32),
    BleRegMaskInit(address: 0x20001774'u32,
                   keepMask: 0xC00007FF'u32, setMask: 0x11180000'u32),
    BleRegMaskInit(address: 0x2000176C'u32,
                   keepMask: 0xC00007FF'u32, setMask: 0x115C0000'u32),
    BleRegMaskInit(address: 0x20001764'u32,
                   keepMask: 0xC00007FF'u32, setMask: 0x11FC0000'u32),
    BleRegMaskInit(address: BleRfSynthCtrlReg,
                   keepMask: 0xFFFFFFFF'u32, setMask: 0x00004007'u32),
    BleRegMaskInit(address: BleRfSynthDfePathControlReg,
                   keepMask: 0xFFFFFFFF'u32, setMask: 0x00008080'u32)
  ]

  BleRfPriTxPowerRegisterBase: array[43, uint32] = [
    0x004524D4'u32, 0x0028E3D0'u32, 0x135FC000'u32, 0x00000000'u32,
    0x12DFC000'u32, 0x00000000'u32, 0x123FE000'u32, 0x00000000'u32,
    0x123FC000'u32, 0x00000000'u32, 0x119FF000'u32, 0x00000000'u32,
    0x119FD000'u32, 0x00000000'u32, 0x113FF000'u32, 0x00000000'u32,
    0x10FBD000'u32, 0x00000000'u32, 0x00000000'u32, 0x00000000'u32,
    0x00000000'u32, 0x00000000'u32, 0x00000000'u32, 0x0030F495'u32,
    0x00003189'u32, 0x11FC0000'u32, 0x00000000'u32, 0x115C0000'u32,
    0x00000000'u32, 0x11180000'u32, 0x00000000'u32, 0x109C0000'u32,
    0x00000000'u32, 0x10940000'u32, 0x00000000'u32, 0x1077E000'u32,
    0x00000000'u32, 0x106FF000'u32, 0x00000000'u32, 0x1037D000'u32,
    0x00000000'u32, 0x000420FC'u32, 0x04030201'u32
  ]

  BleRfPriTxcalParams: array[BleRfTxcalSearchRecords, array[5, uint32]] = [
    [6'u32, 4'u32, 4'u32, 0x00010000'u32, 3'u32],
    [6'u32, 4'u32, 4'u32, 0x00010000'u32, 3'u32],
    [6'u32, 4'u32, 4'u32, 0x00010000'u32, 7'u32],
    [6'u32, 4'u32, 4'u32, 0x00010000'u32, 7'u32],
    [6'u32, 4'u32, 4'u32, 0x00010000'u32, 7'u32],
    [6'u32, 4'u32, 4'u32, 0x00010000'u32, 7'u32],
    [6'u32, 4'u32, 4'u32, 0x00010000'u32, 7'u32],
    [6'u32, 4'u32, 4'u32, 0x00010000'u32, 7'u32]
  ]

  BleRfChannelDivTable40M: array[BleRfLoChannelCount, uint32] = [
    0x14088889'u32, 0x14111111'u32, 0x1419999A'u32, 0x14222222'u32,
    0x142AAAAB'u32, 0x14333333'u32, 0x143BBBBC'u32, 0x14444444'u32,
    0x144CCCCD'u32, 0x14555555'u32, 0x145DDDDE'u32, 0x14666666'u32,
    0x146EEEEF'u32, 0x14777777'u32, 0x14800000'u32, 0x14888889'u32,
    0x14911111'u32, 0x1499999A'u32, 0x14A22222'u32, 0x14AAAAAB'u32,
    0x14B33333'u32
  ]

  BleRfChannelCntTable40M: array[BleRfLoChannelCount, uint16] = [
    0xA6EB'u16, 0xA732'u16, 0xA779'u16, 0xA7C0'u16, 0xA808'u16,
    0xA84F'u16, 0xA896'u16, 0xA8DD'u16, 0xA924'u16, 0xA96B'u16,
    0xA9B2'u16, 0xA9F9'u16, 0xAA40'u16, 0xAA87'u16, 0xAACF'u16,
    0xAB16'u16, 0xAB5D'u16, 0xABA4'u16, 0xABEB'u16, 0xAC32'u16,
    0xAC79'u16
  ]

proc writeBleRegInit(table: openArray[BleRegInit]) =
  for item in table:
    regWrite(item.address.uint, item.value)

proc writeBleRegMaskInit(table: openArray[BleRegMaskInit]) =
  for item in table:
    regWrite(item.address.uint,
             (regRead(item.address.uint) and item.keepMask) or item.setMask)

type
  BleRfCalibData = object
    inited: uint32
    cal: array[6, uint32]
    lo: array[BleRfLoChannelCount, uint16]
    loPad: uint16
    rxcal: array[8, uint32]
    txcal: array[16, uint32]

  BleRfPriCalState = object
    baseCtrl1: uint32
    synthCtrl2c: uint32
    calCtrl1c: uint32
    priModeCtrl30: uint32
    txcalCtrlB8: uint32
    sdmCtrlC0: uint32
    sdmDivC4: uint32
    hbnCtrl30: uint32
    rbbRccalCtrl80: uint32
    calPathConfig8c: uint32
    txcalTosdac600: uint32
    calMeasurePrep60c: uint32
    measureCtrl618: uint32
    measureMode61c: uint32
    rccalTone48: uint32
    calSingenCtrl20c: uint32
    calSingenAmpLo214: uint32
    calSingenAmpHi218: uint32
    calDfeGate23c: uint32
    calDfeState240: uint32
    calDfeState244: uint32
    calMixerStateF0: uint32
    txcalGain64: uint32
    txcalBias58: uint32
    rxMode220: uint32
    txcalParam70: uint32
    acalCtrlA4: uint32
    txcalGain68: uint32
    txcalDfe88: uint32

const
  BleRfCalibDataSize = sizeof(BleRfCalibData)

static:
  doAssert BleRfCalibDataSize == 168

var bleRfCalibData: BleRfCalibData
var bleRfChannelFcalTable: array[BleRfLoChannelCount, uint16]
var bleRfChannelAcalTable: array[BleRfLoChannelCount, uint16]

var nim_ble_rf_service_count* {.exportc.}: uint32
var nim_ble_rf_txcal_latch_count* {.exportc.}: uint32
var nim_ble_rf_fcal_ready_count* {.exportc.}: uint32
var nim_ble_rf_fcal_wait_timeout_count* {.exportc.}: uint32
var nim_ble_rf_last_txcal_before* {.exportc.}: uint32
var nim_ble_rf_last_txcal_after* {.exportc.}: uint32
var nim_ble_rf_last_fcal_before* {.exportc.}: uint32
var nim_ble_rf_last_fcal_after* {.exportc.}: uint32

proc serviceBleRfCalibrationLatch() =
  ## Match the reference RF delay hook: settle calibration latches while RF
  ## bring-up/tuning is actively polling the clocked RF block.
  inc nim_ble_rf_service_count
  var touched = false
  var txcal = regRead(BleRfTxPowerReg.uint)
  nim_ble_rf_last_txcal_before = txcal
  if (txcal and BleRfTxcalLatchMask) != 0'u32:
    inc nim_ble_rf_txcal_latch_count
    txcal = txcal and not BleRfTxcalLatchMask
    regWrite(BleRfTxPowerReg.uint, txcal)
    touched = true
  nim_ble_rf_last_txcal_after = regRead(BleRfTxPowerReg.uint)
  var fcal = regRead(BleRfFcalReg.uint)
  nim_ble_rf_last_fcal_before = fcal
  if (fcal and BleRfFcalReadyMask) != 0'u32:
    inc nim_ble_rf_fcal_ready_count
  nim_ble_rf_last_fcal_after = regRead(BleRfFcalReg.uint)
  when defined(bl808m0):
    if touched:
      nimDisableM0RfClicIrq()

proc bleRfDelayUs(us: uint32) =
  serviceBleRfCalibrationLatch()
  delayUs(us)
  serviceBleRfCalibrationLatch()

proc settleBleRfCalibrationLatches(iterations: int = 8) =
  ## RF calibration latches can assert shortly after a tuning write.  The vendor
  ## delay hook clears them after each RF delay; mirror that with a bounded
  ## settle loop at the end of RF bring-up and channel changes.
  for _ in 0 ..< iterations:
    bleRfDelayUs(10)
  serviceBleRfCalibrationLatch()

proc writeBleMemoryWords(base: uint32, words: openArray[uint32]) =
  for i, word in words:
    regWrite((base + uint32(i) * 4'u32).uint, word)

proc writeBleMemoryWords(base: uint32, words: openArray[uint32], count: int) =
  let limit = min(count, words.len)
  for i in 0 ..< limit:
    regWrite((base + uint32(i) * 4'u32).uint, words[i])

proc clearBleMemoryWords(base: uint32, count: int) =
  for i in 0 ..< count:
    regWrite((base + uint32(i) * 4'u32).uint, 0'u32)

var nim_ble_rf_tune_count* {.exportc.}: uint32
var nim_ble_rf_last_channel_mhz* {.exportc.}: uint32
var nim_ble_rf_last_notch_word* {.exportc.}: uint32
var nim_ble_rf_optimize_count* {.exportc.}: uint32
var nim_ble_rf_last_optimize_word* {.exportc.}: uint32
var nim_ble_rf_init_count* {.exportc.}: uint32
var nim_ble_wifi_rf_dirty_epoch* {.exportc.}: uint32
var nim_ble_wifi_rf_reclaimed_epoch* {.exportc.}: uint32
var nim_ble_rf_pri_static_count* {.exportc.}: uint32
var nim_ble_rf_pri_gain_count* {.exportc.}: uint32
var nim_ble_rf_pri_tx_power_table_count* {.exportc.}: uint32
var nim_ble_rf_pri_lo_fcal_count* {.exportc.}: uint32
var nim_ble_rf_pri_lo_acal_count* {.exportc.}: uint32
var nim_ble_rf_pri_roscal_count* {.exportc.}: uint32
var nim_ble_rf_pri_vco_table_count* {.exportc.}: uint32
var nim_ble_phy_init_count* {.exportc.}: uint32
var nim_ble_phy_mem_load_count* {.exportc.}: uint32
var nim_ble_rf_last_pri_init_64* {.exportc.}: uint32
var nim_ble_rf_last_pri_init_d4* {.exportc.}: uint32
var nim_ble_rf_last_init_a0* {.exportc.}: uint32
var nim_ble_rf_last_init_b0* {.exportc.}: uint32
var nim_ble_rf_last_init_b4* {.exportc.}: uint32
var nim_ble_rf_last_init_c8* {.exportc.}: uint32
var nim_ble_rf_last_lo_fcal* {.exportc.}: uint32

proc markBleRfDirtyForWifi() {.inline.} =
  inc nim_ble_wifi_rf_dirty_epoch

proc nim_ble_coex_wifi_rf_reclaim_needed*(): uint32 {.exportc, cdecl.} =
  if nim_ble_wifi_rf_dirty_epoch == nim_ble_wifi_rf_reclaimed_epoch:
    return 0'u32
  nim_ble_wifi_rf_reclaimed_epoch = nim_ble_wifi_rf_dirty_epoch
  1'u32
var nim_ble_rf_last_lo_acal* {.exportc.}: uint32
var nim_ble_rf_last_roscal_i* {.exportc.}: uint32
var nim_ble_rf_last_roscal_q* {.exportc.}: uint32
var nim_ble_rf_roscal_wait_timeout_count* {.exportc.}: uint32
var nim_ble_rf_last_roscal_raw_i* {.exportc.}: uint32
var nim_ble_rf_last_roscal_raw_q* {.exportc.}: uint32
var nim_ble_rf_pri_rccal_count* {.exportc.}: uint32
var nim_ble_rf_rccal_wait_timeout_count* {.exportc.}: uint32
var nim_ble_rf_last_rccal_code* {.exportc.}: uint32
var nim_ble_rf_last_rccal_baseline* {.exportc.}: uint32
var nim_ble_rf_last_rccal_target* {.exportc.}: uint32
var nim_ble_rf_last_rccal_power* {.exportc.}: uint32
var nim_ble_rf_pri_txcal_count* {.exportc.}: uint32
var nim_ble_rf_txcal_wait_timeout_count* {.exportc.}: uint32
var nim_ble_rf_txcal_search_count* {.exportc.}: uint32
var nim_ble_rf_txcal_amp_search_count* {.exportc.}: uint32
var nim_ble_rf_last_txcal_amp* {.exportc.}: uint32
var nim_ble_rf_last_txcal_amp_mean* {.exportc.}: uint32
var nim_ble_rf_last_txcal_tmxcs* {.exportc.}: uint32
var nim_ble_rf_last_txcal_tmxcs_power* {.exportc.}: uint32
var nim_ble_rf_last_txcal_word0* {.exportc.}: uint32
var nim_ble_rf_last_txcal_word1* {.exportc.}: uint32
var nim_ble_rf_last_vco_113c* {.exportc.}: uint32
var nim_ble_rf_last_vco_1164* {.exportc.}: uint32
var nim_ble_rf_fcal_search_log* {.exportc.}: array[16, uint32]
var nim_ble_rf_roscal_search_log* {.exportc.}: array[16, uint32]
var nim_ble_rf_roscal_raw_log* {.exportc.}: array[16, uint32]
var nim_ble_rf_rccal_search_log* {.exportc.}: array[16, uint32]
var nim_ble_rf_rccal_power_log* {.exportc.}: array[16, uint32]
var nim_ble_rf_txcal_word0_log* {.exportc.}: array[BleRfTxcalSearchRecords, uint32]
var nim_ble_rf_txcal_word1_log* {.exportc.}: array[BleRfTxcalSearchRecords, uint32]
var nim_ble_rf_txcal_power_log* {.exportc.}: array[BleRfTxcalSearchRecords, uint32]
var nim_ble_rf_txcal_amp_log* {.exportc.}: array[BleRfTxcalSearchRecords, uint32]
var nim_ble_rf_txcal_tmxcs_power_log* {.exportc.}: array[BleRfTxcalMixerCsCount, uint32]

proc rfLoFcal(word: uint16): uint16 {.inline.} =
  word and 0x00FF'u16

proc rfLoAcal(word: uint16): uint16 {.inline.} =
  (word shr 8) and 0x001F'u16

proc setRfLoFcal(index: int, fcal: uint16) =
  let value = (bleRfCalibData.lo[index] and 0xFF00'u16) or (fcal and 0x00FF'u16)
  bleRfCalibData.lo[index] = value

proc setRfLoAcal(index: int, acal: uint16) =
  let value = (bleRfCalibData.lo[index] and 0xE0FF'u16) or
    ((acal and 0x001F'u16) shl 8)
  bleRfCalibData.lo[index] = value

proc resetBleRfCalibData() =
  bleRfCalibData = default(BleRfCalibData)
  bleRfCalibData.inited = 1
  for i in 0 ..< BleRfLoChannelCount:
    bleRfChannelFcalTable[i] = 0
    bleRfChannelAcalTable[i] = 0

proc saveBleRfPriCalState(): BleRfPriCalState =
  let rf = bleRfRegs()
  let dfe = bleRfDfeInitRegs()
  result.baseCtrl1 = volatileLoad(addr rf.baseCtrl1)
  result.synthCtrl2c = volatileLoad(addr rf.synthCtrl2c)
  result.calCtrl1c = volatileLoad(addr rf.calCtrl1c)
  result.priModeCtrl30 = volatileLoad(addr rf.priModeCtrl30)
  result.txcalCtrlB8 = volatileLoad(addr rf.txcalCtrlB8)
  result.sdmCtrlC0 = volatileLoad(addr rf.sdmCtrlC0)
  result.sdmDivC4 = volatileLoad(addr rf.sdmDivC4)
  result.hbnCtrl30 = volatileLoad(addr dfe.hbnCtrl30)
  result.rbbRccalCtrl80 = volatileLoad(addr rf.rbbRccalCtrl80)
  result.calPathConfig8c = volatileLoad(addr rf.calPathConfig8c)
  result.txcalTosdac600 = volatileLoad(addr rf.txcalTosdac600)
  result.calMeasurePrep60c = volatileLoad(addr rf.calMeasurePrep60c)
  result.measureCtrl618 = volatileLoad(addr rf.measureCtrl618)
  result.measureMode61c = volatileLoad(addr rf.measureMode61c)
  result.rccalTone48 = volatileLoad(addr rf.rccalTone48)
  result.calSingenCtrl20c = volatileLoad(addr rf.calSingenCtrl20c)
  result.calSingenAmpLo214 = volatileLoad(addr rf.calSingenAmpLo214)
  result.calSingenAmpHi218 = volatileLoad(addr rf.calSingenAmpHi218)
  result.calDfeGate23c = volatileLoad(addr rf.calDfeGate23c)
  result.calDfeState240 = volatileLoad(addr rf.calDfeState240)
  result.calDfeState244 = volatileLoad(addr rf.calDfeState244)
  result.calMixerStateF0 = volatileLoad(addr rf.calMixerStateF0)
  result.txcalGain64 = volatileLoad(addr rf.txcalGain64)
  result.txcalBias58 = volatileLoad(addr rf.txcalBias58)
  result.rxMode220 = volatileLoad(addr rf.rxMode220)
  result.txcalParam70 = volatileLoad(addr rf.txcalParam70)
  result.acalCtrlA4 = volatileLoad(addr rf.acalCtrlA4)
  result.txcalGain68 = volatileLoad(addr rf.txcalGain68)
  result.txcalDfe88 = volatileLoad(addr rf.txcalDfe88)

proc restoreBleRfPriCalState(state: BleRfPriCalState) =
  let rf = bleRfRegs()
  let dfe = bleRfDfeInitRegs()
  volatileStore(addr rf.baseCtrl1, state.baseCtrl1)
  volatileStore(addr rf.synthCtrl2c, state.synthCtrl2c)
  volatileStore(addr rf.calCtrl1c, state.calCtrl1c)
  volatileStore(addr rf.priModeCtrl30, state.priModeCtrl30)
  volatileStore(addr rf.txcalCtrlB8, state.txcalCtrlB8)
  volatileStore(addr rf.sdmCtrlC0, state.sdmCtrlC0)
  volatileStore(addr rf.sdmDivC4, state.sdmDivC4)
  volatileStore(addr dfe.hbnCtrl30, state.hbnCtrl30)
  volatileStore(addr rf.rbbRccalCtrl80, state.rbbRccalCtrl80)
  volatileStore(addr rf.calPathConfig8c, state.calPathConfig8c)
  volatileStore(addr rf.txcalTosdac600, state.txcalTosdac600)
  volatileStore(addr rf.calMeasurePrep60c, state.calMeasurePrep60c)
  volatileStore(addr rf.measureCtrl618, state.measureCtrl618)
  volatileStore(addr rf.measureMode61c, state.measureMode61c)
  volatileStore(addr rf.rccalTone48, state.rccalTone48)
  volatileStore(addr rf.calSingenCtrl20c, state.calSingenCtrl20c)
  volatileStore(addr rf.calSingenAmpLo214, state.calSingenAmpLo214)
  volatileStore(addr rf.calSingenAmpHi218, state.calSingenAmpHi218)
  volatileStore(addr rf.calDfeGate23c, state.calDfeGate23c)
  volatileStore(addr rf.calDfeState240, state.calDfeState240)
  volatileStore(addr rf.calDfeState244, state.calDfeState244)
  volatileStore(addr rf.calMixerStateF0, state.calMixerStateF0)
  volatileStore(addr rf.txcalGain64, state.txcalGain64)
  volatileStore(addr rf.txcalBias58, state.txcalBias58)
  volatileStore(addr rf.rxMode220, state.rxMode220)
  volatileStore(addr rf.txcalParam70, state.txcalParam70)
  volatileStore(addr rf.acalCtrlA4, state.acalCtrlA4)
  volatileStore(addr rf.txcalGain68, state.txcalGain68)
  volatileStore(addr rf.txcalDfe88, state.txcalDfe88)

proc waitBleRfFcalReady(): bool =
  for _ in 0 ..< BleRfFcalWaitLimit:
    if (regRead(BleRfFcalReg.uint) and BleRfFcalReadyMask) != 0'u32:
      return true
    delayUs(1)
  inc nim_ble_rf_fcal_wait_timeout_count
  false

proc sampleBleRfFcalCount(): uint16 =
  regClear32(BleRfFcalReg, BleRfFcalReadyMask)
  regOr(BleRfFcalReg, BleRfFcalStartMask)
  discard waitBleRfFcalReady()
  result = uint16((regRead(BleRfCalResultReg.uint) shr 16) and 0xFFFF'u32)
  regClear32(BleRfFcalReg, BleRfFcalStartMask)

proc writeBleRfFcalCode(code: uint16) =
  regUpdate(BleRfFcalCtrlReg, BleRfFcalCodeMask, uint32(code and 0x00FF'u16))

proc writeBleRfAcalCode(code: uint16) =
  regUpdate(BleRfFcalCtrlReg, BleRfAcalCodeMask,
            uint32(code and 0x001F'u16) shl 16)

proc prepareBleRfPriLoFcal() =
  regWrite(BleRfCalModeReg.uint,
           (regRead(BleRfCalModeReg.uint) and not 0x00000030'u32) or
           0x00000010'u32)
  regClear32(BleRfCtrlReg, BleRfCtrlTuneEnableMask)
  regWrite(BleRfSynthCtrlReg.uint, 0'u32)
  regOr(BleRfPriModeCtrlReg, 0x00000002'u32)
  regWrite(BleRfPriModeCtrlReg.uint,
           (regRead(BleRfPriModeCtrlReg.uint) and 0x0CF090FF'u32) or
           0x0CF00000'u32)
  regOr(BleRfCalCtrlReg, 0x00000008'u32)
  writeBleRfFcalCode(0x80'u16)
  regClear32(BleRfTxcalCtrlReg, 0x00003000'u32)
  regUpdate(BleRfCalResultReg, 0x0000FFFF'u32, uint32(BleRfLoFcalDiv))
  regWrite(BleRfSdm2Reg.uint, 0x01000000'u32)
  regOr(BleRfSdm1Reg, 0x00001000'u32)
  regClear32(BleRfSdm1Reg, 0x00010000'u32)
  regOr(BleRfTxcalCtrlReg, 0x00010000'u32)
  bleRfDelayUs(10)
  regOr(BleRfSdm1Reg, 0x00010000'u32)
  regClear32(BleRfTxcalCtrlReg, 0x00010000'u32)
  bleRfDelayUs(50)
  regUpdate(BleRfAcalCtrlReg, 0x00000003'u32, 0x00000002'u32)
  bleRfDelayUs(50)

proc chooseBleRfBaseFcalCode(): uint16 =
  var code = 0x80'u16
  var logIndex = 0
  for _ in 0 ..< 4:
    var bit = 0x40'u16
    while bit != 0:
      writeBleRfFcalCode(code)
      bleRfDelayUs(100)
      let count = sampleBleRfFcalCount()
      if logIndex < nim_ble_rf_fcal_search_log.len:
        nim_ble_rf_fcal_search_log[logIndex] =
          (uint32(code) shl 24) or (uint32(bit) shl 16) or uint32(count)
        inc logIndex
      if count < BleRfLoFcalLowCount:
        code = uint16((uint32(code) - uint32(bit)) and 0x00FF'u32)
      elif count > BleRfLoFcalHighCount:
        code = uint16((uint32(code) + uint32(bit)) and 0x00FF'u32)
      else:
        bit = 0
        break
      bit = bit shr 1
    if code >= 15'u16 and code <= 240'u16:
      return code
    regClear32(BleRfSdm1Reg, 0x00010000'u32)
    regOr(BleRfTxcalCtrlReg, 0x00010000'u32)
    bleRfDelayUs(50)
    regOr(BleRfSdm1Reg, 0x00010000'u32)
    regClear32(BleRfTxcalCtrlReg, 0x00010000'u32)
    bleRfDelayUs(50)
    code = 0x80'u16
  if logIndex < nim_ble_rf_fcal_search_log.len:
    nim_ble_rf_fcal_search_log[logIndex] = (0xFF'u32 shl 24) or uint32(code)
  code

proc runBleRfPriLoFcal() =
  inc nim_ble_rf_pri_lo_fcal_count
  regWrite(BleRfCalModeReg.uint,
           (regRead(BleRfCalModeReg.uint) and not 0x00000030'u32) or
           0x00000010'u32)
  let saved = saveBleRfPriCalState()
  prepareBleRfPriLoFcal()

  let baseCode = chooseBleRfBaseFcalCode()
  var measured: array[42, uint16]
  var measuredLen = 0
  var code = uint16(min(255'u32, uint32(baseCode) + 1'u32))
  while measuredLen < measured.len and code != 0'u16:
    writeBleRfFcalCode(code)
    bleRfDelayUs(100)
    measured[measuredLen] = sampleBleRfFcalCount()
    if measuredLen < 7:
      nim_ble_rf_fcal_search_log[8 + measuredLen] =
        (uint32(code) shl 16) or uint32(measured[measuredLen])
    inc measuredLen
    if measured[measuredLen - 1] > BleRfLoFcalStopCount:
      break
    dec code

  nim_ble_rf_fcal_search_log[15] =
    if measuredLen == 0:
      (uint32(baseCode) shl 24)
    else:
      (uint32(baseCode) shl 24) or (uint32(measuredLen) shl 16) or
        uint32(measured[min(measuredLen - 1, measured.high)])

  for i in 0 ..< BleRfLoChannelCount:
    var offset = 0
    while offset < measuredLen and measured[offset] < BleRfChannelCntTable40M[i]:
      inc offset
    var fcal = int(baseCode) + 2 - offset
    if fcal < 0:
      fcal = 0
    elif fcal > 255:
      fcal = 255
    setRfLoFcal(i, uint16(fcal))
    bleRfChannelFcalTable[i] = uint16(fcal)

  restoreBleRfPriCalState(saved)
  regOr(BleRfCalModeReg, 0x00000030'u32)
  nim_ble_rf_last_lo_fcal = rfLoFcal(bleRfCalibData.lo[BleRfLoChannelCount - 1])

proc prepareBleRfPriLoAcal() =
  regWrite(BleRfCalModeReg.uint,
           (regRead(BleRfCalModeReg.uint) and not 0x000000C0'u32) or
           0x00000040'u32)
  regClear32(BleRfCtrlReg, BleRfCtrlTuneEnableMask)
  regWrite(BleRfSynthCtrlReg.uint, 0'u32)
  regOr(BleRfPriModeCtrlReg, 0x00000002'u32)
  regWrite(BleRfPriModeCtrlReg.uint,
           (regRead(BleRfPriModeCtrlReg.uint) and 0x0CF090FF'u32) or
           0x0CF00000'u32)
  regOr(BleRfCalCtrlReg, 0x00000010'u32)

proc runBleRfPriLoAcal() =
  inc nim_ble_rf_pri_lo_acal_count
  regWrite(BleRfCalModeReg.uint,
           (regRead(BleRfCalModeReg.uint) and not 0x000000C0'u32) or
           0x00000040'u32)
  let saved = saveBleRfPriCalState()
  prepareBleRfPriLoAcal()

  for i in 0 ..< BleRfLoChannelCount:
    regUpdate(BleRfAcalCtrlReg, 0x00000700'u32, 0x00000400'u32)
    regUpdate(BleRfFcalCtrlReg, 0x001F0000'u32, 0x00100000'u32)
    writeBleRfFcalCode(rfLoFcal(bleRfCalibData.lo[i]))
    regWrite(BleRfSdm2Reg.uint, BleRfChannelDivTable40M[i])
    bleRfDelayUs(1)

    var acal = 0x10'u16
    var bit = 0x08'u16
    while bit != 0'u16:
      writeBleRfAcalCode(acal)
      bleRfDelayUs(1)
      if (regRead(BleRfAcalCtrlReg.uint) and BleRfAcalComparatorMask) == 0'u32:
        acal = uint16((uint32(acal) + uint32(bit)) and 0xFFFF'u32)
      else:
        acal = uint16((uint32(acal) - uint32(bit)) and 0xFFFF'u32)
      bit = bit shr 1

    writeBleRfAcalCode(acal)
    bleRfDelayUs(1)
    if (regRead(BleRfAcalCtrlReg.uint) and BleRfAcalComparatorMask) == 0'u32 and
        acal <= 30'u16:
      inc acal
    acal = acal and 0x001F'u16
    setRfLoAcal(i, acal)
    bleRfChannelAcalTable[i] = acal

  restoreBleRfPriCalState(saved)
  regOr(BleRfCalModeReg, 0x000000C0'u32)
  nim_ble_rf_last_lo_acal = rfLoAcal(bleRfCalibData.lo[BleRfLoChannelCount - 1])

proc signedBleRfMeasurement(word: uint32): int32 {.inline.} =
  ## Vendor ROS calibration uses th.ext(sample, sample, 0x18, 0): signed
  ## extract of the low 25-bit ADC measurement field.
  result = int32(word and 0x01FF_FFFF'u32)
  if (word and 0x0100_0000'u32) != 0'u32:
    result = result - 0x0200_0000'i32

proc waitBleRfRoscalMeasurementReady(): bool =
  for _ in 0 ..< BleRfRoscalWaitLimit:
    if (regRead(BleRfMeasureCtrlReg.uint) and BleRfMeasureReadyMask) != 0'u32:
      return true
    delayUs(1)
  inc nim_ble_rf_roscal_wait_timeout_count
  false

proc writeBleRfRoscalCandidate(iBranch: bool, code: uint32) =
  let value = code and BleRfRoscalCodeMask
  if iBranch:
    regUpdate(BleRfRoscalCtrlReg, BleRfRoscalIRegMask, value shl 8)
  else:
    regUpdate(BleRfRoscalCtrlReg, BleRfRoscalQRegMask, value)

type
  BleRfRoscalSample = object
    raw: uint32
    signed: int32

proc sampleBleRfRoscalMeasurement(iBranch: bool): BleRfRoscalSample =
  regClear32(BleRfMeasureCtrlReg, BleRfMeasureTriggerClearMask)
  regWrite(BleRfMeasureModeReg.uint,
           (regRead(BleRfMeasureModeReg.uint) and BleRfMeasureModeKeepMask) or
           BleRfMeasureRoscalMode)
  regOr(BleRfMeasureCtrlReg, BleRfMeasureStartMask)
  discard waitBleRfRoscalMeasurementReady()
  let sampleReg =
    if iBranch: BleRfMeasureIReg else: BleRfMeasureQReg
  result.raw = regRead(sampleReg.uint)
  result.signed = signedBleRfMeasurement(result.raw)
  if iBranch:
    nim_ble_rf_last_roscal_raw_i = result.raw
  else:
    nim_ble_rf_last_roscal_raw_q = result.raw
  regClear32(BleRfMeasureCtrlReg, BleRfMeasureTriggerClearMask)

proc logBleRfRoscalSearch(index: var int, iBranch: bool, code: uint32,
                          sample: BleRfRoscalSample) =
  if index < nim_ble_rf_roscal_search_log.len:
    let branchBit =
      if iBranch: 0x80000000'u32 else: 0'u32
    let sampleBits = uint32(sample.signed) and 0x0000FFFF'u32
    nim_ble_rf_roscal_search_log[index] =
      branchBit or ((code and BleRfRoscalCodeMask) shl 16) or sampleBits
    nim_ble_rf_roscal_raw_log[index] = sample.raw
    inc index

proc chooseBleRfRoscalCode(iBranch: bool): uint8 =
  var code = 0'u32
  var bit = 32'u32
  var logIndex =
    if iBranch: 0 else: 8

  for _ in 0 ..< 6:
    let candidate = (code + bit) and BleRfRoscalCodeMask
    writeBleRfRoscalCandidate(iBranch, candidate)
    let sample = sampleBleRfRoscalMeasurement(iBranch)
    logBleRfRoscalSearch(logIndex, iBranch, candidate, sample)
    if sample.signed > 0:
      code = candidate
    bit = bit shr 1

  var history = 0'u32
  for attempt in 0 ..< 63:
    writeBleRfRoscalCandidate(iBranch, code)
    let sample = sampleBleRfRoscalMeasurement(iBranch)
    if attempt < 2:
      logBleRfRoscalSearch(logIndex, iBranch, code, sample)
    history = (history shl 1) and 0x0F'u32
    if sample.signed > 0:
      history = (history + 1'u32) and 0x0F'u32
      code = (code - 1'u32) and BleRfRoscalCodeMask
      if history == 5'u32:
        break
    else:
      code = (code + 1'u32) and BleRfRoscalCodeMask
      if history == 10'u32:
        break

  uint8(code and BleRfRoscalCodeMask)

proc applyBleRfRoscalCodes(iCode, qCode: uint32) =
  let iBits = iCode and BleRfRoscalCodeMask
  let qBits = qCode and BleRfRoscalCodeMask
  for entry in 0 ..< 4:
    let wordIndex = entry * 2
    var word = bleRfCalibData.rxcal[wordIndex]
    word = (word and not 0x00000FFF'u32) or iBits or (qBits shl 6)
    bleRfCalibData.rxcal[wordIndex] = word

  let packed = iBits or (qBits shl 8) or (iBits shl 16) or (qBits shl 24)
  regWrite(BleRfRoscalReg0.uint,
           (regRead(BleRfRoscalReg0.uint) and BleRfRoscalRegisterKeepMask) or
           packed)
  regWrite(BleRfRoscalReg1.uint,
           (regRead(BleRfRoscalReg1.uint) and BleRfRoscalRegisterKeepMask) or
           packed)
  nim_ble_rf_last_roscal_i = iBits
  nim_ble_rf_last_roscal_q = qBits

proc prepareBleRfPriRoscal() =
  let rf = bleRfRegs()
  bleRegClearPtr(addr rf.baseCtrl1, BleRfCtrlTuneEnableMask)
  bleRegStorePtr(addr rf.synthCtrl2c, 0'u32)
  bleRegOrPtr(addr rf.priModeCtrl30, 0x00000002'u32)
  bleRegStorePtr(addr rf.priModeCtrl30,
                 (bleRegLoadPtr(addr rf.priModeCtrl30) and 0x21F0FEFF'u32) or
                 0x21F06E00'u32)
  bleRfDelayUs(0)

  bleRegClearPtr(addr rf.rxMode220, 0x00000180'u32)
  bleRegStorePtr(addr rf.rxMode220,
                 (bleRegLoadPtr(addr rf.rxMode220) and 0xFFFFE7FF'u32) or
                 0x00001082'u32)
  bleRegStorePtr(addr rf.rxMode220,
                 (bleRegLoadPtr(addr rf.rxMode220) and not 0x00000010'u32) or
                 0x00000100'u32)
  bleRegStorePtr(addr rf.rxMode220,
                 (bleRegLoadPtr(addr rf.rxMode220) and not 0x00000060'u32) or
                 0x00000061'u32)
  bleRegOrPtr(addr rf.calCtrl1c, 0x00000200'u32)
  bleRegStorePtr(addr rf.rccalTone48,
                 (bleRegLoadPtr(addr rf.rccalTone48) and 0xFFFF8CFF'u32) or
                 0x00003137'u32)
  regClear32(BleRfRoscalCtrlReg, 0x80000000'u32)

proc runBleRfPriRoscal() =
  let rf = bleRfRegs()
  if (bleRegLoadPtr(addr rf.capability20) and BleRfRoscalCapabilityMask) == 0'u32:
    regClear32(BleRfCalModeReg, BleRfRoscalModeMask)
    return

  inc nim_ble_rf_pri_roscal_count
  regWrite(BleRfCalModeReg.uint,
           (regRead(BleRfCalModeReg.uint) and not BleRfRoscalModeMask) or
           BleRfRoscalStartMode)
  let saved = saveBleRfPriCalState()
  prepareBleRfPriRoscal()
  let iCode = uint32(chooseBleRfRoscalCode(true))
  let qCode = uint32(chooseBleRfRoscalCode(false))
  applyBleRfRoscalCodes(iCode, qCode)
  restoreBleRfPriCalState(saved)
  regOr(BleRfCalModeReg, BleRfRoscalDoneMode)

proc startBleRfPriTxDfeForCal() =
  regClear32(BleRfRxModeReg, 0x00000180'u32)
  regWrite(BleRfRxModeReg.uint,
           (regRead(BleRfRxModeReg.uint) and 0xFFFFE7FF'u32) or
           0x00001082'u32)
  regWrite(BleRfRxModeReg.uint,
           (regRead(BleRfRxModeReg.uint) and not 0x00000010'u32) or
           0x00000100'u32)

proc startBleRfPriRxDfeForCal() =
  regWrite(BleRfRxModeReg.uint,
           (regRead(BleRfRxModeReg.uint) and not 0x00000060'u32) or
           0x00000061'u32)

proc signedBleRfPowerMeasurement(word: uint32): int32 {.inline.} =
  ## RCCAL power accumulation uses the signed 16-bit sample in bits 24:9.
  let sample = (word shr 9) and 0x0000FFFF'u32
  result = int32(sample)
  if (sample and 0x00008000'u32) != 0'u32:
    result = result - 0x00010000'i32

proc waitBleRfRccalMeasurementReady(): bool =
  for _ in 0 ..< BleRfRccalWaitLimit:
    if (regRead(BleRfMeasureCtrlReg.uint) and BleRfMeasureReadyMask) != 0'u32:
      return true
    delayUs(1)
  inc nim_ble_rf_rccal_wait_timeout_count
  false

proc squareSample(sample: int32): uint64 {.inline.} =
  let value = int64(sample)
  uint64(value * value)

proc signedBleRfAverageMeasurement(word: uint32): int32 {.inline.} =
  let sample = word and 0x01FF_FFFF'u32
  result = int32(sample)
  if (sample and 0x0100_0000'u32) != 0'u32:
    result = result - 0x0200_0000'i32

proc saturatingUint32(value: uint64): uint32 {.inline.} =
  if value > uint64(high(uint32)):
    high(uint32)
  else:
    uint32(value)

proc absDiff(a, b: uint64): uint64 {.inline.} =
  if a >= b: a - b else: b - a

proc sampleBleRfRccalPower(): uint32 =
  regClear32(BleRfMeasureCtrlReg, BleRfMeasureRccalTriggerMask)
  regOr(BleRfMeasureCtrlReg, BleRfMeasureRccalTriggerMask)
  bleRfDelayUs(1)
  if not waitBleRfRccalMeasurementReady():
    regClear32(BleRfMeasureCtrlReg, BleRfMeasureRccalTriggerMask)
    return 0'u32

  let iSample = signedBleRfPowerMeasurement(regRead(BleRfMeasureIReg.uint))
  let qSample = signedBleRfPowerMeasurement(regRead(BleRfMeasureQReg.uint))
  regClear32(BleRfMeasureCtrlReg, BleRfMeasureRccalTriggerMask)
  saturatingUint32(squareSample(iSample) + squareSample(qSample))

proc primeBleRfRccalPowerMeasurement() =
  regWrite(BleRfMeasureCtrlReg.uint,
           (regRead(BleRfMeasureCtrlReg.uint) and 0xFFF00000'u32) or
           BleRfRccalReferenceMeasureCtrl)
  regWrite(BleRfMeasureModeReg.uint,
           (regRead(BleRfMeasureModeReg.uint) and BleRfMeasureModeKeepMask) or
           BleRfMeasureRoscalMode)
  regClear32(BleRfMeasureCtrlReg, BleRfMeasureRccalTriggerMask)
  regOr(BleRfMeasureCtrlReg, BleRfMeasureStartMask)
  bleRfDelayUs(1)
  discard waitBleRfRccalMeasurementReady()
  discard regRead(BleRfMeasureIReg.uint)
  regClear32(BleRfMeasureCtrlReg, BleRfMeasureRccalTriggerMask)

proc writeBleRfRccalCode(code: uint32) =
  let value = code and BleRfRccalCodeMask
  let packed = value or (value shl 8) or (value shl 16) or (value shl 24)
  regWrite(BleRfRbbRccalReg.uint,
           (regRead(BleRfRbbRccalReg.uint) and BleRfRccalRegisterKeepMask) or
           packed)
  bleRfCalibData.rxcal[2] =
    (bleRfCalibData.rxcal[2] and not 0x00FF_FFFF'u32) or
    value or (value shl 6) or (value shl 12) or (value shl 18)

proc writeBleRfRccalSearchCode(code: uint32) =
  let value = code and BleRfRccalCodeMask
  var word = regRead(BleRfRbbRccalReg.uint)
  word = (word and 0xC0FF_FFFF'u32) or (value shl 24)
  word = (word and 0xFFFF_C0FF'u32) or (value shl 8)
  regWrite(BleRfRbbRccalReg.uint, word)

proc prepareBleRfPriRccal() =
  regClear32(BleRfCtrlReg, BleRfCtrlTuneEnableMask)
  regWrite(BleRfSynthCtrlReg.uint, 0'u32)
  regOr(BleRfPriModeCtrlReg, 0x00000002'u32)
  regWrite(BleRfPriModeCtrlReg.uint,
           (regRead(BleRfPriModeCtrlReg.uint) and 0x2DF8F8FF'u32) or
           0x2DF87800'u32)
  bleRfDelayUs(0)

  startBleRfPriTxDfeForCal()
  startBleRfPriRxDfeForCal()

  regClear32(BleRfRccalReplayReg, 0x00030000'u32)
  regWrite(BleRfRccalReplayReg.uint,
           (regRead(BleRfRccalReplayReg.uint) and 0xFCFF_FFFF'u32) or
           0x0200_0000'u32)
  regOr(BleRfCalPathConfigReg, 0x00001000'u32)
  regOr(BleRfCalCtrlReg, 0x00000800'u32)
  regClear32(BleRfPriRccalMeasurePrepReg, 0x00000400'u32)
  regOr(BleRfPriRccalMeasurePrepReg, 0x04000000'u32)
  regWrite(BleRfPriRccalToneReg.uint,
           (regRead(BleRfPriRccalToneReg.uint) and 0xFFFF8CFF'u32) or
           0x00003100'u32)
  regWrite(BleRfPriRccalSingenReg0.uint,
           (regRead(BleRfPriRccalSingenReg0.uint) and 0xFC00FFFF'u32) or
           0x00300000'u32)
  regWrite(BleRfPriRccalSingenReg1.uint,
           regRead(BleRfPriRccalSingenReg1.uint) and 0x003FFFFF'u32)
  regWrite(BleRfPriRccalSingenReg2.uint,
           (regRead(BleRfPriRccalSingenReg2.uint) and 0x003FFFFF'u32) or
           0xC0000000'u32)
  regWrite(BleRfPriRccalSingenReg1.uint,
           (regRead(BleRfPriRccalSingenReg1.uint) and 0xFFFFF800'u32) or
           0x000000FF'u32)
  regWrite(BleRfPriRccalSingenReg2.uint,
           (regRead(BleRfPriRccalSingenReg2.uint) and 0xFFFFF800'u32) or
           0x000000FF'u32)
  regClear32(BleRfPriRccalSingenReg0, 0x80000000'u32)
  regOr(BleRfPriRccalSingenReg0, 0x80000000'u32)
  startBleRfPriTxDfeForCal()
  regWrite(BleRfMeasureCtrlReg.uint,
           (regRead(BleRfMeasureCtrlReg.uint) and 0xFFF00000'u32) or
           BleRfRccalReferenceMeasureCtrl)
  regClear32(BleRfMeasureCtrlReg, BleRfMeasureRccalTriggerMask)
  regWrite(BleRfMeasureModeReg.uint,
           (regRead(BleRfMeasureModeReg.uint) and BleRfMeasureModeKeepMask) or
           BleRfMeasureRoscalMode)

proc prepareBleRfPriRccalTone() =
  regWrite(BleRfPriRccalToneReg.uint,
           (regRead(BleRfPriRccalToneReg.uint) and 0xFFFF8CFF'u32) or
           0x00006200'u32)
  regWrite(BleRfPriRccalSingenReg0.uint,
           (regRead(BleRfPriRccalSingenReg0.uint) and 0xFC00FFFF'u32) or
           0x00B50000'u32)
  regWrite(BleRfPriRccalSingenReg1.uint,
           regRead(BleRfPriRccalSingenReg1.uint) and 0x003FFFFF'u32)
  regWrite(BleRfPriRccalSingenReg2.uint,
           (regRead(BleRfPriRccalSingenReg2.uint) and 0x003FFFFF'u32) or
           0xC0000000'u32)
  regClear32(BleRfPriRccalSingenReg0, 0x80000000'u32)
  regOr(BleRfPriRccalSingenReg0, 0x80000000'u32)
  startBleRfPriTxDfeForCal()
  regWrite(BleRfMeasureCtrlReg.uint,
           (regRead(BleRfMeasureCtrlReg.uint) and 0xFFF00000'u32) or
           BleRfRccalToneMeasureCtrl)

proc logBleRfRccalSearch(index: var int, code, power: uint32) =
  if index < nim_ble_rf_rccal_search_log.len:
    nim_ble_rf_rccal_search_log[index] =
      ((code and BleRfRccalCodeMask) shl 24) or (power and 0x00FF_FFFF'u32)
    nim_ble_rf_rccal_power_log[index] = power
    inc index

proc chooseBleRfRccalCode(): tuple[ok: bool, code: uint32] =
  for i in 0 ..< nim_ble_rf_rccal_search_log.len:
    nim_ble_rf_rccal_search_log[i] = 0
    nim_ble_rf_rccal_power_log[i] = 0

  primeBleRfRccalPowerMeasurement()
  let baseline = sampleBleRfRccalPower()

  nim_ble_rf_last_rccal_baseline = baseline
  if baseline == 0'u32:
    nim_ble_rf_last_rccal_target = 0
    nim_ble_rf_last_rccal_power = 0
    nim_ble_rf_last_rccal_code = BleRfRccalBaselineCode
    writeBleRfRccalCode(BleRfRccalBaselineCode)
    return (false, BleRfRccalBaselineCode)

  var target = (uint64(baseline) * BleRfRccalTargetNumerator) div
    BleRfRccalTargetDenominator
  nim_ble_rf_last_rccal_target = saturatingUint32(target)

  var logIndex = 0
  var code = 0'u32
  var bit = 0x20'u32
  var lastMeasuredCode = BleRfRccalBaselineCode
  var lastMeasuredPower = baseline

  prepareBleRfPriRccalTone()

  for _ in 0 ..< 6:
    let candidate = (code + bit) and BleRfRccalCodeMask
    writeBleRfRccalSearchCode(candidate)
    bleRfDelayUs(1)
    let power = sampleBleRfRccalPower()
    lastMeasuredCode = candidate
    lastMeasuredPower = power
    logBleRfRccalSearch(logIndex, candidate, power)
    if bit == BleRfRccalBaselineCode and
        baseline < BleRfRccalMinReferencePower and
        power > BleRfRccalMinReferencePower:
      target = (uint64(power) * BleRfRccalFallbackTargetNumerator) div
        BleRfRccalFallbackTargetDenominator
      nim_ble_rf_last_rccal_target = saturatingUint32(target)
    if power != 0'u32 and uint64(power) > target:
      code = candidate
    bit = bit shr 1

  var history = 0'u32
  var ok = false
  for _ in 0 ..< 63:
    let candidate = code and BleRfRccalCodeMask
    writeBleRfRccalSearchCode(candidate)
    bleRfDelayUs(1)
    let power = sampleBleRfRccalPower()
    lastMeasuredCode = candidate
    lastMeasuredPower = power
    logBleRfRccalSearch(logIndex, candidate, power)

    history = (history shl 1) and 0x0F'u32
    if power != 0'u32 and uint64(power) > target:
      history = (history + 1'u32) and 0x0F'u32
      if history == 0x05'u32:
        ok = true
        break
      if code < BleRfRccalCodeMask:
        inc code
    else:
      if history == 0x0A'u32:
        ok = true
        break
      if code > 0'u32:
        dec code

  writeBleRfRccalCode(lastMeasuredCode)
  nim_ble_rf_last_rccal_code = lastMeasuredCode
  nim_ble_rf_last_rccal_power = lastMeasuredPower
  (ok, lastMeasuredCode)

proc runBleRfPriRccal() =
  let rf = bleRfRegs()
  if (bleRegLoadPtr(addr rf.capability20) and BleRfRccalCapabilityMask) == 0'u32:
    regClear32(BleRfCalModeReg, BleRfRccalModeMask)
    return

  inc nim_ble_rf_pri_rccal_count
  regWrite(BleRfCalModeReg.uint,
           (regRead(BleRfCalModeReg.uint) and not BleRfRccalModeMask) or
           BleRfRccalStartMode)
  let saved = saveBleRfPriCalState()
  prepareBleRfPriRccal()
  let result = chooseBleRfRccalCode()
  restoreBleRfPriCalState(saved)
  writeBleRfRccalCode(result.code)
  if result.ok:
    regOr(BleRfCalModeReg, BleRfRccalDoneMode)
  else:
    regWrite(BleRfCalModeReg.uint,
             (regRead(BleRfCalModeReg.uint) and not BleRfRccalModeMask) or
             BleRfRccalFailMode)

proc clampBleRfTxcalParam(paramInd: uint32, value: int32): int32 {.inline.} =
  case paramInd
  of 0'u32, 1'u32:
    if value < 0'i32:
      0'i32
    elif value > 63'i32:
      63'i32
    else:
      value
  of 2'u32:
    if value < 0'i32:
      0'i32
    elif value > 2047'i32:
      2047'i32
    else:
      value
  of 3'u32:
    if value < -512'i32:
      -512'i32
    elif value > 511'i32:
      511'i32
    else:
      value
  else:
    0'i32

proc encodeBleRfTxcalParam3(value: int32): uint32 {.inline.} =
  let clamped = clampBleRfTxcalParam(3'u32, value)
  if clamped < 0'i32:
    uint32(clamped + 1024'i32) and BleRfTxcalParam3Mask
  else:
    uint32(clamped) and BleRfTxcalParam3Mask

proc writeBleRfTxcalParam(paramInd: uint32, value: int32) =
  let clamped = clampBleRfTxcalParam(paramInd, value)
  case paramInd
  of 0'u32:
    regUpdate(BleRfTxcalParamReg, BleRfTxcalParam0Mask,
              (uint32(clamped) and 0x3F'u32) shl 24)
  of 1'u32:
    regUpdate(BleRfTxcalParamReg, BleRfTxcalParam1Mask,
              (uint32(clamped) and 0x3F'u32) shl 16)
  of 2'u32:
    regWrite(BleRfTxcalTosdacReg.uint,
             (regRead(BleRfTxcalTosdacReg.uint) and not BleRfTxcalParam2Mask) or
             ((uint32(clamped) and 0x7FF'u32) shl 12) or
             BleRfTxcalParam2EnableBit)
  of 3'u32:
    regWrite(BleRfTxcalTosdacReg.uint,
             (regRead(BleRfTxcalTosdacReg.uint) and not BleRfTxcalParam3Mask) or
             encodeBleRfTxcalParam3(clamped) or BleRfTxcalParam3SignBit)
  else:
    discard

proc waitBleRfTxcalMeasurementReady(): bool =
  for _ in 0 ..< BleRfTxcalWaitLimit:
    if (regRead(BleRfMeasureCtrlReg.uint) and BleRfMeasureReadyMask) != 0'u32:
      return true
    delayUs(1)
  inc nim_ble_rf_txcal_wait_timeout_count
  false

proc clampBleRfTxcalAmp(value: int32): uint32 {.inline.} =
  if value < 0'i32:
    0'u32
  elif value > int32(BleRfTxcalSingenAmplitudeMask):
    BleRfTxcalSingenAmplitudeMask
  else:
    uint32(value)

proc writeBleRfTxcalSingenAmplitude(amp: uint32) =
  let value = amp and BleRfTxcalSingenAmplitudeMask
  regUpdate(BleRfPriRccalSingenReg1, BleRfTxcalSingenAmplitudeMask, value)
  regUpdate(BleRfPriRccalSingenReg2, BleRfTxcalSingenAmplitudeMask, value)
  regClear32(BleRfPriRccalSingenReg0, 0x80000000'u32)
  regOr(BleRfPriRccalSingenReg0, 0x80000000'u32)
  startBleRfPriTxDfeForCal()

proc sampleBleRfTxcalAverage(): tuple[ok: bool, value: int32] =
  regClear32(BleRfMeasureCtrlReg, BleRfMeasureTriggerClearMask)
  regWrite(BleRfMeasureModeReg.uint,
           (regRead(BleRfMeasureModeReg.uint) and BleRfMeasureModeKeepMask) or
           BleRfTxcalAverageMeasureMode)
  regOr(BleRfMeasureCtrlReg, BleRfMeasureStartMask)
  if not waitBleRfTxcalMeasurementReady():
    regClear32(BleRfMeasureCtrlReg, BleRfMeasureTriggerClearMask)
    return (false, 0'i32)

  let sample = signedBleRfAverageMeasurement(regRead(BleRfMeasureIReg.uint))
  regClear32(BleRfMeasureCtrlReg, BleRfMeasureTriggerClearMask)
  (true, sample)

proc tuneBleRfTxcalSingenPower(initialAmp: uint32,
                               adcMeanMax, adcMeanMin: int32): uint32 =
  inc nim_ble_rf_txcal_amp_search_count
  var amp = int32(initialAmp and BleRfTxcalSingenAmplitudeMask)
  var step = amp div 2'i32
  var lastMean = 0'i32
  var tuning = true

  while tuning:
    let clamped = clampBleRfTxcalAmp(amp)
    writeBleRfTxcalSingenAmplitude(clamped)
    bleRfDelayUs(10)
    let sample = sampleBleRfTxcalAverage()
    if sample.ok:
      lastMean = sample.value
    nim_ble_rf_last_txcal_amp = clamped
    nim_ble_rf_last_txcal_amp_mean = cast[uint32](lastMean)

    if sample.ok and lastMean >= adcMeanMin and lastMean <= adcMeanMax:
      return clamped
    if step == 0'i32:
      return clamped

    if not sample.ok or lastMean < adcMeanMin:
      amp = int32(clamped) + step
    else:
      amp = int32(clamped) - step
    step = step div 2'i32
  uint32(amp)

proc writeBleRfTxcalMixerCs(value: uint32) =
  regUpdate(BleRfPriTxcalDcReg, BleRfTxcalMixerCsMask,
            value and BleRfTxcalMixerCsMask)

proc chooseBleRfTxcalMixerCs(): uint32 =
  var best = 0'u32
  var bestPower = low(int32)
  for cs in 0'u32 ..< uint32(BleRfTxcalMixerCsCount):
    writeBleRfTxcalMixerCs(cs)
    let sample = sampleBleRfTxcalAverage()
    let power = if sample.ok: sample.value else: low(int32)
    if int(cs) < nim_ble_rf_txcal_tmxcs_power_log.len:
      nim_ble_rf_txcal_tmxcs_power_log[int(cs)] = cast[uint32](power)
    if power > bestPower:
      bestPower = power
      best = cs

  writeBleRfTxcalMixerCs(best)
  bleRfCalibData.cal[2] =
    (bleRfCalibData.cal[2] and 0xF8FF_FFFF'u32) or
    ((best and BleRfTxcalMixerCsMask) shl 24)
  nim_ble_rf_last_txcal_tmxcs = best
  nim_ble_rf_last_txcal_tmxcs_power = cast[uint32](bestPower)
  best

proc prepareBleRfTxcalSearchStage() =
  regWrite(BleRfPriRccalSingenReg0.uint,
           (regRead(BleRfPriRccalSingenReg0.uint) and 0xFC00_FFFF'u32) or
           0x003D_0000'u32)
  regWrite(BleRfPriRccalSingenReg1.uint,
           regRead(BleRfPriRccalSingenReg1.uint) and 0x003F_FFFF'u32)
  regWrite(BleRfPriRccalSingenReg2.uint,
           (regRead(BleRfPriRccalSingenReg2.uint) and 0x003F_FFFF'u32) or
           0xC000_0000'u32)
  regWrite(BleRfTxcalGain64Reg.uint,
           (regRead(BleRfTxcalGain64Reg.uint) and 0x0FC3_FFFF'u32) or
           0x9030_0000'u32)
  regWrite(BleRfTxcalBiasReg.uint,
           (regRead(BleRfTxcalBiasReg.uint) and 0xFFF8_FFFF'u32) or
           0x0004_0000'u32)
  regWrite(BleRfPriRccalToneReg.uint,
           (regRead(BleRfPriRccalToneReg.uint) and 0xCE0F_FFFF'u32) or
           0x0077_0000'u32)
  regWrite(BleRfCalPathConfigReg.uint,
           (regRead(BleRfCalPathConfigReg.uint) and not 0x0000_0030'u32) or
           0x0000_0010'u32)

proc sampleBleRfTxcalPower(measFreq: uint32): tuple[ok: bool, power: uint32] =
  regWrite(BleRfMeasureCtrlReg.uint,
           (regRead(BleRfMeasureCtrlReg.uint) and 0xFFF00000'u32) or
           ((measFreq and 0x07FF'u32) shl BleRfMeasureFrequencyShift))
  regClear32(BleRfMeasureCtrlReg, BleRfMeasureRccalTriggerMask)
  regOr(BleRfMeasureCtrlReg, BleRfMeasureRccalTriggerMask)
  if not waitBleRfTxcalMeasurementReady():
    regClear32(BleRfMeasureCtrlReg, BleRfMeasureRccalTriggerMask)
    return (false, 0'u32)

  let iSample = signedBleRfPowerMeasurement(regRead(BleRfMeasureIReg.uint))
  let qSample = signedBleRfPowerMeasurement(regRead(BleRfMeasureQReg.uint))
  regClear32(BleRfMeasureCtrlReg, BleRfMeasureRccalTriggerMask)
  (true, saturatingUint32(squareSample(iSample) + squareSample(qSample)))

proc measureBleRfTxcalCandidate(paramInd: uint32, candidate: int32,
                                measFreq: uint32): tuple[ok: bool, power: uint32] =
  writeBleRfTxcalParam(paramInd, candidate)
  bleRfDelayUs(10)
  sampleBleRfTxcalPower(measFreq)

proc searchBleRfTxcalParam(paramInd: uint32, center, delta: int32,
                           measFreq: uint32): tuple[ok: bool, value: int32,
                                                     power: uint32] =
  inc nim_ble_rf_txcal_search_count
  var bestValue = clampBleRfTxcalParam(paramInd, center)
  var bestPower = high(uint32)
  var anyOk = false

  let centerSample = measureBleRfTxcalCandidate(paramInd, bestValue, measFreq)
  if centerSample.ok:
    bestPower = centerSample.power
    anyOk = true

  var step = delta
  while step > 0'i32:
    let leftValue = clampBleRfTxcalParam(paramInd, bestValue - step)
    let leftSample = measureBleRfTxcalCandidate(paramInd, leftValue, measFreq)
    if leftSample.ok:
      if not anyOk or leftSample.power < bestPower:
        bestValue = leftValue
        bestPower = leftSample.power
      anyOk = true

    let rightValue = clampBleRfTxcalParam(paramInd, bestValue + step)
    let rightSample = measureBleRfTxcalCandidate(paramInd, rightValue, measFreq)
    if rightSample.ok:
      if not anyOk or rightSample.power < bestPower:
        bestValue = rightValue
        bestPower = rightSample.power
      anyOk = true

    step = step div 2'i32

  writeBleRfTxcalParam(paramInd, bestValue)
  if anyOk:
    (true, bestValue, bestPower)
  else:
    (false, bestValue, 0'u32)

proc packBleRfTxcalWord0(p0, p1, p2: int32): uint32 {.inline.} =
  (uint32(clampBleRfTxcalParam(0'u32, p0)) and 0x3F'u32) or
    ((uint32(clampBleRfTxcalParam(1'u32, p1)) and 0x3F'u32) shl 6) or
    ((uint32(clampBleRfTxcalParam(2'u32, p2)) and 0x7FF'u32) shl 12)

proc packBleRfTxcalWord1(p3: int32): uint32 {.inline.} =
  encodeBleRfTxcalParam3(p3)

proc storeBleRfTxcalRecord(index: int, p0, p1, p2, p3: int32, power: uint32) =
  let word0 = packBleRfTxcalWord0(p0, p1, p2)
  let word1 = packBleRfTxcalWord1(p3)
  let base = index * 2
  bleRfCalibData.txcal[base] = word0
  bleRfCalibData.txcal[base + 1] = word1
  nim_ble_rf_last_txcal_word0 = word0
  nim_ble_rf_last_txcal_word1 = word1
  if index >= 0 and index < BleRfTxcalSearchRecords:
    nim_ble_rf_txcal_word0_log[index] = word0
    nim_ble_rf_txcal_word1_log[index] = word1
    nim_ble_rf_txcal_power_log[index] = power

proc configureBleRfPriTxcalGain(param: array[5, uint32]) =
  regWrite(BleRfTxcalGain64Reg.uint,
           (regRead(BleRfTxcalGain64Reg.uint) and 0x0FC3FFFF'u32) or
           ((param[0] and 0x0F'u32) shl 28) or
           ((param[2] and 0x0F'u32) shl 18))
  regWrite(BleRfTxcalBiasReg.uint,
           (regRead(BleRfTxcalBiasReg.uint) and 0xFFF8FFFF'u32) or
           ((param[1] and 0x07'u32) shl 16))
  regWrite(BleRfPriRccalToneReg.uint,
           (regRead(BleRfPriRccalToneReg.uint) and 0xCE08FFFF'u32) or
           ((param[4] and 0x0F'u32) shl 20))

proc prepareBleRfPriTxcal() =
  regClear32(BleRfCtrlReg, BleRfCtrlTuneEnableMask)
  regWrite(BleRfSynthCtrlReg.uint, 0'u32)
  regOr(BleRfPriModeCtrlReg, 0x00000002'u32)
  regWrite(BleRfPriModeCtrlReg.uint,
           (regRead(BleRfPriModeCtrlReg.uint) and 0xCEFFF8FF'u32) or
           0xCEFF7800'u32)
  bleRfDelayUs(1)

  regOr(BleRfPriCalDfeGateReg, 0x00040000'u32)
  startBleRfPriTxDfeForCal()
  startBleRfPriRxDfeForCal()
  regOr(BleRfPriCalDfeGateReg, 0x00040000'u32)
  regOr(BleRfCalCtrlReg, 0x00003000'u32)
  regOr(BleRfPriTxcalDfeReg, 0x80000000'u32)
  regOr(BleRfTxcalGain64Reg, 0x00400000'u32)
  regWrite(BleRfPriTxcalDcReg.uint,
           (regRead(BleRfPriTxcalDcReg.uint) and not 0x00000007'u32) or
           0x00000004'u32)

  regWrite(BleRfPriRccalSingenReg0.uint,
           (regRead(BleRfPriRccalSingenReg0.uint) and 0xFC00FFFF'u32) or
           0x00B00000'u32)
  regWrite(BleRfPriRccalSingenReg1.uint,
           regRead(BleRfPriRccalSingenReg1.uint) and 0x003FFFFF'u32)
  regWrite(BleRfPriRccalSingenReg2.uint,
           (regRead(BleRfPriRccalSingenReg2.uint) and 0x003FFFFF'u32) or
           0xC0000000'u32)
  regClear32(BleRfPriRccalSingenReg0, 0x80000000'u32)
  regOr(BleRfPriRccalSingenReg0, 0x80000000'u32)

  regOr(BleRfPriModeCtrlReg, 0x00000003'u32)
  regWrite(BleRfTxcalGain64Reg.uint,
           (regRead(BleRfTxcalGain64Reg.uint) and 0x0FC3FFFF'u32) or
           0x50000000'u32)
  regWrite(BleRfTxcalBiasReg.uint,
           (regRead(BleRfTxcalBiasReg.uint) and 0xFFF8FFFF'u32) or
           0x00040000'u32)
  regWrite(BleRfPriRccalToneReg.uint,
           (regRead(BleRfPriRccalToneReg.uint) and 0xCE08FFFF'u32) or
           0x00870000'u32)
  regWrite(BleRfTxcalGain68Reg.uint,
           (regRead(BleRfTxcalGain68Reg.uint) and 0x1DFFFFFF'u32) or
           0xE0000000'u32)
  regWrite(BleRfMeasureModeReg.uint,
           (regRead(BleRfMeasureModeReg.uint) and BleRfMeasureModeKeepMask) or
           BleRfMeasureRoscalMode)
  discard tuneBleRfTxcalSingenPower(BleRfTxcalInitialAmp,
                                    BleRfTxcalInitialAdcMax,
                                    BleRfTxcalInitialAdcMin)
  discard chooseBleRfTxcalMixerCs()
  prepareBleRfTxcalSearchStage()

proc runBleRfPriTxcal() =
  inc nim_ble_rf_pri_txcal_count
  regWrite(BleRfCalModeReg.uint,
           (regRead(BleRfCalModeReg.uint) and not BleRfTxcalModeMask) or
           BleRfTxcalStartMode)
  let saved = saveBleRfPriCalState()
  prepareBleRfPriTxcal()

  var allOk = true
  for i in 0 ..< BleRfTxcalSearchRecords:
    configureBleRfPriTxcalGain(BleRfPriTxcalParams[i])
    let amp = tuneBleRfTxcalSingenPower(BleRfTxcalGainAmp,
                                        BleRfTxcalGainAdcMax,
                                        BleRfTxcalGainAdcMin)
    if i >= 0 and i < nim_ble_rf_txcal_amp_log.len:
      nim_ble_rf_txcal_amp_log[i] = amp

    let p0a = searchBleRfTxcalParam(0'u32, 0x20'i32, 0x10'i32, 0x3D'u32)
    let p1a = searchBleRfTxcalParam(1'u32, 0x20'i32, 0x10'i32, 0x3D'u32)
    let p0b = searchBleRfTxcalParam(0'u32, p0a.value, 0x08'i32, 0x3D'u32)
    let p1b = searchBleRfTxcalParam(1'u32, p1a.value, 0x08'i32, 0x3D'u32)
    let p2a = searchBleRfTxcalParam(2'u32, 0x400'i32, 0x80'i32, 0x7A'u32)
    let p3a = searchBleRfTxcalParam(3'u32, 0'i32, 0x40'i32, 0x7A'u32)
    let p2b = searchBleRfTxcalParam(2'u32, p2a.value, 0x40'i32, 0x7A'u32)
    let p3b = searchBleRfTxcalParam(3'u32, p3a.value, 0x20'i32, 0x7A'u32)

    allOk = allOk and p0a.ok and p1a.ok and p0b.ok and p1b.ok and
      p2a.ok and p3a.ok and p2b.ok and p3b.ok
    storeBleRfTxcalRecord(i, p0b.value, p1b.value, p2b.value, p3b.value,
                          p0b.power or p1b.power or p2b.power or p3b.power)

  restoreBleRfPriCalState(saved)
  if allOk:
    regWrite(BleRfCalModeReg.uint,
             (regRead(BleRfCalModeReg.uint) and not BleRfTxcalModeMask) or
             BleRfTxcalDoneMode)

proc applyBleRfTxcalRecordToTable(words: var array[43, uint32],
                                  start, record: int) =
  let word0 = bleRfCalibData.txcal[record * 2]
  let word1 = bleRfCalibData.txcal[record * 2 + 1]
  let p0 = word0 and 0x3F'u32
  let p1 = (word0 shr 6) and 0x3F'u32
  let p2 = (word0 shr 12) and 0x7FF'u32
  let p3 = word1 and 0x3FF'u32
  let index = start + record * 2

  words[index] = (words[index] and 0xFFFFF800'u32) or p2
  words[index + 1] = (words[index + 1] and 0xFF000003'u32) or
    (p3 shl 14) or (p0 shl 8) or (p1 shl 2)

proc applyBleRfVcoTableFromCal() =
  let rf = bleRfRegs()
  for i in 0 ..< BleRfLoChannelCount:
    let pairIndex = i div 2
    var word = volatileLoad(addr rf.vcoPairTable13c[pairIndex])
    let fcal = uint32(rfLoFcal(bleRfCalibData.lo[i])) and 0xFF'u32
    let acal = uint32(rfLoAcal(bleRfCalibData.lo[i])) and 0x1F'u32
    if (i and 1) == 0:
      word = (word and 0xFFFF00E0'u32) or (fcal shl 8) or acal
    else:
      word = (word and 0x00E0FFFF'u32) or (fcal shl 24) or (acal shl 16)
    volatileStore(addr rf.vcoPairTable13c[pairIndex], word)
  inc nim_ble_rf_pri_vco_table_count
  nim_ble_rf_last_vco_113c = volatileLoad(addr rf.vcoPairTable13c[0])
  nim_ble_rf_last_vco_1164 = volatileLoad(addr rf.vcoPair2484Mhz164)

proc runBleRfPriLoCalibration() =
  resetBleRfCalibData()
  regWrite(BleRfRxModeReg.uint, regRead(BleRfRxModeReg.uint) and 0xFFFFE67D'u32)
  regWrite(BleRfRxModeReg.uint, regRead(BleRfRxModeReg.uint) and 0xFFFFFF9E'u32)
  runBleRfPriLoFcal()
  runBleRfPriLoAcal()
  regWrite(BleRfRxModeReg.uint, regRead(BleRfRxModeReg.uint) and 0xFFFFE67D'u32)
  regWrite(BleRfRxModeReg.uint, regRead(BleRfRxModeReg.uint) and 0xFFFFFF9E'u32)

proc applyBleRfPriStaticInit() =
  ## Translate the non-calibration BL606P rf_pri_init register phase used by
  ## the passing vendor BLE reference. Dynamic search/calibration remains a
  ## separate RF HAL task; this keeps the fixed RF defaults synchronized.
  writeBleRegMaskInit(BleRfPriStaticInit)
  inc nim_ble_rf_pri_static_count
  nim_ble_rf_last_pri_init_64 = regRead(BleRfTxcalGain64Reg.uint)
  nim_ble_rf_last_pri_init_d4 = regRead(BleRfBiasTrimD4Reg.uint)

proc applyBleRfPriGainInit() =
  ## Mirror the vendor rf_pri_gain_table_WR2REG follow-up register phase.
  writeBleRegMaskInit(BleRfPriGainInit)
  inc nim_ble_rf_pri_gain_count

proc applyBleRfPriTxPowerTableInit() =
  ## Mirror the BL606P rf_pri_pwr_table_w2reg/rf_pri_txcal_w2reg register
  ## phase. The fixed gain-table fields come from the reference table layout;
  ## per-board TX DC calibration fields are filled from the live TXCAL search.
  var words = BleRfPriTxPowerRegisterBase
  for i in 0 ..< BleRfTxcalSearchRecords:
    applyBleRfTxcalRecordToTable(words, 2, i)
    applyBleRfTxcalRecordToTable(words, 25, i)
  writeBleMemoryWords(0x20001700'u32, words)
  inc nim_ble_rf_pri_tx_power_table_count

proc restoreBleRfIdle1MState(channelMhz: uint16) =
  ## Return the RF state machine to the BLE 1M idle/channel state expected by
  ## the BTBLE scheduler after scan/initiator activity has retuned the radio.
  regClear32(BleRfRxModeReg, BleRfRxModeIdleClearMask)
  regClear32(BleRfRetuneReg, BleRfRetuneHoldMask)
  regOr(BleRfCtrlReg, BleRfCtrlIdleEnableMask)
  regClear32(BleRfSynthCtrlReg, BleRfSynthIdleClearMask)
  regUpdate(BleRfChannelReg, BleRfChannelMask, uint32(channelMhz))
  regWrite(BleRfModeReg.uint,
           (regRead(BleRfModeReg.uint) and not BleRfModeLowBitsMask) or
           BleRfIdle1MMode)

proc loadBlePhyMemories() =
  ## Program the BL606P-compatible PHY data memories used by BLE 1M RX.
  inc nim_ble_phy_mem_load_count
  let phyMem = blePhyMemoryRegs()
  bleRegOrPtr(addr phyMem.agcLoad, BlePhyAgcLoadEnableMask)
  bleRegOrPtr(addr phyMem.agcMemGate, BlePhyAgcMemGateMask)
  clearBleMemoryWords(blerfdata.BleAgcMemBase, blerfdata.BleAgcMemWords)
  writeBleMemoryWords(blerfdata.BleAgcMemBase, blerfdata.BleAgcMemPrefix)
  regWrite((blerfdata.BleAgcMemBase +
            uint32(blerfdata.BleAgcMemLastWordOffset) * 4'u32).uint,
           blerfdata.BleAgcMemLastWord)
  bleRegClearPtr(addr phyMem.agcMemGate, BlePhyAgcMemGateMask)
  bleRegClearPtr(addr phyMem.agcLoad, BlePhyAgcLoadEnableMask)

  bleRegUpdatePtr(addr phyMem.ldpcMode, BlePhyLdpcLoadModeMask,
                  BlePhyLdpcLoadMode)
  bleRegStorePtr(addr phyMem.ldpcLoadAddress, 0'u32)
  bleRegStorePtr(addr phyMem.ldpcLoadLength, 0'u32)
  bleRegStorePtr(addr phyMem.ldpcLoadControl, 0'u32)
  bleRegClearPtr(addr phyMem.memMode, BlePhyLdpcMemSelectMask)
  writeBleMemoryWords(blerfdata.BleLdpcMemBase, blerfdata.BleLdpcMem,
                      BleLdpcInitWords)

proc bleRfChannelMhz(channel: uint16): uint16 {.inline.} =
  ## Accept either BLE channel numbers or an already-expanded MHz value.
  if channel >= 2400'u16 and channel <= 2500'u16:
    channel
  elif channel == 37'u16:
    2402'u16
  elif channel == 38'u16:
    2426'u16
  elif channel == 39'u16:
    2480'u16
  elif channel <= 10'u16:
    2404'u16 + channel * 2'u16
  elif channel < 37'u16:
    2406'u16 + channel * 2'u16
  else:
    BleRfDefaultChannelMhz

proc applyBleRfChannelOptimize(channelMhz: uint16) =
  ## Mirror the BL808 rf_pri_optimize default path for BL616/40 MHz boards.
  ## The vendor routine clears this RF bit only for the 2452-2472 MHz band and
  ## sets it outside that range; CoreBluetooth commonly opens links on those
  ## mid-band data channels.
  var word = regRead(BleRfOptimizeReg.uint)
  if channelMhz >= BleRfOptimizeMidBandFirstMhz and
      channelMhz <= BleRfOptimizeMidBandLastMhz:
    word = word and not BleRfOptimizeMidBandMask
  else:
    word = word or BleRfOptimizeMidBandMask
  regWrite(BleRfOptimizeReg.uint, word)
  inc nim_ble_rf_optimize_count
  nim_ble_rf_last_optimize_word = word

proc bleRfLegacyScanChannelMhz(channelIndex: uint16): uint16 {.inline.} =
  ## Scanner EM uses RF indexes for the legacy advertising channels.
  case channelIndex
  of 0'u16: 2402'u16
  of 12'u16: 2426'u16
  of 39'u16: 2480'u16
  else: bleRfChannelMhz(channelIndex)

proc configureBleRfChannelMhz(channelMhz: uint16) =
  ## Pure Nim translation of the non-floating rfc_config_channel path.
  ##
  ## BL808 rf_pri_update_param and rf_pri_get_notch_param are no-ops in the RF
  ## archive used here, but rf_pri_optimize has one relevant default-path
  ## channel-range write. Keep that translated in pure Nim below.
  when defined(bl808m0):
    if nim_ble_wlcoex_enabled != 0'u32 and
        nim_ble_wifi_tx_window_active != 0'u32:
      inc nim_ble_wifi_tx_window_defer_count
      return
  regOr(BleRfRetuneReg, BleRfRetuneHoldMask)
  regOr(BleRfSynthCtrlReg, BleRfSynthChannelPrepareMask)
  regOr(BleRfSynthCtrlReg, BleRfSynthChannelLatchMask)
  regOr(BleRfSynthCtrlReg, BleRfSynthChannelRequestMask)

  regUpdate(BleRfChannelReg, BleRfChannelMask, uint32(channelMhz))

  regOr(BleRfTuneReg, BleRfTuneStrobeMask)
  bleRfDelayUs(1)
  regClear32(BleRfTuneReg, BleRfTuneStrobeMask)
  bleRfDelayUs(1)

  regOr(BleRfCtrlReg, BleRfCtrlTuneEnableMask)
  bleRfDelayUs(1)

  regUpdate(BleRfModeReg, BleRfModeStateMask, BleRfModeTuneStartState)
  bleRfDelayUs(1)
  regOr(BleRfModeReg, BleRfModeTuneBusyMask)
  bleRfDelayUs(1)
  regUpdate(BleRfModeReg, BleRfModeStateMask, BleRfModeIdleState)
  bleRfDelayUs(100)
  regClear32(BleRfModeReg, BleRfModeTuneBusyMask)
  bleRfDelayUs(1)

  regClear32(BleRfRetuneReg, BleRfRetuneHoldMask)

  let notchWord = (regRead(BleRfNotchReg.uint) and 0x0000FFFF'u32) or
    BleRfNotchDisabledWord
  regWrite(BleRfNotchReg.uint, notchWord)
  applyBleRfChannelOptimize(channelMhz)
  inc nim_ble_rf_tune_count
  nim_ble_rf_last_channel_mhz = channelMhz.uint32
  nim_ble_rf_last_notch_word = notchWord
  markBleRfDirtyForWifi()
  settleBleRfCalibrationLatches()
  when defined(bl808m0):
    nimDisableM0RfClicIrq()

proc configureBlePhy1M() =
  ## Bring up the 1M PHY/AGC register plane used by BL606P-compatible RF.
  inc nim_ble_phy_init_count
  regWrite(0x24C00888'u32.uint, 0x00001111'u32)
  bleRfDelayUs(1)
  regWrite(0x24C00888'u32.uint, 0x00000000'u32)
  writeBleRegInit(BlePhyAgcInit)
  loadBlePhyMemories()

proc configureBleRf1M() =
  ## Configure the BL606P-compatible BLE 1M RF path used by the BL808 BTBLE
  ## controller firmware. The steady-state register values are the pure Nim
  ## equivalent of the vendor RF bring-up state that advertises successfully on
  ## the BL808 board.
  inc nim_ble_rf_init_count
  configureBlePhy1M()
  applyBleRfPriStaticInit()
  writeBleRegInit(BleRf1MInit)
  runBleRfPriLoCalibration()
  runBleRfPriRoscal()
  runBleRfPriRccal()
  runBleRfPriTxcal()
  applyBleRfPriGainInit()
  applyBleRfPriTxPowerTableInit()
  applyBleRfVcoTableFromCal()
  restoreBleRfIdle1MState(BleRfDefaultChannelMhz)
  regWrite(BleRfTxPowerReg.uint, BleRfPower4DbmTxCal)
  settleBleRfCalibrationLatches()
  nim_ble_rf_last_channel_mhz = BleRfDefaultChannelMhz.uint32
  nim_ble_rf_last_notch_word = regRead(BleRfNotchReg.uint)
  nim_ble_rf_last_init_a0 = regRead(0x200010A0'u32.uint)
  nim_ble_rf_last_init_b0 = regRead(0x200010B0'u32.uint)
  nim_ble_rf_last_init_b4 = regRead(0x200010B4'u32.uint)
  nim_ble_rf_last_init_c8 = regRead(0x200010C8'u32.uint)
  markBleRfDirtyForWifi()
  bleRf1MConfigured = true
  when defined(bl808m0):
    nimDisableM0RfClicIrq()

proc ensureBleRf1MConfigured() =
  ## Role starts mirror the reference stack by requiring RF bring-up to have
  ## completed, without rerunning full calibration on scan/init/connection paths.
  if not bleRf1MConfigured:
    configureBleRf1M()

when defined(bl808m0):
  proc bleNimReclaimRfForBle*() {.exportc, cdecl.} =
    ## Reclaim the shared WiFi/BLE RF path after WiFi firmware activity.
    prepareWirelessDomain()
    configureBtPriorityPta()
    configureBleRf1M()

