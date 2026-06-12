from std/volatile import volatileLoad, volatileStore

const bl808BleNimSchProg* {.booldefine.}: bool = false
const bl808BleNimSchProgDeferred* {.booldefine.}: bool = false
const bl808BleNimLlcStart* {.booldefine.}: bool = false
const bl808BleNimPureConnection* {.booldefine.}: bool = false
const bl808BleNimPureCentral* {.booldefine.}: bool = false
const bl808BleNimCentralChSel2* {.booldefine.}: bool = false
const bl808BleNimPeripheralChSel2* {.booldefine.}: bool = true
const bl808BleNimManualConnTx* {.booldefine.}: bool = false
const bl808BleNimUseClicIrq* {.booldefine.}: bool = false
const bl808BleConnStageDiag* {.booldefine.}: bool = false
const bl808BleSkipConnEmWake* {.booldefine.}: bool = false
const bl808BleNimConnectionEnabled =
  bl808BleNimPureConnection
const bl808BleNimSchProgEnabled =
  bl808BleNimSchProg and (bl808BleNimConnectionEnabled or bl808BleNimPureCentral)
const bl808BleNimRuntimeClicIrq =
  bl808BleNimUseClicIrq or bl808BleNimPureCentral
const
  NimBleFeatureExtendedReject = 1'u64 shl 2
  NimBleFeatureLePing = 1'u64 shl 4
  NimBleFeatureDataPacketLengthExtension = 1'u64 shl 5
  NimBleFeatureLe2MPhy = 1'u64 shl 8
  NimBleFeatureLeCodedPhy = 1'u64 shl 11
  NimBleFeatureChannelSelectionAlgorithm2 = 1'u64 shl 14
  NimBleExperimentalLeFeatures =
    when bl808BleNimPeripheralChSel2:
      NimBleFeatureChannelSelectionAlgorithm2
    else:
      0'u64
  NimBleLegacyAdvChSelBit =
    when bl808BleNimPeripheralChSel2:
      0x0020'u16
    else:
      0'u16
  NimBleLe1MPhy = 0x01'u8
  NimBleLeMinDataOctets = 0x001B'u16
  NimBleLeMinDataTime = 0x0148'u16
  NimBleLeSpecMaxDataOctets = 0x00FB'u16
  NimBleLeSpecMaxDataTime = 0x0848'u16
  NimBleLeMaxDataOctets = 0x001B'u16
  NimBleLeMaxDataTime = 0x0148'u16
  NimBlePostLldInitSettleUs = 1000'u32
  NimBlePostHciResetSettleUs = 5000'u32
  # Keep the advertised LE feature set aligned with the pure Nim LLCP support.
  # The controller currently supports the legacy 27-octet data PDU size and
  # extended reject responses.  Do not advertise LE Ping until the encryption
  # procedure exists, and do not advertise Data
  # Length Extension until larger ACL/EM buffers and the LL length-update
  # procedure are implemented end to end.  Likewise, do not participate in PHY
  # update procedures until the connection scheduler supports alternate PHYs.
  # Drive the LE CSA#2 feature bit and the legacy advertising ChSel bit from
  # the same build flag so the over-the-air promise always matches the selected
  # channel-selection algorithm.  The pure Nim peripheral scheduler handles the
  # CONNECT_IND ChSel field and falls back to mandatory CSA#1 when the bit is
  # absent.
  NimBleConservativeLeFeatures =
    NimBleFeatureExtendedReject or NimBleExperimentalLeFeatures

proc nimBleFeatureByte(features: uint64, index: int): uint8 {.inline.} =
  uint8((features shr (index * 8)) and 0xFF'u64)

proc nimBleLocalFeatureSupported(feature: uint64): bool {.inline.} =
  (NimBleConservativeLeFeatures and feature) != 0'u64

proc nimBlePhyUpdateSupported(): bool {.inline.} =
  nimBleLocalFeatureSupported(NimBleFeatureLe2MPhy) or
    nimBleLocalFeatureSupported(NimBleFeatureLeCodedPhy)

proc minU16(a, b: uint16): uint16 {.inline.} =
  if a < b: a else: b

proc clampBleDataOctets(value: uint16): uint16 {.inline.} =
  if value < NimBleLeMinDataOctets:
    NimBleLeMinDataOctets
  elif value > NimBleLeSpecMaxDataOctets:
    NimBleLeSpecMaxDataOctets
  else:
    value

proc clampBleDataTime(value: uint16): uint16 {.inline.} =
  if value < NimBleLeMinDataTime:
    NimBleLeMinDataTime
  elif value > NimBleLeSpecMaxDataTime:
    NimBleLeSpecMaxDataTime
  else:
    value

var nim_ble_platform_init_stage* {.exportc.}: uint32
var nim_ble_core_init_return_count* {.exportc.}: uint32
var nim_ble_lld_init_return_count* {.exportc.}: uint32
var nim_ble_bflbble_init_return_count* {.exportc.}: uint32
var nim_ble_wireless_prepare_count* {.exportc.}: uint32
var nim_ble_wireless_preserve_wifi_count* {.exportc.}: uint32
var nim_ble_wireless_reset_count* {.exportc.}: uint32
var nim_ble_wireless_last_wifi_state* {.exportc.}: uint32
var nim_ble_wlcoex_enabled* {.exportc.}: uint32
var nim_ble_wifi_tx_window_active* {.exportc.}: uint32
var nim_ble_wifi_tx_window_enter_count* {.exportc.}: uint32
var nim_ble_wifi_tx_window_leave_count* {.exportc.}: uint32
var nim_ble_wifi_tx_window_skip_count* {.exportc.}: uint32
var nim_ble_wifi_tx_window_defer_count* {.exportc.}: uint32
var nim_ble_wifi_tx_window_resume_count* {.exportc.}: uint32
var nim_ble_wifi_tx_window_last_intmask* {.exportc.}: uint32
var nim_ble_wifi_tx_window_last_intstat* {.exportc.}: uint32
var nim_ble_hci_reset_settle_pending* {.exportc.}: uint32
var nim_ble_hci_reset_settle_yield_count* {.exportc.}: uint32
var nim_ble_hci_reset_settle_deadline_lo* {.exportc.}: uint32
var bleHciResetSettleDeadline: uint64

when defined(BleDebugCounters):
  var nim_ble_p256_stage* {.exportc.}: uint32
  var nim_ble_p256_result* {.exportc.}: uint32

  proc bleP256Mark(stage: uint32) {.inline.} =
    volatileStore(addr nim_ble_p256_stage, stage)

  proc bleP256Result(value: uint32) {.inline.} =
    volatileStore(addr nim_ble_p256_result, value)
else:
  proc bleP256Mark(stage: uint32) {.inline.} =
    discard stage

  proc bleP256Result(value: uint32) {.inline.} =
    discard value

proc bleVolatileCounterInc(counter: ptr uint32) {.inline.} =
  volatileStore(counter, volatileLoad(counter) + 1'u32)

proc blePlatformInitMark(stage: uint32) {.inline.} =
  volatileStore(addr nim_ble_platform_init_stage, stage)

proc bleSettleAfterLldInit() {.inline.} =
  ## The BTBLE/LLD reset sequence writes clocked RF and EM state. Give that
  ## domain one short hardware settle point before the manager/ECC layers start
  ## allocating messages and touching controller state.
  delayUs(NimBlePostLldInitSettleUs)

proc bleArmHciResetSettle() {.inline.} =
  ## HCI Reset rewrites clocked BTBLE/EM control state. The vendor controller
  ## reaches command-complete through its task scheduler; keep the pure Nim path
  ## from accepting the next controller work in the same hardware instant.
  bleHciResetSettleDeadline =
    clicReadMtime() + NimBlePostHciResetSettleUs.uint64
  nim_ble_hci_reset_settle_pending = 1
  nim_ble_hci_reset_settle_deadline_lo = bleHciResetSettleDeadline.uint32

proc bleHciResetSettlePending(): bool {.inline.} =
  if nim_ble_hci_reset_settle_pending == 0'u32:
    return false
  if clicReadMtime() < bleHciResetSettleDeadline:
    return true
  nim_ble_hci_reset_settle_pending = 0
  false

when defined(bl808BleConnectTrace) or defined(bl808BlePrintNimLlcMsg):
  proc bleTraceByte(ch: uint8) =
    const
      Uart0Base = 0x2000A000'u
      UartFifoConfig1 = 0x84'u
      UartFifoWdata = 0x88'u
      FifoTxFreeMask = 0x3F'u32
    var timeout = 10_000'u32
    while (regRead(Uart0Base + UartFifoConfig1) and FifoTxFreeMask) == 0'u32:
      dec timeout
      if timeout == 0:
        return
    regWrite(Uart0Base + UartFifoWdata, ch.uint32)

  proc bleTrace(s: static[string]) =
    for ch in s:
      bleTraceByte(ch.uint8)

  proc bleTraceHexNibble(value: uint8) =
    let hexNibble = value and 0x0F'u8
    bleTraceByte(if hexNibble < 10'u8: uint8(ord('0')) + hexNibble
                 else: uint8(ord('A')) + hexNibble - 10'u8)

  proc bleTraceHex32(value: uint32) =
    bleTrace("0x")
    for shift in countdown(28, 0, 4):
      bleTraceHexNibble(uint8((value shr shift) and 0x0F'u32))

when defined(bl808m0) and
    bl808BleNimSchProgEnabled:
  var nimSchProgSkipIndex {.exportc: "m_sw_skip_et_idx".}: uint32

when defined(bl808m0):
  when not bl808BleNimSchProg:
    {.error: "M0 BLE requires the pure Nim scheduler program path".}

when defined(bl808m0) and
    (bl808BleNimConnectionEnabled or bl808BleNimPureCentral):
  type
    BtbleRfTableView {.packed.} = object
      reset*: pointer
      forceAgcEnable*: pointer
      unsupportedCallbackSlot08*: pointer
      unsupportedCallbackSlot0c*: pointer
      txpwrMaxSet*: pointer
      txpwrMaxGet*: pointer
      unsupportedCallbackSlot18*: pointer
      txpwrDbmGet*: pointer
      txpwrCsGet*: pointer
      rssiConvert*: pointer
      unsupportedCallbackSlot28*: pointer
      regRead*: pointer
      regWrite*: pointer
      sleep*: pointer
      emConfigFlags*: uint16
      emConfigPadding3a*: array[3, uint8]
      rssiFloorDbm*: int8
      calibrationSignature*: uint16

    BleMacPhyRegs {.packed.} = object
      macPhyBaseToSleepCtrlPadding*: array[0x30, uint8]
      sleepCtrl*: uint32
      sleepCtrlToRfResetTimingPadding*: array[0x84C, uint8]
      rfResetTiming0*: uint32
      rfResetTiming1*: uint32
      rfResetTiming2*: uint32
      rfResetTiming3*: uint32
      rfResetGainWindow0*: uint32
      rfResetGainWindow1*: uint32
      rfResetGainWindow2*: uint32
      rfResetGainWindow3*: uint32
      rfResetGainToPacketSettlePadding*: array[0xE0, uint8]
      rfPacketSettleTiming0*: uint32
      rfPacketSettleTiming1*: uint32
      rfPacketSettleTiming2*: uint32
      rfPacketSettleTiming3*: uint32
      packetSettleToAnalogTrimPadding*: array[0x30, uint8]
      analogTrimControl*: uint32

    BlePhyCtrlRegs {.packed.} = object
      phyCtrlBaseToRfResetInitPadding*: array[0x08, uint8]
      rfResetInitControl*: uint32
      rfResetInitToTuningPadding*: array[0x80, uint8]
      rfResetTuningControl*: uint32

    BlePhyAgcRegs {.packed.} = object
      agcBaseToResetConfigPadding*: array[0x84, uint8]
      resetAgcConfig*: uint32

  const
    BtbleRfEmConfigFlags = 0x2000'u16
    BtbleRfRssiFloorDbm = -40'i8
    BtbleRfCalibrationSignature = 0xBAC4'u16

  static:
    doAssert offsetof(BtbleRfTableView, unsupportedCallbackSlot08) == 0x08
    doAssert offsetof(BtbleRfTableView, unsupportedCallbackSlot0c) == 0x0C
    doAssert offsetof(BtbleRfTableView, txpwrMaxSet) == 0x10
    doAssert offsetof(BtbleRfTableView, txpwrMaxGet) == 0x14
    doAssert offsetof(BtbleRfTableView, unsupportedCallbackSlot18) == 0x18
    doAssert offsetof(BtbleRfTableView, txpwrDbmGet) == 0x1C
    doAssert offsetof(BtbleRfTableView, txpwrCsGet) == 0x20
    doAssert offsetof(BtbleRfTableView, rssiConvert) == 0x24
    doAssert offsetof(BtbleRfTableView, unsupportedCallbackSlot28) == 0x28
    doAssert offsetof(BtbleRfTableView, regRead) == 0x2C
    doAssert offsetof(BtbleRfTableView, regWrite) == 0x30
    doAssert offsetof(BtbleRfTableView, sleep) == 0x34
    doAssert offsetof(BtbleRfTableView, emConfigFlags) == 0x38
    doAssert offsetof(BtbleRfTableView, emConfigPadding3a) == 0x3A
    doAssert offsetof(BtbleRfTableView, rssiFloorDbm) == 0x3D
    doAssert offsetof(BtbleRfTableView, calibrationSignature) == 0x3E
    doAssert offsetof(BleMacPhyRegs, macPhyBaseToSleepCtrlPadding) == 0x00
    doAssert offsetof(BleMacPhyRegs, sleepCtrl) == 0x30
    doAssert offsetof(BleMacPhyRegs, sleepCtrlToRfResetTimingPadding) == 0x34
    doAssert offsetof(BleMacPhyRegs, rfResetTiming0) == 0x880
    doAssert offsetof(BleMacPhyRegs, rfResetGainWindow3) == 0x89C
    doAssert offsetof(BleMacPhyRegs, rfResetGainToPacketSettlePadding) == 0x8A0
    doAssert offsetof(BleMacPhyRegs, rfPacketSettleTiming0) == 0x980
    doAssert offsetof(BleMacPhyRegs, rfPacketSettleTiming3) == 0x98C
    doAssert offsetof(BleMacPhyRegs, packetSettleToAnalogTrimPadding) == 0x990
    doAssert offsetof(BleMacPhyRegs, analogTrimControl) == 0x9C0
    doAssert offsetof(BlePhyCtrlRegs, phyCtrlBaseToRfResetInitPadding) == 0x00
    doAssert offsetof(BlePhyCtrlRegs, rfResetInitControl) == 0x08
    doAssert offsetof(BlePhyCtrlRegs, rfResetInitToTuningPadding) == 0x0C
    doAssert offsetof(BlePhyCtrlRegs, rfResetTuningControl) == 0x8C
    doAssert offsetof(BlePhyAgcRegs, agcBaseToResetConfigPadding) == 0x00
    doAssert offsetof(BlePhyAgcRegs, resetAgcConfig) == 0x84

  var g_ble_max_txpower_dbm: int8

  template bleMacPhyRegs(): ptr BleMacPhyRegs =
    cast[ptr BleMacPhyRegs](0x28000000'u)

  template blePhyCtrlRegs(): ptr BlePhyCtrlRegs =
    cast[ptr BlePhyCtrlRegs](0x20002800'u)

  template blePhyAgcRegs(): ptr BlePhyAgcRegs =
    cast[ptr BlePhyAgcRegs](0x20002C00'u)

  proc regLoad(reg: ptr uint32): uint32 {.inline.} =
    regRead(cast[uint](reg))

  proc regStore(reg: ptr uint32, value: uint32) {.inline.} =
    regWrite(cast[uint](reg), value)

  proc regUpdateField(reg: ptr uint32, clearMask, setMask: uint32) {.inline.} =
    regStore(reg, (regLoad(reg) and clearMask) or setMask)

  proc nimBleRfTxpowerMaxSet(dbm: int8) {.cdecl.} =
    g_ble_max_txpower_dbm = dbm

  proc nimBleRfTxpowerMaxGet(): int8 {.cdecl.} =
    g_ble_max_txpower_dbm

  proc nimRfTxpwrDbmGet(cs: uint8, high: uint8): int8 {.cdecl.} =
    discard high
    let dbm = int8(cs shr 2)
    if g_ble_max_txpower_dbm > 0'i8 and dbm > g_ble_max_txpower_dbm:
      g_ble_max_txpower_dbm
    else:
      dbm

  proc nimRfTxpwrCsGet(dbm: int8, high: uint8): uint8 {.cdecl.} =
    discard high
    if dbm <= 0 or g_ble_max_txpower_dbm <= 0:
      return 0
    var limited = dbm
    if limited > g_ble_max_txpower_dbm:
      limited = g_ble_max_txpower_dbm
    uint8((int32(limited) shl 2) and 0xFC)

  proc nimRfRssiConvert(raw: uint8): int8 {.cdecl.} =
    int8(2'i32 - int32(raw))

  proc nimRfRegRead(regAddr: uint32): uint32 {.cdecl.} =
    discard regAddr
    0

  proc nimRfRegWrite(regAddr, value: uint32) {.cdecl.} =
    discard regAddr
    discard value

  proc nimRfSleep() {.cdecl.} =
    regStore(addr bleMacPhyRegs().sleepCtrl,
             regLoad(addr bleMacPhyRegs().sleepCtrl) or 7'u32)

  proc nimRfReset() {.cdecl.} =
    let mac = bleMacPhyRegs()
    let phy = blePhyCtrlRegs()
    let agc = blePhyAgcRegs()
    regStore(addr mac.rfResetTiming0, 0x00500350'u32)
    regStore(addr mac.rfResetTiming1, 0x00500350'u32)
    regStore(addr mac.rfResetTiming2, 0x00500350'u32)
    regStore(addr mac.rfResetTiming3, 0x00000350'u32)
    regStore(addr mac.rfResetGainWindow0, 0x04000703'u32)
    regStore(addr mac.rfResetGainWindow1, 0x00000502'u32)
    regStore(addr mac.rfResetGainWindow2, 0x08000703'u32)
    regStore(addr mac.rfResetGainWindow3, 0x08000003'u32)
    regUpdateField(addr mac.rfResetGainWindow0, 0xFF80FFFF'u32, 0x00280000'u32)
    regUpdateField(addr mac.rfResetGainWindow1, 0xFF80FFFF'u32, 0x001E0000'u32)
    regUpdateField(addr mac.rfResetGainWindow2, 0xFF00FFFF'u32, 0x00870000'u32)
    regUpdateField(addr mac.rfResetGainWindow3, 0xFF80FFFF'u32, 0x00280000'u32)
    regStore(addr mac.analogTrimControl,
             regLoad(addr mac.analogTrimControl) or 0x00004000'u32)
    regStore(addr agc.resetAgcConfig, 0x1208102B'u32)
    regUpdateField(addr phy.rfResetTuningControl, 0xFF803FFF'u32,
                   0x00014000'u32)
    regStore(addr phy.rfResetInitControl, 0x0842001A'u32)
    regStore(addr mac.rfPacketSettleTiming0, 0x02120013'u32)
    regStore(addr mac.rfPacketSettleTiming1, 0x02120013'u32)
    regStore(addr mac.rfPacketSettleTiming2, 0x02120013'u32)
    regStore(addr mac.rfPacketSettleTiming3, 0x02120013'u32)

  proc nimRfForceAgcEnable() {.cdecl.} =
    discard

  proc btble_rf_init*(rf: pointer) {.exportc, cdecl.} =
    if rf == nil:
      return
    let table = cast[ptr BtbleRfTableView](rf)
    table.reset = cast[pointer](nimRfReset)
    table.forceAgcEnable = cast[pointer](nimRfForceAgcEnable)
    table.unsupportedCallbackSlot08 = nil
    table.unsupportedCallbackSlot0c = nil
    table.txpwrMaxSet = cast[pointer](nimBleRfTxpowerMaxSet)
    table.txpwrMaxGet = cast[pointer](nimBleRfTxpowerMaxGet)
    table.unsupportedCallbackSlot18 = nil
    table.txpwrDbmGet = cast[pointer](nimRfTxpwrDbmGet)
    table.txpwrCsGet = cast[pointer](nimRfTxpwrCsGet)
    table.rssiConvert = cast[pointer](nimRfRssiConvert)
    table.unsupportedCallbackSlot28 = nil
    table.regRead = cast[pointer](nimRfRegRead)
    table.regWrite = cast[pointer](nimRfRegWrite)
    table.sleep = cast[pointer](nimRfSleep)
    table.emConfigFlags = BtbleRfEmConfigFlags
    table.emConfigPadding3a = [0'u8, 0, 0]
    table.rssiFloorDbm = BtbleRfRssiFloorDbm
    table.calibrationSignature = BtbleRfCalibrationSignature
    g_ble_max_txpower_dbm = 15'i8

when defined(bl808m0) and bl808BleNimConnectionEnabled:
  when not bl808BleNimPureConnection:
    {.error: "M0 BLE connections require the pure Nim connection path".}
  proc nimLldConStart(conhdl: uint16, params: pointer): uint8 {.cdecl.}
  when bl808BleNimManualConnTx:
    proc nimLldConDataTx(conhdl: uint16, buf: pointer): uint8 {.cdecl.}
    proc nimLldConLlcpTx(conhdl: uint16, buf: pointer): uint8 {.cdecl.}
    proc lld_con_data_tx*(conhdl: uint16, buf: pointer): uint8
        {.exportc, cdecl.} =
      nimLldConDataTx(conhdl, buf)
    proc lld_con_llcp_tx*(conhdl: uint16, buf: pointer): uint8
        {.exportc, cdecl.} =
      nimLldConLlcpTx(conhdl, buf)
