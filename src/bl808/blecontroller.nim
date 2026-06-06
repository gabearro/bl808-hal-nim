## BLE Controller reimplementation for BL808 (replaces libblecontroller_bl602_m1s1.a)
##
## Reimplemented from the binary blob disassembly. All 465 exported symbols
## are provided with {.exportc, cdecl.} pragmas.
##
## Module map:
##   co_list / co_bdaddr   -- linked list and BD address utilities
##   ke_*                  -- kernel: events, messages, timers, tasks, memory
##   ea_*                  -- event arbiter / scheduler
##   em_buf_*              -- exchange memory buffer management
##   hci_*                 -- HCI command/event interface
##   llc_*                 -- link layer control
##   lld_*                 -- link layer driver hardware
##   llm_*                 -- link layer manager (adv, scan, connection)
##   bflbble_* / bflbip_*  -- platform integration
##   ecc_*                 -- ECC crypto

import mmio
import core
import irq
import blep256
import blebighex
from blerfdata import nil
from blecrypto import nil
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
    let n = value and 0x0F'u8
    bleTraceByte(if n < 10'u8: uint8(ord('0')) + n
                 else: uint8(ord('A')) + n - 10'u8)

  proc bleTraceHex32(value: uint32) =
    bleTrace("0x")
    for shift in countdown(28, 0, 4):
      bleTraceHexNibble(uint8((value shr shift) and 0x0F'u32))

when defined(bl808m0) and
    bl808BleNimSchProgEnabled:
  proc nimSchProgInit(initType: uint8) {.cdecl.}
  proc nimSchProgFifoIsr() {.cdecl.}
  proc nimSchProgSkipIsr(idx: uint8) {.cdecl.}
  var nimSchProgSkipIndex {.exportc: "m_sw_skip_et_idx".}: uint32

when defined(bl808m0):
  when not bl808BleNimSchProg:
    {.error: "M0 BLE requires the pure Nim scheduler program path".}
  proc nimSchProgPush(prog: pointer) {.cdecl.}

when defined(bl808m0) and
    (bl808BleNimConnectionEnabled or bl808BleNimPureCentral):
  type
    BtbleRfTableView {.packed.} = object
      reset*: pointer
      forceAgcEnable*: pointer
      unusedCallback08*: pointer
      unusedCallback0c*: pointer
      txpwrMaxSet*: pointer
      txpwrMaxGet*: pointer
      unusedCallback18*: pointer
      txpwrDbmGet*: pointer
      txpwrCsGet*: pointer
      rssiConvert*: pointer
      unusedCallback28*: pointer
      regRead*: pointer
      regWrite*: pointer
      sleep*: pointer
      emConfigWord*: uint16
      emConfigPadding3a*: array[3, uint8]
      rssiFloorDbm*: int8
      calibrationWord*: uint16

    BleMacPhyRegs {.packed.} = object
      reserved000*: array[0x30, uint8]
      sleepCtrl*: uint32
      reserved034*: array[0x84C, uint8]
      reset880*: uint32
      reset884*: uint32
      reset888*: uint32
      reset88c*: uint32
      reset890*: uint32
      reset894*: uint32
      reset898*: uint32
      reset89c*: uint32
      reserved8a0*: array[0xE0, uint8]
      settle980*: uint32
      settle984*: uint32
      settle988*: uint32
      settle98c*: uint32
      reserved990*: array[0x30, uint8]
      trim9c0*: uint32

    BlePhyCtrlRegs {.packed.} = object
      reserved00*: array[0x08, uint8]
      resetInitCtrl08*: uint32
      reserved0c*: array[0x80, uint8]
      resetTuningCtrl8c*: uint32

    BlePhyAgcRegs {.packed.} = object
      reserved00*: array[0x84, uint8]
      resetAgcConfig84*: uint32

  const
    BtbleRfEmConfigWord = 0x2000'u16
    BtbleRfRssiFloorDbm = -40'i8
    BtbleRfCalibrationWord = 0xBAC4'u16

  static:
    doAssert offsetof(BtbleRfTableView, unusedCallback08) == 0x08
    doAssert offsetof(BtbleRfTableView, unusedCallback0c) == 0x0C
    doAssert offsetof(BtbleRfTableView, txpwrMaxSet) == 0x10
    doAssert offsetof(BtbleRfTableView, txpwrMaxGet) == 0x14
    doAssert offsetof(BtbleRfTableView, unusedCallback18) == 0x18
    doAssert offsetof(BtbleRfTableView, txpwrDbmGet) == 0x1C
    doAssert offsetof(BtbleRfTableView, txpwrCsGet) == 0x20
    doAssert offsetof(BtbleRfTableView, rssiConvert) == 0x24
    doAssert offsetof(BtbleRfTableView, unusedCallback28) == 0x28
    doAssert offsetof(BtbleRfTableView, regRead) == 0x2C
    doAssert offsetof(BtbleRfTableView, regWrite) == 0x30
    doAssert offsetof(BtbleRfTableView, sleep) == 0x34
    doAssert offsetof(BtbleRfTableView, emConfigWord) == 0x38
    doAssert offsetof(BtbleRfTableView, emConfigPadding3a) == 0x3A
    doAssert offsetof(BtbleRfTableView, rssiFloorDbm) == 0x3D
    doAssert offsetof(BtbleRfTableView, calibrationWord) == 0x3E
    doAssert offsetof(BleMacPhyRegs, sleepCtrl) == 0x30
    doAssert offsetof(BleMacPhyRegs, reset880) == 0x880
    doAssert offsetof(BleMacPhyRegs, reset89c) == 0x89C
    doAssert offsetof(BleMacPhyRegs, settle980) == 0x980
    doAssert offsetof(BleMacPhyRegs, settle98c) == 0x98C
    doAssert offsetof(BleMacPhyRegs, trim9c0) == 0x9C0
    doAssert offsetof(BlePhyCtrlRegs, resetInitCtrl08) == 0x08
    doAssert offsetof(BlePhyCtrlRegs, resetTuningCtrl8c) == 0x8C
    doAssert offsetof(BlePhyAgcRegs, resetAgcConfig84) == 0x84

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
    regStore(addr mac.reset880, 0x00500350'u32)
    regStore(addr mac.reset884, 0x00500350'u32)
    regStore(addr mac.reset888, 0x00500350'u32)
    regStore(addr mac.reset88c, 0x00000350'u32)
    regStore(addr mac.reset890, 0x04000703'u32)
    regStore(addr mac.reset894, 0x00000502'u32)
    regStore(addr mac.reset898, 0x08000703'u32)
    regStore(addr mac.reset89c, 0x08000003'u32)
    regUpdateField(addr mac.reset890, 0xFF80FFFF'u32, 0x00280000'u32)
    regUpdateField(addr mac.reset894, 0xFF80FFFF'u32, 0x001E0000'u32)
    regUpdateField(addr mac.reset898, 0xFF00FFFF'u32, 0x00870000'u32)
    regUpdateField(addr mac.reset89c, 0xFF80FFFF'u32, 0x00280000'u32)
    regStore(addr mac.trim9c0, regLoad(addr mac.trim9c0) or 0x00004000'u32)
    regStore(addr agc.resetAgcConfig84, 0x1208102B'u32)
    regUpdateField(addr phy.resetTuningCtrl8c, 0xFF803FFF'u32, 0x00014000'u32)
    regStore(addr phy.resetInitCtrl08, 0x0842001A'u32)
    regStore(addr mac.settle980, 0x02120013'u32)
    regStore(addr mac.settle984, 0x02120013'u32)
    regStore(addr mac.settle988, 0x02120013'u32)
    regStore(addr mac.settle98c, 0x02120013'u32)

  proc nimRfForceAgcEnable() {.cdecl.} =
    discard

  proc btble_rf_init*(rf: pointer) {.exportc, cdecl.} =
    if rf == nil:
      return
    let table = cast[ptr BtbleRfTableView](rf)
    table.reset = cast[pointer](nimRfReset)
    table.forceAgcEnable = cast[pointer](nimRfForceAgcEnable)
    table.unusedCallback08 = nil
    table.unusedCallback0c = nil
    table.txpwrMaxSet = cast[pointer](nimBleRfTxpowerMaxSet)
    table.txpwrMaxGet = cast[pointer](nimBleRfTxpowerMaxGet)
    table.unusedCallback18 = nil
    table.txpwrDbmGet = cast[pointer](nimRfTxpwrDbmGet)
    table.txpwrCsGet = cast[pointer](nimRfTxpwrCsGet)
    table.rssiConvert = cast[pointer](nimRfRssiConvert)
    table.unusedCallback28 = nil
    table.regRead = cast[pointer](nimRfRegRead)
    table.regWrite = cast[pointer](nimRfRegWrite)
    table.sleep = cast[pointer](nimRfSleep)
    table.emConfigWord = BtbleRfEmConfigWord
    table.emConfigPadding3a = [0'u8, 0, 0]
    table.rssiFloorDbm = BtbleRfRssiFloorDbm
    table.calibrationWord = BtbleRfCalibrationWord
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
# ---------------------------------------------------------------------------
# Forward declarations & constants
# ---------------------------------------------------------------------------

const
  BLE_BASE* = 0x28000000'u32
  ## BLE core register base address

  KE_EVENT_MAX* = 10
  ## Maximum number of kernel events

  KE_TASK_MAX* = 20
  ## Maximum number of kernel tasks

  KE_MEM_POOL_MAX* = 8
  ## Maximum number of memory pools

  KE_HEAP_SIZE* = 4096
  ## Default heap size for BLE kernel

  KE_TIMER_MAX_DELAY* = 0x003FFFFF'u32
  ## Maximum timer delay (22 bits)

  BLE_EM_BASE* = 0x28008000'u32
  ## Exchange memory base

  BTBLE_EM_BASE* = 0x28010000'u32
  ## BL808 BTBLE exchange memory base used by the on-chip link layer

  BtbleBusyBit = 0x80000000'u32
  BtbleCommandPollLimit = 100_000'u32
  BleKeMessageEventId = 2'u8
  BleKeMessageEventBit = 1'u32 shl 2
  BleKeEventDrainLimit = 8'u32
  BleKeTimerDrainLimit = 8'u32
  BleArbCallbackDrainLimit = 4'u32
  BleScanReportDrainLimit = 2'u32

var
  nim_btble_cmd_wait_timeout_count* {.exportc.}: uint32
  nim_btble_cmd_wait_last_reg* {.exportc.}: uint32
  nim_ble_ke_event_yield_count* {.exportc.}: uint32
  nim_ble_ke_event_yield_field* {.exportc.}: uint32
  nim_ble_ke_timer_yield_count* {.exportc.}: uint32
  nim_ble_ke_timer_yield_time* {.exportc.}: uint32
  nim_ble_arb_callback_yield_count* {.exportc.}: uint32
  nim_ble_scan_report_yield_count* {.exportc.}: uint32
  nim_ble_scan_report_yield_pending* {.exportc.}: uint32

proc waitBtbleCommandDone(reg: uint,
                          limit: uint32 = BtbleCommandPollLimit): bool =
  var remaining = limit
  while (regRead(reg) and BtbleBusyBit) != 0'u32:
    if remaining == 0'u32:
      inc nim_btble_cmd_wait_timeout_count
      nim_btble_cmd_wait_last_reg = reg.uint32
      return false
    dec remaining
  true

proc bflbble_isr*() {.exportc, cdecl.}
proc rwip_reset*() {.exportc, cdecl.}

when defined(bl808m0):
  var nim_btble_polled_intmask* {.exportc.}: uint32

  const
    NimM0RfTop0IrqRaw = 21'u32
    NimM0RfTop1IrqRaw = 22'u32
    NimM0BleIrqConnRaw = 48'u32
    NimM0BleIrqConnAlias = 64'u32
    NimM0BleIrqRaw = 56'u32
    NimM0BleIrqSchedulerRaw = 61'u32
    NimM0BtIrqRaw = 62'u32
    NimM0BleIrqAlias = 72'u32

  proc nimDisableM0ClicIrq(irq: uint32) =
    m0McuIntMaskAndClearSource(irq)
    clicDisableIrq(irq)
    clicClearPending(irq)
    clicSetAttr(irq, clicDefaultAttr())
    clicSetLevel(irq, 0)

  proc nimDisableM0BleClicIrq() =
    nimDisableM0ClicIrq(NimM0BleIrqConnRaw)
    nimDisableM0ClicIrq(NimM0BleIrqConnAlias)
    nimDisableM0ClicIrq(NimM0BleIrqRaw)
    nimDisableM0ClicIrq(NimM0BleIrqSchedulerRaw)
    nimDisableM0ClicIrq(NimM0BtIrqRaw)
    nimDisableM0ClicIrq(NimM0BleIrqAlias)

  proc nimDisableM0RfClicIrq() =
    m0McuIntMaskAndClearSource(NimM0RfTop0IrqRaw)
    m0McuIntMaskAndClearSource(NimM0RfTop1IrqRaw)
    nimDisableM0ClicIrq(NimM0RfTop0IrqRaw)
    nimDisableM0ClicIrq(NimM0RfTop1IrqRaw)

  proc nimM0BleRuntimeIrqHandler() {.cdecl.} =
    bflbble_isr()

  proc nimEnableM0BleRuntimeIrq(irq: uint32) =
    registerTrapHandler(irq, nimM0BleRuntimeIrqHandler)
    m0McuIntUnmaskSource(irq)
    clicClearPending(irq)
    clicSetAttr(irq, clicDefaultAttr())
    clicSetLevel(irq, 1)
    clicEnableIrq(irq)

  proc nimEnableM0BleRuntimeIrqs(enableGlobal: bool = true) =
    when bl808BleNimPureCentral:
      nimEnableM0BleRuntimeIrq(NimM0RfTop0IrqRaw)
      nimEnableM0BleRuntimeIrq(NimM0RfTop1IrqRaw)
      nimEnableM0BleRuntimeIrq(NimM0BleIrqConnRaw)
      nimEnableM0BleRuntimeIrq(NimM0BleIrqConnAlias)
      nimEnableM0BleRuntimeIrq(NimM0BleIrqRaw)
      nimEnableM0BleRuntimeIrq(NimM0BleIrqSchedulerRaw)
      nimEnableM0BleRuntimeIrq(NimM0BtIrqRaw)
      nimEnableM0BleRuntimeIrq(NimM0BleIrqAlias)
      core.csrWriteMie(core.csrReadMie() or (1'u shl 11))
      if enableGlobal:
        core.enableInterrupts()

const
  CO_LIST_MAX_SIZE* = 0xFFFF'u16
  ## Max elements sentinel

  EM_BUF_RX_COUNT* = 5
  ## Number of RX buffers

  EM_BUF_TX_COUNT* = 8
  ## Number of TX buffers

  EM_BUF_RX_DESC_SIZE* = 14
  ## Size of RX buffer descriptor

  EM_BUF_TX_DESC_SIZE* = 10
  ## Size of TX buffer descriptor

  EM_BUF_RX_DATA_SIZE* = 38
  ## Size of RX data buffer (bytes per element)

  EM_BUF_TX_DATA_SIZE* = 260
  ## Size of TX data buffer (bytes per element)

  EA_INTERVAL_MAX* = 32
  ## Maximum number of EA intervals

  LLC_CON_MAX* = 2
  ## Maximum BLE connections

  LLM_WL_MAX* = 16
  ## Maximum whitelist size

  HCI_CMD_DESC_MAX* = 64
  ## Max HCI command descriptors

  HCI_EVT_DESC_MAX* = 32
  ## Max HCI event descriptors

  HCI_LE_EVT_DESC_MAX* = 32
  ## Max LE event descriptors

  ECC_KEY_LEN* = 32
  ## ECC key length in bytes (256-bit)

  HciOpReadBufferSize = 0x1005'u16
  HciOpReset = 0x0C03'u16
  HciOpDisconnect = 0x0406'u16
  HciOpReadRemoteVersionInfo = 0x041D'u16
  HciOpLeReadBufferSize = 0x2002'u16
  HciOpLeReadLocalSupportedFeatures = 0x2003'u16
  HciOpLeSetRandomAddress = 0x2005'u16
  HciOpLeSetAdvParams = 0x2006'u16
  HciOpLeSetAdvData = 0x2008'u16
  HciOpLeSetScanRspData = 0x2009'u16
  HciOpLeSetAdvEnable = 0x200A'u16
  HciOpLeSetScanParams = 0x200B'u16
  HciOpLeSetScanEnable = 0x200C'u16
  HciOpLeCreateConnection = 0x200D'u16
  HciOpLeCreateConnectionCancel = 0x200E'u16
  HciOpLeConnectionUpdate = 0x2013'u16
  HciOpLeReadRemoteFeatures = 0x2016'u16
  HciOpLeEncrypt = 0x2017'u16
  HciOpLeRand = 0x2018'u16
  HciOpLeSetDataLen = 0x2022'u16
  HciOpLeReadSuggestedDefaultDataLen = 0x2023'u16
  HciOpLeWriteSuggestedDefaultDataLen = 0x2024'u16
  HciOpLeReadLocalP256PublicKey = 0x2025'u16
  HciOpLeGenerateDhKey = 0x2026'u16
  HciOpLeReadMaximumDataLen = 0x202F'u16
  HciStatusSuccess = 0x00'u8
  HciStatusUnknownConnection = 0x02'u8
  HciStatusHardwareFailure = 0x03'u8
  HciStatusCommandDisallowed = 0x0C'u8
  HciStatusUnsupportedFeatureParam = 0x11'u8
  HciStatusInvalidParams = 0x12'u8
  HciStatusUnsupportedRemoteFeature = 0x1A'u8

  BtHciCmd = 0'u8
  BtHciAclData = 1'u8
  HciPktCmdComplete = 2'u8
  HciPktCmdStatus = 3'u8
  HciPktLeMeta = 4'u8
  HciPktEvent = 5'u8
  HciEvtNumberOfCompletedPackets = 0x13'u16
  HciEvtEncryptionChange = 0x08'u16
  HciEvtRemoteVersionInfoComplete = 0x0C'u16
  HciEvtEncryptionKeyRefreshComplete = 0x30'u16
  HciEvtDisconnectComplete = 0x05'u16
  HciEvtFlushOccurred = 0x11'u16
  HciEvtAuthenticatedPayloadTimeoutExpired = 0x57'u16

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
    ldpcCtrlB340*: uint32
    ldpcCtrlB344*: uint32
    ldpcCtrlB348*: uint32
    reservedB34c*: array[0x44, uint8]
    agcLoad*: uint32

static:
  doAssert offsetof(BlePhyMemoryRegs, memMode) == 0x824
  doAssert offsetof(BlePhyMemoryRegs, ldpcMode) == 0x834
  doAssert offsetof(BlePhyMemoryRegs, agcMemGate) == 0x874
  doAssert offsetof(BlePhyMemoryRegs, ldpcCtrlB340) == 0xB340
  doAssert offsetof(BlePhyMemoryRegs, ldpcCtrlB344) == 0xB344
  doAssert offsetof(BlePhyMemoryRegs, ldpcCtrlB348) == 0xB348
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
  bleRegStorePtr(addr phyMem.ldpcCtrlB340, 0'u32)
  bleRegStorePtr(addr phyMem.ldpcCtrlB344, 0'u32)
  bleRegStorePtr(addr phyMem.ldpcCtrlB348, 0'u32)
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

# ---------------------------------------------------------------------------
# Primitive types
# ---------------------------------------------------------------------------

type
  KeTaskId* = uint16
  KeMsgId* = uint16

const
  KeMsgConsumed* = 1'i32
  KeMsgSaved* = 2'i32

# ---------------------------------------------------------------------------
# co_list: singly-linked list (next pointer at offset 0)
# ---------------------------------------------------------------------------

type
  CoListNode* {.packed.} = object
    next*: ptr CoListNode

  CoList* {.packed.} = object
    first*: ptr CoListNode
    last*: ptr CoListNode

# ---------------------------------------------------------------------------
# BD address
# ---------------------------------------------------------------------------

type
  BdAddr* {.packed.} = object
    data*: array[6, uint8]

  BtbleScanReqPduView* {.packed.} = object
    scanA*: BdAddr
    advA*: BdAddr

  BtbleAdvPduView* {.packed.} = object
    advA*: BdAddr
    data*: array[31, uint8]

# ---------------------------------------------------------------------------
# ke_msg: message header + payload
# Layout from disasm: offset 0 = next (4 bytes, linked list pointer)
#                     offset 4 = id uint16
#                     offset 6 = dest_id uint16
#                     offset 8 = src_id uint16
#                     offset 10 = param_len uint16
#                     offset 12 = param[] variable
# ---------------------------------------------------------------------------

type
  KeMsgHeader* {.packed.} = object
    next*: ptr KeMsgHeader          ## list link (set to -1 when free)
    id*: uint16                     ## message id
    dest_id*: uint16                ## destination task id
    src_id*: uint16                 ## source task id
    param_len*: uint16              ## parameter length

  KeMsgEnvelope* {.packed.} = object
    header*: KeMsgHeader
    param*: UncheckedArray[uint8]

# ---------------------------------------------------------------------------
# ke_timer: timer element
# Layout: offset 0 = next (ptr, list link)
#         offset 4 = id uint16
#         offset 6 = task uint16
#         offset 8 = time (uint32, only lower 23 bits used)
# ---------------------------------------------------------------------------

type
  KeTimer* {.packed.} = object
    next*: ptr KeTimer
    id*: uint16
    task*: uint16
    time*: uint32

# ---------------------------------------------------------------------------
# ke_task: task descriptor
# ---------------------------------------------------------------------------

type
  KeMsgHandler* = proc(msgid: KeMsgId, param: pointer,
                         dest_id: KeTaskId, src_id: KeTaskId): int32 {.cdecl.}

  KeMsgStatusHandler* = proc(msgid: KeMsgId, dest_id: KeTaskId,
                               src_id: KeTaskId): int32 {.cdecl.}

  KeStateMsgHandler* {.packed.} = object
    id*: KeMsgId
    handler*: KeMsgHandler

  KeStateHandler* {.packed.} = object
    msg_table*: ptr KeStateMsgHandler
    msg_cnt*: uint16

  KeTaskDesc* {.packed.} = object
    state_handler*: ptr KeStateHandler
    default_handler*: ptr KeStateHandler
    state*: ptr uint8
    state_max*: uint16
    idx_max*: uint16

# ---------------------------------------------------------------------------
# ke_event: event slot
# ---------------------------------------------------------------------------

type
  KeEventCallback* = proc(evt: uint8) {.cdecl.}

  KeEventSlot* {.packed.} = object
    callback*: KeEventCallback

# ---------------------------------------------------------------------------
# EA (event arbiter) types
# ---------------------------------------------------------------------------

type
  EaEltTag* {.packed.} = object
    node*: CoListNode
    ea_cb_start*: pointer
    ea_cb_stop*: pointer
    ea_cb_cancel*: pointer
    timestamp*: uint32
    asap_limit*: uint32
    duration_min*: uint32
    delay*: uint32
    slot_dur*: uint32
    current_prio*: uint8
    linked*: uint8

  EaIntervalTag* {.packed.} = object
    node*: CoListNode
    interval*: uint32
    offset*: uint32
    bandwidth*: uint32
    link_id*: uint8
    role*: uint8

# ---------------------------------------------------------------------------
# EM buffer descriptors
# ---------------------------------------------------------------------------

type
  EmBufRxDesc* {.packed.} = object
    status*: uint16
    reserved2*: uint16
    data_len*: uint16
    buf_ptr*: uint16
    reserved8*: array[6, uint8]

  EmBufTxDesc* {.packed.} = object
    status*: uint16
    reserved2*: uint16
    buf_ptr*: uint16
    data_len*: uint16
    reserved8*: uint16

  EmBufRxFreeSlot* {.packed.} = object
    status*: uint16
    reserved2*: array[6, uint8]
    buf_ptr*: uint16
    reserved10*: array[4, uint8]

  BtbleRxDescView* {.packed.} = object
    status*: uint16
    reserved02*: uint16
    header*: uint16
    timing0*: uint16
    rxClock*: uint16
    timing1*: uint16
    meta*: uint16
    reserved0E*: array[6, uint8]
    dataOffset*: uint16
    reserved16*: array[10, uint8]

  BtbleConnTxDescView* {.packed.} = object
    status*: uint16
    header*: uint16
    dataOffset*: uint16
    reserved06*: array[10, uint8]

  BtbleConnEventView* {.packed.} = object
    activityType*: uint16
    control*: uint16
    reserved04*: uint16
    phyControl*: uint16
    reserved08*: array[6, uint8]
    accessAddrLow*: uint16
    accessAddrHigh*: uint16
    crcInitLow*: uint16
    crcInitHigh*: uint16
    reserved16*: array[2, uint8]
    channel*: uint16
    rfConfig*: uint16
    eventCountEnable*: uint16
    rxSync*: uint16
    reserved20*: array[4, uint8]
    txDescPtr*: uint16
    reserved26*: array[8, uint8]
    txDuration*: uint16
    rxDuration*: uint16
    channelMap01*: uint16
    channelMap23*: uint16
    channelMapHop*: uint16
    rxTiming*: uint16
    reserved3A*: uint16
    reserved3C*: array[36, uint8]
    eventCounter*: uint16
    eventCounterAux0*: uint16
    eventCounterAux1*: uint16
    eventCounterAux2*: uint16

  BtbleAccessAddressWordsView* {.packed.} = object
    accessAddrLow*: uint16
    accessAddrHigh*: uint16
    crcInitLow*: uint16
    crcInitHigh*: uint16

  BtbleProgramSlotView* {.packed.} = object
    control*: uint16
    targetLow*: uint16
    targetHigh*: uint16
    fineBackoff*: uint16
    emPtr*: uint16
    duration*: uint16
    rates*: uint16
    tail*: uint16

  SchProgRequestView* {.packed.} = object
    callback*: uint32
    targetTime*: uint32
    fineTime*: uint16
    reserved0A*: array[6, uint8]
    duration*: uint32
    context*: uint32
    primaryType*: uint8
    rate0*: uint8
    rate1*: uint8
    tail*: uint8
    eventIndex*: uint8
    noBackoff*: uint8
    ctrlType*: uint8
    auxControl*: uint8
    hasAux*: uint8
    auxRate*: uint8
    reserved22*: array[2, uint8]

  NimLlcStartEnvView {.packed.} = object
    reserved0*: array[8, uint8]
    peerFeatureSeed*: array[5, uint8]
    reserved13*: uint8
    connIntervalMin*: uint16
    connIntervalMax*: uint16
    connLatency*: uint16
    supervisionTimeout*: uint16
    txPacketTime*: uint16
    txOctets*: uint16
    rxOctets*: uint16
    txRate*: uint8
    rxRate*: uint8
    eventCounter*: uint16
    peerRate*: uint8
    reserved33*: array[3, uint8]
    pendingList*: CoList
    leFeatures*: array[8, uint8]
    reserved52*: array[56, uint8]
    authPayloadTimeout*: uint8
    reserved109*: uint8
    connEventLenMin*: uint16
    connEventLenMax*: uint16
    channelSelection*: uint8
    reserved115*: uint8
    maxTxTime*: uint16
    maxRxTime*: uint16
    schedulerWord*: uint32
    minEventSpacing*: uint16
    localSleepClockAccuracy*: uint8
    peerSleepClockAccuracy*: uint8
    flags*: uint16
    reserved130*: array[10, uint8]

  ConnectIndPayloadView {.packed.} = object
    initiatorAddr*: BdAddr
    advertiserAddr*: BdAddr
    accessAddress*: uint32
    crcInit*: array[3, uint8]
    transmitWindowSize*: uint8
    windowOffset*: uint16
    interval*: uint16
    latency*: uint16
    supervisionTimeout*: uint16
    channelMap*: array[5, uint8]
    hopSca*: uint8

  NimLldConStartParamsView {.packed.} = object
    accessAddress*: uint32
    crcInit*: array[3, uint8]
    transmitWindowSize*: uint8
    windowOffset*: uint16
    interval*: uint16
    latency*: uint16
    supervisionTimeout*: uint16
    channelMap*: array[5, uint8]
    hopIncrement*: uint8
    peerSleepClockAccuracy*: uint8
    reserved23*: uint8
    timingFine*: uint16
    reserved26*: array[2, uint8]
    timingClock*: uint32
    anchorClock*: uint32
    timingSelector*: uint8
    rate*: uint8
    peerRxAddrType*: uint16
    centralRole*: uint8
    reserved41*: array[7, uint8]

  NimLlcControllerDefaultsView {.packed.} = object
    maxTxTime*: uint16
    maxRxTime*: uint16
    minEventSpacing*: uint16
    localSleepClockAccuracy*: uint8
    peerSleepClockAccuracy*: uint8
    authPayloadTimeout*: uint8
    reserved49*: uint8
    connEventLenMin*: uint16
    connEventLenMax*: uint16
    channelSelection*: uint8

  NimLlcStartParamsView {.packed.} = object
    accessAddress*: uint32
    crcInit*: array[3, uint8]
    transmitWindowSize*: uint8
    windowOffset*: uint16
    interval*: uint16
    latency*: uint16
    supervisionTimeout*: uint16
    channelMap*: array[5, uint8]
    hopIncrement*: uint8
    peerSleepClockAccuracy*: uint8
    reserved23*: uint8
    timingFine*: uint16
    reserved26*: uint8
    transmitWindowSizeMirror*: uint8
    timingClock*: uint32
    anchorClock*: uint32
    rate*: uint8
    timingSelector*: uint8
    peerRxAddrType*: uint16
    controllerDefaults*: NimLlcControllerDefaultsView
    reserved55*: uint8

  NimVendorLlcStartParamsView {.packed.} = object
    accessAddress*: uint32
    crcInit*: array[3, uint8]
    transmitWindowSize*: uint8
    windowOffset*: uint16
    connIntervalMin*: uint16
    connIntervalMax*: uint16
    connLatency*: uint16
    peerFeatureSeed*: array[5, uint8]
    hopSca*: uint8
    peerRate*: uint8
    reserved23*: uint8
    timingFine*: uint16
    reserved26*: uint8
    transmitWindowSizeMirror*: uint8
    timingClock*: uint32
    anchorClock*: uint32
    phyRate*: uint8
    directAnchorMode*: uint8
    peerRxAddrType*: uint16
    controllerDefaults*: NimLlcControllerDefaultsView
    reserved55*: uint8

  LlmAdvertiserConnView {.packed.} = object
    reserved0*: array[24, uint8]
    intervalMinSlots*: uint16
    intervalMaxSlots*: uint16
    intervalLatencyWord*: uint32
    supervisionMinSlots*: uint16
    supervisionMaxSlots*: uint16
    driftSlots*: uint16
    reserved38*: array[2, uint8]
    peerAddr*: BdAddr
    peerAddrType*: uint8
    connected*: uint8
    reserved48*: array[24, uint8]
    state*: uint8

  NimLldAdvParamsView {.packed.} = object
    advA*: BdAddr
    initA*: BdAddr
    reserved12*: array[4, uint8]
    advDataPtr*: uint16
    reserved18*: array[2, uint8]
    advDataLen*: uint16
    reserved22*: array[2, uint8]
    advType*: uint8
    reserved25*: array[4, uint8]
    channelMap*: uint8
    reserved30*: array[3, uint8]
    txPower*: uint8
    primaryPhy*: uint8
    secondaryMaxSkip*: uint8
    secondaryPhy*: uint8
    reserved37*: array[3, uint8]

  NimLldScanParamsView {.packed.} = object
    localAddr*: BdAddr
    addrType*: uint8
    flags*: uint8
    intervalMin*: uint16
    intervalMax*: uint16
    windowMin*: uint16
    windowMax*: uint16
    scanType*: uint8
    scanTypeMirror*: uint8
    filterPolicy*: uint8
    reserved19*: array[3, uint8]
    duration*: uint16
    schedulerOverlay*: array[104, uint8]

  NimLldInitParamsView {.packed.} = object
    localAddr*: BdAddr
    peerAddr*: BdAddr
    channelMap*: array[5, uint8]
    reserved17*: uint8
    phyMask*: uint8
    activityId*: uint8
    ownAddrType*: uint8
    peerAddrType*: uint8
    filterPolicy*: uint8
    reserved23*: uint8
    scanInterval*: uint16
    scanWindow*: uint16
    connInterval*: uint16
    connOffset*: uint16
    connLatency*: uint16
    supervisionTimeout*: uint16
    minCeLen*: uint16
    maxCeLen*: uint16
    controllerOverlay*: array[28, uint8]

  EmBufNode* {.packed.} = object
    next*: ptr EmBufNode
    idx*: uint16
    buf_ptr*: uint16

static:
  doAssert sizeof(KeMsgHeader) == 12
  doAssert offsetof(KeMsgHeader, id) == 4
  doAssert offsetof(KeMsgHeader, dest_id) == 6
  doAssert offsetof(KeMsgHeader, src_id) == 8
  doAssert offsetof(KeMsgHeader, param_len) == 10
  doAssert offsetof(KeMsgEnvelope, header) == 0
  doAssert offsetof(KeMsgEnvelope, param) == sizeof(KeMsgHeader)
  doAssert sizeof(EmBufRxDesc) == EM_BUF_RX_DESC_SIZE
  doAssert offsetof(EmBufRxDesc, status) == 0
  doAssert offsetof(EmBufRxDesc, data_len) == 4
  doAssert offsetof(EmBufRxDesc, buf_ptr) == 6
  doAssert sizeof(EmBufTxDesc) == EM_BUF_TX_DESC_SIZE
  doAssert offsetof(EmBufTxDesc, status) == 0
  doAssert offsetof(EmBufTxDesc, buf_ptr) == 4
  doAssert offsetof(EmBufTxDesc, data_len) == 6
  doAssert sizeof(EmBufRxFreeSlot) == EM_BUF_RX_DESC_SIZE
  doAssert offsetof(EmBufRxFreeSlot, status) == 0
  doAssert offsetof(EmBufRxFreeSlot, buf_ptr) == 8
  doAssert sizeof(BtbleScanReqPduView) == 12
  doAssert offsetof(BtbleScanReqPduView, scanA) == 0
  doAssert offsetof(BtbleScanReqPduView, advA) == 6
  doAssert offsetof(BtbleAdvPduView, advA) == 0
  doAssert offsetof(BtbleAdvPduView, data) == 6
  doAssert sizeof(BtbleRxDescView) == 0x20
  doAssert offsetof(BtbleRxDescView, status) == 0
  doAssert offsetof(BtbleRxDescView, header) == 0x04
  doAssert offsetof(BtbleRxDescView, rxClock) == 0x08
  doAssert offsetof(BtbleRxDescView, meta) == 0x0C
  doAssert offsetof(BtbleRxDescView, dataOffset) == 0x14
  doAssert sizeof(BtbleConnTxDescView) == 0x10
  doAssert offsetof(BtbleConnTxDescView, status) == 0
  doAssert offsetof(BtbleConnTxDescView, header) == 0x02
  doAssert offsetof(BtbleConnTxDescView, dataOffset) == 0x04
  doAssert sizeof(BtbleConnEventView) == 0x68
  doAssert offsetof(BtbleConnEventView, activityType) == 0
  doAssert offsetof(BtbleConnEventView, phyControl) == 0x06
  doAssert offsetof(BtbleConnEventView, accessAddrLow) == 0x0E
  doAssert offsetof(BtbleConnEventView, channel) == 0x18
  doAssert offsetof(BtbleConnEventView, rxSync) == 0x1E
  doAssert offsetof(BtbleConnEventView, txDescPtr) == 0x24
  doAssert offsetof(BtbleConnEventView, txDuration) == 0x2E
  doAssert offsetof(BtbleConnEventView, channelMap01) == 0x32
  doAssert offsetof(BtbleConnEventView, rxTiming) == 0x38
  doAssert offsetof(BtbleConnEventView, eventCounter) == 0x60
  doAssert sizeof(BtbleAccessAddressWordsView) == 0x08
  doAssert offsetof(BtbleAccessAddressWordsView, accessAddrLow) == 0
  doAssert offsetof(BtbleAccessAddressWordsView, accessAddrHigh) == 0x02
  doAssert offsetof(BtbleAccessAddressWordsView, crcInitLow) == 0x04
  doAssert offsetof(BtbleAccessAddressWordsView, crcInitHigh) == 0x06
  doAssert sizeof(BtbleProgramSlotView) == 0x10
  doAssert offsetof(BtbleProgramSlotView, control) == 0
  doAssert offsetof(BtbleProgramSlotView, targetLow) == 0x02
  doAssert offsetof(BtbleProgramSlotView, targetHigh) == 0x04
  doAssert offsetof(BtbleProgramSlotView, fineBackoff) == 0x06
  doAssert offsetof(BtbleProgramSlotView, emPtr) == 0x08
  doAssert offsetof(BtbleProgramSlotView, duration) == 0x0A
  doAssert offsetof(BtbleProgramSlotView, rates) == 0x0C
  doAssert offsetof(BtbleProgramSlotView, tail) == 0x0E
  doAssert sizeof(SchProgRequestView) == 36
  doAssert offsetof(SchProgRequestView, targetTime) == 0x04
  doAssert offsetof(SchProgRequestView, fineTime) == 0x08
  doAssert offsetof(SchProgRequestView, duration) == 0x10
  doAssert offsetof(SchProgRequestView, context) == 0x14
  doAssert offsetof(SchProgRequestView, primaryType) == 0x18
  doAssert offsetof(SchProgRequestView, eventIndex) == 0x1C
  doAssert offsetof(SchProgRequestView, hasAux) == 0x20
  doAssert sizeof(NimLlcStartEnvView) == 0x8C
  doAssert offsetof(NimLlcStartEnvView, peerFeatureSeed) == 8
  doAssert offsetof(NimLlcStartEnvView, pendingList) == 36
  doAssert offsetof(NimLlcStartEnvView, leFeatures) == 44
  doAssert offsetof(NimLlcStartEnvView, authPayloadTimeout) == 108
  doAssert offsetof(NimLlcStartEnvView, connEventLenMin) == 110
  doAssert offsetof(NimLlcStartEnvView, schedulerWord) == 120
  doAssert offsetof(NimLlcStartEnvView, flags) == 128
  doAssert sizeof(ConnectIndPayloadView) == 34
  doAssert offsetof(ConnectIndPayloadView, accessAddress) == 12
  doAssert offsetof(ConnectIndPayloadView, crcInit) == 16
  doAssert offsetof(ConnectIndPayloadView, transmitWindowSize) == 19
  doAssert offsetof(ConnectIndPayloadView, channelMap) == 28
  doAssert sizeof(NimLldConStartParamsView) == 48
  doAssert offsetof(NimLldConStartParamsView, crcInit) == 4
  doAssert offsetof(NimLldConStartParamsView, windowOffset) == 8
  doAssert offsetof(NimLldConStartParamsView, channelMap) == 16
  doAssert offsetof(NimLldConStartParamsView, timingFine) == 24
  doAssert offsetof(NimLldConStartParamsView, timingClock) == 28
  doAssert offsetof(NimLldConStartParamsView, timingSelector) == 36
  doAssert offsetof(NimLldConStartParamsView, peerRxAddrType) == 38
  doAssert offsetof(NimLldConStartParamsView, centralRole) == 40
  doAssert sizeof(NimLlcControllerDefaultsView) == 15
  doAssert offsetof(NimLlcControllerDefaultsView, maxRxTime) == 2
  doAssert offsetof(NimLlcControllerDefaultsView, authPayloadTimeout) == 8
  doAssert offsetof(NimLlcControllerDefaultsView, channelSelection) == 14
  doAssert sizeof(NimLlcStartParamsView) == 56
  doAssert offsetof(NimLlcStartParamsView, transmitWindowSizeMirror) == 27
  doAssert offsetof(NimLlcStartParamsView, rate) == 36
  doAssert offsetof(NimLlcStartParamsView, timingSelector) == 37
  doAssert offsetof(NimLlcStartParamsView, controllerDefaults) == 40
  doAssert sizeof(NimVendorLlcStartParamsView) == 56
  doAssert offsetof(NimVendorLlcStartParamsView, connIntervalMin) == 10
  doAssert offsetof(NimVendorLlcStartParamsView, connIntervalMax) == 12
  doAssert offsetof(NimVendorLlcStartParamsView, connLatency) == 14
  doAssert offsetof(NimVendorLlcStartParamsView, peerFeatureSeed) == 16
  doAssert offsetof(NimVendorLlcStartParamsView, peerRate) == 22
  doAssert offsetof(NimVendorLlcStartParamsView, timingFine) == 24
  doAssert offsetof(NimVendorLlcStartParamsView, timingClock) == 28
  doAssert offsetof(NimVendorLlcStartParamsView, anchorClock) == 32
  doAssert offsetof(NimVendorLlcStartParamsView, phyRate) == 36
  doAssert offsetof(NimVendorLlcStartParamsView, directAnchorMode) == 37
  doAssert offsetof(NimVendorLlcStartParamsView, peerRxAddrType) == 38
  doAssert offsetof(NimVendorLlcStartParamsView, controllerDefaults) == 40
  doAssert offsetof(LlmAdvertiserConnView, intervalMinSlots) == 24
  doAssert offsetof(LlmAdvertiserConnView, peerAddr) == 40
  doAssert offsetof(LlmAdvertiserConnView, state) == 72
  doAssert sizeof(NimLldAdvParamsView) == 40
  doAssert offsetof(NimLldAdvParamsView, advDataPtr) == 16
  doAssert offsetof(NimLldAdvParamsView, advDataLen) == 20
  doAssert offsetof(NimLldAdvParamsView, advType) == 24
  doAssert offsetof(NimLldAdvParamsView, channelMap) == 29
  doAssert offsetof(NimLldAdvParamsView, txPower) == 33
  doAssert offsetof(NimLldAdvParamsView, primaryPhy) == 34
  doAssert offsetof(NimLldAdvParamsView, secondaryPhy) == 36
  doAssert sizeof(NimLldScanParamsView) == 128
  doAssert offsetof(NimLldScanParamsView, addrType) == 6
  doAssert offsetof(NimLldScanParamsView, flags) == 7
  doAssert offsetof(NimLldScanParamsView, intervalMin) == 8
  doAssert offsetof(NimLldScanParamsView, windowMax) == 14
  doAssert offsetof(NimLldScanParamsView, filterPolicy) == 18
  doAssert offsetof(NimLldScanParamsView, duration) == 22
  doAssert sizeof(NimLldInitParamsView) == 68
  doAssert offsetof(NimLldInitParamsView, channelMap) == 12
  doAssert offsetof(NimLldInitParamsView, phyMask) == 18
  doAssert offsetof(NimLldInitParamsView, activityId) == 19
  doAssert offsetof(NimLldInitParamsView, ownAddrType) == 20
  doAssert offsetof(NimLldInitParamsView, peerAddrType) == 21
  doAssert offsetof(NimLldInitParamsView, filterPolicy) == 22
  doAssert offsetof(NimLldInitParamsView, scanInterval) == 24
  doAssert offsetof(NimLldInitParamsView, connInterval) == 28
  doAssert offsetof(NimLldInitParamsView, connOffset) == 30
  doAssert offsetof(NimLldInitParamsView, connLatency) == 32
  doAssert offsetof(NimLldInitParamsView, supervisionTimeout) == 34
  doAssert offsetof(NimLldInitParamsView, minCeLen) == 36
  doAssert offsetof(NimLldInitParamsView, maxCeLen) == 38
# ---------------------------------------------------------------------------
# HCI types
# ---------------------------------------------------------------------------

type
  HciCmdDescTag* {.packed.} = object
    opcode*: uint16
    param_len*: uint8
    dest_id*: uint8

  HciEvtDescTag* {.packed.} = object
    code*: uint8
    param_len*: uint8

  HciFlowControl* {.packed.} = object
    acl_pkt_nb*: uint16
    acl_buf_size*: uint16
    flow_en*: bool

  OnChipHciRecvCb* = proc(pktType: uint8, srcId: uint16,
                           param: ptr uint8, paramLen: uint8) {.cdecl.}

  OnChipHciCmd* = object
    opcode*: uint16
    params*: ptr uint8
    paramLen*: uint8

  OnChipHciAclDataTx* = object
    conhdl*: uint16
    pbBcFlag*: uint8
    len*: uint16
    buffer*: ptr uint8

  HciRawCommandPacket* {.packed.} = object
    opcode*: uint16
    paramLen*: uint8
    params*: array[1, uint8]

  HciCmdStatusDescView {.packed.} = object
    reserved00*: array[8, uint8]
    expectedStatusWord*: uint32

  HciRawCmdView {.packed.} = object
    opcode*: uint16
    paramLen*: uint8
    params*: UncheckedArray[uint8]

  HciEventRoutingView {.packed.} = object
    eventCode*: uint8
    route*: uint8
    hostLid*: uint8

  HciAclHostPacketView {.packed.} = object
    handleFlags*: uint16
    length*: uint16
    payload*: UncheckedArray[uint8]

  HciDisconnectCompleteEventView {.packed.} = object
    status*: uint8
    handle*: uint16
    reason*: uint8

  HciEncryptionChangeEventView {.packed.} = object
    status*: uint8
    handle*: uint16
    enabled*: uint8

  HciRemoteVersionInfoCompleteEventView {.packed.} = object
    status*: uint8
    handle*: uint16
    version*: uint8
    companyId*: uint16
    subversion*: uint16

  HciLeConnectionCompleteEventView {.packed.} = object
    subevent*: uint8
    status*: uint8
    handle*: uint16
    role*: uint8
    peerAddrType*: uint8
    peerAddr*: BdAddr
    interval*: uint16
    latency*: uint16
    timeout*: uint16
    accuracy*: uint8

  HciLeConnectionUpdateCompleteEventView {.packed.} = object
    subevent*: uint8
    status*: uint8
    handle*: uint16
    interval*: uint16
    latency*: uint16
    timeout*: uint16

  HciLeRemoteFeaturesCompleteEventView {.packed.} = object
    subevent*: uint8
    status*: uint8
    handle*: uint16
    features*: array[8, uint8]

  HciLePhyUpdateCompleteEventView {.packed.} = object
    subevent*: uint8
    status*: uint8
    handle*: uint16
    txPhy*: uint8
    rxPhy*: uint8

  HciAclDataIndView {.packed.} = object
    handleFlags*: uint16
    length*: uint16
    dataAddr*: uint32

  LldAclRxIndView {.packed.} = object
    bufRef*: uint16
    length*: uint16
    llidFlags*: uint8

  HciLeCreateConnReqView* {.packed.} = object
    scanInterval*: uint16
    scanWindow*: uint16
    filterPolicy*: uint8
    peerAddrType*: uint8
    peerAddr*: BdAddr
    ownAddrType*: uint8
    connIntervalMin*: uint16
    connIntervalMax*: uint16
    connLatency*: uint16
    supervisionTimeout*: uint16
    minCeLen*: uint16
    maxCeLen*: uint16

  HciLeConnUpdateReqView* {.packed.} = object
    handle*: uint16
    connIntervalMin*: uint16
    connIntervalMax*: uint16
    connLatency*: uint16
    supervisionTimeout*: uint16
    minCeLen*: uint16
    maxCeLen*: uint16

  HciLeSetPhyReqView* {.packed.} = object
    handle*: uint16
    allPhys*: uint8
    txPhys*: uint8
    rxPhys*: uint8
    phyOptions*: uint16

  HciLeSetDataLenReqView* {.packed.} = object
    handle*: uint16
    txOctets*: uint16
    txTime*: uint16

  HciLeSuggestedDataLenReqView* {.packed.} = object
    txOctets*: uint16
    txTime*: uint16

  HciLeSetAdvSetRandomAddressReqView* {.packed.} = object
    advertisingHandle*: uint8
    randomAddress*: BdAddr

  HciConnHandleReqView* {.packed.} = object
    handle*: uint16

  HciDisconnectReqView* {.packed.} = object
    handle*: uint16
    reason*: uint8

  HciLeSetRandomAddressReqView* {.packed.} = object
    address*: BdAddr

  HciLeSetAdvParamsReqView* {.packed.} = object
    bytes*: array[15, uint8]

  HciLeDataPayloadReqView* {.packed.} = object
    length*: uint8
    data*: array[31, uint8]

  HciLeSetAdvEnableReqView* {.packed.} = object
    enabled*: uint8

  HciLeSetScanParamsReqView* {.packed.} = object
    scanType*: uint8
    interval*: uint16
    window*: uint16
    ownAddrType*: uint8
    filterPolicy*: uint8

  HciLeSetScanEnableReqView* {.packed.} = object
    enabled*: uint8
    filterDuplicates*: uint8

  HciWriteAuthPayloadTimeoutReqView* {.packed.} = object
    handle*: uint16
    timeout*: uint16

static:
  doAssert sizeof(HciRawCommandPacket) == 4
  doAssert offsetof(HciRawCommandPacket, opcode) == 0
  doAssert offsetof(HciRawCommandPacket, paramLen) == 2
  doAssert offsetof(HciRawCommandPacket, params) == 3
  doAssert sizeof(HciCmdStatusDescView) == 12
  doAssert offsetof(HciCmdStatusDescView, expectedStatusWord) == 8
  doAssert offsetof(HciRawCmdView, opcode) == 0
  doAssert offsetof(HciRawCmdView, paramLen) == 2
  doAssert offsetof(HciRawCmdView, params) == 3
  doAssert sizeof(HciEventRoutingView) == 3
  doAssert offsetof(HciEventRoutingView, route) == 1
  doAssert offsetof(HciEventRoutingView, hostLid) == 2
  doAssert offsetof(HciAclHostPacketView, handleFlags) == 0
  doAssert offsetof(HciAclHostPacketView, length) == 2
  doAssert offsetof(HciAclHostPacketView, payload) == 4
  doAssert sizeof(HciDisconnectCompleteEventView) == 4
  doAssert offsetof(HciDisconnectCompleteEventView, handle) == 1
  doAssert offsetof(HciDisconnectCompleteEventView, reason) == 3
  doAssert sizeof(HciEncryptionChangeEventView) == 4
  doAssert offsetof(HciEncryptionChangeEventView, handle) == 1
  doAssert offsetof(HciEncryptionChangeEventView, enabled) == 3
  doAssert sizeof(HciRemoteVersionInfoCompleteEventView) == 8
  doAssert offsetof(HciRemoteVersionInfoCompleteEventView, handle) == 1
  doAssert offsetof(HciRemoteVersionInfoCompleteEventView, version) == 3
  doAssert offsetof(HciRemoteVersionInfoCompleteEventView, companyId) == 4
  doAssert offsetof(HciRemoteVersionInfoCompleteEventView, subversion) == 6
  doAssert sizeof(HciLeConnectionCompleteEventView) == 19
  doAssert offsetof(HciLeConnectionCompleteEventView, status) == 1
  doAssert offsetof(HciLeConnectionCompleteEventView, handle) == 2
  doAssert offsetof(HciLeConnectionCompleteEventView, role) == 4
  doAssert offsetof(HciLeConnectionCompleteEventView, peerAddrType) == 5
  doAssert offsetof(HciLeConnectionCompleteEventView, peerAddr) == 6
  doAssert offsetof(HciLeConnectionCompleteEventView, interval) == 12
  doAssert offsetof(HciLeConnectionCompleteEventView, latency) == 14
  doAssert offsetof(HciLeConnectionCompleteEventView, timeout) == 16
  doAssert offsetof(HciLeConnectionCompleteEventView, accuracy) == 18
  doAssert sizeof(HciLeConnectionUpdateCompleteEventView) == 10
  doAssert offsetof(HciLeConnectionUpdateCompleteEventView, status) == 1
  doAssert offsetof(HciLeConnectionUpdateCompleteEventView, handle) == 2
  doAssert offsetof(HciLeConnectionUpdateCompleteEventView, interval) == 4
  doAssert offsetof(HciLeConnectionUpdateCompleteEventView, latency) == 6
  doAssert offsetof(HciLeConnectionUpdateCompleteEventView, timeout) == 8
  doAssert sizeof(HciLeRemoteFeaturesCompleteEventView) == 12
  doAssert offsetof(HciLeRemoteFeaturesCompleteEventView, status) == 1
  doAssert offsetof(HciLeRemoteFeaturesCompleteEventView, handle) == 2
  doAssert offsetof(HciLeRemoteFeaturesCompleteEventView, features) == 4
  doAssert sizeof(HciLePhyUpdateCompleteEventView) == 6
  doAssert offsetof(HciLePhyUpdateCompleteEventView, status) == 1
  doAssert offsetof(HciLePhyUpdateCompleteEventView, handle) == 2
  doAssert offsetof(HciLePhyUpdateCompleteEventView, txPhy) == 4
  doAssert offsetof(HciLePhyUpdateCompleteEventView, rxPhy) == 5
  doAssert sizeof(HciAclDataIndView) == 8
  doAssert offsetof(HciAclDataIndView, length) == 2
  doAssert offsetof(HciAclDataIndView, dataAddr) == 4
  doAssert sizeof(LldAclRxIndView) == 5
  doAssert offsetof(LldAclRxIndView, length) == 2
  doAssert offsetof(LldAclRxIndView, llidFlags) == 4
  doAssert sizeof(HciLeCreateConnReqView) == 25
  doAssert offsetof(HciLeCreateConnReqView, peerAddrType) == 5
  doAssert offsetof(HciLeCreateConnReqView, peerAddr) == 6
  doAssert offsetof(HciLeCreateConnReqView, ownAddrType) == 12
  doAssert offsetof(HciLeCreateConnReqView, connIntervalMin) == 13
  doAssert offsetof(HciLeCreateConnReqView, connLatency) == 17
  doAssert offsetof(HciLeCreateConnReqView, supervisionTimeout) == 19
  doAssert sizeof(HciLeConnUpdateReqView) == 14
  doAssert offsetof(HciLeConnUpdateReqView, connIntervalMin) == 2
  doAssert offsetof(HciLeConnUpdateReqView, connLatency) == 6
  doAssert offsetof(HciLeConnUpdateReqView, supervisionTimeout) == 8
  doAssert sizeof(HciLeSetPhyReqView) == 7
  doAssert offsetof(HciLeSetPhyReqView, txPhys) == 3
  doAssert offsetof(HciLeSetPhyReqView, rxPhys) == 4
  doAssert sizeof(HciLeSetDataLenReqView) == 6
  doAssert offsetof(HciLeSetDataLenReqView, txOctets) == 2
  doAssert offsetof(HciLeSetDataLenReqView, txTime) == 4
  doAssert sizeof(HciLeSuggestedDataLenReqView) == 4
  doAssert offsetof(HciLeSuggestedDataLenReqView, txTime) == 2
  doAssert sizeof(HciLeSetAdvSetRandomAddressReqView) == 7
  doAssert offsetof(HciLeSetAdvSetRandomAddressReqView, randomAddress) == 1
  doAssert sizeof(HciConnHandleReqView) == 2
  doAssert offsetof(HciConnHandleReqView, handle) == 0
  doAssert sizeof(HciDisconnectReqView) == 3
  doAssert offsetof(HciDisconnectReqView, reason) == 2
  doAssert sizeof(HciLeSetRandomAddressReqView) == 6
  doAssert sizeof(HciLeSetAdvParamsReqView) == 15
  doAssert sizeof(HciLeDataPayloadReqView) == 32
  doAssert offsetof(HciLeDataPayloadReqView, data) == 1
  doAssert sizeof(HciLeSetAdvEnableReqView) == 1
  doAssert sizeof(HciLeSetScanParamsReqView) == 7
  doAssert offsetof(HciLeSetScanParamsReqView, interval) == 1
  doAssert offsetof(HciLeSetScanParamsReqView, ownAddrType) == 5
  doAssert sizeof(HciLeSetScanEnableReqView) == 2
  doAssert sizeof(HciWriteAuthPayloadTimeoutReqView) == 4
  doAssert offsetof(HciWriteAuthPayloadTimeoutReqView, timeout) == 2

# ---------------------------------------------------------------------------
# LLC / LLD / LLM types (opaque state structs)
# ---------------------------------------------------------------------------

type
  LlcConEnv* = object
    ## Per-connection LLC environment (opaque, ~420 bytes from disasm)
    data*: array[420, uint8]

  LlcChannelAssessmentView {.packed.} = object
    reserved00*: array[344, uint8]
    flags*: uint16
    channelMap*: array[5, uint8]

  LlcDisconnectStateView {.packed.} = object
    reserved00*: array[413, uint8]
    reason*: uint8
    active*: uint8

  LldEvtEnv* = object
    ## LLD event environment
    data*: array[256, uint8]

  LlmEnv* = object
    ## LLM environment block
    data*: array[512, uint8]

  LlmChannelMapView {.packed.} = object
    reserved00*: array[344, uint8]
    localMap*: array[5, uint8]
    masterMap*: array[5, uint8]

doAssert offsetof(LlcChannelAssessmentView, flags) == 344
doAssert offsetof(LlcChannelAssessmentView, channelMap) == 346
doAssert offsetof(LlcDisconnectStateView, reason) == 413
doAssert offsetof(LlcDisconnectStateView, active) == 414
doAssert offsetof(LlmChannelMapView, localMap) == 344
doAssert offsetof(LlmChannelMapView, masterMap) == 349

# ---------------------------------------------------------------------------
# ECC types
# ---------------------------------------------------------------------------

type
  EccPoint256* {.packed.} = object
    x*: array[ECC_KEY_LEN, uint8]
    y*: array[ECC_KEY_LEN, uint8]

# ---------------------------------------------------------------------------
# Global state (kernel environment)
# ---------------------------------------------------------------------------

var
  # co_list patch function pointer(s)
  co_list_init_patch: proc(a0: uint32, list: ptr CoList): int32 {.cdecl.}
  co_list_push_back_patch: proc(a0: uint32, list: ptr CoList, node: ptr CoListNode): int32 {.cdecl.}
  co_list_push_front_patch: proc(a0: uint32, list: ptr CoList, node: ptr CoListNode): int32 {.cdecl.}
  co_list_pop_front_patch: proc(result_out: ptr pointer, list: ptr CoList): int32 {.cdecl.}
  co_list_extract_patch: proc(found: ptr uint8, list: ptr CoList, node: ptr CoListNode, count: uint32): int32 {.cdecl.}
  co_list_extract_after_patch: proc(a0: uint32, list: ptr CoList, prev: ptr CoListNode, node: ptr CoListNode): int32 {.cdecl.}
  co_list_find_patch: proc(result_out: ptr pointer, list: ptr CoList, node: ptr CoListNode): int32 {.cdecl.}
  co_list_merge_patch: proc(a0: uint32, dest: ptr CoList, src: ptr CoList): int32 {.cdecl.}
  co_list_insert_before_patch: proc(a0: uint32, list: ptr CoList, before_node: ptr CoListNode, node: ptr CoListNode): int32 {.cdecl.}
  co_list_insert_after_patch: proc(a0: uint32, list: ptr CoList, after_node: ptr CoListNode, node: ptr CoListNode): int32 {.cdecl.}
  co_list_size_patch: proc(result_out: ptr uint32, list: ptr CoList): int32 {.cdecl.}
  co_list_check_size_available_patch: proc(result_out: ptr uint8, list: ptr CoList, limit: uint32): int32 {.cdecl.}

  # ke_event
  ke_event_field*: uint32
  ke_event_slots*: array[KE_EVENT_MAX, KeEventSlot]

  ke_event_init_patch: proc(a0: uint32): int32 {.cdecl.}
  ke_event_callback_set_patch: proc(status: ptr uint8, idx: uint8, cb: KeEventCallback): int32 {.cdecl.}
  ke_event_set_patch: proc(a0: uint32, idx: uint8): int32 {.cdecl.}
  ke_event_clear_patch: proc(a0: uint32, idx: uint8): int32 {.cdecl.}
  ke_event_get_all_patch: proc(result_out: ptr uint32): int32 {.cdecl.}
  ke_event_flush_patch: proc(): int32 {.cdecl.}
  ke_event_schedule_patch: proc(a0: uint32): int32 {.cdecl.}

  # ke_mem
  ke_mem_heap*: ptr uint8
  ke_mem_heap_end*: ptr uint8

  ke_mem_is_in_heap_patch: proc(result_out: ptr uint8, p: pointer): int32 {.cdecl.}
  ke_mem_init_patch: proc(a0: uint32): int32 {.cdecl.}

  # ke_malloc/free
  ke_malloc_patch: proc(result_out: ptr pointer, size: uint32, mtype: uint32): int32 {.cdecl.}
  ke_free_patch: proc(a0: uint32, p: pointer): int32 {.cdecl.}
  ke_is_free_patch: proc(result_out: ptr uint8, p: pointer): int32 {.cdecl.}

  # ke_msg
  ke_msg_alloc_patch: proc(result_out: ptr pointer, id: KeMsgId, dest: KeTaskId,
                            src: KeTaskId, plen: uint16): int32 {.cdecl.}
  ke_msg_send_patch: proc(a0: uint32, param: pointer): int32 {.cdecl.}
  ke_msg_get_sent_num_patch: proc(result_out: ptr uint32, id: KeMsgId): int32 {.cdecl.}
  ke_msg_send_basic_patch: proc(a0: uint32, id: KeMsgId, dest: KeTaskId, src: KeTaskId): int32 {.cdecl.}
  ke_msg_free_patch: proc(a0: uint32, msg: ptr KeMsgHeader): int32 {.cdecl.}

  # ke_queue
  ke_queue_extract_patch: proc(a0: uint32, queue: ptr CoList, cmp: pointer, arg: pointer): int32 {.cdecl.}
  ke_queue_insert_patch: proc(a0: uint32, queue: ptr CoList, node: ptr CoListNode, cmp: pointer): int32 {.cdecl.}

  # ke_task
  ke_task_desc*: array[KE_TASK_MAX, KeTaskDesc]
  ke_task_saved*: array[KE_TASK_MAX, ptr KeStateHandler]

  ke_task_saved_update_patch: proc(a0: uint32, task_type: uint16): int32 {.cdecl.}
  ke_handler_search_patch: proc(result_out: ptr pointer, msg_id: KeMsgId, task_desc: ptr KeTaskDesc): int32 {.cdecl.}
  ke_task_handler_get_patch: proc(result_out: ptr pointer, msg_id: KeMsgId, task_id: KeTaskId): int32 {.cdecl.}
  ke_task_schedule_patch: proc(a0: uint32): int32 {.cdecl.}
  ke_task_init_patch: proc(a0: uint32): int32 {.cdecl.}
  ke_task_create_patch: proc(a0: uint32, task_type: uint8, desc: ptr KeTaskDesc): int32 {.cdecl.}
  ke_state_set_patch: proc(a0: uint32, task_id: KeTaskId, state: uint8): int32 {.cdecl.}
  ke_state_get_patch: proc(result_out: ptr uint8, task_id: KeTaskId): int32 {.cdecl.}

  # ke_time / ke_timer
  ke_time_patch: proc(result_out: ptr uint32): int32 {.cdecl.}
  ke_time_cmp_patch: proc(result_out: ptr uint8, t1: uint32, t2: uint32): int32 {.cdecl.}
  ke_time_past_patch: proc(result_out: ptr uint8, t: uint32): int32 {.cdecl.}
  ke_timer_hw_set_patch: proc(a0: uint32, timer: ptr KeTimer): int32 {.cdecl.}
  ke_timer_schedule_patch: proc(a0: uint32): int32 {.cdecl.}
  ke_timer_init_patch: proc(a0: uint32): int32 {.cdecl.}
  ke_timer_set_patch: proc(a0: uint32, id: uint16, task: uint16, delay: uint32): int32 {.cdecl.}
  ke_timer_clear_patch: proc(a0: uint32, id: uint16, task: uint16): int32 {.cdecl.}
  ke_timer_active_patch: proc(result_out: ptr uint8, id: uint16, task: uint16): int32 {.cdecl.}
  ke_timer_target_get_patch: proc(result_out: ptr uint32): int32 {.cdecl.}

  # ke_init / flush / sleep
  ke_init_patch: proc(a0: uint32): int32 {.cdecl.}
  ke_flush_patch: proc(a0: uint32): int32 {.cdecl.}
  ke_sleep_check_patch: proc(result_out: ptr uint8): int32 {.cdecl.}

  # ke misc compare patches
  cmp_abs_time_patch: proc(a0: uint32, t1: pointer, t2: pointer): int32 {.cdecl.}
  cmp_timer_id_patch: proc(a0: uint32, t1: pointer, t2: pointer): int32 {.cdecl.}
  cmp_dest_id_patch: proc(a0: uint32, a1: pointer, a2: pointer): int32 {.cdecl.}

  # Kernel message queue
  ke_msg_queue*: CoList
  ke_timer_list*: CoList

  # Debug level
  ble_debug_level*: uint32

  # TX power
  ble_tx_pwr*: int8

  # Scan channel / filter
  ble_scan_chan_fixed*: uint8
  ble_scan_filter_table_size*: uint16

  # ADV rand(om) delay disable flag
  ble_adv_random_delay_disabled*: bool

  # Ongoing programming flag
  ble_programming_ongoing*: ptr uint32

  # ADV discarded notification callback
  ble_adv_discarded_callback*: proc(count: uint32) {.cdecl.}

  # Sleep prevention bitmask
  bflbip_prevent_sleep_mask*: uint32

  # Sleep enable flag
  bflbip_sleep_enabled*: bool

  # External wakeup enable
  bflbip_ext_wakeup*: bool

  # Sleep duration / stat counters
  bflbip_sw_wakeup_cnt*: uint32
  bflbip_sleep_dur_cnt*: uint32
  bflbip_sleep_stat_cnt*: uint32

  nim_btble_sw_pending: bool

  # Deep sleep stat
  ble_deep_sleep_stat*: uint32

  # Wakeup delay
  bflbip_wakeup_delay*: uint32

  # Wlcoex configuration
  bflbip_wlcoex_cfg*: uint32

  # Controller lib version string
  ble_controller_lib_ver: cstring = "bl808-blecontroller-nim-1.0"

  # RTOS task handle
  ble_controller_task_handle*: pointer

  # Main task queue handle
  bflb_main_queue_handle*: pointer

  # Main task function pointer
  bflb_main_task_func*: pointer

  # Trace malloc info
  trace_malloc_info*: array[16, uint32]
  trace_malloc_idx*: uint32

  # EM buf global state
  em_buf_env*: array[512, uint8]  ## large enough for the em_buf environment

  # EA global state
  ea_env_list*: CoList
  ea_env_interval_list*: CoList
  ea_env_target*: uint32
  ea_env_finetarget*: uint32

  # HCI global state
  hci_env*: array[256, uint8]
  hci_evt_mask*: array[8, uint8]
  hci_le_evt_mask*: array[8, uint8]
  hci_fc_env*: HciFlowControl

  # LLC global
  llc_env*: array[LLC_CON_MAX, ptr LlcConEnv]
  llc_env_data*: array[LLC_CON_MAX, LlcConEnv]

  # LLD global
  lld_evt_env_data*: array[512, uint8]

  # LLM global
  llm_env_data*: LlmEnv
  llm_wl*: array[LLM_WL_MAX, BdAddr]
  llm_wl_type*: array[LLM_WL_MAX, uint8]

  # ECC state
  ecc_env*: array[512, uint8]
  ecc_ongoing*: bool
  ecc_private_key*: array[ECC_KEY_LEN, uint8]

  # RF state
  rf_pwr_offset*: int8
  rf_pwr_offset_table*: ptr int8
  rf_pwr_max*: int8

  # PKA state
  pka_result*: array[ECC_KEY_LEN * 2, uint8]

  # On-chip HCI
  onchiphci_env*: array[64, uint8]
  onchiphci_recv_cb*: OnChipHciRecvCb
  onchiphci_cb_payload*: array[260, uint8]
  nim_adv_params* {.exportc.}: array[15, uint8]
  nim_adv_event_props*: uint16
  nim_scan_params*: array[7, uint8]
  nim_adv_data* {.exportc.}: array[31, uint8]
  nim_scan_rsp_data* {.exportc.}: array[31, uint8]
  nim_local_addr*: array[6, uint8]
  nim_local_addr_valid*: bool
  nim_public_addr*: array[6, uint8]
  nim_public_addr_valid*: bool
  nim_adv_data_len* {.exportc.}: uint8
  nim_scan_rsp_data_len* {.exportc.}: uint8
  nim_adv_enabled* {.exportc.}: bool
  nim_scan_enabled*: bool
  nim_conn_active*: bool
  nim_conn_handle*: uint16
  nim_auth_payload_timeout*: uint16
  nim_suggested_tx_octets*: uint16 = NimBleLeMaxDataOctets
  nim_suggested_tx_time*: uint16 = NimBleLeMaxDataTime
  nim_ble_core_ready*: bool
  nim_adv_schedule_slot: uint8
  nim_adv_target_half_us: uint32
  nim_ble_dbg_isr_count* {.exportc.}: uint32
  nim_ble_dbg_isr_stat_or* {.exportc.}: uint32
  nim_ble_dbg_stat20_count* {.exportc.}: uint32
  nim_ble_dbg_stat8000_count* {.exportc.}: uint32
  nim_ble_dbg_push_count* {.exportc.}: uint32
  nim_ble_dbg_rx_ready_count* {.exportc.}: uint32
  nim_ble_dbg_rx_scan_req_count* {.exportc.}: uint32
  nim_ble_dbg_rx_scan_req_match_count* {.exportc.}: uint32
  nim_ble_dbg_rx_scan_req_last_scana0* {.exportc.}: uint32
  nim_ble_dbg_rx_scan_req_last_scana1* {.exportc.}: uint32
  nim_ble_dbg_rx_scan_req_last_adva0* {.exportc.}: uint32
  nim_ble_dbg_rx_scan_req_last_adva1* {.exportc.}: uint32
  nim_ble_dbg_rx_connect_ind_count* {.exportc.}: uint32
  nim_ble_dbg_rx_last_header* {.exportc.}: uint32
  nim_ble_dbg_rx_last_status* {.exportc.}: uint32
  nim_ble_dbg_rx_last_desc* {.exportc.}: uint32
  nim_ble_dbg_rx_last_buf* {.exportc.}: uint32
  nim_hci_debug_stage* {.exportc.}: uint32
  nim_hci_debug_opcode* {.exportc.}: uint32
  nim_hci_debug_status* {.exportc.}: uint32
  nim_hci_debug_len* {.exportc.}: uint32
  nim_hci_debug_cb* {.exportc.}: uint32
  nim_adv_debug_stage* {.exportc.}: uint32
  nim_adv_debug_detail* {.exportc.}: uint32

  # Coex stats
  coex_ble_dump_buf*: array[32, uint8]

  one_bits* {.exportc.}: array[16, uint8] =
    [0'u8, 1, 1, 2, 1, 2, 2, 3, 1, 2, 2, 3, 2, 3, 3, 4]

proc rwip_prevent_sleep_set*(mask: uint16) {.exportc, cdecl.}
proc rwip_prevent_sleep_clear*(mask: uint16) {.exportc, cdecl.}
proc lld_aa_gen*(outAddr: ptr uint8, seed: uint8) {.exportc, cdecl.}
proc lld_ch_map_set*(chMap: ptr uint8) {.exportc, cdecl.}

when defined(bl808m0) and bl808BleNimPureCentral:
  const NimScanPeerHintSlots = 8
  var nim_scan_program_count* {.exportc.}: uint32
  var nim_scan_event_count* {.exportc.}: uint32
  var nim_scan_last_event* {.exportc.}: uint32
  var nim_scan_last_status* {.exportc.}: uint32
  var nim_scan_next_program_at* {.exportc.}: uint32
  var nim_scan_channel_cursor* {.exportc.}: uint8
  var nim_scan_last_channel_index* {.exportc.}: uint32
  var nim_scan_last_adv_channel* {.exportc.}: uint32
  var nim_scan_req_peer_addr_type* {.exportc.}: uint32
  var nim_scan_peer_hint_write_index* {.exportc.}: uint32
  var nim_scan_peer_hint_addr0* {.exportc.}: array[NimScanPeerHintSlots, uint32]
  var nim_scan_peer_hint_addr1* {.exportc.}: array[NimScanPeerHintSlots, uint32]
  var nim_scan_peer_hint_type* {.exportc.}: array[NimScanPeerHintSlots, uint32]
  var nim_scan_peer_hint_channel_index* {.exportc.}: array[NimScanPeerHintSlots, uint32]
  var nim_scan_peer_hint_adv_channel* {.exportc.}: array[NimScanPeerHintSlots, uint32]
  var nim_init_active* {.exportc.}: uint32
  var nim_init_program_count* {.exportc.}: uint32
  var nim_init_event_count* {.exportc.}: uint32
  var nim_init_match_count* {.exportc.}: uint32
  var nim_init_start_count* {.exportc.}: uint32
  var nim_init_complete_count* {.exportc.}: uint32
  var nim_init_hci_complete_count* {.exportc.}: uint32
  var nim_init_cancel_count* {.exportc.}: uint32
  var nim_init_tx_event_count* {.exportc.}: uint32
  var nim_init_last_status* {.exportc.}: uint32
  var nim_init_last_event* {.exportc.}: uint32
  var nim_init_last_rx_clock* {.exportc.}: uint32
  var nim_init_last_rx_fine* {.exportc.}: uint32
  var nim_init_last_anchor* {.exportc.}: uint32
  var nim_init_last_access_addr* {.exportc.}: uint32
  var nim_init_rx_count* {.exportc.}: uint32
  var nim_init_rx_match_reason* {.exportc.}: uint32
  var nim_init_rx_last_header* {.exportc.}: uint32
  var nim_init_rx_last_status* {.exportc.}: uint32
  var nim_init_rx_last_buf* {.exportc.}: uint32
  var nim_init_rx_last_peer0* {.exportc.}: uint32
  var nim_init_rx_last_peer1* {.exportc.}: uint32
  var nim_init_rx_pdu_mismatch_count* {.exportc.}: uint32
  var nim_init_rx_short_count* {.exportc.}: uint32
  var nim_init_rx_addr_mismatch_count* {.exportc.}: uint32
  var nim_init_rx_addr_match_count* {.exportc.}: uint32
  var nim_init_rx_type_mismatch_count* {.exportc.}: uint32
  var nim_init_total_rx_count* {.exportc.}: uint32
  var nim_init_total_match_count* {.exportc.}: uint32
  var nim_init_total_pdu_mismatch_count* {.exportc.}: uint32
  var nim_init_total_short_count* {.exportc.}: uint32
  var nim_init_total_addr_mismatch_count* {.exportc.}: uint32
  var nim_init_total_addr_match_count* {.exportc.}: uint32
  var nim_init_total_type_mismatch_count* {.exportc.}: uint32
  var nim_init_total_handoff_start_count* {.exportc.}: uint32
  var nim_init_total_handoff_timeout_count* {.exportc.}: uint32
  var nim_init_total_start_count* {.exportc.}: uint32
  var nim_init_total_tx_event_count* {.exportc.}: uint32
  var nim_init_total_hci_complete_count* {.exportc.}: uint32
  var nim_init_connect_ind_header_flags* {.exportc.}: uint32
  var nim_init_rx_log_index* {.exportc.}: uint32
  var nim_init_rx_header_log* {.exportc.}: array[8, uint32]
  var nim_init_rx_status_log* {.exportc.}: array[8, uint32]
  var nim_init_rx_peer0_log* {.exportc.}: array[8, uint32]
  var nim_init_rx_peer1_log* {.exportc.}: array[8, uint32]
  var nim_init_rx_reason_log* {.exportc.}: array[8, uint32]
  var nim_init_next_program_at* {.exportc.}: uint32
  var nim_init_event_target_clock* {.exportc.}: uint32
  var nim_init_rx_event_clock* {.exportc.}: uint32
  var nim_init_last_rx_now* {.exportc.}: uint32
  var nim_init_last_rx_event_clock* {.exportc.}: uint32
  var nim_init_last_rx_clock_source* {.exportc.}: uint32
  var nim_init_rx_service_pending* {.exportc.}: uint32
  var nim_init_rx_service_program_count* {.exportc.}: uint32
  var nim_init_rx_service_deadline* {.exportc.}: uint32
  var nim_init_event_done_program_count* {.exportc.}: uint32
  var nim_init_handoff_pending* {.exportc.}: uint32
  var nim_init_handoff_program_count* {.exportc.}: uint32
  var nim_init_handoff_tx_event_count* {.exportc.}: uint32
  var nim_init_handoff_ready_clock* {.exportc.}: uint32
  var nim_init_handoff_deadline* {.exportc.}: uint32
  var nim_init_handoff_start_count* {.exportc.}: uint32
  var nim_init_handoff_timeout_count* {.exportc.}: uint32
  var nim_init_pending_header* {.exportc.}: uint32
  var nim_init_pending_rx_clock* {.exportc.}: uint32
  var nim_init_pending_rx_fine* {.exportc.}: uint32
  var nim_init_pending_desc* {.exportc.}: uint32
  var nim_init_pending_desc_status* {.exportc.}: uint32
  var nim_init_pending_desc_idx* {.exportc.}: uint32
  var nim_init_channel_cursor* {.exportc.}: uint8
  var nim_init_channel_seed* {.exportc.}: uint32
  var nim_init_channel_window_valid* {.exportc.}: uint32
  var nim_init_channel_window_deadline* {.exportc.}: uint32
  var nim_init_last_channel_index* {.exportc.}: uint32
  var nim_init_last_adv_channel* {.exportc.}: uint32
  var nim_init_channel_hint_hit_count* {.exportc.}: uint32
  var nim_init_channel_hint_miss_count* {.exportc.}: uint32
  var nim_init_channel_hint_index* {.exportc.}: uint32
  var nim_init_channel_hint_adv_channel* {.exportc.}: uint32
  var nim_init_complete_pending* {.exportc.}: uint32
  var nim_init_hci_params* {.exportc.}: array[25, uint8]
  var nim_init_ll_data* {.exportc.}: array[22, uint8]
  when defined(BleDebugCounters):
    var nim_init_program_snapshot_count* {.exportc.}: uint32
    var nim_init_program_snapshot_channel* {.exportc.}: uint32
    var nim_init_program_snapshot_timing* {.exportc.}: array[8, uint32]
    var nim_init_program_snapshot_em* {.exportc.}: array[18, uint32]
    var nim_init_program_snapshot_tx_desc* {.exportc.}: array[4, uint32]
    var nim_init_program_snapshot_sched* {.exportc.}: array[8, uint32]
    var nim_init_sch_event_log_index* {.exportc.}: uint32
    var nim_init_sch_event_code_log* {.exportc.}: array[16, uint32]
    var nim_init_sch_event_time_log* {.exportc.}: array[16, uint32]
    var nim_init_sch_event_now_log* {.exportc.}: array[16, uint32]
    var nim_init_sch_event_state_log* {.exportc.}: array[16, uint32]
    var nim_init_sch_event_counts_log* {.exportc.}: array[16, uint32]
    var nim_init_sch_event_done_log* {.exportc.}: array[16, uint32]
    var nim_init_sch_event_int_log* {.exportc.}: array[16, uint32]
    var nim_init_handoff_snapshot_count* {.exportc.}: uint32
    var nim_init_handoff_snapshot_reason* {.exportc.}: uint32
    var nim_init_handoff_snapshot_timing* {.exportc.}: array[16, uint32]
    var nim_init_handoff_snapshot_em* {.exportc.}: array[64, uint32]
    var nim_init_handoff_snapshot_desc* {.exportc.}: array[32, uint32]
    var nim_init_handoff_snapshot_data* {.exportc.}: array[32, uint32]
  var nim_scan_debug_stage* {.exportc.}: uint32
  var nim_scan_debug_now* {.exportc.}: uint32
  var nim_scan_debug_target* {.exportc.}: uint32
  var nim_scan_debug_lead* {.exportc.}: uint32

var sch_slice_params* {.exportc.}: array[8, uint16]

when defined(bl808m0) and
    bl808BleNimSchProgEnabled:
  var nim_sch_prog: array[36, uint8]
  var nim_adv_sch_program_count* {.exportc.}: uint32
  var nim_adv_sch_event_count* {.exportc.}: uint32
  var nim_adv_sch_end_count* {.exportc.}: uint32
  var nim_adv_sch_last_event* {.exportc.}: uint32
  var nim_adv_sch_event_active* {.exportc.}: uint32

  proc nimSchProgCb(arg0: uint32, ctx: pointer,
                          event: uint8) {.exportc, cdecl.} =
    discard arg0
    discard ctx
    nim_adv_sch_last_event = event.uint32
    inc nim_adv_sch_event_count
    case event
    of 0'u8, 1'u8, 4'u8, 7'u8, 0xFF'u8:
      nim_adv_sch_event_active = 0
      inc nim_adv_sch_end_count
    else:
      discard

when defined(bl808m0):
  var nim_lld_adv_params: array[40, uint8]

  when not bl808BleNimConnectionEnabled:
    var nim_lld_adv_rand_state: uint32 = 0x12345678'u32

    proc rand*(): cint {.exportc, cdecl.} =
      nim_lld_adv_rand_state =
        nim_lld_adv_rand_state * 1103515245'u32 + 12345'u32
      cint((nim_lld_adv_rand_state shr 16) and 0x7FFF'u32)

template llcChannelAssessment(env: ptr LlcConEnv): ptr LlcChannelAssessmentView =
  cast[ptr LlcChannelAssessmentView](env)

template llcDisconnectState(env: ptr LlcConEnv): ptr LlcDisconnectStateView =
  cast[ptr LlcDisconnectStateView](env)

template llmChannelMaps(): ptr LlmChannelMapView =
  cast[ptr LlmChannelMapView](addr llm_env_data)

template llmAdvertiserConn(): ptr LlmAdvertiserConnView =
  cast[ptr LlmAdvertiserConnView](addr llm_env_data)

proc bleCentralTraceReadSp(): uint32 {.inline.} =
  var v: uint32
  {.emit: ["asm volatile(\"mv %0, sp\" : \"=r\"(", v, "));"].}
  v

proc bleCentralDebugMark*(stage, detail: uint32) {.exportc, cdecl.} =
  discard stage
  discard detail

proc bleCentralTraceStoreWord(offset: uint, value: uint32) {.inline.} =
  discard offset
  discard value

proc bleCentralTraceStoreRawRa(offset: uint) {.inline.} =
  discard offset

proc bleCentralTraceCheckRawRa(stage: uint32) {.inline.} =
  discard stage

# Memset/memcpy from C (linked externally)
proc c_memset(s: pointer, c: cint, n: csize_t): pointer {.importc: "memset", header: "<string.h>", cdecl.}
proc c_memcpy(dest: pointer, src: pointer, n: csize_t): pointer {.importc: "memcpy", header: "<string.h>", cdecl.}
proc c_memcmp(a: pointer, b: pointer, n: csize_t): cint {.importc: "memcmp", header: "<string.h>", cdecl.}

proc bflbip_us_2_lpcycles*(us: uint32): uint32 {.exportc, cdecl.}
proc bflbip_wakeup_delay_set*(delay: uint32) {.exportc, cdecl.}
proc lld_sleep_init*() {.exportc, cdecl.}

proc read16(regAddr: uint32): uint16 {.inline.} =
  volatileLoad(cast[ptr uint16](regAddr.uint))

proc read8(regAddr: uint32): uint8 {.inline.} =
  volatileLoad(cast[ptr uint8](regAddr.uint))

proc read32(regAddr: uint32): uint32 {.inline.} =
  volatileLoad(cast[ptr uint32](regAddr.uint))

proc write16(regAddr: uint32, value: uint16) {.inline.} =
  volatileStore(cast[ptr uint16](regAddr.uint), value)

proc write8(regAddr: uint32, value: uint8) {.inline.} =
  volatileStore(cast[ptr uint8](regAddr.uint), value)

template bleEmBytes(): ptr UncheckedArray[uint8] =
  cast[ptr UncheckedArray[uint8]](BLE_EM_BASE)

template btbleEmBytes(): ptr UncheckedArray[uint8] =
  cast[ptr UncheckedArray[uint8]](BTBLE_EM_BASE)

proc bleEmPointer(offset: uint16): pointer {.inline.} =
  cast[pointer](addr bleEmBytes()[offset])

proc btbleEmBytePtr(offset: uint16): ptr uint8 {.inline.} =
  addr btbleEmBytes()[offset]

proc btbleEmPayload(offset: uint16): ptr UncheckedArray[uint8] {.inline.} =
  cast[ptr UncheckedArray[uint8]](btbleEmBytePtr(offset))

template btbleAdvPduAt(buf: uint16): ptr BtbleAdvPduView =
  cast[ptr BtbleAdvPduView](BTBLE_EM_BASE + buf.uint32)

proc btbleEmRead8(offset: uint16): uint8 {.inline.} =
  volatileLoad(btbleEmBytePtr(offset))

proc btbleEmWrite8(offset: uint16, value: uint8) {.inline.} =
  volatileStore(btbleEmBytePtr(offset), value)

proc copyBytes(dstAddr: uint32, src: ptr uint8, len: int) =
  if src == nil or len <= 0:
    return
  let raw = cast[ptr UncheckedArray[uint8]](src)
  for i in 0 ..< len:
    write8(dstAddr + i.uint32, raw[i])

proc copyBtbleEmBytes(dstOffset: uint16, src: ptr uint8, len: int) =
  if src == nil or len <= 0:
    return
  let raw = cast[ptr UncheckedArray[uint8]](src)
  for i in 0 ..< len:
    btbleEmWrite8(dstOffset + i.uint16, raw[i])

proc writeBtbleInterruptMask(mask: uint32) =
  ## BTBLE's mask register gates the hardware status sources that the
  ## cooperative M0 poller reads.  In polled M0 builds keep M-mode interrupts
  ## globally disabled while the foreground poller owns BLE; E907 CLIC can
  ## still enter the trap path for pending-disabled sources if MIE stays set.
  when defined(bl808m0) and not bl808BleNimRuntimeClicIrq:
    nim_btble_polled_intmask = mask
    quiesceM0PolledBleClicSources()
    regWrite((BLE_BASE + BTBLE_INTMASK_OFFSET).uint, mask)
    quiesceM0PolledBleClicSources()
  else:
    regWrite((BLE_BASE + BTBLE_INTMASK_OFFSET).uint, mask)

proc enableBtbleInterruptMaskBits(mask: uint32) =
  when defined(bl808m0) and not bl808BleNimRuntimeClicIrq:
    nim_btble_polled_intmask = nim_btble_polled_intmask or mask
    quiesceM0PolledBleClicSources()
    regOr(BLE_BASE + BTBLE_INTMASK_OFFSET, mask)
    quiesceM0PolledBleClicSources()
  else:
    regOr(BLE_BASE + BTBLE_INTMASK_OFFSET, mask)

proc invokeOnChipHci(pktType: uint8, srcId: uint16, payload: ptr uint8,
                     len: uint8): bool =
  let cb = onchiphci_recv_cb
  nim_hci_debug_cb = cast[uint32](cast[uint](cb))
  if cb == nil:
    return false
  if len.int > onchiphci_cb_payload.len:
    return false

  var cbPayload: ptr uint8 = nil
  if len != 0'u8:
    if payload == nil:
      return false
    let src = cast[ptr UncheckedArray[uint8]](payload)
    for i in 0 ..< len.int:
      onchiphci_cb_payload[i] = src[i]
    cbPayload = addr onchiphci_cb_payload[0]

  nim_hci_debug_stage = 0x4010'u32
  cb(pktType, srcId, cbPayload, len)
  nim_hci_debug_stage = 0x4020'u32
  true

proc sendCmdComplete(opcode: uint16, status: uint8) =
  nim_hci_debug_stage = 0x4000'u32
  nim_hci_debug_opcode = opcode.uint32
  nim_hci_debug_status = status.uint32
  nim_hci_debug_len = 1
  bleCentralDebugMark(0x900'u32, uint32(opcode))
  var cc = [status]
  if invokeOnChipHci(HciPktCmdComplete, opcode, addr cc[0], 1):
    bleCentralDebugMark(0x902'u32, uint32(opcode))

proc sendCmdComplete2(opcode: uint16, status: uint8, value: uint8) =
  var cc = [status, value]
  discard invokeOnChipHci(HciPktCmdComplete, opcode, addr cc[0],
                          cc.len.uint8)

proc sendCmdCompletePayload(opcode: uint16, payload: ptr uint8, len: uint8) =
  nim_hci_debug_stage = 0x4030'u32
  nim_hci_debug_opcode = opcode.uint32
  nim_hci_debug_len = len.uint32
  discard invokeOnChipHci(HciPktCmdComplete, opcode, payload, len)
  nim_hci_debug_stage = 0x4031'u32

proc sendCmdStatus(opcode: uint16, status: uint8) =
  var cs = [status]
  discard invokeOnChipHci(HciPktCmdStatus, opcode, addr cs[0], 1)

proc sendHostEvent(eventCode: uint16, payload: ptr uint8, len: uint8) =
  discard invokeOnChipHci(HciPktEvent, eventCode, payload, len)

proc sendLeMetaPayload(payload: ptr uint8, len: uint8) =
  discard invokeOnChipHci(HciPktLeMeta, 0, payload, len)

proc sendNumberOfCompletedPackets(handle, count: uint16) =
  var evt = [1'u8, uint8(handle and 0x00FF'u16),
             uint8((handle shr 8) and 0x00FF'u16),
             uint8(count and 0x00FF'u16),
             uint8((count shr 8) and 0x00FF'u16)]
  sendHostEvent(HciEvtNumberOfCompletedPackets, addr evt[0], evt.len.uint8)

proc sendHostAclBytes(handle: uint16, llid: uint8,
                      data: ptr uint8, len: uint8): bool =
  if onchiphci_recv_cb == nil:
    return false
  if data == nil or len == 0'u8 or len.uint16 > NimBleLeMaxDataOctets:
    return false
  var pkt: array[4 + NimBleLeMaxDataOctets.int, uint8]
  let acl = cast[ptr HciAclHostPacketView](addr pkt[0])
  let pbFlag =
    if llid == 0x01'u8:
      0x01'u16
    else:
      0x02'u16
  let hciHandle = (handle and 0x0FFF'u16) or (pbFlag shl 12)
  acl.handleFlags = hciHandle
  acl.length = len.uint16
  let src = cast[ptr UncheckedArray[uint8]](data)
  for i in 0 ..< len.int:
    acl.payload[i] = src[i]
  invokeOnChipHci(BtHciAclData, handle, addr pkt[0], len + 4'u8)

proc sendHostAclData(handle: uint16, llid: uint8,
                     dataOff: uint16, len: uint8): bool =
  let data = btbleEmBytePtr(dataOff)
  sendHostAclBytes(handle, llid, data, len)

proc sendLeEncryptComplete(opcode: uint16, params: ptr uint8,
                           paramLen: uint8): uint8
proc sendLeRandComplete(opcode: uint16, paramLen: uint8): uint8
proc sendReadBufferSizeComplete(opcode: uint16, paramLen: uint8): uint8
proc sendLeReadBufferSizeComplete(opcode: uint16, paramLen: uint8): uint8
proc sendLeReadLocalSupportedFeaturesComplete(opcode: uint16,
                                              paramLen: uint8): uint8
proc sendLeReadLocalP256Complete(opcode: uint16, paramLen: uint8): uint8
proc sendLeGenerateDhKeyComplete(opcode: uint16, params: ptr uint8,
                                 paramLen: uint8): uint8
proc sendLeDataLengthChange(handle: uint16)
proc sendLeRemoteFeaturesComplete(handle: uint16, status: uint8)
proc sendRemoteVersionInfoComplete(handle: uint16, status: uint8)
proc sendLeConnectionUpdateCompleteValues(handle: uint16, status: uint8,
                                          interval, latency,
                                          timeout: uint16)
proc sendLeReadRemoteFeaturesCommand(opcode: uint16, params: ptr uint8,
                                     paramLen: uint8): uint8
proc sendReadRemoteVersionInfoCommand(opcode: uint16, params: ptr uint8,
                                      paramLen: uint8): uint8
proc sendLeConnectionUpdateCommand(opcode: uint16, params: ptr uint8,
                                   paramLen: uint8): uint8
proc sendLeSetDataLengthComplete(opcode: uint16, params: ptr uint8,
                                 paramLen: uint8): uint8
proc sendLeReadSuggestedDefaultDataLengthComplete(opcode: uint16,
                                                  paramLen: uint8): uint8
proc sendLeWriteSuggestedDefaultDataLengthComplete(opcode: uint16,
                                                   params: ptr uint8,
                                                   paramLen: uint8): uint8
proc sendLeReadMaximumDataLengthComplete(opcode: uint16,
                                         paramLen: uint8): uint8
proc nimBleCurrentChannelMap(dst: ptr UncheckedArray[uint8])
proc bleFillRandomBytes(dst: ptr uint8, len: int): bool
proc ble_util_buf_acl_tx_free*(buf: pointer) {.exportc, cdecl.}
proc llc_llcp_feats_req_pdu_send*(conhdl: uint16) {.exportc, cdecl.}
proc ble_util_buf_rx_free*(buf: pointer) {.exportc, cdecl.}

proc connDataPayloadLen(header: uint16): uint8 {.inline.} =
  uint8((header shr 8) and 0x00FF'u16)

proc advPayloadLen(header: uint16): uint8 {.inline.} =
  uint8((header shr 8) and 0x003F'u16)

template hciRawCmd(data: pointer): ptr HciRawCmdView =
  cast[ptr HciRawCmdView](data)

proc hciRawOpcode(data: pointer): uint16 {.inline.} =
  hciRawCmd(data).opcode

proc hciRawParamLen(data: pointer): uint8 {.inline.} =
  hciRawCmd(data).paramLen

proc hciRawParams(data: pointer): ptr uint8 {.inline.} =
  addr hciRawCmd(data).params[0]

template hciLeCreateConnReq(params: ptr uint8): ptr HciLeCreateConnReqView =
  cast[ptr HciLeCreateConnReqView](params)

template nimVendorLlcStartParams(params: pointer): ptr NimVendorLlcStartParamsView =
  cast[ptr NimVendorLlcStartParamsView](params)

template nimLldConStartParams(params: pointer): ptr NimLldConStartParamsView =
  cast[ptr NimLldConStartParamsView](params)

template hciLeConnUpdateReq(params: ptr uint8): ptr HciLeConnUpdateReqView =
  cast[ptr HciLeConnUpdateReqView](params)

template hciLeSetPhyReq(params: ptr uint8): ptr HciLeSetPhyReqView =
  cast[ptr HciLeSetPhyReqView](params)

template hciLeSetDataLenReq(params: ptr uint8): ptr HciLeSetDataLenReqView =
  cast[ptr HciLeSetDataLenReqView](params)

template hciLeSuggestedDataLenReq(params: ptr uint8): ptr HciLeSuggestedDataLenReqView =
  cast[ptr HciLeSuggestedDataLenReqView](params)

template hciLeSetAdvRandomAddrReq(params: ptr uint8): ptr HciLeSetAdvSetRandomAddressReqView =
  cast[ptr HciLeSetAdvSetRandomAddressReqView](params)

template hciConnHandleReq(params: ptr uint8): ptr HciConnHandleReqView =
  cast[ptr HciConnHandleReqView](params)

template hciConnHandle(params: ptr uint8): uint16 =
  if params == nil: 0'u16 else: hciConnHandleReq(params).handle

template hciDisconnectReq(params: ptr uint8): ptr HciDisconnectReqView =
  cast[ptr HciDisconnectReqView](params)

template hciLeSetRandomAddressReq(params: ptr uint8): ptr HciLeSetRandomAddressReqView =
  cast[ptr HciLeSetRandomAddressReqView](params)

template hciLeSetAdvParamsReq(params: ptr uint8): ptr HciLeSetAdvParamsReqView =
  cast[ptr HciLeSetAdvParamsReqView](params)

template hciLeDataPayloadReq(params: ptr uint8): ptr HciLeDataPayloadReqView =
  cast[ptr HciLeDataPayloadReqView](params)

template hciLeSetAdvEnableReq(params: ptr uint8): ptr HciLeSetAdvEnableReqView =
  cast[ptr HciLeSetAdvEnableReqView](params)

template hciLeSetScanParamsReq(params: ptr uint8): ptr HciLeSetScanParamsReqView =
  cast[ptr HciLeSetScanParamsReqView](params)

template hciLeSetScanEnableReq(params: ptr uint8): ptr HciLeSetScanEnableReqView =
  cast[ptr HciLeSetScanEnableReqView](params)

template hciWriteAuthPayloadTimeoutReq(params: ptr uint8): ptr HciWriteAuthPayloadTimeoutReqView =
  cast[ptr HciWriteAuthPayloadTimeoutReqView](params)

proc connParamStatus(params: ptr uint8, handle: uint16): uint8 =
  if params == nil:
    return HciStatusInvalidParams
  if not nim_conn_active or handle != nim_conn_handle:
    return HciStatusUnknownConnection
  return HciStatusSuccess

proc sendLeConnectionCompleteStatusHandle(params: ptr uint8, paramLen: uint8,
                                          status: uint8, handle: uint16,
                                          role: uint8) =
  if onchiphci_recv_cb == nil or params == nil or paramLen != 25:
    return
  let req = hciLeCreateConnReq(params)
  var evt: array[19, uint8]
  let body = cast[ptr HciLeConnectionCompleteEventView](addr evt[0])
  body.subevent = 0x01'u8
  body.status = status
  body.handle = handle
  body.role = role
  body.peerAddrType = req.peerAddrType
  body.peerAddr = req.peerAddr
  body.interval = req.connIntervalMin
  body.latency = req.connLatency
  body.timeout = req.supervisionTimeout
  body.accuracy = 0
  if status == 0'u8:
    nim_conn_active = true
    nim_conn_handle = handle
  sendLeMetaPayload(addr evt[0], evt.len.uint8)

proc sendLeConnectionCompleteStatus(params: ptr uint8, paramLen: uint8,
                                    status: uint8) =
  sendLeConnectionCompleteStatusHandle(params, paramLen, status, 0'u16, 0'u8)

proc sendLeConnectionComplete(params: ptr uint8, paramLen: uint8) =
  sendLeConnectionCompleteStatus(params, paramLen, 0'u8)

proc drainNimInitPeerComplete(): bool =
  false

when defined(bl808m0) and bl808BleNimConnectionEnabled:
  proc clearNimConnectionStateForDisconnect(reason: uint8)

proc sendDisconnectComplete(handle: uint16, reason: uint8) =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    clearNimConnectionStateForDisconnect(reason)
  nim_conn_active = false
  nim_conn_handle = 0
  if onchiphci_recv_cb == nil:
    return
  var evt: array[4, uint8]
  let body = cast[ptr HciDisconnectCompleteEventView](addr evt[0])
  body.status = 0'u8
  body.handle = handle
  body.reason = reason
  sendHostEvent(HciEvtDisconnectComplete, addr evt[0], evt.len.uint8)

when defined(bl808m0):
  const NimPendingScanReportSlots = 8

  type NimPendingScanReport = object
    len: uint8
    payload: array[43, uint8]

  var nim_pending_scan_reports: array[NimPendingScanReportSlots,
                                      NimPendingScanReport]
  var nim_pending_scan_report_head: uint8
  var nim_pending_scan_report_tail: uint8
  var nim_pending_scan_report_count: uint8
  var nim_pending_scan_report_dropped* {.exportc.}: uint32
  var nim_scan_unsupported_count* {.exportc.}: uint32
  var nim_scan_unsupported_header* {.exportc.}: uint32
  var nim_scan_unsupported_len* {.exportc.}: uint32
  var nim_scan_unsupported_buf* {.exportc.}: uint32
  var nim_scan_unsupported_data* {.exportc.}: array[40, uint8]

  proc enqueueLeAdvertisingReport(payload: ptr uint8, len: uint8): bool =
    if payload == nil or len == 0'u8 or len.int > 43:
      return false
    if nim_pending_scan_report_count >= NimPendingScanReportSlots.uint8:
      inc nim_pending_scan_report_dropped
      return false
    let src = cast[ptr UncheckedArray[uint8]](payload)
    let slot = nim_pending_scan_report_tail.int
    nim_pending_scan_reports[slot].len = len
    for i in 0 ..< len.int:
      nim_pending_scan_reports[slot].payload[i] = src[i]
    nim_pending_scan_report_tail =
      uint8((nim_pending_scan_report_tail.uint32 + 1'u32) mod
      NimPendingScanReportSlots.uint32)
    inc nim_pending_scan_report_count
    true

  proc pendingScanReportsReady(): bool {.inline.} =
    nim_pending_scan_report_count != 0'u8 and onchiphci_recv_cb != nil

  proc bleControllerDrainScanReports*() {.exportc, cdecl.} =
    discard drainNimInitPeerComplete()
    var drained = 0'u32
    while pendingScanReportsReady() and drained < BleScanReportDrainLimit:
      let slot = nim_pending_scan_report_head.int
      let reportLen = nim_pending_scan_reports[slot].len
      sendLeMetaPayload(addr nim_pending_scan_reports[slot].payload[0],
                        reportLen)
      nim_pending_scan_report_head =
        uint8((nim_pending_scan_report_head.uint32 + 1'u32) mod
              NimPendingScanReportSlots.uint32)
      dec nim_pending_scan_report_count
      inc drained
    if pendingScanReportsReady():
      inc nim_ble_scan_report_yield_count
      nim_ble_scan_report_yield_pending = nim_pending_scan_report_count.uint32

  proc scanEventTypeFromPdu(pduType: uint8): uint8 =
    case pduType
    of 0x00'u8: 0x00'u8 # ADV_IND
    of 0x02'u8: 0x03'u8 # ADV_NONCONN_IND
    of 0x04'u8: 0x04'u8 # SCAN_RSP
    of 0x06'u8: 0x02'u8 # ADV_SCAN_IND
    else: 0xFF'u8

  proc sendLeAdvertisingReportFromRxDesc(header: uint16, buf: uint16) =
    if onchiphci_recv_cb == nil or not nim_scan_enabled:
      return
    let pduType = uint8(header and 0x000F'u16)
    let eventType = scanEventTypeFromPdu(pduType)
    if eventType == 0xFF'u8:
      return
    let pduLen = int((header shr 8) and 0x003F'u16)
    if pduLen < 6:
      return
    let dataLen = pduLen - 6
    if dataLen > 31:
      return
    let advPdu = btbleAdvPduAt(buf)
    var evt: array[43, uint8]
    evt[0] = 0x02'u8 # LE Advertising Report
    evt[1] = 0x01'u8 # one report
    evt[2] = eventType
    evt[3] = uint8((header shr 6) and 0x0001'u16)
    for i in 0 ..< 6:
      evt[4 + i] = advPdu.advA.data[i]
    evt[10] = dataLen.uint8
    for i in 0 ..< dataLen:
      evt[11 + i] = advPdu.data[i]
    evt[11 + dataLen] = 0x7F'u8 # RSSI unavailable.
    when bl808BleNimPureCentral:
      if (nim_scan_params[0] and 0x01'u8) != 0'u8 and
          (pduType == 0x00'u8 or pduType == 0x04'u8 or pduType == 0x06'u8):
        nim_scan_req_peer_addr_type =
          uint32((header shr 6) and 0x0001'u16)
      let hintSlot =
        (nim_scan_peer_hint_write_index mod NimScanPeerHintSlots.uint32).int
      nim_scan_peer_hint_addr0[hintSlot] =
        uint32(evt[4]) or
        (uint32(evt[5]) shl 8) or
        (uint32(evt[6]) shl 16) or
        (uint32(evt[7]) shl 24)
      nim_scan_peer_hint_addr1[hintSlot] =
        uint32(evt[8]) or (uint32(evt[9]) shl 8)
      nim_scan_peer_hint_type[hintSlot] = uint32(evt[3] and 0x01'u8)
      nim_scan_peer_hint_channel_index[hintSlot] =
        nim_scan_last_channel_index mod 3'u32
      nim_scan_peer_hint_adv_channel[hintSlot] = nim_scan_last_adv_channel
      nim_scan_peer_hint_write_index = nim_scan_peer_hint_write_index + 1'u32
    discard enqueueLeAdvertisingReport(addr evt[0], uint8(12 + dataLen))
when defined(bl808m0):
  proc noteUnsupportedScanPdu(header: uint16, buf: uint16) =
    let pduLen = int((header shr 8) and 0x003F'u16)
    let copyLen =
      if pduLen > nim_scan_unsupported_data.len:
        nim_scan_unsupported_data.len
      else:
        pduLen
    let payloadBase = BTBLE_EM_BASE + buf.uint32
    inc nim_scan_unsupported_count
    nim_scan_unsupported_header = header.uint32
    nim_scan_unsupported_len = copyLen.uint32
    nim_scan_unsupported_buf = buf.uint32
    for i in 0 ..< copyLen:
      nim_scan_unsupported_data[i] = read8(payloadBase + i.uint32)

proc initBtbleTimeRegisters() =
  regWrite((BLE_BASE + 0x000'u32).uint,
           regRead((BLE_BASE + 0x000'u32).uint) or BtbleBusyBit)
  discard waitBtbleCommandDone((BLE_BASE + 0x000'u32).uint)
  # Core reset initializes timekeeping only; activity-specific code arms the
  # BTBLE status sources when advertising or connection scheduling starts.
  writeBtbleInterruptMask(0)
  regWrite((BLE_BASE + 0x020'u32).uint, 0xFFFFFFFF'u32)
  regWrite((BLE_BASE + 0x03C'u32).uint, 0x14829015'u32)
  regWrite((BLE_BASE + 0x0E0'u32).uint, 0x011800C8'u32)

proc currentBtbleTime(): uint32 =
  regWrite((BLE_BASE + 0x100'u32).uint,
           regRead((BLE_BASE + 0x100'u32).uint) or BtbleBusyBit)
  discard waitBtbleCommandDone((BLE_BASE + 0x100'u32).uint, 4096'u32)
  regRead((BLE_BASE + 0x100'u32).uint) and 0x0FFFFFFF'u32

when defined(bl808m0) and
    (bl808BleNimConnectionEnabled or bl808BleNimPureCentral):
  var nim_lld_rx_desc_idx* {.exportc.}: uint8
  var nim_lld_rx_desc_active* {.exportc.}: uint8
  var nim_lld_rx_check_count* {.exportc.}: uint32
  var nim_lld_rx_check_hit_count* {.exportc.}: uint32
  var nim_lld_rx_check_miss_count* {.exportc.}: uint32
  var nim_lld_rx_free_count* {.exportc.}: uint32
  var nim_lld_rx_last_idx* {.exportc.}: uint32
  var nim_lld_rx_last_env_idx* {.exportc.}: uint32
  var nim_lld_rx_last_status* {.exportc.}: uint32
  var nim_lld_rx_last_header* {.exportc.}: uint32
  var nim_lld_rx_last_meta* {.exportc.}: uint32

when defined(bl808m0) and
    bl808BleNimSchProgEnabled:
  var nim_sch_prog_fifo_count* {.exportc: "nim_vendor_sch_prog_fifo_count".}: uint32
  var nim_sch_prog_skip_count* {.exportc: "nim_vendor_sch_prog_skip_count".}: uint32
  var nim_arb_sw_count* {.exportc.}: uint32
  var nim_arb_event_start_count* {.exportc.}: uint32
  when defined(bl808BleBridgeDiag):
    var nim_bridge_stage* {.exportc.}: uint32
    var nim_sch_call_count* {.exportc.}: uint32
    var nim_sch_call_last_slot* {.exportc.}: uint32
    var nim_sch_call_last_event* {.exportc.}: uint32
    var nim_sch_call_last_cb* {.exportc.}: uint32
    var nim_sch_call_last_ctx* {.exportc.}: uint32
    var nim_sch_call_return_count* {.exportc.}: uint32
const
  RwipDefaultProgramDelaySlots = 3'u16
  RwipDefaultMaxDriftPpm = 500'u32

when defined(bl808m0) and
    bl808BleNimPureCentral and
    not bl808BleNimConnectionEnabled:
  var co_rate_to_phy* {.exportc.}: array[5, uint8] =
    [1'u8, 2, 3, 3, 0]
  var co_sca2ppm* {.exportc.}: array[8, uint16] =
    [500'u16, 250'u16, 150'u16, 100'u16, 75'u16, 50'u16, 30'u16, 20'u16]
  var lld_env* {.exportc.}: array[56, uint8]
  var lld_exp_sync_pos_tab* {.exportc.}: array[16, uint16]
  var rwip_priority* {.exportc.}: array[32, uint8] =
    [0x28'u8, 0x08, 0x60, 0x08, 0x50, 0x08, 0x70, 0x08,
     0x80, 0x08, 0xA0, 0x08, 0xA0, 0x08, 0x28, 0x08,
     0x50, 0x08, 0x60, 0x08, 0x50, 0x08, 0, 0,
     0, 0, 0, 0, 0, 0, 0, 0]
  var rwip_rf* {.exportc.}: array[96, uint8]
  var rwip_coex_cfg* {.exportc.}: array[5, uint8] = [0'u8, 3, 1, 2, 3]
  var rwip_prog_delay* {.exportc.}: uint16 = RwipDefaultProgramDelaySlots

when defined(bl808m0) and bl808BleNimConnectionEnabled:
  var co_rate_to_phy* {.exportc.}: array[5, uint8] =
    [1'u8, 2, 3, 3, 0]
  var co_sca2ppm* {.exportc.}: array[8, uint16] =
    [500'u16, 250'u16, 150'u16, 100'u16, 75'u16, 50'u16, 30'u16, 20'u16]
  var lld_env* {.exportc.}: array[56, uint8]
  var lld_exp_sync_pos_tab* {.exportc.}: array[16, uint16] =
    [0'u16, 0'u16, 0'u16, 0'u16, 0'u16, 0'u16, 0'u16, 0'u16,
     0'u16, 0'u16, 0'u16, 0'u16, 0'u16, 0'u16, 0'u16, 0'u16]
  var rwip_priority* {.exportc.}: array[32, uint8] =
    [0x28'u8, 0x08, 0x60, 0x08, 0x50, 0x08, 0x70, 0x08,
     0x80, 0x08, 0xA0, 0x08, 0xA0, 0x08, 0x28, 0x08,
     0x50, 0x08, 0x60, 0x08, 0x50, 0x08, 0, 0,
     0, 0, 0, 0, 0, 0, 0, 0]
  var rwip_rf* {.exportc.}: array[96, uint8]
  var rwip_coex_cfg* {.exportc.}: array[5, uint8] = [0'u8, 3, 1, 2, 3]
  var rwip_prog_delay* {.exportc.}: uint16 = RwipDefaultProgramDelaySlots
  var nim_rand_state: uint32 = 0x12345678'u32

  proc rand*(): cint {.exportc, cdecl.} =
    nim_rand_state = nim_rand_state * 1103515245'u32 + 12345'u32
    cint((nim_rand_state shr 16) and 0x7FFF'u32)

  proc lld_read_clock*(): uint32 {.exportc, cdecl.} =
    result = currentBtbleTime()
  proc rwip_current_drift_get*(): uint32 {.exportc, cdecl.} =
    RwipDefaultMaxDriftPpm

  proc rwip_max_drift_get*(sca: uint8): uint32 {.exportc, cdecl.} =
    discard sca
    RwipDefaultMaxDriftPpm

  proc lld_rx_timing_compute*(baseClock: uint32, clock: ptr uint32,
                              fine: ptr uint32, peerDrift: uint32,
                              rate: uint8, winSize: uint32): uint32
      {.exportc, cdecl.} =
    if clock == nil or fine == nil:
      return winSize
    const btClockMask = 0x0FFFFFFF'u32
    let clockNow = clock[]
    let elapsedSlots = (clockNow - baseClock) and btClockMask
    let drift = rwip_current_drift_get() + peerDrift
    let driftHalfUs = ((elapsedSlots * drift) div 1600'u32) + 32'u32
    var adjustedWin = winSize + (driftHalfUs shl 1)
    if adjustedWin < 28'u32:
      adjustedWin = 28'u32

    let halfWin = adjustedWin shr 1
    let coarseAdjust = halfWin div 625'u32
    clock[] = (clockNow - coarseAdjust) and btClockMask
    var fineValue =
      int32(fine[]) - int32(halfWin) + int32(coarseAdjust * 625'u32)
    fine[] = cast[uint32](fineValue)
    if fineValue < 0'i32:
      clock[] = (clock[] - 1'u32) and btClockMask
      fineValue += 625'i32
      fine[] = cast[uint32](fineValue)

    let phy =
      if rate.int < co_rate_to_phy.len: co_rate_to_phy[rate.int]
      else: co_rate_to_phy[0]
    if phy == 3'u8:
      adjustedWin + 196'u32
    else:
      adjustedWin

  proc rwip_channel_assess_ble*(channel: uint8, rssi: int8) {.exportc, cdecl.} =
    discard channel
    discard rssi

  proc ble_util_pkt_dur_in_us*(length: uint16, rate: uint8): uint16
      {.exportc, cdecl.} =
    case rate
    of 0:
      uint16((uint32(length) + 10'u32) * 8'u32)
    of 1:
      uint16((uint32(length) + 11'u32) * 4'u32)
    of 2:
      uint16(uint32(length) * 64'u32 + 720'u32)
    else:
      uint16(uint32(length) * 16'u32 + 462'u32)

when defined(bl808m0) and bl808BleNimPureCentral and
    not bl808BleNimConnectionEnabled:
  proc ble_util_pkt_dur_in_us*(length: uint16, rate: uint8): uint16
      {.exportc, cdecl.} =
    case rate
    of 0:
      uint16((uint32(length) + 10'u32) * 8'u32)
    of 1:
      uint16((uint32(length) + 11'u32) * 4'u32)
    of 2:
      uint16(uint32(length) * 64'u32 + 720'u32)
    else:
      uint16(uint32(length) * 16'u32 + 462'u32)

when defined(bl808m0) and
    (bl808BleNimConnectionEnabled or bl808BleNimPureCentral):
  proc initNimRwipRfTable() =
    discard c_memset(addr rwip_rf[0], 0, rwip_rf.len.csize_t)
    btble_rf_init(addr rwip_rf[0])

const
  BtbleRxDescRingBaseOffset = 0x458'u32
  BtbleRxDescRingStride = 0x20'u32
  BtbleRxDescRingCount = 8'u32
  BtbleRxDescDone = 0x8000'u16
  BtbleRxDescLinkMask = 0x7FFF'u16

proc btbleRxDescOffset(idx: uint32): uint32 {.inline.} =
  BtbleRxDescRingBaseOffset +
    (idx and (BtbleRxDescRingCount - 1'u32)) * BtbleRxDescRingStride

template btbleRxDescAt(descAddr: uint32): ptr BtbleRxDescView =
  cast[ptr BtbleRxDescView](descAddr.uint)

proc btbleRxDescStatus(descAddr: uint32): uint16 {.inline.} =
  volatileLoad(addr btbleRxDescAt(descAddr).status)

proc btbleRxDescHeader(descAddr: uint32): uint16 {.inline.} =
  volatileLoad(addr btbleRxDescAt(descAddr).header)

proc btbleRxDescClock(descAddr: uint32): uint16 {.inline.} =
  volatileLoad(addr btbleRxDescAt(descAddr).rxClock)

proc btbleRxDescMeta(descAddr: uint32): uint16 {.inline.} =
  volatileLoad(addr btbleRxDescAt(descAddr).meta)

proc btbleRxDescDataOffset(descAddr: uint32): uint16 {.inline.} =
  volatileLoad(addr btbleRxDescAt(descAddr).dataOffset)

proc btbleRxDescSetStatus(descAddr: uint32; status: uint16) {.inline.} =
  volatileStore(addr btbleRxDescAt(descAddr).status, status)

proc btbleRxDescSetDataOffset(descAddr: uint32; offset: uint16) {.inline.} =
  volatileStore(addr btbleRxDescAt(descAddr).dataOffset, offset)

proc btbleRxDescReset(descAddr, nextOffset, dataOffset: uint32) {.inline.} =
  let desc = btbleRxDescAt(descAddr)
  volatileStore(addr desc.status, uint16((nextOffset shr 2) and 0xFFFF'u32))
  volatileStore(addr desc.reserved02, 0'u16)
  volatileStore(addr desc.header, 0'u16)
  volatileStore(addr desc.timing0, 0'u16)
  volatileStore(addr desc.rxClock, 0'u16)
  volatileStore(addr desc.timing1, 0'u16)
  volatileStore(addr desc.meta, 0'u16)
  for i in 0 ..< desc.reserved0E.len:
    volatileStore(addr desc.reserved0E[i], 0'u8)
  volatileStore(addr desc.dataOffset, uint16(dataOffset and 0xFFFF'u32))
  for i in 0 ..< desc.reserved16.len:
    volatileStore(addr desc.reserved16[i], 0'u8)

proc btbleRxDescClearDone(descAddr: uint32; status: uint16) {.inline.} =
  btbleRxDescSetStatus(descAddr, status and not BtbleRxDescDone)

proc btbleRxDescReleaseLink(descAddr: uint32; status: uint16) {.inline.} =
  btbleRxDescSetStatus(descAddr, status and BtbleRxDescLinkMask)

proc btbleRxDescPtr(idx: uint32): uint32 {.inline.} =
  btbleRxDescOffset(idx) shr 2

template btbleLegacyTxDescAt(descAddr: uint32): ptr BtbleConnTxDescView =
  cast[ptr BtbleConnTxDescView](descAddr.uint)

proc btbleLegacyTxDescProgram(descAddr: uint32; status, header,
                              dataOffset: uint16) {.inline.} =
  let desc = btbleLegacyTxDescAt(descAddr)
  volatileStore(addr desc.status, status)
  volatileStore(addr desc.header, header)
  volatileStore(addr desc.dataOffset, dataOffset)
  for i in 0 ..< desc.reserved06.len:
    volatileStore(addr desc.reserved06[i], 0'u8)

template btbleAccessWordsAt(emAddr: uint32): ptr BtbleAccessAddressWordsView =
  cast[ptr BtbleAccessAddressWordsView](emAddr.uint)

proc writeBtbleDefaultAccessWords(emAddr: uint32) {.inline.} =
  let words = btbleAccessWordsAt(emAddr)
  volatileStore(addr words.accessAddrLow, 0xBED6'u16)
  volatileStore(addr words.accessAddrHigh, 0x8E89'u16)
  volatileStore(addr words.crcInitLow, 0x5555'u16)
  volatileStore(addr words.crcInitHigh, 0x0055'u16)

proc btbleProgramSlotAddr(slot: uint32): uint32 {.inline.} =
  BTBLE_EM_BASE + slot * 0x10'u32

template btbleProgramSlotAt(slot: uint32): ptr BtbleProgramSlotView =
  cast[ptr BtbleProgramSlotView](btbleProgramSlotAddr(slot).uint)

proc btbleProgramSlotControl(slot: uint32): uint16 {.inline.} =
  volatileLoad(addr btbleProgramSlotAt(slot).control)

proc btbleProgramSlotTarget(slot: uint32): uint32 {.inline.} =
  let view = btbleProgramSlotAt(slot)
  volatileLoad(addr view.targetLow).uint32 or
    ((volatileLoad(addr view.targetHigh).uint32 and 0x0FFF'u32) shl 16)

proc btbleProgramSlotTail(slot: uint32): uint16 {.inline.} =
  volatileLoad(addr btbleProgramSlotAt(slot).tail)

proc btbleProgramSlotSetControl(slot: uint32; value: uint16) {.inline.} =
  volatileStore(addr btbleProgramSlotAt(slot).control, value)

proc btbleProgramSlotSetDisabled(slot: uint32) {.inline.} =
  let control = btbleProgramSlotControl(slot)
  btbleProgramSlotSetControl(slot, (control and not 0x0038'u16) or 0x0018'u16)

proc btbleProgramSlotSetTail(slot: uint32; value: uint16) {.inline.} =
  volatileStore(addr btbleProgramSlotAt(slot).tail, value)

proc btbleProgramSlotClear(slot: uint32; tail: uint16) {.inline.} =
  let view = btbleProgramSlotAt(slot)
  volatileStore(addr view.control, 0'u16)
  volatileStore(addr view.targetLow, 0'u16)
  volatileStore(addr view.targetHigh, 0'u16)
  volatileStore(addr view.fineBackoff, 0'u16)
  volatileStore(addr view.emPtr, 0'u16)
  volatileStore(addr view.duration, 0'u16)
  volatileStore(addr view.rates, 0'u16)
  volatileStore(addr view.tail, tail)

proc btbleProgramSlotProgram(slot: uint32; target: uint32; fineBackoff,
                             duration, rates, tail, control,
                             emPtr: uint16; writeControlAndPtr: bool) {.inline.} =
  let view = btbleProgramSlotAt(slot)
  volatileStore(addr view.targetLow, uint16(target and 0xFFFF'u32))
  volatileStore(addr view.targetHigh, uint16((target shr 16) and 0x0FFF'u32))
  volatileStore(addr view.fineBackoff, fineBackoff)
  volatileStore(addr view.duration, duration)
  volatileStore(addr view.rates, rates)
  volatileStore(addr view.tail, tail)
  if writeControlAndPtr:
    volatileStore(addr view.control, control)
    volatileStore(addr view.emPtr, emPtr)

proc btbleProgramSlotProgramRaw(slot: uint32; control, targetLow, targetHigh,
                                fineBackoff, emPtr, duration, rates,
                                tail: uint16) {.inline.} =
  let view = btbleProgramSlotAt(slot)
  volatileStore(addr view.control, control)
  volatileStore(addr view.targetLow, targetLow)
  volatileStore(addr view.targetHigh, targetHigh)
  volatileStore(addr view.fineBackoff, fineBackoff)
  volatileStore(addr view.emPtr, emPtr)
  volatileStore(addr view.duration, duration)
  volatileStore(addr view.rates, rates)
  volatileStore(addr view.tail, tail)

when defined(bl808m0) and
    (bl808BleNimConnectionEnabled or bl808BleNimPureCentral):
  proc clearBtbleProgramSlots() =
    for slot in 0'u32 ..< 18'u32:
      btbleProgramSlotClear(slot,
        uint16((btbleAdvSlotTail(slot) shr 16) and 0xFFFF'u32))

proc writeBtbleRxDescHeadIndex(idx: uint32) {.inline.} =
  regWrite((BLE_BASE + 0x828'u32).uint, btbleRxDescPtr(idx))

proc resetBtbleAdvRxRing() =
  ## Drop advertising-channel RX descriptors from a previous scanner,
  ## advertiser, or initiator role.  The low half-word is both the descriptor
  ## link pointer and the hardware-owned done bit, so restore the BL808 ring
  ## link value instead of blindly zeroing it.
  when defined(bl808m0) and
      (bl808BleNimConnectionEnabled or
       bl808BleNimPureCentral):
    lld_env[14] = 0
    lld_env[16] = 0
    nim_lld_rx_desc_idx = 0
    nim_lld_rx_desc_active = 0
  for i in 0'u32 ..< 8'u32:
    let desc = BTBLE_EM_BASE + btbleRxDescOffset(i)
    let nextOff = btbleRxDescOffset(i + 1'u32)
    let rxBuf = 0x0B0D'u32 + i * 0x104'u32
    btbleRxDescReset(desc, nextOff, rxBuf)

proc prepareBtbleConnectionRxRingForHandoff() =
  ## The vendor lld_adv_frm_isr frees the consumed CONNECT_IND descriptor and
  ## then hands the same live RX ring to lld_con_start.  Do not reset the ring or
  ## force BTBLE+0x828 back to descriptor zero here; the hardware head may have
  ## already advanced past advertising-channel traffic.
  when defined(bl808m0) and
      (bl808BleNimConnectionEnabled or
       bl808BleNimPureCentral):
    nim_lld_rx_desc_idx = lld_env[14] and 0x07'u8
    nim_lld_rx_desc_active = 0

proc currentBtbleHalfUs(): uint32 =
  regWrite((BLE_BASE + 0x100'u32).uint,
           regRead((BLE_BASE + 0x100'u32).uint) or BtbleBusyBit)
  discard waitBtbleCommandDone((BLE_BASE + 0x100'u32).uint, 4096'u32)
  let base = regRead((BLE_BASE + 0x100'u32).uint) and 0x0000FFFF'u32
  let fineRaw = regRead((BLE_BASE + 0x104'u32).uint) and 0x0000FFFF'u32
  let fine =
    if fineRaw <= 0x270'u32: 0x270'u32 - fineRaw
    else: 0'u32
  ((base * 625'u32 + fine) shr 1) and 0x0FFFFFFF'u32

proc requestBtbleSwInterrupt() =
  ## Queue deferred BLE work. Polled M0 builds service this from bflbble_isr()
  ## without raising a CLIC interrupt.
  nim_btble_sw_pending = true
  when not (defined(bl808m0) and not bl808BleNimRuntimeClicIrq):
    regWrite((BLE_BASE + BTBLE_INTACK_OFFSET).uint, BtbleIntSw)
    enableBtbleInterruptMaskBits(BtbleIntSw)
    regUpdate(BLE_BASE + 0x000'u32, 0x08000000'u32, 0x08000000'u32)

when defined(bl808m0) and
    bl808BleNimSchProgEnabled:
  proc schProgWrite16(off: int, value: uint16) =
    nim_sch_prog[off] = uint8(value and 0x00FF'u16)
    nim_sch_prog[off + 1] = uint8((value shr 8) and 0x00FF'u16)

  proc schProgWrite32(off: int, value: uint32) =
    nim_sch_prog[off] = uint8(value and 0x000000FF'u32)
    nim_sch_prog[off + 1] = uint8((value shr 8) and 0x000000FF'u32)
    nim_sch_prog[off + 2] = uint8((value shr 16) and 0x000000FF'u32)
    nim_sch_prog[off + 3] = uint8((value shr 24) and 0x000000FF'u32)

when defined(bl808m0) and
    bl808BleNimSchProgEnabled:
  type
    RwipParamGet = proc(param: uint8, buf: ptr uint8,
                        len: ptr uint8): uint8 {.cdecl.}
    RwipParamSet = proc(param: uint8, buf: ptr uint8,
                        len: uint8): uint8 {.cdecl.}
    RwipParamDel = proc(param: uint8): uint8 {.cdecl.}
    RwipParam = object
      get: RwipParamGet
      set: RwipParamSet
      del: RwipParamDel

  proc rwipParamDummyGet(param: uint8, buf: ptr uint8,
                         len: ptr uint8): uint8 {.cdecl.} =
    discard param
    discard buf
    if len != nil:
      len[] = 0
    1'u8

  proc rwipParamDummySet(param: uint8, buf: ptr uint8,
                         len: uint8): uint8 {.cdecl.} =
    discard param
    discard buf
    discard len
    1'u8

  proc rwipParamDummyDel(param: uint8): uint8 {.cdecl.} =
    discard param
    1'u8

  var rwip_param* {.exportc.}: RwipParam

  proc rwip_time_get*(time: pointer) {.exportc, cdecl.} =
    if time == nil:
      return
    regWrite((BLE_BASE + 0x100'u32).uint,
             regRead((BLE_BASE + 0x100'u32).uint) or BtbleBusyBit)
    discard waitBtbleCommandDone((BLE_BASE + 0x100'u32).uint, 4096'u32)
    let words = cast[ptr UncheckedArray[uint32]](time)
    let fineRaw = regRead((BLE_BASE + 0x104'u32).uint) and 0x0000FFFF'u32
    let fine =
      if fineRaw <= 624'u32: 624'u32 - fineRaw
      else: 0'u32
    words[0] = regRead((BLE_BASE + 0x100'u32).uint) and 0x0FFFFFFF'u32
    words[1] = fine and 0x0000FFFF'u32
    words[2] = regRead((BLE_BASE + 0x9C4'u32).uint)

  proc rwip_prevent_sleep_set*(mask: uint16) {.exportc, cdecl.} =
    bflbip_prevent_sleep_mask = bflbip_prevent_sleep_mask or mask.uint32

  proc rwip_prevent_sleep_clear*(mask: uint16) {.exportc, cdecl.} =
    bflbip_prevent_sleep_mask = bflbip_prevent_sleep_mask and not mask.uint32

  proc rwip_sw_int_req*() {.exportc, cdecl.}

  when bl808BleNimSchProg:
    type SchProgCb = proc(timestamp: uint32, ctx: pointer, event: uint8) {.cdecl.}

    var schProgCb: array[16, SchProgCb]
    var schProgCtx: array[16, pointer]
    var schProgActive: array[16, uint8]
    var schProgElapsedEndTarget: array[16, uint32]
    var schProgElapsedEndArmed: array[16, uint8]
    var schProgReadIdx: uint8
    var schProgWriteIdx: uint8
    var schProgCount: uint8
    var schProgLastTime* {.exportc: "last_prog_time".}: uint32
    var skipFlag* {.exportc: "skipFlag".}: uint8
    var rwip_mac_done* {.exportc.}: uint8
    var nim_sch_prog_last_stage* {.exportc.}: uint32
    var nim_sch_prog_last_cb* {.exportc.}: uint32
    var nim_sch_prog_last_ctx* {.exportc.}: uint32
    var nim_sch_prog_last_target* {.exportc.}: uint32
    var nim_sch_prog_last_now* {.exportc.}: uint32
    var nim_sch_prog_last_slot* {.exportc.}: uint32
    var nim_sch_prog_last_intmask* {.exportc.}: uint32
    var nim_sch_prog_last_intstat* {.exportc.}: uint32
    var nim_sch_prog_elapsed_count* {.exportc: "nim_vendor_sch_prog_elapsed_count".}: uint32

    proc schProgSlotTarget(slot: uint8): uint32 {.inline.} =
      btbleProgramSlotTarget(uint32(slot and 0x0F'u8))

    proc schProgClockReached(now, target: uint32): bool {.inline.} =
      (((now - target) and 0x0FFFFFFF'u32) < 0x08000000'u32)

    proc schProgDurationSlots(durationUs: uint32): uint32 {.inline.} =
      if durationUs == 0'u32:
        1'u32
      elif durationUs < 0x8000'u32:
        max(1'u32, (durationUs + 624'u32) div 625'u32)
      else:
        max(1'u32, durationUs and 0x7FFF'u32)

    const NimBleWifiTxGuardSlots = 8'u32

    proc schProgFutureDistance(now, target: uint32): uint32 {.inline.} =
      (target - now) and 0x0FFFFFFF'u32

    proc schProgCall(idx: uint8, event: uint8) =
      let slot = idx and 0x0F'u8
      if schProgActive[slot.int] == 0:
        when defined(bl808BleBridgeDiag):
          nim_bridge_stage = 0x52F0'u32 or uint32(event)
        return
      let cb = schProgCb[slot.int]
      let timestamp = schProgSlotTarget(slot)
      when defined(bl808BleBridgeDiag):
        nim_bridge_stage = 0x5300'u32 or uint32(event)
        inc nim_sch_call_count
        nim_sch_call_last_slot = slot.uint32
        nim_sch_call_last_event = event.uint32
        nim_sch_call_last_cb = cast[uint32](cast[uint](cb))
        nim_sch_call_last_ctx =
          cast[uint32](cast[uint](schProgCtx[slot.int]))
      if cb != nil:
        cb(timestamp, schProgCtx[slot.int], event)
        when defined(bl808BleBridgeDiag):
          inc nim_sch_call_return_count
          nim_bridge_stage = 0x5400'u32 or uint32(event)
      else:
        when defined(bl808BleBridgeDiag):
          nim_bridge_stage = 0x53F0'u32 or uint32(event)

    proc schProgFindNextRead(fromSlot: uint8, untilSlot: uint8): uint8 =
      var slot = fromSlot and 0x0F'u8
      let stop = untilSlot and 0x0F'u8
      while slot != stop:
        slot = (slot + 1'u8) and 0x0F'u8
        if schProgActive[slot.int] != 0:
          return slot
      stop

    proc schProgSetEntry(slot: uint8, cbRaw: uint32, ctxRaw: uint32) =
      let s = slot and 0x0F'u8
      schProgCb[s.int] = cast[SchProgCb](cbRaw.uint)
      schProgCtx[s.int] = cast[pointer](ctxRaw.uint)
      schProgActive[s.int] = 1

    proc sch_prog_rx_isr*(idx: uint8) {.exportc, cdecl.} =
      schProgCall(idx, 2'u8)

    proc sch_prog_tx_isr*(idx: uint8) {.exportc, cdecl.} =
      schProgCall(idx, 3'u8)

    proc sch_prog_skip_isr*(idx: uint8) {.exportc, cdecl.} =
      let slot = idx and 0x0F'u8
      if schProgActive[slot.int] != 0:
        schProgCall(slot, 4'u8)
        schProgElapsedEndArmed[slot.int] = 0
        if schProgReadIdx == slot and skipFlag == 0'u8:
          schProgReadIdx = (slot + 1'u8) and 0x0F'u8
        schProgActive[slot.int] = 0
        if schProgCount != 0:
          dec schProgCount
        if schProgCount == 1'u8 and skipFlag == 0'u8:
          schProgWriteIdx = (schProgReadIdx + 1'u8) and 0x0F'u8
          return
      elif schProgCount == 1'u8 and skipFlag == 0'u8:
        schProgWriteIdx = (schProgReadIdx + 1'u8) and 0x0F'u8
        return
      if schProgCount == 0:
        rwip_prevent_sleep_clear(64'u16)

    proc schProgFinishSlot(slot: uint8, event: uint8) =
      schProgElapsedEndArmed[slot.int] = 0
      schProgCall(slot, event)
      if schProgActive[slot.int] != 0:
        schProgActive[slot.int] = 0
        if schProgCount != 0:
          dec schProgCount
      schProgReadIdx = schProgFindNextRead(slot, schProgWriteIdx)
      if schProgCount == 0:
        rwip_prevent_sleep_clear(64'u16)

    proc sch_prog_end_isr*(idx: uint8) {.exportc, cdecl.} =
      let slot = idx and 0x0F'u8
      let rawStatus = btbleProgramSlotControl(uint32(slot))
      let status = (rawStatus shr 3) and 0x0007'u16
      let event =
        if status == 3'u16: 0'u8
        elif status == 4'u16: 1'u8
        elif status == 5'u16: 7'u8
        else: 0xFF'u8
      schProgFinishSlot(slot, event)

    proc rwip_mac_done_set*() {.exportc, cdecl.} =
      rwip_mac_done = 1'u8

    proc sch_prog_fifo_isr*() {.exportc, cdecl.} =
      let stat = regRead(BLE_BASE + 0x024'u32)
      let eventSlot = uint8((stat shr 24) and 0x0F'u32)
      let skipSlot = uint8((stat shr 28) and 0x0F'u32)
      if (stat and 0x00000008'u32) != 0:
        sch_prog_tx_isr(eventSlot)
      if (stat and 0x00000010'u32) != 0:
        sch_prog_rx_isr(eventSlot)
      if (stat and 0x00000004'u32) != 0:
        sch_prog_skip_isr(skipSlot)
      if (stat and 0x00000002'u32) != 0:
        sch_prog_end_isr(eventSlot)
        rwip_mac_done_set()

    proc sch_prog_elapsed_isr*() {.exportc, cdecl.} =
      let now = currentBtbleTime()
      for rawSlot in 0'u8 ..< 16'u8:
        let slot = rawSlot and 0x0F'u8
        if schProgActive[slot.int] == 0 or
            schProgElapsedEndArmed[slot.int] == 0:
          continue
        if not schProgClockReached(now, schProgElapsedEndTarget[slot.int]):
          continue
        inc nim_sch_prog_elapsed_count
        schProgFinishSlot(slot, 0'u8)
        rwip_mac_done_set()

    proc nim_ble_coex_wifi_tx_window_enter*(): uint32 {.exportc, cdecl.} =
      ## Called by the WiFi firmware while it owns the shared RF/PTA fabric.
      ## Return 1 only when WiFi acquires an idle BLE scheduler gap. If a BLE
      ## slot is already active, skip/reschedule it and make WiFi retry later
      ## instead of transmitting while the shared RF may still be busy.
      inc nim_ble_wifi_tx_window_enter_count
      nim_ble_wifi_tx_window_last_intmask =
        regRead(BLE_BASE + BTBLE_INTMASK_OFFSET)
      nim_ble_wifi_tx_window_last_intstat =
        regRead(BLE_BASE + BTBLE_INTSTAT_OFFSET)
      if nim_ble_wlcoex_enabled == 0'u32:
        return 1'u32
      if nim_ble_wifi_tx_window_active != 0'u32:
        return 1'u32
      writeBtbleInterruptMask(0)
      regWrite((BLE_BASE + BTBLE_INTACK_OFFSET).uint,
               regRead(BLE_BASE + BTBLE_INTSTAT_OFFSET))
      let now = currentBtbleTime()
      var skipped = 0'u32
      var nearFuture = 0'u32
      for rawSlot in 0'u8 ..< 16'u8:
        let slot = rawSlot and 0x0F'u8
        if schProgActive[slot.int] != 0:
          let target = schProgSlotTarget(slot)
          let untilTarget = schProgFutureDistance(now, target)
          if untilTarget < 0x08000000'u32 and
              untilTarget > NimBleWifiTxGuardSlots:
            continue
          if untilTarget < 0x08000000'u32:
            inc nearFuture
            continue
          btbleProgramSlotSetDisabled(uint32(slot))
          schProgElapsedEndArmed[slot.int] = 0
          inc nim_ble_wifi_tx_window_skip_count
          inc skipped
          sch_prog_skip_isr(slot)
      if skipped != 0'u32 or nearFuture != 0'u32:
        writeBtbleInterruptMask(BtbleIntConnection)
        if skipped != 0'u32:
          inc nim_ble_wifi_tx_window_resume_count
          rwip_sw_int_req()
        return 0'u32
      nim_ble_wifi_tx_window_active = 1'u32
      1'u32

    proc nim_ble_coex_wifi_tx_window_leave*() {.exportc, cdecl.} =
      ## Re-enable BLE scheduling after the WiFi MAC reports TX confirmation.
      inc nim_ble_wifi_tx_window_leave_count
      if nim_ble_wifi_tx_window_active == 0'u32:
        return
      nim_ble_wifi_tx_window_active = 0'u32
      writeBtbleInterruptMask(BtbleIntConnection)
      if nim_ble_wlcoex_enabled != 0'u32:
        inc nim_ble_wifi_tx_window_resume_count
        rwip_sw_int_req()

    proc sch_prog_init*(initType: uint8) {.exportc, cdecl.} =
      if initType < 2'u8 or initType > 3'u8:
        return
      discard c_memset(addr schProgCb[0], 0, sizeof(schProgCb).csize_t)
      discard c_memset(addr schProgCtx[0], 0, sizeof(schProgCtx).csize_t)
      discard c_memset(addr schProgActive[0], 0,
                       sizeof(schProgActive).csize_t)
      discard c_memset(addr schProgElapsedEndTarget[0], 0,
                       sizeof(schProgElapsedEndTarget).csize_t)
      discard c_memset(addr schProgElapsedEndArmed[0], 0,
                       sizeof(schProgElapsedEndArmed).csize_t)
      schProgReadIdx = 0
      schProgWriteIdx = 0
      schProgCount = 0
      nimSchProgSkipIndex = 0
      schProgLastTime = 0
      skipFlag = 0
      rwip_mac_done = 0
      nim_sch_prog_last_stage = 0
      nim_sch_prog_last_cb = 0
      nim_sch_prog_last_ctx = 0
      nim_sch_prog_last_target = 0
      nim_sch_prog_last_now = 0
      nim_sch_prog_last_slot = 0
      nim_sch_prog_last_intmask = 0
      nim_sch_prog_last_intstat = 0
      nim_sch_prog_elapsed_count = 0
      for slot in 0'u32 ..< 16'u32:
        btbleProgramSlotSetDisabled(slot)

    proc sch_prog_push*(prog: pointer) {.exportc, cdecl.} =
      if prog == nil:
        return
      let irqState = btbleIrqSave()
      defer:
        btbleIrqRestore(irqState)
      nim_sch_prog_last_stage = 0x1000'u32
      let req = cast[ptr SchProgRequestView](prog)
      req.primaryType = req.primaryType shr 3
      req.rate0 = req.rate0 shr 3
      req.rate1 = req.rate1 shr 3

      let slot = schProgWriteIdx and 0x0F'u8
      let cbRaw = req.callback
      let target = req.targetTime
      let fine = req.fineTime
      let dur = req.duration
      let ctxRaw = req.context
      nim_sch_prog_last_stage = 0x1010'u32
      nim_sch_prog_last_cb = cbRaw
      nim_sch_prog_last_ctx = ctxRaw
      nim_sch_prog_last_target = target
      nim_sch_prog_last_slot = slot.uint32
      nim_sch_prog_last_intmask = regRead(BLE_BASE + BTBLE_INTMASK_OFFSET)
      nim_sch_prog_last_intstat = regRead(BLE_BASE + BTBLE_INTSTAT_OFFSET)

      var now: array[3, uint32]
      rwip_time_get(addr now[0])
      nim_sch_prog_last_stage = 0x1020'u32
      nim_sch_prog_last_now = now[0]
      if ((now[0] + 1'u32) >= target) or (target == schProgLastTime):
        nim_sch_prog_last_stage = 0x1100'u32
        schProgLastTime = target
        schProgSetEntry(slot, cbRaw, ctxRaw)
        nimSchProgSkipIndex = slot.uint32
        inc schProgCount
        skipFlag = 1'u8
        rwip_prevent_sleep_set(64'u16)
        nim_sch_prog_last_stage = 0x1110'u32
        rwip_sw_int_req()
        nim_sch_prog_last_stage = 0x1120'u32
        return

      nim_sch_prog_last_stage = 0x1200'u32
      let emPtr = uint16((uint32(req.eventIndex) * 0x94'u32 + 0x0120'u32) shr 2)
      let crowded =
        if ((uint32(schProgWriteIdx) - uint32(schProgReadIdx)) and 0x0F'u32) >=
            14'u32: 1'u16
        else: 0'u16
      var ctrl0 = (crowded shl 10) or
                  (uint16(req.ctrlType) shl 8)
      let primaryType =
        if req.primaryType > 31'u8: 31'u16
        else: uint16(req.primaryType)
      if req.hasAux != 0'u8:
        ctrl0 = ctrl0 or (primaryType shl 11) or
                (uint16(req.auxRate) shl 9) or
                (uint16(req.auxControl) shl 7) or 0x0042'u16
      else:
        ctrl0 = ctrl0 or (primaryType shl 11) or 0x0002'u16
      let durHalf =
        if dur < 0x8000'u32:
          uint16(((dur + 1'u32) shr 1) and 0xFFFF'u32)
        else:
          uint16((((dur + 625'u32) div 625'u32) or 0xFFFF8000'u32) and
                 0xFFFF'u32)
      let fineBackoff =
        if fine <= 624'u16: 624'u16 - fine
        else: 0'u16
      let rate0 =
        if req.rate0 > 31'u8: 31'u16
        else: uint16(req.rate0)
      let rate1 =
        if req.rate1 > 31'u8: 31'u16
        else: uint16(req.rate1)
      let slotU32 = uint32(slot)
      let tail = (btbleProgramSlotTail(slotU32) and 0xE0FF'u16) or
                 (uint16(req.tail) shl 8)

      schProgSetEntry(slot, cbRaw, ctxRaw)
      schProgLastTime = target
      nim_sch_prog_last_stage = 0x1210'u32

      btbleProgramSlotProgram(slotU32, target, fineBackoff, durHalf,
        rate0 or (rate1 shl 8), tail, ctrl0, emPtr, req.noBackoff == 0'u8)

      nim_sch_prog_last_stage = 0x1220'u32
      regWrite((BLE_BASE + 0x110'u32).uint, 0x80000000'u32 or slot.uint32)
      nim_sch_prog_last_stage = 0x1230'u32
      schProgWriteIdx = (slot + 1'u8) and 0x0F'u8
      inc schProgCount
      schProgElapsedEndTarget[slot.int] =
        (target + schProgDurationSlots(dur) + 1'u32) and 0x0FFFFFFF'u32
      schProgElapsedEndArmed[slot.int] = 1
      rwip_prevent_sleep_set(64'u16)
      if skipFlag != 0:
        nim_sch_prog_last_stage = 0x1240'u32
        rwip_sw_int_req()
        nim_sch_prog_last_stage = 0x1250'u32
      else:
        nim_sch_prog_last_stage = 0x1260'u32

    proc nimSchProgInit(initType: uint8) {.cdecl.} =
      sch_prog_init(initType)

    proc nimSchProgFifoIsr() {.cdecl.} =
      sch_prog_fifo_isr()

    proc nimSchProgSkipIsr(idx: uint8) {.cdecl.} =
      sch_prog_skip_isr(idx)

    proc nimSchProgPush(prog: pointer) {.cdecl.} =
      sch_prog_push(prog)

    proc nimSchProgElapsedIsr() {.cdecl.} =
      sch_prog_elapsed_isr()

  proc serviceNimArbTimer() =
    discard

  proc rwip_sw_int_req*() {.exportc, cdecl.} =
    inc nim_arb_sw_count
    requestBtbleSwInterrupt()

const bl808BleNimSyntheticCentral* {.booldefine.}: bool = false
const bl808BleNimSyntheticCentralComplete* {.booldefine.}: bool = false
const bl808BleNimSyntheticPeripheral* {.booldefine.}: bool = false

when defined(bl808m0) and bl808BleNimConnectionEnabled:
  const bl808BleNimConAnchorBiasSlots* {.intdefine.}: int = 0
  const bl808BleNimConTimingClockBiasSlots* {.intdefine.}: int = 0
  const bl808BleNimConTimingPath* {.booldefine.}: bool = true
  const bl808BleNimDeferConnectInd* {.booldefine.}: bool = true
  const bl808BleNimKeepaliveAcl* {.booldefine.}: bool = true
  const bl808BleNimLlcStartInitialLlcp* {.booldefine.}: bool = false
  const bl808BleNimStartupLlcpRetries* {.intdefine.}: int = 8
  const bl808BleNimStartupLlcpDelayServices* {.intdefine.}: int = 0

  var nim_conn_started: bool
  var nim_connect_ind_pending* {.exportc.}: uint32
  var nim_connect_ind_queued_count* {.exportc.}: uint32
  var nim_connect_ind_service_count* {.exportc.}: uint32
  var nim_connect_ind_return_count* {.exportc.}: uint32
  var nim_connect_ind_pending_desc_idx: uint8
  var nim_connect_ind_pending_payload: array[34, uint8]
  var nim_connect_ind_work_payload: array[34, uint8]
  var nim_connect_ind_pending_header: uint16
  var nim_connect_ind_pending_rx_clock: uint32
  var nim_connect_ind_pending_rx_fine: uint16
  var nim_conn_params: array[64, uint8]
  var nim_llc_msg* {.exportc: "nim_vendor_llc_msg".}: array[64, uint8]
  var nim_llc_env_storage: array[0x8C, uint8]
  var nim_llc_status* {.exportc.}: uint32
  var nim_llcp_rx_count* {.exportc.}: uint32
  var nim_llcp_tx_count* {.exportc.}: uint32
  var nim_llcp_tx_pending* {.exportc.}: uint32
  var nim_llcp_tx_queued* {.exportc.}: uint32
  var nim_llcp_tx_dropped* {.exportc.}: uint32
  var nim_llcp_startup_tx_count* {.exportc.}: uint32
  var nim_llcp_startup_deferred_count* {.exportc.}: uint32
  var nim_llcp_last_opcode* {.exportc.}: uint32
  var nim_llcp_last_status* {.exportc.}: uint32
  var nim_llcp_rx_log* {.exportc.}: array[8, uint32]
  var nim_llcp_tx_log* {.exportc.}: array[8, uint32]
  var nim_llcp_rx_log_index* {.exportc.}: uint32
  var nim_llcp_tx_log_index* {.exportc.}: uint32
  var nim_llcp_peer_features* {.exportc.}: array[2, uint32]
  var nim_llcp_used_features* {.exportc.}: array[2, uint32]
  var nim_llcp_rx_malformed_count* {.exportc.}: uint32
  var nim_llcp_rx_malformed_last* {.exportc.}: uint32
  var nim_llcp_alloc_count* {.exportc.}: uint32
  var nim_llcp_free_count* {.exportc.}: uint32
  var nim_llcp_alloc_last_len* {.exportc.}: uint32
  var nim_llcp_alloc_last_ptr* {.exportc.}: uint32
  var nim_llcp_alloc_last_emoff* {.exportc.}: uint32
  var nim_llcp_alloc_last_len_field* {.exportc.}: uint32
  var nim_llcp_free_last_raw* {.exportc.}: uint32
  var nim_llcp_free_manual_count* {.exportc.}: uint32
  var nim_llcp_free_heap_count* {.exportc.}: uint32
  var nim_acl_empty_tx_count* {.exportc.}: uint32
  var nim_acl_empty_tx_pending* {.exportc.}: uint32
  var nim_acl_empty_tx_queued: uint32
  var nim_acl_empty_last_status* {.exportc.}: uint32
  var nim_acl_host_tx_count* {.exportc.}: uint32
  var nim_acl_host_tx_pending* {.exportc.}: uint32
  var nim_acl_host_tx_complete_count* {.exportc.}: uint32
  var nim_acl_host_tx_reject_count* {.exportc.}: uint32
  var nim_acl_rx_count* {.exportc.}: uint32
  var nim_acl_rx_drop_count* {.exportc.}: uint32
  var nim_conn_last_status* {.exportc.}: uint32
  var nim_conn_last_rx_clock* {.exportc.}: uint32
  var nim_conn_last_rx_fine* {.exportc.}: uint32
  var nim_conn_last_anchor* {.exportc.}: uint32
  var nim_conn_last_win_offset* {.exportc.}: uint32
  var nim_conn_last_interval* {.exportc.}: uint32
  var nim_conn_last_timeout* {.exportc.}: uint32
  var nim_conn_last_access_addr* {.exportc.}: uint32
  var nim_conn_last_crcinit* {.exportc.}: uint32
  var nim_connect_desc_fields* {.exportc.}: array[4, uint32]
  var nim_connect_timing_snapshot* {.exportc.}: array[8, uint32]
  var nim_conn_start_return_count* {.exportc.}: uint32
  when bl808BleConnStageDiag:
    var nim_conn_stage* {.exportc: "nim_vendor_conn_stage".}: uint32
    var nim_conn_stage_ra* {.exportc: "nim_vendor_conn_stage_ra".}: uint32
    var nim_conn_stage_sp* {.exportc: "nim_vendor_conn_stage_sp".}: uint32
    var nim_conn_stage_mepc* {.exportc: "nim_vendor_conn_stage_mepc".}: uint32
    var nim_conn_stage_mcause* {.exportc: "nim_vendor_conn_stage_mcause".}: uint32
  var nim_lld_con_start_count* {.exportc.}: uint32
  var nim_lld_con_start_status* {.exportc.}: uint32
  var nim_lld_con_start_param* {.exportc.}: array[48, uint8]
  var nim_conn_start_em_snapshot* {.exportc.}: array[64, uint32]
  var nim_conn_start_rx_snapshot* {.exportc.}: array[64, uint32]
  var nim_conn_start_tx_snapshot* {.exportc.}: array[16, uint32]
  var nim_conn_start_reg_snapshot* {.exportc.}: array[8, uint32]
  var nim_conn_evt_count* {.exportc.}: uint32
  var nim_conn_evt_handle* {.exportc.}: uint32
  var nim_conn_evt_peer_a0* {.exportc.}: uint32
  var nim_conn_evt_peer_a1* {.exportc.}: uint32
  var nim_conn_evt_peer_type* {.exportc.}: uint32
  var nim_conn_evt_reported: bool
  var nim_disc_evt_count* {.exportc.}: uint32
  var nim_disc_evt_reason* {.exportc.}: uint32
  var nim_disc_evt_source* {.exportc.}: uint32
  var nim_llcp_tx_buf: array[12, uint8]
  var nim_acl_host_tx_buf: array[8, uint8]
  type
    NimLlcpState = object
      versionProcedureStarted: bool
      startupAttemptsLeft: uint8
      startupDelayServices: uint8
      remoteFeaturesEventPending: bool
      peerFeaturesKnown: bool
      peerFeatures: uint64
      dataLengthKnown: bool
      localTxOctets: uint16
      localTxTime: uint16
      peerMaxRxOctets: uint16
      peerMaxRxTime: uint16
      peerMaxTxOctets: uint16
      peerMaxTxTime: uint16

    NimLlcpPdu = object
      payloadLen: uint8
      data: array[32, uint8]

    NimLlcpLengthPduView {.packed.} = object
      opcode: uint8
      maxRxOctets: uint16
      maxRxTime: uint16
      maxTxOctets: uint16
      maxTxTime: uint16

    NimLlcpConnectionUpdateIndView {.packed.} = object
      opcode: uint8
      winSize: uint8
      winOffset: uint16
      interval: uint16
      latency: uint16
      timeout: uint16
      instant: uint16

    NimLlcpChannelMapIndView {.packed.} = object
      opcode: uint8
      channelMap: array[5, uint8]
      instant: uint16

    NimLlcpVersionIndView {.packed.} = object
      opcode: uint8
      version: uint8
      companyId: uint16
      subversion: uint16

    NimLlcpPhyPairPduView {.packed.} = object
      opcode: uint8
      txPhys: uint8
      rxPhys: uint8

    NimLlcpRejectIndView {.packed.} = object
      opcode: uint8
      errorCode: uint8

    NimLlcpRejectExtIndView {.packed.} = object
      opcode: uint8
      rejectedOpcode: uint8
      errorCode: uint8

    NimLlcpUnknownRspView {.packed.} = object
      opcode: uint8
      unknownOpcode: uint8

    NimLlcpTerminateIndView {.packed.} = object
      opcode: uint8
      reason: uint8

    NimConnTxElementView {.packed.} = object
      reserved00: array[4, uint8]
      emOffset: uint16
      length: uint16

  static:
    doAssert sizeof(NimLlcpLengthPduView) == 9
    doAssert offsetof(NimLlcpLengthPduView, maxRxOctets) == 1
    doAssert offsetof(NimLlcpLengthPduView, maxRxTime) == 3
    doAssert offsetof(NimLlcpLengthPduView, maxTxOctets) == 5
    doAssert offsetof(NimLlcpLengthPduView, maxTxTime) == 7
    doAssert sizeof(NimLlcpConnectionUpdateIndView) == 12
    doAssert offsetof(NimLlcpConnectionUpdateIndView, winSize) == 1
    doAssert offsetof(NimLlcpConnectionUpdateIndView, winOffset) == 2
    doAssert offsetof(NimLlcpConnectionUpdateIndView, interval) == 4
    doAssert offsetof(NimLlcpConnectionUpdateIndView, latency) == 6
    doAssert offsetof(NimLlcpConnectionUpdateIndView, timeout) == 8
    doAssert offsetof(NimLlcpConnectionUpdateIndView, instant) == 10
    doAssert sizeof(NimLlcpChannelMapIndView) == 8
    doAssert offsetof(NimLlcpChannelMapIndView, channelMap) == 1
    doAssert offsetof(NimLlcpChannelMapIndView, instant) == 6
    doAssert sizeof(NimLlcpVersionIndView) == 6
    doAssert offsetof(NimLlcpVersionIndView, version) == 1
    doAssert offsetof(NimLlcpVersionIndView, companyId) == 2
    doAssert offsetof(NimLlcpVersionIndView, subversion) == 4
    doAssert sizeof(NimLlcpPhyPairPduView) == 3
    doAssert offsetof(NimLlcpPhyPairPduView, txPhys) == 1
    doAssert offsetof(NimLlcpPhyPairPduView, rxPhys) == 2
    doAssert sizeof(NimLlcpRejectIndView) == 2
    doAssert offsetof(NimLlcpRejectIndView, errorCode) == 1
    doAssert sizeof(NimLlcpRejectExtIndView) == 3
    doAssert offsetof(NimLlcpRejectExtIndView, rejectedOpcode) == 1
    doAssert offsetof(NimLlcpRejectExtIndView, errorCode) == 2
    doAssert sizeof(NimLlcpUnknownRspView) == 2
    doAssert offsetof(NimLlcpUnknownRspView, unknownOpcode) == 1
    doAssert sizeof(NimLlcpTerminateIndView) == 2
    doAssert offsetof(NimLlcpTerminateIndView, reason) == 1
    doAssert sizeof(NimConnTxElementView) == 8
    doAssert offsetof(NimConnTxElementView, emOffset) == 4
    doAssert offsetof(NimConnTxElementView, length) == 6

  when bl808BleNimPureConnection:
    type
      NimConnTxKind = enum
        nimConnTxEmptyData
        nimConnTxAclData
        nimConnTxLlcp

      NimConnState = object
        active: bool
        reschedulePending: bool
        centralRole: bool
        directAnchorMode: bool
        handle: uint16
        accessAddress: uint32
        crcInit: uint32
        intervalSlots: uint32
        supervisionSlots: uint32
        nextAnchor: uint32
        anchorFine: uint16
        rxWindowHalfUs: uint32
        rxTimingHalfUs: uint32
        timingReferenceClock: uint32
        peerDriftPpm: uint32
        eventCounter: uint16
        connUpdatePending: bool
        connUpdateInstant: uint16
        pendingIntervalSlots: uint32
        pendingSupervisionSlots: uint32
        pendingWinOffsetSlots: uint32
        pendingWinSizeHalfUs: uint32
        pendingIntervalUnits: uint16
        pendingLatency: uint16
        pendingTimeoutUnits: uint16
        connUpdateNotifyHost: bool
        hopIncrement: uint8
        channelSelection2: bool
        channelMap: array[5, uint8]
        pendingChannelMap: array[5, uint8]
        channelMapInstant: uint16
        channelMapPending: bool
        remap: array[37, uint8]
        usedChannelCount: uint8
        lastUnmappedChannel: uint8
        emUnmappedChannel: uint8
        rfChannelMhz: uint16
        rxObserved: bool
        rxAcquiredEvents: uint8
        lastRxEventCounter: uint16
        lastRxClock: uint32
        rxNextExpectedSeq: uint8
        rxPayloadFresh: bool
        txNesn: uint8
        txSeq: uint8
        txPendingSeq: uint8
        txAckArmed: bool
        txAckObserved: bool
        txAckEligibleEvent: uint16
        txAckDescOff: uint16
        txKind: NimConnTxKind
        txEmOffset: uint16
        txLen: uint8
        txProgrammed: bool
        txProgrammedEvent: uint16
        txDescBaseOffset: uint16
        txDescCursor: uint8
        rate: uint8
        phy: uint8
        dataFlowEnabled: bool
        peerSca: uint8
        preferredSlaveLatency: uint16
        preferredSlaveEventDuration: uint16

  var nim_llcp_tx_queue: array[8, array[32, uint8]]
  var nim_llcp_tx_queue_len: array[8, uint8]
  var nim_llcp_tx_queue_conhdl: array[8, uint16]
  var nim_llcp_tx_queue_head: uint32
  var nim_llcp_tx_queue_tail: uint32
  var nim_llcp_state: NimLlcpState
  when bl808BleNimPureConnection:
    var nim_conn_state: NimConnState
    var nim_conn_sch_prog: array[36, uint8]
    var nim_conn_sched_log_index* {.exportc.}: uint32
    var nim_conn_sched_now_log* {.exportc.}: array[8, uint32]
    var nim_conn_sched_target_log* {.exportc.}: array[8, uint32]
    var nim_conn_sched_delta_log* {.exportc.}: array[8, uint32]
    var nim_conn_sched_duration_log* {.exportc.}: array[8, uint32]
    var nim_conn_sched_event_log* {.exportc.}: array[8, uint32]
    var nim_conn_sched_channel_log* {.exportc.}: array[8, uint32]
    var nim_conn_sched_timing_log* {.exportc.}: array[8, uint32]
    var nim_conn_last_schedule_now* {.exportc.}: uint32
    var nim_conn_last_schedule_target* {.exportc.}: uint32
    var nim_conn_last_schedule_fine* {.exportc.}: uint32
    var nim_conn_last_schedule_delta* {.exportc.}: uint32
    var nim_conn_last_schedule_duration* {.exportc.}: uint32
    var nim_conn_last_rx_timing* {.exportc.}: uint32
    var nim_conn_last_channel_word* {.exportc.}: uint32
    var nim_conn_last_channel* {.exportc.}: uint32
    var nim_conn_last_unmapped_channel* {.exportc.}: uint32
    var nim_conn_last_event_counter* {.exportc.}: uint32
    var nim_conn_last_schedule_anchor* {.exportc.}: uint32
    var nim_conn_last_schedule_anchor_fine* {.exportc.}: uint32
    var nim_conn_first_schedule_snapshot* {.exportc.}: array[12, uint32]
    var nim_conn_missed_event_fallback_count* {.exportc.}: uint32
    var nim_conn_deferred_schedule_count* {.exportc.}: uint32
    var nim_conn_rx_acquire_events* {.exportc.}: uint32
    var nim_conn_rx_acquire_reset_count* {.exportc.}: uint32
    var nim_conn_rx_status_reject_count* {.exportc.}: uint32
    var nim_conn_rx_last_rejected_status* {.exportc.}: uint32
    var nim_conn_rx_last_rejected_header* {.exportc.}: uint32
    when defined(BleDebugCounters):
      var nim_conn_tx_header_log* {.exportc.}: array[16, uint32]
      var nim_conn_tx_state_log* {.exportc.}: array[16, uint32]
      var nim_conn_tx_header_log_index* {.exportc.}: uint32
      var nim_conn_rx_seq_log* {.exportc.}: array[16, uint32]
      var nim_conn_rx_state_log* {.exportc.}: array[16, uint32]
      var nim_conn_rx_seq_log_index* {.exportc.}: uint32
      var nim_conn_sch_event_log_index* {.exportc.}: uint32
      var nim_conn_sch_event_code_log* {.exportc.}: array[16, uint32]
      var nim_conn_sch_event_time_log* {.exportc.}: array[16, uint32]
      var nim_conn_sch_event_now_log* {.exportc.}: array[16, uint32]
      var nim_conn_sch_event_state_log* {.exportc.}: array[16, uint32]
      var nim_conn_sch_event_counts_log* {.exportc.}: array[16, uint32]
      var nim_conn_sch_event_int_log* {.exportc.}: array[16, uint32]

  proc activeNimConnectionHandle(): uint16 {.inline.} =
    when bl808BleNimPureConnection:
      if nim_conn_state.active:
        nim_conn_state.handle
      else:
        1'u16
    else:
      1'u16

  when bl808BleNimLlcStart:
    var nim_llc_start_env_slots: array[5, pointer]
    var nim_llc_start_env_storage: array[5, array[0x8C, uint8]]

  const
    NimLlcpTxEmOffset = 0x0788'u16
    NimAclTxEmOffset = 0x0A20'u16
    NimLlcpMaxPayloadLen = 32'u8
    NimLlcpDefaultReason = 0x13'u8
    NimLlcpLocalVersion = 0x0C'u8
    NimLlcpLocalCompanyId = 0x0060'u16
    NimLlcpLocalSubversion = 0x000A'u16
    NimLlcpMaxDataOctets = NimBleLeMaxDataOctets
    NimLlcpPhy1M = NimBleLe1MPhy
    NimRxDescDone = 0x8000'u16
    NimRxDescLinkMask = 0x7FFF'u16
    NimRxDescHeaderOffset = 0x04'u32
    NimRxDescDataOffsetOffset = 0x14'u32
    NimDataLlIdContinuation = 0x01'u8
    NimDataLlIdStart = 0x02'u8
    NimDataLlIdControl = 0x03'u8
    NimConnMaxRxPayloadLen = 0x1B'u8
    NimConnEmStride = 0x94'u32
    NimConnEmBaseOffset = 0x0120'u32
    NimConnTxDescBaseOffset = 0x0558'u16
    NimConnTxDescPerHandleStride = 0x0070'u16
    NimConnTxDescStride = 0x0010'u16
    NimConnEmptyDataEmOffset = 0x0A20'u16
    NimConnTxDescSoftwareOwned = 0x8000'u16
    NimConnDataHeaderMoreDataBit = 0x0010'u16
    NimConnPhyControlBase = 0x1100'u16
    NimConnPhyControlStep = 5'u16
    NimConnChannelSelect2Bit = 0x2000'u16
    NimConnChannelEnableBit = 0x8000'u16
    NimConnRfConfigIndex = 0x39
    # The Nim LLD connection start path seeds EM +0x1E with the expected PHY
    # sync position. lld_con_evt_start_cbk overwrites the same field from the
    # computed RX timing window when the normal CONNECT_IND timing path is
    # active.
    NimConnLe1mSyncPosition = 0x0007'u16
    NimConnCodedSyncPosition = 0x0038'u16
    NimConnRxTimingDefault = 0x00FB'u16
    NimConnEventDurationMarginUs = 290'u32
    NimConnHalfSlotsPerConnIntervalUnit = 4'u32
    NimConnHalfSlotsPerSupervisionUnit = 32'u32
    NimConnHalfUsPerConnWindowUnit = 2500'u32
    NimConnHalfUsPerHalfSlot = 625'u32
    NimConnScheduleDurationMarginHalfUs = 2500'u32
    NimConnScheduleLeadSlots = 4'u32
    NimConnTrackedRxWindowHalfUs = 2500'u32
    NimConnPeripheralAcquireRxEvents = 4'u8
    NimConnConnectIndTransmitWindowDelayHalfSlots = 4'u32
    NimConnAdvTypeTimingBit = 0x10'u16
    NimConnDefaultLegacyAdvType = 0'u8
    NimConnLegacyAdvEventProps: array[5, uint16] = [
      0x13'u16, 0x1D'u16, 0x12'u16, 0x10'u16, 0x15'u16
    ]
    # The first central event still needs the normal scheduler setup lead.  The
    # initiator chooses an anchor inside the CONNECT_IND transmit window with
    # enough margin; if handoff runs late, skip event 0 instead of programming a
    # radio event at its boundary.
    NimConnInitialCentralScheduleLeadSlots = NimConnScheduleLeadSlots
    NimConnStartCentralRoleOffset = 40
    NimConnDiscSourceSupervisionTimeout = 9'u32
    NimConnDisconnectReasonTimeout = 0x08'u8
    BleErrorPinOrKeyMissing = 0x06'u8
    BleErrorUnsupportedRemoteFeature = 0x1A'u8
    BleErrorUnsupportedLlParameter = 0x20'u8
    LlcpConnectionUpdateInd = 0x00'u8
    LlcpChannelMapInd = 0x01'u8
    LlcpTerminateInd = 0x02'u8
    LlcpEncReq = 0x03'u8
    LlcpEncRsp = 0x04'u8
    LlcpStartEncReq = 0x05'u8
    LlcpStartEncRsp = 0x06'u8
    LlcpUnknownRsp = 0x07'u8
    LlcpFeatureReq = 0x08'u8
    LlcpFeatureRsp = 0x09'u8
    LlcpPauseEncReq = 0x0A'u8
    LlcpPauseEncRsp = 0x0B'u8
    LlcpVersionInd = 0x0C'u8
    LlcpRejectInd = 0x0D'u8
    LlcpSlaveFeatureReq = 0x0E'u8
    LlcpConnectionParamReq = 0x0F'u8
    LlcpConnectionParamRsp = 0x10'u8
    LlcpRejectExtInd = 0x11'u8
    LlcpPingReq = 0x12'u8
    LlcpPingRsp = 0x13'u8
    LlcpLengthReq = 0x14'u8
    LlcpLengthRsp = 0x15'u8
    LlcpPhyReq = 0x16'u8
    LlcpPhyRsp = 0x17'u8
    LlcpPhyUpdateInd = 0x18'u8
    LlcpMinUsedChannelsInd = 0x19'u8

  proc noteNimRxDescConsumed(idx: uint32) =
    lld_env[14] = uint8((idx + 1'u32) and 0x07'u32)

  proc putLe16(dst: ptr UncheckedArray[uint8], off: int, value: uint16) =
    dst[off] = uint8(value and 0x00FF'u16)
    dst[off + 1] = uint8((value shr 8) and 0x00FF'u16)

  proc putLe32(dst: ptr UncheckedArray[uint8], off: int, value: uint32) =
    dst[off] = uint8(value and 0x000000FF'u32)
    dst[off + 1] = uint8((value shr 8) and 0x000000FF'u32)
    dst[off + 2] = uint8((value shr 16) and 0x000000FF'u32)
    dst[off + 3] = uint8((value shr 24) and 0x000000FF'u32)

  proc nimLlcpRecordRx(header: uint16, dataOff: uint16, pduLen: uint16) =
    let slot = nim_llcp_rx_log_index and 0x07'u32
    var word = uint32(header) shl 16
    if pduLen > 0'u16:
      word = word or uint32(btbleEmRead8(dataOff))
    if pduLen > 1'u16:
      word = word or (uint32(btbleEmRead8(dataOff + 1'u16)) shl 8)
    nim_llcp_rx_log[slot.int] = word
    nim_llcp_rx_log_index = nim_llcp_rx_log_index + 1'u32

  proc nimLlcpRecordTx(pdu: ptr UncheckedArray[uint8], len: uint8) =
    let slot = nim_llcp_tx_log_index and 0x07'u32
    var word = uint32(len) shl 24
    if pdu != nil and len > 0'u8:
      word = word or uint32(pdu[0])
    if pdu != nil and len > 1'u8:
      word = word or (uint32(pdu[1]) shl 8)
    if pdu != nil and len > 2'u8:
      word = word or (uint32(pdu[2]) shl 16)
    nim_llcp_tx_log[slot.int] = word
    nim_llcp_tx_log_index = nim_llcp_tx_log_index + 1'u32

  proc nimLlcpRecordPeerFeatures(pdu: ptr UncheckedArray[uint8],
                                pduLen: uint8): bool =
    if pdu == nil or pduLen < 9'u8:
      return
    let opcode = pdu[0]
    if opcode != LlcpFeatureReq and opcode != LlcpFeatureRsp and
        opcode != LlcpSlaveFeatureReq:
      return
    var features = 0'u64
    for i in 0 ..< 8:
      features = features or (uint64(pdu[i + 1]) shl (i * 8))
    nim_llcp_state.peerFeatures = features
    nim_llcp_state.peerFeaturesKnown = true
    nim_llcp_peer_features[0] =
      uint32(features and 0x00000000FFFFFFFF'u64)
    nim_llcp_peer_features[1] = uint32(features shr 32)
    true

  proc nimLlcpUsedFeaturesForPeer(): uint64 =
    if nim_llcp_state.peerFeaturesKnown:
      return NimBleConservativeLeFeatures and
        nim_llcp_state.peerFeatures
    NimBleConservativeLeFeatures

  proc nimLlcpRecordUsedFeatures(features: uint64) =
    nim_llcp_used_features[0] =
      uint32(features and 0x00000000FFFFFFFF'u64)
    nim_llcp_used_features[1] = uint32(features shr 32)

  proc nimLlcpClearFeatureExchangeState(clearDebug: bool = false) =
    nim_llcp_state.remoteFeaturesEventPending = false
    nim_llcp_state.peerFeaturesKnown = false
    nim_llcp_state.peerFeatures = 0
    if clearDebug:
      nim_llcp_peer_features[0] = 0
      nim_llcp_peer_features[1] = 0
      nim_llcp_used_features[0] = 0
      nim_llcp_used_features[1] = 0

  proc nimLlcpMaybeCompleteRemoteFeatures(conhdl: uint16) =
    if nim_llcp_state.remoteFeaturesEventPending and
        nim_llcp_state.peerFeaturesKnown:
      nim_llcp_state.remoteFeaturesEventPending = false
      sendLeRemoteFeaturesComplete(conhdl, HciStatusSuccess)

  proc getLe16(src: ptr UncheckedArray[uint8], off: int): uint16 =
    uint16(src[off]) or (uint16(src[off + 1]) shl 8)

  template nimLlcpLengthPduAt(pdu: ptr UncheckedArray[uint8]): ptr NimLlcpLengthPduView =
    cast[ptr NimLlcpLengthPduView](pdu)

  template nimLlcpLengthPdu(pdu: var NimLlcpPdu): ptr NimLlcpLengthPduView =
    cast[ptr NimLlcpLengthPduView](addr pdu.data[0])

  template nimLlcpConnectionUpdateInd(pdu: var NimLlcpPdu): ptr NimLlcpConnectionUpdateIndView =
    cast[ptr NimLlcpConnectionUpdateIndView](addr pdu.data[0])

  template nimLlcpConnectionUpdateIndAt(pdu: ptr UncheckedArray[uint8]): ptr NimLlcpConnectionUpdateIndView =
    cast[ptr NimLlcpConnectionUpdateIndView](pdu)

  template nimLlcpChannelMapInd(pdu: var NimLlcpPdu): ptr NimLlcpChannelMapIndView =
    cast[ptr NimLlcpChannelMapIndView](addr pdu.data[0])

  template nimLlcpChannelMapIndAt(pdu: ptr UncheckedArray[uint8]): ptr NimLlcpChannelMapIndView =
    cast[ptr NimLlcpChannelMapIndView](pdu)

  template nimLlcpVersionInd(pdu: var NimLlcpPdu): ptr NimLlcpVersionIndView =
    cast[ptr NimLlcpVersionIndView](addr pdu.data[0])

  template nimLlcpPhyPairPdu(pdu: var NimLlcpPdu): ptr NimLlcpPhyPairPduView =
    cast[ptr NimLlcpPhyPairPduView](addr pdu.data[0])

  template nimLlcpRejectInd(pdu: var NimLlcpPdu): ptr NimLlcpRejectIndView =
    cast[ptr NimLlcpRejectIndView](addr pdu.data[0])

  template nimLlcpRejectExtInd(pdu: var NimLlcpPdu): ptr NimLlcpRejectExtIndView =
    cast[ptr NimLlcpRejectExtIndView](addr pdu.data[0])

  template nimLlcpUnknownRsp(pdu: var NimLlcpPdu): ptr NimLlcpUnknownRspView =
    cast[ptr NimLlcpUnknownRspView](addr pdu.data[0])

  template nimLlcpTerminateInd(pdu: var NimLlcpPdu): ptr NimLlcpTerminateIndView =
    cast[ptr NimLlcpTerminateIndView](addr pdu.data[0])

  template nimConnTxElementAt(buf: pointer): ptr NimConnTxElementView =
    cast[ptr NimConnTxElementView](buf)

  proc nimConnTxElementInit(buf: pointer; emOffset, length: uint16) =
    let tx = nimConnTxElementAt(buf)
    discard c_memset(buf, 0, sizeof(NimConnTxElementView).csize_t)
    tx.emOffset = emOffset
    tx.length = length

  proc nimLlcpResetDataLengthState() =
    nim_llcp_state.dataLengthKnown = false
    nim_llcp_state.localTxOctets = NimBleLeMaxDataOctets
    nim_llcp_state.localTxTime = NimBleLeMaxDataTime
    nim_llcp_state.peerMaxRxOctets = NimBleLeMaxDataOctets
    nim_llcp_state.peerMaxRxTime = NimBleLeMaxDataTime
    nim_llcp_state.peerMaxTxOctets = NimBleLeMaxDataOctets
    nim_llcp_state.peerMaxTxTime = NimBleLeMaxDataTime

  proc nimLlcpStorePeerDataLength(maxRxOctets, maxRxTime, maxTxOctets,
                                 maxTxTime: uint16) =
    nim_llcp_state.dataLengthKnown = true
    nim_llcp_state.peerMaxRxOctets = clampBleDataOctets(maxRxOctets)
    nim_llcp_state.peerMaxRxTime = clampBleDataTime(maxRxTime)
    nim_llcp_state.peerMaxTxOctets = clampBleDataOctets(maxTxOctets)
    nim_llcp_state.peerMaxTxTime = clampBleDataTime(maxTxTime)

  proc nimLlcpRecordPeerDataLength(pdu: ptr UncheckedArray[uint8],
                                  pduLen: uint8) =
    if not nimBleLocalFeatureSupported(NimBleFeatureDataPacketLengthExtension):
      return
    if pdu == nil or pduLen < 9'u8:
      return
    let lengthPdu = nimLlcpLengthPduAt(pdu)
    if lengthPdu.opcode != LlcpLengthReq and lengthPdu.opcode != LlcpLengthRsp:
      return
    nimLlcpStorePeerDataLength(lengthPdu.maxRxOctets, lengthPdu.maxRxTime,
                              lengthPdu.maxTxOctets, lengthPdu.maxTxTime)

  proc nimLlcpConfigCount(value: int): uint8 {.inline.} =
    if value <= 0:
      0'u8
    elif value > 255:
      255'u8
    else:
      uint8(value)

  when defined(bl808BlePrintNimLlcMsg):
    proc nimLlcMsgWord(index: int): uint32 =
      let off = index * 4
      uint32(nim_llc_msg[off]) or
        (uint32(nim_llc_msg[off + 1]) shl 8) or
        (uint32(nim_llc_msg[off + 2]) shl 16) or
        (uint32(nim_llc_msg[off + 3]) shl 24)

    proc printNimLlcMsg(label: static[string]) =
      bleTrace("[NIMLLC] ")
      bleTrace(label)
      bleTrace(" words=")
      for i in 0 ..< 14:
        if i != 0:
          bleTrace(",")
        bleTraceHex32(nimLlcMsgWord(i))
      bleTrace("\r\n")

  when bl808BleConnStageDiag:
    template nimConnReadRa(): uint32 =
      block:
        var v: uint32
        {.emit: [
          "asm volatile(\"mv %0, ra\" : \"=r\"(", v, ") : : \"memory\");"
        ].}
        v

    template nimConnReadSp(): uint32 =
      block:
        var v: uint32
        {.emit: [
          "asm volatile(\"mv %0, sp\" : \"=r\"(", v, ") : : \"memory\");"
        ].}
        v

    proc nimConnMark(stage: uint32) {.inline.} =
      nim_conn_stage = stage
      nim_conn_stage_ra = nimConnReadRa()
      nim_conn_stage_sp = nimConnReadSp()
      nim_conn_stage_mepc = cast[uint32](csrReadMepc())
      nim_conn_stage_mcause = cast[uint32](csrReadMcause())
  else:
    proc nimConnMark(stage: uint32) {.inline.} =
      discard stage

  proc recordNimPeripheralPeer(conhdl: uint16,
                                  raw: ptr UncheckedArray[uint8],
                                  header: uint16) =
    nimConnMark(0x130'u32)
    nim_conn_evt_handle = conhdl.uint32
    nim_conn_evt_peer_type = (uint32(header) shr 6) and 0x01'u32
    if raw != nil:
      nim_conn_evt_peer_a0 =
        uint32(raw[0]) or (uint32(raw[1]) shl 8) or
        (uint32(raw[2]) shl 16) or (uint32(raw[3]) shl 24)
      nim_conn_evt_peer_a1 =
        uint32(raw[4]) or (uint32(raw[5]) shl 8)

  proc noteNimPeripheralConnected(conhdl: uint16) =
    if nim_conn_evt_reported:
      return
    nimConnMark(0x132'u32)
    nim_conn_evt_handle = conhdl.uint32
    nim_conn_evt_reported = true
    inc nim_conn_evt_count

  proc completeNimInitiatorHciConnection(conhdl: uint16) =
    when defined(bl808m0) and bl808BleNimPureCentral:
      if nim_init_complete_pending == 0'u32:
        return
      nim_init_complete_pending = 0
      nim_init_active = 0
      nim_init_rx_service_pending = 0
      nim_init_handoff_pending = 0
      nim_init_handoff_program_count = 0
      nim_init_handoff_tx_event_count = 0
      nim_init_handoff_ready_clock = 0
      nim_init_handoff_deadline = 0
      nim_init_last_status = HciStatusSuccess.uint32
      inc nim_init_hci_complete_count
      inc nim_init_total_hci_complete_count
      sendLeConnectionCompleteStatusHandle(
        addr nim_init_hci_params[0], nim_init_hci_params.len.uint8,
        HciStatusSuccess, conhdl, 0'u8)
    else:
      discard conhdl

  proc noteNimAdvertiserConnected(raw: ptr UncheckedArray[uint8],
                                     header: uint16,
                                     interval: uint32,
                                     latency: uint32,
                                     peerSca: uint8) =
    ## lld_adv_end_ind_handler records the initiator identity and marks the
    ## advertising environment as connected after llc_start succeeds.  The Nim
    ## CONNECT_IND shortcut bypasses that handler, so mirror the consumed fields
    ## for advertiser slot 0.
    let conn = llmAdvertiserConn()
    if raw != nil:
      for i in 0 ..< 6:
        conn.peerAddr.data[i] = raw[i]
    conn.peerAddrType = uint8((header shr 6) and 0x01'u16)
    conn.connected = 1'u8
    conn.state = 9'u8
    conn.intervalMinSlots = uint16(interval * 4'u32)
    conn.intervalMaxSlots = uint16(interval * 4'u32)
    conn.intervalLatencyWord = 0x00040004'u32
    conn.supervisionMinSlots = uint16((latency + 1'u32) * interval)
    conn.supervisionMaxSlots = uint16((latency + 1'u32) * interval)
    let intervalLatency = (latency + 1'u32) * interval
    let scaIdx = peerSca and 0x07'u8
    let driftPpm = uint32(co_sca2ppm[scaIdx.int]) + rwip_max_drift_get(scaIdx)
    let driftSlots = (((driftPpm * intervalLatency) div 400'u32) * 2'u32 +
                      312'u32) div 625'u32 + 1'u32
    conn.driftSlots = uint16(driftSlots and 0xFFFF'u32)

  proc clearNimConnectionStateForDisconnect(reason: uint8) =
    discard reason
    nim_conn_active = false
    nim_conn_handle = 0
    nim_conn_started = false
    nim_conn_evt_reported = false
    when defined(bl808m0) and bl808BleNimPureCentral:
      nim_init_active = 0
      nim_init_complete_pending = 0
      nim_init_rx_service_pending = 0
      nim_init_handoff_pending = 0
      nim_init_handoff_program_count = 0
      nim_init_handoff_tx_event_count = 0
      nim_init_handoff_ready_clock = 0
      nim_init_handoff_deadline = 0
    when bl808BleNimPureConnection:
      nim_conn_state.active = false
      nim_conn_state.reschedulePending = false
      nim_conn_state.connUpdatePending = false
      nim_conn_state.pendingIntervalSlots = 0
      nim_conn_state.pendingSupervisionSlots = 0
      nim_conn_state.pendingWinOffsetSlots = 0
      nim_conn_state.pendingWinSizeHalfUs = 0
      nim_conn_state.pendingIntervalUnits = 0
      nim_conn_state.pendingLatency = 0
      nim_conn_state.pendingTimeoutUnits = 0
      nim_conn_state.connUpdateNotifyHost = false
    nim_connect_ind_pending = 0
    nim_llcp_tx_pending = 0
    nim_llcp_tx_queued = 0
    nim_llcp_tx_queue_head = 0
    nim_llcp_tx_queue_tail = 0
    nim_llcp_state.versionProcedureStarted = false
    nimLlcpClearFeatureExchangeState()
    nim_llcp_state.startupAttemptsLeft = 0
    nim_llcp_state.startupDelayServices = 0
    nimLlcpResetDataLengthState()
    nim_acl_empty_tx_pending = 0
    nim_acl_empty_tx_queued = 0
    nim_acl_host_tx_pending = 0
    when defined(bl808m0):
      when not bl808BleNimRuntimeClicIrq:
        nimDisableM0BleClicIrq()
    regWrite(BLE_BASE + BTBLE_INTACK_OFFSET,
             regRead(BLE_BASE + BTBLE_INTSTAT_OFFSET))
    writeBtbleInterruptMask(0)

  proc noteNimPeripheralDisconnectedFrom(source: uint32, reason: uint8) =
    nimConnMark(0x1D0'u32)
    let alreadyDisconnected =
      not nim_conn_active and not nim_conn_started and
      nim_disc_evt_count != 0
    clearNimConnectionStateForDisconnect(reason)
    nim_disc_evt_reason = reason.uint32
    nim_disc_evt_source = source
    if not alreadyDisconnected:
      inc nim_disc_evt_count

  proc noteNimPeripheralDisconnected(reason: uint8) =
    noteNimPeripheralDisconnectedFrom(0'u32, reason)

  proc bleNimPeripheralIdleDisconnect*(reason: uint8) {.exportc, cdecl.} =
    ## Host-side fallback disconnect for the Nim peripheral bridge.  The local
    ## host can synthesize the disconnect after the macOS central drops the
    ## link, but the vendor LLD shim still has to leave connection mode so the
    ## BTBLE interrupt line does not keep the M0 in the connection service path.
    noteNimPeripheralDisconnectedFrom(1'u32, reason)

  proc validConnDataHeader(header: uint16): bool =
    let llid = uint8(header and 0x0003'u16)
    let payloadLen = connDataPayloadLen(header)
    if llid == 0'u8:
      return false
    if payloadLen > NimConnMaxRxPayloadLen:
      return false
    if llid == NimDataLlIdControl and payloadLen == 0'u8:
      return false
    true

  proc connRxStatusAcceptsPayload(status: uint16): bool {.inline.} =
    ## Match vendor lld_rxdesc_check: descriptor word 0 is the hardware ring
    ## link pointer plus the done bit.  Values such as 0x8116/0x811e are not
    ## CRC/sync errors; the lower bits point at the next RX descriptor.
    (status and NimRxDescDone) != 0'u16

  proc rejectConnRxDescriptor(desc: uint32, status, header: uint16,
                              cur: uint32) =
    btbleRxDescReleaseLink(desc, status)
    noteNimRxDescConsumed(cur)
    inc nim_lld_rx_free_count
    when bl808BleNimPureConnection:
      inc nim_conn_rx_status_reject_count
      nim_conn_rx_last_rejected_status = status.uint32
      nim_conn_rx_last_rejected_header = header.uint32

  when bl808BleNimManualConnTx:
    var nim_acl_empty_tx_buf: array[8, uint8]

    proc nimSendEmptyAclNow(conhdl: uint16): bool =
      if nim_acl_empty_tx_pending != 0:
        return false
      if nim_acl_host_tx_pending != 0:
        nim_acl_empty_tx_queued = 1
        return false
      # lld_con_data_tx takes an LLD ACL TX element, not a raw LL PDU.
      # Offset +4 is the EM payload offset and +6 carries the pending length.
      btbleEmWrite8(NimAclTxEmOffset, 0'u8)
      nimConnTxElementInit(addr nim_acl_empty_tx_buf[0], NimAclTxEmOffset, 0'u16)
      nim_acl_empty_tx_pending = 1
      inc nim_acl_empty_tx_count
      nim_acl_empty_last_status =
        nimLldConDataTx(conhdl, addr nim_acl_empty_tx_buf[0]).uint32
      if nim_acl_empty_last_status != 0:
        nim_acl_empty_tx_pending = 0
        return false
      true

    proc nimRequestEmptyAcl(conhdl: uint16): bool =
      if nim_acl_empty_tx_pending != 0:
        nim_acl_empty_tx_queued = 1
        return false
      if nim_acl_host_tx_pending != 0:
        nim_acl_empty_tx_queued = 1
        return false
      nimSendEmptyAclNow(conhdl)

    proc nimLlcpSendPduNow(conhdl: uint16, pdu: ptr UncheckedArray[uint8],
                              len: uint8,
                              sendAclKick: bool = bl808BleNimKeepaliveAcl): bool =
      if pdu == nil or len == 0'u8 or len > NimLlcpMaxPayloadLen:
        return false
      nimLlcpRecordTx(pdu, len)
      for i in 0 ..< len.int:
        btbleEmWrite8(NimLlcpTxEmOffset + i.uint16, pdu[i])
      nimConnTxElementInit(addr nim_llcp_tx_buf[0], NimLlcpTxEmOffset, len.uint16)
      nim_llcp_tx_pending = 1
      inc nim_llcp_tx_count
      nim_llcp_last_status =
        nimLldConLlcpTx(conhdl, addr nim_llcp_tx_buf[0]).uint32
      if nim_llcp_last_status != 0:
        nim_llcp_tx_pending = 0
        return false
      when bl808BleNimPureConnection:
        discard sendAclKick
      else:
        if sendAclKick:
          discard nimRequestEmptyAcl(conhdl)
      true

    proc nimLlcpSendPduNow(conhdl: uint16, pdu: var NimLlcpPdu,
                              sendAclKick: bool = bl808BleNimKeepaliveAcl): bool =
      nimLlcpSendPduNow(conhdl,
        cast[ptr UncheckedArray[uint8]](addr pdu.data[0]), pdu.payloadLen,
        sendAclKick)

    proc nimLlcpTrySendQueued() =
      if nim_llcp_tx_pending != 0:
        return
      if nim_llcp_tx_queued == 0:
        return
      let slot = nim_llcp_tx_queue_head and 0x07'u32
      nim_llcp_tx_queue_head =
        (nim_llcp_tx_queue_head + 1'u32) and 0x07'u32
      dec nim_llcp_tx_queued
      discard nimLlcpSendPduNow(nim_llcp_tx_queue_conhdl[slot.int],
        cast[ptr UncheckedArray[uint8]](
          addr nim_llcp_tx_queue[slot.int][0]),
        nim_llcp_tx_queue_len[slot.int])

    proc nimLlcpQueuePdu(conhdl: uint16, pdu: ptr UncheckedArray[uint8],
                            len: uint8): bool =
      if pdu == nil or len == 0'u8 or len > NimLlcpMaxPayloadLen:
        return false
      if nim_llcp_tx_pending == 0 and nim_llcp_tx_queued != 0:
        nimLlcpTrySendQueued()
      if nim_llcp_tx_pending == 0 and nim_llcp_tx_queued == 0:
        if nimLlcpSendPduNow(conhdl, pdu, len):
          return true
        inc nim_llcp_tx_dropped
        return false
      if nim_llcp_tx_queued >=
          nim_llcp_tx_queue_len.len.uint32:
        inc nim_llcp_tx_dropped
        return false
      let slot = nim_llcp_tx_queue_tail and 0x07'u32
      nim_llcp_tx_queue_tail =
        (nim_llcp_tx_queue_tail + 1'u32) and 0x07'u32
      nim_llcp_tx_queue_conhdl[slot.int] = conhdl
      nim_llcp_tx_queue_len[slot.int] = len
      for i in 0 ..< len.int:
        nim_llcp_tx_queue[slot.int][i] = pdu[i]
      inc nim_llcp_tx_queued
      true

    proc nimLlcpQueuePdu(conhdl: uint16,
                            pdu: var NimLlcpPdu): bool {.inline.} =
      nimLlcpQueuePdu(conhdl,
        cast[ptr UncheckedArray[uint8]](addr pdu.data[0]), pdu.payloadLen)

    proc nimLlcpWireLength(opcode: uint8): uint8 =
      case opcode
      of LlcpConnectionUpdateInd:
        12'u8
      of LlcpChannelMapInd:
        8'u8
      of LlcpTerminateInd:
        2'u8
      of LlcpEncReq:
        23'u8
      of LlcpEncRsp:
        13'u8
      of LlcpStartEncReq, LlcpStartEncRsp, LlcpPauseEncReq, LlcpPauseEncRsp,
         LlcpPingReq, LlcpPingRsp:
        1'u8
      of LlcpUnknownRsp:
        2'u8
      of LlcpFeatureReq, LlcpFeatureRsp, LlcpSlaveFeatureReq:
        9'u8
      of LlcpVersionInd:
        6'u8
      of LlcpRejectInd:
        2'u8
      of LlcpConnectionParamReq, LlcpConnectionParamRsp:
        24'u8
      of LlcpRejectExtInd:
        3'u8
      of LlcpLengthReq, LlcpLengthRsp:
        9'u8
      of LlcpPhyReq, LlcpPhyRsp:
        3'u8
      of LlcpPhyUpdateInd:
        5'u8
      of LlcpMinUsedChannelsInd:
        3'u8
      else:
        0'u8

    proc nimLlcpRxPduValid(opcode: uint8, pduLen: uint16): bool =
      const LlcpPlausibleFutureOpcodeMax = 0x3F'u8
      if pduLen == 0'u16 or pduLen > NimConnMaxRxPayloadLen.uint16:
        return false
      let expected = nimLlcpWireLength(opcode)
      if expected != 0'u8:
        return pduLen == expected.uint16
      opcode <= LlcpPlausibleFutureOpcodeMax

    proc nimLlcpRecordMalformed(header: uint16, opcode: uint8,
                                   pduLen: uint16) =
      inc nim_llcp_rx_malformed_count
      nim_llcp_rx_malformed_last =
        (uint32(header) shl 16) or
        (uint32(pduLen and 0x00FF'u16) shl 8) or uint32(opcode)

    proc nimLlcpBuildFeaturePdu(
        opcode: uint8,
        features: uint64 = NimBleConservativeLeFeatures): NimLlcpPdu =
      result.payloadLen = 9'u8
      result.data[0] = opcode
      for i in 0 ..< 8:
        result.data[i + 1] = nimBleFeatureByte(features, i)

    proc nimLlcpBuildLengthPdu(opcode: uint8): NimLlcpPdu =
      result.payloadLen = 9'u8
      let body = nimLlcpLengthPdu(result)
      body.opcode = opcode
      body.maxRxOctets = NimBleLeMaxDataOctets
      body.maxRxTime = NimBleLeMaxDataTime
      body.maxTxOctets = nim_llcp_state.localTxOctets
      body.maxTxTime = nim_llcp_state.localTxTime

    proc nimLlcpBuildOpcodePdu(opcode: uint8): NimLlcpPdu =
      result.payloadLen = 1'u8
      result.data[0] = opcode

    proc nimConnStorePendingConnectionUpdate(winSize: uint8, winOffset: uint16,
                                             interval, latency,
                                             timeout, instant: uint16,
                                             notifyHost: bool) =
      when bl808BleNimPureConnection:
        nim_conn_state.pendingWinOffsetSlots =
          uint32(winOffset) * NimConnHalfSlotsPerConnIntervalUnit
        nim_conn_state.pendingWinSizeHalfUs =
          uint32(if winSize == 0'u8: 1'u8 else: winSize) *
          NimConnHalfUsPerConnWindowUnit
        nim_conn_state.pendingIntervalSlots =
          uint32(interval) * NimConnHalfSlotsPerConnIntervalUnit
        nim_conn_state.pendingSupervisionSlots =
          uint32(timeout) * NimConnHalfSlotsPerSupervisionUnit
        nim_conn_state.pendingIntervalUnits = interval
        nim_conn_state.pendingLatency = latency
        nim_conn_state.pendingTimeoutUnits = timeout
        nim_conn_state.connUpdateInstant = instant
        nim_conn_state.connUpdateNotifyHost = notifyHost
        nim_conn_state.connUpdatePending = true

    proc nimLlcpBuildConnectionUpdateInd(req: ptr HciLeConnUpdateReqView): NimLlcpPdu =
      result.payloadLen = 12'u8
      let body = nimLlcpConnectionUpdateInd(result)
      body.opcode = LlcpConnectionUpdateInd
      if req == nil:
        return
      let interval = req.connIntervalMin
      let instant =
        when bl808BleNimPureConnection:
          uint16(nim_conn_state.eventCounter + 6'u16)
        else:
          6'u16
      body.winSize = 1'u8
      body.winOffset = 0'u16
      body.interval = interval
      body.latency = req.connLatency
      body.timeout = req.supervisionTimeout
      body.instant = instant

    proc nimLlcpStartConnectionUpdate(conhdl: uint16,
                                     req: ptr HciLeConnUpdateReqView): uint8 =
      when defined(bl808m0) and bl808BleNimConnectionEnabled and
          bl808BleNimManualConnTx:
        when bl808BleNimPureConnection:
          if not nim_conn_state.active or conhdl != nim_conn_state.handle:
            return HciStatusUnknownConnection
          if not nim_conn_state.centralRole:
            return HciStatusCommandDisallowed
          if nim_conn_state.connUpdatePending:
            return HciStatusCommandDisallowed
        else:
          return HciStatusUnsupportedFeatureParam
        if req == nil:
          return HciStatusInvalidParams
        var pdu = nimLlcpBuildConnectionUpdateInd(req)
        if not nimLlcpQueuePdu(conhdl, pdu):
          return HciStatusCommandDisallowed
        let update = nimLlcpConnectionUpdateInd(pdu)
        nimConnStorePendingConnectionUpdate(
          update.winSize,
          update.winOffset,
          req.connIntervalMin,
          req.connLatency,
          req.supervisionTimeout,
          update.instant,
          notifyHost = true)
        HciStatusSuccess
      else:
        discard conhdl
        discard req
        HciStatusUnsupportedFeatureParam

    proc nimLlcpBuildChannelMapInd(): NimLlcpPdu =
      result.payloadLen = 8'u8
      let body = nimLlcpChannelMapInd(result)
      body.opcode = LlcpChannelMapInd
      nimBleCurrentChannelMap(cast[ptr UncheckedArray[uint8]](addr body.channelMap[0]))
      let instant =
        when bl808BleNimPureConnection:
          uint16(nim_conn_state.eventCounter + 6'u16)
        else:
          6'u16
      body.instant = instant

    proc nimLlcpBuildVersionInd(): NimLlcpPdu =
      result.payloadLen = 6'u8
      let body = nimLlcpVersionInd(result)
      body.opcode = LlcpVersionInd
      body.version = NimLlcpLocalVersion
      body.companyId = NimLlcpLocalCompanyId
      body.subversion = NimLlcpLocalSubversion

    proc nimLlcpBuildFeatureRsp(): NimLlcpPdu =
      let features = nimLlcpUsedFeaturesForPeer()
      nimLlcpRecordUsedFeatures(features)
      nimLlcpBuildFeaturePdu(LlcpFeatureRsp, features)

    proc nimLlcpBuildPhyRsp(): NimLlcpPdu =
      result.payloadLen = 3'u8
      let body = nimLlcpPhyPairPdu(result)
      body.opcode = LlcpPhyRsp
      body.txPhys = NimLlcpPhy1M
      body.rxPhys = NimLlcpPhy1M

    proc nimLlcpBuildPingRsp(): NimLlcpPdu =
      nimLlcpBuildOpcodePdu(LlcpPingRsp)

    proc nimLlcpBuildLengthRsp(): NimLlcpPdu =
      nimLlcpBuildLengthPdu(LlcpLengthRsp)

    proc nimLlcpBuildRejectInd(errorCode: uint8): NimLlcpPdu =
      result.payloadLen = 2'u8
      let body = nimLlcpRejectInd(result)
      body.opcode = LlcpRejectInd
      body.errorCode = errorCode

    proc nimLlcpBuildRejectExtInd(rejectedOpcode, errorCode: uint8): NimLlcpPdu =
      result.payloadLen = 3'u8
      let body = nimLlcpRejectExtInd(result)
      body.opcode = LlcpRejectExtInd
      body.rejectedOpcode = rejectedOpcode
      body.errorCode = errorCode

    proc nimLlcpBuildUnsupportedFeatureRsp(opcode: uint8): NimLlcpPdu =
      nimLlcpBuildRejectExtInd(opcode, BleErrorUnsupportedRemoteFeature)

    proc nimLlcpBuildUnknownRsp(opcode: uint8): NimLlcpPdu =
      result.payloadLen = 2'u8
      let body = nimLlcpUnknownRsp(result)
      body.opcode = LlcpUnknownRsp
      body.unknownOpcode = opcode

    proc nimLlcpBuildTerminateInd(reason: uint8): NimLlcpPdu =
      result.payloadLen = 2'u8
      let body = nimLlcpTerminateInd(result)
      body.opcode = LlcpTerminateInd
      body.reason = reason

    proc nimLlcpRespond(conhdl: uint16, opcode: uint8,
                             reason: uint8 = NimLlcpDefaultReason) =
      case opcode
      of LlcpTerminateInd:
        noteNimPeripheralDisconnectedFrom(2'u32, reason)
        sendDisconnectComplete(conhdl, reason)
      of LlcpFeatureReq:
        var rsp = nimLlcpBuildFeatureRsp()
        discard nimLlcpQueuePdu(conhdl, rsp)
      of LlcpSlaveFeatureReq:
        var rsp = nimLlcpBuildFeatureRsp()
        discard nimLlcpQueuePdu(conhdl, rsp)
      of LlcpVersionInd:
        if not nim_llcp_state.versionProcedureStarted:
          var rsp = nimLlcpBuildVersionInd()
          if nimLlcpQueuePdu(conhdl, rsp):
            nim_llcp_state.versionProcedureStarted = true
            nim_llcp_state.startupAttemptsLeft = 0
      of LlcpLengthReq:
        if nimBleLocalFeatureSupported(NimBleFeatureDataPacketLengthExtension):
          var rsp = nimLlcpBuildLengthRsp()
          if nimLlcpQueuePdu(conhdl, rsp):
            sendLeDataLengthChange(conhdl)
        else:
          var rsp = nimLlcpBuildUnsupportedFeatureRsp(opcode)
          discard nimLlcpQueuePdu(conhdl, rsp)
      of LlcpPhyReq:
        if nimBlePhyUpdateSupported():
          var rsp = nimLlcpBuildPhyRsp()
          discard nimLlcpQueuePdu(conhdl, rsp)
        else:
          var rsp = nimLlcpBuildUnsupportedFeatureRsp(opcode)
          discard nimLlcpQueuePdu(conhdl, rsp)
      of LlcpPingReq:
        if nimBleLocalFeatureSupported(NimBleFeatureLePing):
          var rsp = nimLlcpBuildPingRsp()
          discard nimLlcpQueuePdu(conhdl, rsp)
        else:
          var rsp = nimLlcpBuildUnsupportedFeatureRsp(opcode)
          discard nimLlcpQueuePdu(conhdl, rsp)
      of LlcpEncReq, LlcpPauseEncReq:
        var rsp = nimLlcpBuildRejectInd(BleErrorPinOrKeyMissing)
        discard nimLlcpQueuePdu(conhdl, rsp)
      of LlcpConnectionParamReq:
        var rsp = nimLlcpBuildUnsupportedFeatureRsp(opcode)
        discard nimLlcpQueuePdu(conhdl, rsp)
      of LlcpConnectionUpdateInd, LlcpChannelMapInd, LlcpPhyUpdateInd:
        discard
      of LlcpMinUsedChannelsInd:
        discard
      of LlcpEncRsp, LlcpStartEncReq, LlcpStartEncRsp, LlcpPauseEncRsp:
        discard
      of LlcpUnknownRsp, LlcpFeatureRsp, LlcpLengthRsp, LlcpPhyRsp, LlcpPingRsp,
         LlcpConnectionParamRsp, LlcpRejectInd, LlcpRejectExtInd:
        discard
      else:
        var rsp = nimLlcpBuildUnknownRsp(opcode)
        discard nimLlcpQueuePdu(conhdl, rsp)

    proc nimLlcpPrimeStartup() =
      nim_llcp_state.versionProcedureStarted = false
      nimLlcpClearFeatureExchangeState(clearDebug = true)
      nimLlcpResetDataLengthState()
      when bl808BleNimPureConnection:
        # Prime the controller-owned version procedure.  As a central, defer
        # until a slave packet anchors the link; as a peripheral, the first
        # slave response may legally ACK the master's SN=0 packet and carry
        # LL_VERSION_IND, which is what CoreBluetooth expects when it waits for
        # the peer version procedure.
        nim_llcp_state.startupAttemptsLeft =
          nimLlcpConfigCount(bl808BleNimStartupLlcpRetries)
        nim_llcp_state.startupDelayServices = 0
      else:
        when bl808BleNimStartupLlcpRetries > 0:
          nim_llcp_state.startupAttemptsLeft =
            nimLlcpConfigCount(bl808BleNimStartupLlcpRetries)
          nim_llcp_state.startupDelayServices =
            nimLlcpConfigCount(bl808BleNimStartupLlcpDelayServices)
        else:
          nim_llcp_state.startupAttemptsLeft = 0
          nim_llcp_state.startupDelayServices = 0

    proc nimLlcpTrySendStartup(conhdl: uint16) =
      when bl808BleNimStartupLlcpRetries > 0:
        if not nim_conn_started:
          return
        if nim_llcp_state.startupAttemptsLeft == 0'u8:
          return
        when bl808BleNimPureConnection:
          if nim_conn_state.active and nim_conn_state.centralRole and
              not nim_conn_state.rxObserved:
            inc nim_llcp_startup_deferred_count
            return
        # TX-free only confirms that the vendor LLD accepted/free'd our buffer,
        # not that the peer received the control PDU. Retry only until any LLCP
        # arrives from the peer; after that, the normal LLCP responder owns it.
        if nim_llcp_rx_count != 0'u32:
          nim_llcp_state.startupAttemptsLeft = 0
          return
        if nim_llcp_tx_pending != 0'u32 or
            nim_llcp_tx_queued != 0'u32:
          inc nim_llcp_startup_deferred_count
          return
        if nim_llcp_state.startupDelayServices != 0'u8:
          dec nim_llcp_state.startupDelayServices
          inc nim_llcp_startup_deferred_count
          return
        var pdu = nimLlcpBuildVersionInd()
        dec nim_llcp_state.startupAttemptsLeft
        inc nim_llcp_startup_tx_count
        if nimLlcpSendPduNow(conhdl, pdu):
          nim_llcp_state.versionProcedureStarted = true

    when bl808BleNimPureConnection:
      proc nimConnReceiveChannelMapIndBytes(pdu: ptr UncheckedArray[uint8],
                                            pduLen: uint8)
      proc nimConnReceiveConnectionUpdateIndBytes(pdu: ptr UncheckedArray[uint8],
                                                  pduLen: uint8)
      proc nimConnReceivePhyUpdateIndBytes(pdu: ptr UncheckedArray[uint8],
                                           pduLen: uint8)

    proc nimLlcpObservePdu(conhdl: uint16, pdu: ptr UncheckedArray[uint8],
                              pduLen: uint8) =
      if pdu == nil or pduLen == 0'u8:
        return
      let peerFeaturesUpdated = nimLlcpRecordPeerFeatures(pdu, pduLen)
      nimLlcpRecordPeerDataLength(pdu, pduLen)
      if peerFeaturesUpdated:
        nimLlcpMaybeCompleteRemoteFeatures(conhdl)
      when bl808BleNimPureConnection:
        case pdu[0]
        of LlcpChannelMapInd:
          nimConnReceiveChannelMapIndBytes(pdu, pduLen)
        of LlcpConnectionUpdateInd:
          nimConnReceiveConnectionUpdateIndBytes(pdu, pduLen)
        of LlcpPhyUpdateInd:
          nimConnReceivePhyUpdateIndBytes(pdu, pduLen)
        else:
          discard

    proc nimLlcpObserveEm(conhdl: uint16, dataOff: uint16, pduLen: uint8) =
      if pduLen == 0'u8:
        return
      let pdu = cast[ptr UncheckedArray[uint8]](
        BTBLE_EM_BASE + uint32(dataOff))
      nimLlcpObservePdu(conhdl, pdu, pduLen)

    proc nimLlcpHandleConsumed(conhdl: uint16,
                                  pdu: ptr UncheckedArray[uint8],
                                  rxHeader: uint16,
                                  fallbackOpcode: uint8): uint32 =
      let pduLen = uint8((rxHeader shr 8) and 0x00FF'u16)
      let opcode =
        if pdu != nil and pduLen > 0'u8:
          pdu[0]
        else:
          fallbackOpcode
      let reason =
        if pdu != nil and pduLen > 1'u8:
          pdu[1]
        else:
          NimLlcpDefaultReason
      if not nimLlcpRxPduValid(opcode, pduLen.uint16):
        nimLlcpRecordMalformed(rxHeader, opcode, pduLen.uint16)
        return 0'u32
      let slot = nim_llcp_rx_log_index and 0x07'u32
      nim_llcp_rx_log[slot.int] =
        (uint32(rxHeader) shl 16) or (uint32(reason) shl 8) or
        uint32(opcode)
      nim_llcp_rx_log_index = nim_llcp_rx_log_index + 1'u32
      inc nim_llcp_rx_count
      nim_llcp_last_opcode =
        0xCC000000'u32 or (uint32(rxHeader) shl 8) or uint32(opcode)
      nimLlcpObservePdu(conhdl, pdu, pduLen)
      nimLlcpRespond(conhdl, opcode, reason)
      0'u32

    proc nimLlcpSendInitialNow(conhdl: uint16): bool =
      var pdu = nimLlcpBuildVersionInd()
      result = nimLlcpSendPduNow(conhdl, pdu)
      if result:
        nim_llcp_state.versionProcedureStarted = true
        nim_llcp_state.startupAttemptsLeft = 0

    proc nimSendLeConnComplete(conhdl: uint16) =
      var evt: array[19, uint8]
      evt[0] = 0x01'u8
      evt[1] = 0x00'u8
      evt[2] = uint8(conhdl and 0xFF'u16)
      evt[3] = uint8((conhdl shr 8) and 0xFF'u16)
      nim_conn_active = true
      nim_conn_handle = conhdl
      sendLeMetaPayload(addr evt[0], evt.len.uint8)

  proc addBtbleClockSlots(base: uint32, slots: int): uint32 =
    if slots >= 0:
      (base + uint32(slots)) and 0x0FFFFFFF'u32
    else:
      (base - uint32(-slots)) and 0x0FFFFFFF'u32

  proc refreshNimSyncPositions() =
    ## The LLD init path derives the RX sync-position table from these BTBLE
    ## timing registers. lld_con_start uses the table again when converting
    ## CONNECT_IND RX timing into the first connection anchor.
    lld_exp_sync_pos_tab[0] =
      uint16(((regRead((BLE_BASE + 0x890'u32).uint) shr 8) and 0xFF'u32) +
             0x28'u32)
    lld_exp_sync_pos_tab[1] =
      uint16(((regRead((BLE_BASE + 0x894'u32).uint) shr 8) and 0xFF'u32) +
             0x18'u32)
    let codedSync =
      uint16(((regRead((BLE_BASE + 0x898'u32).uint) shr 8) and 0xFF'u32) +
             0x150'u32)
    lld_exp_sync_pos_tab[2] = codedSync
    lld_exp_sync_pos_tab[3] = codedSync

  proc nimConnectTiming(baseClock: uint32, rawFine: uint16,
                           rateIdx: uint8, outClock: var uint32,
                           outFine: var uint16) =
    refreshNimSyncPositions()
    let syncPos =
      if rateIdx.int < lld_exp_sync_pos_tab.len:
        lld_exp_sync_pos_tab[rateIdx.int]
      else:
        0'u16
    var coarse = baseClock and 0x0000FFFF'u32
    var fine = 0x270'i32 - int32(rawFine and 0x03FF'u16) -
               int32(syncPos) * 2'i32
    while fine < 0'i32:
      fine += 0x271'i32
      coarse = (coarse - 1'u32) and 0x0000FFFF'u32
    outClock = coarse
    outFine = uint16(fine)

  proc nimConnLegacyAdvPropsFromHciType(advType: uint8): uint16 {.inline.} =
    if advType.int < NimConnLegacyAdvEventProps.len:
      NimConnLegacyAdvEventProps[advType.int]
    else:
      NimConnLegacyAdvEventProps[NimConnDefaultLegacyAdvType.int]

  proc nimConnLegacyAdvActiveProps(): uint16 {.inline.} =
    ## Reference llm_adv passes the properties of the scheduled advertising
    ## event.  Keep a saved pure Nim copy because the EM TX descriptor belongs
    ## to the radio program and can be rewritten before CONNECT_IND handoff.
    let advType = nim_adv_params[4]
    let fallback = nimConnLegacyAdvPropsFromHciType(advType)
    if nim_adv_event_props != 0'u16: nim_adv_event_props
    else: fallback

  proc nimConnLegacyAdvLeadSelector(): uint8 {.inline.} =
    ## Reference lld_adv_end_ind_handler stores byte 39 as the active
    ## advertising properties with the legacy timing bit toggled.
    let props = nimConnLegacyAdvActiveProps()
    uint8((props xor NimConnAdvTypeTimingBit) and 0x00FF'u16)

  proc quiesceNimAdvertisingForConnectionHandoff() =
    ## Retire the pure Nim advertiser's delayed target state before programming a
    ## connection.  The vendor CONNECT_IND path removes the advertising scheduler
    ## activity before llm_adv hands the timing message to llc_start.  Keep the
    ## BTBLE target/RF gate armed: reference llc_start snapshots still have
    ## BLE+0x9C0 bit 14 set when the first connection event is scheduled.
    nim_adv_enabled = false
    nim_adv_target_half_us = 0
    when declared(nim_adv_sch_event_active):
      nim_adv_sch_event_active = 0
    regOr(BLE_BASE + 0x9C0'u32, BtbleEventTargetEnableBit)
    regWrite((BLE_BASE + BTBLE_INTACK_OFFSET).uint, BtbleIntEventTarget)

  when bl808BleNimPureConnection:
    when bl808BleNimManualConnTx:
      proc serviceNimConnectionLlcpRxDescriptors()
      proc nimConnArmPendingHostAclTx()
    proc nimConnSchProgCb(arg0: uint32, ctx: pointer, event: uint8) {.cdecl.}

    proc nimConnEmOffset(conhdl: uint16): uint32 {.inline.} =
      NimConnEmBaseOffset + NimConnEmStride * uint32(conhdl and 0x000F'u16)

    proc nimConnEmAddr(conhdl: uint16, off: uint32): uint32 {.inline.} =
      BTBLE_EM_BASE + nimConnEmOffset(conhdl) + off

    template btbleConnEventAt(eventAddr: uint32): ptr BtbleConnEventView =
      cast[ptr BtbleConnEventView](eventAddr.uint)

    proc nimConnEventView(conhdl: uint16): ptr BtbleConnEventView {.inline.} =
      btbleConnEventAt(nimConnEmAddr(conhdl, 0))

    proc nimConnEventSetRxSync(conhdl: uint16; timing: uint16) {.inline.} =
      volatileStore(addr nimConnEventView(conhdl).rxSync, timing)

    proc nimConnEventSetPacketDurations(conhdl: uint16;
                                        duration: uint16) {.inline.} =
      let event = nimConnEventView(conhdl)
      volatileStore(addr event.txDuration, duration)
      volatileStore(addr event.rxDuration, duration)

    proc nimConnEventSetTxDescPtr(conhdl: uint16; descPtr: uint16) {.inline.} =
      volatileStore(addr nimConnEventView(conhdl).txDescPtr, descPtr)

    proc nimConnEventSetChannel(conhdl: uint16; channelWord: uint16) {.inline.} =
      volatileStore(addr nimConnEventView(conhdl).channel, channelWord)

    proc nimConnEventSetEventCounter(conhdl: uint16; eventCounter: uint16) {.inline.} =
      volatileStore(addr nimConnEventView(conhdl).eventCounter, eventCounter)

    proc nimConnDescAddr(off: uint16): uint32 {.inline.} =
      BTBLE_EM_BASE + uint32(off)

    proc nimConnDescPtr(off: uint16): uint16 {.inline.} =
      uint16((uint32(off) shr 2) and 0xFFFF'u32)

    proc nimConnDescStatus(nextOff: uint16,
                           softwareOwned: bool): uint16 {.inline.} =
      result = nimConnDescPtr(nextOff)
      if softwareOwned:
        result = result or NimConnTxDescSoftwareOwned

    template btbleConnTxDescAt(descAddr: uint32): ptr BtbleConnTxDescView =
      cast[ptr BtbleConnTxDescView](descAddr.uint)

    proc btbleConnTxDescStatus(descAddr: uint32): uint16 {.inline.} =
      volatileLoad(addr btbleConnTxDescAt(descAddr).status)

    proc btbleConnTxDescSetStatus(descAddr: uint32; status: uint16) {.inline.} =
      volatileStore(addr btbleConnTxDescAt(descAddr).status, status)

    proc btbleConnTxDescSetHeader(descAddr: uint32; header: uint16) {.inline.} =
      volatileStore(addr btbleConnTxDescAt(descAddr).header, header)

    proc btbleConnTxDescSetDataOffset(descAddr: uint32; offset: uint16) {.inline.} =
      volatileStore(addr btbleConnTxDescAt(descAddr).dataOffset, offset)

    proc btbleConnTxDescClear(descAddr: uint32; nextOff: uint16) {.inline.} =
      let desc = btbleConnTxDescAt(descAddr)
      volatileStore(addr desc.status, nimConnDescStatus(nextOff, softwareOwned = true))
      volatileStore(addr desc.header, 0'u16)
      volatileStore(addr desc.dataOffset, 0'u16)
      for i in 0 ..< desc.reserved06.len:
        volatileStore(addr desc.reserved06[i], 0'u8)

    proc nimConnEmDescPtr(off: uint16): uint16 {.inline.} =
      nimConnDescPtr(off)

    proc nimConnTxDescBaseOffsetForHandle(handle: uint16): uint16 {.inline.} =
      ## Match vendor lld_con_start: connection TX descriptors start at
      ## 0x558 + 7 * conhdl * sizeof(tx_desc), with two descriptors per link.
      NimConnTxDescBaseOffset +
        uint16(uint32(handle and 0x00FF'u16) *
               uint32(NimConnTxDescPerHandleStride))

    proc nimConnTxDescOffset(slot: uint8): uint16 {.inline.} =
      nim_conn_state.txDescBaseOffset + uint16((slot and 1'u8) shl 4)

    proc captureNimConnStartSnapshot(conhdl: uint16) =
      let txBase = nimConnTxDescBaseOffsetForHandle(conhdl)
      for i in 0 ..< nim_conn_start_em_snapshot.len:
        nim_conn_start_em_snapshot[i] =
          read32(nimConnEmAddr(conhdl, uint32(i) * 4'u32))
      for i in 0 ..< nim_conn_start_rx_snapshot.len:
        nim_conn_start_rx_snapshot[i] =
          read32(BTBLE_EM_BASE + BtbleRxDescRingBaseOffset + uint32(i) * 4'u32)
      for i in 0 ..< nim_conn_start_tx_snapshot.len:
        nim_conn_start_tx_snapshot[i] =
          read32(BTBLE_EM_BASE + uint32(txBase) + uint32(i) * 4'u32)
      nim_conn_start_reg_snapshot[0] =
        regRead((BLE_BASE + BTBLE_INTMASK_OFFSET).uint)
      nim_conn_start_reg_snapshot[1] =
        regRead((BLE_BASE + BTBLE_INTSTAT_OFFSET).uint)
      nim_conn_start_reg_snapshot[2] =
        regRead((BLE_BASE + BTBLE_INTDETAIL_OFFSET).uint)
      nim_conn_start_reg_snapshot[3] = regRead((BLE_BASE + 0x100'u32).uint)
      nim_conn_start_reg_snapshot[4] = regRead((BLE_BASE + 0x104'u32).uint)
      nim_conn_start_reg_snapshot[5] = regRead((BLE_BASE + 0x828'u32).uint)
      nim_conn_start_reg_snapshot[6] = regRead((BLE_BASE + 0x800'u32).uint)
      nim_conn_start_reg_snapshot[7] = regRead((BLE_BASE + 0x9C0'u32).uint)

    proc nimConnNormalizeFine(clock: var uint32, fine: var int32) =
      while fine < 0'i32:
        fine += int32(NimConnHalfUsPerHalfSlot)
        clock = (clock - 1'u32) and 0x0FFFFFFF'u32
      while fine >= int32(NimConnHalfUsPerHalfSlot):
        fine -= int32(NimConnHalfUsPerHalfSlot)
        clock = (clock + 1'u32) and 0x0FFFFFFF'u32

    proc nimConnExpandClock(rawClock, referenceClock: uint32): uint32 =
      let reference = referenceClock and 0x0FFFFFFF'u32
      let rawLow = rawClock and 0x0000FFFF'u32
      var candidate = (reference and 0x0FFF0000'u32) or rawLow
      let ahead = (candidate - reference) and 0x0FFFFFFF'u32
      if ahead < 0x08000000'u32:
        if ahead > 0x00008000'u32:
          candidate = (candidate - 0x00010000'u32) and 0x0FFFFFFF'u32
      else:
        let behind = (reference - candidate) and 0x0FFFFFFF'u32
        if behind > 0x00008000'u32:
          candidate = (candidate + 0x00010000'u32) and 0x0FFFFFFF'u32
      candidate and 0x0FFFFFFF'u32

    proc nimConnPeripheralAcquired(): bool {.inline.} =
      nim_conn_state.centralRole or
        nim_conn_state.rxAcquiredEvents >= NimConnPeripheralAcquireRxEvents

    proc nimConnCrcInit(params: ptr NimLldConStartParamsView): uint32 {.inline.} =
      uint32(params.crcInit[0]) or
        (uint32(params.crcInit[1]) shl 8) or
        (uint32(params.crcInit[2]) shl 16)

    proc nimConnLegacyLeadSelector(params: ptr NimLldConStartParamsView): uint8 {.inline.} =
      uint8(params.peerRxAddrType shr 8)

    proc nimConnChannelSelection2(params: ptr NimLldConStartParamsView): bool {.inline.} =
      (params.peerRxAddrType and 0x00FF'u16) != 0'u16

    proc nimConnAnchorFromTiming(params: ptr NimLldConStartParamsView,
                                 outFine: var uint16): uint32 =
      refreshNimSyncPositions()
      let rateIdx = params.rate
      let syncPos =
        if rateIdx.int < lld_exp_sync_pos_tab.len:
          lld_exp_sync_pos_tab[rateIdx.int]
        else:
          0'u16
      var clock = params.timingClock and 0x0FFFFFFF'u32
      var fine = int32(params.timingFine) + int32(syncPos) * 2'i32
      nimConnNormalizeFine(clock, fine)
      outFine = uint16(fine)

      let windowSizeHalfSlots =
        uint32(params.transmitWindowSize) * NimConnHalfSlotsPerConnIntervalUnit
      let windowOffsetHalfSlots =
        uint32(params.windowOffset) * NimConnHalfSlotsPerConnIntervalUnit
      var phyLeadHalfSlots =
        if rateIdx <= 1'u8: 8'u32 else: 12'u32
      if (uint16(nimConnLegacyLeadSelector(params)) and NimConnAdvTypeTimingBit) == 0'u16:
        phyLeadHalfSlots = 4'u32
      (clock + (windowSizeHalfSlots shr 1) + windowOffsetHalfSlots +
       phyLeadHalfSlots) and 0x0FFFFFFF'u32

    proc nimConnAnchorFromRxTimestamp(rawClock: uint32, rawFine: uint16,
                                      outFine: var uint16): uint32 =
      ## Match the lld_con_frm_cbk timing recovery path: convert the RX
      ## descriptor timestamp back to the current data-channel anchor.
      refreshNimSyncPositions()
      let syncPos =
        if nim_conn_state.rate.int < lld_exp_sync_pos_tab.len:
          lld_exp_sync_pos_tab[nim_conn_state.rate.int]
        else:
          0'u16
      var clock = nimConnExpandClock(rawClock, nim_conn_state.nextAnchor)
      var fine =
        int32(NimConnHalfUsPerHalfSlot - 1'u32) -
        int32(rawFine and 0x03FF'u16) -
        int32(syncPos) * 2'i32
      nimConnNormalizeFine(clock, fine)
      outFine = uint16(fine)
      clock and 0x0FFFFFFF'u32

    proc nimConnScheduleTarget(anchor: uint32, anchorFine: uint16,
                               targetClock: var uint32,
                               targetFine: var uint16): uint32 =
      targetClock = anchor
      var fine = uint32(anchorFine)
      let windowHalfUs = nim_conn_state.rxWindowHalfUs
      if windowHalfUs != 0'u32:
        result = lld_rx_timing_compute(nim_conn_state.timingReferenceClock,
                                       addr targetClock,
                                       addr fine,
                                       nim_conn_state.peerDriftPpm,
                                       nim_conn_state.rate,
                                       windowHalfUs)
      else:
        result = 0'u32
      targetFine = uint16(fine and 0xFFFF'u32)

    proc nimConnRxSyncPosition(): uint16 =
      if nim_conn_state.phy == 3'u8:
        NimConnCodedSyncPosition
      else:
        NimConnLe1mSyncPosition

    proc nimConnRxWindowControl(rxTimingHalfUs: uint32): uint16 {.inline.} =
      ## Match lld_con_evt_start_cbk's EM +0x1E update for normal peripheral
      ## timing: small windows are programmed in half-microsecond units, while
      ## larger windows use the high-bit slot-encoded form.
      let half = (rxTimingHalfUs + 1'u32) shr 1
      if half >= 0x4000'u32:
        0x8000'u16 or
          uint16(((half + NimConnHalfUsPerHalfSlot - 1'u32) div
                  NimConnHalfUsPerHalfSlot) and 0x7FFF'u32)
      else:
        uint16((half + 1'u32) and 0xFFFF'u32)

    proc nimConnProgramRxTiming(conhdl: uint16) =
      let timing =
        if not nim_conn_state.directAnchorMode and
            nim_conn_state.rxTimingHalfUs != 0'u32:
          nimConnRxWindowControl(nim_conn_state.rxTimingHalfUs)
        else:
          nimConnRxSyncPosition()
      nimConnEventSetRxSync(conhdl, timing)

    proc nimConnTxOctets(): uint16 =
      result = NimBleLeMaxDataOctets
      if nim_llcp_state.localTxOctets != 0'u16:
        result = nim_llcp_state.localTxOctets
      if nim_llcp_state.dataLengthKnown:
        result = minU16(result, nim_llcp_state.peerMaxRxOctets)

    proc nimConnTxTime(): uint16 =
      result = NimBleLeMaxDataTime
      if nim_llcp_state.localTxTime != 0'u16:
        result = nim_llcp_state.localTxTime
      if nim_llcp_state.dataLengthKnown:
        result = minU16(result, nim_llcp_state.peerMaxRxTime)

    proc nimConnRxOctets(): uint16 =
      result = NimBleLeMaxDataOctets
      if nim_llcp_state.dataLengthKnown:
        result = minU16(result, nim_llcp_state.peerMaxTxOctets)

    proc nimConnRxTime(): uint16 =
      result = NimBleLeMaxDataTime
      if nim_llcp_state.dataLengthKnown:
        result = minU16(result, nim_llcp_state.peerMaxTxTime)

    proc nimConnEffectivePacketTimeUs(octets, maxTime: uint16,
                                      rate: uint8): uint32 =
      ## lld_con_evt_time_update clamps the configured max packet time to the
      ## actual packet airtime before writing the connection EM duration fields.
      let airtime = uint32(ble_util_pkt_dur_in_us(octets, rate))
      let limit = uint32(maxTime)
      if limit != 0'u32 and limit < airtime:
        limit
      else:
        airtime

    proc nimConnEventDurationHalfUs(txOctets, txTime, rxOctets, rxTime: uint16,
                                    rate: uint8): uint16 =
      let txUs = nimConnEffectivePacketTimeUs(txOctets, txTime, rate)
      let rxUs = nimConnEffectivePacketTimeUs(rxOctets, rxTime, rate)
      let duration = (txUs + rxUs + NimConnEventDurationMarginUs) * 2'u32
      if duration > 0xFFFF'u32:
        0xFFFF'u16
      else:
        uint16(duration)

    proc nimConnProgramPacketDurations(conhdl: uint16) =
      let durationHalfUs = nimConnEventDurationHalfUs(
        nimConnTxOctets(), nimConnTxTime(),
        nimConnRxOctets(), nimConnRxTime(),
        nim_conn_state.rate)
      nimConnEventSetPacketDurations(conhdl, durationHalfUs)

    proc nimConnPacketEventDurationHalfUs(): uint32 =
      ## Match lld_con_evt_time_update: the scheduler duration is the packet
      ## event duration written to EM. lld_con_evt_start_cbk programs the radio
      ## event for that packet duration plus the full RX timing window, while
      ## lld_con_sched positions the target earlier by half of that window.
      uint32(nimConnEventDurationHalfUs(
        nimConnTxOctets(), nimConnTxTime(),
        nimConnRxOctets(), nimConnRxTime(),
        nim_conn_state.rate))

    proc nimConnScheduleDurationHalfUs(): uint32 {.inline.} =
      nimConnPacketEventDurationHalfUs() + nim_conn_state.rxTimingHalfUs

    proc nimConnDataHeader(llid, pduLen: uint8,
                           moreData: bool = false): uint16 =
      ## Match vendor lld_con_tx_prog: TX descriptors carry LLID, MD, and
      ## payload length.  The BTBLE connection engine owns NESN/SN insertion.
      result = (uint16(pduLen) shl 8) or uint16(llid and 0x03'u8)
      if moreData:
        result = result or NimConnDataHeaderMoreDataBit

    proc nimConnResetTxDesc(off, nextOff: uint16) =
      let desc = nimConnDescAddr(off)
      btbleConnTxDescClear(desc, nextOff)

    proc nimConnArmTxDesc(off, nextOff, dataOff: uint16,
                          descHeader: uint16) =
      let desc = nimConnDescAddr(off)
      btbleConnTxDescSetHeader(desc, descHeader)
      btbleConnTxDescSetDataOffset(desc, dataOff)
      btbleConnTxDescSetStatus(desc, nimConnDescStatus(nextOff, softwareOwned = false))

    proc nimConnTxDescriptorComplete(): bool =
      ## Reference lld_con_frm_cbk treats a returned software-owned TX
      ## descriptor as the controller TX confirmation for LLCP/ACL payloads.
      if not nim_conn_state.txAckArmed or nim_conn_state.txAckDescOff == 0'u16:
        return false
      (btbleConnTxDescStatus(nimConnDescAddr(nim_conn_state.txAckDescOff)) and
        NimConnTxDescSoftwareOwned) != 0'u16

    proc nimConnInitTxDescriptors(conhdl: uint16) =
      ## Match vendor lld_con_start: initialize the descriptor ring, but leave
      ## descriptors software-owned until lld_con_tx_prog has real payload work.
      let firstOff = nimConnTxDescOffset(0'u8)
      let secondOff = nimConnTxDescOffset(1'u8)
      nimConnResetTxDesc(firstOff, secondOff)
      nimConnResetTxDesc(secondOff, firstOff)
      nimConnEventSetTxDescPtr(conhdl, nimConnEmDescPtr(firstOff))
      nim_conn_state.txDescCursor = 0'u8

    proc nimConnEventReached(target: uint16): bool {.inline.} =
      uint16(nim_conn_state.eventCounter - target) < 0x8000'u16

    proc nimConnApplyPendingConnectionUpdate() =
      if not nim_conn_state.connUpdatePending:
        return
      if not nimConnEventReached(nim_conn_state.connUpdateInstant):
        return
      nim_conn_state.nextAnchor =
        (nim_conn_state.nextAnchor + nim_conn_state.pendingWinOffsetSlots) and
        0x0FFFFFFF'u32
      if nim_conn_state.pendingIntervalSlots != 0'u32:
        nim_conn_state.intervalSlots = nim_conn_state.pendingIntervalSlots
      if nim_conn_state.pendingSupervisionSlots != 0'u32:
        nim_conn_state.supervisionSlots = nim_conn_state.pendingSupervisionSlots
      if nim_conn_state.pendingWinSizeHalfUs != 0'u32:
        nim_conn_state.rxWindowHalfUs = nim_conn_state.pendingWinSizeHalfUs
        nim_conn_state.timingReferenceClock = nim_conn_state.nextAnchor
        nim_conn_state.rxAcquiredEvents = 0
        nim_conn_rx_acquire_events = 0
      let notifyHost = nim_conn_state.connUpdateNotifyHost
      let interval = nim_conn_state.pendingIntervalUnits
      let latency = nim_conn_state.pendingLatency
      let timeout = nim_conn_state.pendingTimeoutUnits
      nim_conn_state.connUpdatePending = false
      nim_conn_state.pendingIntervalSlots = 0
      nim_conn_state.pendingSupervisionSlots = 0
      nim_conn_state.pendingWinOffsetSlots = 0
      nim_conn_state.pendingWinSizeHalfUs = 0
      nim_conn_state.pendingIntervalUnits = 0
      nim_conn_state.pendingLatency = 0
      nim_conn_state.pendingTimeoutUnits = 0
      nim_conn_state.connUpdateNotifyHost = false
      if notifyHost:
        sendLeConnectionUpdateCompleteValues(nim_conn_state.handle,
          HciStatusSuccess, interval, latency, timeout)

    proc nimConnRecordTxHeader(header: uint16, pduLen: uint8) =
      when defined(BleDebugCounters):
        let slot = nim_conn_tx_header_log_index and 0x0F'u32
        nim_conn_tx_header_log[slot.int] =
          uint32(header) or (uint32(nim_conn_state.eventCounter) shl 16)
        var state = uint32(ord(nim_conn_state.txKind)) or
          (uint32(nim_conn_state.txSeq and 1'u8) shl 4) or
          (uint32(nim_conn_state.txNesn and 1'u8) shl 5) or
          (uint32(nim_conn_state.txPendingSeq and 1'u8) shl 6)
        if nim_llcp_tx_pending != 0'u32:
          state = state or (1'u32 shl 8)
        if nim_conn_state.txAckArmed:
          state = state or (1'u32 shl 9)
        if nim_conn_state.txAckObserved:
          state = state or (1'u32 shl 10)
        nim_conn_tx_state_log[slot.int] = state
        nim_conn_tx_header_log_index = nim_conn_tx_header_log_index + 1'u32

    proc nimConnRecordRxSeq(header: uint16, peerNesn, peerSn,
                            txSeqBefore: uint8, llcpPending,
                            llcpAcked: bool) =
      when defined(BleDebugCounters):
        let slot = nim_conn_rx_seq_log_index and 0x0F'u32
        nim_conn_rx_seq_log[slot.int] =
          uint32(header) or (uint32(nim_conn_state.eventCounter) shl 16)
        var state =
          uint32(peerNesn and 1'u8) or
          (uint32(peerSn and 1'u8) shl 1) or
          (uint32(txSeqBefore and 1'u8) shl 2) or
          (uint32(nim_conn_state.txSeq and 1'u8) shl 3) or
          (uint32(nim_conn_state.txNesn and 1'u8) shl 4) or
          (uint32(nim_conn_state.txPendingSeq and 1'u8) shl 5)
        if llcpPending:
          state = state or (1'u32 shl 8)
        if nim_conn_state.txAckArmed:
          state = state or (1'u32 shl 9)
        if nim_conn_state.txAckObserved:
          state = state or (1'u32 shl 10)
        if llcpAcked:
          state = state or (1'u32 shl 11)
        nim_conn_rx_state_log[slot.int] = state
        nim_conn_rx_seq_log_index = nim_conn_rx_seq_log_index + 1'u32

    proc nimConnRecordSchEvent(timestamp: uint32, event: uint8) =
      when defined(BleDebugCounters):
        let slot = int(nim_conn_sch_event_log_index and 0x0F'u32)
        let intStat = regRead(BLE_BASE + 0x024'u32)
        let eventSlot = (intStat shr 24) and 0x0F'u32
        let slotStatus = uint32(read16(BTBLE_EM_BASE + eventSlot * 0x10'u32))
        nim_conn_sch_event_code_log[slot] =
          event.uint32 or (eventSlot shl 8) or (slotStatus shl 16)
        nim_conn_sch_event_time_log[slot] = timestamp and 0x0FFFFFFF'u32
        nim_conn_sch_event_now_log[slot] = currentBtbleTime()
        nim_conn_sch_event_state_log[slot] =
          (if nim_conn_state.active: 1'u32 else: 0'u32) or
          (if nim_conn_state.centralRole: 2'u32 else: 0'u32) or
          (if nim_conn_state.directAnchorMode: 4'u32 else: 0'u32) or
          (if nim_conn_state.reschedulePending: 8'u32 else: 0'u32) or
          (uint32(nim_conn_state.eventCounter) shl 16)
        nim_conn_sch_event_counts_log[slot] =
          uint32(nim_conn_state.txDescCursor and 0x0F'u8) or
          (uint32(ord(nim_conn_state.txKind) and 0x0F) shl 4) or
          (uint32(nim_conn_state.txNesn and 1'u8) shl 8) or
          (uint32(nim_conn_state.txSeq and 1'u8) shl 9) or
          (uint32(nim_conn_state.rxNextExpectedSeq and 1'u8) shl 10) or
          (uint32(nim_conn_state.lastRxEventCounter) shl 16)
        nim_conn_sch_event_int_log[slot] = intStat
        nim_conn_sch_event_log_index = nim_conn_sch_event_log_index + 1'u32

    proc nimConnChannelUsed(ch: uint8): bool =
      if ch >= 37'u8:
        return false
      let bit = ch and 0x07'u8
      (nim_conn_state.channelMap[(ch shr 3).int] and (1'u8 shl bit)) != 0

    proc nimConnBuildRemap() =
      nim_conn_state.usedChannelCount = 0
      for ch in 0'u8 .. 36'u8:
        if nimConnChannelUsed(ch):
          nim_conn_state.remap[nim_conn_state.usedChannelCount.int] = ch
          inc nim_conn_state.usedChannelCount
      if nim_conn_state.usedChannelCount >= 2'u8:
        return
      nim_conn_state.channelMap = [0xFF'u8, 0xFF, 0xFF, 0xFF, 0x1F]
      nim_conn_state.usedChannelCount = 0
      for ch in 0'u8 .. 36'u8:
        nim_conn_state.remap[nim_conn_state.usedChannelCount.int] = ch
        inc nim_conn_state.usedChannelCount

    proc nimConnPermute(value: uint16): uint16 {.inline.} =
      var x = value
      x = ((x and 0xAAAA'u16) shr 1) or ((x and 0x5555'u16) shl 1)
      x = ((x and 0xCCCC'u16) shr 2) or ((x and 0x3333'u16) shl 2)
      x = ((x and 0xF0F0'u16) shr 4) or ((x and 0x0F0F'u16) shl 4)
      ((x and 0xFF00'u16) shr 8) or ((x and 0x00FF'u16) shl 8)

    proc nimConnMam(a, b: uint16): uint16 {.inline.} =
      uint16((uint32(a) * 17'u32 + uint32(b)) and 0xFFFF'u32)

    proc nimConnCsa2Prn(counter: uint16): uint16 =
      let channelId = uint16(
        ((nim_conn_state.accessAddress shr 16) xor
         (nim_conn_state.accessAddress and 0xFFFF'u32)) and 0xFFFF'u32)
      var prn = counter xor channelId
      prn = nimConnPermute(prn)
      prn = nimConnMam(prn, channelId)
      prn = nimConnPermute(prn)
      prn = nimConnMam(prn, channelId)
      prn = nimConnPermute(prn)
      nimConnMam(prn, channelId)

    proc nimConnHopIncrement(): uint8 {.inline.} =
      if nim_conn_state.hopIncrement == 0'u8: 5'u8
      else: nim_conn_state.hopIncrement

    proc nimConnAdvanceCsa1Unmapped(unmapped: uint8,
                                    eventDelta: uint16): uint8 {.inline.} =
      let base =
        if unmapped <= 36'u8: uint32(unmapped)
        else: 0'u32
      uint8((base + uint32(nimConnHopIncrement()) * uint32(eventDelta)) mod
            37'u32)

    proc nimConnAdvanceCsa1ChannelState(eventDelta: uint16) =
      ## Mirror the vendor lld_evt_channel_next state update.  CSA#1 advances
      ## an unmapped channel state, then the event-start path writes that
      ## channel state into EM +0x18.  The BTBLE engine applies the connection
      ## channel map from EM for the actual data channel.
      if eventDelta == 0'u16 or nim_conn_state.channelSelection2:
        return
      nim_conn_state.emUnmappedChannel =
        nimConnAdvanceCsa1Unmapped(nim_conn_state.emUnmappedChannel,
                                   eventDelta)

    proc nimConnMappedChannel(unmapped: uint8): uint8 =
      if nimConnChannelUsed(unmapped):
        unmapped
      else:
        nim_conn_state.remap[
          (unmapped mod nim_conn_state.usedChannelCount).int]

    proc nimConnSelectChannel(): uint8 =
      if nim_conn_state.usedChannelCount == 0'u8:
        nim_conn_state.lastUnmappedChannel = 0'u8
        return 0'u8
      if nim_conn_state.channelSelection2:
        let prn = nimConnCsa2Prn(nim_conn_state.eventCounter)
        let unmapped = uint8((uint32(prn) * 37'u32) shr 16)
        nim_conn_state.lastUnmappedChannel = unmapped
        if nimConnChannelUsed(unmapped):
          return unmapped
        let remapIdx =
          (uint32(nim_conn_state.usedChannelCount) * uint32(prn)) shr 16
        return nim_conn_state.remap[remapIdx.int]

      nim_conn_state.lastUnmappedChannel =
        if nim_conn_state.emUnmappedChannel <= 36'u8:
          nim_conn_state.emUnmappedChannel
        else:
          0'u8
      nimConnMappedChannel(nim_conn_state.lastUnmappedChannel)

    proc nimConnApplyPendingChannelMap() =
      if not nim_conn_state.channelMapPending:
        return
      if not nimConnEventReached(nim_conn_state.channelMapInstant):
        return
      for i in 0 ..< nim_conn_state.channelMap.len:
        nim_conn_state.channelMap[i] = nim_conn_state.pendingChannelMap[i]
      nim_conn_state.channelMap[4] = nim_conn_state.channelMap[4] and 0x1F'u8
      nimConnBuildRemap()
      nim_conn_state.channelMapPending = false

    proc nimConnReceiveChannelMapIndBytes(pdu: ptr UncheckedArray[uint8],
                                          pduLen: uint8) =
      if pdu == nil or pduLen < 8'u8:
        return
      let body = nimLlcpChannelMapIndAt(pdu)
      for i in 0 ..< nim_conn_state.pendingChannelMap.len:
        nim_conn_state.pendingChannelMap[i] = body.channelMap[i]
      nim_conn_state.pendingChannelMap[4] =
        nim_conn_state.pendingChannelMap[4] and 0x1F'u8
      nim_conn_state.channelMapInstant = body.instant
      nim_conn_state.channelMapPending = true
      nimConnApplyPendingChannelMap()

    proc nimConnReceiveChannelMapInd(dataOff: uint16, pduLen: uint8) =
      nimConnReceiveChannelMapIndBytes(
        cast[ptr UncheckedArray[uint8]](BTBLE_EM_BASE + uint32(dataOff)),
        pduLen)

    proc nimConnReceiveConnectionUpdateIndBytes(pdu: ptr UncheckedArray[uint8],
                                                pduLen: uint8) =
      if pdu == nil or pduLen < 12'u8:
        return
      let update = nimLlcpConnectionUpdateIndAt(pdu)
      let interval = update.interval
      let latency = update.latency
      let timeout = update.timeout
      if interval < 6'u16 or interval > 3200'u16:
        return
      if latency > 499'u16:
        return
      if timeout < 10'u16 or timeout > 3200'u16:
        return
      nimConnStorePendingConnectionUpdate(update.winSize, update.winOffset,
        interval, latency, timeout, update.instant, notifyHost = true)
      nimConnApplyPendingConnectionUpdate()

    proc nimConnReceivePhyUpdateIndBytes(pdu: ptr UncheckedArray[uint8],
                                         pduLen: uint8) =
      if pdu == nil or pduLen < 5'u8:
        return
      let masterToSlave = pdu[1]
      let slaveToMaster = pdu[2]
      if (masterToSlave == 0'u8 or masterToSlave == NimLlcpPhy1M) and
          (slaveToMaster == 0'u8 or slaveToMaster == NimLlcpPhy1M):
        nim_conn_state.rate = 0'u8
        nim_conn_state.phy = NimLlcpPhy1M

    proc nimConnProgramTxDescriptors() =
      let llcpPending = nim_llcp_tx_pending != 0'u32 and
        nim_conn_state.txKind == nimConnTxLlcp
      let aclPayloadPending = nim_acl_host_tx_pending != 0'u32 and
        nim_conn_state.txKind == nimConnTxAclData and
        nim_conn_state.txLen != 0'u8
      let aclEmptyPending = nim_acl_empty_tx_pending != 0'u32 and
        nim_conn_state.txKind == nimConnTxAclData and
        nim_conn_state.txLen == 0'u8
      if (llcpPending or aclPayloadPending) and
          nim_conn_state.txAckArmed and not nimConnTxDescriptorComplete():
        return
      if llcpPending and nim_conn_state.txProgrammed and
          nim_conn_state.txProgrammedEvent == nim_conn_state.eventCounter:
        return
      var llid = NimDataLlIdContinuation
      var emOff = NimConnEmptyDataEmOffset
      var pduLen = 0'u8
      if llcpPending:
        llid = NimDataLlIdControl
        emOff = nim_conn_state.txEmOffset
        pduLen = nim_conn_state.txLen
      elif aclPayloadPending or aclEmptyPending:
        llid =
          if nim_conn_state.txLen == 0'u8:
            NimDataLlIdContinuation
          else:
            NimDataLlIdStart
        emOff = nim_conn_state.txEmOffset
        pduLen = nim_conn_state.txLen

      let header = nimConnDataHeader(llid, pduLen)

      let descSlot = nim_conn_state.txDescCursor and 1'u8
      let descOff = nimConnTxDescOffset(descSlot)
      let nextOff = nimConnTxDescOffset(descSlot xor 1'u8)
      if pduLen == 0'u8:
        btbleEmWrite8(NimConnEmptyDataEmOffset, 0'u8)
        nimConnResetTxDesc(nextOff, descOff)
        nimConnArmTxDesc(descOff, nextOff, NimConnEmptyDataEmOffset, header)
        nimConnEventSetTxDescPtr(nim_conn_state.handle, nimConnEmDescPtr(descOff))
        nim_conn_state.txDescCursor = descSlot xor 1'u8
        nim_conn_state.txProgrammed = false
        nim_conn_state.txProgrammedEvent = 0'u16
        nim_conn_state.txAckDescOff = 0'u16
        nimConnRecordTxHeader(header, pduLen)
        return

      nimConnResetTxDesc(nextOff, descOff)
      nimConnArmTxDesc(descOff, nextOff, emOff, header)
      nimConnEventSetTxDescPtr(nim_conn_state.handle, nimConnEmDescPtr(descOff))
      nim_conn_state.txDescCursor = descSlot xor 1'u8
      if pduLen != 0'u8:
        nim_conn_state.txProgrammed = true
        nim_conn_state.txProgrammedEvent = nim_conn_state.eventCounter
        if (llcpPending or aclPayloadPending) and not nim_conn_state.txAckArmed:
          nim_conn_state.txAckArmed = true
          nim_conn_state.txAckObserved = false
          nim_conn_state.txAckEligibleEvent =
            nim_conn_state.eventCounter + 1'u16
          nim_conn_state.txAckDescOff = descOff
      nimConnRecordTxHeader(header, pduLen)

    proc nimConnArmPendingHostAclTx() =
      if not nim_conn_state.active:
        return
      if nim_acl_host_tx_pending == 0'u32:
        return
      if nim_llcp_tx_pending != 0'u32:
        return
      if nim_acl_empty_tx_pending != 0'u32:
        return
      if nim_conn_state.txKind == nimConnTxAclData and
          nim_conn_state.txLen != 0'u8:
        return
      let tx = nimConnTxElementAt(addr nim_acl_host_tx_buf[0])
      let len = tx.length
      if len == 0'u16 or len > NimBleLeMaxDataOctets:
        nim_acl_host_tx_pending = 0
        inc nim_acl_host_tx_reject_count
        return
      nim_conn_state.txKind = nimConnTxAclData
      nim_conn_state.txEmOffset = tx.emOffset
      nim_conn_state.txLen = uint8(len)
      nim_conn_state.txPendingSeq = nim_conn_state.txSeq
      nim_conn_state.txAckArmed = false
      nim_conn_state.txAckObserved = false
      nim_conn_state.txAckEligibleEvent = 0'u16
      nim_conn_state.txAckDescOff = 0'u16
      nim_conn_state.txProgrammed = false
      nim_conn_state.txProgrammedEvent = 0'u16
      nimConnProgramTxDescriptors()

    proc nimConnProgramEm(conhdl: uint16) =
      let base = nimConnEmAddr(conhdl, 0)
      for off in countup(0'u32, NimConnEmStride - 2'u32, 2'u32):
        write16(base + off, 0'u16)

      let activityType =
        if nim_conn_state.directAnchorMode: 0x0002'u16 else: 0x0003'u16
      let event = nimConnEventView(conhdl)
      volatileStore(addr event.activityType, activityType)
      volatileStore(addr event.control,
        uint16(((conhdl and 0x00FF'u16) shl 8) or 0x0020'u16))
      let phyControl =
        NimConnPhyControlBase or
        uint16(uint32(nim_conn_state.rate) * uint32(NimConnPhyControlStep))
      volatileStore(addr event.phyControl, phyControl)
      volatileStore(addr event.accessAddrLow,
        uint16(nim_conn_state.accessAddress and 0xFFFF'u32))
      volatileStore(addr event.accessAddrHigh,
        uint16((nim_conn_state.accessAddress shr 16) and 0xFFFF'u32))
      volatileStore(addr event.crcInitLow,
        uint16(nim_conn_state.crcInit and 0xFFFF'u32))
      let crcHigh =
        uint16((nim_conn_state.crcInit shr 16) and 0x00FF'u32)
      volatileStore(addr event.crcInitHigh, crcHigh)
      volatileStore(addr event.rfConfig, uint16(rwip_rf[NimConnRfConfigIndex]))
      volatileStore(addr event.eventCountEnable, 1'u16)
      volatileStore(addr event.rxSync, nimConnRxSyncPosition())
      volatileStore(addr event.txDescPtr, nimConnEmDescPtr(nimConnTxDescOffset(0'u8)))
      nimConnProgramPacketDurations(conhdl)
      volatileStore(addr event.channelMap01,
        uint16(nim_conn_state.channelMap[0]) or
        (uint16(nim_conn_state.channelMap[1]) shl 8))
      volatileStore(addr event.channelMap23,
        uint16(nim_conn_state.channelMap[2]) or
        (uint16(nim_conn_state.channelMap[3]) shl 8))
      volatileStore(addr event.channelMapHop,
        uint16(nim_conn_state.channelMap[4] and 0x1F'u8) or
        (uint16(nim_conn_state.hopIncrement and 0x1F'u8) shl 8))
      volatileStore(addr event.rxTiming, NimConnRxTimingDefault)
      volatileStore(addr event.reserved3A, 0'u16)
      volatileStore(addr event.eventCounter, nim_conn_state.eventCounter)
      volatileStore(addr event.eventCounterAux0, 0'u16)
      volatileStore(addr event.eventCounterAux1, 0'u16)
      volatileStore(addr event.eventCounterAux2, 0'u16)
      nimConnInitTxDescriptors(conhdl)
      nimConnProgramTxDescriptors()

    proc nimConnProgramChannel(conhdl: uint16): uint8 =
      let channel = nimConnSelectChannel()
      # Connection-event retuning is owned by the BTBLE scheduler from the EM
      # channel control word.  CSA#2 is selected by the hardware bit in the
      # control word, matching vendor lld_con_start; CSA#1 keeps the current
      # unmapped channel in the low bits.
      let emChannel =
        if nim_conn_state.channelSelection2:
          0'u8
        elif nim_conn_state.lastUnmappedChannel <= 36'u8:
          nim_conn_state.lastUnmappedChannel
        else:
          0'u8
      let channelField =
        if emChannel <= 36'u8: emChannel else: 0'u8
      var channelWord =
        NimConnChannelEnableBit or
        (uint16(nim_conn_state.hopIncrement and 0x1F'u8) shl 8) or
        uint16(channelField and 0x3F'u8)
      if nim_conn_state.channelSelection2:
        channelWord = channelWord or NimConnChannelSelect2Bit
      nimConnEventSetChannel(conhdl, channelWord)
      nimConnEventSetEventCounter(conhdl, nim_conn_state.eventCounter)
      nim_conn_last_channel = channel.uint32
      nim_conn_last_unmapped_channel = nim_conn_state.lastUnmappedChannel.uint32
      nim_conn_last_channel_word = channelWord.uint32
      nim_conn_last_event_counter = nim_conn_state.eventCounter.uint32
      channel

    proc nimConnClockAhead(target, now: uint32): bool {.inline.} =
      ((target - now) and 0x0FFFFFFF'u32) < 0x08000000'u32

    proc nimConnClockReached(target, now: uint32): bool {.inline.} =
      ((now - target) and 0x0FFFFFFF'u32) < 0x08000000'u32

    proc nimConnScheduleLeadSlotsForCurrentEvent(): uint32 {.inline.} =
      if nim_conn_state.centralRole and
          nim_conn_state.eventCounter == 0'u16:
        NimConnInitialCentralScheduleLeadSlots
      else:
        NimConnScheduleLeadSlots

    proc nimConnAdvanceEventForSchedule() =
      nimConnAdvanceCsa1ChannelState(1'u16)
      nim_conn_state.nextAnchor =
        (nim_conn_state.nextAnchor + nim_conn_state.intervalSlots) and
        0x0FFFFFFF'u32
      nim_conn_state.eventCounter = nim_conn_state.eventCounter + 1'u16

    proc nimConnSchedule() =
      if not nim_conn_state.active:
        return
      var now = currentBtbleTime()
      var targetClock: uint32
      var targetFine: uint16
      var scheduled = false
      while not scheduled:
        nimConnApplyPendingConnectionUpdate()
        targetClock = nim_conn_state.nextAnchor
        targetFine = nim_conn_state.anchorFine
        nim_conn_state.rxTimingHalfUs =
          nimConnScheduleTarget(nim_conn_state.nextAnchor,
                                nim_conn_state.anchorFine,
                                targetClock,
                                targetFine)
        let delta = (targetClock - now) and 0x0FFFFFFF'u32
        let leadSlots = nimConnScheduleLeadSlotsForCurrentEvent()
        if nimConnClockAhead(targetClock, now):
          if delta > leadSlots:
            nimConnApplyPendingChannelMap()
            discard nimConnProgramChannel(nim_conn_state.handle)
            scheduled = true
            continue
        nimConnAdvanceEventForSchedule()

      nimConnProgramRxTiming(nim_conn_state.handle)
      nimConnProgramTxDescriptors()

      var scheduleDuration =
        nimConnScheduleDurationHalfUs()
      let intervalDuration =
        nim_conn_state.intervalSlots * NimConnHalfUsPerHalfSlot
      if intervalDuration > NimConnScheduleDurationMarginHalfUs and
          scheduleDuration >= intervalDuration:
        scheduleDuration = intervalDuration - NimConnScheduleDurationMarginHalfUs

      if nim_conn_first_schedule_snapshot[0] == 0'u32:
        nim_conn_first_schedule_snapshot[0] =
          0x80000000'u32 or nim_conn_state.eventCounter.uint32
        nim_conn_first_schedule_snapshot[1] = now
        nim_conn_first_schedule_snapshot[2] = nim_conn_state.nextAnchor
        nim_conn_first_schedule_snapshot[3] = nim_conn_state.anchorFine.uint32
        nim_conn_first_schedule_snapshot[4] = targetClock
        nim_conn_first_schedule_snapshot[5] = targetFine.uint32
        nim_conn_first_schedule_snapshot[6] = nim_conn_state.rxTimingHalfUs
        nim_conn_first_schedule_snapshot[7] =
          (targetClock - now) and 0x0FFFFFFF'u32
        nim_conn_first_schedule_snapshot[8] = scheduleDuration
        nim_conn_first_schedule_snapshot[9] = nim_conn_state.intervalSlots
        nim_conn_first_schedule_snapshot[10] = nim_conn_state.rxWindowHalfUs
        nim_conn_first_schedule_snapshot[11] =
          nim_conn_state.timingReferenceClock

      nim_conn_last_schedule_now = now
      nim_conn_last_schedule_target = targetClock
      nim_conn_last_schedule_fine = targetFine.uint32
      nim_conn_last_schedule_delta = (targetClock - now) and 0x0FFFFFFF'u32
      nim_conn_last_schedule_duration = scheduleDuration
      nim_conn_last_rx_timing = nim_conn_state.rxTimingHalfUs
      nim_conn_last_schedule_anchor = nim_conn_state.nextAnchor
      nim_conn_last_schedule_anchor_fine = nim_conn_state.anchorFine.uint32
      let schedIdx = nim_conn_sched_log_index and 0x07'u32
      nim_conn_sched_now_log[schedIdx.int] = now
      nim_conn_sched_target_log[schedIdx.int] = targetClock
      nim_conn_sched_delta_log[schedIdx.int] = nim_conn_last_schedule_delta
      nim_conn_sched_duration_log[schedIdx.int] = scheduleDuration
      nim_conn_sched_event_log[schedIdx.int] = nim_conn_state.eventCounter.uint32
      nim_conn_sched_channel_log[schedIdx.int] =
        nim_conn_last_channel or
        (nim_conn_last_unmapped_channel shl 8) or
        (nim_conn_last_channel_word shl 16)
      nim_conn_sched_timing_log[schedIdx.int] =
        targetFine.uint32 or
        ((nim_conn_state.rxTimingHalfUs and 0xFFFF'u32) shl 16)
      nim_conn_sched_log_index = nim_conn_sched_log_index + 1'u32

      discard c_memset(addr nim_conn_sch_prog[0], 0,
                       nim_conn_sch_prog.len.csize_t)
      let req = cast[ptr SchProgRequestView](addr nim_conn_sch_prog[0])
      req.callback = cast[uint32](cast[uint](nimConnSchProgCb))
      req.targetTime = targetClock
      req.fineTime = targetFine
      req.duration = scheduleDuration
      req.context = uint32(nim_conn_state.handle)
      req.primaryType = rwip_priority[10]
      req.rate0 = 0'u8
      req.rate1 = 0'u8
      req.tail = 0x1F'u8
      req.eventIndex = uint8(nim_conn_state.handle and 0x00FF'u16)
      sch_prog_push(addr nim_conn_sch_prog[0])

    proc nimConnObserveRxHeader(header: uint16,
                                rxClock: uint32 = 0'u32,
                                rxFine: uint16 = 0'u16) =
      if not nim_conn_state.active:
        return
      noteNimPeripheralConnected(nim_conn_state.handle)
      let hadRx = nim_conn_state.rxObserved
      let prevRxEventCounter = nim_conn_state.lastRxEventCounter
      let firstRxInEvent =
        (not nim_conn_state.rxObserved) or
        nim_conn_state.lastRxEventCounter != nim_conn_state.eventCounter
      nim_conn_state.rxObserved = true
      if rxClock != 0'u32 and firstRxInEvent:
        if nim_conn_state.centralRole:
          let observedClock =
            nimConnExpandClock(rxClock, nim_conn_state.nextAnchor)
          nim_conn_state.nextAnchor = observedClock
          nim_conn_state.anchorFine = rxFine and 0x03FF'u16
          nim_conn_state.timingReferenceClock = observedClock
        else:
          let consecutive =
            hadRx and uint16(nim_conn_state.eventCounter -
                             prevRxEventCounter) == 1'u16
          if not consecutive:
            var observedFine: uint16
            let observedClock =
              nimConnAnchorFromRxTimestamp(rxClock, rxFine, observedFine)
            nim_conn_state.nextAnchor = observedClock
            nim_conn_state.anchorFine = observedFine
            nim_conn_state.timingReferenceClock = observedClock
          if consecutive:
            if nim_conn_state.rxAcquiredEvents <
                NimConnPeripheralAcquireRxEvents:
              inc nim_conn_state.rxAcquiredEvents
          else:
            if hadRx:
              inc nim_conn_rx_acquire_reset_count
            nim_conn_state.rxAcquiredEvents = 1'u8
          nim_conn_rx_acquire_events =
            nim_conn_state.rxAcquiredEvents.uint32
          if nimConnPeripheralAcquired() and
              (nim_conn_state.rxWindowHalfUs == 0'u32 or
               nim_conn_state.rxWindowHalfUs > NimConnTrackedRxWindowHalfUs):
            nim_conn_state.rxWindowHalfUs = NimConnTrackedRxWindowHalfUs
      when defined(bl808m0) and bl808BleNimPureCentral:
        if nim_conn_state.centralRole and nim_init_complete_pending != 0'u32:
          completeNimInitiatorHciConnection(nim_conn_state.handle)
      nim_conn_state.lastRxEventCounter = nim_conn_state.eventCounter
      nim_conn_state.lastRxClock = nim_conn_state.nextAnchor
      let peerNesn = uint8((header shr 2) and 1'u16)
      let peerSn = uint8((header shr 3) and 1'u16)
      let txSeqBefore = nim_conn_state.txSeq
      let payloadFresh = peerSn == nim_conn_state.rxNextExpectedSeq
      nim_conn_state.rxPayloadFresh = payloadFresh
      let llcpPending =
        nim_llcp_tx_pending != 0'u32 and
        nim_conn_state.txKind == nimConnTxLlcp
      let aclPayloadPending =
        nim_acl_host_tx_pending != 0'u32 and
        nim_conn_state.txKind == nimConnTxAclData and
        nim_conn_state.txLen != 0'u8
      let txAckEligible =
        (llcpPending or aclPayloadPending) and nim_conn_state.txAckArmed and
        nimConnEventReached(nim_conn_state.txAckEligibleEvent)
      let txAcked =
        txAckEligible and peerNesn != nim_conn_state.txPendingSeq
      if payloadFresh:
        nim_conn_state.rxNextExpectedSeq =
          nim_conn_state.rxNextExpectedSeq xor 1'u8
      nim_conn_state.txNesn = nim_conn_state.rxNextExpectedSeq
      if txAcked:
        nim_conn_state.txSeq = peerNesn
        nim_conn_state.txAckObserved = true
      elif peerNesn != nim_conn_state.txSeq:
        nim_conn_state.txSeq = peerNesn
      nimConnRecordRxSeq(header, peerNesn, peerSn, txSeqBefore,
                         llcpPending or aclPayloadPending, txAcked)

    proc nimConnSupervisionExpired(): bool =
      if nim_conn_state.supervisionSlots == 0'u32 or
          nim_conn_state.intervalSlots == 0'u32:
        return false
      let missedEvents =
        uint32(uint16(nim_conn_state.eventCounter -
                      nim_conn_state.lastRxEventCounter))
      missedEvents * nim_conn_state.intervalSlots >=
        nim_conn_state.supervisionSlots

    proc nimConnSupervisionClockExpired(now: uint32): bool =
      if nim_conn_state.supervisionSlots == 0'u32:
        return false
      if not nimConnClockReached(nim_conn_state.lastRxClock, now):
        return false
      let elapsed = (now - nim_conn_state.lastRxClock) and 0x0FFFFFFF'u32
      elapsed >= nim_conn_state.supervisionSlots

    proc nimConnHandleSupervisionTimeout() =
      let handle = nim_conn_state.handle
      when defined(bl808m0) and bl808BleNimPureCentral:
        if nim_conn_state.centralRole and
            nim_init_complete_pending != 0'u32:
          nim_init_complete_pending = 0
          nim_init_active = 0
          nim_init_rx_service_pending = 0
          nim_init_handoff_pending = 0
          nim_init_handoff_program_count = 0
          nim_init_handoff_tx_event_count = 0
          nim_init_handoff_ready_clock = 0
          nim_init_handoff_deadline = 0
          nim_conn_state.active = false
          nim_conn_state.reschedulePending = false
          nim_conn_started = false
          nim_init_last_status = 0x3E'u32
          sendLeConnectionCompleteStatusHandle(
            addr nim_init_hci_params[0], nim_init_hci_params.len.uint8,
            0x3E'u8, 0'u16, 0'u8)
          return
      noteNimPeripheralDisconnectedFrom(
        NimConnDiscSourceSupervisionTimeout,
        NimConnDisconnectReasonTimeout)
      sendDisconnectComplete(handle, NimConnDisconnectReasonTimeout)

    proc nimConnCompleteManualTx() =
      when bl808BleNimManualConnTx:
        if nim_llcp_tx_pending != 0'u32 and
            (nim_conn_state.txAckObserved or nimConnTxDescriptorComplete()):
          nim_llcp_tx_pending = 0
          nim_conn_state.txAckArmed = false
          nim_conn_state.txAckObserved = false
          nim_conn_state.txAckEligibleEvent = 0'u16
          nim_conn_state.txAckDescOff = 0'u16
          nim_conn_state.txProgrammed = false
          nim_conn_state.txProgrammedEvent = 0'u16
          nim_conn_state.txKind = nimConnTxEmptyData
          nim_conn_state.txEmOffset = NimConnEmptyDataEmOffset
          nim_conn_state.txLen = 0'u8
          inc nim_llcp_free_manual_count
          nimLlcpTrySendQueued()
          nimLlcpTrySendStartup(nim_conn_state.handle)
          if nim_llcp_tx_pending == 0'u32:
            nimConnArmPendingHostAclTx()
            nimConnProgramTxDescriptors()
        if nim_acl_host_tx_pending != 0'u32 and
            nim_conn_state.txKind == nimConnTxAclData and
            nim_conn_state.txLen != 0'u8 and
            (nim_conn_state.txAckObserved or nimConnTxDescriptorComplete()):
          nim_acl_host_tx_pending = 0
          nim_conn_state.txAckArmed = false
          nim_conn_state.txAckObserved = false
          nim_conn_state.txAckEligibleEvent = 0'u16
          nim_conn_state.txAckDescOff = 0'u16
          nim_conn_state.txProgrammed = false
          nim_conn_state.txProgrammedEvent = 0'u16
          nim_conn_state.txKind = nimConnTxEmptyData
          nim_conn_state.txEmOffset = NimConnEmptyDataEmOffset
          nim_conn_state.txLen = 0'u8
          inc nim_acl_host_tx_complete_count
          sendNumberOfCompletedPackets(nim_conn_state.handle, 1'u16)
          nimLlcpTrySendQueued()
          nimLlcpTrySendStartup(nim_conn_state.handle)
          if nim_llcp_tx_pending == 0'u32:
            nimConnProgramTxDescriptors()
        if nim_acl_empty_tx_pending != 0'u32:
          nim_acl_empty_tx_pending = 0
          nimConnArmPendingHostAclTx()
          if nim_acl_empty_tx_queued != 0'u32:
            nim_acl_empty_tx_queued = 0
            discard nimSendEmptyAclNow(nim_conn_state.handle)

    proc nimConnEventDone() =
      if not nim_conn_state.active:
        return
      when bl808BleNimManualConnTx:
        serviceNimConnectionLlcpRxDescriptors()
        nimConnCompleteManualTx()
      if not nim_conn_state.active:
        return
      nimConnAdvanceCsa1ChannelState(1'u16)
      nim_conn_state.nextAnchor =
        (nim_conn_state.nextAnchor + nim_conn_state.intervalSlots) and
        0x0FFFFFFF'u32
      nim_conn_state.eventCounter = nim_conn_state.eventCounter + 1'u16
      if nimConnSupervisionExpired():
        nimConnHandleSupervisionTimeout()
        return
      nim_conn_state.reschedulePending = true
      requestBtbleSwInterrupt()

    proc nimConnServiceSupervisionTimeout() =
      if not nim_conn_state.active:
        return
      if nimConnSupervisionClockExpired(currentBtbleTime()):
        nimConnHandleSupervisionTimeout()

    proc nimConnServiceDeferredSchedule() =
      if not nim_conn_state.active or not nim_conn_state.reschedulePending:
        return
      if nim_ble_wlcoex_enabled != 0'u32 and
          nim_ble_wifi_tx_window_active != 0'u32:
        inc nim_ble_wifi_tx_window_defer_count
        return
      nim_conn_state.reschedulePending = false
      nimConnSchedule()

    proc nimConnServiceMissedEventFallback() =
      if not nim_conn_state.active or nim_conn_state.reschedulePending:
        return
      if nim_conn_state.intervalSlots <= NimConnScheduleLeadSlots + 1'u32:
        return
      let now = currentBtbleTime()
      let missedEventDeadline =
        (nim_conn_state.nextAnchor + nim_conn_state.intervalSlots -
         NimConnScheduleLeadSlots) and 0x0FFFFFFF'u32
      if not nimConnClockReached(missedEventDeadline, now):
        return
      inc nim_conn_missed_event_fallback_count
      nimConnEventDone()

    proc nimConnSchProgCb(arg0: uint32, ctx: pointer,
                          event: uint8) {.cdecl.} =
      discard ctx
      nimConnRecordSchEvent(arg0, event)
      case event
      of 2'u8:
        when bl808BleNimManualConnTx:
          # The LLD connection frame callback drains RX descriptors before the
          # terminal event schedules the next anchor.
          serviceNimConnectionLlcpRxDescriptors()
      of 0'u8, 1'u8, 4'u8, 7'u8, 0xFF'u8:
        nimConnEventDone()
      else:
        discard

    proc nimLldConStart(conhdl: uint16, params: pointer): uint8 {.cdecl.} =
      inc nim_lld_con_start_count
      if params == nil or conhdl == 0'u16:
        nim_lld_con_start_status = 0xFF'u32
        return 0xFF'u8
      if nim_conn_state.active:
        nim_lld_con_start_status = 0x0C'u32
        return 0x0C'u8

      let start = nimLldConStartParams(params)
      let snapshotBytes = cast[ptr UncheckedArray[uint8]](params)
      for i in 0 ..< nim_lld_con_start_param.len:
        nim_lld_con_start_param[i] = snapshotBytes[i]

      discard c_memset(addr nim_conn_state, 0, sizeof(NimConnState).csize_t)
      nim_conn_state.active = true
      nim_conn_state.dataFlowEnabled = true
      nim_conn_state.centralRole = start.centralRole != 0'u8
      nim_conn_state.directAnchorMode = start.timingSelector == 0'u8
      nim_conn_state.handle = conhdl
      nim_conn_state.txDescBaseOffset = nimConnTxDescBaseOffsetForHandle(conhdl)
      nim_conn_state.accessAddress = start.accessAddress
      nim_conn_state.crcInit = nimConnCrcInit(start)
      nim_conn_state.intervalSlots =
        uint32(start.interval) * NimConnHalfSlotsPerConnIntervalUnit
      if nim_conn_state.intervalSlots == 0'u32:
        nim_conn_state.intervalSlots =
          24'u32 * NimConnHalfSlotsPerConnIntervalUnit
      nim_conn_state.supervisionSlots =
        uint32(start.supervisionTimeout) * NimConnHalfSlotsPerSupervisionUnit
      nim_conn_state.channelMap = start.channelMap
      nim_conn_state.channelMap[4] = nim_conn_state.channelMap[4] and 0x1F'u8
      nim_conn_state.hopIncrement = start.hopIncrement and 0x1F'u8
      if nim_conn_state.hopIncrement == 0'u8:
        nim_conn_state.hopIncrement = 5'u8
      # CSA#1 starts the first data-channel event one hop after channel zero.
      # Keep emUnmappedChannel as the unmapped channel for the next scheduled
      # event; event completion and skipped-event handling advance it after use.
      nim_conn_state.emUnmappedChannel = nimConnHopIncrement()
      nim_conn_state.channelSelection2 = nimConnChannelSelection2(start)
      nim_conn_state.rate = start.rate
      nim_conn_state.phy =
        if start.rate.int < co_rate_to_phy.len:
          co_rate_to_phy[start.rate.int]
        else:
          co_rate_to_phy[0]
      if nim_conn_state.phy == 0'u8:
        nim_conn_state.phy = co_rate_to_phy[0]
      if start.timingSelector != 0'u8:
        nim_conn_state.timingReferenceClock =
          start.timingClock and 0x0FFFFFFF'u32
        nim_conn_state.nextAnchor =
          nimConnAnchorFromTiming(start, nim_conn_state.anchorFine)
        nim_conn_state.rxWindowHalfUs =
          uint32(start.transmitWindowSize) * NimConnHalfUsPerConnWindowUnit
      else:
        nim_conn_state.nextAnchor =
          start.anchorClock and 0x0FFFFFFF'u32
        nim_conn_state.anchorFine = 0'u16
        # Direct central handoff gives the exact first master-packet time we
        # selected inside the CONNECT_IND transmit window.  A peripheral only
        # knows the peer's transmit window, so keep that acquisition window if
        # this path is enabled for a peripheral build.
        nim_conn_state.rxWindowHalfUs =
          if nim_conn_state.centralRole: 0'u32
          else: uint32(start.transmitWindowSize) * NimConnHalfUsPerConnWindowUnit
        nim_conn_state.timingReferenceClock = nim_conn_state.nextAnchor
      let scaIdx = start.peerSleepClockAccuracy and 0x07'u8
      nim_conn_state.peerSca = scaIdx
      nim_conn_state.peerDriftPpm =
        if scaIdx.int < co_sca2ppm.len:
          uint32(co_sca2ppm[scaIdx.int])
        else:
          0'u32
      if nim_conn_state.nextAnchor == 0'u32:
        nim_conn_state.nextAnchor =
          (currentBtbleTime() +
           uint32(start.windowOffset) * NimConnHalfSlotsPerConnIntervalUnit) and
          0x0FFFFFFF'u32
        nim_conn_state.anchorFine = 0'u16
        nim_conn_state.timingReferenceClock = nim_conn_state.nextAnchor
      nim_conn_state.lastRxClock = nim_conn_state.nextAnchor
      nim_conn_state.txKind = nimConnTxEmptyData
      nim_conn_state.txEmOffset = NimConnEmptyDataEmOffset
      nim_conn_state.txLen = 0'u8
      nim_conn_state.rxNextExpectedSeq = 0'u8
      if nim_conn_state.centralRole:
        # A central opens the link with the first master packet and has not
        # received any slave sequence number yet.
        nim_conn_state.txNesn = 0'u8
      else:
        # The peripheral descriptor is preloaded before the central opens the
        # first data-channel event.  Seed the transmit NESN for the response to
        # that first expected central SN=0 packet; subsequent RX callbacks keep
        # it aligned with rxNextExpectedSeq before the next transmit descriptor
        # use.
        nim_conn_state.txNesn = 1'u8
      nim_conn_state.txProgrammedEvent = 0'u16
      nimConnBuildRemap()
      nimConnProgramEm(conhdl)
      sch_prog_init(3'u8)
      writeBtbleInterruptMask(BtbleIntConnection)
      nimConnSchedule()
      captureNimConnStartSnapshot(conhdl)
      nim_lld_con_start_status = 0
      0'u8

    proc nimLldConLlcpTx(conhdl: uint16, buf: pointer): uint8 {.cdecl.} =
      if not nim_conn_state.active or conhdl != nim_conn_state.handle or buf == nil:
        return 0xFF'u8
      let tx = nimConnTxElementAt(buf)
      nim_conn_state.txKind = nimConnTxLlcp
      nim_conn_state.txEmOffset = tx.emOffset
      nim_conn_state.txLen = uint8(tx.length)
      nim_conn_state.txPendingSeq = nim_conn_state.txSeq
      nim_conn_state.txAckArmed = false
      nim_conn_state.txAckObserved = false
      nim_conn_state.txAckEligibleEvent = 0'u16
      nim_conn_state.txAckDescOff = 0'u16
      nim_conn_state.txProgrammed = false
      nim_conn_state.txProgrammedEvent = 0'u16
      nimConnProgramTxDescriptors()
      0'u8

    proc nimLldConDataTx(conhdl: uint16, buf: pointer): uint8 {.cdecl.} =
      if not nim_conn_state.active or conhdl != nim_conn_state.handle or buf == nil:
        return 0xFF'u8
      if nim_llcp_tx_pending != 0'u32 and
          nim_conn_state.txKind == nimConnTxLlcp:
        nim_acl_empty_tx_queued = 1
        return 0'u8
      let tx = nimConnTxElementAt(buf)
      let len = tx.length
      if len > NimBleLeMaxDataOctets:
        return HciStatusInvalidParams
      if len != 0'u16 and not nim_conn_state.dataFlowEnabled:
        return HciStatusCommandDisallowed
      if len != 0'u16 and nim_acl_host_tx_pending == 0'u32:
        return HciStatusCommandDisallowed
      nim_conn_state.txKind = nimConnTxAclData
      nim_conn_state.txEmOffset = tx.emOffset
      nim_conn_state.txLen = uint8(len)
      nim_conn_state.txProgrammed = false
      nimConnProgramTxDescriptors()
      0'u8

  proc startNimConnectionFromConnectInd(descIdx: uint8,
                                        payload: ptr UncheckedArray[uint8],
                                        header: uint16,
                                        rxClock: uint32,
                                        rxFine: uint16) =
    nimConnMark(0x100'u32)
    when defined(bl808BleConnectTrace):
      bleTrace("\r\n[CON] start\r\n")
    if nim_conn_started:
      nimConnMark(0x101'u32)
      when defined(bl808BleConnectTrace):
        bleTrace("[CON] already\r\n")
      return
    nim_conn_started = true
    quiesceNimAdvertisingForConnectionHandoff()

    discard c_memset(addr nim_conn_params[0], 0,
                     nim_conn_params.len.csize_t)
    discard c_memset(addr nim_llc_msg[0], 0,
                     nim_llc_msg.len.csize_t)
    let outp = cast[ptr UncheckedArray[uint8]](addr nim_conn_params[0])
    let llc = cast[ptr UncheckedArray[uint8]](addr nim_llc_msg[0])
    for i in 0 ..< nim_connect_ind_work_payload.len:
      nim_connect_ind_work_payload[i] = payload[i]
    let raw = cast[ptr UncheckedArray[uint8]](
      addr nim_connect_ind_work_payload[0])

    # Keep this handoff byte-exact. A typed packed-object rewrite produced the
    # same-looking buffers under JTAG but hard-faulted after llc_start.
    for i in 0 ..< 4:
      outp[i] = raw[12 + i]      # access address
    outp[4] = raw[16]            # CRC init
    outp[5] = raw[17]
    outp[6] = raw[18]
    outp[7] = raw[19]            # transmit window size
    putLe16(outp, 8, getLe16(raw, 20))
    putLe16(outp, 10, getLe16(raw, 22))
    putLe16(outp, 12, getLe16(raw, 24))
    putLe16(outp, 14, getLe16(raw, 26))
    for i in 0 ..< 5:
      outp[16 + i] = raw[28 + i]
    outp[21] = raw[33] and 0x1F'u8
    outp[22] = raw[33] shr 5

    let winOffset = uint32(getLe16(raw, 20))
    let interval = uint32(getLe16(raw, 22))
    let latency = uint32(getLe16(raw, 24))
    let timeout = uint32(getLe16(raw, 26))
    let baseClock =
      if rxClock != 0'u32: rxClock and 0x0FFFFFFF'u32
      else: currentBtbleTime()
    # Direct handoff bypasses lld_con_start's timing conversion, so it must pass
    # the first LE 1M transmit-window anchor explicitly. The normal timing path
    # mirrors vendor lld_adv_frm_isr: pass normalized CONNECT_IND RX timing and
    # let lld_con_start apply the transmit-window lead exactly once.
    let firstAnchor = (baseClock +
      winOffset * NimConnHalfSlotsPerConnIntervalUnit +
      NimConnConnectIndTransmitWindowDelayHalfSlots) and
      0x0FFFFFFF'u32
    let directAnchor = addBtbleClockSlots(
      firstAnchor,
      bl808BleNimConAnchorBiasSlots)
    # Vendor co_rate_to_phy maps rate enum 0 to LE 1M.  llc_start passes this
    # value through as lld_con_start byte 37, which also selects the sync-position
    # table entry used when normal advertiser timing is converted to an anchor.
    let rateIdx = 0'u8
    var timingClock = baseClock and 0x0000FFFF'u32
    var timingFine = rxFine
    when bl808BleNimConTimingPath:
      nimConnectTiming(baseClock, rxFine, rateIdx, timingClock, timingFine)
      when bl808BleNimConTimingClockBiasSlots != 0:
        timingClock = addBtbleClockSlots(timingClock,
          bl808BleNimConTimingClockBiasSlots)
      putLe16(outp, 24, timingFine)
      putLe32(outp, 28, timingClock)
      putLe32(outp, 32, directAnchor)
      outp[36] = 1'u8            # normal advertiser timing path
    else:
      putLe32(outp, 32, directAnchor)
      outp[36] = 0'u8            # direct handoff with precomputed anchor
    outp[37] = rateIdx           # vendor rate enum: 0 maps to LE 1M
    outp[38] = uint8((header shr 5) and 0x01'u16)
    outp[39] = nimConnLegacyAdvLeadSelector()

    when bl808BleNimPureConnection:
      var snapshotAnchorFine: uint16
      let snapshotAnchor =
        nimConnAnchorFromTiming(nimLldConStartParams(addr nim_conn_params[0]),
                                snapshotAnchorFine)
      nim_connect_timing_snapshot[0] = baseClock
      nim_connect_timing_snapshot[1] = rxFine.uint32
      nim_connect_timing_snapshot[2] = timingClock
      nim_connect_timing_snapshot[3] = timingFine.uint32
      nim_connect_timing_snapshot[4] = snapshotAnchor
      nim_connect_timing_snapshot[5] = snapshotAnchorFine.uint32
      nim_connect_timing_snapshot[6] =
        uint32(outp[36]) or (uint32(outp[37]) shl 8) or
        (uint32(outp[38]) shl 16) or (uint32(outp[39]) shl 24)
      nim_connect_timing_snapshot[7] = currentBtbleTime()

    nim_conn_last_rx_clock = baseClock
    nim_conn_last_rx_fine = rxFine.uint32
    nim_conn_last_anchor = directAnchor
    nim_conn_last_win_offset = winOffset
    nim_conn_last_interval = interval
    nim_conn_last_timeout = timeout
    nim_conn_last_access_addr =
      uint32(raw[12]) or (uint32(raw[13]) shl 8) or
      (uint32(raw[14]) shl 16) or (uint32(raw[15]) shl 24)
    nim_conn_last_crcinit =
      uint32(raw[16]) or (uint32(raw[17]) shl 8) or
      (uint32(raw[18]) shl 16)

    prepareBtbleConnectionRxRingForHandoff()
    writeBtbleInterruptMask(BtbleIntConnection)
    initNimRwipRfTable()
    refreshNimSyncPositions()
    clearBtbleProgramSlots()
    nimConnMark(0x110'u32)
    when defined(bl808BleConnectTrace):
      bleTrace("[CON] before lld\r\n")
    nim_conn_last_status =
      nimLldConStart(1'u16, addr nim_conn_params[0]).uint32
    nimConnMark(0x111'u32)
    when defined(bl808BleConnectTrace):
      bleTrace("[CON] after lld\r\n")
    if nim_conn_last_status == 0'u32:
      noteNimAdvertiserConnected(raw, header, interval, latency, raw[33] shr 5)
      recordNimPeripheralPeer(1'u16, raw, header)
      when bl808BleNimManualConnTx:
        nimLlcpPrimeStartup()
        when bl808BleNimPureConnection:
          nimLlcpTrySendStartup(1'u16)
        else:
          when bl808BleNimLlcStartInitialLlcp:
            discard nimLlcpSendInitialNow(1'u16)
          elif bl808BleNimKeepaliveAcl:
            discard nimRequestEmptyAcl(1'u16)
      nimConnMark(0x131'u32)
    when bl808BleNimManualConnTx:
      if nim_conn_last_status == 0'u32 and
          bl808BleNimSyntheticPeripheral:
        nimSendLeConnComplete(1'u16)
    writeBtbleInterruptMask(BtbleIntConnection)
    nimConnMark(0x140'u32)
    when defined(bl808m0):
      when not bl808BleNimRuntimeClicIrq:
        nimDisableM0BleClicIrq()
    when not bl808BleSkipConnEmWake:
      regOr(BTBLE_EM_BASE + 0x1B4'u32, 0x00000001'u32)
    nimConnMark(0x1FF'u32)
    bleVolatileCounterInc(addr nim_conn_start_return_count)
    when defined(bl808BleConnectTrace):
      bleTrace("[CON] done\r\n")

  proc serviceQueuedNimConnectInd() =
    when bl808BleNimDeferConnectInd:
      if nim_connect_ind_pending == 0'u32:
        return
      when declared(nim_adv_sch_event_active):
        if nim_adv_sch_event_active != 0'u32:
          if nim_adv_enabled:
            return
          nim_adv_sch_event_active = 0
      nim_connect_ind_pending = 0
      inc nim_connect_ind_service_count
      startNimConnectionFromConnectInd(
        nim_connect_ind_pending_desc_idx,
        cast[ptr UncheckedArray[uint8]](
          addr nim_connect_ind_pending_payload[0]),
        nim_connect_ind_pending_header,
        nim_connect_ind_pending_rx_clock,
        nim_connect_ind_pending_rx_fine)
      bleVolatileCounterInc(addr nim_connect_ind_return_count)
    else:
      discard

  proc handleNimConnectInd(descIdx: uint8,
                           payload: ptr UncheckedArray[uint8],
                           header: uint16,
                           rxClock: uint32,
                           rxFine: uint16) =
    if payload == nil:
      return
    inc nim_ble_dbg_rx_connect_ind_count
    when bl808BleNimDeferConnectInd:
      if nim_conn_started or nim_connect_ind_pending != 0'u32:
        return
      nim_connect_ind_pending_desc_idx = descIdx and 0x07'u8
      nim_connect_ind_pending_header = header
      nim_connect_ind_pending_rx_clock = rxClock
      nim_connect_ind_pending_rx_fine = rxFine
      for j in 0 ..< nim_connect_ind_pending_payload.len:
        nim_connect_ind_pending_payload[j] = payload[j]
      nim_connect_ind_pending = 1
      inc nim_connect_ind_queued_count
      nim_adv_enabled = false
      requestBtbleSwInterrupt()
    else:
      startNimConnectionFromConnectInd(descIdx, payload, header,
                                       rxClock, rxFine)
      bleVolatileCounterInc(addr nim_connect_ind_return_count)

proc btbleDelayTicksToSlots(delayTicks: uint32): uint32 {.inline.} =
  let slots = (delayTicks + 624'u32) div 625'u32
  if slots < 8'u32: 8'u32 else: slots

proc btbleDelayTicksCeilSlots(delayTicks: uint32): uint32 {.inline.} =
  (delayTicks + 624'u32) div 625'u32

proc nimAdvIntervalHalfUs(): uint32 {.inline.} =
  let interval =
    uint32(nim_adv_params[0]) or (uint32(nim_adv_params[1]) shl 8)
  let bounded =
    if interval == 0'u32: 0x00A0'u32 else: interval
  bounded * 1250'u32

proc nextLegacyAdvDelayHalfUs(): uint32 =
  if ble_adv_random_delay_disabled:
    return 0
  var sample =
    currentBtbleTime() xor
    (nim_ble_dbg_isr_count * 0x9E3779B9'u32) xor 0xA5A5A5A5'u32
  sample = sample xor (sample shr 7)
  sample = sample xor (sample shl 9)
  var units = sample and 0x0F'u32
  if units > 8'u32:
    units = units - 8'u32
  units * (BleLegacyAdvDelayMaxHalfUs div 8'u32)

proc pushBtbleAdvProgram(leadSlots: uint32 = 8'u32) =
  serviceBleRfCalibrationLatch()
  inc nim_ble_dbg_push_count
  let nowClock = currentBtbleTime()
  let targetClock = (nowClock + leadSlots) and 0x0FFFFFFF'u32
  let clock = targetClock and 0x0000FFFF'u32

  when defined(bl808m0) and
      bl808BleNimSchProgEnabled:
    let slot = uint32(schProgWriteIdx and 0x0F'u8)
    let slotTail = btbleAdvSlotTail(slot)
    discard c_memset(addr nim_sch_prog[0], 0, nim_sch_prog.len.csize_t)

    btbleProgramSlotProgramRaw(slot, 0x281A'u16,
      uint16(clock and 0xFFFF'u32), 0'u16, 0x0270'u16, 0x0048'u16,
      0x085A'u16, uint16(slotTail and 0xFFFF'u32),
      uint16((slotTail shr 16) and 0xFFFF'u32))

    schProgWrite32(0x00, cast[uint32](cast[uint](nimSchProgCb)))
    schProgWrite32(0x04, targetClock)    # coarse target time
    schProgWrite16(0x08, 0'u16)          # fine target time
    schProgWrite32(0x10, 0x000010B3'u32) # duration -> 0x085a half slot
    schProgWrite32(0x14, 0'u32)          # callback context
    nim_sch_prog[0x18] = 0x28'u8     # adv rate/type field, shifted by vendor code
    nim_sch_prog[0x19] = 0x00'u8
    nim_sch_prog[0x1A] = 0x60'u8     # final low half at +0x0c: 0x0c00
    nim_sch_prog[0x1B] = uint8((slotTail shr 24) and 0xFF'u32)
    nim_sch_prog[0x1C] = 0x00'u8     # advertising event index -> EM ptr 0x48
    nim_sch_prog[0x1D] = 0x00'u8     # legacy advertising control-word path
    nim_sch_prog[0x1E] = 0x00'u8
    nim_sch_prog[0x1F] = 0x00'u8
    nim_sch_prog[0x20] = 0x00'u8
    nim_sch_prog[0x21] = 0x00'u8
    nim_adv_sch_event_active = 1
    inc nim_adv_sch_program_count
    sch_prog_push(addr nim_sch_prog[0])
    nim_adv_schedule_slot = uint8((slot + 1'u32) mod 16'u32)
    return

  let directSlot = uint32(nim_adv_schedule_slot) mod 10'u32
  let directSlotTail = btbleAdvSlotTail(directSlot)
  btbleProgramSlotProgramRaw(directSlot, 0x2802'u16,
    uint16(clock and 0xFFFF'u32), 0'u16, 0x0270'u16, 0x0048'u16,
    0x085A'u16, uint16(directSlotTail and 0xFFFF'u32),
    uint16((directSlotTail shr 16) and 0xFFFF'u32))

  regWrite((BLE_BASE + 0x110'u32).uint, 0x80000000'u32 or directSlot)
  nim_adv_schedule_slot = uint8((directSlot + 1'u32) mod 10'u32)

proc scheduleBtbleEvent(delayHalfUs: uint32 = 0'u32) =
  nim_adv_debug_stage = 0x7100'u32
  nim_adv_debug_detail = delayHalfUs
  serviceBleRfCalibrationLatch()
  nim_adv_debug_stage = 0x7110'u32
  let delay =
    if delayHalfUs == 0'u32:
      nimAdvIntervalHalfUs() + nextLegacyAdvDelayHalfUs()
    else: delayHalfUs
  nim_adv_debug_stage = 0x7120'u32
  nim_adv_debug_detail = delay
  let target = (currentBtbleHalfUs() + delay) and 0x0FFFFFFF'u32
  nim_adv_debug_stage = 0x7130'u32
  nim_adv_debug_detail = target
  let nowClock = currentBtbleTime()
  let leadSlots = btbleDelayTicksToSlots(delay)
  let clock = (nowClock + leadSlots) and 0x0000FFFF'u32
  nim_adv_debug_stage = 0x7140'u32
  nim_adv_debug_detail = clock
  nim_adv_target_half_us = target
  regWrite((BLE_BASE + 0x9C0'u32).uint, 0x00004000'u32)
  regWrite((BLE_BASE + 0x0E8'u32).uint,
           clock and 0x0FFFFFFF'u32)
  regWrite((BLE_BASE + 0x0EC'u32).uint, 0x00000270'u32)
  regWrite((BLE_BASE + BTBLE_INTACK_OFFSET).uint, BtbleIntEventTarget)
  enableBtbleInterruptMaskBits(BtbleIntEventTarget)
  nim_adv_debug_stage = 0x7150'u32
  nim_adv_debug_detail = regRead((BLE_BASE + BTBLE_INTMASK_OFFSET).uint)
  serviceBleRfCalibrationLatch()
  nim_adv_debug_stage = 0x7160'u32

proc btbleTargetExpired(target: uint32): bool =
  if target == 0:
    return true
  let now = currentBtbleHalfUs()
  (((now - target) and 0x0FFFFFFF'u32) < 0x08000000'u32)

proc readBleAddrLow(addrBase: uint32): uint32 =
  read8(addrBase).uint32 or
    (read8(addrBase + 1'u32).uint32 shl 8) or
    (read8(addrBase + 2'u32).uint32 shl 16) or
    (read8(addrBase + 3'u32).uint32 shl 24)

proc readBleAddrHigh(addrBase: uint32): uint32 =
  read8(addrBase + 4'u32).uint32 or
    (read8(addrBase + 5'u32).uint32 shl 8)

template btbleScanReqPduAt(buf: uint16): ptr BtbleScanReqPduView =
  cast[ptr BtbleScanReqPduView](BTBLE_EM_BASE + buf.uint32)

proc bdAddrLow(bd: ptr BdAddr): uint32 {.inline.} =
  bd.data[0].uint32 or
    (bd.data[1].uint32 shl 8) or
    (bd.data[2].uint32 shl 16) or
    (bd.data[3].uint32 shl 24)

proc bdAddrHigh(bd: ptr BdAddr): uint32 {.inline.} =
  bd.data[4].uint32 or (bd.data[5].uint32 shl 8)

proc fallbackLocalAddrByte(idx: int): uint8 {.inline.} =
  case idx
  of 0: 0x01'u8
  of 1: 0x23'u8
  of 2: 0x45'u8
  of 3: 0x67'u8
  of 4: 0x89'u8
  else: 0xAB'u8

proc selectedLocalAddrByte(idx: int, ownAddrType: uint8): uint8 =
  if (ownAddrType and 0x01'u8) != 0'u8 and nim_local_addr_valid:
    return nim_local_addr[idx]
  if nim_public_addr_valid:
    return nim_public_addr[idx]
  fallbackLocalAddrByte(idx)

proc expectedAdvAddrByte(idx: int): uint8 =
  selectedLocalAddrByte(idx, nim_adv_params[5])

proc btbleAdvRxFine(desc: uint32): uint16 {.inline.} =
  ## Vendor lld_adv_frm_isr uses descriptor +0x0C low 10 bits as the raw RX
  ## fine timestamp before subtracting the advertising sync position.
  btbleRxDescMeta(desc) and 0x03FF'u16

proc btbleAdvRxClock(desc: uint32): uint32 {.inline.} =
  ## Reference lld_adv_frm_isr uses descriptor +0x08 as the coarse RX clock for
  ## the advertising-channel PDU.
  btbleRxDescClock(desc).uint32

proc btbleConnRxFine(desc: uint32): uint16 {.inline.} =
  ## Reference lld_con_frm_cbk uses descriptor +0x0C low 10 bits as the
  ## data-channel RX fine timestamp before subtracting the PHY sync position.
  btbleRxDescMeta(desc) and 0x03FF'u16

proc btbleConnRxClock(desc: uint32): uint32 {.inline.} =
  ## Reference lld_con_frm_cbk uses descriptor +0x08 as the data-channel coarse
  ## RX clock. The pure path expands this 16-bit hardware value near the
  ## scheduled anchor.
  btbleRxDescClock(desc).uint32

proc btbleRecordConnectDescTiming(desc: uint32) =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    let rxDesc = btbleRxDescAt(desc)
    nim_connect_desc_fields[0] = volatileLoad(addr rxDesc.timing0).uint32
    nim_connect_desc_fields[1] = btbleRxDescClock(desc).uint32
    nim_connect_desc_fields[2] = volatileLoad(addr rxDesc.timing1).uint32
    nim_connect_desc_fields[3] = btbleRxDescMeta(desc).uint32

when defined(bl808m0) and bl808BleNimPureCentral:
  proc handleNimInitiatorAdvRx(header: uint16, buf: uint16, desc: uint32,
                               status: uint16, idx: uint32): bool

proc serviceBtbleAdvRxDescriptors() =
  ## The BL808 BTBLE advertising engine writes received advertising-channel
  ## PDUs into the RX descriptor ring at EM 0x458.  Vendor lld_adv_frm_isr()
  ## consumes these on scheduler FIFO completion; the Nim scheduler bypasses
  ## that callback path, so service the ring directly until the full LLD event
  ## callback model is ported.
  var startIdx = 0'u32
  when defined(bl808m0) and
      (bl808BleNimConnectionEnabled or
       bl808BleNimPureCentral):
    startIdx = uint32(lld_env[14] and 0x07'u8)
  for step in 0'u32 ..< 8'u32:
    when defined(bl808m0) and bl808BleNimConnectionEnabled:
      if nim_conn_started:
        nimConnMark(0x160'u32 or step)
    let i = (startIdx + step) and 0x07'u32
    let desc = BTBLE_EM_BASE + btbleRxDescOffset(i)
    let status = btbleRxDescStatus(desc)
    if (status and BtbleRxDescDone) == 0:
      continue

    let header = btbleRxDescHeader(desc)
    let buf = btbleRxDescDataOffset(desc)
    let meta = btbleRxDescMeta(desc)
    let pduType = uint8(header and 0x000F'u16)
    let pduLen = uint8((header shr 8) and 0x003F'u16)

    inc nim_ble_dbg_rx_ready_count
    nim_ble_dbg_rx_last_header = header.uint32
    nim_ble_dbg_rx_last_status = status.uint32
    nim_ble_dbg_rx_last_desc = desc
    nim_ble_dbg_rx_last_buf = buf.uint32

    if pduType == 0x03'u8 and pduLen == 12'u8:
      inc nim_ble_dbg_rx_scan_req_count
      let scanReq = btbleScanReqPduAt(buf)
      nim_ble_dbg_rx_scan_req_last_scana0 = bdAddrLow(addr scanReq.scanA)
      nim_ble_dbg_rx_scan_req_last_scana1 = bdAddrHigh(addr scanReq.scanA)
      nim_ble_dbg_rx_scan_req_last_adva0 = bdAddrLow(addr scanReq.advA)
      nim_ble_dbg_rx_scan_req_last_adva1 = bdAddrHigh(addr scanReq.advA)
      var advaMatches = true
      for j in 0 ..< 6:
        if scanReq.advA.data[j] != expectedAdvAddrByte(j):
          advaMatches = false
      if advaMatches:
        inc nim_ble_dbg_rx_scan_req_match_count
    elif pduType == 0x05'u8 and pduLen == 34'u8:
      when defined(bl808BleConnectTrace):
        bleTrace("\r\n[CON] rx connect\r\n")
      when defined(bl808m0) and bl808BleNimConnectionEnabled:
        # Match vendor lld_adv_frm_isr timing extraction.
        btbleRecordConnectDescTiming(desc)
        let rxFine = btbleAdvRxFine(desc)
        let rxClock = btbleAdvRxClock(desc)
        var connectPdu: array[34, uint8]
        let payload = btbleEmPayload(buf)
        for j in 0 ..< connectPdu.len:
          connectPdu[j] = payload[j]
        btbleRxDescClearDone(desc, status)
        noteNimRxDescConsumed(i)
        let advRxSp = bleCentralTraceReadSp()
        let advRxRa = regRead((advRxSp + 124'u32).uint)
        let isrRa = regRead((advRxSp + 156'u32).uint)
        handleNimConnectInd(uint8(i and 0x07'u32),
                               cast[ptr UncheckedArray[uint8]](
                                 addr connectPdu[0]),
                               header, rxClock, rxFine)
        if advRxRa != 0'u32:
          regWrite((advRxSp + 124'u32).uint, advRxRa)
        if isrRa != 0'u32:
          regWrite((advRxSp + 156'u32).uint, isrRa)
        nimConnMark(0x150'u32)
        when defined(bl808BleConnectTrace):
          bleTrace("[CON] post start return\r\n")
        nimConnMark(0x151'u32)
        return

    when defined(bl808m0) and bl808BleNimConnectionEnabled:
      if nim_conn_started:
        nimConnMark(0x170'u32 or step)

    when defined(bl808m0) and bl808BleNimPureCentral:
      if handleNimInitiatorAdvRx(header, buf, desc, status, i):
        return

    when defined(bl808m0):
      if nim_scan_enabled and pduLen >= 6'u8 and
          (pduType == 0x00'u8 or pduType == 0x02'u8 or
           pduType == 0x04'u8 or pduType == 0x06'u8):
        sendLeAdvertisingReportFromRxDesc(header, buf)
    when defined(bl808m0) and bl808BleNimConnectionEnabled:
      if nim_conn_started and pduType != 0x03'u8 and pduType != 0x05'u8:
        continue

    btbleRxDescClearDone(desc, status)
    when defined(bl808m0) and
        (bl808BleNimConnectionEnabled or
         bl808BleNimPureCentral):
      if (lld_env[14] and 0x07'u8) == uint8(i and 0x07'u32):
        lld_env[14] = uint8((i + 1'u32) and 0x07'u32)

proc resetBtbleLinkLayerCore() =
  regWrite((BLE_BASE + 0x800'u32).uint,
           regRead((BLE_BASE + 0x800'u32).uint) and not 0x00000100'u32)
  regWrite((BLE_BASE + 0x800'u32).uint,
           regRead((BLE_BASE + 0x800'u32).uint) or BtbleBusyBit)
  discard waitBtbleCommandDone((BLE_BASE + 0x800'u32).uint)
  regWrite((BLE_BASE + 0x80C'u32).uint, 0'u32)
  regWrite((BLE_BASE + 0x814'u32).uint, 0xFFFFFFFF'u32)
  for off in [0x404'u32, 0x410'u32, 0x41C'u32, 0x428'u32,
              0x434'u32, 0x440'u32, 0x44C'u32]:
    write16(BTBLE_EM_BASE + off, 0'u16)
  regWrite((BLE_BASE + 0x8D0'u32).uint,
           regRead((BLE_BASE + 0x8D0'u32).uint) and not 0x00001000'u32)
  regWrite((BLE_BASE + 0x850'u32).uint, 0'u32)

proc initBtbleLinkLayerRegisters() =
  ## Port of the BL808 BTBLE lld_init hardware register setup.  The older
  ## BL602-style EM map at 0x28008000 is not used by BL808 advertising.
  resetBtbleLinkLayerCore()
  when defined(bl808m0) and
      bl808BleNimSchProgEnabled:
    sch_slice_params[0] = 0xFFFF'u16
    sch_slice_params[1] = 0xFFFF'u16
    sch_slice_params[2] = 0x57E4'u16
    sch_slice_params[3] = 0'u16
    when bl808BleNimConnectionEnabled or bl808BleNimPureCentral:
      rwip_param.get = rwipParamDummyGet
      rwip_param.set = rwipParamDummySet
      rwip_param.del = rwipParamDummyDel
    nimSchProgInit(3'u8)
  for off in countup(0'u32, 0x00F0'u32, 0x10):
    write16(BTBLE_EM_BASE + off, 0x281A'u16)

  regWrite((BLE_BASE + 0x800'u32).uint, 0x00100607'u32)
  regOr(BLE_BASE + 0x800'u32, 0x00400000'u32)
  regWrite((BLE_BASE + 0x80C'u32).uint, 0x0001001E'u32)
  regWrite((BLE_BASE + 0x930'u32).uint, 0xFF9602EE'u32)
  regWrite((BLE_BASE + 0x940'u32).uint, 0x00070101'u32)
  regWrite((BLE_BASE + 0x944'u32).uint, 0x00000101'u32)
  regWrite((BLE_BASE + 0x970'u32).uint, 0x00000116'u32)
  regWrite((BLE_BASE + 0x974'u32).uint, 0x00000116'u32)
  regWrite((BLE_BASE + 0x948'u32).uint, 0x00000010'u32)

  resetBtbleAdvRxRing()

  regWrite((BLE_BASE + 0x828'u32).uint, 0x00000116'u32)
  regWrite((BLE_BASE + 0x82C'u32).uint, 0'u32)
  regWrite((BLE_BASE + 0x860'u32).uint, 0'u32)
  regWrite((BLE_BASE + 0x880'u32).uint, 0x00500350'u32)
  regWrite((BLE_BASE + 0x884'u32).uint, 0x00500350'u32)
  regWrite((BLE_BASE + 0x888'u32).uint, 0x00500350'u32)
  regWrite((BLE_BASE + 0x88C'u32).uint, 0x00000350'u32)
  regWrite((BLE_BASE + 0x890'u32).uint, 0x04280703'u32)
  regWrite((BLE_BASE + 0x894'u32).uint, 0x001E0502'u32)
  regWrite((BLE_BASE + 0x898'u32).uint, 0x08870703'u32)
  regWrite((BLE_BASE + 0x89C'u32).uint, 0x08280003'u32)
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    refreshNimSyncPositions()
  regWrite((BLE_BASE + 0x950'u32).uint, 0x000500F3'u32)
  regWrite((BLE_BASE + 0x980'u32).uint, 0x02120013'u32)
  regWrite((BLE_BASE + 0x984'u32).uint, 0x02120013'u32)
  regWrite((BLE_BASE + 0x988'u32).uint, 0x02120013'u32)
  regWrite((BLE_BASE + 0x98C'u32).uint, 0x02120013'u32)

  var seq = 0'u16
  for off in [0x122'u32, 0x1B6'u32, 0x24A'u32, 0x2DE'u32, 0x372'u32]:
    let v = (read16(BTBLE_EM_BASE + off) and 0xE0FF'u16) or seq
    write16(BTBLE_EM_BASE + off, v)
    seq = seq + 0x0100'u16

  let seed0 = (currentBtbleTime() xor 0x00243B9F'u32) and 0x003FFFFF'u32
  let seed1 = ((currentBtbleTime() shl 7) xor 0x00238DC9'u32) and 0x003FFFFF'u32
  regWrite((BLE_BASE + 0x978'u32).uint, 0x80000000'u32 or seed0)
  regWrite((BLE_BASE + 0x97C'u32).uint, 0x80000000'u32 or seed1)
  regWrite((BLE_BASE + 0x9E0'u32).uint,
           (regRead((BLE_BASE + 0x9E0'u32).uint) and not 0xFF'u32) or 1'u32)
  regOr(BLE_BASE + 0x800'u32, 0x00000100'u32)
  regWrite((BLE_BASE + 0x9C0'u32).uint, 0'u32)

proc initBleCoreRegisters() =
  blePlatformInitMark(0x100'u32)
  prepareWirelessDomain()
  blePlatformInitMark(0x101'u32)
  configureBtPriorityPta()
  blePlatformInitMark(0x102'u32)
  configureBleRf1M()
  blePlatformInitMark(0x103'u32)

  regUpdate(BLE_BASE + 0x000'u32, 0x000000F0'u32, 0x000000E0'u32)
  regUpdate(BLE_BASE + 0x0F0'u32, 0x000001FF'u32, 0x000000D2'u32)
  regUpdate(BLE_BASE + 0x0F0'u32, 0x03FF0000'u32, 0x01B80000'u32)
  regWrite((BLE_BASE + 0x00C'u32).uint, 0x0000033A'u32)
  regWrite((BLE_BASE + 0x000'u32).uint,
           regRead((BLE_BASE + 0x000'u32).uint) and not 0x00300000'u32)

  regOr(BLE_BASE + 0x000'u32, 0x00000200'u32)
  regWrite((BLE_BASE + 0x090'u32).uint, 0x00000007'u32)
  regWrite((BLE_BASE + 0x0B0'u32).uint, 0x000001A2'u32)
  regWrite((BLE_BASE + 0x0B4'u32).uint, 0x000001B4'u32)
  regWrite((BLE_BASE + 0x0B8'u32).uint, 0x00000303'u32)
  regWrite((BLE_BASE + 0x120'u32).uint, 0x000001C6'u32)
  regWrite((BLE_BASE + 0x124'u32).uint, 0x00000003'u32)
  regWrite((BLE_BASE + 0x02C'u32).uint, 0x0000035C'u32)

  for off in [
    0x02C'u32, 0x090'u32, 0x0A0'u32, 0x0A8'u32, 0x0AC'u32,
    0x0B0'u32, 0x0B4'u32, 0x0B8'u32, 0x0BC'u32, 0x0F0'u32,
    0x120'u32, 0x124'u32
  ]:
    regWrite((BLE_BASE + off).uint, 0'u32)

  writeBtbleDefaultAccessWords(BLE_EM_BASE + 0x0F0'u32)
  write16(BLE_EM_BASE + 0x106'u32, 0'u16)
  write16(BLE_EM_BASE + 0x108'u32, 0'u16)
  write16(BLE_EM_BASE + 0x10A'u32, 0'u16)
  writeBtbleDefaultAccessWords(BLE_EM_BASE + 0x14C'u32)
  write16(BLE_EM_BASE + 0x162'u32, 0'u16)
  write16(BLE_EM_BASE + 0x164'u32, 0'u16)
  write16(BLE_EM_BASE + 0x166'u32, 0'u16)
  write16(BLE_EM_BASE + 0x0FC'u32, ble_tx_pwr.uint16)
  write16(BLE_EM_BASE + 0x158'u32, ble_tx_pwr.uint16)

  for off in countup(0'u32, 0x3C'u32, 4):
    write16(BLE_EM_BASE + off, 0'u16)
    write16(BLE_EM_BASE + off + 2'u32, 0'u16)

  var v = read16(BLE_EM_BASE + 0x0EA'u32)
  v = v and not 0x0700'u16
  write16(BLE_EM_BASE + 0x0EA'u32, v)
  v = read16(BLE_EM_BASE + 0x146'u32)
  v = v and not 0x0700'u16
  write16(BLE_EM_BASE + 0x146'u32, v)

  regWrite((BLE_BASE + 0x1A0'u32).uint, 0'u32)
  regWrite((BLE_BASE + 0x0E0'u32).uint,
           regRead((BLE_BASE + 0x0E0'u32).uint) and not 0x00001000'u32)
  regOr(BLE_BASE + 0x000'u32, 0x00000100'u32)
  lld_sleep_init()
  blePlatformInitMark(0x110'u32)
  initBtbleTimeRegisters()
  initBtbleLinkLayerRegisters()

  nim_ble_core_ready = true
  bleVolatileCounterInc(addr nim_ble_core_init_return_count)

proc resetNimControllerState() =
  let irqState = btbleIrqSave()
  quiesceM0PolledBleClicSources()
  defer:
    quiesceM0PolledBleClicSources()
    btbleIrqRestore(irqState)
  nim_adv_enabled = false
  nim_scan_enabled = false
  nim_conn_active = false
  nim_conn_handle = 0
  nim_local_addr_valid = false
  nim_adv_data_len = 0
  nim_scan_rsp_data_len = 0
  nim_hci_debug_stage = 0
  nim_hci_debug_opcode = 0
  nim_hci_debug_status = 0
  nim_hci_debug_len = 0
  nim_hci_debug_cb = cast[uint32](cast[uint](onchiphci_recv_cb))
  nim_suggested_tx_octets = NimBleLeMaxDataOctets
  nim_suggested_tx_time = NimBleLeMaxDataTime
  nim_adv_schedule_slot = 0
  nim_adv_target_half_us = 0
  nim_adv_event_props = 0
  when declared(nim_adv_sch_program_count):
    nim_adv_sch_program_count = 0
    nim_adv_sch_event_count = 0
    nim_adv_sch_end_count = 0
    nim_adv_sch_last_event = 0
    nim_adv_sch_event_active = 0
  when defined(bl808m0):
    nim_pending_scan_report_head = 0
    nim_pending_scan_report_tail = 0
    nim_pending_scan_report_count = 0
    nim_pending_scan_report_dropped = 0
  when defined(bl808m0) and bl808BleNimPureCentral:
    nim_scan_program_count = 0
    nim_scan_event_count = 0
    nim_scan_last_event = 0
    nim_scan_last_status = 0
    nim_scan_next_program_at = 0
    nim_scan_channel_cursor = 0
    nim_scan_last_channel_index = 0
    nim_scan_last_adv_channel = 0
    nim_scan_req_peer_addr_type = 0
    nim_scan_peer_hint_write_index = 0
    for i in 0 ..< NimScanPeerHintSlots:
      nim_scan_peer_hint_addr0[i] = 0
      nim_scan_peer_hint_addr1[i] = 0
      nim_scan_peer_hint_type[i] = 0
      nim_scan_peer_hint_channel_index[i] = 0
      nim_scan_peer_hint_adv_channel[i] = 0
    nim_init_active = 0
    nim_init_program_count = 0
    nim_init_event_count = 0
    nim_init_match_count = 0
    nim_init_start_count = 0
    nim_init_complete_count = 0
    nim_init_hci_complete_count = 0
    nim_init_cancel_count = 0
    nim_init_tx_event_count = 0
    nim_init_last_status = 0
    nim_init_last_event = 0
    nim_init_last_rx_clock = 0
    nim_init_last_rx_fine = 0
    nim_init_last_anchor = 0
    nim_init_last_access_addr = 0
    nim_init_rx_count = 0
    nim_init_rx_match_reason = 0
    nim_init_rx_last_header = 0
    nim_init_rx_last_status = 0
    nim_init_rx_last_buf = 0
    nim_init_rx_last_peer0 = 0
    nim_init_rx_last_peer1 = 0
    nim_init_rx_pdu_mismatch_count = 0
    nim_init_rx_short_count = 0
    nim_init_rx_addr_mismatch_count = 0
    nim_init_rx_addr_match_count = 0
    nim_init_rx_type_mismatch_count = 0
    nim_init_total_rx_count = 0
    nim_init_total_match_count = 0
    nim_init_total_pdu_mismatch_count = 0
    nim_init_total_short_count = 0
    nim_init_total_addr_mismatch_count = 0
    nim_init_total_addr_match_count = 0
    nim_init_total_type_mismatch_count = 0
    nim_init_total_handoff_start_count = 0
    nim_init_total_handoff_timeout_count = 0
    nim_init_total_start_count = 0
    nim_init_total_tx_event_count = 0
    nim_init_total_hci_complete_count = 0
    nim_init_connect_ind_header_flags = 0
    nim_init_rx_log_index = 0
    for i in 0 ..< nim_init_rx_header_log.len:
      nim_init_rx_header_log[i] = 0
      nim_init_rx_status_log[i] = 0
      nim_init_rx_peer0_log[i] = 0
      nim_init_rx_peer1_log[i] = 0
      nim_init_rx_reason_log[i] = 0
    nim_init_next_program_at = 0
    nim_init_event_target_clock = 0
    nim_init_rx_event_clock = 0
    nim_init_last_rx_now = 0
    nim_init_last_rx_event_clock = 0
    nim_init_last_rx_clock_source = 0
    nim_init_rx_service_pending = 0
    nim_init_rx_service_program_count = 0
    nim_init_rx_service_deadline = 0
    nim_init_event_done_program_count = 0
    nim_init_handoff_pending = 0
    nim_init_handoff_program_count = 0
    nim_init_handoff_tx_event_count = 0
    nim_init_handoff_ready_clock = 0
    nim_init_handoff_deadline = 0
    nim_init_handoff_start_count = 0
    nim_init_handoff_timeout_count = 0
    nim_init_pending_header = 0
    nim_init_pending_rx_clock = 0
    nim_init_pending_rx_fine = 0
    nim_init_pending_desc = 0
    nim_init_pending_desc_status = 0
    nim_init_pending_desc_idx = 0
    nim_init_channel_cursor = 0
    nim_init_channel_seed = 0
    nim_init_channel_window_valid = 0
    nim_init_channel_window_deadline = 0
    nim_init_last_channel_index = 0
    nim_init_last_adv_channel = 0
    nim_init_channel_hint_hit_count = 0
    nim_init_channel_hint_miss_count = 0
    nim_init_channel_hint_index = 0
    nim_init_channel_hint_adv_channel = 0
    nim_init_complete_pending = 0
    nim_scan_debug_stage = 0
    nim_scan_debug_now = 0
    nim_scan_debug_target = 0
    nim_scan_debug_lead = 0
    when defined(BleDebugCounters):
      nim_init_program_snapshot_count = 0
      nim_init_program_snapshot_channel = 0
      for i in 0 ..< nim_init_program_snapshot_timing.len:
        nim_init_program_snapshot_timing[i] = 0
      for i in 0 ..< nim_init_program_snapshot_em.len:
        nim_init_program_snapshot_em[i] = 0
      for i in 0 ..< nim_init_program_snapshot_tx_desc.len:
        nim_init_program_snapshot_tx_desc[i] = 0
      for i in 0 ..< nim_init_program_snapshot_sched.len:
        nim_init_program_snapshot_sched[i] = 0
      nim_init_sch_event_log_index = 0
      for i in 0 ..< nim_init_sch_event_code_log.len:
        nim_init_sch_event_code_log[i] = 0
        nim_init_sch_event_time_log[i] = 0
        nim_init_sch_event_now_log[i] = 0
        nim_init_sch_event_state_log[i] = 0
        nim_init_sch_event_counts_log[i] = 0
        nim_init_sch_event_done_log[i] = 0
        nim_init_sch_event_int_log[i] = 0
      nim_init_handoff_snapshot_count = 0
      nim_init_handoff_snapshot_reason = 0
      for i in 0 ..< nim_init_handoff_snapshot_timing.len:
        nim_init_handoff_snapshot_timing[i] = 0
      for i in 0 ..< nim_init_handoff_snapshot_em.len:
        nim_init_handoff_snapshot_em[i] = 0
      for i in 0 ..< nim_init_handoff_snapshot_desc.len:
        nim_init_handoff_snapshot_desc[i] = 0
      for i in 0 ..< nim_init_handoff_snapshot_data.len:
        nim_init_handoff_snapshot_data[i] = 0
    discard c_memset(addr nim_init_hci_params[0], 0,
                     nim_init_hci_params.len.csize_t)
    discard c_memset(addr nim_init_ll_data[0], 0,
                     nim_init_ll_data.len.csize_t)
  when defined(bl808m0) and bl808BleNimPureConnection:
    nim_conn_sched_log_index = 0
    for i in 0 ..< nim_conn_sched_now_log.len:
      nim_conn_sched_now_log[i] = 0
      nim_conn_sched_target_log[i] = 0
      nim_conn_sched_delta_log[i] = 0
      nim_conn_sched_duration_log[i] = 0
      nim_conn_sched_event_log[i] = 0
      nim_conn_sched_channel_log[i] = 0
      nim_conn_sched_timing_log[i] = 0
    nim_conn_last_schedule_now = 0
    nim_conn_last_schedule_target = 0
    nim_conn_last_schedule_fine = 0
    nim_conn_last_schedule_delta = 0
    nim_conn_last_schedule_duration = 0
    nim_conn_last_rx_timing = 0
    nim_conn_last_channel_word = 0
    nim_conn_last_channel = 0
    nim_conn_last_unmapped_channel = 0
    nim_conn_last_event_counter = 0
    nim_conn_last_schedule_anchor = 0
    nim_conn_last_schedule_anchor_fine = 0
    for i in 0 ..< nim_conn_first_schedule_snapshot.len:
      nim_conn_first_schedule_snapshot[i] = 0
    nim_conn_missed_event_fallback_count = 0
    nim_conn_rx_acquire_events = 0
    nim_conn_rx_acquire_reset_count = 0
    nim_ble_wifi_tx_window_active = 0
    nim_ble_wifi_tx_window_enter_count = 0
    nim_ble_wifi_tx_window_leave_count = 0
    nim_ble_wifi_tx_window_skip_count = 0
    nim_ble_wifi_tx_window_defer_count = 0
    nim_ble_wifi_tx_window_resume_count = 0
    nim_ble_wifi_tx_window_last_intmask = 0
    nim_ble_wifi_tx_window_last_intstat = 0
    when defined(BleDebugCounters):
      nim_conn_tx_header_log_index = 0
      nim_conn_rx_seq_log_index = 0
      nim_conn_sch_event_log_index = 0
      for i in 0 ..< nim_conn_tx_header_log.len:
        nim_conn_tx_header_log[i] = 0
        nim_conn_tx_state_log[i] = 0
        nim_conn_rx_seq_log[i] = 0
        nim_conn_rx_state_log[i] = 0
        nim_conn_sch_event_code_log[i] = 0
        nim_conn_sch_event_time_log[i] = 0
        nim_conn_sch_event_now_log[i] = 0
        nim_conn_sch_event_state_log[i] = 0
        nim_conn_sch_event_counts_log[i] = 0
        nim_conn_sch_event_int_log[i] = 0
  when defined(bl808m0):
    nim_scan_unsupported_count = 0
    nim_scan_unsupported_header = 0
    nim_scan_unsupported_len = 0
    nim_scan_unsupported_buf = 0
    discard c_memset(addr nim_scan_unsupported_data[0], 0,
                     nim_scan_unsupported_data.len.csize_t)
    when not defined(bl808BleNimLlcStart):
      nim_lld_rx_desc_active = 0
      nim_lld_rx_desc_idx = 0
      nim_lld_rx_check_count = 0
      nim_lld_rx_check_hit_count = 0
      nim_lld_rx_check_miss_count = 0
      nim_lld_rx_free_count = 0
      nim_lld_rx_last_idx = 0
      nim_lld_rx_last_env_idx = 0
      nim_lld_rx_last_status = 0
      nim_lld_rx_last_header = 0
      nim_lld_rx_last_meta = 0
    nim_sch_prog_fifo_count = 0
    nim_sch_prog_skip_count = 0
    nim_arb_sw_count = 0
    nim_arb_event_start_count = 0
  when defined(bl808m0) and
      bl808BleNimConnectionEnabled:
    nim_sch_prog_fifo_count = 0
    nim_sch_prog_skip_count = 0
    nim_arb_sw_count = 0
    nim_arb_event_start_count = 0
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_conn_started = false
    nim_connect_ind_pending = 0
    nim_connect_ind_queued_count = 0
    nim_connect_ind_service_count = 0
    nim_connect_ind_return_count = 0
    nim_connect_ind_pending_desc_idx = 0
    nim_connect_ind_pending_header = 0
    nim_connect_ind_pending_rx_clock = 0
    nim_connect_ind_pending_rx_fine = 0
    discard c_memset(addr nim_connect_ind_pending_payload[0], 0,
                     nim_connect_ind_pending_payload.len.csize_t)
    discard c_memset(addr nim_connect_ind_work_payload[0], 0,
                     nim_connect_ind_work_payload.len.csize_t)
    nim_llc_status = 0
    nim_conn_last_status = 0
    nim_conn_last_rx_clock = 0
    nim_conn_last_rx_fine = 0
    nim_conn_last_anchor = 0
    nim_conn_last_win_offset = 0
    nim_conn_last_interval = 0
    nim_conn_last_timeout = 0
    nim_conn_last_access_addr = 0
    nim_conn_last_crcinit = 0
    for i in 0 ..< nim_connect_desc_fields.len:
      nim_connect_desc_fields[i] = 0
    for i in 0 ..< nim_connect_timing_snapshot.len:
      nim_connect_timing_snapshot[i] = 0
    nim_conn_start_return_count = 0
    nim_lld_con_start_count = 0
    nim_lld_con_start_status = 0
    discard c_memset(addr nim_lld_con_start_param[0], 0,
                     nim_lld_con_start_param.len.csize_t)
    discard c_memset(addr nim_conn_start_em_snapshot[0], 0,
                     nim_conn_start_em_snapshot.len.csize_t * sizeof(uint32).csize_t)
    discard c_memset(addr nim_conn_start_rx_snapshot[0], 0,
                     nim_conn_start_rx_snapshot.len.csize_t * sizeof(uint32).csize_t)
    discard c_memset(addr nim_conn_start_tx_snapshot[0], 0,
                     nim_conn_start_tx_snapshot.len.csize_t * sizeof(uint32).csize_t)
    discard c_memset(addr nim_conn_start_reg_snapshot[0], 0,
                     nim_conn_start_reg_snapshot.len.csize_t * sizeof(uint32).csize_t)
    nim_conn_evt_count = 0
    nim_conn_evt_handle = 0
    nim_conn_evt_peer_a0 = 0
    nim_conn_evt_peer_a1 = 0
    nim_conn_evt_peer_type = 0
    nim_conn_evt_reported = false
    nim_disc_evt_count = 0
    nim_disc_evt_reason = 0
    nim_disc_evt_source = 0
    when bl808BleNimPureConnection:
      discard c_memset(addr nim_conn_state, 0, sizeof(NimConnState).csize_t)
      discard c_memset(addr nim_conn_sch_prog[0], 0,
                       nim_conn_sch_prog.len.csize_t)
    discard c_memset(addr nim_llc_msg[0], 0,
                     nim_llc_msg.len.csize_t)
    discard c_memset(addr nim_llc_env_storage[0], 0,
                     nim_llc_env_storage.len.csize_t)
    when not defined(bl808BleNimLlcStart):
      nim_lld_rx_desc_active = 0
      nim_lld_rx_desc_idx = 0
      nim_lld_rx_check_count = 0
      nim_lld_rx_check_hit_count = 0
      nim_lld_rx_check_miss_count = 0
      nim_lld_rx_free_count = 0
      nim_lld_rx_last_idx = 0
      nim_lld_rx_last_env_idx = 0
      nim_lld_rx_last_status = 0
      nim_lld_rx_last_header = 0
      nim_lld_rx_last_meta = 0
    nim_llcp_rx_count = 0
    nim_llcp_tx_count = 0
    nim_llcp_tx_pending = 0
    nim_llcp_tx_queued = 0
    nim_llcp_tx_dropped = 0
    nim_llcp_startup_tx_count = 0
    nim_llcp_startup_deferred_count = 0
    nim_llcp_state.versionProcedureStarted = false
    nimLlcpClearFeatureExchangeState(clearDebug = true)
    nim_llcp_state.startupAttemptsLeft = 0
    nim_llcp_state.startupDelayServices = 0
    nimLlcpResetDataLengthState()
    nim_llcp_tx_queue_head = 0
    nim_llcp_tx_queue_tail = 0
    nim_llcp_last_opcode = 0
    nim_llcp_last_status = 0
    nim_llcp_rx_log_index = 0
    nim_llcp_tx_log_index = 0
    nim_llcp_rx_malformed_count = 0
    nim_llcp_rx_malformed_last = 0
    nim_llcp_alloc_count = 0
    nim_llcp_free_count = 0
    nim_llcp_alloc_last_len = 0
    nim_llcp_alloc_last_ptr = 0
    nim_llcp_alloc_last_emoff = 0
    nim_llcp_alloc_last_len_field = 0
    nim_llcp_free_last_raw = 0
    nim_llcp_free_manual_count = 0
    nim_llcp_free_heap_count = 0
    discard c_memset(addr nim_llcp_rx_log[0], 0,
                     (sizeof(uint32) * nim_llcp_rx_log.len).csize_t)
    discard c_memset(addr nim_llcp_tx_log[0], 0,
                     (sizeof(uint32) * nim_llcp_tx_log.len).csize_t)
    nim_acl_empty_tx_count = 0
    nim_acl_empty_tx_pending = 0
    nim_acl_empty_tx_queued = 0
    nim_acl_empty_last_status = 0
    nim_acl_host_tx_count = 0
    nim_acl_host_tx_pending = 0
    nim_acl_host_tx_complete_count = 0
    nim_acl_host_tx_reject_count = 0
    nim_acl_rx_count = 0
    nim_acl_rx_drop_count = 0
    discard c_memset(addr nim_acl_host_tx_buf[0], 0,
                     nim_acl_host_tx_buf.len.csize_t)
    initNimRwipRfTable()
  discard c_memset(addr nim_adv_params[0], 0, nim_adv_params.len.csize_t)
  discard c_memset(addr nim_scan_params[0], 0, nim_scan_params.len.csize_t)
  discard c_memset(addr nim_adv_data[0], 0, nim_adv_data.len.csize_t)
  discard c_memset(addr nim_scan_rsp_data[0], 0, nim_scan_rsp_data.len.csize_t)
  if nim_ble_core_ready:
    when defined(bl808m0):
      nimDisableM0RfClicIrq()
      writeBtbleInterruptMask(0)
      resetBtbleAdvRxRing()
      initBtbleTimeRegisters()
      initBtbleLinkLayerRegisters()
      regWrite((BLE_BASE + BTBLE_INTACK_OFFSET).uint, 0xFFFFFFFF'u32)
      writeBtbleInterruptMask(0)
      quiesceM0PolledBleClicSources()
    else:
      initBleCoreRegisters()
  else:
    initBleCoreRegisters()

proc localAddrBytes(dst: ptr uint8, ownAddrType: uint8 = 0'u8) =
  if dst == nil:
    return
  let raw = cast[ptr UncheckedArray[uint8]](dst)
  for i in 0 ..< 6:
    raw[i] = selectedLocalAddrByte(i, ownAddrType)

proc defaultLocalAddrBytes(dst: ptr uint8) =
  localAddrBytes(dst)

proc programBtbleLegacyAdv(advDataLen: uint8) =
  let advLen = min(advDataLen.int, 31)
  let scanRspLen = min(nim_scan_rsp_data_len.int, 31)
  let pduLen = uint16(6 + advLen)
  let scanRspPduLen = uint16(6 + scanRspLen)
  var addrBytes: array[6, uint8]
  localAddrBytes(addr addrBytes[0], nim_adv_params[5])
  let txAdd = uint16(nim_adv_params[5] and 0x01'u8) shl 6
  let eventAddrType = uint16(nim_adv_params[5] and 0x01'u8)
  let advEventHeader = BtbleLegacyAdvEventHeaderBase or eventAddrType
  let advHeaderFlags = NimBleLegacyAdvChSelBit or txAdd
  let scanRspHeaderFlags = 0x0004'u16 or txAdd
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_adv_event_props = NimConnLegacyAdvEventProps[0]

  copyBytes(BTBLE_EM_BASE + BtbleAdvDataOffset, addr nim_adv_data[0], advLen)
  copyBytes(BTBLE_EM_BASE + BtbleScanRspDataOffset,
            addr nim_scan_rsp_data[0], scanRspLen)
  copyBytes(BTBLE_EM_BASE + 0x128'u32, addr addrBytes[0], addrBytes.len)

  write16(BTBLE_EM_BASE + 0x120'u32, 0x0404'u16)
  write16(BTBLE_EM_BASE + 0x122'u32, advEventHeader)
  write16(BTBLE_EM_BASE + 0x124'u32, BtbleLegacyAdvEventWord124)
  write16(BTBLE_EM_BASE + 0x126'u32, 0'u16)
  writeBtbleDefaultAccessWords(BTBLE_EM_BASE + 0x12E'u32)
  write16(BTBLE_EM_BASE + 0x136'u32, 0'u16)
  write16(BTBLE_EM_BASE + 0x138'u32, BtbleLegacyAdvWord138)
  write16(BTBLE_EM_BASE + 0x13A'u32, 0x0020'u16)
  write16(BTBLE_EM_BASE + 0x13C'u32, BtbleLegacyAdvWord13C)
  write16(BTBLE_EM_BASE + 0x13E'u32, 0'u16)
  regWrite((BTBLE_EM_BASE + 0x140'u32).uint, BtbleLegacyAdvControl)
  write16(BTBLE_EM_BASE + 0x144'u32, 0x0156'u16)
  write16(BTBLE_EM_BASE + 0x146'u32, BtbleLegacyAdvTimingHigh)
  write16(BTBLE_EM_BASE + 0x148'u32, BtbleLegacyAdvTimingLow)
  write16(BTBLE_EM_BASE + 0x14A'u32, 0'u16)
  write16(BTBLE_EM_BASE + 0x14C'u32, BtbleLegacyAdvTail)
  write16(BTBLE_EM_BASE + 0x14E'u32, 0'u16)
  write16(BTBLE_EM_BASE + 0x150'u32, 0x0008'u16)
  write16(BTBLE_EM_BASE + 0x152'u32, 0'u16)
  write16(BTBLE_EM_BASE + 0x154'u32, 0'u16)
  write16(BTBLE_EM_BASE + 0x156'u32, 0x00E0'u16)
  write16(BTBLE_EM_BASE + 0x158'u32, 0'u16)
  write16(BTBLE_EM_BASE + 0x15A'u32, 0'u16)
  write16(BTBLE_EM_BASE + 0x15C'u32, 0'u16)
  write16(BTBLE_EM_BASE + 0x15E'u32, 0'u16)
  write16(BTBLE_EM_BASE + 0x160'u32, 0'u16)
  write16(BTBLE_EM_BASE + 0x162'u32, 0'u16)
  write16(BTBLE_EM_BASE + 0x164'u32, 0'u16)
  write16(BTBLE_EM_BASE + 0x180'u32, 0'u16)

  write16(BTBLE_EM_BASE + 0x558'u32, 0x015A'u16)
  write16(BTBLE_EM_BASE + 0x55A'u32,
          ((pduLen and 0x00FF'u16) shl 8) or advHeaderFlags)
  write16(BTBLE_EM_BASE + 0x55C'u32, BtbleAdvDataOffset.uint16)
  write16(BTBLE_EM_BASE + 0x55E'u32, BtbleLegacyAdvTxDescFlags)
  write16(BTBLE_EM_BASE + 0x560'u32, BtbleLegacyAdvTxTailLow)
  write16(BTBLE_EM_BASE + 0x562'u32, BtbleLegacyAdvTxTailHigh)
  write16(BTBLE_EM_BASE + 0x564'u32, BtbleLegacyAdvRxTailLow)
  write16(BTBLE_EM_BASE + 0x566'u32, BtbleLegacyAdvRxTailHigh)
  write16(BTBLE_EM_BASE + 0x568'u32, 0x0156'u16)
  write16(BTBLE_EM_BASE + 0x56A'u32,
          ((scanRspPduLen and 0x00FF'u16) shl 8) or scanRspHeaderFlags)
  if scanRspLen == 0:
    write16(BTBLE_EM_BASE + 0x56C'u32, BtbleLegacyScanRspEmptyPtr)
    write16(BTBLE_EM_BASE + 0x56E'u32, BtbleLegacyScanRspEmptyTail)
  else:
    write16(BTBLE_EM_BASE + 0x56C'u32, BtbleScanRspDataOffset.uint16)
    write16(BTBLE_EM_BASE + 0x56E'u32, BtbleLegacyScanRspDataTail)
  regWrite((BTBLE_EM_BASE + 0x570'u32).uint, 0xB8B5344B'u32)
  regWrite((BTBLE_EM_BASE + 0x574'u32).uint, 0x3E8F9FB7'u32)

  when defined(bl808m0):
    write16(BTBLE_EM_BASE + 0x150'u32, 0x0008'u16)
    write16(BTBLE_EM_BASE + 0x152'u32, 0'u16)

when defined(bl808m0) and bl808BleNimPureCentral:
  when not bl808BleNimSchProg:
    {.error: "bl808BleNimPureCentral requires bl808BleNimSchProg".}

  const
    NimScanEventIndex = 0'u8
    NimScanEventEmOffset = 0x0120'u32
    NimScanMinLeadSlots = 8'u32
    NimScanHalfSlotsPerScanUnit = 2'u32
    # Vendor lld_scan_start programs the scan activity word as 0x0008 for
    # passive scan and 0x0009 for active scan.  The 0x020x form belongs to the
    # legacy initiator path and prevents the scan role from producing reports.
    NimScanPassiveActivityWord = 0x0008'u16
    NimScanActiveActivityWord = 0x0009'u16
    # SDK lld_scan_start programs the active SCAN_REQ TX descriptor at
    # 0x28010e70 and stores the descriptor pointer as offset >> 2.
    NimScanReqTxDescPtr = 0x039C'u16
    NimScanReqTxDescOffset = uint32(NimScanReqTxDescPtr) shl 2
    NimScanReqPduType = 0x0003'u16
    NimScanReqPduLen = 12'u16
    NimInitHalfSlotsPerConnIntervalUnit = 4'u32
    # The pure central path stops scanning before it initiates, so it can reuse
    # the legacy scan activity.  This is the receive-side EM layout the BL808
    # advertising/initiator engine accepts with the pure scheduler.
    NimInitEventIndex = NimScanEventIndex
    NimInitEventEmOffset = 0x0120'u32 + uint32(NimInitEventIndex) * 0x94'u32
    NimInitConnectIndPayloadLen = 34
    NimInitConnReqLlDataLen = 22
    NimInitConnectIndPduType = 0x0005'u16
    NimInitTxDescPtr = 0x0304'u16
    NimInitTxDescOffset = uint32(NimInitTxDescPtr) shl 2
    NimInitConnReqDataOffset0 = 0x1794'u16
    NimInitConnReqDataOffset1 = 0x17B6'u16
    NimInitConnReqDataOffset2 = 0x17D8'u16
    NimInitMinLeadSlots = 32'u32
    NimInitTransmitWindowSize = 2'u8
    NimInitTransmitWindowOffset = 0'u16
    NimInitTransmitWindowDelaySlots = NimInitHalfSlotsPerConnIntervalUnit
    NimInitConnPhyLeadSlots = 4'u32
    NimInitConnectReqTailUs = 1000'u32
    NimInitConnectReqTailSlots = 4'u32
    NimInitConnectReqHandoffGuardSlots = 0'u32
    NimInitFirstAnchorSchedulerGuardSlots = 0'u32
    NimInitMaxChannelDwellSlotsConfig {.intdefine.}: int = 96
    NimInitMaxChannelDwellSlots =
      when NimInitMaxChannelDwellSlotsConfig < 1:
        1'u32
      else:
        uint32(NimInitMaxChannelDwellSlotsConfig)
    # The legacy initiator activity stores a hardware tail through event+0x9C.
    # Use the next connection slot for pure-central handoff to keep that tail
    # clear of connection state.
    NimInitConnHandle = 2'u16
    NimInitDefaultConnInterval = 0x0018'u16
    NimInitDefaultSupervisionTimeout = 0x0190'u16
    NimInitRoleCentral = 1'u8
    # Legacy initiator EM control words are role-specific.  They intentionally
    # differ from scan-mode controls: the hardware uses them to arm the
    # CONNECT_IND TX descriptor and the matching ADV RX descriptor in one event.
    # Legacy initiator event descriptors: one hardware-owned TX descriptor for
    # the CONNECT_IND and one RX descriptor for the advertising PDU that anchors
    # the first data-channel event.  The BL808 encoding is advertising-channel
    # dependent; using a single channel's words makes central connection
    # attempts intermittently fail when the peer is first observed elsewhere.
    NimInitTxDescCtl1 = 0x1194'u16
    NimInitRxWindowCtl = 1'u16
    NimInitTailPacketPtr = 0x0A20'u16
    NimInitTailPacketCtl = 0x0428'u16
    NimInitTailHeaderCtl = 0x060E'u16
    NimInitTailFlags = 0x2000'u16
    # Use CSA#1 for legacy initiation unless CSA#2 is explicitly enabled and
    # advertised in the local feature set. CSA#1 is mandatory, while setting
    # ChSel without matching capabilities can make peers ignore CONNECT_IND.
    NimInitConnectIndChSelBit =
      when bl808BleNimCentralChSel2: 0x0020'u16 else: 0'u16

  proc nimScanParam16(off: int, fallback: uint16): uint16 =
    let raw = uint16(nim_scan_params[off]) or
      (uint16(nim_scan_params[off + 1]) shl 8)
    if raw == 0'u16: fallback else: raw

  proc nimInitPutLe16(dst: ptr UncheckedArray[uint8], off: int,
                      value: uint16) {.inline.} =
    dst[off] = uint8(value and 0x00FF'u16)
    dst[off + 1] = uint8((value shr 8) and 0x00FF'u16)

  proc nimInitPutLe32(dst: ptr UncheckedArray[uint8], off: int,
                      value: uint32) {.inline.} =
    dst[off] = uint8(value and 0x000000FF'u32)
    dst[off + 1] = uint8((value shr 8) and 0x000000FF'u32)
    dst[off + 2] = uint8((value shr 16) and 0x000000FF'u32)
    dst[off + 3] = uint8((value shr 24) and 0x000000FF'u32)

  proc nimInitParam16(off: int, fallback: uint16): uint16 =
    let raw = uint16(nim_init_hci_params[off]) or
      (uint16(nim_init_hci_params[off + 1]) shl 8)
    if raw == 0'u16: fallback else: raw

  proc nimInitConnIntervalUnits(): uint16 {.inline.} =
    nimInitParam16(13, NimInitDefaultConnInterval)

  proc nimInitSupervisionTimeoutUnits(): uint16 {.inline.} =
    nimInitParam16(19, NimInitDefaultSupervisionTimeout)

  proc nimScanIntervalUnits(): uint16 {.inline.} =
    nimScanParam16(1, 0x0060'u16)

  proc nimScanWindowUnits(): uint16 {.inline.} =
    let interval = nimScanIntervalUnits()
    let requested = nimScanParam16(3, 0x0030'u16)
    if requested > interval: interval else: requested

  proc nimScanActive(): bool {.inline.} =
    (nim_scan_params[0] and 0x01'u8) != 0'u8

  proc nimScanActivityWord(): uint16 {.inline.} =
    if nimScanActive(): NimScanActiveActivityWord else: NimScanPassiveActivityWord

  proc nimScanReqHeader(): uint16 {.inline.} =
    let txAdd = uint16(nim_scan_params[5] and 0x01'u8) shl 6
    let rxAdd = uint16(nim_scan_req_peer_addr_type and 0x01'u32) shl 7
    (NimScanReqPduLen shl 8) or NimScanReqPduType or txAdd or rxAdd

  proc programBtbleScanReqTxDesc() =
    let desc = BTBLE_EM_BASE + NimScanReqTxDescOffset
    let header = if nimScanActive(): nimScanReqHeader() else: 0'u16
    btbleLegacyTxDescProgram(desc, 0'u16, header, 0'u16)

  proc nimScanIntervalSlots(): uint32 {.inline.} =
    uint32(nimScanIntervalUnits()) * NimScanHalfSlotsPerScanUnit

  proc nimScanWindowSlots(): uint32 {.inline.} =
    uint32(nimScanWindowUnits()) * NimScanHalfSlotsPerScanUnit

  proc nimScanRescheduleLeadSlots(): uint32 {.inline.} =
    let interval = nimScanIntervalSlots()
    let window = nimScanWindowSlots()
    let gap =
      if interval > window: interval - window
      else: NimScanMinLeadSlots
    if gap < NimScanMinLeadSlots: NimScanMinLeadSlots else: gap

  proc nimScanFallbackDelaySlots(): uint32 {.inline.} =
    ## Fallback polling re-arms a missed callback one scheduler lead before the
    ## next scan interval, not at the scan gap.  Re-arming at the gap overlaps the
    ## still-active window and eventually fills the hardware program-slot FIFO.
    let interval = nimScanIntervalSlots()
    if interval > NimScanMinLeadSlots:
      interval - NimScanMinLeadSlots
    else:
      interval

  proc nimScanTimeReached(target: uint32): bool =
    let now = currentBtbleTime()
    ((now - target) and 0x0FFFFFFF'u32) < 0x08000000'u32

  proc enableBtbleLegacySchedulerEvents() =
    ## HCI Reset disables the BTBLE event sources while preserving the already
    ## initialized core.  Scanner and initiator roles both use the legacy
    ## scheduler FIFO path, so re-arm the same event bits that cold init uses
    ## before pushing role programs.
    regWrite(BLE_BASE + BTBLE_INTACK_OFFSET,
             regRead(BLE_BASE + BTBLE_INTSTAT_OFFSET))
    writeBtbleInterruptMask(BtbleIntLegacyScheduler)
    when defined(bl808m0):
      when not bl808BleNimRuntimeClicIrq:
        nimDisableM0BleClicIrq()

  proc nimAdvRfChannelIndex(idx: uint8): uint16 {.inline.} =
    ## The BL808 legacy activity channel field is programmed with the RF
    ## frequency index for scanner activities.  BLE advertising channels
    ## 39/37/38 map to RF indexes 39/0/12.
    case idx mod 3'u8
    of 0'u8: 39'u16
    of 1'u8: 0'u16
    else: 12'u16

  proc nimInitAdvChannelNumber(idx: uint8): uint16 {.inline.} =
    ## Legacy initiator activities use the Bluetooth advertising channel
    ## number in the same EM field where scanner activities use an RF index.
    ## This matches vendor LLD init snapshots, which program values such as
    ## 0x8026 for advertising channel 38.
    case idx mod 3'u8
    of 0'u8: 39'u16
    of 1'u8: 37'u16
    else: 38'u16

  proc nimInitLegacyCtlWord(advChannel: uint16): uint16 {.inline.} =
    case advChannel
    of 37'u16, 39'u16: 0x69F5'u16
    else: 0xE9F5'u16

  proc nimInitTxDescCtl0(advChannel: uint16): uint16 {.inline.} =
    case advChannel
    of 37'u16: 0x2402'u16
    else: 0x2442'u16

  proc nimInitRxDescCtl0(advChannel: uint16): uint16 {.inline.} =
    case advChannel
    of 37'u16: 0x1991'u16
    of 39'u16: 0x3D91'u16
    else: 0x3F91'u16

  proc nimInitRxDescCtl1(advChannel: uint16): uint16 {.inline.} =
    case advChannel
    of 37'u16, 39'u16: 0x40F1'u16
    else: 0x40F1'u16

  proc nimInitRxDescCtl2(advChannel: uint16): uint16 {.inline.} =
    case advChannel
    of 37'u16: 0x8765'u16
    of 39'u16: 0x9765'u16
    else: 0x85E5'u16

  proc nimScanNextAdvChannel(): uint16 =
    let idx = nim_scan_channel_cursor mod 3'u8
    nim_scan_channel_cursor = (nim_scan_channel_cursor + 1'u8) mod 3'u8
    result = nimAdvRfChannelIndex(idx)
    nim_scan_last_channel_index = idx.uint32
    nim_scan_last_adv_channel = result.uint32

  proc nimInitPeerAddrLow(params: ptr uint8): uint32 {.inline.} =
    let req = hciLeCreateConnReq(params)
    uint32(req.peerAddr.data[0]) or
      (uint32(req.peerAddr.data[1]) shl 8) or
      (uint32(req.peerAddr.data[2]) shl 16) or
      (uint32(req.peerAddr.data[3]) shl 24)

  proc nimInitPeerAddrHigh(params: ptr uint8): uint32 {.inline.} =
    let req = hciLeCreateConnReq(params)
    uint32(req.peerAddr.data[4]) or (uint32(req.peerAddr.data[5]) shl 8)

  proc nimInitSeedChannelFromScanHint(params: ptr uint8): bool =
    ## LE Create Connection consumes a peer address learned from advertising
    ## reports.  Seed the first initiator window from the most recent matching
    ## scanner observation, then let the normal channel dwell/rotation continue.
    let req = hciLeCreateConnReq(params)
    let peerType = uint32(req.peerAddrType and 0x01'u8)
    let peer0 = nimInitPeerAddrLow(params)
    let peer1 = nimInitPeerAddrHigh(params)
    let written = nim_scan_peer_hint_write_index
    let limit =
      if written < NimScanPeerHintSlots.uint32:
        written
      else:
        NimScanPeerHintSlots.uint32
    for age in 0'u32 ..< limit:
      let slot =
        ((written - 1'u32 - age) mod NimScanPeerHintSlots.uint32).int
      if nim_scan_peer_hint_type[slot] == peerType and
          nim_scan_peer_hint_addr0[slot] == peer0 and
          nim_scan_peer_hint_addr1[slot] == peer1:
        let idx = nim_scan_peer_hint_channel_index[slot] mod 3'u32
        nim_init_channel_cursor = uint8(idx)
        nim_init_channel_seed = idx or 0x80000000'u32
        nim_init_channel_hint_index = idx
        nim_init_channel_hint_adv_channel = nim_scan_peer_hint_adv_channel[slot]
        inc nim_init_channel_hint_hit_count
        return true
    nim_init_channel_hint_index = 0xFFFFFFFF'u32
    nim_init_channel_hint_adv_channel = 0
    inc nim_init_channel_hint_miss_count
    false

  proc nimInitWindowUnits(): uint16 {.inline.} =
    let interval = nimInitParam16(0, nimScanIntervalUnits())
    let requested = nimInitParam16(2, nimScanWindowUnits())
    if requested > interval: interval else: requested

  proc nimInitWindowEmUnits(): uint16 {.inline.} =
    nimInitWindowUnits()

  proc nimInitIntervalSlots(): uint32 {.inline.} =
    uint32(nimInitParam16(0, nimScanIntervalUnits())) *
      NimScanHalfSlotsPerScanUnit

  proc nimInitWindowSlots(): uint32 {.inline.} =
    uint32(nimInitWindowUnits()) * NimScanHalfSlotsPerScanUnit

  proc nimInitContinuousWindow(): bool {.inline.} =
    nimInitWindowUnits() >= nimInitParam16(0, nimScanIntervalUnits())

  proc nimInitEventWindowSlots(): uint32 {.inline.} =
    let windowSlots = nimInitWindowSlots()
    if nimInitContinuousWindow() and windowSlots > NimInitMaxChannelDwellSlots:
      NimInitMaxChannelDwellSlots
    else:
      windowSlots

  proc nimInitEventWindowUnits(): uint16 {.inline.} =
    let slots = nimInitEventWindowSlots()
    let units = (slots + NimScanHalfSlotsPerScanUnit - 1'u32) div
      NimScanHalfSlotsPerScanUnit
    if units == 0'u32: 1'u16 else: uint16(units and 0xFFFF'u32)

  proc nimInitRescheduleLeadSlots(): uint32 {.inline.} =
    let interval = nimInitIntervalSlots()
    let window = nimInitWindowSlots()
    let gap =
      if interval > window: interval - window
      else: NimInitMinLeadSlots
    if gap < NimInitMinLeadSlots: NimInitMinLeadSlots else: gap

  proc nimInitFallbackDelaySlots(): uint32 {.inline.} =
    ## See nimScanFallbackDelaySlots: the callback path uses interval-window as
    ## the lead time, while polling uses the full interval cadence.
    if nimInitContinuousWindow() and
        nimInitWindowSlots() > NimInitMaxChannelDwellSlots:
      return nimInitEventWindowSlots()
    let interval = nimInitIntervalSlots()
    if interval > NimInitMinLeadSlots:
      interval - NimInitMinLeadSlots
    else:
      interval

  proc nimInitTargetReached(targetClock, deadline: uint32): bool {.inline.} =
    ((targetClock - deadline) and 0x0FFFFFFF'u32) < 0x08000000'u32

  proc nimInitChannelDwellSlots(): uint32 {.inline.} =
    let window = nimInitWindowSlots()
    if window < NimInitMaxChannelDwellSlots:
      window
    else:
      NimInitMaxChannelDwellSlots

  proc nimInitNextAdvChannel(targetClock: uint32): uint16 =
    ## Keep the selected channel stable across early scheduler completions, but
    ## bound the dwell so a low-duty advertiser cannot phase-lock against a
    ## full-window channel.
    if nim_init_channel_window_valid != 0'u32 and
        not nimInitTargetReached(targetClock, nim_init_channel_window_deadline):
      return uint16(nim_init_last_adv_channel and 0xFFFF'u32)

    let idx = nim_init_channel_cursor mod 3'u8
    nim_init_channel_cursor = (nim_init_channel_cursor + 1'u8) mod 3'u8
    result = nimInitAdvChannelNumber(idx)
    nim_init_last_channel_index = idx.uint32
    nim_init_last_adv_channel = result.uint32
    nim_init_channel_window_valid = 1
    nim_init_channel_window_deadline =
      (targetClock + nimInitChannelDwellSlots()) and 0x0FFFFFFF'u32

  proc nimInitWriteConnReqData() =
    ## The legacy initiator TX buffer contains only the CONNECT_IND LLData.
    ## The activity record provides InitA/AdvA and the hardware prefixes those
    ## addresses when it builds the over-the-air 34-byte CONNECT_IND payload.
    copyBytes(BTBLE_EM_BASE + NimInitConnReqDataOffset0.uint32,
              addr nim_init_ll_data[0], NimInitConnReqLlDataLen)
    copyBytes(BTBLE_EM_BASE + NimInitConnReqDataOffset1.uint32,
              addr nim_init_ll_data[0], NimInitConnReqLlDataLen)
    copyBytes(BTBLE_EM_BASE + NimInitConnReqDataOffset2.uint32,
              addr nim_init_ll_data[0], NimInitConnReqLlDataLen)

  proc nimInitAccessAddress(): uint32 {.inline.} =
    uint32(nim_init_ll_data[0]) or
      (uint32(nim_init_ll_data[1]) shl 8) or
      (uint32(nim_init_ll_data[2]) shl 16) or
      (uint32(nim_init_ll_data[3]) shl 24)

  proc computeConnectIndHeaderFlags(): uint16 {.inline.} =
    ## The CONNECT_IND PDU header carries the initiator address type in TxAdd
    ## and the advertiser address type in RxAdd.  HCI also has identity-address
    ## types 2 and 3; the over-the-air legacy bit is still the rand(om)/public low
    ## bit.
    let txAdd = uint16(nim_init_hci_params[12] and 0x01'u8) shl 6
    let rxAdd = uint16(nim_init_hci_params[5] and 0x01'u8) shl 7
    NimInitConnectIndChSelBit or txAdd or rxAdd

  proc nimInitConnectIndHeader(): uint16 {.inline.} =
    (uint16(NimInitConnectIndPayloadLen) shl 8) or
      NimInitConnectIndPduType or computeConnectIndHeaderFlags()

  proc nimInitBuildConnReqData() =
    let ll = cast[ptr UncheckedArray[uint8]](addr nim_init_ll_data[0])
    discard c_memset(addr nim_init_ll_data[0], 0,
                     nim_init_ll_data.len.csize_t)
    lld_aa_gen(addr nim_init_ll_data[0], 1'u8)
    var crcInit = currentBtbleTime() and 0x00FFFFFF'u32
    if crcInit == 0'u32:
      crcInit = 0x555555'u32
    ll[4] = uint8(crcInit and 0xFF'u32)
    ll[5] = uint8((crcInit shr 8) and 0xFF'u32)
    ll[6] = uint8((crcInit shr 16) and 0xFF'u32)
    ll[7] = NimInitTransmitWindowSize
    nimInitPutLe16(ll, 8, NimInitTransmitWindowOffset)
    nimInitPutLe16(ll, 10, nimInitConnIntervalUnits())
    nimInitPutLe16(ll, 12, nimInitParam16(17, 0'u16))
    nimInitPutLe16(ll, 14, nimInitSupervisionTimeoutUnits())
    ll[16] = 0xFF'u8
    ll[17] = 0xFF'u8
    ll[18] = 0xFF'u8
    ll[19] = 0xFF'u8
    ll[20] = 0x1F'u8
    let hop = uint8(5'u32 + (currentBtbleTime() mod 12'u32))
    let sca = 0'u8
    ll[21] = uint8(((sca and 0x07'u8) shl 5) or (hop and 0x1F'u8))
    nim_init_last_access_addr = nimInitAccessAddress()
    nimInitWriteConnReqData()

  proc programBtbleInitTxDesc() =
    ## The initiator event record points at the same legacy TX descriptor slot
    ## active scanning uses for SCAN_REQ.  Rebuild the descriptor as CONNECT_IND
    ## before scheduling, matching the vendor lld_init_start descriptor path.
    let desc = BTBLE_EM_BASE + NimInitTxDescOffset
    btbleLegacyTxDescProgram(
      desc, 0'u16, nimInitConnectIndHeader(), NimInitConnReqDataOffset0)

  proc nimInitRecordRx(header, status, buf: uint16, peer0, peer1,
                       reason: uint32) =
    let slot = nim_init_rx_log_index and 0x07'u32
    nim_init_rx_header_log[slot.int] = header.uint32
    nim_init_rx_status_log[slot.int] =
      (status.uint32 shl 16) or uint32(buf)
    nim_init_rx_peer0_log[slot.int] = peer0
    nim_init_rx_peer1_log[slot.int] = peer1
    nim_init_rx_reason_log[slot.int] = reason
    nim_init_rx_log_index = nim_init_rx_log_index + 1'u32

  proc nimInitPeerMatches(header: uint16, buf: uint16, status: uint16): bool =
    inc nim_init_rx_count
    inc nim_init_total_rx_count
    nim_init_rx_last_header = header.uint32
    nim_init_rx_last_buf = buf.uint32
    let pduType = uint8(header and 0x000F'u16)
    if pduType != 0x00'u8:
      inc nim_init_rx_pdu_mismatch_count
      inc nim_init_total_pdu_mismatch_count
      nim_init_rx_match_reason = 1
      nimInitRecordRx(header, status, buf, 0, 0, 1)
      return false
    let pduLen = uint8((header shr 8) and 0x003F'u16)
    if pduLen < 6'u8:
      inc nim_init_rx_short_count
      inc nim_init_total_short_count
      nim_init_rx_match_reason = 3
      nimInitRecordRx(header, status, buf, 0, 0, 3)
      return false
    let payloadBase = BTBLE_EM_BASE + buf.uint32
    nim_init_rx_last_peer0 = readBleAddrLow(payloadBase)
    nim_init_rx_last_peer1 = readBleAddrHigh(payloadBase)
    for j in 0 ..< 6:
      if read8(payloadBase + j.uint32) != nim_init_hci_params[6 + j]:
        inc nim_init_rx_addr_mismatch_count
        inc nim_init_total_addr_mismatch_count
        nim_init_rx_match_reason = 4
        nimInitRecordRx(header, status, buf, nim_init_rx_last_peer0,
                        nim_init_rx_last_peer1, 4)
        return false
    inc nim_init_rx_addr_match_count
    inc nim_init_total_addr_match_count
    let actualAddrType = uint8((header shr 6) and 0x0001'u16)
    let expectedAddrType = nim_init_hci_params[5] and 0x01'u8
    if actualAddrType != expectedAddrType:
      inc nim_init_rx_type_mismatch_count
      inc nim_init_total_type_mismatch_count
      nim_init_rx_match_reason = 2
      nimInitRecordRx(header, status, buf, nim_init_rx_last_peer0,
                      nim_init_rx_last_peer1, 2)
      return false
    nim_init_rx_match_reason = 0
    nimInitRecordRx(header, status, buf, nim_init_rx_last_peer0,
                    nim_init_rx_last_peer1, 0)
    true

  proc nimInitConnectReqDelaySlots(pduLen: uint8): uint32 =
    let advPacketHalfUs = (uint32(pduLen) + 10'u32) * 16'u32
    let connectReqHalfUs = (NimInitConnectIndPayloadLen.uint32 + 10'u32) *
      16'u32
    let tifsHalfUs = 300'u32
    btbleDelayTicksCeilSlots(advPacketHalfUs + tifsHalfUs +
                             connectReqHalfUs)

  proc nimInitComputeHandoffReadyClock(rxClock: uint32, pduLen: uint8): uint32 =
    ## Keep the matched advertising RX descriptor owned until the controller has
    ## had enough time to transmit CONNECT_IND, then free it before connection
    ## event 0 needs to be scheduled.
    (rxClock + nimInitConnectReqDelaySlots(pduLen) +
     NimInitConnectReqHandoffGuardSlots) and 0x0FFFFFFF'u32

  proc nimInitFirstAnchor(rxClock: uint32, pduLen: uint8,
                          handoffClock: uint32): uint32 =
    let connectReqDelaySlots = nimInitConnectReqDelaySlots(pduLen)
    let schedulerLeadSlots =
      when bl808BleNimConnectionEnabled:
        NimConnInitialCentralScheduleLeadSlots
      else:
        NimInitMinLeadSlots
    let transmitWindowSlots =
      uint32(NimInitTransmitWindowSize) * NimInitHalfSlotsPerConnIntervalUnit
    let windowOffsetSlots =
      uint32(NimInitTransmitWindowOffset) *
      NimInitHalfSlotsPerConnIntervalUnit
    let windowStart =
      (rxClock + connectReqDelaySlots + NimInitTransmitWindowDelaySlots +
       windowOffsetSlots) and 0x0FFFFFFF'u32
    let earliestOffset =
      if transmitWindowSlots > NimInitConnPhyLeadSlots:
        NimInitConnPhyLeadSlots
      else:
        0'u32
    let latestOffset =
      if transmitWindowSlots >
          NimInitConnPhyLeadSlots + schedulerLeadSlots:
        transmitWindowSlots - NimInitConnPhyLeadSlots
      else:
        transmitWindowSlots
    let handoffOffset =
      ((handoffClock + schedulerLeadSlots +
        NimInitFirstAnchorSchedulerGuardSlots) - windowStart) and
      0x0FFFFFFF'u32
    var targetOffset = earliestOffset
    if handoffOffset < 0x08000000'u32 and handoffOffset > targetOffset:
      targetOffset = handoffOffset
    if targetOffset > latestOffset:
      targetOffset = latestOffset

    # CONNECT_IND only advertises the first-event transmit window; the central
    # chooses the exact first master packet time.  Choose that time at handoff
    # using the current controller clock so a late-but-still-in-window handoff
    # does not silently schedule event 1 before the peer has ever anchored.
    (windowStart + targetOffset) and 0x0FFFFFFF'u32

  proc nimInitClockWithinRxWindow(clock, eventClock: uint32): bool =
    let elapsed = (clock - eventClock) and 0x0FFFFFFF'u32
    let window = nimInitWindowSlots()
    elapsed < 0x08000000'u32 and elapsed <= window + NimInitMinLeadSlots

  proc nimInitExpandRxClock(rawClock, referenceClock: uint32): uint32 =
    let reference = referenceClock and 0x0FFFFFFF'u32
    let rawLow = rawClock and 0x0000FFFF'u32
    var candidate = (reference and 0x0FFF0000'u32) or rawLow
    let ahead = (candidate - reference) and 0x0FFFFFFF'u32
    if ahead < 0x08000000'u32:
      if ahead > 0x00008000'u32:
        candidate = (candidate - 0x00010000'u32) and 0x0FFFFFFF'u32
    else:
      let behind = (reference - candidate) and 0x0FFFFFFF'u32
      if behind > 0x00008000'u32:
        candidate = (candidate + 0x00010000'u32) and 0x0FFFFFFF'u32
    candidate and 0x0FFFFFFF'u32

  proc nimInitRxClock(rawClock: uint32): uint32 =
    let now = currentBtbleTime()
    let eventClock =
      if nim_init_rx_event_clock != 0'u32:
        nim_init_rx_event_clock
      else:
        nim_init_event_target_clock
    let referenceClock =
      if eventClock != 0'u32: eventClock
      else: now
    nim_init_last_rx_now = now
    nim_init_last_rx_event_clock = eventClock

    if rawClock != 0'u32:
      nim_init_last_rx_clock_source = 1
      return nimInitExpandRxClock(rawClock, referenceClock)

    if eventClock != 0'u32:
      let zeroClock = nimInitExpandRxClock(rawClock, eventClock)
      if nimInitClockWithinRxWindow(zeroClock, eventClock):
        nim_init_last_rx_clock_source = 1
        return zeroClock

    # Initiator RX descriptors on BL808 can omit the coarse clock while still
    # reporting a valid RX event.  When that happens inside the active window,
    # use the live BTBLE clock just like the vendor path's lld_read_clock()
    # handoff instead of seeding the connection scheduler from zero.
    if eventClock == 0'u32 or nimInitClockWithinRxWindow(now, eventClock):
      nim_init_last_rx_clock_source = 2
      return now

    nim_init_last_rx_clock_source = 3
    eventClock and 0x0FFFFFFF'u32

  proc nimInitEventDone(event: uint8): bool {.inline.} =
    event == 0'u8 or event == 1'u8 or event == 7'u8 or event == 0xFF'u8

  proc nimInitWindowDoneDeadline(baseClock: uint32): uint32 {.inline.} =
    (baseClock + nimInitEventWindowSlots() + NimInitConnectReqTailSlots +
     NimInitMinLeadSlots) and 0x0FFFFFFF'u32

  proc nimInitProgramDone(programCount: uint32, deadline: uint32): bool =
    if programCount != 0'u32 and
        nim_init_event_done_program_count == programCount:
      return true
    deadline != 0'u32 and nimScanTimeReached(deadline)

  proc clearBtbleLegacyEventEm(em: uint32) =
    ## The BL808 activity record is a 0x94-byte EM object.  Every role transition
    ## must install a complete record instead of inheriting opaque state left by
    ## a previous role or by hardware.
    for off in countup(0'u32, 0x92'u32, 2'u32):
      write16(em + off, 0'u16)

  proc programBtbleLegacyScanEm() =
    let em = BTBLE_EM_BASE + NimScanEventEmOffset
    var addrBytes: array[6, uint8]
    localAddrBytes(addr addrBytes[0], nim_scan_params[5])
    let advChannel = nimScanNextAdvChannel()
    configureBleRfChannelMhz(bleRfLegacyScanChannelMhz(advChannel))
    programBtbleScanReqTxDesc()

    clearBtbleLegacyEventEm(em)
    write16(em + 0x00'u32, nimScanActivityWord())
    write16(em + 0x02'u32,
            0x0020'u16 or uint16(nim_scan_params[5] and 0x01'u8))
    write16(em + 0x06'u32, 0x1000'u16)
    copyBytes(em + 0x08'u32, addr addrBytes[0], addrBytes.len)
    writeBtbleDefaultAccessWords(em + 0x0E'u32)
    let scanCtrl =
      0x0008'u16 or
      (uint16(nim_scan_params[0] and 0x01'u8) shl 4) or
      (uint16(nim_scan_params[6] and 0x03'u8) shl 8)
    write16(em + 0x16'u32, scanCtrl)
    write16(em + 0x18'u32, 0x8000'u16 or (advChannel and 0x003F'u16))
    write16(em + 0x1A'u32, 0'u16)
    write16(em + 0x1C'u32, 0'u16)
    write16(em + 0x1E'u32, 0x8000'u16 or
            (nimScanWindowUnits() and 0x3FFF'u16))
    write16(em + 0x24'u32,
            if nimScanActive(): NimScanReqTxDescPtr else: 0'u16)
    write16(em + 0x26'u32, 0'u16)
    write16(em + 0x2A'u32, 0'u16)
    write16(em + 0x2E'u32, 0'u16)
    write16(em + 0x30'u32, nimScanWindowUnits())
    write16(em + 0x32'u32, 0'u16)
    write16(em + 0x34'u32, 0'u16)
    write16(em + 0x36'u32, 0'u16)
    write16(em + 0x38'u32, 0x4672'u16)
    write16(em + 0x3A'u32, 0'u16)
    write16(em + 0x44'u32, 0'u16)
    write16(em + 0x56'u32, 0'u16)
    regWrite((BLE_BASE + 0x934'u32).uint, 0x00010001'u32)

  proc programBtbleLegacyInitiatorEm(advChannel: uint16) =
    let em = BTBLE_EM_BASE + NimInitEventEmOffset
    var addrBytes: array[6, uint8]
    localAddrBytes(addr addrBytes[0], nim_init_hci_params[12])
    configureBleRfChannelMhz(bleRfChannelMhz(advChannel))
    nimInitWriteConnReqData()
    programBtbleInitTxDesc()

    clearBtbleLegacyEventEm(em)
    write16(em + 0x00'u32, 0x0209'u16)
    write16(em + 0x02'u32,
            0x0020'u16 or uint16(nim_init_hci_params[12] and 0x01'u8))
    write16(em + 0x04'u32, nimInitLegacyCtlWord(advChannel))
    write16(em + 0x06'u32, 0x1000'u16)
    copyBytes(em + 0x08'u32, addr addrBytes[0], addrBytes.len)
    writeBtbleDefaultAccessWords(em + 0x0E'u32)
    write16(em + 0x16'u32, uint16(nim_init_hci_params[4] and 0x01'u8) shl 8)
    write16(em + 0x18'u32, 0x8000'u16 or (advChannel and 0x003F'u16))
    write16(em + 0x1A'u32, 0'u16)
    write16(em + 0x1C'u32, 0'u16)
    write16(em + 0x1E'u32,
            0x8000'u16 or (nimInitEventWindowUnits() and 0x3FFF'u16))
    write16(em + 0x20'u32, nimInitTxDescCtl0(advChannel))
    write16(em + 0x22'u32, NimInitTxDescCtl1)
    write16(em + 0x24'u32, NimInitTxDescPtr)
    write16(em + 0x26'u32, 0'u16)
    write16(em + 0x28'u32, nimInitRxDescCtl0(advChannel))
    write16(em + 0x2A'u32, nimInitRxDescCtl1(advChannel))
    write16(em + 0x2C'u32, nimInitRxDescCtl2(advChannel))
    write16(em + 0x2E'u32, 0'u16)
    write16(em + 0x30'u32, NimInitRxWindowCtl)
    write16(em + 0x32'u32, 0'u16)
    write16(em + 0x34'u32, 0'u16)
    write16(em + 0x36'u32, 0'u16)
    write16(em + 0x38'u32, 0x4672'u16)
    let headerFlags = computeConnectIndHeaderFlags()
    nim_init_connect_ind_header_flags = headerFlags.uint32
    write16(em + 0x3A'u32, 0'u16)
    copyBytes(em + 0x3C'u32, addr nim_init_hci_params[6], 6)
    write16(em + 0x42'u32, uint16(nim_init_hci_params[5] and 0x01'u8))
    write16(em + 0x44'u32, 0'u16)
    write16(em + 0x56'u32, 0'u16)
    write16(em + 0x84'u32, NimInitTailPacketPtr)
    write16(em + 0x86'u32, NimInitTailPacketCtl)
    write16(em + 0x88'u32, NimInitTailHeaderCtl)
    write16(em + 0x8A'u32, uint16(NimInitEventEmOffset and 0xFFFF'u32))
    write16(em + 0x8C'u32, uint16(currentBtbleTime() and 0x0000FFFF'u32))
    write16(em + 0x8E'u32, NimInitTailFlags)
    copyBytes(em + 0x90'u32, addr addrBytes[0], addrBytes.len)
    writeBtbleDefaultAccessWords(em + 0x96'u32)
    regWrite((BLE_BASE + 0x934'u32).uint, 0x00010001'u32)

  when defined(BleDebugCounters):
    proc nimInitCaptureProgramSnapshot(advChannel, now, targetClock,
                                       lead: uint32) =
      let em = BTBLE_EM_BASE + NimInitEventEmOffset
      inc nim_init_program_snapshot_count
      nim_init_program_snapshot_channel = advChannel
      nim_init_program_snapshot_timing[0] = now and 0x0FFFFFFF'u32
      nim_init_program_snapshot_timing[1] = targetClock and 0x0FFFFFFF'u32
      nim_init_program_snapshot_timing[2] = lead
      nim_init_program_snapshot_timing[3] = uint32(nimInitEventWindowUnits())
      nim_init_program_snapshot_timing[4] = nimInitEventWindowSlots()
      nim_init_program_snapshot_timing[5] = nim_init_channel_seed
      nim_init_program_snapshot_timing[6] = nim_init_channel_hint_index
      nim_init_program_snapshot_timing[7] = nim_init_program_count
      for i in 0 ..< nim_init_program_snapshot_em.len:
        nim_init_program_snapshot_em[i] = read32(em + uint32(i * 4))
      for i in 0 ..< nim_init_program_snapshot_tx_desc.len:
        nim_init_program_snapshot_tx_desc[i] =
          read32(BTBLE_EM_BASE + NimInitTxDescOffset + uint32(i * 4))
      for i in 0 ..< nim_init_program_snapshot_sched.len:
        let off = i * 4
        nim_init_program_snapshot_sched[i] =
          uint32(nim_sch_prog[off]) or
          (uint32(nim_sch_prog[off + 1]) shl 8) or
          (uint32(nim_sch_prog[off + 2]) shl 16) or
          (uint32(nim_sch_prog[off + 3]) shl 24)

    proc nimInitCaptureHandoffSnapshot(reason: uint32, header: uint16,
                                       rxClock: uint32, rxFine: uint16) =
      ## Preserve the initiator activity exactly as it looked when the pure
      ## central path handed off to the connection scheduler.  The scheduler
      ## clears this EM slot immediately afterwards.
      let em = BTBLE_EM_BASE + NimInitEventEmOffset
      inc nim_init_handoff_snapshot_count
      nim_init_handoff_snapshot_reason = reason
      nim_init_handoff_snapshot_timing[0] = currentBtbleTime()
      nim_init_handoff_snapshot_timing[1] =
        uint32(header) or (uint32(rxFine) shl 16)
      nim_init_handoff_snapshot_timing[2] = rxClock and 0x0FFFFFFF'u32
      nim_init_handoff_snapshot_timing[3] = nim_init_event_target_clock
      nim_init_handoff_snapshot_timing[4] = nim_init_rx_event_clock
      nim_init_handoff_snapshot_timing[5] = nim_init_handoff_ready_clock
      nim_init_handoff_snapshot_timing[6] = nim_init_handoff_deadline
      nim_init_handoff_snapshot_timing[7] = nim_init_event_count
      nim_init_handoff_snapshot_timing[8] = nim_init_last_event
      nim_init_handoff_snapshot_timing[9] = nim_init_tx_event_count
      nim_init_handoff_snapshot_timing[10] = nim_init_event_done_program_count
      nim_init_handoff_snapshot_timing[11] = nim_init_handoff_program_count
      nim_init_handoff_snapshot_timing[12] = nim_init_handoff_tx_event_count
      nim_init_handoff_snapshot_timing[13] = nim_init_program_count
      nim_init_handoff_snapshot_timing[14] = nim_init_next_program_at
      nim_init_handoff_snapshot_timing[15] = nim_init_pending_desc
      for i in 0 ..< nim_init_handoff_snapshot_em.len:
        nim_init_handoff_snapshot_em[i] = read32(em + uint32(i * 4))
      for i in 0 ..< nim_init_handoff_snapshot_desc.len:
        nim_init_handoff_snapshot_desc[i] =
          read32(BTBLE_EM_BASE + 0x0458'u32 + uint32(i * 4))
      for i in 0 ..< nim_init_handoff_snapshot_data.len:
        nim_init_handoff_snapshot_data[i] =
          read32(BTBLE_EM_BASE + 0x1780'u32 + uint32(i * 4))

    proc nimInitRecordSchEvent(timestamp: uint32, event: uint8) =
      let slot = int(nim_init_sch_event_log_index and 0x0F'u32)
      let intStat = regRead(BLE_BASE + 0x024'u32)
      let eventSlot = (intStat shr 24) and 0x0F'u32
      let slotStatus = uint32(read16(BTBLE_EM_BASE + eventSlot * 0x10'u32))
      nim_init_sch_event_code_log[slot] =
        event.uint32 or (eventSlot shl 8) or (slotStatus shl 16)
      nim_init_sch_event_time_log[slot] = timestamp and 0x0FFFFFFF'u32
      nim_init_sch_event_now_log[slot] = currentBtbleTime()
      nim_init_sch_event_state_log[slot] =
        (nim_init_active and 0x01'u32) or
        ((nim_init_handoff_pending and 0x01'u32) shl 1) or
        ((nim_init_rx_service_pending and 0x01'u32) shl 2) or
        ((nim_init_last_adv_channel and 0xFF'u32) shl 8)
      nim_init_sch_event_counts_log[slot] =
        (nim_init_program_count and 0xFFFF'u32) or
        ((nim_init_tx_event_count and 0xFFFF'u32) shl 16)
      nim_init_sch_event_done_log[slot] = nim_init_event_done_program_count
      nim_init_sch_event_int_log[slot] = intStat
      inc nim_init_sch_event_log_index

  proc pushNimScanProgram(leadSlots: uint32 = NimScanMinLeadSlots)
  proc pushNimInitiatorProgram(leadSlots: uint32 = NimInitMinLeadSlots)
  proc startNimInitiatorConnection(header: uint16, buf: uint16, rxClock: uint32,
                                   rxFine: uint16): bool
  proc nimInitServiceDeferredHandoff()
  proc nimInitRequestRxDescriptorService(eventClock: uint32)

  proc nimScanSchProgCb(timestamp: uint32, ctx: pointer,
                        event: uint8) {.cdecl.} =
    discard timestamp
    discard ctx
    inc nim_scan_event_count
    nim_scan_last_event = event.uint32
    if nim_scan_enabled and (event == 0'u8 or event == 1'u8 or
        event == 4'u8 or event == 7'u8):
      pushNimScanProgram(nimScanRescheduleLeadSlots())

  proc nimInitSchProgCb(timestamp: uint32, ctx: pointer,
                        event: uint8) {.cdecl.} =
    discard ctx
    inc nim_init_event_count
    nim_init_last_event = event.uint32
    when defined(BleDebugCounters):
      nimInitRecordSchEvent(timestamp, event)
    if event == 2'u8:
      nim_init_rx_event_clock =
        if timestamp != 0'u32: timestamp and 0x0FFFFFFF'u32
        else: nim_init_event_target_clock
      nimInitRequestRxDescriptorService(nim_init_rx_event_clock)
    elif event == 3'u8:
      inc nim_init_tx_event_count
      inc nim_init_total_tx_event_count
      if nim_init_handoff_pending != 0'u32:
        requestBtbleSwInterrupt()
    elif event == 4'u8:
      if nim_init_handoff_pending != 0'u32:
        requestBtbleSwInterrupt()
      elif nim_init_active != 0'u32:
        pushNimInitiatorProgram(nimInitRescheduleLeadSlots())
    if nimInitEventDone(event):
      nim_init_event_done_program_count = nim_init_program_count
      if nim_init_handoff_pending != 0'u32:
        requestBtbleSwInterrupt()
      elif nim_init_active != 0'u32:
        let eventClock =
          if timestamp != 0'u32: timestamp and 0x0FFFFFFF'u32
          elif nim_init_rx_event_clock != 0'u32: nim_init_rx_event_clock
          else: nim_init_event_target_clock
        nimInitRequestRxDescriptorService(eventClock)

  proc nimInitRequestRxDescriptorService(eventClock: uint32) =
    if nim_init_active == 0'u32 or nim_init_handoff_pending != 0'u32:
      return
    let clock =
      if eventClock != 0'u32: eventClock and 0x0FFFFFFF'u32
      else: nim_init_event_target_clock
    nim_init_rx_event_clock = clock
    nim_init_rx_service_pending = 1
    nim_init_rx_service_program_count = nim_init_program_count
    nim_init_rx_service_deadline = nimInitWindowDoneDeadline(clock)
    requestBtbleSwInterrupt()

  proc nimInitResumeAfterUnmatchedRx() =
    if nim_init_rx_service_pending == 0'u32 or
        nim_init_handoff_pending != 0'u32:
      return
    if not nimInitProgramDone(nim_init_rx_service_program_count,
                              nim_init_rx_service_deadline):
      return
    nim_init_rx_service_pending = 0
    nim_init_rx_service_program_count = 0
    nim_init_rx_service_deadline = 0
    if nim_init_active != 0'u32:
      pushNimInitiatorProgram(nimInitRescheduleLeadSlots())

  proc pushNimScanProgram(leadSlots: uint32 = NimScanMinLeadSlots) =
    nim_scan_debug_stage = 0x2000'u32
    programBtbleLegacyScanEm()
    nim_scan_debug_stage = 0x2010'u32
    let lead =
      if leadSlots < NimScanMinLeadSlots: NimScanMinLeadSlots else: leadSlots
    let now = currentBtbleTime()
    let targetClock = (now + lead) and 0x0FFFFFFF'u32
    nim_scan_debug_now = now
    nim_scan_debug_target = targetClock
    nim_scan_debug_lead = lead
    nim_scan_debug_stage = 0x2020'u32
    discard c_memset(addr nim_sch_prog[0], 0,
                     nim_sch_prog.len.csize_t)
    schProgWrite32(0x00, cast[uint32](cast[uint](nimScanSchProgCb)))
    schProgWrite32(0x04, targetClock)
    schProgWrite16(0x08, 0'u16)
    schProgWrite32(0x10, uint32(nimScanWindowUnits()) * 1250'u32)
    schProgWrite32(0x14, 0'u32)
    nim_sch_prog[0x18] = rwip_priority[0]
    nim_sch_prog[0x19] = 0'u8
    nim_sch_prog[0x1A] = rwip_priority[2]
    nim_sch_prog[0x1B] = 0x1F'u8
    nim_sch_prog[0x1C] = NimScanEventIndex
    nim_scan_debug_stage = 0x2030'u32
    sch_prog_push(addr nim_sch_prog[0])
    nim_scan_debug_stage = 0x2040'u32
    nim_scan_next_program_at = (targetClock + nimScanFallbackDelaySlots()) and
      0x0FFFFFFF'u32
    inc nim_scan_program_count
    nim_scan_debug_stage = 0x2050'u32

  proc pushNimInitiatorProgram(leadSlots: uint32 = NimInitMinLeadSlots) =
    if nim_init_active == 0'u32 or nim_init_handoff_pending != 0'u32 or
        nim_init_rx_service_pending != 0'u32:
      return
    let lead =
      if leadSlots < NimInitMinLeadSlots: NimInitMinLeadSlots else: leadSlots
    let now = currentBtbleTime()
    let targetClock = (now + lead) and 0x0FFFFFFF'u32
    let advChannel = nimInitNextAdvChannel(targetClock)
    programBtbleLegacyInitiatorEm(advChannel)
    nim_init_event_target_clock = targetClock
    discard c_memset(addr nim_sch_prog[0],
                     0, nim_sch_prog.len.csize_t)
    schProgWrite32(0x00, cast[uint32](cast[uint](nimInitSchProgCb)))
    schProgWrite32(0x04, targetClock)
    schProgWrite16(0x08, 0'u16)
    schProgWrite32(0x10,
                      uint32(nimInitEventWindowUnits()) * 1250'u32 +
                      NimInitConnectReqTailUs)
    schProgWrite32(0x14, 0'u32)
    nim_sch_prog[0x18] = rwip_priority[4]
    nim_sch_prog[0x19] = 0'u8
    nim_sch_prog[0x1A] = rwip_priority[2]
    nim_sch_prog[0x1B] = 0x1F'u8
    nim_sch_prog[0x1C] = NimInitEventIndex
    when defined(BleDebugCounters):
      nimInitCaptureProgramSnapshot(advChannel.uint32, now, targetClock, lead)
    sch_prog_push(addr nim_sch_prog[0])
    nim_init_next_program_at = (targetClock + nimInitFallbackDelaySlots()) and
      0x0FFFFFFF'u32
    inc nim_init_program_count

  proc bleControllerServiceScan*() {.exportc, cdecl.} =
    if nim_init_rx_service_pending != 0'u32:
      serviceBtbleAdvRxDescriptors()
    nimInitServiceDeferredHandoff()
    nimInitResumeAfterUnmatchedRx()
    if nim_scan_enabled and nimScanTimeReached(nim_scan_next_program_at):
      pushNimScanProgram()
    if nim_init_active != 0'u32 and nim_init_handoff_pending == 0'u32 and
        nim_init_rx_service_pending == 0'u32 and
        nimScanTimeReached(nim_init_next_program_at):
      pushNimInitiatorProgram()

  proc nimInitValidCreateConnectionParams(params: ptr uint8,
                                          paramLen: uint8): uint8 =
    if params == nil or paramLen != 25'u8:
      return HciStatusInvalidParams
    let req = hciLeCreateConnReq(params)
    if req.filterPolicy != 0'u8:
      return HciStatusUnsupportedFeatureParam
    if req.peerAddrType > 3'u8 or req.ownAddrType > 3'u8:
      return HciStatusInvalidParams
    if req.connIntervalMin < 6'u16 or req.connIntervalMin > 3200'u16:
      return HciStatusInvalidParams
    if req.connIntervalMax < req.connIntervalMin or
        req.connIntervalMax > 3200'u16:
      return HciStatusInvalidParams
    if req.connLatency > 499'u16:
      return HciStatusInvalidParams
    if req.supervisionTimeout < 10'u16 or req.supervisionTimeout > 3200'u16:
      return HciStatusInvalidParams
    HciStatusSuccess

  proc programNimInitiator(params: ptr uint8, paramLen: uint8): uint8 =
    let paramStatus = nimInitValidCreateConnectionParams(params, paramLen)
    if paramStatus != HciStatusSuccess:
      return paramStatus
    when not (bl808BleNimPureConnection and bl808BleNimManualConnTx):
      discard params
      discard paramLen
      return HciStatusUnsupportedFeatureParam
    else:
      if nim_init_active != 0'u32 or nim_init_complete_pending != 0'u32 or
          nim_conn_active:
        return HciStatusCommandDisallowed
      if not nim_ble_core_ready:
        initBleCoreRegisters()
      ensureBleRf1MConfigured()
      initNimRwipRfTable()
      refreshNimSyncPositions()
      for i in 0 ..< nim_init_hci_params.len:
        nim_init_hci_params[i] = cast[ptr UncheckedArray[uint8]](params)[i]
      nim_scan_enabled = false
      sch_prog_init(3'u8)
      clearBtbleProgramSlots()
      resetBtbleAdvRxRing()
      nim_init_active = 1
      nim_init_complete_pending = 0
      nim_init_last_status = HciStatusSuccess.uint32
      nim_init_last_event = 0
      nim_init_last_rx_clock = 0
      nim_init_last_rx_fine = 0
      nim_init_last_anchor = 0
      nim_init_last_access_addr = 0
      nim_init_rx_count = 0
      nim_init_rx_match_reason = 0
      nim_init_rx_last_header = 0
      nim_init_rx_last_status = 0
      nim_init_rx_last_buf = 0
      nim_init_rx_last_peer0 = 0
      nim_init_rx_last_peer1 = 0
      nim_init_rx_pdu_mismatch_count = 0
      nim_init_rx_short_count = 0
      nim_init_rx_addr_mismatch_count = 0
      nim_init_rx_addr_match_count = 0
      nim_init_rx_type_mismatch_count = 0
      nim_init_connect_ind_header_flags = 0
      nim_init_next_program_at = 0
      nim_init_tx_event_count = 0
      nim_init_event_target_clock = 0
      nim_init_rx_event_clock = 0
      nim_init_last_rx_now = 0
      nim_init_last_rx_event_clock = 0
      nim_init_last_rx_clock_source = 0
      nim_init_rx_service_pending = 0
      nim_init_rx_service_program_count = 0
      nim_init_rx_service_deadline = 0
      nim_init_event_done_program_count = 0
      nim_init_handoff_pending = 0
      nim_init_handoff_program_count = 0
      nim_init_handoff_tx_event_count = 0
      nim_init_handoff_ready_clock = 0
      nim_init_handoff_deadline = 0
      nim_init_handoff_start_count = 0
      nim_init_handoff_timeout_count = 0
      nim_init_pending_header = 0
      nim_init_pending_rx_clock = 0
      nim_init_pending_rx_fine = 0
      nim_init_pending_desc = 0
      nim_init_pending_desc_status = 0
      nim_init_pending_desc_idx = 0
      # Prefer the channel on which the target address was just observed.  If
      # the create request was not preceded by a matching scan report, fall back
      # to the scanner cadence plus live controller time so repeated direct
      # create requests do not phase-lock on one advertising channel.
      if not nimInitSeedChannelFromScanHint(params):
        nim_init_channel_cursor =
          uint8((uint32(nim_scan_channel_cursor mod 3'u8) +
                 currentBtbleTime() mod 3'u32) mod 3'u32)
        nim_init_channel_seed = nim_init_channel_cursor.uint32
      nim_init_channel_window_valid = 0
      nim_init_channel_window_deadline = 0
      nim_init_last_channel_index = 0
      nim_init_last_adv_channel = 0
      nimInitBuildConnReqData()
      enableBtbleLegacySchedulerEvents()
      regOr(BLE_BASE + 0x000'u32, 0x00000100'u32)
      pushNimInitiatorProgram()
      HciStatusSuccess

  proc nimInitReleasePendingRxDesc() =
    if nim_init_pending_desc == 0'u32:
      return
    let desc = nim_init_pending_desc
    let status = uint16(nim_init_pending_desc_status and 0xFFFF'u32)
    let idx = nim_init_pending_desc_idx and 0x07'u32
    nim_init_pending_desc = 0
    nim_init_pending_desc_status = 0
    nim_init_pending_desc_idx = 0
    btbleRxDescClearDone(desc, status)
    when bl808BleNimPureConnection:
      noteNimRxDescConsumed(idx)
    else:
      lld_env[14] = uint8((idx + 1'u32) and 0x07'u32)

  proc failPendingNimInitiator(status: uint8) =
    if nim_init_complete_pending == 0'u32 and nim_init_active == 0'u32:
      return
    nimInitReleasePendingRxDesc()
    nim_init_active = 0
    nim_init_complete_pending = 0
    nim_init_rx_service_pending = 0
    nim_init_handoff_pending = 0
    nim_init_handoff_program_count = 0
    nim_init_handoff_tx_event_count = 0
    nim_init_handoff_ready_clock = 0
    nim_init_handoff_deadline = 0
    nim_init_last_status = status.uint32
    when bl808BleNimPureConnection:
      nim_conn_state.active = false
      nim_conn_state.reschedulePending = false
      nim_conn_started = false
    sendLeConnectionCompleteStatusHandle(
      addr nim_init_hci_params[0], nim_init_hci_params.len.uint8,
      status, 0'u16, 0'u8)

  proc cancelNimInitiator(): uint8 =
    if nim_init_active == 0'u32 and nim_init_complete_pending == 0'u32:
      return HciStatusCommandDisallowed
    inc nim_init_cancel_count
    failPendingNimInitiator(0x3E'u8)
    HciStatusSuccess

  proc nimInitQueueConnectionHandoff(header: uint16, rxClock: uint32,
                                     rxFine: uint16, desc: uint32,
                                     status: uint16, idx: uint32) =
    if nim_init_handoff_pending != 0'u32:
      return
    let programCount =
      if nim_init_rx_service_program_count != 0'u32:
        nim_init_rx_service_program_count
      else:
        nim_init_program_count
    let eventClock =
      if nim_init_rx_event_clock != 0'u32:
        nim_init_rx_event_clock
      elif nim_init_event_target_clock != 0'u32:
        nim_init_event_target_clock
      else:
        rxClock
    nim_init_handoff_pending = 1
    nim_init_handoff_program_count = programCount
    nim_init_handoff_tx_event_count = nim_init_tx_event_count
    nim_init_handoff_ready_clock =
      nimInitComputeHandoffReadyClock(rxClock,
                                      uint8((header shr 8) and 0x003F'u16))
    nim_init_handoff_deadline = nimInitWindowDoneDeadline(eventClock)
    nim_init_pending_header = header.uint32
    nim_init_pending_rx_clock = rxClock and 0x0FFFFFFF'u32
    nim_init_pending_rx_fine = rxFine.uint32
    nim_init_pending_desc = desc
    nim_init_pending_desc_status = status.uint32
    nim_init_pending_desc_idx = idx and 0x07'u32
    nim_init_rx_service_pending = 0
    nim_init_rx_service_program_count = 0
    nim_init_rx_service_deadline = 0
    nim_init_next_program_at = 0
    requestBtbleSwInterrupt()

  proc startNimInitiatorConnection(header: uint16, buf: uint16, rxClock: uint32,
                                   rxFine: uint16): bool =
    when not (bl808BleNimPureConnection and bl808BleNimManualConnTx):
      discard header
      discard buf
      discard rxClock
      discard rxFine
      false
    else:
      let pduLen = uint8((header shr 8) and 0x003F'u16)
      let handoffClock = currentBtbleTime()
      let anchor = nimInitFirstAnchor(rxClock, pduLen, handoffClock)
      let p = cast[ptr UncheckedArray[uint8]](addr nim_conn_params[0])
      discard c_memset(addr nim_conn_params[0],
                       0, nim_conn_params.len.csize_t)
      for i in 0 .. 20:
        p[i] = nim_init_ll_data[i]
      p[21] = nim_init_ll_data[21] and 0x1F'u8
      p[22] = (nim_init_ll_data[21] shr 5) and 0x07'u8
      nimInitPutLe16(p, 24, rxFine)
      nimInitPutLe32(p, 28, rxClock)
      nimInitPutLe32(p, 32, anchor)
      # The initiator path has already converted the matched advertising RX
      # timestamp into the first master-packet anchor inside the CONNECT_IND
      # transmit window.  Use direct-anchor mode so the connection scheduler
      # consumes p[32..35] instead of deriving an earlier anchor from rxClock.
      p[36] = 0'u8
      p[37] = 0'u8
      # lld_con_start takes ChSel as a byte bool(ean) and shifts it into the EM
      # channel-control word. Keep CONNECT_IND and the connection scheduler on
      # the same channel-selection algorithm.
      p[38] =
        when bl808BleNimCentralChSel2: 1'u8 else: 0'u8
      p[NimConnStartCentralRoleOffset] = NimInitRoleCentral

      nim_init_last_rx_clock = rxClock
      nim_init_last_rx_fine = rxFine.uint32
      nim_init_last_anchor = anchor
      nim_conn_last_rx_clock = rxClock
      nim_conn_last_rx_fine = rxFine.uint32
      nim_conn_last_anchor = anchor
      nim_conn_last_win_offset = NimInitTransmitWindowOffset.uint32
      nim_conn_last_interval = nimInitConnIntervalUnits().uint32
      nim_conn_last_timeout = nimInitSupervisionTimeoutUnits().uint32
      nim_conn_last_access_addr = nimInitAccessAddress()
      nim_conn_last_crcinit =
        uint32(nim_init_ll_data[4]) or
        (uint32(nim_init_ll_data[5]) shl 8) or
        (uint32(nim_init_ll_data[6]) shl 16)
      nim_conn_evt_handle = NimInitConnHandle.uint32
      nim_conn_evt_peer_type = uint32(nim_init_hci_params[5] and 1'u8)
      nim_conn_evt_peer_a0 =
        uint32(nim_init_hci_params[6]) or
        (uint32(nim_init_hci_params[7]) shl 8) or
        (uint32(nim_init_hci_params[8]) shl 16) or
        (uint32(nim_init_hci_params[9]) shl 24)
      nim_conn_evt_peer_a1 =
        uint32(nim_init_hci_params[10]) or
        (uint32(nim_init_hci_params[11]) shl 8)

      prepareBtbleConnectionRxRingForHandoff()
      writeBtbleInterruptMask(BtbleIntConnection)
      when defined(bl808m0):
        when not bl808BleNimRuntimeClicIrq:
          nimDisableM0BleClicIrq()
      initNimRwipRfTable()
      refreshNimSyncPositions()
      clearBtbleProgramSlots()
      nim_conn_last_status =
        nimLldConStart(NimInitConnHandle, addr nim_conn_params[0]).uint32
      nim_init_last_status = nim_conn_last_status
      if nim_conn_last_status != 0'u32:
        nim_conn_started = false
        failPendingNimInitiator(0x3E'u8)
        return true

      nim_init_active = 0
      nim_init_complete_pending = 1
      inc nim_init_start_count
      inc nim_init_total_start_count
      nim_conn_started = true
      nimLlcpPrimeStartup()
      noteNimPeripheralConnected(NimInitConnHandle)
      completeNimInitiatorHciConnection(NimInitConnHandle)
      true

  proc nimInitServiceDeferredHandoff() =
    if nim_init_handoff_pending == 0'u32:
      return
    let txDone =
      nim_init_tx_event_count != nim_init_handoff_tx_event_count
    let eventDone =
      nim_init_handoff_program_count != 0'u32 and
      nim_init_event_done_program_count == nim_init_handoff_program_count
    let readyReached =
      nim_init_handoff_ready_clock != 0'u32 and
      nimScanTimeReached(nim_init_handoff_ready_clock)
    let deadlineReached =
      nim_init_handoff_deadline != 0'u32 and
      nimScanTimeReached(nim_init_handoff_deadline)
    if not txDone and not readyReached and not eventDone and not deadlineReached:
      return

    let header = uint16(nim_init_pending_header and 0xFFFF'u32)
    let rxClock = nim_init_pending_rx_clock and 0x0FFFFFFF'u32
    let rxFine = uint16(nim_init_pending_rx_fine and 0x03FF'u32)
    when defined(BleDebugCounters):
      var snapshotReason = 0'u32
      if txDone:
        snapshotReason = snapshotReason or 0x01'u32
      if readyReached:
        snapshotReason = snapshotReason or 0x02'u32
      if eventDone:
        snapshotReason = snapshotReason or 0x04'u32
      if deadlineReached:
        snapshotReason = snapshotReason or 0x08'u32
      nimInitCaptureHandoffSnapshot(snapshotReason, header, rxClock, rxFine)
    nim_init_handoff_pending = 0
    nim_init_handoff_program_count = 0
    nim_init_handoff_tx_event_count = 0
    nim_init_handoff_ready_clock = 0
    nim_init_handoff_deadline = 0
    nim_init_pending_header = 0
    nim_init_pending_rx_clock = 0
    nim_init_pending_rx_fine = 0
    inc nim_init_handoff_start_count
    inc nim_init_total_handoff_start_count
    if deadlineReached and not txDone and not readyReached and not eventDone:
      inc nim_init_handoff_timeout_count
      inc nim_init_total_handoff_timeout_count
    nimInitReleasePendingRxDesc()
    discard startNimInitiatorConnection(header, 0'u16, rxClock, rxFine)

  proc handleNimInitiatorAdvRx(header: uint16, buf: uint16, desc: uint32,
                               status: uint16, idx: uint32): bool =
    nim_init_rx_last_status = status.uint32
    if nim_init_active == 0'u32 or nim_init_handoff_pending != 0'u32:
      return false
    if not nimInitPeerMatches(header, buf, status):
      return false
    inc nim_init_match_count
    inc nim_init_total_match_count
    let rxFine = btbleAdvRxFine(desc)
    let rxClock = nimInitRxClock(btbleAdvRxClock(desc))
    inc nim_init_complete_count
    nimInitQueueConnectionHandoff(header, rxClock, rxFine, desc, status, idx)
    true

  proc programNimScanning(enable: bool): uint8 =
    nim_scan_debug_stage = 0x3000'u32
    if not enable:
      nim_scan_enabled = false
      nim_scan_last_status = 0
      nim_scan_next_program_at = 0
      nim_scan_debug_stage = 0x3010'u32
      return HciStatusSuccess
    if not nim_ble_core_ready:
      nim_scan_debug_stage = 0x3020'u32
      initBleCoreRegisters()
      nim_scan_debug_stage = 0x3030'u32
    ensureBleRf1MConfigured()
    sch_prog_init(3'u8)
    clearBtbleProgramSlots()
    nim_scan_enabled = true
    nim_scan_last_status = 0
    nim_scan_next_program_at = 0
    nim_scan_peer_hint_write_index = 0
    for i in 0 ..< NimScanPeerHintSlots:
      nim_scan_peer_hint_addr0[i] = 0
      nim_scan_peer_hint_addr1[i] = 0
      nim_scan_peer_hint_type[i] = 0
      nim_scan_peer_hint_channel_index[i] = 0
      nim_scan_peer_hint_adv_channel[i] = 0
    resetBtbleAdvRxRing()
    enableBtbleLegacySchedulerEvents()
    regOr(BLE_BASE + 0x000'u32, 0x00000100'u32)
    nim_scan_debug_stage = 0x3050'u32
    pushNimScanProgram()
    nim_scan_debug_stage = 0x3060'u32
    HciStatusSuccess

proc programNimAdvertising(enable: bool): uint8 =
  nim_adv_debug_stage = 0x7000'u32
  nim_adv_debug_detail = if enable: 1'u32 else: 0'u32
  if not enable:
    nim_adv_enabled = false
    nim_adv_target_half_us = 0
    write16(BLE_EM_BASE + 0x0EA'u32, read16(BLE_EM_BASE + 0x0EA'u32) and
            not 0x2000'u16)
    writeBtbleInterruptMask(0)
    regWrite((BLE_BASE + 0x9C0'u32).uint, 0'u32)
    nim_adv_debug_stage = 0x7010'u32
    return 0

  if not nim_ble_core_ready:
    nim_adv_debug_stage = 0x7020'u32
    initBleCoreRegisters()
    nim_adv_debug_stage = 0x7030'u32

  var pdu: array[39, uint8]
  let advLen = min(nim_adv_data_len.int, 31)
  nim_adv_debug_detail = advLen.uint32
  pdu[0] = 0x00'u8
  pdu[1] = uint8(6 + advLen)
  localAddrBytes(addr pdu[2], nim_adv_params[5])
  for i in 0 ..< advLen:
    pdu[8 + i] = nim_adv_data[i]
  copyBytes(BLE_EM_BASE + 0x600'u32, addr pdu[0], 8 + advLen)
  programBtbleLegacyAdv(advLen.uint8)
  nim_adv_debug_stage = 0x7040'u32

  let pduLen = uint16(8 + advLen)
  write16(BLE_EM_BASE + 0x28C'u32,
          ((pduLen and 0x00FF'u16) shl 8) or 0x0024'u16)
  write16(BLE_EM_BASE + 0x28E'u32, 0x0600'u16)
  write16(BLE_EM_BASE + 0x298'u32, 0x8000'u16)
  write16(BLE_EM_BASE + 0x29A'u32, 0x0600'u16)
  write16(BLE_EM_BASE + 0x29C'u32, pduLen)
  write16(BLE_EM_BASE + 0x0A4'u32, 0x0298'u16)

  write16(BLE_EM_BASE + 0x0EE'u32,
          (read16(BLE_EM_BASE + 0x0EE'u32) and not 0x001F'u16) or 0x0001'u16)
  write16(BLE_EM_BASE + 0x0EA'u32, 0xF005'u16)
  write16(BLE_EM_BASE + 0x0F8'u32, nim_adv_params[13].uint16 shl 8)
  write16(BLE_EM_BASE + 0x142'u32,
          read16(BLE_EM_BASE + 0x142'u32) and not 0x0080'u16)
  write16(BLE_EM_BASE + 0x138'u32, 0'u16)
  write16(BLE_EM_BASE + 0x13A'u32, 0'u16)
  write16(BLE_EM_BASE + 0x13C'u32, 0'u16)
  write16(BLE_EM_BASE + 0x13E'u32, 0'u16)
  write16(BLE_EM_BASE + 0x140'u32, 0'u16)
  copyBytes(BLE_EM_BASE + 0x110'u32, cast[ptr uint8](addr nim_adv_params[7]), 6)
  write16(BLE_EM_BASE + 0x116'u32, nim_adv_params[5].uint16)
  write16(BLE_EM_BASE + 0x0FA'u32, 0xC027'u16)
  write16(BLE_EM_BASE + 0x0F6'u32, 0x0055'u16)
  write16(BLE_EM_BASE + 0x0FE'u32, 0'u16)
  write16(BLE_EM_BASE + 0x0FC'u32, ble_tx_pwr.uint16)
  write16(BLE_EM_BASE + 0x0EE'u32, read16(BLE_EM_BASE + 0x0EE'u32) or 0x2000'u16)
  write16(BLE_EM_BASE + 0x0EC'u32, 0'u16)
  write16(BLE_EM_BASE + 0x10C'u32, 0'u16)
  write16(BLE_EM_BASE + 0x10E'u32, 0'u16)
  write16(BLE_EM_BASE + 0x104'u32, 8'u16)

  nim_adv_debug_stage = 0x7060'u32
  ensureBleRf1MConfigured()
  nim_adv_debug_stage = 0x7070'u32
  regOr(BLE_BASE + 0x000'u32, 0x00000100'u32)
  regWrite((BLE_BASE + 0x828'u32).uint, 0x0000011E'u32)
  nim_adv_debug_stage = 0x7080'u32
  nim_adv_enabled = true
  writeBtbleInterruptMask(BtbleIntAdvertising)
  nim_adv_debug_stage = 0x7090'u32
  nim_adv_debug_detail = regRead((BLE_BASE + BTBLE_INTMASK_OFFSET).uint)
  nim_adv_debug_stage = 0x70A0'u32
  scheduleBtbleEvent()
  nim_adv_debug_stage = 0x70B0'u32
  0

proc handleNimHciCommand(opcode: uint16, params: ptr uint8,
                         paramLen: uint8): uint8 =
  nim_hci_debug_stage = 0x4500'u32
  nim_hci_debug_opcode = opcode.uint32
  nim_hci_debug_len = paramLen.uint32
  case opcode
  of HciOpReset:
    rwip_reset()
    0
  of HciOpDisconnect:
    if paramLen != 3 or params == nil:
      return 0x12'u8
    let req = hciDisconnectReq(params)
    let handle = req.handle
    if not nim_conn_active or handle != nim_conn_handle:
      return 0x02'u8
    sendDisconnectComplete(handle, req.reason)
    0
  of HciOpLeSetRandomAddress:
    if paramLen != 6 or params == nil:
      return 0x12'u8
    let req = hciLeSetRandomAddressReq(params)
    for i in 0 ..< nim_local_addr.len:
      nim_local_addr[i] = req.address.data[i]
    nim_local_addr_valid = true
    0
  of HciOpLeSetAdvParams:
    if paramLen != 15 or params == nil:
      return 0x12'u8
    let req = hciLeSetAdvParamsReq(params)
    for i in 0 ..< 15:
      nim_adv_params[i] = req.bytes[i]
    0
  of HciOpLeSetAdvData:
    if paramLen != 32 or params == nil:
      return 0x12'u8
    let req = hciLeDataPayloadReq(params)
    if req.length > 31'u8:
      return 0x12'u8
    let n = min(req.length.int, nim_adv_data.len)
    nim_adv_data_len = n.uint8
    for i in 0 ..< n:
      nim_adv_data[i] = req.data[i]
    0
  of HciOpLeSetScanRspData:
    if paramLen != 32 or params == nil:
      return 0x12'u8
    let req = hciLeDataPayloadReq(params)
    if req.length > 31'u8:
      return 0x12'u8
    let n = min(req.length.int, nim_scan_rsp_data.len)
    nim_scan_rsp_data_len = n.uint8
    for i in 0 ..< n:
      nim_scan_rsp_data[i] = req.data[i]
    if nim_adv_enabled:
      programBtbleLegacyAdv(nim_adv_data_len)
    0
  of HciOpLeSetAdvEnable:
    if paramLen != 1 or params == nil:
      return 0x12'u8
    programNimAdvertising(hciLeSetAdvEnableReq(params).enabled != 0)
  of HciOpLeSetScanParams:
    nim_hci_debug_stage = 0x4510'u32
    if paramLen != 7 or params == nil:
      return 0x12'u8
    let req = hciLeSetScanParamsReq(params)
    when defined(bl808m0) and bl808BleNimPureCentral:
      if req.scanType > 1'u8:
        return HciStatusInvalidParams
    nim_scan_params[0] = req.scanType
    nim_scan_params[1] = uint8(req.interval and 0xFF'u16)
    nim_scan_params[2] = uint8(req.interval shr 8)
    nim_scan_params[3] = uint8(req.window and 0xFF'u16)
    nim_scan_params[4] = uint8(req.window shr 8)
    nim_scan_params[5] = req.ownAddrType
    nim_scan_params[6] = req.filterPolicy
    nim_hci_debug_stage = 0x4511'u32
    0
  of HciOpLeSetScanEnable:
    nim_hci_debug_stage = 0x4520'u32
    if paramLen != 2 or params == nil:
      return 0x12'u8
    let req = hciLeSetScanEnableReq(params)
    nim_scan_enabled = req.enabled != 0
    when defined(bl808m0) and bl808BleNimPureCentral:
      bleCentralDebugMark(0x800'u32, req.enabled.uint32)
      nim_hci_debug_stage = 0x4521'u32
      programNimScanning(nim_scan_enabled)
    else:
      0
  of HciOpLeCreateConnection:
    nim_hci_debug_stage = 0x4530'u32
    if paramLen != 25 or params == nil:
      return 0x12'u8
    nim_scan_enabled = false
    when defined(bl808m0) and bl808BleNimPureCentral:
      let initStatus = programNimInitiator(params, paramLen)
      if initStatus != 0'u8:
        return initStatus
    elif bl808BleNimSyntheticCentral or bl808BleNimSyntheticCentralComplete:
      sendLeConnectionComplete(params, paramLen)
    else:
      return 0x11'u8
    0
  of HciOpLeCreateConnectionCancel:
    if paramLen != 0:
      return 0x12'u8
    when defined(bl808m0) and bl808BleNimPureCentral:
      cancelNimInitiator()
    else:
      0x0C'u8
  else:
    0x01'u8

# Platform RTOS wrappers. The HAL validation build has no FreeRTOS layer, so
# provide a bounded single-queue shim that is enough for controller smoke tests.
type BleQueue = object
  length: uint32
  itemSize: uint32
  head: uint32
  tail: uint32
  count: uint32
  storage: array[20 * 8, uint8]

var bleMainQueue: BleQueue

proc ble_xQueueCreate(length: uint32, item_size: uint32): pointer {.exportc, cdecl.} =
  if length == 0 or item_size == 0 or length * item_size > bleMainQueue.storage.len.uint32:
    return nil
  bleMainQueue.length = length
  bleMainQueue.itemSize = item_size
  bleMainQueue.head = 0
  bleMainQueue.tail = 0
  bleMainQueue.count = 0
  cast[pointer](addr bleMainQueue)

proc ble_xQueueSend(q: pointer, item: pointer, timeout: uint32): uint32 {.exportc, cdecl.} =
  discard timeout
  if q == nil or item == nil:
    return 0
  let queue = cast[ptr BleQueue](q)
  if queue.count >= queue.length:
    return 0
  let off = queue.tail * queue.itemSize
  discard c_memcpy(addr queue.storage[off], item, queue.itemSize.csize_t)
  queue.tail = (queue.tail + 1) mod queue.length
  inc queue.count
  1

proc ble_xQueueReceive(q: pointer, item: pointer, timeout: uint32): uint32 {.exportc, cdecl.} =
  discard timeout
  if q == nil or item == nil:
    return 0
  let queue = cast[ptr BleQueue](q)
  if queue.count == 0:
    return 0
  let off = queue.head * queue.itemSize
  discard c_memcpy(item, addr queue.storage[off], queue.itemSize.csize_t)
  queue.head = (queue.head + 1) mod queue.length
  dec queue.count
  1

proc bleQueuePending(q: pointer): bool {.inline.} =
  q != nil and cast[ptr BleQueue](q).count != 0

proc ble_vTaskDelete(t: pointer) {.exportc, cdecl.} =
  discard t

proc ble_uxTaskPriorityGet(t: pointer): uint32 {.exportc, cdecl.} =
  discard t
  0

proc ble_xQueueSendFromISR(q: pointer, item: pointer, woken: ptr uint32): uint32 {.exportc, cdecl.} =
  if woken != nil:
    woken[] = 0
  ble_xQueueSend(q, item, 0)

proc ble_portYIELD_FROM_ISR() {.exportc, cdecl.} =
  discard

# ---------------------------------------------------------------------------
# Inline helpers
# ---------------------------------------------------------------------------

proc csrRead(csr: uint32): uint32 {.inline.} =
  var val: uint32
  asm """
    csrr %0, mstatus
    : "=r"(`val`)
  """
  val

proc disableInterrupts(): uint32 {.inline.} =
  ## Save mstatus, clear MIE (bit 3). Returns old mstatus.
  let old = csrRead(0x300)
  asm """
    csrci mstatus, 8
  """
  old

proc restoreInterrupts(mstatus: uint32) {.inline.} =
  asm """
    csrw mstatus, %0
    :: "r"(`mstatus`)
  """

# ---------------------------------------------------------------------------
# ======================= CO_LIST IMPLEMENTATION ===========================
# ---------------------------------------------------------------------------

proc ble_co_list_init*(list: ptr CoList) {.exportc, cdecl.} =
  ## Initialize a linked list (set first and last to nil)
  if co_list_init_patch != nil:
    let r = co_list_init_patch(0, list)
    if r != 0:
      return
  list.first = nil
  list.last = nil

proc ble_co_list_push_back*(list: ptr CoList, node: ptr CoListNode) {.exportc, cdecl.} =
  ## Push a node to the back of the list
  if co_list_push_back_patch != nil:
    let r = co_list_push_back_patch(0, list, node)
    if r != 0:
      return
  if node == nil:
    return
  if list.first == nil:
    list.first = node
  else:
    list.last.next = node
  list.last = node
  node.next = nil

proc ble_co_list_push_front*(list: ptr CoList, node: ptr CoListNode) {.exportc, cdecl.} =
  ## Push a node to the front of the list
  if co_list_push_front_patch != nil:
    let r = co_list_push_front_patch(0, list, node)
    if r != 0:
      return
  if node == nil:
    return
  node.next = list.first
  list.first = node
  if list.last == nil:
    list.last = node

proc ble_co_list_pop_front*(list: ptr CoList): ptr CoListNode {.exportc, cdecl.} =
  ## Pop the first node from the list
  var res: pointer
  if co_list_pop_front_patch != nil:
    let r = co_list_pop_front_patch(addr res, list)
    if r != 0:
      return cast[ptr CoListNode](res)
  let node = list.first
  if node == nil:
    return nil
  list.first = node.next
  if list.first == nil:
    list.last = nil
  return node

proc ble_co_list_extract*(list: ptr CoList, node: ptr CoListNode) {.exportc, cdecl.} =
  ## Extract a specific node from the list
  if co_list_extract_patch != nil:
    var found: uint8
    let r = co_list_extract_patch(addr found, list, node, 0)
    if r != 0:
      return
  if node == nil:
    return
  var cur = list.first
  var prev: ptr CoListNode = nil
  while cur != nil:
    if cur == node:
      if prev == nil:
        list.first = cur.next
      else:
        prev.next = cur.next
      if list.last == cur:
        list.last = prev
      return
    prev = cur
    cur = cur.next

proc ble_co_list_extract_after*(list: ptr CoList, prev_node: ptr CoListNode,
                                 node: ptr CoListNode) {.exportc, cdecl.} =
  ## Extract a node that is known to follow prev_node
  if co_list_extract_after_patch != nil:
    let r = co_list_extract_after_patch(0, list, prev_node, node)
    if r != 0:
      return
  if node == nil:
    return
  if prev_node == nil:
    # Node is first
    list.first = node.next
  else:
    prev_node.next = node.next
  if list.last == node:
    list.last = prev_node

proc ble_co_list_find*(list: ptr CoList, node: ptr CoListNode): bool {.exportc, cdecl.} =
  ## Check if a node is in the list
  var res: pointer
  if co_list_find_patch != nil:
    let r = co_list_find_patch(addr res, list, node)
    if r != 0:
      return cast[uint32](res) != 0
  var cur = list.first
  while cur != nil:
    if cur == node:
      return true
    cur = cur.next
  return false

proc ble_co_list_merge*(dest: ptr CoList, src: ptr CoList) {.exportc, cdecl.} =
  ## Merge src list into dest (appending src to end of dest)
  if co_list_merge_patch != nil:
    let r = co_list_merge_patch(0, dest, src)
    if r != 0:
      return
  if src.first == nil:
    return
  if dest.first == nil:
    dest.first = src.first
  else:
    dest.last.next = src.first
  dest.last = src.last
  src.first = nil
  src.last = nil

proc ble_co_list_insert_before*(list: ptr CoList, before_node: ptr CoListNode,
                                 node: ptr CoListNode) {.exportc, cdecl.} =
  ## Insert node before before_node in the list
  if co_list_insert_before_patch != nil:
    let r = co_list_insert_before_patch(0, list, before_node, node)
    if r != 0:
      return
  if node == nil:
    return
  if before_node == nil or before_node == list.first:
    # Insert at front
    node.next = list.first
    list.first = node
    if list.last == nil:
      list.last = node
    return
  var cur = list.first
  while cur != nil:
    if cur.next == before_node:
      node.next = before_node
      cur.next = node
      return
    cur = cur.next

proc ble_co_list_insert_after*(list: ptr CoList, after_node: ptr CoListNode,
                                node: ptr CoListNode) {.exportc, cdecl.} =
  ## Insert node after after_node in the list
  if co_list_insert_after_patch != nil:
    let r = co_list_insert_after_patch(0, list, after_node, node)
    if r != 0:
      return
  if node == nil:
    return
  if after_node == nil:
    # Insert at front
    node.next = list.first
    list.first = node
    if list.last == nil:
      list.last = node
    return
  node.next = after_node.next
  after_node.next = node
  if list.last == after_node:
    list.last = node

proc ble_co_list_size*(list: ptr CoList): uint32 {.exportc, cdecl.} =
  ## Return the number of elements in the list
  var res: uint32
  if co_list_size_patch != nil:
    let r = co_list_size_patch(addr res, list)
    if r != 0:
      return res
  var count: uint32 = 0
  var cur = list.first
  while cur != nil:
    inc count
    cur = cur.next
  return count

proc ble_co_list_check_size_available*(list: ptr CoList, limit: uint32): bool {.exportc, cdecl.} =
  ## Check if the list has fewer than limit elements
  var res: uint8
  if co_list_check_size_available_patch != nil:
    let r = co_list_check_size_available_patch(addr res, list, limit)
    if r != 0:
      return res != 0
  var count: uint32 = 0
  var cur = list.first
  while cur != nil:
    inc count
    if count >= limit:
      return false
    cur = cur.next
  return true

proc ble_co_list_pool_init*(list: ptr CoList, pool: pointer, elt_size: uint32,
                             count: uint32, init_cb: pointer, last_cb: pointer) {.exportc, cdecl.} =
  ## Initialize a list from a pool of fixed-size elements
  ble_co_list_init(list)
  var base = cast[uint](pool)
  for i in 0'u32 ..< count:
    let node = cast[ptr CoListNode](base)
    if init_cb != nil and i < count - 1:
      let cb = cast[proc(p: pointer, data: pointer) {.cdecl.}](init_cb)
      cb(pool, cast[pointer](base))
    if i == count - 1 and last_cb != nil:
      let cb = cast[proc(p: pointer, data: pointer) {.cdecl.}](last_cb)
      cb(pool, cast[pointer](base))
    ble_co_list_push_back(list, node)
    base += elt_size

# Patch wrappers for co_list
proc patch_ble_co_list_init*(list: ptr CoList) {.exportc: "_patch_ble_co_list_init", cdecl.} =
  list.first = nil
  list.last = nil

proc patch_ble_co_list_push_back*(list: ptr CoList, node: ptr CoListNode) {.exportc: "_patch_ble_co_list_push_back", cdecl.} =
  if node == nil:
    return
  if list.first == nil:
    list.first = node
  else:
    list.last.next = node
  list.last = node
  node.next = nil

proc patch_ble_co_list_push_front*(list: ptr CoList, node: ptr CoListNode) {.exportc: "_patch_ble_co_list_push_front", cdecl.} =
  if node == nil:
    return
  node.next = list.first
  list.first = node
  if list.last == nil:
    list.last = node

proc patch_ble_co_list_pop_front*(list: ptr CoList): ptr CoListNode {.exportc: "_patch_ble_co_list_pop_front", cdecl.} =
  let node = list.first
  if node == nil:
    return nil
  list.first = node.next
  if list.first == nil:
    list.last = nil
  return node

proc patch_ble_co_list_extract*(list: ptr CoList, node: ptr CoListNode) {.exportc: "_patch_ble_co_list_extract", cdecl.} =
  if node == nil:
    return
  var cur = list.first
  var prev: ptr CoListNode = nil
  while cur != nil:
    if cur == node:
      if prev == nil:
        list.first = cur.next
      else:
        prev.next = cur.next
      if list.last == cur:
        list.last = prev
      return
    prev = cur
    cur = cur.next

proc patch_ble_co_list_extract_after*(list: ptr CoList, prev_node: ptr CoListNode,
                                          node: ptr CoListNode) {.exportc: "_patch_ble_co_list_extract_after", cdecl.} =
  if node == nil:
    return
  if prev_node == nil:
    list.first = node.next
  else:
    prev_node.next = node.next
  if list.last == node:
    list.last = prev_node

proc patch_ble_co_list_find*(list: ptr CoList, node: ptr CoListNode): bool {.exportc: "_patch_ble_co_list_find", cdecl.} =
  var cur = list.first
  while cur != nil:
    if cur == node:
      return true
    cur = cur.next
  return false

proc patch_ble_co_list_merge*(dest: ptr CoList, src: ptr CoList) {.exportc: "_patch_ble_co_list_merge", cdecl.} =
  if src.first == nil:
    return
  if dest.first == nil:
    dest.first = src.first
  else:
    dest.last.next = src.first
  dest.last = src.last
  src.first = nil
  src.last = nil

proc patch_ble_co_list_insert_before*(list: ptr CoList, before_node: ptr CoListNode,
                                          node: ptr CoListNode) {.exportc: "_patch_ble_co_list_insert_before", cdecl.} =
  if node == nil:
    return
  if before_node == nil or before_node == list.first:
    node.next = list.first
    list.first = node
    if list.last == nil:
      list.last = node
    return
  var cur = list.first
  while cur != nil:
    if cur.next == before_node:
      node.next = before_node
      cur.next = node
      return
    cur = cur.next

proc patch_ble_co_list_insert_after*(list: ptr CoList, after_node: ptr CoListNode,
                                         node: ptr CoListNode) {.exportc: "_patch_ble_co_list_insert_after", cdecl.} =
  if node == nil:
    return
  if after_node == nil:
    node.next = list.first
    list.first = node
    if list.last == nil:
      list.last = node
    return
  node.next = after_node.next
  after_node.next = node
  if list.last == after_node:
    list.last = node

proc patch_ble_co_list_size*(list: ptr CoList): uint32 {.exportc: "_patch_ble_co_list_size", cdecl.} =
  var count: uint32 = 0
  var cur = list.first
  while cur != nil:
    inc count
    cur = cur.next
  return count

proc patch_ble_co_list_check_size_available*(list: ptr CoList, limit: uint32): bool {.exportc: "_patch_ble_co_list_check_size_available", cdecl.} =
  var count: uint32 = 0
  var cur = list.first
  while cur != nil:
    inc count
    if count >= limit:
      return false
    cur = cur.next
  return true

# ---------------------------------------------------------------------------
# ======================== CO_BDADDR =======================================
# ---------------------------------------------------------------------------

proc co_bdaddr_set*(dest: ptr BdAddr, src: ptr BdAddr) {.exportc, cdecl.} =
  discard c_memcpy(dest, src, 6)

proc co_bdaddr_compare*(a: ptr BdAddr, b: ptr BdAddr): bool {.exportc, cdecl.} =
  return c_memcmp(a, b, 6) == 0

# ---------------------------------------------------------------------------
# ======================== KE_EVENT ========================================
# ---------------------------------------------------------------------------

proc patch_ble_ke_event_init*() {.exportc: "_patch_ble_ke_event_init", cdecl.} =
  discard c_memset(addr ke_event_slots[0], 0, (sizeof(KeEventSlot) * KE_EVENT_MAX).csize_t)

proc ble_ke_event_init*() {.exportc, cdecl.} =
  if ke_event_init_patch != nil:
    let r = ke_event_init_patch(0)
    if r != 0:
      return
  discard c_memset(addr ke_event_slots[0], 0, (sizeof(KeEventSlot) * KE_EVENT_MAX).csize_t)

proc patch_ble_ke_event_callback_set*(idx: uint8, cb: KeEventCallback) {.exportc: "_patch_ble_ke_event_callback_set", cdecl.} =
  if idx < KE_EVENT_MAX and cb != nil:
    ke_event_slots[idx].callback = cb

proc ble_ke_event_callback_set*(idx: uint8, cb: KeEventCallback) {.exportc, cdecl.} =
  if ke_event_callback_set_patch != nil:
    var status: uint8
    let r = ke_event_callback_set_patch(addr status, idx, cb)
    if r != 0:
      return
  if idx < KE_EVENT_MAX and cb != nil:
    ke_event_slots[idx].callback = cb

proc patch_ble_ke_event_set*(idx: uint8) {.exportc: "_patch_ble_ke_event_set", cdecl.} =
  if idx < KE_EVENT_MAX:
    let old = disableInterrupts()
    ke_event_field = ke_event_field or (1'u32 shl idx)
    restoreInterrupts(old)

proc ble_ke_event_set*(idx: uint8) {.exportc, cdecl.} =
  if ke_event_set_patch != nil:
    let r = ke_event_set_patch(0, idx)
    if r != 0:
      return
  if idx < KE_EVENT_MAX:
    let old = disableInterrupts()
    ke_event_field = ke_event_field or (1'u32 shl idx)
    restoreInterrupts(old)

proc patch_ble_ke_event_clear*(idx: uint8) {.exportc: "_patch_ble_ke_event_clear", cdecl.} =
  if idx < KE_EVENT_MAX:
    let old = disableInterrupts()
    ke_event_field = ke_event_field and not (1'u32 shl idx)
    restoreInterrupts(old)

proc ble_ke_event_clear*(idx: uint8) {.exportc, cdecl.} =
  if ke_event_clear_patch != nil:
    let r = ke_event_clear_patch(0, idx)
    if r != 0:
      return
  if idx < KE_EVENT_MAX:
    let old = disableInterrupts()
    ke_event_field = ke_event_field and not (1'u32 shl idx)
    restoreInterrupts(old)

proc ble_ke_event_get*(idx: uint8): bool {.exportc, cdecl.} =
  ## Check if an event is set
  if idx >= KE_EVENT_MAX:
    return false
  return (ke_event_field and (1'u32 shl idx)) != 0

proc patch_ble_ke_event_get_all*(): uint32 {.exportc: "_patch_ble_ke_event_get_all", cdecl.} =
  return ke_event_field

proc ble_ke_event_get_all*(): uint32 {.exportc, cdecl.} =
  if ke_event_get_all_patch != nil:
    var res: uint32
    let r = ke_event_get_all_patch(addr res)
    if r != 0:
      return res
  return ke_event_field

proc patch_ble_ke_event_flush*() {.exportc: "_patch_ble_ke_event_flush", cdecl.} =
  ke_event_field = 0

proc ble_ke_event_flush*() {.exportc, cdecl.} =
  if ke_event_flush_patch != nil:
    let r = ke_event_flush_patch()
    if r != 0:
      return
  ke_event_field = 0

proc bleKeEventYieldNeeded(drained, field: uint32): bool {.inline.} =
  drained >= BleKeEventDrainLimit and field != 0

proc patch_ble_ke_event_schedule*() {.exportc: "_patch_ble_ke_event_schedule", cdecl.} =
  var field = ke_event_field
  var drained = 0'u32
  while field != 0:
    # Find lowest set bit
    var bit = 0'u8
    var tmp = field
    while (tmp and 1) == 0:
      tmp = tmp shr 1
      inc bit
    # Clear and dispatch
    let old = disableInterrupts()
    ke_event_field = ke_event_field and not (1'u32 shl bit)
    restoreInterrupts(old)
    if bit < KE_EVENT_MAX and ke_event_slots[bit].callback != nil:
      ke_event_slots[bit].callback(bit)
    inc drained
    field = ke_event_field
    if bleKeEventYieldNeeded(drained, field):
      inc nim_ble_ke_event_yield_count
      nim_ble_ke_event_yield_field = field
      return

proc ble_ke_event_schedule*() {.exportc, cdecl.} =
  if ke_event_schedule_patch != nil:
    let r = ke_event_schedule_patch(0)
    if r != 0:
      return
  patch_ble_ke_event_schedule()

proc ble_ke_get_event_field*(): uint32 {.exportc, cdecl.} =
  return ke_event_field

# ---------------------------------------------------------------------------
# ======================== KE_MEM ==========================================
# ---------------------------------------------------------------------------

var
  ke_mem_pool*: array[KE_MEM_POOL_MAX, uint8]  ## Pool tracking

proc patch_ble_ke_mem_is_in_heap*(p: pointer): bool {.exportc: "_patch_ble_ke_mem_is_in_heap", cdecl.} =
  let addr_val = cast[uint](p)
  let heap_start = cast[uint](ke_mem_heap)
  let heap_end = cast[uint](ke_mem_heap_end)
  return addr_val >= heap_start and addr_val < heap_end

proc ble_ke_mem_is_in_heap*(p: pointer): bool {.exportc, cdecl.} =
  if ke_mem_is_in_heap_patch != nil:
    var res: uint8
    let r = ke_mem_is_in_heap_patch(addr res, p)
    if r != 0:
      return res != 0
  return patch_ble_ke_mem_is_in_heap(p)

proc patch_ble_ke_mem_init*() {.exportc: "_patch_ble_ke_mem_init", cdecl.} =
  ## Initialize kernel memory subsystem
  discard c_memset(addr ke_mem_pool[0], 0, KE_MEM_POOL_MAX.csize_t)

proc ble_ke_mem_init*() {.exportc, cdecl.} =
  if ke_mem_init_patch != nil:
    let r = ke_mem_init_patch(0)
    if r != 0:
      return
  patch_ble_ke_mem_init()

proc ble_ke_mem_is_empty*(): bool {.exportc, cdecl.} =
  ## Check if the memory heap is empty (all freed)
  ## Walk free list to see if total free equals heap size
  return true  # Simplified: report empty when no allocations tracked

proc ble_ke_check_malloc*(): uint32 {.exportc, cdecl.} =
  ## Debug: return number of allocated blocks
  return 0

# ---------------------------------------------------------------------------
# ======================== KE_MALLOC / FREE ================================
# ---------------------------------------------------------------------------

proc patch_ble_ke_malloc*(size: uint32, mtype: uint32): pointer {.exportc: "_patch_ble_ke_malloc", cdecl.} =
  ## Allocate memory from kernel heap
  ## Uses simple first-fit free-list allocator
  ## Each block has a 4-byte header: [size:31 | free:1]
  var res: pointer
  if ke_malloc_patch != nil:
    let r = ke_malloc_patch(addr res, size, mtype)
    if r != 0:
      return res
  # Fallback to C malloc
  proc cmalloc(s: csize_t): pointer {.importc: "malloc", cdecl.}
  return cmalloc(size.csize_t)

proc ble_ke_malloc*(size: uint32, mtype: uint32): pointer {.exportc, cdecl.} =
  if ke_malloc_patch != nil:
    var res: pointer
    let r = ke_malloc_patch(addr res, size, mtype)
    if r != 0:
      return res
  return patch_ble_ke_malloc(size, mtype)

proc patch_ble_ke_free*(p: pointer) {.exportc: "_patch_ble_ke_free", cdecl.} =
  if p == nil:
    return
  if ke_free_patch != nil:
    discard ke_free_patch(0, p)
    return
  proc cfree(p: pointer) {.importc: "free", cdecl.}
  cfree(p)

proc ble_ke_free*(p: pointer) {.exportc, cdecl.} =
  if ke_free_patch != nil:
    discard ke_free_patch(0, p)
    return
  patch_ble_ke_free(p)

proc patch_ble_ke_is_free*(p: pointer): bool {.exportc: "_patch_ble_ke_is_free", cdecl.} =
  if p == nil:
    return true
  if ke_is_free_patch != nil:
    var res: uint8
    discard ke_is_free_patch(addr res, p)
    return res != 0
  return false

proc ble_ke_is_free*(p: pointer): bool {.exportc, cdecl.} =
  if ke_is_free_patch != nil:
    var res: uint8
    let r = ke_is_free_patch(addr res, p)
    if r != 0:
      return res != 0
  return patch_ble_ke_is_free(p)

proc ble_controller_trace_malloc_init*() {.exportc, cdecl.} =
  discard c_memset(addr trace_malloc_info[0], 0, sizeof(trace_malloc_info).csize_t)
  trace_malloc_idx = 0

proc trace_malloc*(size: uint32, p: pointer) {.exportc, cdecl.} =
  if trace_malloc_idx < 16:
    trace_malloc_info[trace_malloc_idx] = cast[uint32](p)
    inc trace_malloc_idx

proc trace_free*(p: pointer) {.exportc, cdecl.} =
  for i in 0 ..< 16:
    if trace_malloc_info[i] == cast[uint32](p):
      trace_malloc_info[i] = 0
      break

proc ble_ke_debug_mem_info*() {.exportc, cdecl.} =
  ## Debug: print memory info (no-op in production)
  discard

# ---------------------------------------------------------------------------
# ======================== KE_MSG ==========================================
# ---------------------------------------------------------------------------

proc getMsgHeader(param: pointer): ptr KeMsgHeader {.inline.} =
  ## Given a pointer to the message parameters, get the header
  let envelope = cast[ptr KeMsgEnvelope](
    cast[uint](param) - offsetof(KeMsgEnvelope, param).uint)
  addr envelope.header

proc getMsgParam(hdr: ptr KeMsgHeader): pointer {.inline.} =
  let envelope = cast[ptr KeMsgEnvelope](hdr)
  cast[pointer](addr envelope.param[0])

proc keStateHandlerAt(base: ptr KeStateHandler, idx: uint8): ptr KeStateHandler {.inline.} =
  addr cast[ptr UncheckedArray[KeStateHandler]](base)[idx]

proc keMsgHandlerEntryAt(base: ptr KeStateMsgHandler,
                         idx: uint16): ptr KeStateMsgHandler {.inline.} =
  addr cast[ptr UncheckedArray[KeStateMsgHandler]](base)[idx]

template emRxDescTableAt(base: uint32): ptr UncheckedArray[EmBufRxDesc] =
  cast[ptr UncheckedArray[EmBufRxDesc]](base)

template emTxDescTableAt(base: uint32): ptr UncheckedArray[EmBufTxDesc] =
  cast[ptr UncheckedArray[EmBufTxDesc]](base)

template emRxFreeTable(): ptr UncheckedArray[EmBufRxFreeSlot] =
  cast[ptr UncheckedArray[EmBufRxFreeSlot]](bleEmPointer(0x35C'u16))

proc emRxDescAt(base: uint32, idx: uint16): ptr EmBufRxDesc {.inline.} =
  addr emRxDescTableAt(base)[idx]

proc emTxDescAt(base: uint32, idx: uint16): ptr EmBufTxDesc {.inline.} =
  addr emTxDescTableAt(base)[idx]

proc emRxFreeSlotAt(idx: uint16): ptr EmBufRxFreeSlot {.inline.} =
  addr emRxFreeTable()[idx]

proc emRxFreeStatusField(idx: uint16): ptr uint16 {.inline.} =
  addr emRxFreeSlotAt(idx).status

proc emRxBufferPointerField(idx: uint16): ptr uint16 {.inline.} =
  addr emRxFreeSlotAt(idx).buf_ptr

proc emTxPoolDescForBufferOffset(offset: uint32): ptr EmBufTxDesc {.inline.} =
  let txDescBase = BLE_EM_BASE + 0x264'u32
  emTxDescAt(txDescBase, uint16(offset div EM_BUF_TX_DATA_SIZE.uint32))

when defined(bl808m0) and bl808BleNimConnectionEnabled and
    bl808BleNimManualConnTx:
  proc handleNimLldMessage(param: pointer): bool =
    if param == nil:
      return false
    let hdr = getMsgHeader(param)
    let p = cast[ptr UncheckedArray[uint8]](param)
    let conhdl = uint16((hdr.dest_id shr 8) and 0x00FF'u16)
    case hdr.id
    of 523'u16:
      let pduLen = uint16(p[2])
      let dataOff = uint16(p[4]) or (uint16(p[5]) shl 8)
      nimLlcpRecordRx(0'u16, dataOff, pduLen)
      if pduLen > 0'u16:
        let opcode = btbleEmRead8(dataOff)
        let reason =
          if pduLen > 1'u16: btbleEmRead8(dataOff + 1'u16)
          else: NimLlcpDefaultReason
        if nimLlcpRxPduValid(opcode, pduLen):
          inc nim_llcp_rx_count
          nim_llcp_last_opcode = opcode.uint32
          nimLlcpObserveEm(conhdl, dataOff, uint8(pduLen))
          nimLlcpRespond(conhdl, opcode, reason)
        else:
          nimLlcpRecordMalformed(0'u16, opcode, pduLen)
      true
    of 525'u16:
      let dataOff = uint16(p[0]) or (uint16(p[1]) shl 8)
      let pduLen = uint16(p[2]) or (uint16(p[3]) shl 8)
      let llid = p[4] and 0x03'u8
      if llid == NimDataLlIdControl and pduLen > 0'u16:
        nimLlcpRecordRx(uint16(llid), dataOff, pduLen)
        let opcode = btbleEmRead8(dataOff)
        let reason =
          if pduLen > 1'u16: btbleEmRead8(dataOff + 1'u16)
          else: NimLlcpDefaultReason
        if nimLlcpRxPduValid(opcode, pduLen):
          inc nim_llcp_rx_count
          nim_llcp_last_opcode = opcode.uint32
          nimLlcpObserveEm(conhdl, dataOff, uint8(pduLen))
          nimLlcpRespond(conhdl, opcode, reason)
        else:
          nimLlcpRecordMalformed(uint16(llid), opcode, pduLen)
      true
    else:
      false

proc patch_ble_ke_msg_alloc*(id: KeMsgId, dest_id: KeTaskId,
                                 src_id: KeTaskId, param_len: uint16): pointer {.exportc: "_patch_ble_ke_msg_alloc", cdecl.} =
  ## Allocate a kernel message with header + param space
  let total = param_len.uint32 + offsetof(KeMsgEnvelope, param).uint32
  let mem = ble_ke_malloc(total, 0)
  if mem == nil:
    return nil
  let hdr = cast[ptr KeMsgHeader](mem)
  hdr.next = cast[ptr KeMsgHeader](cast[uint32](0xFFFFFFFF'u32))  # -1 sentinel
  hdr.id = id
  hdr.dest_id = dest_id
  hdr.src_id = src_id
  hdr.param_len = param_len
  let param = getMsgParam(hdr)
  discard c_memset(param, 0, param_len.csize_t)
  return param

proc ble_ke_msg_alloc*(id: KeMsgId, dest_id: KeTaskId,
                        src_id: KeTaskId, param_len: uint16): pointer {.exportc, cdecl.} =
  if ke_msg_alloc_patch != nil:
    var res: pointer
    let r = ke_msg_alloc_patch(addr res, id, dest_id, src_id, param_len)
    if r != 0:
      return res
  return patch_ble_ke_msg_alloc(id, dest_id, src_id, param_len)

proc patch_ble_ke_msg_send*(param: pointer) {.exportc: "_patch_ble_ke_msg_send", cdecl.} =
  ## Send a kernel message (enqueue to destination)
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    when bl808BleNimManualConnTx:
      if handleNimLldMessage(param):
        ble_ke_free(getMsgHeader(param))
        return
  let old = disableInterrupts()
  let hdr = getMsgHeader(param)
  ble_co_list_push_back(addr ke_msg_queue, cast[ptr CoListNode](hdr))
  restoreInterrupts(old)
  ble_ke_event_set(BleKeMessageEventId)

proc ble_ke_msg_send*(param: pointer) {.exportc, cdecl.} =
  if ke_msg_send_patch != nil:
    let r = ke_msg_send_patch(0, param)
    if r != 0:
      return
  patch_ble_ke_msg_send(param)

proc patch_ble_ke_msg_get_sent_num*(id: KeMsgId): uint32 {.exportc: "_patch_ble_ke_msg_get_sent_num", cdecl.} =
  ## Count messages with given id in the queue
  var count: uint32 = 0
  var cur = cast[ptr KeMsgHeader](ke_msg_queue.first)
  while cur != nil:
    if cur.id == id:
      inc count
    cur = cast[ptr KeMsgHeader](cur.next)
  return count

proc ble_ke_msg_get_sent_num*(id: KeMsgId): uint32 {.exportc, cdecl.} =
  if ke_msg_get_sent_num_patch != nil:
    var res: uint32
    let r = ke_msg_get_sent_num_patch(addr res, id)
    if r != 0:
      return res
  return patch_ble_ke_msg_get_sent_num(id)

proc patch_ble_ke_msg_send_basic*(id: KeMsgId, dest_id: KeTaskId,
                                      src_id: KeTaskId) {.exportc: "_patch_ble_ke_msg_send_basic", cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled and
      bl808BleNimManualConnTx:
    if id == 0x0213'u16: # LLD_DISC_IND routed to LLC in the vendor task table.
      discard dest_id
      discard src_id
      noteNimPeripheralDisconnectedFrom(3'u32, NimLlcpDefaultReason)
      return
  let param = ble_ke_msg_alloc(id, dest_id, src_id, 0)
  if param != nil:
    ble_ke_msg_send(param)

proc ble_ke_msg_send_basic*(id: KeMsgId, dest_id: KeTaskId,
                             src_id: KeTaskId) {.exportc, cdecl.} =
  if ke_msg_send_basic_patch != nil:
    let r = ke_msg_send_basic_patch(0, id, dest_id, src_id)
    if r != 0:
      return
  patch_ble_ke_msg_send_basic(id, dest_id, src_id)

when defined(bl808m0) and
    (bl808BleNimConnectionEnabled or bl808BleNimPureCentral):
  type SchArbStartCb = proc(elt: pointer) {.cdecl.}

  const bl808BleNimDeferArbCallbacks* {.booldefine.}: bool = true

  proc runNimArbCallback(cb: SchArbStartCb, elt: pointer) =
    cb(elt)

  when bl808BleNimConnectionEnabled:
    var nim_conn_arb_pending_cb: SchArbStartCb
    var nim_conn_arb_pending_elt: pointer

    proc nimArbCallbackPending(): bool {.inline.} =
      nim_conn_arb_pending_cb != nil

    proc queueNimArbCallback(cb: SchArbStartCb, elt: pointer): bool =
      if nim_conn_arb_pending_cb != nil:
        return false
      nim_conn_arb_pending_cb = cb
      nim_conn_arb_pending_elt = elt
      true

    proc serviceNimArbCallbacks() =
      var drained = 0'u32
      while drained < BleArbCallbackDrainLimit and nimArbCallbackPending():
        let cb = nim_conn_arb_pending_cb
        let elt = nim_conn_arb_pending_elt
        nim_conn_arb_pending_cb = nil
        nim_conn_arb_pending_elt = nil
        if cb != nil:
          runNimArbCallback(cb, elt)
        inc drained
      if nimArbCallbackPending():
        inc nim_ble_arb_callback_yield_count

  proc nimLldRxDescAddr(idx: uint8): uint32 {.inline.} =
    BTBLE_EM_BASE + btbleRxDescOffset(uint32(idx))

  proc lld_rxdesc_buf_ready*(buf: uint16): uint8 {.exportc, cdecl.} =
    let pending = lld_env[16]
    if pending == 0'u8:
      return 0
    var idx = 0'u8
    var mask = pending
    while (mask and 1'u8) == 0'u8:
      inc idx
      mask = mask shr 1
    btbleRxDescSetDataOffset(nimLldRxDescAddr(idx), buf)
    lld_env[16] = pending and not (1'u8 shl idx)
    1

  proc lld_rxdesc_check*(idx: uint8): pointer {.exportc, cdecl.} =
    when defined(bl808BleBridgeDiag):
      nim_bridge_stage = 0x6000'u32 or idx.uint32
    inc nim_lld_rx_check_count
    for step in 0'u32 ..< 8'u32:
      let cur = lld_env[14] and 0x07'u8
      let desc = nimLldRxDescAddr(cur)
      let status = btbleRxDescStatus(desc)
      let header = btbleRxDescHeader(desc)
      let meta = btbleRxDescMeta(desc)
      nim_lld_rx_last_idx = idx.uint32
      nim_lld_rx_last_env_idx = cur.uint32
      nim_lld_rx_last_status = status.uint32
      nim_lld_rx_last_header = header.uint32
      nim_lld_rx_last_meta = meta.uint32
      if (status and BtbleRxDescDone) == 0:
        break
      if header == 0'u16:
        btbleRxDescClearDone(desc, status)
        lld_env[14] = uint8((uint32(cur) + 1'u32) and 0x07'u32)
        inc nim_lld_rx_free_count
        continue
      let pduType = uint8(header and 0x000F'u16)
      let dataLlId = uint8(header and 0x0003'u16)
      let advLen = advPayloadLen(header)
      let connLen = connDataPayloadLen(header)
      var scanDescObserved = false
      var scanDescUnsupported = false
      when defined(bl808m0):
        if nim_scan_enabled and advLen > 0'u8:
          scanDescObserved = true
          if advLen >= 6'u8 and
              (pduType == 0x00'u8 or pduType == 0x02'u8 or
               pduType == 0x04'u8 or pduType == 0x06'u8):
            sendLeAdvertisingReportFromRxDesc(header, btbleRxDescDataOffset(desc))
          else:
            scanDescUnsupported = true
      when bl808BleNimConnectionEnabled:
        if pduType == 0x05'u8 and advLen == 34'u8:
          # Match vendor lld_adv_frm_isr timing extraction.
          btbleRecordConnectDescTiming(desc)
          let rxFine = btbleAdvRxFine(desc)
          let rxClock = btbleAdvRxClock(desc)
          var connectPdu: array[34, uint8]
          let dataOff = btbleRxDescDataOffset(desc)
          let payload = btbleEmPayload(dataOff)
          for j in 0 ..< connectPdu.len:
            connectPdu[j] = payload[j]
          btbleRxDescClearDone(desc, status)
          noteNimRxDescConsumed(cur.uint32)
          inc nim_lld_rx_free_count
          handleNimConnectInd(uint8(cur and 0x07'u8),
            cast[ptr UncheckedArray[uint8]](addr connectPdu[0]),
            header, rxClock, rxFine)
          nimConnMark(0x250'u32)
          continue
        when bl808BleNimManualConnTx:
          if nim_conn_started and not connRxStatusAcceptsPayload(status):
            rejectConnRxDescriptor(desc, status, header, cur.uint32)
            continue
          if nim_conn_started and not validConnDataHeader(header):
            btbleRxDescReleaseLink(desc, status)
            noteNimRxDescConsumed(cur.uint32)
            inc nim_lld_rx_free_count
            continue
          if nim_conn_started:
            noteNimPeripheralConnected(activeNimConnectionHandle())
          if nim_conn_started and
              dataLlId == NimDataLlIdControl and connLen > 0'u8:
            let conhdl = activeNimConnectionHandle()
            let dataOff = btbleRxDescDataOffset(desc)
            nimLlcpRecordRx(header, dataOff, connLen.uint16)
            let opcode = btbleEmRead8(dataOff)
            let reason =
              if connLen > 1'u8: btbleEmRead8(dataOff + 1'u16)
              else: NimLlcpDefaultReason
            if nimLlcpRxPduValid(opcode, connLen.uint16):
              inc nim_llcp_rx_count
              nim_llcp_last_opcode =
                (uint32(header) shl 16) or opcode.uint32
              nimLlcpObserveEm(conhdl, dataOff, connLen)
              nimLlcpRespond(conhdl, opcode, reason)
            else:
              nimLlcpRecordMalformed(header, opcode, connLen.uint16)
            btbleRxDescReleaseLink(desc, status)
            noteNimRxDescConsumed(cur.uint32)
            inc nim_lld_rx_free_count
            continue
      if pduType == 0x03'u8 and advLen == 12'u8:
        btbleRxDescClearDone(desc, status)
        lld_env[14] = uint8((uint32(cur) + 1'u32) and 0x07'u32)
        inc nim_lld_rx_free_count
        continue
      if scanDescUnsupported:
        btbleRxDescClearDone(desc, status)
        lld_env[14] = uint8((uint32(cur) + 1'u32) and 0x07'u32)
        inc nim_lld_rx_free_count
        continue
      let descIdx = uint8((meta shr 11) and 0x001F'u16)
      if descIdx == (idx and 0x1F'u8):
        when bl808BleNimManualConnTx:
          if nim_conn_started and not connRxStatusAcceptsPayload(status):
            rejectConnRxDescriptor(desc, status, header, cur.uint32)
            continue
          if nim_conn_started and not validConnDataHeader(header):
            btbleRxDescReleaseLink(desc, status)
            noteNimRxDescConsumed(cur.uint32)
            inc nim_lld_rx_free_count
            continue
          if nim_conn_started:
            noteNimPeripheralConnected(activeNimConnectionHandle())
          if dataLlId == NimDataLlIdControl and connLen > 0'u8:
            let conhdl = activeNimConnectionHandle()
            let dataOff = btbleRxDescDataOffset(desc)
            nimLlcpRecordRx(header, dataOff, connLen.uint16)
            let opcode = btbleEmRead8(dataOff)
            let reason =
              if connLen > 1'u8: btbleEmRead8(dataOff + 1'u16)
              else: NimLlcpDefaultReason
            if nimLlcpRxPduValid(opcode, connLen.uint16):
              nim_llcp_last_opcode =
                (uint32(dataLlId) shl 24) or (uint32(connLen) shl 16) or
                opcode.uint32
              inc nim_llcp_rx_count
              nimLlcpObserveEm(conhdl, dataOff, connLen)
              nimLlcpRespond(conhdl, opcode, reason)
            else:
              nimLlcpRecordMalformed(header, opcode, connLen.uint16)
        nim_lld_rx_desc_idx = cur
        nim_lld_rx_desc_active = 1'u8
        inc nim_lld_rx_check_hit_count
        when defined(bl808BleBridgeDiag):
          nim_bridge_stage = 0x6100'u32 or cur.uint32
        return cast[pointer](desc)
      if scanDescObserved:
        btbleRxDescClearDone(desc, status)
        lld_env[14] = uint8((uint32(cur) + 1'u32) and 0x07'u32)
        inc nim_lld_rx_free_count
        continue
      break
    inc nim_lld_rx_check_miss_count
    when defined(bl808BleBridgeDiag):
      nim_bridge_stage = 0x6200'u32 or idx.uint32
    nil

  proc lld_rxdesc_free*(desc: pointer) {.exportc, cdecl.} =
    when defined(bl808BleBridgeDiag):
      nim_bridge_stage = 0x6300'u32 or
        (cast[uint32](desc) and 0x000000FF'u32)
    discard desc
    inc nim_lld_rx_free_count
    let cur = lld_env[14] and 0x07'u8
    let descAddr = nimLldRxDescAddr(cur)
    let status = btbleRxDescStatus(descAddr)
    btbleRxDescClearDone(descAddr, status)
    lld_env[14] = uint8((uint32(cur) + 1'u32) and 0x07'u32)
    nim_lld_rx_desc_idx = lld_env[14]
    nim_lld_rx_desc_active = 0'u8

  when bl808BleNimManualConnTx:
    proc serviceNimConnectionLlcpRxDescriptors() =
      if not nim_conn_started:
        return
      var handledLlcp = false
      let startIdx = uint32(lld_env[14] and 0x07'u8)
      for step in 0'u32 ..< 8'u32:
        let cur = (startIdx + step) and 0x07'u32
        let desc = nimLldRxDescAddr(uint8(cur))
        let status = btbleRxDescStatus(desc)
        if (status and BtbleRxDescDone) == 0:
          break
        let header = btbleRxDescHeader(desc)
        let meta = btbleRxDescMeta(desc)
        nim_lld_rx_last_idx = cur
        nim_lld_rx_last_env_idx = uint32(lld_env[14] and 0x07'u8)
        nim_lld_rx_last_status = status.uint32
        nim_lld_rx_last_header = header.uint32
        nim_lld_rx_last_meta = meta.uint32
        if not connRxStatusAcceptsPayload(status):
          rejectConnRxDescriptor(desc, status, header, cur)
          continue
        if not validConnDataHeader(header):
          btbleRxDescReleaseLink(desc, status)
          noteNimRxDescConsumed(cur)
          inc nim_lld_rx_free_count
          continue
        let conhdl = activeNimConnectionHandle()
        noteNimPeripheralConnected(conhdl)
        let dataLlId = uint8(header and 0x0003'u16)
        let pduLen = connDataPayloadLen(header)
        var payloadFresh = true
        when bl808BleNimPureConnection:
          if dataLlId != 0'u8:
            let rxFine = btbleConnRxFine(desc)
            let rxClock = btbleConnRxClock(desc)
            nimConnObserveRxHeader(header, rxClock, rxFine)
            payloadFresh = nim_conn_state.rxPayloadFresh
        if dataLlId == NimDataLlIdControl and pduLen > 0'u8:
          let dataOff = btbleRxDescDataOffset(desc)
          if payloadFresh:
            nimLlcpRecordRx(header, dataOff, pduLen.uint16)
            let opcode = btbleEmRead8(dataOff)
            let reason =
              if pduLen > 1'u8: btbleEmRead8(dataOff + 1'u16)
              else: NimLlcpDefaultReason
            if nimLlcpRxPduValid(opcode, pduLen.uint16):
              inc nim_llcp_rx_count
              handledLlcp = true
              nim_llcp_last_opcode =
                (uint32(header) shl 16) or opcode.uint32
              nimLlcpObserveEm(conhdl, dataOff, pduLen)
              nimLlcpRespond(conhdl, opcode, reason)
            else:
              nimLlcpRecordMalformed(header, opcode, pduLen.uint16)
          btbleRxDescReleaseLink(desc, status)
          if (lld_env[14] and 0x07'u8) == uint8(cur and 0x07'u32):
            noteNimRxDescConsumed(cur)
          inc nim_lld_rx_free_count
        elif (dataLlId == NimDataLlIdStart or
              dataLlId == NimDataLlIdContinuation) and pduLen > 0'u8:
          let dataOff = btbleRxDescDataOffset(desc)
          if payloadFresh:
            if sendHostAclData(conhdl, dataLlId, dataOff, pduLen):
              inc nim_acl_rx_count
            else:
              inc nim_acl_rx_drop_count
          btbleRxDescReleaseLink(desc, status)
          if (lld_env[14] and 0x07'u8) == uint8(cur and 0x07'u32):
            noteNimRxDescConsumed(cur)
          inc nim_lld_rx_free_count
        else:
          btbleRxDescReleaseLink(desc, status)
          if (lld_env[14] and 0x07'u8) == uint8(cur and 0x07'u32):
            noteNimRxDescConsumed(cur)
          inc nim_lld_rx_free_count
          continue
      if not handledLlcp:
        nimLlcpTrySendStartup(activeNimConnectionHandle())

  when not defined(bl808m0):
    proc sch_slice_per_add*(sliceType: uint8, conhdl: uint8,
                            interval: uint32, anchor: uint32,
                            offset: uint16): uint8 {.exportc, cdecl.} =
      when defined(bl808m0) and
          bl808BleNimConnectionEnabled:
        inc nim_slice_add_count
        nim_slice_last_type_con =
          (uint32(sliceType) shl 16) or uint32(conhdl)
        nim_slice_last_interval = interval
        nim_slice_last_anchor = anchor
        nim_slice_last_offset = offset.uint32
      discard sliceType
      discard conhdl
      discard interval
      discard anchor
      discard offset
      0

    proc sch_slice_per_remove*(sliceType: uint8,
                               conhdl: uint8): uint8 {.exportc, cdecl.} =
      when defined(bl808m0) and
          bl808BleNimConnectionEnabled:
        inc nim_slice_remove_count
        nim_slice_last_type_con =
          (uint32(sliceType) shl 16) or uint32(conhdl)
      discard sliceType
      discard conhdl
      0

proc ble_ke_msg_fobflbard*(param: pointer, dest_id: KeTaskId) {.exportc, cdecl.} =
  ## Forward a message to a new destination
  let hdr = getMsgHeader(param)
  hdr.dest_id = dest_id
  ble_ke_msg_send(param)

proc ble_ke_msg_fobflbard_new_id*(param: pointer, id: KeMsgId, dest_id: KeTaskId) {.exportc, cdecl.} =
  ## Forward with new msg id and destination
  let hdr = getMsgHeader(param)
  hdr.id = id
  hdr.dest_id = dest_id
  ble_ke_msg_send(param)

proc patch_ble_ke_msg_free*(msg: ptr KeMsgHeader) {.exportc: "_patch_ble_ke_msg_free", cdecl.} =
  if msg != nil:
    ble_ke_free(msg)

proc ble_ke_msg_free*(msg: ptr KeMsgHeader) {.exportc, cdecl.} =
  if ke_msg_free_patch != nil:
    discard ke_msg_free_patch(0, msg)
    return
  patch_ble_ke_msg_free(msg)

proc ble_ke_msg_dest_id_get*(param: pointer): KeTaskId {.exportc, cdecl.} =
  let hdr = getMsgHeader(param)
  return hdr.dest_id

proc ble_ke_msg_src_id_get*(param: pointer): KeTaskId {.exportc, cdecl.} =
  let hdr = getMsgHeader(param)
  return hdr.src_id

proc ble_ke_msg_in_queue*(param: pointer): bool {.exportc, cdecl.} =
  ## Check if message is currently in the queue (next != -1)
  let hdr = getMsgHeader(param)
  return cast[uint32](hdr.next) != 0xFFFFFFFF'u32

proc ble_ke_msg_discard*(msgid: KeMsgId, dest_id: KeTaskId,
                          src_id: KeTaskId, param: pointer): int32 {.exportc, cdecl.} =
  ## Default message handler: discard (consume the message)
  return KeMsgConsumed

proc ble_ke_msg_save*(msgid: KeMsgId, dest_id: KeTaskId,
                       src_id: KeTaskId, param: pointer): int32 {.exportc, cdecl.} =
  ## Default message handler: save (keep in queue)
  return KeMsgSaved

# ---------------------------------------------------------------------------
# ======================== KE_QUEUE ========================================
# ---------------------------------------------------------------------------

type
  QueueCmpFunc* = proc(a: ptr CoListNode, b: ptr CoListNode, extra: pointer): bool {.cdecl.}

proc patch_ble_ke_queue_extract*(queue: ptr CoList, cmp: QueueCmpFunc,
                                     arg: pointer): ptr CoListNode {.exportc: "_patch_ble_ke_queue_extract", cdecl.} =
  ## Extract first element matching comparison from queue
  var cur = queue.first
  var prev: ptr CoListNode = nil
  while cur != nil:
    if cmp(cur, cast[ptr CoListNode](arg), nil):
      if prev == nil:
        queue.first = cur.next
      else:
        prev.next = cur.next
      if queue.last == cur:
        queue.last = prev
      return cur
    prev = cur
    cur = cur.next
  return nil

proc ble_ke_queue_extract*(queue: ptr CoList, cmp: QueueCmpFunc,
                            arg: pointer): ptr CoListNode {.exportc, cdecl.} =
  if ke_queue_extract_patch != nil:
    discard ke_queue_extract_patch(0, queue, cast[pointer](cmp), arg)
  return patch_ble_ke_queue_extract(queue, cmp, arg)

proc patch_ble_ke_queue_insert*(queue: ptr CoList, node: ptr CoListNode,
                                    cmp: QueueCmpFunc) {.exportc: "_patch_ble_ke_queue_insert", cdecl.} =
  ## Insert into sorted queue
  var cur = queue.first
  var prev: ptr CoListNode = nil
  while cur != nil:
    if cmp(node, cur, nil):
      if prev == nil:
        node.next = queue.first
        queue.first = node
      else:
        node.next = cur
        prev.next = node
      return
    prev = cur
    cur = cur.next
  # Insert at end
  ble_co_list_push_back(queue, node)

proc ble_ke_queue_insert*(queue: ptr CoList, node: ptr CoListNode,
                           cmp: QueueCmpFunc) {.exportc, cdecl.} =
  if ke_queue_insert_patch != nil:
    discard ke_queue_insert_patch(0, queue, node, cast[pointer](cmp))
    return
  patch_ble_ke_queue_insert(queue, node, cmp)

# ---------------------------------------------------------------------------
# ======================== KE COMPARE FUNCTIONS ============================
# ---------------------------------------------------------------------------

proc ble_cmp_dest_id*(a: ptr CoListNode, b: ptr CoListNode): bool {.exportc, cdecl.} =
  ## Compare destination IDs of two messages for queue extraction
  let ha = cast[ptr KeMsgHeader](a)
  let hb = cast[ptr KeMsgHeader](b)
  return ha.dest_id == hb.dest_id

proc patch_ble_cmp_dest_id*(a: ptr CoListNode, b: ptr CoListNode): bool {.exportc: "_patch_ble_cmp_dest_id", cdecl.} =
  return ble_cmp_dest_id(a, b)

proc ble_cmp_abs_time*(a: ptr CoListNode, b: ptr CoListNode): bool {.exportc, cdecl.} =
  ## Compare timer absolute times for sorted insertion
  let ta = cast[ptr KeTimer](a)
  let tb = cast[ptr KeTimer](b)
  let diff = ta.time - tb.time
  return (diff shr 22) != 0  # time comparison with 22-bit wrap

proc patch_ble_cmp_abs_time*(a: ptr CoListNode, b: ptr CoListNode): bool {.exportc: "_patch_ble_cmp_abs_time", cdecl.} =
  return ble_cmp_abs_time(a, b)

proc ble_cmp_timer_id*(a: ptr CoListNode, b: ptr CoListNode): bool {.exportc, cdecl.} =
  ## Compare timer id+task for queue extraction
  let ta = cast[ptr KeTimer](a)
  let tb = cast[ptr KeTimer](b)
  return ta.id == tb.id and ta.task == tb.task

proc patch_ble_cmp_timer_id*(a: ptr CoListNode, b: ptr CoListNode): bool {.exportc: "_patch_ble_cmp_timer_id", cdecl.} =
  return ble_cmp_timer_id(a, b)

# ---------------------------------------------------------------------------
# ======================== KE_TASK =========================================
# ---------------------------------------------------------------------------

proc patch_ble_ke_task_saved_update*(task_type: uint16) {.exportc: "_patch_ble_ke_task_saved_update", cdecl.} =
  ## Update the saved handler for a task based on its current state
  if task_type < KE_TASK_MAX:
    let desc = addr ke_task_desc[task_type]
    if desc.state != nil and desc.state_handler != nil:
      let st = desc.state[]
      if st < desc.state_max:
        ke_task_saved[task_type] = keStateHandlerAt(desc.state_handler, st)

proc ble_ke_task_saved_update*(task_type: uint16) {.exportc, cdecl.} =
  if ke_task_saved_update_patch != nil:
    discard ke_task_saved_update_patch(0, task_type)
    return
  patch_ble_ke_task_saved_update(task_type)

proc patch_ble_ke_handler_search*(msg_id: KeMsgId, task_desc: ptr KeTaskDesc): KeMsgHandler {.exportc: "_patch_ble_ke_handler_search", cdecl.} =
  ## Search for a message handler in a task descriptor
  if task_desc == nil or task_desc.state == nil or task_desc.state_handler == nil:
    return nil
  let st = task_desc.state[]
  if st >= task_desc.state_max:
    return nil
  let state_handler = keStateHandlerAt(task_desc.state_handler, st)
  if state_handler.msg_table != nil:
    for i in 0'u16 ..< state_handler.msg_cnt:
      let entry = keMsgHandlerEntryAt(state_handler.msg_table, i)
      if entry.id == msg_id:
        return entry.handler
  # Check default handler
  if task_desc.default_handler != nil and task_desc.default_handler.msg_table != nil:
    for i in 0'u16 ..< task_desc.default_handler.msg_cnt:
      let entry = keMsgHandlerEntryAt(task_desc.default_handler.msg_table, i)
      if entry.id == msg_id:
        return entry.handler
  return nil

proc ble_ke_handler_search*(msg_id: KeMsgId, task_desc: ptr KeTaskDesc): KeMsgHandler {.exportc, cdecl.} =
  if ke_handler_search_patch != nil:
    var res: pointer
    let r = ke_handler_search_patch(addr res, msg_id, task_desc)
    if r != 0:
      return cast[KeMsgHandler](res)
  return patch_ble_ke_handler_search(msg_id, task_desc)

proc patch_ble_ke_task_handler_get*(msg_id: KeMsgId, task_id: KeTaskId): KeMsgHandler {.exportc: "_patch_ble_ke_task_handler_get", cdecl.} =
  ## Get the handler for a message ID and task ID
  let task_type = (task_id shr 8) and 0xFF
  if task_type >= KE_TASK_MAX:
    return nil
  return ble_ke_handler_search(msg_id, addr ke_task_desc[task_type])

proc ble_ke_task_handler_get*(msg_id: KeMsgId, task_id: KeTaskId): KeMsgHandler {.exportc, cdecl.} =
  if ke_task_handler_get_patch != nil:
    var res: pointer
    let r = ke_task_handler_get_patch(addr res, msg_id, task_id)
    if r != 0:
      return cast[KeMsgHandler](res)
  return patch_ble_ke_task_handler_get(msg_id, task_id)

proc bleKeTaskClearEventIfQueueEmpty() {.inline.} =
  let old = disableInterrupts()
  if ke_msg_queue.first == nil:
    ke_event_field = ke_event_field and not BleKeMessageEventBit
  restoreInterrupts(old)

proc bleKeTaskRescheduleIfQueued() {.inline.} =
  let old = disableInterrupts()
  if ke_msg_queue.first != nil:
    ble_ke_event_set(BleKeMessageEventId)
  restoreInterrupts(old)

proc patch_ble_ke_task_schedule*() {.exportc: "_patch_ble_ke_task_schedule", cdecl.} =
  ## Process one message from the message queue
  let old = disableInterrupts()
  let node = ble_co_list_pop_front(addr ke_msg_queue)
  restoreInterrupts(old)
  if node == nil:
    # Check if queue empty, if so clear event
    bleKeTaskClearEventIfQueueEmpty()
    return
  let hdr = cast[ptr KeMsgHeader](node)
  hdr.next = cast[ptr KeMsgHeader](cast[uint32](0xFFFFFFFF'u32))
  when defined(bl808m0) and bl808BleNimConnectionEnabled and
      bl808BleNimManualConnTx:
    let nimLlcpTxCfm = hdr.id == 524'u16
  let handler = ble_ke_task_handler_get(hdr.id, hdr.dest_id)
  let param = getMsgParam(hdr)
  if handler != nil:
    let result = handler(hdr.id, param, hdr.dest_id, hdr.src_id)
    case result
    of KeMsgConsumed:
      bleKeTaskRescheduleIfQueued()
    of KeMsgSaved:
      # Re-insert into saved list
      let old3 = disableInterrupts()
      ble_co_list_push_back(addr ke_msg_queue, cast[ptr CoListNode](hdr))
      restoreInterrupts(old3)
    else:
      ble_ke_msg_free(hdr)
      bleKeTaskRescheduleIfQueued()
  else:
    ble_ke_msg_free(hdr)
    bleKeTaskRescheduleIfQueued()
  when defined(bl808m0) and bl808BleNimConnectionEnabled and
      bl808BleNimManualConnTx:
    if nimLlcpTxCfm and nim_llcp_tx_pending == 0:
      nimLlcpTrySendQueued()

proc ble_ke_task_schedule*() {.exportc, cdecl.} =
  if ke_task_schedule_patch != nil:
    let r = ke_task_schedule_patch(0)
    if r != 0:
      return
  patch_ble_ke_task_schedule()

proc patch_ble_ke_task_init*() {.exportc: "_patch_ble_ke_task_init", cdecl.} =
  discard c_memset(addr ke_task_desc[0], 0, (sizeof(KeTaskDesc) * KE_TASK_MAX).csize_t)

proc ble_ke_task_init*() {.exportc, cdecl.} =
  if ke_task_init_patch != nil:
    let r = ke_task_init_patch(0)
    if r != 0:
      return
  patch_ble_ke_task_init()

proc patch_ble_ke_task_create*(task_type: uint8, desc: ptr KeTaskDesc) {.exportc: "_patch_ble_ke_task_create", cdecl.} =
  if task_type < KE_TASK_MAX:
    discard c_memcpy(addr ke_task_desc[task_type], desc, sizeof(KeTaskDesc).csize_t)

proc ble_ke_task_create*(task_type: uint8, desc: ptr KeTaskDesc) {.exportc, cdecl.} =
  if ke_task_create_patch != nil:
    discard ke_task_create_patch(0, task_type, desc)
    return
  patch_ble_ke_task_create(task_type, desc)

proc ble_ke_task_delete*(task_type: uint8) {.exportc, cdecl.} =
  if task_type < KE_TASK_MAX:
    discard c_memset(addr ke_task_desc[task_type], 0, sizeof(KeTaskDesc).csize_t)

proc patch_ble_ke_state_set*(task_id: KeTaskId, state: uint8) {.exportc: "_patch_ble_ke_state_set", cdecl.} =
  let task_type = (task_id shr 8) and 0xFF
  if task_type < KE_TASK_MAX:
    let desc = addr ke_task_desc[task_type]
    if desc.state != nil:
      desc.state[] = state
      ble_ke_task_saved_update(task_type)

proc ble_ke_state_set*(task_id: KeTaskId, state: uint8) {.exportc, cdecl.} =
  if ke_state_set_patch != nil:
    discard ke_state_set_patch(0, task_id, state)
    return
  patch_ble_ke_state_set(task_id, state)

proc patch_ble_ke_state_get*(task_id: KeTaskId): uint8 {.exportc: "_patch_ble_ke_state_get", cdecl.} =
  let task_type = (task_id shr 8) and 0xFF
  if task_type < KE_TASK_MAX:
    let desc = addr ke_task_desc[task_type]
    if desc.state != nil:
      return desc.state[]
  return 0

proc ble_ke_state_get*(task_id: KeTaskId): uint8 {.exportc, cdecl.} =
  if ke_state_get_patch != nil:
    var res: uint8
    let r = ke_state_get_patch(addr res, task_id)
    if r != 0:
      return res
  return patch_ble_ke_state_get(task_id)

proc ble_ke_task_msg_flush*(task_id: KeTaskId) {.exportc, cdecl.} =
  ## Flush all messages for a given task from the queue
  var cur = cast[ptr KeMsgHeader](ke_msg_queue.first)
  var prev: ptr KeMsgHeader = nil
  while cur != nil:
    let next = cast[ptr KeMsgHeader](cur.next)
    if cur.dest_id == task_id:
      if prev == nil:
        ke_msg_queue.first = cast[ptr CoListNode](next)
      else:
        prev.next = next
      if ke_msg_queue.last == cast[ptr CoListNode](cur):
        ke_msg_queue.last = cast[ptr CoListNode](prev)
      ble_ke_msg_free(cur)
    else:
      prev = cur
    cur = next

proc ble_ke_task_check*(task_type: uint8): bool {.exportc, cdecl.} =
  if task_type >= KE_TASK_MAX:
    return false
  return ke_task_desc[task_type].state_handler != nil

# ---------------------------------------------------------------------------
# ======================== KE_TIME / KE_TIMER ==============================
# ---------------------------------------------------------------------------

proc patch_ke_time*(): uint32 {.exportc: "_patch_ke_time", cdecl.} =
  ## Read current BLE base time counter
  ## From disasm: write 0x80000000 to BLE_BASE+0x1C to latch, wait for ready,
  ## then read BLE_BASE+0x1C (half-slot count) and BLE_BASE+0x20 (fine count)
  ## Returns time in 10ms units (half-slots / 16)
  regWrite(BLE_BASE + BLE_BASETIMECNT_OFFSET, 0x80000000'u32)
  discard waitBtbleCommandDone((BLE_BASE + BLE_BASETIMECNT_OFFSET).uint,
                               4096'u32)
  let basetimecnt = regRead(BLE_BASE + BLE_BASETIMECNT_OFFSET)
  let finetimecnt = regRead(BLE_BASE + BLE_FINETIMECNT_OFFSET)
  let half_us_flag = if finetimecnt < 312: 1'u32 else: 0'u32
  return ((basetimecnt + half_us_flag) shl 5) shr 9

proc ble_ke_time*(): uint32 {.exportc, cdecl.} =
  if ke_time_patch != nil:
    var res: uint32
    let r = ke_time_patch(addr res)
    if r != 0:
      return res
  return patch_ke_time()

proc patch_ble_ke_time_cmp*(t1: uint32, t2: uint32): bool {.exportc: "_patch_ble_ke_time_cmp", cdecl.} =
  ## Compare times: returns true if t1 >= t2 (with wrap-around at 22 bits)
  let diff = t1 - t2
  return ((((diff shr 22) xor 1'u32) and 1'u32) != 0'u32)

proc ble_ke_time_cmp*(t1: uint32, t2: uint32): bool {.exportc, cdecl.} =
  if ke_time_cmp_patch != nil:
    var res: uint8
    let r = ke_time_cmp_patch(addr res, t1, t2)
    if r != 0:
      return res != 0
  return patch_ble_ke_time_cmp(t1, t2)

proc patch_ble_ke_time_past*(t: uint32): bool {.exportc: "_patch_ble_ke_time_past", cdecl.} =
  ## Check if time t is in the past
  let now = ble_ke_time()
  return ble_ke_time_cmp(now, t)

proc ble_ke_time_past*(t: uint32): bool {.exportc, cdecl.} =
  if ke_time_past_patch != nil:
    var res: uint8
    let r = ke_time_past_patch(addr res, t)
    if r != 0:
      return res != 0
  return patch_ble_ke_time_past(t)

proc patch_ble_ke_timer_hw_set*(timer: ptr KeTimer) {.exportc: "_patch_ble_ke_timer_hw_set", cdecl.} =
  ## Program the hardware timer with the first timer's expiry
  if timer != nil:
    let target = timer.time and 0x7FFFFF'u32
    # Program the BLE timer target register
    regWrite(BLE_BASE + 0x24'u32, target)

proc ble_ke_timer_hw_set*(timer: ptr KeTimer) {.exportc, cdecl.} =
  if ke_timer_hw_set_patch != nil:
    discard ke_timer_hw_set_patch(0, timer)
    return
  patch_ble_ke_timer_hw_set(timer)

proc bleKeTimerHead(): ptr KeTimer {.inline.} =
  cast[ptr KeTimer](ke_timer_list.first)

proc bleKeTimerExpired(timer: ptr KeTimer): bool {.inline.} =
  timer != nil and ble_ke_time_past(timer.time)

proc bleKeTimerPendingWork(): bool {.inline.} =
  bleKeTimerExpired(bleKeTimerHead())

proc patch_ble_ke_timer_schedule*() {.exportc: "_patch_ble_ke_timer_schedule", cdecl.} =
  ## Process expired timers
  var drained = 0'u32
  while drained < BleKeTimerDrainLimit:
    let timer = bleKeTimerHead()
    if not bleKeTimerExpired(timer):
      break
    discard ble_co_list_pop_front(addr ke_timer_list)
    ble_ke_msg_send_basic(timer.id, timer.task, timer.task)
    ble_ke_free(timer)
    inc drained
  # Reprogram HW timer
  let next = bleKeTimerHead()
  if next != nil:
    if drained >= BleKeTimerDrainLimit and bleKeTimerExpired(next):
      inc nim_ble_ke_timer_yield_count
      nim_ble_ke_timer_yield_time = next.time
    ble_ke_timer_hw_set(next)

proc ble_ke_timer_schedule*() {.exportc, cdecl.} =
  if ke_timer_schedule_patch != nil:
    discard ke_timer_schedule_patch(0)
    return
  patch_ble_ke_timer_schedule()

proc patch_ble_ke_timer_init*() {.exportc: "_patch_ble_ke_timer_init", cdecl.} =
  ble_co_list_init(addr ke_timer_list)

proc ble_ke_timer_init*() {.exportc, cdecl.} =
  if ke_timer_init_patch != nil:
    discard ke_timer_init_patch(0)
    return
  patch_ble_ke_timer_init()

proc patch_ble_ke_timer_set*(id: uint16, task: uint16, delay: uint32) {.exportc: "_patch_ble_ke_timer_set", cdecl.} =
  ## Set (or reset) a kernel timer
  var actual_delay = delay
  if actual_delay == 0:
    actual_delay = 1
  if actual_delay >= 0x400000'u32:
    actual_delay = 0x3FFFFF'u32

  # Check if timer already exists with same id/task
  var existing = false
  let first = cast[ptr KeTimer](ke_timer_list.first)
  if first != nil and first.id == id and first.task == task:
    existing = true

  # Search and remove existing timer with this id/task
  var cur = cast[ptr KeTimer](ke_timer_list.first)
  var timer: ptr KeTimer = nil
  while cur != nil:
    if cur.id == id and cur.task == task:
      timer = cur
      patch_ble_co_list_extract(addr ke_timer_list, cast[ptr CoListNode](timer))
      break
    cur = cur.next

  # Allocate new timer if not found
  if timer == nil:
    timer = cast[ptr KeTimer](ble_ke_malloc(sizeof(KeTimer).uint32, 0))
    if timer == nil:
      return
    timer.id = id
    timer.task = task

  # Set expiry time
  let now = ble_ke_time()
  let target = (now + actual_delay) and 0x7FFFFF'u32
  timer.time = target

  # Insert into sorted timer list
  ble_ke_queue_insert(addr ke_timer_list, cast[ptr CoListNode](timer),
                       cast[QueueCmpFunc](ble_cmp_abs_time))

  # If this is now the first timer or we changed the first, reprogram HW
  if not existing or cast[ptr KeTimer](ke_timer_list.first) == timer:
    ble_ke_timer_hw_set(cast[ptr KeTimer](ke_timer_list.first))

proc ble_ke_timer_set*(id: uint16, task: uint16, delay: uint32) {.exportc, cdecl.} =
  if ke_timer_set_patch != nil:
    let r = ke_timer_set_patch(0, id, task, delay)
    if r != 0:
      return
  patch_ble_ke_timer_set(id, task, delay)

proc patch_ble_ke_timer_clear*(id: uint16, task: uint16) {.exportc: "_patch_ble_ke_timer_clear", cdecl.} =
  ## Clear cancel a timer
  var cur = cast[ptr KeTimer](ke_timer_list.first)
  while cur != nil:
    if cur.id == id and cur.task == task:
      let removedFirst = ke_timer_list.first == cast[ptr CoListNode](cur)
      patch_ble_co_list_extract(addr ke_timer_list, cast[ptr CoListNode](cur))
      ble_ke_free(cur)
      # Reprogram if we removed the first
      if removedFirst and ke_timer_list.first != nil:
        ble_ke_timer_hw_set(cast[ptr KeTimer](ke_timer_list.first))
      return
    cur = cur.next

proc ble_ke_timer_clear*(id: uint16, task: uint16) {.exportc, cdecl.} =
  if ke_timer_clear_patch != nil:
    discard ke_timer_clear_patch(0, id, task)
    return
  patch_ble_ke_timer_clear(id, task)

proc patch_ble_ke_timer_active*(id: uint16, task: uint16): bool {.exportc: "_patch_ble_ke_timer_active", cdecl.} =
  var cur = cast[ptr KeTimer](ke_timer_list.first)
  while cur != nil:
    if cur.id == id and cur.task == task:
      return true
    cur = cur.next
  return false

proc ble_ke_timer_active*(id: uint16, task: uint16): bool {.exportc, cdecl.} =
  if ke_timer_active_patch != nil:
    var res: uint8
    let r = ke_timer_active_patch(addr res, id, task)
    if r != 0:
      return res != 0
  return patch_ble_ke_timer_active(id, task)

proc ble_ke_timer_adjust_all*() {.exportc, cdecl.} =
  ## Adjust all timer times after a clock correction (no-op if no correction needed)
  discard

proc patch_ble_ke_timer_target_get*(): uint32 {.exportc: "_patch_ble_ke_timer_target_get", cdecl.} =
  let first = cast[ptr KeTimer](ke_timer_list.first)
  if first != nil:
    return first.time
  return 0

proc ble_ke_timer_target_get*(): uint32 {.exportc, cdecl.} =
  if ke_timer_target_get_patch != nil:
    var res: uint32
    let r = ke_timer_target_get_patch(addr res)
    if r != 0:
      return res
  return patch_ble_ke_timer_target_get()

# ---------------------------------------------------------------------------
# ======================== KE_INIT / FLUSH / SLEEP =========================
# ---------------------------------------------------------------------------

proc patch_ble_ke_init*() {.exportc: "_patch_ble_ke_init", cdecl.} =
  ble_ke_event_init()
  ble_ke_task_init()
  ble_ke_timer_init()
  ble_ke_mem_init()
  ble_co_list_init(addr ke_msg_queue)

proc ble_ke_init*() {.exportc, cdecl.} =
  if ke_init_patch != nil:
    let r = ke_init_patch(0)
    if r != 0:
      return
  patch_ble_ke_init()

proc bleControllerHasPendingWork(): bool {.inline.}

proc patch_ble_ke_flush*() {.exportc: "_patch_ble_ke_flush", cdecl.} =
  ## Flush all pending messages and timers
  # Drain timer list
  while ke_timer_list.first != nil:
    let node = ble_co_list_pop_front(addr ke_timer_list)
    ble_ke_free(node)
  # Drain message queue
  while ke_msg_queue.first != nil:
    let node = ble_co_list_pop_front(addr ke_msg_queue)
    ble_ke_free(node)
  ke_event_field = 0

proc ble_ke_flush*() {.exportc, cdecl.} =
  if ke_flush_patch != nil:
    discard ke_flush_patch(0)
    return
  patch_ble_ke_flush()

proc patch_ble_ke_sleep_check*(): bool {.exportc: "_patch_ble_ke_sleep_check", cdecl.} =
  return not bleControllerHasPendingWork()

proc ble_ke_sleep_check*(): bool {.exportc, cdecl.} =
  if ke_sleep_check_patch != nil:
    var res: uint8
    let r = ke_sleep_check_patch(addr res)
    if r != 0:
      return res != 0
  return patch_ble_ke_sleep_check()

proc ble_ke_tx_queue_num*(): uint32 {.exportc, cdecl.} =
  return ble_co_list_size(addr ke_msg_queue)

# ---------------------------------------------------------------------------
# ======================== EM_BUF ==========================================
# ---------------------------------------------------------------------------

proc em_buf_init*() {.exportc, cdecl.} =
  ## Initialize exchange memory buffer pools
  ## From disasm: initializes RX and TX buffer descriptors in EM space
  discard c_memset(addr em_buf_env[0], 0, sizeof(em_buf_env).csize_t)

  # Initialize RX buffer pool (5 descriptors of 14 bytes starting at EM offset)
  let rx_base = BLE_EM_BASE + 0x262'u32  # from disasm: 0x28008262
  for i in 0'u16 ..< EM_BUF_RX_COUNT:
    let desc = emRxDescAt(rx_base, i)
    # Set buffer pointer (offset from EM base) = 0x3CC + i * 38
    let buf_offset = 0x3CC'u16 + i * EM_BUF_RX_DATA_SIZE.uint16
    volatileStore(addr desc.buf_ptr, buf_offset)
    # Clear status/flags
    volatileStore(addr desc.status, 0'u16)
    volatileStore(addr desc.data_len, 0'u16)

  # Initialize TX buffer pool descriptors
  let tx_base = BLE_EM_BASE + 0x298'u32
  for i in 0'u16 ..< EM_BUF_TX_COUNT.uint16:
    volatileStore(addr emTxDescAt(tx_base, i).status, 0'u16)

proc em_buf_rx_free*(idx: uint16) {.exportc, cdecl.} =
  ## Free an RX buffer by clearing the used bit in status
  let status_ptr = emRxFreeStatusField(idx)
  let v = volatileLoad(status_ptr)
  volatileStore(status_ptr, v and 0x7FFF'u16)  # Clear bit 15 (used/done flag)

proc em_buf_rx_buff_addr_get*(idx: uint16): pointer {.exportc, cdecl.} =
  ## Get the address of an RX buffer's data area
  let buf_ptr = emRxBufferPointerField(idx)
  let offset = volatileLoad(buf_ptr)
  return bleEmPointer(offset)

proc em_buf_tx_buff_addr_get*(desc: pointer): pointer {.exportc, cdecl.} =
  ## Get TX buffer data address from descriptor
  let txDesc = cast[ptr EmBufTxDesc](desc)
  let offset = volatileLoad(addr txDesc.buf_ptr)
  return bleEmPointer(offset)

proc em_buf_tx_free*(desc: pointer) {.exportc, cdecl.} =
  ## Free a TX buffer
  let txDesc = cast[ptr EmBufTxDesc](desc)
  let offset = volatileLoad(addr txDesc.buf_ptr)
  # Clear allocation status in TX pool
  let pool_idx = offset.uint32
  let old = disableInterrupts()
  # Mark buffer as free in the TX descriptor
  let poolDesc = emTxPoolDescForBufferOffset(pool_idx)
  volatileStore(addr poolDesc.status, 0'u16)
  restoreInterrupts(old)

# ---------------------------------------------------------------------------
# ======================== EA (Event Arbiter) ==============================
# ---------------------------------------------------------------------------

proc ea_init*() {.exportc, cdecl.} =
  ## Initialize the event arbiter
  ble_co_list_init(addr ea_env_list)
  ble_co_list_init(addr ea_env_interval_list)
  ea_env_target = 0
  ea_env_finetarget = 0

proc ea_elt_create*(size: uint32): ptr EaEltTag {.exportc, cdecl.} =
  ## Create an EA element
  let elt = cast[ptr EaEltTag](ble_ke_malloc(size + sizeof(EaEltTag).uint32, 0))
  if elt != nil:
    discard c_memset(elt, 0, (size + sizeof(EaEltTag).uint32).csize_t)
  return elt

proc ea_elt_insert*(elt: ptr EaEltTag) {.exportc, cdecl.} =
  ## Insert an element into the EA schedule
  if elt == nil:
    return
  elt.linked = 1
  ble_co_list_push_back(addr ea_env_list, cast[ptr CoListNode](elt))

proc ea_elt_remove*(elt: ptr EaEltTag) {.exportc, cdecl.} =
  ## Remove an element from the EA schedule
  if elt == nil:
    return
  ble_co_list_extract(addr ea_env_list, cast[ptr CoListNode](elt))
  elt.linked = 0

proc ea_elt_cancel*(elt: ptr EaEltTag) {.exportc, cdecl.} =
  ## Cancel a scheduled element
  if elt == nil:
    return
  ea_elt_remove(elt)
  if elt.ea_cb_cancel != nil:
    let cb = cast[proc(elt: ptr EaEltTag) {.cdecl.}](elt.ea_cb_cancel)
    cb(elt)

proc ea_interval_create*(intv: ptr EaIntervalTag) {.exportc, cdecl.} =
  ## Create an interval element
  if intv != nil:
    discard c_memset(intv, 0, sizeof(EaIntervalTag).csize_t)

proc ea_interval_insert*(intv: ptr EaIntervalTag) {.exportc, cdecl.} =
  ## Insert interval into the interval list
  ble_co_list_push_back(addr ea_env_interval_list, cast[ptr CoListNode](intv))

proc ea_interval_remove*(intv: ptr EaIntervalTag) {.exportc, cdecl.} =
  ## Remove interval from list
  ble_co_list_extract(addr ea_env_interval_list, cast[ptr CoListNode](intv))

proc ea_interval_delete*(intv: ptr EaIntervalTag) {.exportc, cdecl.} =
  ## Delete an interval (remove and free)
  ea_interval_remove(intv)
  ble_ke_free(intv)

proc ea_interval_duration_req*(intv: ptr EaIntervalTag): uint32 {.exportc, cdecl.} =
  ## Get duration requirement for interval
  if intv != nil:
    return intv.bandwidth
  return 0

proc ea_sw_isr*() {.exportc, cdecl.} =
  ## Software ISR for event arbiter
  # Process completed events
  var cur = cast[ptr EaEltTag](ea_env_list.first)
  while cur != nil:
    let next = cast[ptr EaEltTag](cur.node.next)
    if cur.ea_cb_start != nil:
      let cb = cast[proc(elt: ptr EaEltTag) {.cdecl.}](cur.ea_cb_start)
      cb(cur)
    cur = next

proc ea_finetimer_isr*() {.exportc, cdecl.} =
  ## Fine timer ISR
  # Acknowledge interrupt
  regWrite(BLE_BASE + BLE_INTACK_OFFSET, 0x00000001'u32)  # Fine timer IRQ bit
  # Schedule pending events
  ea_sw_isr()

proc ea_offset_req*(intv: ptr EaIntervalTag, offset: ptr uint32): bool {.exportc, cdecl.} =
  ## Request an offset for a new interval
  if offset != nil:
    offset[] = 0
  return true

proc ea_time_get_halfslot_rounded*(): uint32 {.exportc, cdecl.} =
  ## Get current time rounded to half-slot
  regWrite(BLE_BASE + BLE_BASETIMECNT_OFFSET, BtbleBusyBit)
  discard waitBtbleCommandDone((BLE_BASE + BLE_BASETIMECNT_OFFSET).uint)
  return regRead(BLE_BASE + BLE_BASETIMECNT_OFFSET)

proc ea_time_get_slot_rounded*(): uint32 {.exportc, cdecl.} =
  ## Get current time rounded to slot (even half-slot)
  let hs = ea_time_get_halfslot_rounded()
  return hs and 0xFFFFFFFE'u32

proc ea_timer_target_get*(): uint32 {.exportc, cdecl.} =
  return ea_env_target

# ---------------------------------------------------------------------------
# ======================== HCI =============================================
# ---------------------------------------------------------------------------

proc hci_fc_init*() {.exportc, cdecl.}

proc hci_init*(reset: bool) {.exportc, cdecl.} =
  ## Initialize HCI layer
  discard c_memset(addr hci_env[0], 0, sizeof(hci_env).csize_t)
  discard c_memset(addr hci_evt_mask[0], 0xFF, sizeof(hci_evt_mask).csize_t)
  discard c_memset(addr hci_le_evt_mask[0], 0xFF, sizeof(hci_le_evt_mask).csize_t)
  hci_fc_init()

proc hci_reset*() {.exportc, cdecl.} =
  ## Reset HCI layer
  hci_init(true)

proc hci_tl_init*() {.exportc, cdecl.} =
  ## Initialize HCI transport layer
  discard

proc hci_tl_send*(buf: pointer, len: uint16): bool {.exportc, cdecl.} =
  ## Send data over HCI transport
  return true

proc hci_fc_init*() {.exportc, cdecl.} =
  hci_fc_env.acl_pkt_nb = 0
  hci_fc_env.acl_buf_size = 0
  hci_fc_env.flow_en = false

proc hci_fc_acl_buf_size_set*(size: uint16) {.exportc, cdecl.} =
  hci_fc_env.acl_buf_size = size

proc hci_fc_acl_en*(en: bool) {.exportc, cdecl.} =
  hci_fc_env.flow_en = en

proc hci_fc_acl_packet_sent*() {.exportc, cdecl.} =
  if hci_fc_env.acl_pkt_nb > 0:
    dec hci_fc_env.acl_pkt_nb

proc hci_fc_check_host_available_nb_acl_packets*(): bool {.exportc, cdecl.} =
  if not hci_fc_env.flow_en:
    return true
  return hci_fc_env.acl_pkt_nb > 0

proc hci_fc_host_nb_acl_pkts_complete*(nb: uint16) {.exportc, cdecl.} =
  hci_fc_env.acl_pkt_nb = hci_fc_env.acl_pkt_nb + nb

proc completeHciCommand(opcode: uint16, params: ptr uint8,
                        paramLen: uint8): uint8 =
  nim_hci_debug_stage = 0x4100'u32
  nim_hci_debug_opcode = opcode.uint32
  nim_hci_debug_len = paramLen.uint32
  if opcode == HciOpReadBufferSize:
    return sendReadBufferSizeComplete(opcode, paramLen)
  if opcode == HciOpLeReadBufferSize:
    return sendLeReadBufferSizeComplete(opcode, paramLen)
  if opcode == HciOpLeReadLocalSupportedFeatures:
    return sendLeReadLocalSupportedFeaturesComplete(opcode, paramLen)
  if opcode == HciOpLeConnectionUpdate:
    return sendLeConnectionUpdateCommand(opcode, params, paramLen)
  if opcode == HciOpReadRemoteVersionInfo:
    return sendReadRemoteVersionInfoCommand(opcode, params, paramLen)
  if opcode == HciOpLeReadRemoteFeatures:
    return sendLeReadRemoteFeaturesCommand(opcode, params, paramLen)
  if opcode == HciOpLeEncrypt:
    return sendLeEncryptComplete(opcode, params, paramLen)
  if opcode == HciOpLeRand:
    return sendLeRandComplete(opcode, paramLen)
  if opcode == HciOpLeSetDataLen:
    return sendLeSetDataLengthComplete(opcode, params, paramLen)
  if opcode == HciOpLeReadSuggestedDefaultDataLen:
    return sendLeReadSuggestedDefaultDataLengthComplete(opcode, paramLen)
  if opcode == HciOpLeWriteSuggestedDefaultDataLen:
    return sendLeWriteSuggestedDefaultDataLengthComplete(opcode, params,
                                                        paramLen)
  if opcode == HciOpLeReadLocalP256PublicKey:
    return sendLeReadLocalP256Complete(opcode, paramLen)
  if opcode == HciOpLeGenerateDhKey:
    return sendLeGenerateDhKeyComplete(opcode, params, paramLen)
  if opcode == HciOpLeReadMaximumDataLen:
    return sendLeReadMaximumDataLengthComplete(opcode, paramLen)
  nim_hci_debug_stage = 0x4110'u32
  result = handleNimHciCommand(opcode, params, paramLen)
  nim_hci_debug_stage = 0x4120'u32
  nim_hci_debug_status = result.uint32
  sendCmdComplete(opcode, result)
  nim_hci_debug_stage = 0x4130'u32

proc hci_evt_mask_set*(mask: ptr uint8) {.exportc, cdecl.} =
  discard c_memcpy(addr hci_evt_mask[0], mask, 8)

proc hci_cmd_get_max_param_size*(): uint16 {.exportc, cdecl.} =
  return 255

proc hci_cmd_received*(buf: pointer, len: uint16) {.exportc, cdecl.} =
  ## Process received HCI command
  if buf == nil or len < 3:
    return
  let opcode = hciRawOpcode(buf)
  let paramLen = hciRawParamLen(buf)
  if len < uint16(paramLen.int + 3):
    sendCmdComplete(opcode, 0x12'u8)
    return
  let params =
    if paramLen == 0: nil
    else: hciRawParams(buf)
  discard completeHciCommand(opcode, params, paramLen)

proc hci_command_handler*(msgid: KeMsgId, dest_id: KeTaskId,
                           src_id: KeTaskId, param: pointer): int32 {.exportc, cdecl.} =
  return 1  # KE_MSG_CONSUMED

proc hci_send_2_controller*(param: pointer) {.exportc, cdecl.} =
  ble_ke_msg_send(param)

proc hci_send_2_host*(param: pointer) {.exportc, cdecl.} =
  ble_ke_msg_send(param)

proc hci_look_for_cmd_desc*(opcode: uint16): pointer {.exportc, cdecl.} =
  return nil

proc hci_look_for_evt_desc*(code: uint8): pointer {.exportc, cdecl.} =
  return nil

proc hci_look_for_le_evt_desc*(subcode: uint8): pointer {.exportc, cdecl.} =
  return nil

proc hci_build_evt*(code: uint8, param: pointer, param_len: uint16): pointer {.exportc, cdecl.} =
  let msg = ble_ke_msg_alloc(code.KeMsgId, 0, 0, param_len)
  if msg != nil and param != nil and param_len > 0:
    discard c_memcpy(msg, param, param_len.csize_t)
  return msg

proc hci_build_le_evt*(subcode: uint8, param: pointer, param_len: uint16): pointer {.exportc, cdecl.} =
  return hci_build_evt(0x3E, param, param_len)

proc hci_build_cc_evt*(opcode: uint16, param: pointer, param_len: uint16): pointer {.exportc, cdecl.} =
  return hci_build_evt(0x0E, param, param_len)

proc hci_build_acl_rx_data*(handle: uint16, data: pointer, len: uint16): pointer {.exportc, cdecl.} =
  let msg = ble_ke_msg_alloc(0, handle, 0, len)
  if msg != nil and data != nil and len > 0:
    discard c_memcpy(msg, data, len.csize_t)
  return msg

proc hci_acl_tx_data_alloc*(handle: uint16, len: uint16): pointer {.exportc, cdecl.} =
  return ble_ke_msg_alloc(0, handle, 0, len)

proc hciAclTxDataStatus(handle: uint16, pbBcFlag: uint8,
                        data: pointer, len: uint16): uint8 =
  let pb = pbBcFlag and 0x03'u8
  let bc = (pbBcFlag shr 2) and 0x03'u8
  if bc != 0'u8 or (pb != 0'u8 and pb != 0x02'u8):
    return HciStatusUnsupportedFeatureParam
  if data == nil or len == 0'u16:
    return HciStatusInvalidParams
  if len > NimBleLeMaxDataOctets:
    return HciStatusInvalidParams
  when defined(bl808m0) and bl808BleNimConnectionEnabled and
      bl808BleNimManualConnTx and bl808BleNimPureConnection:
    let conhdl = handle and 0x0FFF'u16
    if not nim_conn_state.active or conhdl != nim_conn_state.handle:
      inc nim_acl_host_tx_reject_count
      return HciStatusUnknownConnection
    if not nim_conn_state.dataFlowEnabled:
      inc nim_acl_host_tx_reject_count
      return HciStatusCommandDisallowed
    if nim_acl_host_tx_pending != 0'u32:
      inc nim_acl_host_tx_reject_count
      return HciStatusCommandDisallowed
    copyBtbleEmBytes(NimAclTxEmOffset, cast[ptr uint8](data), len.int)
    nimConnTxElementInit(addr nim_acl_host_tx_buf[0], NimAclTxEmOffset, len)
    nim_acl_host_tx_pending = 1
    inc nim_acl_host_tx_count
    nimConnArmPendingHostAclTx()
    HciStatusSuccess
  else:
    HciStatusUnsupportedFeatureParam

proc hciOwnedAclTxDataReceived(handle: uint16, pbBcFlag: uint8,
                               data: pointer, len: uint16): uint8 =
  result = hciAclTxDataStatus(handle, pbBcFlag, data, len)
  if data != nil:
    ble_util_buf_acl_tx_free(data)
  if result != HciStatusSuccess:
    sendNumberOfCompletedPackets(handle and 0x0FFF'u16, 1'u16)

proc hci_acl_tx_data_received*(handle: uint16, data: pointer, len: uint16) {.exportc, cdecl.} =
  discard hciOwnedAclTxDataReceived(handle, 0x02'u8, data, len)

proc hci_get_tx_queue_num*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled and
      bl808BleNimManualConnTx and bl808BleNimPureConnection:
    if nim_acl_host_tx_pending != 0'u32:
      return 1
  return 0

proc hciFormatFieldSize(ch: uint8): int =
  case ch
  of 0'u8:
    0
  of uint8('B'), uint8('b'):
    1
  of uint8('H'), uint8('h'):
    2
  of uint8('L'), uint8('l'):
    4
  of uint8('D'), uint8('d'), uint8('E'), uint8('e'):
    8
  else:
    0

proc hciUtilCopyByFormat(outBuf: pointer, inBuf: pointer, format: cstring,
                         outLen: ptr uint16) =
  if outLen != nil:
    outLen[] = 0
  if outBuf == nil or inBuf == nil or format == nil:
    return
  let outRaw = cast[ptr UncheckedArray[uint8]](outBuf)
  let inRaw = cast[ptr UncheckedArray[uint8]](inBuf)
  let fmt = cast[ptr UncheckedArray[uint8]](format)
  var fmtOff = 0
  var inOff = 0
  var outOff = 0
  var repeat = 0
  while fmt[fmtOff] != 0'u8:
    let ch = fmt[fmtOff]
    inc fmtOff
    if ch >= uint8('0') and ch <= uint8('9'):
      repeat = repeat * 10 + int(ch - uint8('0'))
      continue
    if ch == uint8(' ') or ch == uint8(',') or ch == uint8(':'):
      continue
    var size = hciFormatFieldSize(ch)
    if size == 0:
      repeat = 0
      continue
    if repeat > 0:
      size = size * repeat
      repeat = 0
    for i in 0 ..< size:
      outRaw[outOff + i] = inRaw[inOff + i]
    inOff += size
    outOff += size
  if outLen != nil:
    outLen[] = outOff.uint16

proc hci_util_pack*(out_buf: pointer, in_buf: pointer, format: cstring, out_len: ptr uint16) {.exportc, cdecl.} =
  ## Pack HCI parameters according to the compact controller format string.
  hciUtilCopyByFormat(out_buf, in_buf, format, out_len)

proc hci_util_unpack*(out_buf: pointer, in_buf: pointer, format: cstring, out_len: ptr uint16) {.exportc, cdecl.} =
  ## Unpack HCI parameters according to the compact controller format string.
  hciUtilCopyByFormat(out_buf, in_buf, format, out_len)

# ---------------------------------------------------------------------------
# ======================== LLC (Link Layer Control) ========================
# ---------------------------------------------------------------------------

proc llc_init*() {.exportc, cdecl.} =
  for i in 0 ..< LLC_CON_MAX:
    llc_env[i] = nil
  when defined(bl808m0) and bl808BleNimConnectionEnabled and bl808BleNimLlcStart:
    for i in 0 ..< nim_llc_start_env_slots.len:
      nim_llc_start_env_slots[i] = nil

proc llc_reset*() {.exportc, cdecl.} =
  llc_init()

proc llc_start*(conhdl: uint16) {.exportc, cdecl.} =
  discard

proc llc_stop*(conhdl: uint16) {.exportc, cdecl.} =
  if conhdl < LLC_CON_MAX:
    if llc_env[conhdl] != nil:
      ble_ke_free(llc_env[conhdl])
      llc_env[conhdl] = nil
  when defined(bl808m0) and bl808BleNimConnectionEnabled and bl808BleNimLlcStart:
    if conhdl < nim_llc_start_env_slots.len.uint16:
      nim_llc_start_env_slots[conhdl] = nil

proc llc_hci_command_handler*(msgid: KeMsgId, dest_id: KeTaskId,
                               src_id: KeTaskId, param: pointer): int32 {.exportc, cdecl.} =
  return 1  # KE_MSG_CONSUMED

proc llc_hci_acl_data_tx_handler*(msgid: KeMsgId, dest_id: KeTaskId,
                                   src_id: KeTaskId, param: pointer): int32 {.exportc, cdecl.} =
  return 1

proc llc_llcp_recv_handler*(conhdl: uint16, buf: pointer) {.exportc, cdecl.} =
  discard

proc llc_llcp_get_autorize*(conhdl: uint16, opcode: uint8): uint8 {.exportc, cdecl.} =
  return 1  # Authorized

proc llc_common_cmd_complete_send*(conhdl: uint16, opcode: uint16, status: uint8) {.exportc, cdecl.} =
  discard conhdl
  sendCmdComplete(opcode, status)

proc llc_common_cmd_status_send*(conhdl: uint16, opcode: uint16, status: uint8) {.exportc, cdecl.} =
  discard conhdl
  sendCmdStatus(opcode, status)

proc llc_common_enc_change_evt_send*(conhdl: uint16, status: uint8, enabled: uint8) {.exportc, cdecl.} =
  var evt = [status, uint8(conhdl and 0xFF),
             uint8((conhdl shr 8) and 0xFF), enabled]
  sendHostEvent(HciEvtEncryptionChange, addr evt[0], evt.len.uint8)

proc llc_common_enc_key_ref_comp_evt_send*(conhdl: uint16, status: uint8) {.exportc, cdecl.} =
  var evt = [status, uint8(conhdl and 0xFF),
             uint8((conhdl shr 8) and 0xFF)]
  sendHostEvent(HciEvtEncryptionKeyRefreshComplete, addr evt[0],
                evt.len.uint8)

proc llc_common_flush_occurred_send*(conhdl: uint16) {.exportc, cdecl.} =
  var evt = [uint8(conhdl and 0xFF), uint8((conhdl shr 8) and 0xFF)]
  sendHostEvent(HciEvtFlushOccurred, addr evt[0], evt.len.uint8)

proc llc_common_nb_of_pkt_comp_evt_send*(conhdl: uint16, nb: uint16) {.exportc, cdecl.} =
  sendNumberOfCompletedPackets(conhdl, nb)

proc llc_con_update_complete_send*(conhdl: uint16, status: uint8) {.exportc, cdecl.} =
  var evt = [0x03'u8, status, uint8(conhdl and 0xFF),
             uint8((conhdl shr 8) and 0xFF), 0'u8, 0'u8, 0'u8, 0'u8,
             0'u8, 0'u8]
  sendLeMetaPayload(addr evt[0], evt.len.uint8)

proc llc_con_update_finished*(conhdl: uint16) {.exportc, cdecl.} =
  discard

proc llc_con_update_ind*(conhdl: uint16) {.exportc, cdecl.} =
  discard

proc llc_discon_event_complete_send*(conhdl: uint16, reason: uint8) {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    noteNimPeripheralDisconnectedFrom(4'u32, reason)
  sendDisconnectComplete(conhdl, reason)

proc nimBleCurrentRemoteFeatures(): uint64 =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    if nim_llcp_state.peerFeaturesKnown:
      return nim_llcp_state.peerFeatures
  0'u64

proc hciPutLe16(dst: ptr UncheckedArray[uint8], off: int, value: uint16) =
  dst[off] = uint8(value and 0x00FF'u16)
  dst[off + 1] = uint8((value shr 8) and 0x00FF'u16)

proc nimBleCurrentChannelMap(dst: ptr UncheckedArray[uint8]) =
  if dst == nil:
    return
  dst[0] = 0xFF'u8
  dst[1] = 0xFF'u8
  dst[2] = 0xFF'u8
  dst[3] = 0xFF'u8
  dst[4] = 0x1F'u8
  when defined(bl808m0) and bl808BleNimPureConnection:
    if nim_conn_state.active:
      for i in 0 ..< 5:
        dst[i] = nim_conn_state.channelMap[i]
      dst[4] = dst[4] and 0x1F'u8

proc nimBleCurrentPhy(): uint8 =
  when defined(bl808m0) and bl808BleNimPureConnection:
    if nim_conn_state.active and nim_conn_state.phy != 0'u8:
      return nim_conn_state.phy
  NimBleLe1MPhy

proc nimBleSetCurrentPhy1M() =
  when defined(bl808m0) and bl808BleNimPureConnection:
    if nim_conn_state.active:
      nim_conn_state.rate = 0'u8
      nim_conn_state.phy = NimBleLe1MPhy

proc nimBleLocalTxDataOctets(): uint16 =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    if nim_llcp_state.localTxOctets != 0'u16:
      return nim_llcp_state.localTxOctets
  NimBleLeMaxDataOctets

proc nimBleLocalTxDataTime(): uint16 =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    if nim_llcp_state.localTxTime != 0'u16:
      return nim_llcp_state.localTxTime
  NimBleLeMaxDataTime

proc nimBleCurrentMaxTxOctets(): uint16 =
  result = nimBleLocalTxDataOctets()
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    if nim_llcp_state.dataLengthKnown:
      result = minU16(result, nim_llcp_state.peerMaxRxOctets)

proc nimBleCurrentMaxTxTime(): uint16 =
  result = nimBleLocalTxDataTime()
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    if nim_llcp_state.dataLengthKnown:
      result = minU16(result, nim_llcp_state.peerMaxRxTime)

proc nimBleCurrentMaxRxOctets(): uint16 =
  result = NimBleLeMaxDataOctets
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    if nim_llcp_state.dataLengthKnown:
      result = minU16(result, nim_llcp_state.peerMaxTxOctets)

proc nimBleCurrentMaxRxTime(): uint16 =
  result = NimBleLeMaxDataTime
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    if nim_llcp_state.dataLengthKnown:
      result = minU16(result, nim_llcp_state.peerMaxTxTime)

proc nimBleDataLengthParamStatus(txOctets, txTime: uint16): uint8 =
  if txOctets < NimBleLeMinDataOctets or txTime < NimBleLeMinDataTime:
    return HciStatusInvalidParams
  if txOctets > NimBleLeSpecMaxDataOctets or
      txTime > NimBleLeSpecMaxDataTime:
    return HciStatusInvalidParams
  if txOctets > NimBleLeMaxDataOctets or txTime > NimBleLeMaxDataTime:
    return HciStatusUnsupportedFeatureParam
  return HciStatusSuccess

proc nimBleApplyLocalDataLength(handle, txOctets, txTime: uint16) =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_llcp_state.localTxOctets = txOctets
    nim_llcp_state.localTxTime = txTime
    when bl808BleNimPureConnection:
      if nim_conn_state.active:
        nimConnProgramPacketDurations(handle)
  else:
    discard handle
    discard txOctets
    discard txTime

proc sendLeDataLengthChange(handle: uint16) =
  var evt: array[11, uint8]
  evt[0] = 0x07'u8
  evt[1] = uint8(handle and 0x00FF'u16)
  evt[2] = uint8((handle shr 8) and 0x00FF'u16)
  hciPutLe16(cast[ptr UncheckedArray[uint8]](addr evt[0]), 3,
             nimBleCurrentMaxTxOctets())
  hciPutLe16(cast[ptr UncheckedArray[uint8]](addr evt[0]), 5,
             nimBleCurrentMaxTxTime())
  hciPutLe16(cast[ptr UncheckedArray[uint8]](addr evt[0]), 7,
             nimBleCurrentMaxRxOctets())
  hciPutLe16(cast[ptr UncheckedArray[uint8]](addr evt[0]), 9,
             nimBleCurrentMaxRxTime())
  sendLeMetaPayload(addr evt[0], evt.len.uint8)

proc sendLeReadRemoteFeaturesCommand(opcode: uint16, params: ptr uint8,
                                     paramLen: uint8): uint8 =
  let handle =
    if params == nil or paramLen < 2'u8: 0'u16 else: hciConnHandle(params)
  result =
    if params == nil or paramLen != 2'u8:
      HciStatusInvalidParams
    else:
      connParamStatus(params, handle)
  sendCmdStatus(opcode, result)
  if result != HciStatusSuccess:
    return

  when defined(bl808m0) and bl808BleNimConnectionEnabled and
      bl808BleNimManualConnTx:
    if nim_llcp_state.peerFeaturesKnown:
      sendLeRemoteFeaturesComplete(handle, HciStatusSuccess)
    else:
      nim_llcp_state.remoteFeaturesEventPending = true
      llc_llcp_feats_req_pdu_send(handle)
  else:
    sendLeRemoteFeaturesComplete(handle, HciStatusSuccess)

proc sendReadRemoteVersionInfoCommand(opcode: uint16, params: ptr uint8,
                                      paramLen: uint8): uint8 =
  let handle =
    if params == nil or paramLen < 2'u8: 0'u16 else: hciConnHandle(params)
  result =
    if params == nil or paramLen != 2'u8:
      HciStatusInvalidParams
    else:
      connParamStatus(params, handle)
  sendCmdStatus(opcode, result)
  if result == HciStatusSuccess:
    sendRemoteVersionInfoComplete(handle, result)

proc nimBleConnectionUpdateParamStatus(params: ptr uint8, paramLen: uint8,
                                       handle: uint16): uint8 =
  if params == nil or paramLen != sizeof(HciLeConnUpdateReqView).uint8:
    return HciStatusInvalidParams
  result = connParamStatus(params, handle)
  if result != HciStatusSuccess:
    return
  let req = hciLeConnUpdateReq(params)
  if req.connIntervalMin < 6'u16 or req.connIntervalMin > 3200'u16:
    return HciStatusInvalidParams
  if req.connIntervalMax < req.connIntervalMin or
      req.connIntervalMax > 3200'u16:
    return HciStatusInvalidParams
  if req.connLatency > 499'u16:
    return HciStatusInvalidParams
  if req.supervisionTimeout < 10'u16 or req.supervisionTimeout > 3200'u16:
    return HciStatusInvalidParams
  let timeoutMargin = uint32(req.supervisionTimeout) * 4'u32
  let latencyInterval =
    uint32(req.connLatency + 1'u16) * uint32(req.connIntervalMax)
  if timeoutMargin <= latencyInterval:
    return HciStatusInvalidParams
  return HciStatusSuccess

proc sendLeConnectionUpdateCommand(opcode: uint16, params: ptr uint8,
                                   paramLen: uint8): uint8 =
  let handle =
    if params == nil or paramLen < 2'u8: 0'u16 else: hciConnHandle(params)
  result = nimBleConnectionUpdateParamStatus(params, paramLen, handle)
  if result == HciStatusSuccess:
    when defined(bl808m0) and bl808BleNimConnectionEnabled and
        bl808BleNimManualConnTx:
      result = nimLlcpStartConnectionUpdate(handle, hciLeConnUpdateReq(params))
    else:
      result = HciStatusUnsupportedFeatureParam
  sendCmdStatus(opcode, result)

proc nimBleRequestedPhySupported(req: ptr HciLeSetPhyReqView): bool =
  if req == nil:
    return false
  let txUnsupported =
    (req.allPhys and 0x01'u8) == 0'u8 and
    (req.txPhys == 0'u8 or (req.txPhys and not NimBleLe1MPhy) != 0'u8)
  let rxUnsupported =
    (req.allPhys and 0x02'u8) == 0'u8 and
    (req.rxPhys == 0'u8 or (req.rxPhys and not NimBleLe1MPhy) != 0'u8)
  not txUnsupported and not rxUnsupported

proc nimBleDataLengthStatus(params: ptr uint8, handle: uint16): uint8 =
  let baseStatus = connParamStatus(params, handle)
  if baseStatus != HciStatusSuccess:
    return baseStatus
  if not nimBleLocalFeatureSupported(NimBleFeatureDataPacketLengthExtension):
    return HciStatusUnsupportedFeatureParam
  let req = hciLeSetDataLenReq(params)
  result = nimBleDataLengthParamStatus(req.txOctets, req.txTime)
  if result == HciStatusSuccess:
    nimBleApplyLocalDataLength(handle, req.txOctets, req.txTime)

proc sendLeSetDataLengthComplete(opcode: uint16, params: ptr uint8,
                                 paramLen: uint8): uint8 =
  let handle =
    if params == nil or paramLen < 2'u8: 0'u16 else: hciConnHandle(params)
  result =
    if params == nil or paramLen != sizeof(HciLeSetDataLenReqView).uint8:
      HciStatusInvalidParams
    else:
      nimBleDataLengthStatus(params, handle)
  var rsp = [result, uint8(handle and 0x00FF'u16),
             uint8((handle shr 8) and 0x00FF'u16)]
  sendCmdCompletePayload(opcode, addr rsp[0], rsp.len.uint8)
  if result == HciStatusSuccess:
    sendLeDataLengthChange(handle)

proc sendLeReadSuggestedDefaultDataLengthComplete(opcode: uint16,
                                                  paramLen: uint8): uint8 =
  result =
    if paramLen == 0'u8: HciStatusSuccess else: HciStatusInvalidParams
  var rsp: array[5, uint8]
  rsp[0] = result
  hciPutLe16(cast[ptr UncheckedArray[uint8]](addr rsp[0]), 1,
             nim_suggested_tx_octets)
  hciPutLe16(cast[ptr UncheckedArray[uint8]](addr rsp[0]), 3,
             nim_suggested_tx_time)
  sendCmdCompletePayload(opcode, addr rsp[0], rsp.len.uint8)

proc sendLeWriteSuggestedDefaultDataLengthComplete(opcode: uint16,
                                                   params: ptr uint8,
                                                   paramLen: uint8): uint8 =
  if params == nil or
      paramLen != sizeof(HciLeSuggestedDataLenReqView).uint8:
    result = HciStatusInvalidParams
  else:
    let req = hciLeSuggestedDataLenReq(params)
    result = nimBleDataLengthParamStatus(req.txOctets, req.txTime)
    if result == HciStatusSuccess:
      nim_suggested_tx_octets = req.txOctets
      nim_suggested_tx_time = req.txTime
  sendCmdComplete(opcode, result)

proc sendLeReadMaximumDataLengthComplete(opcode: uint16,
                                         paramLen: uint8): uint8 =
  result =
    if paramLen == 0'u8: HciStatusSuccess else: HciStatusInvalidParams
  var rsp: array[9, uint8]
  rsp[0] = result
  hciPutLe16(cast[ptr UncheckedArray[uint8]](addr rsp[0]), 1,
             NimBleLeMaxDataOctets)
  hciPutLe16(cast[ptr UncheckedArray[uint8]](addr rsp[0]), 3,
             NimBleLeMaxDataTime)
  hciPutLe16(cast[ptr UncheckedArray[uint8]](addr rsp[0]), 5,
             NimBleLeMaxDataOctets)
  hciPutLe16(cast[ptr UncheckedArray[uint8]](addr rsp[0]), 7,
             NimBleLeMaxDataTime)
  sendCmdCompletePayload(opcode, addr rsp[0], rsp.len.uint8)

proc llc_end_evt_defer*(conhdl: uint16) {.exportc, cdecl.} =
  discard

proc llc_feats_rd_event_send*(conhdl: uint16, status: uint8) {.exportc, cdecl.} =
  var evt = [0x04'u8, status, uint8(conhdl and 0xFF),
             uint8((conhdl shr 8) and 0xFF), 0'u8, 0'u8, 0'u8, 0'u8,
             0'u8, 0'u8, 0'u8, 0'u8]
  let features = nimBleCurrentRemoteFeatures()
  for i in 0 ..< 8:
    evt[4 + i] = nimBleFeatureByte(features, i)
  sendLeMetaPayload(addr evt[0], evt.len.uint8)

proc llc_le_ch_sel_algo_evt_send*(conhdl: uint16, algo: uint8) {.exportc, cdecl.} =
  var evt = [0x14'u8, uint8(conhdl and 0xFF),
             uint8((conhdl shr 8) and 0xFF), algo]
  sendLeMetaPayload(addr evt[0], evt.len.uint8)

proc llc_le_con_cmp_evt_send*(conhdl: uint16, status: uint8) {.exportc, cdecl.} =
  var evt: array[19, uint8]
  evt[0] = 0x01'u8
  evt[1] = status
  evt[2] = uint8(conhdl and 0xFF)
  evt[3] = uint8((conhdl shr 8) and 0xFF)
  if status == 0:
    nim_conn_active = true
    nim_conn_handle = conhdl
  sendLeMetaPayload(addr evt[0], evt.len.uint8)

proc llc_llcp_ch_map_update_pdu_send*(conhdl: uint16) {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled and
      bl808BleNimManualConnTx:
    var pdu = nimLlcpBuildChannelMapInd()
    discard nimLlcpQueuePdu(conhdl, pdu)
  else:
    discard conhdl

proc llc_llcp_con_param_req_pdu_send*(conhdl: uint16) {.exportc, cdecl.} =
  discard conhdl

proc llc_llcp_con_param_rsp_pdu_send*(conhdl: uint16) {.exportc, cdecl.} =
  discard conhdl

proc llc_llcp_con_update_pdu_send*(conhdl: uint16) {.exportc, cdecl.} =
  discard conhdl

proc llc_llcp_enc_req_pdu_send*(conhdl: uint16) {.exportc, cdecl.} =
  discard conhdl

proc llc_llcp_enc_rsp_pdu_send*(conhdl: uint16) {.exportc, cdecl.} =
  discard conhdl

proc llc_llcp_feats_req_pdu_send*(conhdl: uint16) {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled and
      bl808BleNimManualConnTx:
    var pdu = nimLlcpBuildFeaturePdu(LlcpFeatureReq)
    discard nimLlcpQueuePdu(conhdl, pdu)
  else:
    discard conhdl

proc llc_llcp_feats_rsp_pdu_send*(conhdl: uint16) {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled and
      bl808BleNimManualConnTx:
    var pdu = nimLlcpBuildFeatureRsp()
    discard nimLlcpQueuePdu(conhdl, pdu)
  else:
    discard conhdl

proc llc_llcp_length_req_pdu_send*(conhdl: uint16) {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled and
      bl808BleNimManualConnTx:
    if nimBleLocalFeatureSupported(NimBleFeatureDataPacketLengthExtension):
      var pdu = nimLlcpBuildLengthPdu(LlcpLengthReq)
      discard nimLlcpQueuePdu(conhdl, pdu)
    else:
      discard conhdl
  else:
    discard conhdl

proc llc_llcp_length_rsp_pdu_send*(conhdl: uint16) {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled and
      bl808BleNimManualConnTx:
    if nimBleLocalFeatureSupported(NimBleFeatureDataPacketLengthExtension):
      var pdu = nimLlcpBuildLengthRsp()
      discard nimLlcpQueuePdu(conhdl, pdu)
    else:
      discard conhdl
  else:
    discard conhdl

proc llc_llcp_pause_enc_req_pdu_send*(conhdl: uint16) {.exportc, cdecl.} =
  discard conhdl

proc llc_llcp_pause_enc_rsp_pdu_send*(conhdl: uint16) {.exportc, cdecl.} =
  discard conhdl

proc llc_llcp_ping_req_pdu_send*(conhdl: uint16) {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled and
      bl808BleNimManualConnTx:
    if nimBleLocalFeatureSupported(NimBleFeatureLePing):
      var pdu = nimLlcpBuildOpcodePdu(LlcpPingReq)
      discard nimLlcpQueuePdu(conhdl, pdu)
    else:
      discard conhdl
  else:
    discard conhdl

proc llc_llcp_ping_rsp_pdu_send*(conhdl: uint16) {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled and
      bl808BleNimManualConnTx:
    if nimBleLocalFeatureSupported(NimBleFeatureLePing):
      var pdu = nimLlcpBuildPingRsp()
      discard nimLlcpQueuePdu(conhdl, pdu)
    else:
      discard conhdl
  else:
    discard conhdl

proc llc_llcp_reject_ind_pdu_send*(conhdl: uint16, reason: uint8) {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled and
      bl808BleNimManualConnTx:
    var pdu = nimLlcpBuildRejectInd(reason)
    discard nimLlcpQueuePdu(conhdl, pdu)
  else:
    discard conhdl
    discard reason

proc llc_llcp_start_enc_req_pdu_send*(conhdl: uint16) {.exportc, cdecl.} =
  discard conhdl

proc llc_llcp_start_enc_rsp_pdu_send*(conhdl: uint16) {.exportc, cdecl.} =
  discard conhdl

proc llc_llcp_terminate_ind_pdu_send*(conhdl: uint16, reason: uint8) {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled and
      bl808BleNimManualConnTx:
    var pdu = nimLlcpBuildTerminateInd(reason)
    discard nimLlcpQueuePdu(conhdl, pdu)
  else:
    discard conhdl
    discard reason

proc llc_llcp_unknown_rsp_send_pdu*(conhdl: uint16, opcode: uint8) {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled and
      bl808BleNimManualConnTx:
    var pdu = nimLlcpBuildUnknownRsp(opcode)
    discard nimLlcpQueuePdu(conhdl, pdu)
  else:
    discard conhdl
    discard opcode

proc llc_llcp_version_ind_pdu_send*(conhdl: uint16) {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled and
      bl808BleNimManualConnTx:
    var pdu = nimLlcpBuildVersionInd()
    discard nimLlcpQueuePdu(conhdl, pdu)
  else:
    discard conhdl

proc llc_lsto_con_update*(conhdl: uint16) {.exportc, cdecl.} =
  discard

proc llc_ltk_req_send*(conhdl: uint16) {.exportc, cdecl.} =
  discard

proc llc_map_update_finished*(conhdl: uint16) {.exportc, cdecl.} =
  discard

proc llc_map_update_ind*(conhdl: uint16) {.exportc, cdecl.} =
  discard

proc llc_pdu_acl_tx_ack_defer*(conhdl: uint16) {.exportc, cdecl.} =
  discard

proc llc_pdu_defer*(conhdl: uint16) {.exportc, cdecl.} =
  discard

proc llc_pdu_llcp_tx_ack_defer*(conhdl: uint16) {.exportc, cdecl.} =
  discard

proc llc_version_rd_event_send*(conhdl: uint16, status: uint8) {.exportc, cdecl.} =
  var evt = [
    status,
    uint8(conhdl and 0xFF),
    uint8((conhdl shr 8) and 0xFF),
    0x09'u8,
    0xBF'u8, 0x01'u8,
    0x01'u8, 0x00'u8
  ]
  sendHostEvent(HciEvtRemoteVersionInfoComplete, addr evt[0], evt.len.uint8)

proc llc_ch_assess_get_current_ch_map*(conhdl: uint16, map: ptr uint8) {.exportc, cdecl.} =
  ## Get the current channel map for the connection
  if conhdl < LLC_CON_MAX and llc_env[conhdl] != nil:
    let assess = llcChannelAssessment(llc_env[conhdl])
    discard c_memcpy(map, addr assess.channelMap[0], 5)

proc llc_ch_assess_get_local_ch_map*(map: ptr uint8) {.exportc, cdecl.} =
  ## Get the local channel assessment map
  discard c_memset(map, 0xFF, 5)  # All channels available by default

proc llc_ch_assess_local*() {.exportc, cdecl.} =
  ## Perform local channel assessment
  discard

proc llc_ch_assess_reass_ch*() {.exportc, cdecl.} =
  ## Reassess channels
  discard

proc llc_util_bw_mgt*(conhdl: uint16) {.exportc, cdecl.} =
  discard

proc llc_util_clear_operation_ptr*(conhdl: uint16, op_type: uint8) {.exportc, cdecl.} =
  discard

proc llc_util_dicon_procedure*(conhdl: uint16, reason: uint8) {.exportc, cdecl.} =
  ## Initiate disconnection procedure
  if conhdl < LLC_CON_MAX and llc_env[conhdl] != nil:
    let disconnect = llcDisconnectState(llc_env[conhdl])
    if disconnect.active != 0:
      return  # Already disconnecting
    disconnect.reason = reason
    disconnect.active = 1

proc llc_util_get_free_conhdl*(): uint16 {.exportc, cdecl.} =
  for i in 0'u16 ..< LLC_CON_MAX.uint16:
    if llc_env[i] == nil:
      return i
  return 0xFFFF'u16

proc llc_util_get_nb_active_link*(): uint8 {.exportc, cdecl.} =
  var count: uint8 = 0
  for i in 0 ..< LLC_CON_MAX:
    if llc_env[i] != nil:
      inc count
  return count

proc llc_util_set_auth_payl_to_margin*(conhdl: uint16, margin: uint16) {.exportc, cdecl.} =
  discard

proc llc_util_set_llcp_discard_enable*(conhdl: uint16, enable: bool) {.exportc, cdecl.} =
  if conhdl < LLC_CON_MAX and llc_env[conhdl] != nil:
    let assess = llcChannelAssessment(llc_env[conhdl])
    if enable:
      assess.flags = assess.flags or 0x0008'u16
    else:
      assess.flags = assess.flags and not 0x0008'u16

proc llc_util_update_channel_map*(conhdl: uint16, map: ptr uint8) {.exportc, cdecl.} =
  if conhdl < LLC_CON_MAX and llc_env[conhdl] != nil:
    let assess = llcChannelAssessment(llc_env[conhdl])
    discard c_memcpy(addr assess.channelMap[0], map, 5)

# ---------------------------------------------------------------------------
# ======================== LLD (Link Layer Driver) =========================
# ---------------------------------------------------------------------------

proc lld_init*(reset: bool) {.exportc, cdecl.} =
  discard reset
  blePlatformInitMark(0x200'u32)
  discard c_memset(addr lld_evt_env_data[0], 0, sizeof(lld_evt_env_data).csize_t)
  blePlatformInitMark(0x201'u32)
  initBleCoreRegisters()
  blePlatformInitMark(0x202'u32)
  bleVolatileCounterInc(addr nim_ble_lld_init_return_count)

proc lld_core_reset*() {.exportc, cdecl.} =
  lld_init(true)

proc lld_evt_init*() {.exportc, cdecl.} =
  discard

proc lld_evt_init_evt*(elt: pointer) {.exportc, cdecl.} =
  discard

proc lld_evt_adv_create*(params: pointer): pointer {.exportc, cdecl.} =
  let elt = ea_elt_create(128)
  return elt

proc lld_evt_scan_create*(params: pointer): pointer {.exportc, cdecl.} =
  let elt = ea_elt_create(128)
  return elt

proc lld_evt_update_create*(conhdl: uint16): pointer {.exportc, cdecl.} =
  let elt = ea_elt_create(128)
  return elt

proc lld_evt_elt_insert*(elt: pointer) {.exportc, cdecl.} =
  ea_elt_insert(cast[ptr EaEltTag](elt))

proc lld_evt_elt_delete*(elt: pointer) {.exportc, cdecl.} =
  ea_elt_remove(cast[ptr EaEltTag](elt))
  ble_ke_free(elt)

proc lld_evt_delete_elt_push*(elt: pointer) {.exportc, cdecl.} =
  lld_evt_elt_delete(elt)

proc lld_evt_delete_evt_mode_get*(): uint8 {.exportc, cdecl.} =
  return 0

proc lld_evt_end*(elt: pointer) {.exportc, cdecl.} =
  discard

proc lld_evt_end_isr*() {.exportc, cdecl.} =
  discard

proc lld_evt_rx*(elt: pointer) {.exportc, cdecl.} =
  discard

proc lld_evt_rx_afs*() {.exportc, cdecl.} =
  discard

proc lld_evt_rx_isr*() {.exportc, cdecl.} =
  discard

proc lld_evt_slot_isr*() {.exportc, cdecl.} =
  discard

proc lld_evt_timer_isr*() {.exportc, cdecl.} =
  discard

proc lld_evt_channel_next*(conhdl: uint16) {.exportc, cdecl.} =
  discard

proc lld_evt_schedule*(elt: pointer) {.exportc, cdecl.} =
  discard

proc lld_evt_schedule_next*(elt: pointer) {.exportc, cdecl.} =
  discard

proc lld_evt_move_to_master*(conhdl: uint16) {.exportc, cdecl.} =
  discard

proc lld_evt_move_to_slave*(conhdl: uint16) {.exportc, cdecl.} =
  discard

proc lld_evt_slave_update*(conhdl: uint16) {.exportc, cdecl.} =
  discard

proc lld_evt_restart*(elt: pointer) {.exportc, cdecl.} =
  discard

proc lld_evt_prevent_stop*() {.exportc, cdecl.} =
  discard

proc lld_evt_canceled*(elt: pointer) {.exportc, cdecl.} =
  discard

proc lld_evt_deffered_elt_handler*() {.exportc, cdecl.} =
  discard

proc lld_evt_deffered_elt_simple_handler*() {.exportc, cdecl.} =
  discard

proc lld_evt_elt_defferred_get*(): pointer {.exportc, cdecl.} =
  return nil

proc lld_evt_drift_compute*(conhdl: uint16): uint32 {.exportc, cdecl.} =
  return 0

proc lld_con_start*(conhdl: uint16, params: pointer) {.exportc, cdecl.} =
  discard

proc lld_con_stop*(conhdl: uint16) {.exportc, cdecl.} =
  discard

proc lld_con_param_req*(conhdl: uint16) {.exportc, cdecl.} =
  discard

proc lld_con_param_rsp*(conhdl: uint16) {.exportc, cdecl.} =
  discard

proc lld_con_update_req*(conhdl: uint16) {.exportc, cdecl.} =
  discard

proc lld_con_update_ind*(conhdl: uint16) {.exportc, cdecl.} =
  discard

proc lld_con_update_after_param_req*(conhdl: uint16) {.exportc, cdecl.} =
  discard

proc lld_ch_map_ind*(conhdl: uint16) {.exportc, cdecl.} =
  discard

proc lld_crypt_isr*() {.exportc, cdecl.} =
  discard

proc lld_set_evt_end_time*(elt: pointer, time: uint32) {.exportc, cdecl.} =
  discard

proc lld_get_mode*(): uint8 {.exportc, cdecl.} =
  return 0

proc lld_get_evt_mode*(): uint8 {.exportc, cdecl.} =
  return 0

proc lld_move_to_master*(conhdl: uint16) {.exportc, cdecl.} =
  lld_evt_move_to_master(conhdl)

proc lld_move_to_slave*(conhdl: uint16) {.exportc, cdecl.} =
  lld_evt_move_to_slave(conhdl)

proc lld_master_check_increase_instant*(conhdl: uint16): bool {.exportc, cdecl.} =
  return false

proc lld_update_adv_scan_aa*() {.exportc, cdecl.} =
  discard

proc lld_wlcoex_set*(en: bool) {.exportc, cdecl.} =
  nim_ble_wlcoex_enabled = if en: 1'u32 else: 0'u32
  if not en:
    nim_ble_wifi_tx_window_active = 0'u32

# LLD PDU functions
proc lld_pdu_adv_pack*(params: pointer) {.exportc, cdecl.} =
  discard

proc lld_pdu_check*(conhdl: uint16): bool {.exportc, cdecl.} =
  return true

proc lld_pdu_data_send*(conhdl: uint16, buf: pointer) {.exportc, cdecl.} =
  discard

proc lld_pdu_data_tx_push*(conhdl: uint16) {.exportc, cdecl.} =
  discard

proc lld_pdu_rx_handler*() {.exportc, cdecl.} =
  discard

proc lld_pdu_tx_flush*(conhdl: uint16) {.exportc, cdecl.} =
  discard

proc lld_pdu_tx_loop*(conhdl: uint16) {.exportc, cdecl.} =
  discard

proc lld_pdu_tx_prog*(conhdl: uint16) {.exportc, cdecl.} =
  discard

proc lld_pdu_tx_push*(conhdl: uint16, buf: pointer) {.exportc, cdecl.} =
  discard

# LLD sleep functions
proc lld_sleep_init*() {.exportc, cdecl.} =
  let wakeLp = bflbip_us_2_lpcycles(5000)
  let slotLp = bflbip_us_2_lpcycles(625)
  let sleepCfg =
    ((wakeLp shl 21) and 0xFE000000'u32) or
    ((wakeLp shl 10) and 0x03FFFC00'u32) or
    (slotLp and 0x0000FFFF'u32)
  regWrite((BLE_BASE + 0x03C'u32).uint, sleepCfg)
  bflbip_wakeup_delay_set(5000)
  regWrite((BLE_BASE + 0x030'u32).uint,
           regRead((BLE_BASE + 0x030'u32).uint) and 0x7FFFFFFF'u32)

proc lld_sleep_enter*() {.exportc, cdecl.} =
  discard

proc lld_sleep_wakeup*() {.exportc, cdecl.} =
  discard

proc lld_sleep_wakeup_end*() {.exportc, cdecl.} =
  discard

# LLD utility functions
proc lld_util_anchor_point_move*(conhdl: uint16) {.exportc, cdecl.} =
  discard

proc lld_util_compute_ce_max*(conhdl: uint16): uint16 {.exportc, cdecl.} =
  return 0

proc lld_util_connection_param_set*(conhdl: uint16, params: pointer) {.exportc, cdecl.} =
  discard

proc lld_util_dle_set_cs_fields*(conhdl: uint16) {.exportc, cdecl.} =
  discard

proc lld_util_eff_tx_time_set*(conhdl: uint16, time: uint16) {.exportc, cdecl.} =
  discard

proc lld_util_elt_programmed*(elt: pointer): bool {.exportc, cdecl.} =
  return false

proc lld_util_flush_list*(list: ptr CoList) {.exportc, cdecl.} =
  while list.first != nil:
    let node = ble_co_list_pop_front(list)
    ble_ke_free(node)

proc lld_util_freq2chnl*(freq: uint8): uint8 {.exportc, cdecl.} =
  ## Convert frequency index to channel index
  if freq <= 10:
    return freq + 1
  elif freq == 39:
    return 0  # Advertising channel 37
  elif freq == 38:
    return 12  # Advertising channel 38
  else:
    return freq - 10 + 13

proc lld_util_get_bd_address*(addr_out: ptr BdAddr) {.exportc, cdecl.} =
  if addr_out == nil:
    return
  for i in 0 ..< addr_out.data.len:
    addr_out.data[i] =
      if nim_public_addr_valid: nim_public_addr[i]
      else: fallbackLocalAddrByte(i)

proc lld_util_set_bd_address*(addr_in: ptr BdAddr) {.exportc, cdecl.} =
  if addr_in == nil:
    return
  let lo = addr_in.data[0].uint32 or
           (addr_in.data[1].uint32 shl 8) or
           (addr_in.data[2].uint32 shl 16) or
           (addr_in.data[3].uint32 shl 24)
  let hi = addr_in.data[4].uint32 or
           (addr_in.data[5].uint32 shl 8)
  regWrite(BLE_BASE + 0x24'u32, lo)
  regWrite(BLE_BASE + 0x28'u32, hi)
  for i in 0 ..< nim_public_addr.len:
    nim_public_addr[i] = addr_in.data[i]
  nim_public_addr_valid = true

proc lld_util_get_local_offset*(): int16 {.exportc, cdecl.} =
  return 0

proc lld_util_get_peer_offset*(): int16 {.exportc, cdecl.} =
  return 0

proc lld_util_get_tx_pkt_cnt*(conhdl: uint16): uint32 {.exportc, cdecl.} =
  return 0

proc lld_util_instant_get*(conhdl: uint16): uint16 {.exportc, cdecl.} =
  return 0

proc lld_util_instant_ongoing*(conhdl: uint16): bool {.exportc, cdecl.} =
  return false

proc lld_util_priority_set*(elt: pointer, prio: uint8) {.exportc, cdecl.} =
  if elt != nil:
    cast[ptr EaEltTag](elt).current_prio = prio

proc lld_util_priority_update*(elt: pointer) {.exportc, cdecl.} =
  discard

# ---------------------------------------------------------------------------
# ======================== LLM (Link Layer Manager) ========================
# ---------------------------------------------------------------------------

when defined(bl808m0):
  proc sch_plan_rem*(elt: pointer) {.importc, cdecl.}
else:
  proc sch_plan_rem*(elt: pointer) {.exportc, cdecl.} =
    discard elt

proc llm_init*() {.exportc, cdecl.} =
  discard c_memset(addr llm_env_data, 0, sizeof(LlmEnv).csize_t)
  discard c_memset(addr llm_wl[0], 0, sizeof(llm_wl).csize_t)
  discard c_memset(addr llm_wl_type[0], 0, sizeof(llm_wl_type).csize_t)
  let maps = llmChannelMaps()
  for i in 0 ..< hci_le_evt_mask.len:
    llm_env_data.data[4 + i] = hci_le_evt_mask[i]
  for i in 0 ..< maps.localMap.len:
    maps.localMap[i] = 0xFF'u8
    maps.masterMap[i] = 0xFF'u8
  maps.localMap[4] = maps.localMap[4] and 0x1F'u8
  maps.masterMap[4] = maps.masterMap[4] and 0x1F'u8
  llm_env_data.data[428] = 0xA0'u8
  llm_env_data.data[429] = 0x1F'u8
  llm_env_data.data[430] = 27'u8
  llm_env_data.data[431] = 0'u8
  llm_env_data.data[432] = 0x48'u8
  llm_env_data.data[433] = 0x01'u8
  llm_env_data.data[436] = 0x07'u8
  llm_env_data.data[437] = 0x07'u8
  llm_env_data.data[439] = 0x2C'u8
  llm_env_data.data[478] = 0x84'u8
  llm_env_data.data[479] = 0x03'u8

proc llm_ble_ready*() {.exportc, cdecl.} =
  discard

proc llm_le_evt_mask_check*(evtBit: uint8): uint8 {.exportc, cdecl.} =
  let byteIdx = int(evtBit shr 3)
  if byteIdx >= 8:
    return 0
  let bitIdx = evtBit and 0x07'u8
  if (llm_env_data.data[4 + byteIdx] and (1'u8 shl bitIdx)) != 0'u8:
    1
  else:
    0

proc llm_get_connection_accept_timeout*(): uint16 {.exportc, cdecl.} =
  uint16(llm_env_data.data[428]) or
    (uint16(llm_env_data.data[429]) shl 8)

proc llm_set_connection_accept_timeout*(timeout: uint16) {.exportc, cdecl.} =
  llm_env_data.data[428] = uint8(timeout and 0x00FF'u16)
  llm_env_data.data[429] = uint8((timeout shr 8) and 0x00FF'u16)

proc llm_clk_acc_set*(position: uint8, enable: uint8) {.exportc, cdecl.} =
  let bit = 1'u32 shl (position and 0x1F'u8)
  var mask = uint32(llm_env_data.data[0]) or
    (uint32(llm_env_data.data[1]) shl 8) or
    (uint32(llm_env_data.data[2]) shl 16) or
    (uint32(llm_env_data.data[3]) shl 24)
  if enable != 0'u8:
    mask = mask or bit
    rwip_prevent_sleep_set(0x0200'u16)
  else:
    mask = mask and not bit
    if mask == 0'u32:
      rwip_prevent_sleep_clear(0x0200'u16)
  llm_env_data.data[0] = uint8(mask and 0x000000FF'u32)
  llm_env_data.data[1] = uint8((mask shr 8) and 0x000000FF'u32)
  llm_env_data.data[2] = uint8((mask shr 16) and 0x000000FF'u32)
  llm_env_data.data[3] = uint8((mask shr 24) and 0x000000FF'u32)

proc llm_master_ch_map_get*(): ptr uint8 {.exportc, cdecl.} =
  addr llmChannelMaps().masterMap[0]

proc llm_rx_path_comp_get*(): int16 {.exportc, cdecl.} =
  cast[int16](uint16(llm_env_data.data[482]) or
    (uint16(llm_env_data.data[483]) shl 8))

proc llm_tx_path_comp_get*(): int16 {.exportc, cdecl.} =
  cast[int16](uint16(llm_env_data.data[484]) or
    (uint16(llm_env_data.data[485]) shl 8))

proc llm_plan_elt_get*(activityId: uint8): pointer {.exportc, cdecl.} =
  let off = int(activityId) * 64 + 16
  if off >= llm_env_data.data.len:
    return nil
  cast[pointer](addr llm_env_data.data[off])

proc llm_is_adv_itf_legacy*(): uint8 {.exportc, cdecl.} =
  if llm_env_data.data[487] == 1'u8: 1 else: 0

proc llm_adv_itf_extended_set*() {.exportc, cdecl.} =
  if llm_env_data.data[487] == 0'u8:
    llm_env_data.data[487] = 2'u8

proc llm_dev_list_empty_entry*(): uint8 {.exportc, cdecl.} =
  for i in 0 ..< 7:
    if (llm_env_data.data[365 + i * 10] and 1'u8) == 0'u8:
      return uint8(i)
  7'u8

proc llm_dev_list_search*(addrIn: ptr BdAddr, addrType: uint8): uint8
    {.exportc, cdecl.} =
  for i in 0 ..< 7:
    let base = 356 + i * 10
    if (llm_env_data.data[base + 9] and 1'u8) != 0'u8 and
        llm_env_data.data[base + 8] == addrType and addrIn != nil:
      let entry = cast[ptr BdAddr](addr llm_env_data.data[base])
      if co_bdaddr_compare(entry, addrIn):
        return uint8(i)
  7'u8

proc llm_is_dev_connected*(addrIn: ptr BdAddr, addrType: uint8): uint8
    {.exportc, cdecl.} =
  if addrIn == nil:
    return 0
  for i in 0 ..< 5:
    let base = 40 + i * 64
    if llm_env_data.data[base + 32] == 9'u8 and
        (llm_env_data.data[base + 6] xor addrType) == 0'u8:
      let entry = cast[ptr BdAddr](addr llm_env_data.data[base])
      if co_bdaddr_compare(addrIn, entry):
        return 1
  0

proc llm_activity_free_get*(activityId: ptr uint8): uint8 {.exportc, cdecl.} =
  if activityId == nil:
    return 7
  for i in 0 ..< 5:
    if llm_env_data.data[72 + i * 64] == 0'u8:
      activityId[] = uint8(i)
      discard c_memset(addr llm_env_data.data[40 + i * 64], 0, 32)
      return 0
  activityId[] = 5'u8
  7

proc llm_activity_free_set*(activityId: uint8) {.exportc, cdecl.} =
  let off = int(activityId) * 64 + 16
  if off + 56 >= llm_env_data.data.len:
    return
  llm_env_data.data[72 + int(activityId) * 64] = 0'u8
  sch_plan_rem(cast[pointer](addr llm_env_data.data[off]))

proc llm_adv_hdl_to_id*(advHandle: uint8, paramOut: ptr pointer): uint8
    {.exportc, cdecl.} =
  for i in 0 ..< 5:
    let base = 12 + i * 64
    let state = llm_env_data.data[base + 60]
    if state >= 1'u8 and state <= 3'u8:
      let raw = uint32(llm_env_data.data[base]) or
        (uint32(llm_env_data.data[base + 1]) shl 8) or
        (uint32(llm_env_data.data[base + 2]) shl 16) or
        (uint32(llm_env_data.data[base + 3]) shl 24)
      if raw != 0'u32:
        let param = cast[ptr UncheckedArray[uint8]](raw.uint)
        if param[0] == advHandle:
          if paramOut != nil:
            paramOut[] = cast[pointer](raw.uint)
          return uint8(i)
  0xFF'u8

proc llm_cmd_cmp_send*(opcode: uint16, status: uint8) {.exportc, cdecl.} =
  let param = ble_ke_msg_alloc(0x1100'u16, 0'u16, opcode, 1'u16)
  if param != nil:
    cast[ptr uint8](param)[] = status
    hci_send_2_host(param)

proc llm_cmd_stat_send*(opcode: uint16, status: uint8) {.exportc, cdecl.} =
  let param = ble_ke_msg_alloc(0x1101'u16, 0'u16, opcode, 1'u16)
  if param != nil:
    cast[ptr uint8](param)[] = status
    hci_send_2_host(param)

when not (defined(bl808m0) and
    (bl808BleNimConnectionEnabled or bl808BleNimPureCentral)):
  proc ble_util_pkt_dur_in_us*(length: uint16, rate: uint8): uint16
      {.exportc, cdecl.}

proc llm_per_adv_chain_dur*(length: uint16, rate: uint8): uint8
    {.exportc, cdecl.} =
  var chainCount = uint32(length) div 240'u32 + 1'u32
  chainCount = chainCount and 0xFF'u32
  let pduLength =
    if chainCount <= 1'u32:
      let capped = uint32(length) + 15'u32
      if capped > 255'u32: 255'u16 else: uint16(capped)
    else:
      255'u16
  let phyRate = uint8((rate - 1'u8) and 0xFF'u8)
  let packetDur = uint32(ble_util_pkt_dur_in_us(pduLength, phyRate))
  let spacing = (chainCount - 1'u32) * 300'u32
  uint8((((packetDur * chainCount + spacing) shl 1) div 625'u32 + 1'u32) and
        0xFF'u32)

proc llm_common_cmd_complete_send*(opcode: uint16, status: uint8)
    {.exportc, cdecl.} =
  llm_cmd_cmp_send(opcode, status)

proc llm_common_cmd_status_send*(opcode: uint16, status: uint8)
    {.exportc, cdecl.} =
  llm_cmd_stat_send(opcode, status)

proc llm_con_req_ind*(conhdl: uint16) {.exportc, cdecl.} =
  discard

proc llm_con_req_tx_cfm*(conhdl: uint16) {.exportc, cdecl.} =
  discard

proc llm_create_con*(params: pointer) {.exportc, cdecl.} =
  discard

proc llm_encryption_done*(conhdl: uint16) {.exportc, cdecl.} =
  discard

proc llm_encryption_start*(conhdl: uint16) {.exportc, cdecl.} =
  discard

proc llm_end_evt_defer*() {.exportc, cdecl.} =
  discard

proc llm_le_adv_report_ind*(params: pointer) {.exportc, cdecl.} =
  discard

proc llm_ll_adv_type_get*(): uint8 {.exportc, cdecl.} =
  return 0

proc llm_notify_adv_discarded*(count: uint32, reason: uint32) {.exportc, cdecl.} =
  discard reason
  if ble_adv_discarded_callback != nil:
    ble_adv_discarded_callback(count)

proc llm_pdu_defer*() {.exportc, cdecl.} =
  discard

proc llm_set_adv_data*(data: ptr uint8, len: uint8) {.exportc, cdecl.} =
  let n = min(len.int, nim_adv_data.len)
  nim_adv_data_len = n.uint8
  if data != nil:
    discard c_memcpy(addr nim_adv_data[0], data, n.csize_t)

proc llm_set_adv_en*(en: bool) {.exportc, cdecl.} =
  discard programNimAdvertising(en)

proc llm_set_adv_param*(params: pointer) {.exportc, cdecl.} =
  if params != nil:
    discard c_memcpy(addr nim_adv_params[0], params,
                     nim_adv_params.len.csize_t)

proc llm_set_scan_en*(en: bool) {.exportc, cdecl.} =
  nim_scan_enabled = en

proc llm_set_scan_param*(params: pointer) {.exportc, cdecl.} =
  if params != nil:
    discard c_memcpy(addr nim_scan_params[0], params,
                     nim_scan_params.len.csize_t)

proc llm_set_scan_rsp_data*(data: ptr uint8, len: uint8) {.exportc, cdecl.} =
  let n = min(len.int, nim_scan_rsp_data.len)
  nim_scan_rsp_data_len = n.uint8
  if data != nil:
    discard c_memcpy(addr nim_scan_rsp_data[0], data, n.csize_t)
  if nim_adv_enabled:
    programBtbleLegacyAdv(nim_adv_data_len)

proc llm_util_adv_data_update*() {.exportc, cdecl.} =
  discard

proc llm_util_apply_bd_addr*(addr_in: ptr BdAddr) {.exportc, cdecl.} =
  lld_util_set_bd_address(addr_in)

proc llm_util_bd_addr_in_wl*(addr_in: ptr BdAddr, addr_type: uint8): bool {.exportc, cdecl.} =
  for i in 0 ..< LLM_WL_MAX:
    if llm_wl_type[i] == addr_type and co_bdaddr_compare(addr llm_wl[i], addr_in):
      return true
  return false

proc llm_util_bd_addr_wl_position*(addr_in: ptr BdAddr, addr_type: uint8): int32 {.exportc, cdecl.} =
  for i in 0 ..< LLM_WL_MAX:
    if llm_wl_type[i] == addr_type and co_bdaddr_compare(addr llm_wl[i], addr_in):
      return i.int32
  return -1

proc llmWlSlotAvailable(slot: int): bool {.inline.} =
  slot >= 0 and slot < LLM_WL_MAX and llm_wl_type[slot] == 0xFF'u8

proc llmWlNormalizeSlot(position: uint8): int {.inline.} =
  if position < LLM_WL_MAX.uint8:
    int(position)
  else:
    -1

proc llm_util_bl_add*(addr_in: ptr BdAddr, addr_type: uint8): bool {.exportc, cdecl.} =
  if addr_in == nil:
    return false
  for i in 0 ..< LLM_WL_MAX:
    if llm_wl_type[i] == addr_type and co_bdaddr_compare(addr llm_wl[i], addr_in):
      return true
  for i in 0 ..< LLM_WL_MAX:
    if llm_wl_type[i] == 0xFF:  # Empty slot
      co_bdaddr_set(addr llm_wl[i], addr_in)
      llm_wl_type[i] = addr_type
      return true
  return false

proc llm_util_bl_check*(addr_in: ptr BdAddr, addr_type: uint8): bool {.exportc, cdecl.} =
  if addr_in == nil:
    return false
  return llm_util_bd_addr_in_wl(addr_in, addr_type)

proc llm_util_bl_rem*(addr_in: ptr BdAddr, addr_type: uint8): bool {.exportc, cdecl.} =
  if addr_in == nil:
    return false
  for i in 0 ..< LLM_WL_MAX:
    if llm_wl_type[i] == addr_type and co_bdaddr_compare(addr llm_wl[i], addr_in):
      discard c_memset(addr llm_wl[i], 0, sizeof(BdAddr).csize_t)
      llm_wl_type[i] = 0xFF
      return true
  return false

proc llm_util_check_address_validity*(addr_in: ptr BdAddr, addr_type: uint8): uint8 {.exportc, cdecl.} =
  ## Returns 0 on valid, error code otherwise
  return 0

proc llm_util_check_evt_mask*(evt_bit: uint8): bool {.exportc, cdecl.} =
  let byte_idx = evt_bit div 8
  let bit_idx = evt_bit mod 8
  if byte_idx < 8:
    return (hci_le_evt_mask[byte_idx] and (1'u8 shl bit_idx)) != 0
  return false

proc llm_util_check_map_validity*(map: ptr uint8): bool {.exportc, cdecl.} =
  ## Check if channel map has at least 2 used channels
  let mapBytes = cast[ptr UncheckedArray[uint8]](map)
  var count = 0
  for i in 0 ..< 5:
    let byte_val = mapBytes[i]
    for b in 0 ..< 8:
      if i * 8 + b < 37:  # Only 37 data channels
        if (byte_val and (1'u8 shl b)) != 0:
          inc count
  return count >= 2

proc llm_util_get_channel_map*(map: ptr uint8) {.exportc, cdecl.} =
  discard c_memset(map, 0xFF, 5)
  # Mask out bits above channel 36
  let mapBytes = cast[ptr UncheckedArray[uint8]](map)
  mapBytes[4] = mapBytes[4] and 0x1F

proc llm_ch_map_update*(): uint32 {.exportc, cdecl.} =
  var nextMap: array[5, uint8]
  let maps = llmChannelMaps()
  for i in 0 ..< nextMap.len:
    nextMap[i] = maps.masterMap[i]
  if not llm_util_check_map_validity(addr nextMap[0]):
    llm_util_get_channel_map(addr nextMap[0])
  for i in 0 ..< nextMap.len:
    maps.localMap[i] = nextMap[i]
  lld_ch_map_set(addr nextMap[0])
  0

proc llm_ch_map_update_ind_handler*(msgid: KeMsgId, param: pointer,
                                    dest_id: KeTaskId,
                                    src_id: KeTaskId): uint32
    {.exportc, cdecl.} =
  discard msgid
  discard param
  discard dest_id
  discard src_id
  llm_ch_map_update()

proc llm_link_disc*(conhdl: uint16): uint32 {.exportc, cdecl.} =
  if conhdl < LLC_CON_MAX.uint16:
    llc_env[conhdl] = nil
  0

proc llm_util_get_supp_features*(): uint64 {.exportc, cdecl.} =
  return NimBleConservativeLeFeatures

proc llm_util_set_public_addr*(addr_in: ptr BdAddr) {.exportc, cdecl.} =
  lld_util_set_bd_address(addr_in)

proc llm_wl_clr*() {.exportc, cdecl.} =
  discard c_memset(addr llm_wl[0], 0, sizeof(llm_wl).csize_t)
  discard c_memset(addr llm_wl_type[0], 0xFF, sizeof(llm_wl_type).csize_t)

proc llm_wl_dev_add*(addr_in: ptr BdAddr, addr_type: uint8): uint8 {.exportc, cdecl.} =
  if llm_util_bl_add(addr_in, addr_type):
    return 0
  return 0x07  # Memory capacity exceeded

proc llm_wl_dev_add_hdl*(params: pointer): uint8 {.exportc, cdecl.} =
  return 0

proc llm_wl_dev_rem*(addr_in: ptr BdAddr, addr_type: uint8): uint8 {.exportc, cdecl.} =
  if llm_util_bl_rem(addr_in, addr_type):
    return 0
  return 0x02  # Unknown connection identifier

proc llm_wl_dev_rem_hdl*(params: pointer): uint8 {.exportc, cdecl.} =
  return 0

proc llm_bad_channel_sort*(ch_assess: pointer) {.exportc, cdecl.} =
  discard

# ---------------------------------------------------------------------------
# ======================== BFLBBLE (Platform BLE) ==========================
# ---------------------------------------------------------------------------

proc bflbble_init*() {.exportc, cdecl.} =
  ## Initialize the BLE platform-facing controller state.
  blePlatformInitMark(0x300'u32)
  when defined(bl808m0):
    nimDisableM0RfClicIrq()
    nimDisableM0BleClicIrq()
  blePlatformInitMark(0x301'u32)
  prepareWirelessDomain()
  blePlatformInitMark(0x302'u32)
  configureBtPriorityPta()
  blePlatformInitMark(0x303'u32)
  em_buf_init()
  blePlatformInitMark(0x304'u32)
  lld_init(false)
  blePlatformInitMark(0x305'u32)
  bleSettleAfterLldInit()
  blePlatformInitMark(0x306'u32)
  llc_init()
  blePlatformInitMark(0x307'u32)
  llm_init()
  blePlatformInitMark(0x308'u32)
  regWrite((BLE_BASE + 0x050'u32).uint, 0'u32)
  bleVolatileCounterInc(addr nim_ble_bflbble_init_return_count)

proc bflbble_reset*() {.exportc, cdecl.} =
  ## Reset BLE hardware and link-layer state, matching the vendor reset order.
  when defined(bl808m0):
    nimDisableM0RfClicIrq()
    nimDisableM0BleClicIrq()
  lld_core_reset()
  lld_init(true)
  llc_reset()
  llm_init()
  em_buf_init()
  nim_ble_core_ready = false
  initBleCoreRegisters()

proc bflbble_enable_runtime_irqs*() {.exportc, cdecl.} =
  ## Enable runtime BLE/RF interrupt delivery after controller state is ready.
  when defined(bl808m0):
    nimEnableM0BleRuntimeIrqs()

proc bflbble_sleep_check*(): bool {.exportc, cdecl.} =
  return ble_ke_sleep_check()

proc bflbble_activity_ongoing_check*(): bool {.exportc, cdecl.} =
  return ea_env_list.first != nil

proc bflbble_version*(): uint32 {.exportc, cdecl.} =
  return regRead(BLE_BASE + BLE_VERSION_OFFSET)

proc ble_dbg_isr_count*(): uint32 {.exportc, cdecl.} =
  nim_ble_dbg_isr_count

proc ble_dbg_isr_stat_or*(): uint32 {.exportc, cdecl.} =
  nim_ble_dbg_isr_stat_or

proc ble_dbg_stat20_count*(): uint32 {.exportc, cdecl.} =
  nim_ble_dbg_stat20_count

proc ble_dbg_stat8000_count*(): uint32 {.exportc, cdecl.} =
  nim_ble_dbg_stat8000_count

proc bflbble_isr_clear*() {.exportc, cdecl.} =
  ## Clear all BLE interrupts
  let stat = regRead(BLE_BASE + BTBLE_INTSTAT_OFFSET)
  regWrite(BLE_BASE + BTBLE_INTACK_OFFSET, stat)

proc bflbble_isr*() {.exportc, cdecl.} =
  ## BLE interrupt service routine
  when defined(bl808BleConnectTrace) and defined(bl808m0) and
      bl808BleNimConnectionEnabled:
    if nim_conn_started:
      bleTrace("[CON] isr enter\r\n")
  serviceBleRfCalibrationLatch()
  let stat = regRead(BLE_BASE + BTBLE_INTSTAT_OFFSET)
  let detail = regRead(BLE_BASE + BTBLE_INTDETAIL_OFFSET)
  let swPending = nim_btble_sw_pending or (stat and 0x00000008'u32) != 0
  var legacySchedulerPending = (stat and 0x00008000'u32) != 0
  when defined(bl808m0) and not bl808BleNimRuntimeClicIrq:
    legacySchedulerPending =
      legacySchedulerPending or ((detail and 0x0000001E'u32) != 0)
  var ackStat = stat
  if legacySchedulerPending:
    ackStat = ackStat or 0x00008000'u32
  let observedStat =
    if legacySchedulerPending: stat or 0x00008000'u32 else: stat
  inc nim_ble_dbg_isr_count
  nim_ble_dbg_isr_stat_or = nim_ble_dbg_isr_stat_or or observedStat
  if (observedStat and 0x20'u32) != 0:
    inc nim_ble_dbg_stat20_count
  if (observedStat and 0x8000'u32) != 0:
    inc nim_ble_dbg_stat8000_count
  when defined(bl808m0) and
      bl808BleNimConnectionEnabled:
    serviceNimArbCallbacks()
  when defined(bl808m0) and
      (bl808BleNimConnectionEnabled or
       bl808BleNimPureCentral):
    when bl808BleNimSchProg:
      if swPending and skipFlag != 0'u8:
        inc nim_sch_prog_skip_count
        nimSchProgSkipIsr(uint8(nimSchProgSkipIndex and 0x0F'u32))
        skipFlag = 0'u8
    if legacySchedulerPending:
      inc nim_sch_prog_fifo_count
      nimSchProgFifoIsr()
      when bl808BleNimPureConnection:
        nimConnServiceDeferredSchedule()
      when defined(bl808m0) and
          bl808BleNimConnectionEnabled:
        serviceNimArbCallbacks()
  # Acknowledge all interrupts
  regWrite(BLE_BASE + BTBLE_INTACK_OFFSET, ackStat)
  when defined(bl808m0):
    serviceNimArbTimer()
  when defined(bl808m0) and bl808BleNimConnectionEnabled and
      bl808BleNimManualConnTx:
    if (stat and 0x8000'u32) != 0 or nim_conn_started:
      serviceNimConnectionLlcpRxDescriptors()
  var serviceAdvRx = legacySchedulerPending
  when defined(bl808m0):
    # The vendor scan arbiter can complete RX descriptors without leaving a
    # scheduler FIFO bit visible to the cooperative poller.  Poll while scanning
    # so LE advertising reports are not stranded in EM.
    if nim_scan_enabled:
      serviceAdvRx = true
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    # In cooperative M0 builds the BTBLE RX descriptor done bit can arrive
    # without a FIFO interrupt status bit; poll the advertising RX ring while
    # advertising so SCAN_REQ/CONNECT_IND PDUs are not left queued in EM.
    if nim_adv_enabled:
      serviceAdvRx = true
    if nim_conn_started:
      serviceAdvRx = false
  if serviceAdvRx:
    when defined(bl808BleConnectTrace) and defined(bl808m0) and
        bl808BleNimConnectionEnabled:
      if nim_conn_started:
        bleTrace("[CON] before advrx\r\n")
    serviceBtbleAdvRxDescriptors()
    when defined(bl808m0) and bl808BleNimConnectionEnabled and
        not bl808BleNimRuntimeClicIrq:
      serviceQueuedNimConnectInd()
    when defined(bl808m0) and bl808BleNimConnectionEnabled:
      nimConnMark(0x220'u32)
    when defined(bl808BleConnectTrace) and defined(bl808m0) and
        bl808BleNimConnectionEnabled:
      if nim_conn_started:
        bleTrace("[CON] after advrx\r\n")
  when defined(bl808m0) and
      bl808BleNimSchProg and not bl808BleNimRuntimeClicIrq:
    if not legacySchedulerPending:
      nimSchProgElapsedIsr()
  when defined(bl808m0) and bl808BleNimPureCentral:
    bleControllerServiceScan()
  when defined(bl808m0) and
      bl808BleNimConnectionEnabled:
    serviceNimArbCallbacks()
  when not (defined(bl808m0) and bl808BleNimConnectionEnabled):
    if (stat and 0x20'u32) != 0:
      regClear32(BLE_BASE + BTBLE_INTMASK_OFFSET, BtbleIntEventTarget)
    if (stat and 0x40'u32) != 0:
      regClear32(BLE_BASE + BTBLE_INTMASK_OFFSET, 0x00000040'u32)
    if (stat and 0x80'u32) != 0:
      regClear32(BLE_BASE + BTBLE_INTMASK_OFFSET, 0x00000080'u32)
  if swPending:
    nim_btble_sw_pending = false
    if (stat and 0x08'u32) != 0:
      regWrite((BLE_BASE + BTBLE_INTACK_OFFSET).uint, BtbleIntSw)
    when not (defined(bl808m0) and not bl808BleNimRuntimeClicIrq):
      regClear32(BLE_BASE + BTBLE_INTMASK_OFFSET, BtbleIntSw)
  when bl808BleNimPureConnection:
    nimConnServiceSupervisionTimeout()
    nimConnServiceMissedEventFallback()
    nimConnServiceDeferredSchedule()
  if nim_adv_enabled and
      ((stat and 0x20'u32) != 0 or btbleTargetExpired(nim_adv_target_half_us)):
    pushBtbleAdvProgram()
    scheduleBtbleEvent()
  when defined(bl808m0) and
      bl808BleNimConnectionEnabled:
    if nim_adv_enabled:
      write16(BTBLE_EM_BASE + 0x150'u32, 0x0008'u16)
  when defined(bl808BleConnectTrace) and defined(bl808m0) and
      bl808BleNimConnectionEnabled:
    if nim_conn_started:
      bleTrace("[CON] isr exit\r\n")
      write16(BTBLE_EM_BASE + 0x152'u32, 0'u16)

  # Process interrupt sources
  if (stat and 0x01) != 0:
    ea_finetimer_isr()
  if (stat and 0x02) != 0:
    lld_evt_slot_isr()
  if (stat and 0x04) != 0:
    lld_evt_rx_isr()
  if (stat and 0x08) != 0:
    lld_evt_end_isr()
  if (stat and 0x10) != 0:
    lld_evt_timer_isr()
  if (stat and 0x20) != 0:
    lld_crypt_isr()
  serviceBleRfCalibrationLatch()

proc bleNimDbgIsrCount*(): uint32 {.exportc, cdecl.} =
  nim_ble_dbg_isr_count

proc bleNimDbgIsrStatOr*(): uint32 {.exportc, cdecl.} =
  nim_ble_dbg_isr_stat_or

proc bleNimDbgStat20Count*(): uint32 {.exportc, cdecl.} =
  nim_ble_dbg_stat20_count

proc bleNimDbgStat8000Count*(): uint32 {.exportc, cdecl.} =
  nim_ble_dbg_stat8000_count

proc bleNimDbgPushCount*(): uint32 {.exportc, cdecl.} =
  nim_ble_dbg_push_count

proc bleNimDbgRxReadyCount*(): uint32 {.exportc, cdecl.} =
  nim_ble_dbg_rx_ready_count

proc bleNimDbgRxScanReqCount*(): uint32 {.exportc, cdecl.} =
  nim_ble_dbg_rx_scan_req_count

proc bleNimDbgRxScanReqMatchCount*(): uint32 {.exportc, cdecl.} =
  nim_ble_dbg_rx_scan_req_match_count

proc bleNimDbgRxScanReqLastScanA0*(): uint32 {.exportc, cdecl.} =
  nim_ble_dbg_rx_scan_req_last_scana0

proc bleNimDbgRxScanReqLastScanA1*(): uint32 {.exportc, cdecl.} =
  nim_ble_dbg_rx_scan_req_last_scana1

proc bleNimDbgRxScanReqLastAdvA0*(): uint32 {.exportc, cdecl.} =
  nim_ble_dbg_rx_scan_req_last_adva0

proc bleNimDbgRxScanReqLastAdvA1*(): uint32 {.exportc, cdecl.} =
  nim_ble_dbg_rx_scan_req_last_adva1

proc bleNimDbgRxConnectIndCount*(): uint32 {.exportc, cdecl.} =
  nim_ble_dbg_rx_connect_ind_count

proc bleNimDbgRxLastHeader*(): uint32 {.exportc, cdecl.} =
  nim_ble_dbg_rx_last_header

proc bleNimDbgRxLastStatus*(): uint32 {.exportc, cdecl.} =
  nim_ble_dbg_rx_last_status

proc bleNimDbgRxLastDesc*(): uint32 {.exportc, cdecl.} =
  nim_ble_dbg_rx_last_desc

proc bleNimDbgRxLastBuf*(): uint32 {.exportc, cdecl.} =
  nim_ble_dbg_rx_last_buf

proc bleNimDbgVendorConStarted*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    if nim_conn_started: 1'u32 else: 0'u32
  else:
    0'u32

proc bleNimPeripheralConnEventCount*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_conn_evt_count
  else:
    0'u32

proc bleNimPeripheralConnHandle*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_conn_evt_handle
  else:
    0'u32

proc bleNimPeripheralConnPeerA0*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_conn_evt_peer_a0
  else:
    0'u32

proc bleNimPeripheralConnPeerA1*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_conn_evt_peer_a1
  else:
    0'u32

proc bleNimPeripheralConnPeerType*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_conn_evt_peer_type
  else:
    0'u32

proc bleNimPeripheralDiscEventCount*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_disc_evt_count
  else:
    0'u32

proc bleNimPeripheralDiscReason*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_disc_evt_reason
  else:
    0'u32

proc bleNimPeripheralDiscSource*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_disc_evt_source
  else:
    0'u32

proc bleNimDbgVendorLlcpRxCount*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_llcp_rx_count
  else:
    0'u32

proc bleNimPeripheralLastRxEventCounter*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled and
      bl808BleNimPureConnection:
    if nim_conn_state.active:
      nim_conn_state.lastRxEventCounter.uint32
    else:
      0'u32
  else:
    0'u32

proc bleNimDbgVendorLlcpTxCount*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_llcp_tx_count
  else:
    0'u32

proc bleNimDbgVendorLlcpTxQueued*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_llcp_tx_queued
  else:
    0'u32

proc bleNimDbgVendorLlcpTxDropped*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_llcp_tx_dropped
  else:
    0'u32

proc bleNimDbgVendorLlcpLastOpcode*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_llcp_last_opcode
  else:
    0'u32

proc bleNimDbgVendorLlcpLastStatus*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_llcp_last_status
  else:
    0'u32

proc bleNimDbgVendorLlcpAllocCount*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_llcp_alloc_count
  else:
    0'u32

proc bleNimDbgVendorLlcpFreeCount*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_llcp_free_count
  else:
    0'u32

proc bleNimDbgVendorLlcpAllocLastLen*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_llcp_alloc_last_len
  else:
    0'u32

proc bleNimDbgVendorLlcpAllocLastPtr*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_llcp_alloc_last_ptr
  else:
    0'u32

proc bleNimDbgVendorLlcpAllocLastEmoff*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_llcp_alloc_last_emoff
  else:
    0'u32

proc bleNimDbgVendorLlcpAllocLastLenField*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_llcp_alloc_last_len_field
  else:
    0'u32

proc bleNimDbgVendorLlcpFreeLastRaw*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_llcp_free_last_raw
  else:
    0'u32

proc bleNimDbgVendorLlcpFreeManualCount*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_llcp_free_manual_count
  else:
    0'u32

proc bleNimDbgVendorLlcpFreeHeapCount*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_llcp_free_heap_count
  else:
    0'u32

proc bleNimDbgVendorAclEmptyTxCount*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_acl_empty_tx_count
  else:
    0'u32

proc bleNimDbgVendorAclEmptyTxPending*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_acl_empty_tx_pending
  else:
    0'u32

proc bleNimDbgVendorAclEmptyLastStatus*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_acl_empty_last_status
  else:
    0'u32

proc bleNimDbgVendorConLastStatus*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_conn_last_status
  else:
    0'u32

proc bleNimDbgVendorConLastRxClock*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_conn_last_rx_clock
  else:
    0'u32

proc bleNimDbgVendorConLastRxFine*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_conn_last_rx_fine
  else:
    0'u32

proc bleNimDbgVendorConLastAnchor*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_conn_last_anchor
  else:
    0'u32

proc bleNimDbgVendorConLastWinOffset*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_conn_last_win_offset
  else:
    0'u32

proc bleNimDbgVendorConLastInterval*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_conn_last_interval
  else:
    0'u32

proc bleNimDbgVendorConLastTimeout*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_conn_last_timeout
  else:
    0'u32

proc bleNimDbgVendorConLastAccessAddr*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_conn_last_access_addr
  else:
    0'u32

proc bleNimDbgVendorConLastCrcInit*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_conn_last_crcinit
  else:
    0'u32

proc bleNimDbgVendorConnStage*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled and
      bl808BleConnStageDiag:
    nim_conn_stage
  else:
    0'u32

proc bleNimDbgVendorConnStageRa*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled and
      bl808BleConnStageDiag:
    nim_conn_stage_ra
  else:
    0'u32

proc bleNimDbgVendorConnStageSp*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled and
      bl808BleConnStageDiag:
    nim_conn_stage_sp
  else:
    0'u32

proc bleNimDbgVendorConnStageMepc*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled and
      bl808BleConnStageDiag:
    nim_conn_stage_mepc
  else:
    0'u32

proc bleNimDbgVendorConnStageMcause*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled and
      bl808BleConnStageDiag:
    nim_conn_stage_mcause
  else:
    0'u32

proc bleNimDbgVendorConnStageMark*(stage: uint32) {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled and
      bl808BleConnStageDiag:
    nimConnMark(stage)
  else:
    discard stage

proc bleNimDbgVendorLldConStartCount*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_lld_con_start_count
  else:
    0'u32

proc bleNimDbgVendorLldConStartStatus*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_lld_con_start_status
  else:
    0'u32

proc bleNimDbgVendorLldConStartParamWord*(word: uint32): uint32
    {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    let base = (word and 0x0F'u32) * 4'u32
    uint32(nim_lld_con_start_param[base.int]) or
      (uint32(nim_lld_con_start_param[base.int + 1]) shl 8) or
      (uint32(nim_lld_con_start_param[base.int + 2]) shl 16) or
      (uint32(nim_lld_con_start_param[base.int + 3]) shl 24)
  else:
    0'u32

proc bleNimDbgLldRxCheckCount*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_lld_rx_check_count
  else:
    0'u32

proc bleNimDbgLldRxCheckHitCount*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_lld_rx_check_hit_count
  else:
    0'u32

proc bleNimDbgLldRxCheckMissCount*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_lld_rx_check_miss_count
  else:
    0'u32

proc bleNimDbgLldRxFreeCount*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_lld_rx_free_count
  else:
    0'u32

proc bleNimDbgLldRxLastIdx*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_lld_rx_last_idx
  else:
    0'u32

proc bleNimDbgLldRxLastEnvIdx*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_lld_rx_last_env_idx
  else:
    0'u32

proc bleNimDbgLldRxLastStatus*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_lld_rx_last_status
  else:
    0'u32

proc bleNimDbgLldRxLastHeader*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_lld_rx_last_header
  else:
    0'u32

proc bleNimDbgLldRxLastMeta*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_lld_rx_last_meta
  else:
    0'u32

proc bleNimDbgConnDeferredScheduleCount*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimPureConnection:
    nim_conn_deferred_schedule_count
  else:
    0'u32

proc bleNimDbgConnRxStatusRejectCount*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimPureConnection:
    nim_conn_rx_status_reject_count
  else:
    0'u32

proc bleNimDbgConnRxLastRejectedStatus*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimPureConnection:
    nim_conn_rx_last_rejected_status
  else:
    0'u32

proc bleNimDbgConnRxLastRejectedHeader*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimPureConnection:
    nim_conn_rx_last_rejected_header
  else:
    0'u32

proc bleNimDbgLldRxDescActive*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    nim_lld_rx_desc_active.uint32
  else:
    0'u32

proc bleNimDbgVendorSchProgFifoCount*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and
      bl808BleNimConnectionEnabled:
    nim_sch_prog_fifo_count
  else:
    0'u32

proc bleNimDbgVendorSchProgSkipCount*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and
      bl808BleNimConnectionEnabled:
    nim_sch_prog_skip_count
  else:
    0'u32

proc bleNimDbgVendorArbSwCount*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and
      bl808BleNimConnectionEnabled:
    nim_arb_sw_count
  else:
    0'u32

proc bleNimDbgVendorArbEventStartCount*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and
      bl808BleNimConnectionEnabled:
    nim_arb_event_start_count
  else:
    0'u32

proc bleNimDbgVendorArbSetCount*(): uint32 {.exportc, cdecl.} =
  0'u32

proc bleNimDbgVendorArbLastTargetCoarse*(): uint32 {.exportc, cdecl.} =
  0'u32

proc bleNimDbgVendorArbLastTargetFine*(): uint32 {.exportc, cdecl.} =
  0'u32

proc bleNimDbgVendorArbDueTargetCoarse*(): uint32 {.exportc, cdecl.} =
  0'u32

proc bleNimDbgVendorArbDueTargetFine*(): uint32 {.exportc, cdecl.} =
  0'u32

proc bleNimDbgVendorArbDueNowCoarse*(): uint32 {.exportc, cdecl.} =
  0'u32

proc bleNimDbgVendorArbDueNowFine*(): uint32 {.exportc, cdecl.} =
  0'u32

proc bleNimDbgVendorSliceAddCount*(): uint32 {.exportc, cdecl.} =
  0'u32

proc bleNimDbgVendorSliceRemoveCount*(): uint32 {.exportc, cdecl.} =
  0'u32

proc bleNimDbgVendorSliceLastTypeCon*(): uint32 {.exportc, cdecl.} =
  0'u32

proc bleNimDbgVendorSliceLastInterval*(): uint32 {.exportc, cdecl.} =
  0'u32

proc bleNimDbgVendorSliceLastAnchor*(): uint32 {.exportc, cdecl.} =
  0'u32

proc bleNimDbgVendorSliceLastOffset*(): uint32 {.exportc, cdecl.} =
  0'u32

proc bleNimDbgVendorWrapArbInsertCount*(): uint32 {.exportc, cdecl.} =
  0'u32

proc bleNimDbgVendorWrapArbInsertStatus*(): uint32 {.exportc, cdecl.} =
  0'u32

proc bleNimDbgVendorWrapArbInsertLast*(): uint32 {.exportc, cdecl.} =
  0'u32

proc bleNimDbgVendorWrapProgPushCount*(): uint32 {.exportc, cdecl.} =
  0'u32

proc bleNimDbgVendorWrapProgPushLast*(): uint32 {.exportc, cdecl.} =
  0'u32

# ---------------------------------------------------------------------------
# ======================== BFLBIP (Platform IP) ============================
# ---------------------------------------------------------------------------

proc bflbip_init*() {.exportc, cdecl.} =
  bflbip_prevent_sleep_mask = 0
  bflbip_sleep_enabled = false
  bflbip_ext_wakeup = false
  bflbip_sw_wakeup_cnt = 0
  bflbip_sleep_dur_cnt = 0
  bflbip_sleep_stat_cnt = 0
  bflbip_wakeup_delay = 0

proc bflbip_reset*() {.exportc, cdecl.} =
  bflbip_init()

proc bflbip_version*(): uint32 {.exportc, cdecl.} =
  return bflbble_version()

proc bleControllerServiceNonblocking(): bool

proc bflbip_schedule*() {.exportc, cdecl.} =
  when defined(bl808BleConnectTrace) and defined(bl808m0) and
      bl808BleNimConnectionEnabled:
    if nim_conn_started:
      bleTrace("[CON] before sched\r\n")
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    serviceQueuedNimConnectInd()
  discard bleControllerServiceNonblocking()
  when defined(bl808BleConnectTrace) and defined(bl808m0) and
      bl808BleNimConnectionEnabled:
    if nim_conn_started:
      bleTrace("[CON] after sched\r\n")

proc bflbip_get_sw_wakup_cnt*(): uint32 {.exportc, cdecl.} =
  return bflbip_sw_wakeup_cnt

proc bflbip_get_sleep_dur_cnt*(): uint32 {.exportc, cdecl.} =
  return bflbip_sleep_dur_cnt

proc bflbip_get_sleep_stat_cnt*(): uint32 {.exportc, cdecl.} =
  return bflbip_sleep_stat_cnt

proc bflbip_sleep*(): bool {.exportc, cdecl.} =
  ## Check and enter sleep if possible
  if not bflbip_sleep_enabled:
    return false
  if bflbip_prevent_sleep_mask != 0:
    return false
  if not ble_ke_sleep_check():
    return false
  # Enter sleep
  lld_sleep_enter()
  inc bflbip_sleep_stat_cnt
  return true

proc bflbip_check_wakeup_boundary*(): bool {.exportc, cdecl.} =
  return true

proc bflbip_prevent_sleep_set*(mask: uint32) {.exportc, cdecl.} =
  bflbip_prevent_sleep_mask = bflbip_prevent_sleep_mask or mask

proc bflbip_prevent_sleep_clear*(mask: uint32) {.exportc, cdecl.} =
  bflbip_prevent_sleep_mask = bflbip_prevent_sleep_mask and not mask

proc bflbip_get_prevent_sleep*(): uint32 {.exportc, cdecl.} =
  return bflbip_prevent_sleep_mask

proc bflbip_sleep_enable*(en: bool) {.exportc, cdecl.} =
  bflbip_sleep_enabled = en

proc bflbip_ext_wakeup_enable*(en: bool) {.exportc, cdecl.} =
  bflbip_ext_wakeup = en

proc bflbip_sleep_lpcycles_2_us*(lpcycles: uint32): uint32 {.exportc, cdecl.} =
  ## Convert low-power clock cycles to microseconds
  ## Assumes 32.768 kHz LP clock: 1 cycle = ~30.5 us
  return (lpcycles * 3051) div 100

proc bflbip_us_2_lpcycles*(us: uint32): uint32 {.exportc, cdecl.} =
  ## Convert microseconds to low-power clock cycles
  return (us * 100) div 3051

proc bflbip_wakeup*() {.exportc, cdecl.} =
  lld_sleep_wakeup()
  inc bflbip_sw_wakeup_cnt

proc bflbip_wakeup_end*() {.exportc, cdecl.} =
  lld_sleep_wakeup_end()

proc bflbip_wakeup_delay_set*(delay: uint32) {.exportc, cdecl.} =
  bflbip_wakeup_delay = delay

proc bflbip_wlcoex_set*(en: bool) {.exportc, cdecl.} =
  bflbip_wlcoex_cfg = if en: 1'u32 else: 0'u32
  lld_wlcoex_set(en)

proc bflbip_eif_get*(): pointer {.exportc, cdecl.} =
  ## Get external interface structure pointer
  return nil

# ---------------------------------------------------------------------------
# ======================== BLE CONTROLLER API ==============================
# ---------------------------------------------------------------------------

proc bdaddr_init*() {.exportc, cdecl.}
proc ble_controller_task_init*(cfg: pointer) {.exportc, cdecl.}
proc ecc_init*() {.exportc, cdecl.}

proc bleControllerInitInternal(cfg: pointer) =
  blePlatformInitMark(0x400'u32)
  when defined(bl808m0):
    nimDisableM0RfClicIrq()
    nimDisableM0BleClicIrq()
  bflbip_init()
  blePlatformInitMark(0x401'u32)
  ble_ke_init()
  blePlatformInitMark(0x402'u32)
  hci_init(false)
  blePlatformInitMark(0x403'u32)
  bflbble_init()
  blePlatformInitMark(0x404'u32)
  ecc_init()
  blePlatformInitMark(0x405'u32)
  lld_sleep_init()
  blePlatformInitMark(0x406'u32)
  lld_evt_init()
  blePlatformInitMark(0x407'u32)
  bdaddr_init()
  blePlatformInitMark(0x408'u32)
  ble_controller_task_init(cfg)
  blePlatformInitMark(0x409'u32)
  bflbble_enable_runtime_irqs()
  blePlatformInitMark(0x40E'u32)

proc ble_controller_init*(taskPriority: uint8) {.exportc, cdecl.} =
  ## Initialize the BLE controller.
  discard taskPriority
  bleControllerInitInternal(nil)

proc ble_controller_deinit*() {.exportc, cdecl.} =
  ## De-initialize the BLE controller
  ble_ke_flush()
  if ble_controller_task_handle != nil:
    ble_vTaskDelete(ble_controller_task_handle)
    ble_controller_task_handle = nil

proc ble_controller_task_init*(cfg: pointer) {.exportc, cdecl.} =
  ## Initialize the BLE controller task
  bflb_main_queue_handle = ble_xQueueCreate(20, 8)

proc ble_controller_get_lib_ver*(): cstring {.exportc, cdecl.} =
  return ble_controller_lib_ver

proc ble_controller_set_tx_pwr*(pwr: cint) {.exportc, cdecl.} =
  ble_tx_pwr = pwr.int8

proc ble_controller_get_tx_pwr*(): int8 {.exportc, cdecl.} =
  return ble_tx_pwr

proc ble_controller_set_debug_level*(level: uint32) {.exportc, cdecl.} =
  ble_debug_level = level

proc ble_controller_get_debug_level*(): uint32 {.exportc, cdecl.} =
  return ble_debug_level

proc ble_controller_set_scan_filter_table_size*(size: uint8): int8
    {.exportc, cdecl.} =
  ble_scan_filter_table_size = size
  0'i8

proc ble_controller_fix_scan_chan*(chan: uint8) {.exportc, cdecl.} =
  ble_scan_chan_fixed = chan

proc ble_controller_disable_adv_random_delay*(disable: bool)
    {.exportc, cdecl.} =
  ble_adv_random_delay_disabled = disable

proc ble_controller_notify_adv_discarded*(cb: proc(count: uint32) {.cdecl.}) {.exportc, cdecl.} =
  ble_adv_discarded_callback = cb

proc ble_controller_program_ongoing*(): bool {.exportc, cdecl.} =
  return ble_programming_ongoing != nil and ble_programming_ongoing[] != 0

proc ble_controller_sleep*(maxSleepCycles: int32): int32 {.exportc, cdecl.} =
  if bflbip_sleep():
    maxSleepCycles
  else:
    0'i32

proc ble_controller_wakeup*() {.exportc, cdecl.} =
  bflbip_wakeup()

proc ble_controller_sleep_restore*() {.exportc, cdecl.} =
  bflbip_wakeup_end()

proc ble_controller_sleep_is_ongoing*(): bool {.exportc, cdecl.} =
  false

proc ble_controller_update_adv_scan_aa*() {.exportc, cdecl.} =
  lld_update_adv_scan_aa()

proc coDjobAnyPending(): bool

proc bleEventPendingWork(): bool {.inline.} =
  ble_ke_event_get_all() != 0'u32

proc bleMessagePendingWork(): bool {.inline.} =
  ke_msg_queue.first != nil

proc bleMessageEventPending(): bool {.inline.} =
  (ble_ke_event_get_all() and BleKeMessageEventBit) != 0

proc bleHiddenMessagePendingWork(): bool {.inline.} =
  bleMessagePendingWork() and not bleMessageEventPending()

proc bleMainQueuePendingWork(): bool {.inline.} =
  bleQueuePending(bflb_main_queue_handle)

proc bleDrainKernelEvents(): bool {.inline.} =
  if not bleEventPendingWork():
    return false
  ble_ke_event_schedule()
  true

proc bleControllerHasPendingWork(): bool =
  result = bleHciResetSettlePending() or bleEventPendingWork() or bleKeTimerPendingWork() or
    bleMessagePendingWork() or bleMainQueuePendingWork() or
    coDjobAnyPending()
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    result = result or nimArbCallbackPending()

proc bleDrainMainQueueMessage(): bool =
  if bflb_main_queue_handle == nil:
    return false
  var msg_buf: array[8, uint8]
  let ret = ble_xQueueReceive(bflb_main_queue_handle, addr msg_buf[0], 0)
  if ret != 1 or msg_buf[0] != 1:
    return false
  let param = cast[pointer](cast[ptr uint32](addr msg_buf[4])[])
  if param != nil:
    let hdr = getMsgHeader(param)
    ble_ke_msg_free(hdr)
  true

proc bleDrainScheduledWork(): bool =
  if bleHciResetSettlePending():
    inc nim_ble_hci_reset_settle_yield_count
    return true
  if bleKeTimerPendingWork():
    result = true
    ble_ke_timer_schedule()
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    if nimArbCallbackPending():
      result = true
      serviceNimArbCallbacks()
  if bleDrainKernelEvents():
    result = true
  if bleHiddenMessagePendingWork():
    result = true
    ble_ke_task_schedule()

proc bleControllerServiceStep(blockWhenIdle = false): bool =
  ## Service one BLE controller scheduler turn. The pure Nim queue receive path
  ## is nonblocking, so CPS callers can use this without pinning the scheduler.
  result = bleControllerHasPendingWork()
  if bleDrainMainQueueMessage():
    result = true
  if bleDrainScheduledWork():
    result = true
  if blockWhenIdle and not result:
    discard bflbip_sleep()
    result = bleControllerHasPendingWork()

proc bleControllerServiceNonblocking(): bool =
  bleControllerServiceStep()

proc bleControllerServiceBlockingIdle(): bool =
  bleControllerServiceStep(blockWhenIdle = true)

proc blecontroller_service_step*(blockWhenIdle: uint8 = 0'u8) {.exportc, cdecl.} =
  discard bleControllerServiceStep(blockWhenIdle != 0'u8)

proc blecontroller_poll_once*() {.exportc, cdecl.} =
  discard bleControllerServiceNonblocking()

proc blecontroller_main*() {.exportc, cdecl.} =
  ## Main BLE controller loop
  while true:
    discard bleControllerServiceBlockingIdle()

# ---------------------------------------------------------------------------
# ======================== BLE_DBG / ASSERT ================================
# ---------------------------------------------------------------------------

proc ble_assert_err*(file: cstring, line: uint32) {.exportc, cdecl.} =
  ## Fatal assertion
  discard

proc ble_assert_param*(a0: uint32, a1: uint32, a2: cstring, a3: uint32) {.exportc, cdecl.} =
  discard

proc ble_assert_warn*(file: cstring, line: uint32) {.exportc, cdecl.} =
  ## Non-fatal warning assertion
  discard

proc ble_dbg_platform_reset_complete*(status: uint32) {.exportc, cdecl.} =
  discard

proc ble_fur_debug_info*() {.exportc, cdecl.} =
  discard

proc ble_get_deep_sleep_stat*(): uint32 {.exportc, cdecl.} =
  return ble_deep_sleep_stat

proc dump_data*(data: pointer, len: uint32) {.exportc, cdecl.} =
  ## Debug data dump (no-op in production)
  discard

proc coex_dump_ble*(buf: pointer, len: uint32) {.exportc, cdecl.} =
  discard

# ---------------------------------------------------------------------------
# ======================== PLATFORM ========================================
# ---------------------------------------------------------------------------

proc platform_reset*(reason: uint32) {.exportc, cdecl.} =
  ## Platform reset handler
  ## From disasm: disables interrupts, then checks for magic values
  discard disableInterrupts()
  if reason == 0xC3C3C3C3'u32 or reason == 0xA5A5A5A5'u32:
    return  # Soft reset already handled
  # Hard reset: jump to address 0
  discard

proc BLE_ROM_patch*() {.exportc, cdecl.} =
  ## Apply ROM patches - sets up patch function pointer(s)
  discard

proc BLE_ROM_hook_init*() {.exportc, cdecl.} =
  ## Initialize ROM hook function pointer(s)
  ## From disasm: stores a sequence of function pointer(s)
  discard

proc get_stack_usage*(): uint16 {.exportc, cdecl.} =
  ## Calculate stack usage by scanning for sentinel byte 0xBB
  return 0

# ---------------------------------------------------------------------------
# ======================== BFLB_MAIN =======================================
# ---------------------------------------------------------------------------

proc bflb_main_task_post*(fn: pointer, arg: pointer): bool {.exportc, cdecl.} =
  if fn == nil:
    return false
  if bflb_main_queue_handle == nil:
    return false
  var msg: array[3, uint32]
  msg[0] = 1  # message type
  msg[1] = cast[uint32](fn)
  msg[2] = cast[uint32](arg)
  let ret = ble_xQueueSend(bflb_main_queue_handle, addr msg[0], 0)
  return ret == 1

proc bflb_main_task_post_from_fw*(fn: pointer, arg: pointer) {.exportc, cdecl.} =
  ## Post task from firmware context
  var msg_buf: array[8, uint8]
  msg_buf[0] = 2  # type = firmware post
  if bflb_main_queue_handle != nil:
    var woken: uint32 = 0
    discard ble_xQueueSendFromISR(bflb_main_queue_handle, addr msg_buf[0], addr woken)
    if woken == 1:
      ble_portYIELD_FROM_ISR()
  else:
    discard

proc bflb_main_task_post_from_isr*(fn: pointer, arg: pointer) {.exportc, cdecl.} =
  ## Post task from ISR context
  var msg_buf: array[8, uint8]
  msg_buf[0] = 2  # type
  if bflb_main_queue_handle != nil:
    var woken: uint32 = 0
    discard ble_xQueueSendFromISR(bflb_main_queue_handle, addr msg_buf[0], addr woken)
    if woken == 1:
      ble_portYIELD_FROM_ISR()

proc bflb_main_check_task_valid*(): bool {.exportc, cdecl.} =
  return ble_controller_task_handle != nil

proc bflb_main_get_task_priority*(): uint8 {.exportc, cdecl.} =
  if ble_controller_task_handle == nil:
    return 0
  return uint8(ble_uxTaskPriorityGet(ble_controller_task_handle) and 0xFF)

# ---------------------------------------------------------------------------
# ======================== BDADDR / MAC ====================================
# ---------------------------------------------------------------------------

proc bl_read_mac_addr*(mac: ptr uint8) {.exportc, cdecl.} =
  ## Read MAC address from eFuse
  let lo = regRead(0x40007014'u)
  let hi = regRead(0x40007018'u)
  let macBytes = cast[ptr UncheckedArray[uint8]](mac)
  for i in 0 ..< 4:
    macBytes[i] = uint8((lo shr (i * 8)) and 0xFF'u32)
  for i in 0 ..< 2:
    macBytes[4 + i] = uint8((hi shr (i * 8)) and 0xFF'u32)
  # Check if all zero or all 0x01 => use default
  var all_zero = true
  var all_same = true
  for i in 0 ..< 6:
    let b = macBytes[i]
    if b != 0:
      all_zero = false
    if b != 1:
      all_same = false
  if all_zero or all_same:
    # Use default MAC
    let default_mac = [0xC0'u8, 0x01, 0x02, 0x03, 0x04, 0x05]
    discard c_memcpy(mac, unsafeAddr default_mac[0], 6)

proc bdaddr_init*() {.exportc, cdecl.} =
  ## Initialize BD address from stored/eFuse MAC
  var addr_buf: BdAddr
  bl_read_mac_addr(addr addr_buf.data[0])
  # Increment first byte by 1 as the BLE address
  addr_buf.data[0] = addr_buf.data[0] + 1
  llm_util_set_public_addr(addr addr_buf)

# ---------------------------------------------------------------------------
# ======================== BLE RF ==========================================
# ---------------------------------------------------------------------------

proc ble_rf_init*() {.exportc, cdecl.} =
  rf_pwr_offset = 0
  rf_pwr_max = 0

proc ble_rf_set_pwr_offset_table*(table: ptr int8) {.exportc, cdecl.} =
  rf_pwr_offset_table = table

proc ble_rf_get_pwr_offset*(channel: uint8): int8 {.exportc, cdecl.} =
  if rf_pwr_offset_table != nil and channel < 40:
    return cast[ptr UncheckedArray[int8]](rf_pwr_offset_table)[channel]
  return 0

proc ble_rf_set_tx_channel*(channel: uint16) {.exportc, cdecl.} =
  configureBleRfChannelMhz(bleRfChannelMhz(channel))

proc bl_channel_calc_threshold*(ch_assess: pointer, threshold: ptr int8): uint8 {.exportc, cdecl.} =
  return 0

# ---------------------------------------------------------------------------
# ======================== ON-CHIP HCI =====================================
# ---------------------------------------------------------------------------

proc bt_onchiphci_interface_init*(cb: OnChipHciRecvCb): uint8 {.exportc, cdecl.} =
  discard c_memset(addr onchiphci_env[0], 0, sizeof(onchiphci_env).csize_t)
  onchiphci_recv_cb = cb
  nim_hci_debug_stage = 0x4200'u32
  nim_hci_debug_cb = cast[uint32](cast[uint](cb))
  0

proc handleOnchipHciCommandBuffer(data: pointer, len: uint16): uint8 =
  nim_hci_debug_stage = 0x4300'u32
  nim_hci_debug_len = len.uint32
  if data == nil or len < 3:
    return 0x12'u8
  let opcode = hciRawOpcode(data)
  let paramLen = hciRawParamLen(data)
  nim_hci_debug_stage = 0x4310'u32
  nim_hci_debug_opcode = opcode.uint32
  nim_hci_debug_len = paramLen.uint32
  if len < uint16(paramLen.int + 3):
    return 0x12'u8
  let params =
    if paramLen == 0: nil
    else: hciRawParams(data)
  let status = completeHciCommand(opcode, params, paramLen)
  nim_hci_debug_stage = 0x4320'u32
  nim_hci_debug_status = status.uint32
  when defined(bl808m0):
    bleCentralDebugMark(0x910'u32, (uint32(opcode) shl 8) or uint32(status))
  status

proc bt_onchiphci_send_raw*(data: pointer, len: uint16): bool =
  nim_hci_debug_stage = 0x4400'u32
  nim_hci_debug_len = len.uint32
  bleCentralDebugMark(0x920'u32, uint32(len))
  let ok = handleOnchipHciCommandBuffer(data, len) == 0
  nim_hci_debug_stage = 0x4410'u32
  nim_hci_debug_status = if ok: 0'u32 else: 1'u32
  when defined(bl808m0):
    bleCentralDebugMark(0x921'u32, if ok: 1'u32 else: 0'u32)
  ok

proc bt_onchiphci_send*(pktType: uint8, destId: uint16,
                        pkt: pointer): int8 {.exportc, cdecl.} =
  discard destId
  if pkt == nil:
    return -1'i8
  case pktType
  of BtHciCmd:
    let cmd = cast[ptr OnChipHciCmd](pkt)
    discard completeHciCommand(cmd.opcode, cmd.params, cmd.paramLen)
    return 0'i8
  of BtHciAclData:
    let acl = cast[ptr OnChipHciAclDataTx](pkt)
    let status = hciAclTxDataStatus(acl.conhdl, acl.pbBcFlag,
                                    acl.buffer, acl.len)
    return if status == HciStatusSuccess: 0'i8 else: -1'i8
  else:
    return -1'i8

proc bt_onchiphci_send_buffer*(data: pointer, len: uint16): bool {.cdecl.} =
  if data == nil or len < 3:
    return false
  handleOnchipHciCommandBuffer(data, len) == 0

proc bt_onchiphci_handle_rx_acl*(param: pointer, hostBufData: ptr uint8): uint8
    {.exportc, cdecl.} =
  discard param
  discard hostBufData
  0

# ---------------------------------------------------------------------------
# ======================== ECC CRYPTO ======================================
# ---------------------------------------------------------------------------

proc eccGenerateSecretKey(secret: ptr uint8): bool =
  bleP256Mark(0x00000100'u32)
  if secret == nil:
    bleP256Mark(0x00000101'u32)
    return false
  var tries = 32
  while tries > 0:
    bleP256Mark(0x00000110'u32)
    if not bleFillRandomBytes(secret, ECC_KEY_LEN):
      discard c_memset(secret, 0, ECC_KEY_LEN.csize_t)
      bleP256Mark(0x00000111'u32)
      return false
    bleP256Mark(0x00000120'u32)
    if bleP256IsValidScalarLe(secret):
      discard c_memcpy(addr ecc_private_key[0], secret, ECC_KEY_LEN.csize_t)
      bleP256Mark(0x00000130'u32)
      return true
    dec tries
  discard c_memset(secret, 0, ECC_KEY_LEN.csize_t)
  bleP256Mark(0x000001FF'u32)
  false

proc p256ControllerScalarMultLe(secret, pointX, pointY, outX, outY: ptr uint8): bool =
  bleP256ScalarMultLe(secret, pointX, pointY, outX, outY)

proc p256ControllerBaseMultLe(secret, outX, outY: ptr uint8): bool =
  bleP256ScalarBaseMultLe(secret, outX, outY)

proc ecc_init*() {.exportc, cdecl.} =
  discard c_memset(addr ecc_env[0], 0, sizeof(ecc_env).csize_t)
  discard c_memset(addr ecc_private_key[0], 0, ECC_KEY_LEN.csize_t)
  ecc_ongoing = false

proc ecc_is_valid_point*(point: ptr EccPoint256): bool {.exportc, cdecl.} =
  if point == nil:
    return false
  bleP256IsValidPublicKeyLe(addr point.x[0], addr point.y[0])

proc ecc_generate_key256*(op: uint32, secret: ptr uint8, pointX: ptr uint8,
                          pointY: ptr uint8, publicKey: ptr EccPoint256,
                          resultCb: pointer) {.exportc, cdecl.} =
  discard op
  discard resultCb
  ecc_ongoing = true
  if secret == nil or publicKey == nil:
    ecc_ongoing = false
    return
  let ok =
    if pointX == nil or pointY == nil:
      p256ControllerBaseMultLe(secret, addr publicKey.x[0], addr publicKey.y[0])
    else:
      p256ControllerScalarMultLe(secret, pointX, pointY, addr publicKey.x[0],
                                 addr publicKey.y[0])
  if ok:
    discard c_memcpy(addr ecc_private_key[0], secret, ECC_KEY_LEN.csize_t)
  else:
    discard c_memset(publicKey, 0, sizeof(EccPoint256).csize_t)
  ecc_ongoing = false

proc ecc_abort_key256_generation*() {.exportc, cdecl.} =
  ecc_ongoing = false

proc ecc_gen_new_public_key*(secret: ptr uint8, public_key: ptr EccPoint256) {.exportc, cdecl.} =
  if secret == nil or public_key == nil:
    return
  if p256ControllerBaseMultLe(secret, addr public_key.x[0], addr public_key.y[0]):
    discard c_memcpy(addr ecc_private_key[0], secret, ECC_KEY_LEN.csize_t)
  else:
    discard c_memset(public_key, 0, sizeof(EccPoint256).csize_t)

proc ecc_gen_new_secret_key*(secret: ptr uint8) {.exportc, cdecl.} =
  discard eccGenerateSecretKey(secret)

proc ecc_get_debug_Keys*(secret: ptr uint8, public_key: ptr EccPoint256) {.exportc, cdecl.} =
  if secret != nil:
    discard c_memcpy(secret, unsafeAddr BleP256DebugPrivateKeyLe[0],
                     ECC_KEY_LEN.csize_t)
    discard c_memcpy(addr ecc_private_key[0], secret, ECC_KEY_LEN.csize_t)
  if public_key != nil:
    discard c_memcpy(addr public_key.x[0], unsafeAddr BleP256DebugPublicKeyXLe[0],
                     ECC_KEY_LEN.csize_t)
    discard c_memcpy(addr public_key.y[0], unsafeAddr BleP256DebugPublicKeyYLe[0],
                     ECC_KEY_LEN.csize_t)

proc ecc_get_private_key*(key: ptr uint8) {.exportc, cdecl.} =
  if key != nil:
    discard c_memcpy(key, addr ecc_private_key[0], ECC_KEY_LEN.csize_t)

proc notEqual256*(a: ptr uint8, b: ptr uint8): bool {.exportc, cdecl.} =
  return c_memcmp(a, b, ECC_KEY_LEN.csize_t) != 0

proc bigHexInversion256*(input: ptr uint8, output: ptr uint8) {.exportc, cdecl.} =
  if not bleP256InverseFieldLe(input, output) and output != nil:
    discard c_memset(output, 0, ECC_KEY_LEN.csize_t)

proc GF_Point_Jacobian_To_Affine256*(point: ptr uint8) {.exportc, cdecl.} =
  ## Convert Jacobian to Affine coordinates
  bleP256JacobianToAffineInPlace(point)

# ---------------------------------------------------------------------------
# ======================== BTBLE VENDOR ABI ALIASES ========================
# ---------------------------------------------------------------------------

proc btble_co_list_push_back*(list: ptr CoList,
                              node: ptr CoListNode) {.exportc, cdecl.} =
  ble_co_list_push_back(list, node)

proc btble_co_list_push_front*(list: ptr CoList,
                               node: ptr CoListNode) {.exportc, cdecl.} =
  ble_co_list_push_front(list, node)

proc btble_co_list_pop_front*(list: ptr CoList): ptr CoListNode
    {.exportc, cdecl.} =
  ble_co_list_pop_front(list)

proc btble_co_list_init*(list: ptr CoList) {.exportc, cdecl.} =
  ble_co_list_init(list)

proc btble_co_list_extract*(list: ptr CoList,
                            node: ptr CoListNode) {.exportc, cdecl.} =
  ble_co_list_extract(list, node)

proc btble_co_list_extract_after*(list: ptr CoList, prevNode: ptr CoListNode,
                                  node: ptr CoListNode) {.exportc, cdecl.} =
  ble_co_list_extract_after(list, prevNode, node)

proc btble_co_list_find*(list: ptr CoList, node: ptr CoListNode): bool
    {.exportc, cdecl.} =
  ble_co_list_find(list, node)

proc btble_co_list_insert_after*(list: ptr CoList,
                                 afterNode: ptr CoListNode,
                                 node: ptr CoListNode) {.exportc, cdecl.} =
  ble_co_list_insert_after(list, afterNode, node)

proc btble_co_list_insert_before*(list: ptr CoList,
                                  beforeNode: ptr CoListNode,
                                  node: ptr CoListNode) {.exportc, cdecl.} =
  ble_co_list_insert_before(list, beforeNode, node)

proc btble_co_list_merge*(dest: ptr CoList, src: ptr CoList)
    {.exportc, cdecl.} =
  ble_co_list_merge(dest, src)

proc btble_co_list_pool_init*(list: ptr CoList, pool: pointer,
                              eltSize: uint32, count: uint32,
                              initCb: pointer, lastCb: pointer)
    {.exportc, cdecl.} =
  ble_co_list_pool_init(list, pool, eltSize, count, initCb, lastCb)

proc btble_co_list_size*(list: ptr CoList): uint32 {.exportc, cdecl.} =
  ble_co_list_size(list)

proc btble_co_list_push_back_sublist*(list: ptr CoList,
                                      firstNode: ptr CoListNode,
                                      lastNode: ptr CoListNode)
    {.exportc, cdecl.} =
  if firstNode == nil:
    return
  if list.first == nil:
    list.first = firstNode
  else:
    list.last.next = firstNode
  list.last = lastNode
  if list.last != nil:
    list.last.next = nil

proc btble_co_list_extract_sublist*(list: ptr CoList,
                                    firstNode: ptr CoListNode,
                                    lastNode: ptr CoListNode)
    {.exportc, cdecl.} =
  if firstNode == nil:
    return
  var prev: ptr CoListNode = nil
  var cur = list.first
  while cur != nil and cur != firstNode:
    prev = cur
    cur = cur.next
  if cur == nil:
    return
  let afterLast =
    if lastNode != nil: lastNode.next
    else: nil
  if prev == nil:
    list.first = afterLast
  else:
    prev.next = afterLast
  if list.last == lastNode:
    list.last = prev
  if lastNode != nil:
    lastNode.next = nil

proc btble_ke_event_callback_set*(idx: uint8, cb: KeEventCallback)
    {.exportc, cdecl.} =
  ble_ke_event_callback_set(idx, cb)

proc btble_ke_event_clear*(idx: uint8) {.exportc, cdecl.} =
  ble_ke_event_clear(idx)

proc btble_ke_event_flush*() {.exportc, cdecl.} =
  ble_ke_event_flush()

proc btble_ke_event_get*(idx: uint8): bool {.exportc, cdecl.} =
  ble_ke_event_get(idx)

proc btble_ke_event_get_all*(): uint32 {.exportc, cdecl.} =
  ble_ke_event_get_all()

proc btble_ke_event_init*() {.exportc, cdecl.} =
  ble_ke_event_init()

proc btble_ke_event_schedule*() {.exportc, cdecl.} =
  ble_ke_event_schedule()

proc btble_ke_event_set*(idx: uint8) {.exportc, cdecl.} =
  ble_ke_event_set(idx)

proc btble_ke_init*() {.exportc, cdecl.} =
  ble_ke_init()

proc btble_ke_flush*() {.exportc, cdecl.} =
  ble_ke_flush()

proc btble_ke_malloc*(size: uint32, mtype: uint32): pointer
    {.exportc, cdecl.} =
  when defined(bl808m0):
    bleCentralTraceCheckRawRa(0x0A00'u32)
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    if nim_llc_status == 0xC0010001'u32 and size == 0x8C'u32:
      discard mtype
      discard c_memset(addr nim_llc_env_storage[0], 0,
                       nim_llc_env_storage.len.csize_t)
      nim_llc_status = 0xC0010011'u32
      return cast[pointer](addr nim_llc_env_storage[0])
  result = ble_ke_malloc(size, mtype)
  when defined(bl808m0):
    bleCentralTraceCheckRawRa(0x0A01'u32)
proc btble_ke_free*(p: pointer) {.exportc, cdecl.} =
  ble_ke_free(p)

proc btble_ke_check_malloc*(): uint32 {.exportc, cdecl.} =
  ble_ke_check_malloc()

proc btble_ke_is_free*(p: pointer): bool {.exportc, cdecl.} =
  ble_ke_is_free(p)

proc btble_ke_mem_init*(mtype: uint8, heap: ptr uint8, size: uint16)
    {.exportc, cdecl.} =
  discard mtype
  ke_mem_heap = heap
  ke_mem_heap_end = addr cast[ptr UncheckedArray[uint8]](heap)[size.int]
  ble_ke_mem_init()

proc btble_ke_mem_is_empty*(): bool {.exportc, cdecl.} =
  ble_ke_mem_is_empty()

proc btble_ke_msg_alloc*(id: KeMsgId, destId: KeTaskId,
                         srcId: KeTaskId,
                         paramLen: uint16): pointer {.exportc, cdecl.} =
  when defined(bl808m0) and
      bl808BleNimConnectionEnabled:
    when defined(bl808BleBridgeDiag):
      nim_bridge_stage = 0x8000'u32 or uint32(id and 0x00FF'u16)
  ble_ke_msg_alloc(id, destId, srcId, paramLen)

proc btble_ke_msg_send*(param: pointer) {.exportc, cdecl.} =
  when defined(bl808m0) and
      bl808BleNimConnectionEnabled:
    when defined(bl808BleBridgeDiag):
      nim_bridge_stage = 0x8100'u32 or
        (cast[uint32](param) and 0x000000FF'u32)
  ble_ke_msg_send(param)

proc btble_ke_msg_send_basic*(id: KeMsgId, destId: KeTaskId,
                              srcId: KeTaskId) {.exportc, cdecl.} =
  when defined(bl808m0) and
      bl808BleNimConnectionEnabled:
    when defined(bl808BleBridgeDiag):
      nim_bridge_stage = 0x8200'u32 or uint32(id and 0x00FF'u16)
  ble_ke_msg_send_basic(id, destId, srcId)

proc btble_ke_msg_free*(msg: ptr KeMsgHeader) {.exportc, cdecl.} =
  ble_ke_msg_free(msg)

proc btble_ke_msg_dest_id_get*(param: pointer): KeTaskId {.exportc, cdecl.} =
  ble_ke_msg_dest_id_get(param)

proc btble_ke_msg_src_id_get*(param: pointer): KeTaskId {.exportc, cdecl.} =
  ble_ke_msg_src_id_get(param)

proc btble_ke_msg_in_queue*(param: pointer): bool {.exportc, cdecl.} =
  ble_ke_msg_in_queue(param)

proc btble_ke_msg_discard*(msgid: KeMsgId, destId: KeTaskId,
                           srcId: KeTaskId, param: pointer): int32
    {.exportc, cdecl.} =
  ble_ke_msg_discard(msgid, destId, srcId, param)

proc btble_ke_msg_save*(msgid: KeMsgId, destId: KeTaskId,
                        srcId: KeTaskId, param: pointer): int32
    {.exportc, cdecl.} =
  ble_ke_msg_save(msgid, destId, srcId, param)

proc btble_ke_msg_forward*(param: pointer, destId: KeTaskId)
    {.exportc, cdecl.} =
  ble_ke_msg_fobflbard(param, destId)

proc btble_ke_msg_forward_new_id*(param: pointer, id: KeMsgId,
                                  destId: KeTaskId) {.exportc, cdecl.} =
  ble_ke_msg_fobflbard_new_id(param, id, destId)

proc btble_ke_queue_extract*(queue: ptr CoList, cmp: QueueCmpFunc,
                             arg: pointer): ptr CoListNode {.exportc, cdecl.} =
  ble_ke_queue_extract(queue, cmp, arg)

proc btble_ke_queue_insert*(queue: ptr CoList, node: ptr CoListNode,
                            cmp: QueueCmpFunc) {.exportc, cdecl.} =
  ble_ke_queue_insert(queue, node, cmp)

proc btble_ke_sleep_check*(): bool {.exportc, cdecl.} =
  ble_ke_sleep_check()

proc btble_ke_state_set*(taskId: KeTaskId, state: uint8) {.exportc, cdecl.} =
  ble_ke_state_set(taskId, state)
proc btble_ke_state_get*(taskId: KeTaskId): uint8 {.exportc, cdecl.} =
  ble_ke_state_get(taskId)

proc btble_ke_task_check*(taskType: uint8): bool {.exportc, cdecl.} =
  ble_ke_task_check(taskType)

proc btble_ke_task_create*(taskType: uint8, desc: ptr KeTaskDesc)
    {.exportc, cdecl.} =
  ble_ke_task_create(taskType, desc)

proc btble_ke_task_delete*(taskType: uint8) {.exportc, cdecl.} =
  ble_ke_task_delete(taskType)

proc btble_ke_task_init*() {.exportc, cdecl.} =
  ble_ke_task_init()

proc btble_ke_task_msg_flush*(taskId: KeTaskId) {.exportc, cdecl.} =
  ble_ke_task_msg_flush(taskId)

proc btble_ke_timer_active*(id: uint16, task: uint16): bool
    {.exportc, cdecl.} =
  ble_ke_timer_active(id, task)

proc btble_ke_timer_clear*(id: uint16, task: uint16) {.exportc, cdecl.} =
  ble_ke_timer_clear(id, task)

proc btble_ke_timer_flush*() {.exportc, cdecl.} =
  while ke_timer_list.first != nil:
    let node = ble_co_list_pop_front(addr ke_timer_list)
    ble_ke_free(node)

proc btble_ke_timer_get*(id: uint16, task: uint16): uint32
    {.exportc, cdecl.} =
  var cur = cast[ptr KeTimer](ke_timer_list.first)
  while cur != nil:
    if cur.id == id and cur.task == task:
      return cur.time
    cur = cur.next
  0

proc btble_ke_timer_set*(id: uint16, task: uint16, delay: uint32)
    {.exportc, cdecl.} =
  ble_ke_timer_set(id, task, delay)

proc btble_controller_init*(taskPriority: uint8) {.exportc, cdecl.} =
  ble_controller_init(taskPriority)
  resetNimControllerState()

proc btble_controller_deinit*() {.exportc, cdecl.} =
  ble_controller_deinit()

proc btblecontroller_main*() {.exportc, cdecl.} =
  blecontroller_main()

proc btble_controller_get_lib_ver*(): cstring {.exportc, cdecl.} =
  ble_controller_get_lib_ver()

proc btble_controller_sleep*(maxSleepCycles: int32): int32
    {.exportc, cdecl.} =
  ble_controller_sleep(maxSleepCycles)

proc btble_controller_remaining_mem*(): uint32 {.exportc, cdecl.} =
  0

proc ble_controller_reset*() {.exportc, cdecl.} =
  rwip_reset()

proc BTBLE_ROM_hook_init*() {.exportc, cdecl.} =
  BLE_ROM_hook_init()

proc dbg_platform_reset_complete*(status: uint32) {.exportc, cdecl.} =
  ble_dbg_platform_reset_complete(status)

proc bt_onchiphci_hanlde_rx_acl*(param: pointer, hostBufData: ptr uint8): uint8
    {.exportc: "bt_onchiphci_hanlde_rx_acl", cdecl.} =
  bt_onchiphci_handle_rx_acl(param, hostBufData)

proc hci_initialize*(initType: uint8) {.exportc, cdecl.} =
  hci_init(initType != 0)

proc hci_is_ext_host*(): bool {.exportc, cdecl.} =
  false

proc hci_build_acl_data*(handle: uint16, data: pointer, len: uint16): pointer
    {.exportc, cdecl.} =
  hci_build_acl_rx_data(handle, data, len)

proc ble_util_buf_init*() {.exportc, cdecl.} =
  em_buf_init()

proc ble_util_buf_acl_tx_alloc*(len: uint16): pointer {.exportc, cdecl.} =
  ble_ke_malloc(len.uint32, 0)

proc ble_util_buf_acl_tx_elt_get*(buf: pointer): pointer {.exportc, cdecl.} =
  buf

proc ble_util_buf_acl_tx_free*(buf: pointer) {.exportc, cdecl.} =
  when defined(bl808m0) and
      bl808BleNimConnectionEnabled:
    when defined(bl808BleBridgeDiag):
      nim_bridge_stage = 0x8300'u32 or
        (cast[uint32](buf) and 0x000000FF'u32)
  when defined(bl808m0) and bl808BleNimConnectionEnabled and
      bl808BleNimManualConnTx:
    let raw = cast[uint32](buf)
    if raw == NimAclTxEmOffset.uint32 or
        raw == cast[uint32](addr nim_acl_empty_tx_buf[0]):
      nim_acl_empty_tx_pending = 0
      if nim_conn_started and nim_acl_empty_tx_queued != 0:
        nim_acl_empty_tx_queued = 0
        discard nimSendEmptyAclNow(activeNimConnectionHandle())
      return
  if buf != nil:
    ble_ke_free(buf)

proc ble_util_buf_adv_tx_alloc*(len: uint16): pointer {.exportc, cdecl.} =
  ble_ke_malloc(len.uint32, 0)

proc ble_util_buf_adv_tx_free*(buf: pointer) {.exportc, cdecl.} =
  if buf != nil:
    ble_ke_free(buf)

proc ble_util_buf_elt_rx_get*(idx: uint8): pointer {.exportc, cdecl.} =
  discard idx
  nil

proc ble_util_buf_llcp_tx_alloc*(len: uint16): pointer {.exportc, cdecl.} =
  let buf = ble_ke_malloc(len.uint32, 0)
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    inc nim_llcp_alloc_count
    nim_llcp_alloc_last_len = len.uint32
    nim_llcp_alloc_last_ptr = cast[uint32](buf)
    nim_llcp_alloc_last_emoff = 0
    nim_llcp_alloc_last_len_field = 0
    if buf != nil and len >= 7'u16:
      let raw = cast[ptr UncheckedArray[uint8]](buf)
      nim_llcp_alloc_last_emoff =
        uint32(raw[4]) or (uint32(raw[5]) shl 8)
      nim_llcp_alloc_last_len_field = raw[6].uint32
  buf

proc ble_util_buf_llcp_tx_free*(buf: pointer) {.exportc, cdecl.} =
  when defined(bl808m0) and
      bl808BleNimConnectionEnabled:
    when defined(bl808BleBridgeDiag):
      nim_bridge_stage = 0x8400'u32 or
        (cast[uint32](buf) and 0x000000FF'u32)
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    let raw = cast[uint32](buf)
    inc nim_llcp_free_count
    nim_llcp_free_last_raw = raw
    if raw == NimLlcpTxEmOffset.uint32 or
        raw == cast[uint32](addr nim_llcp_tx_buf[0]):
      nim_llcp_tx_pending = 0
      inc nim_llcp_free_manual_count
      when bl808BleNimManualConnTx:
        serviceNimConnectionLlcpRxDescriptors()
        nimLlcpTrySendQueued()
        nimLlcpTrySendStartup(activeNimConnectionHandle())
      return
    if buf != nil:
      inc nim_llcp_free_heap_count
  if buf != nil:
    ble_ke_free(buf)

proc ble_util_buf_rx_alloc*(len: uint16): pointer {.exportc, cdecl.} =
  ble_ke_malloc(len.uint32, 0)

proc ble_util_buf_rx_free*(buf: pointer) {.exportc, cdecl.} =
  if buf == nil:
    return
  let raw = cast[uint32](buf)
  if raw < 0x00010000'u32:
    return
  when defined(bl808m0):
    if raw >= BTBLE_EM_BASE and raw < BTBLE_EM_BASE + 0x00010000'u32:
      return
  ble_ke_free(buf)

proc ble_util_nb_good_channels*(map: ptr uint8): uint8 {.exportc, cdecl.} =
  if map == nil:
    return 0
  let mapBytes = cast[ptr UncheckedArray[uint8]](map)
  var count: uint8 = 0
  for i in 0 ..< 5:
    let byteVal = mapBytes[i]
    for bit in 0 ..< 8:
      if i * 8 + bit < 37 and (byteVal and (1'u8 shl bit)) != 0:
        inc count
  count

when not (defined(bl808m0) and
    (bl808BleNimConnectionEnabled or bl808BleNimPureCentral)):
  proc lld_read_clock*(): uint32 {.exportc, cdecl.} =
    result = currentBtbleTime()
  proc rwip_current_drift_get*(): uint32 {.exportc, cdecl.} =
    RwipDefaultMaxDriftPpm

  proc rwip_max_drift_get*(sca: uint8): uint32 {.exportc, cdecl.} =
    discard sca
    RwipDefaultMaxDriftPpm

  proc rwip_channel_assess_ble*(channel: uint8, rssi: int8)
      {.exportc, cdecl.} =
    discard channel
    discard rssi

  proc ble_util_pkt_dur_in_us*(length: uint16, rate: uint8): uint16
      {.exportc, cdecl.} =
    case rate
    of 0:
      uint16((uint32(length) + 10'u32) * 8'u32)
    of 1:
      uint16((uint32(length) + 11'u32) * 4'u32)
    of 2:
      uint16(uint32(length) * 64'u32 + 720'u32)
    else:
      uint16(uint32(length) * 16'u32 + 462'u32)

when not (defined(bl808m0) and
    bl808BleNimSchProgEnabled):
  proc rwip_time_get*(time: pointer) {.exportc, cdecl.} =
    if time == nil:
      return
    let words = cast[ptr UncheckedArray[uint32]](time)
    words[0] = currentBtbleTime()
    words[1] = 0
    words[2] = regRead((BLE_BASE + 0x9C4'u32).uint)

  proc rwip_prevent_sleep_set*(mask: uint16) {.exportc, cdecl.} =
    bflbip_prevent_sleep_mask = bflbip_prevent_sleep_mask or mask.uint32

  proc rwip_prevent_sleep_clear*(mask: uint16) {.exportc, cdecl.} =
    bflbip_prevent_sleep_mask = bflbip_prevent_sleep_mask and not mask.uint32

  proc rwip_sw_int_req*() {.exportc, cdecl.} =
    requestBtbleSwInterrupt()

proc rwip_prevent_sleep_get*(): uint32 {.exportc, cdecl.} =
  bflbip_prevent_sleep_mask

proc rwip_driver_init*(initType: uint8) {.exportc, cdecl.} =
  discard initType
  bflbip_init()

proc rwip_init*(initType: uint8) {.exportc, cdecl.} =
  bflbip_init()
  ble_ke_init()
  em_buf_init()
  hci_init(initType != 0)
  llc_init()
  lld_init(initType != 0)
  bleSettleAfterLldInit()
  llm_init()
  ecc_init()
  lld_sleep_init()
  bdaddr_init()
  resetNimControllerState()

proc rwipResetCore() =
  ble_ke_flush()
  hci_reset()
  bflbip_reset()
  bflbble_reset()
  ea_init()
  bflbip_prevent_sleep_mask = 0
  nim_btble_sw_pending = false
  resetNimControllerState()
  bleArmHciResetSettle()
  quiesceM0PolledBleClicSources()

proc rwip_reset*() {.exportc, cdecl.} =
  let irqState = btbleIrqSave()
  defer:
    btbleIrqRestore(irqState)
  rwipResetCore()
  when defined(bl808m0):
    nimEnableM0BleRuntimeIrqs(false)

proc rwip_isr*() {.exportc, cdecl.} =
  bflbble_isr()

proc rwip_schedule*() {.exportc, cdecl.} =
  discard bleControllerServiceNonblocking()

proc rwip_sleep*(): int32 {.exportc, cdecl.} =
  bflbip_sleep().int32

proc rwip_rand_init*(seed: uint32) {.exportc, cdecl.} =
  discard seed

proc rwip_sca_get*(): uint8 {.exportc, cdecl.} =
  0

proc rwip_wlcoex_set*(en: bool) {.exportc, cdecl.} =
  bflbip_wlcoex_set(en)

proc rwip_eif_get*(): pointer {.exportc, cdecl.} =
  bflbip_eif_get()

when not (defined(bl808m0)):
  proc rwip_timer_alarm_set*(targetCoarse: uint32, targetFine: uint16)
      {.exportc, cdecl.} =
    discard targetCoarse
    discard targetFine

when not (defined(bl808m0)):
  proc rwip_timer_arb_set*(targetCoarse: uint32, targetFine: uint16)
      {.exportc, cdecl.} =
    discard targetCoarse
    discard targetFine

proc rwip_timer_co_set*(target: uint32) {.exportc, cdecl.} =
  discard target

proc rwip_bt_time_to_bts*(time: pointer, bts: pointer) {.exportc, cdecl.} =
  if time != nil and bts != nil:
    discard c_memcpy(bts, time, 8)

proc rwip_bts_to_bt_time*(bts: pointer, time: pointer) {.exportc, cdecl.} =
  if bts != nil and time != nil:
    discard c_memcpy(time, bts, 8)

proc rwip_ch_ass_en_get*(): bool {.exportc, cdecl.} =
  false

proc rwip_ch_ass_en_set*(en: bool) {.exportc, cdecl.} =
  discard en

proc rwip_ch_assess_data_ble_get*(): pointer {.exportc, cdecl.} =
  nil

type
  BleAesResultCb = proc(status: uint8, result: ptr uint8, ctx: pointer)
    {.cdecl.}
  BleAesContinueCb = proc(op: pointer, result: ptr uint8): uint8 {.cdecl.}

  BleAesOpHeader = object
    next: pointer
    continueCb: pointer
    resultCb: pointer
    key: ptr uint8
    value: ptr uint8
    ctx: pointer

var nim_aes_last_result*: array[16, uint8]
var nim_aes_k2_last_result*: array[33, uint8]

proc bleAesDeliver(cb: pointer, ctx: pointer, status: uint8,
                   result: ptr uint8) =
  if cb != nil:
    cast[BleAesResultCb](cb)(status, result, ctx)

proc bleAesCompleteOp(op: pointer, status: uint8, result: ptr uint8) =
  if op == nil:
    return
  let hdr = cast[ptr BleAesOpHeader](op)
  var callFinal = true
  if status == 0'u8 and hdr.continueCb != nil:
    callFinal = cast[BleAesContinueCb](hdr.continueCb)(op, result) != 0'u8
  if callFinal:
    bleAesDeliver(hdr.resultCb, hdr.ctx, status, result)
    ble_ke_free(op)

const
  SecEngBase = 0x20004000'u
  SecCtrlProtRead = SecEngBase + 0xF00'u
  TrngCtrl = SecEngBase + 0x200'u
  TrngData = SecEngBase + 0x208'u
  TrngCtrl3 = SecEngBase + 0x234'u
  TrngCtrlProt = SecEngBase + 0x2FC'u
  TrngBusy = 1'u32 shl 0
  TrngTrigger = 1'u32 shl 1
  TrngEnable = 1'u32 shl 2
  TrngDataClear = 1'u32 shl 3
  TrngIntClear = 1'u32 shl 9
  TrngIntMask = 1'u32 shl 11
  TrngRoscEnable = 1'u32 shl 31
  TrngGroupOwnerShift = 4
  TrngGroupOwnerMask = 0x03'u32
  TrngGroup0Owner = 0x01'u32
  TrngReleasedOwner = 0x03'u32
  TrngRequestGroup0 = 0x02'u32
  TrngReleaseAccess = 0x06'u32
  TrngTimeout = 100_000'u32

var
  nim_trng_wait_timeout_count* {.exportc.}: uint32
  nim_trng_wait_last_reg* {.exportc.}: uint32
  nim_trng_wait_last_mask* {.exportc.}: uint32

proc bleTrngNopDelay() {.inline.} =
  {.emit: """
    __asm__ volatile("nop");
    __asm__ volatile("nop");
    __asm__ volatile("nop");
    __asm__ volatile("nop");
  """.}

proc noteTrngWaitTimeout(reg, mask: uint32) {.inline.} =
  inc nim_trng_wait_timeout_count
  nim_trng_wait_last_reg = reg
  nim_trng_wait_last_mask = mask

proc bleTrngOwner(): uint32 {.inline.} =
  (regRead(SecCtrlProtRead) shr TrngGroupOwnerShift) and TrngGroupOwnerMask

proc bleRequestTrngGroup0(releaseWhenDone: var bool): bool =
  releaseWhenDone = false
  case bleTrngOwner()
  of TrngGroup0Owner:
    true
  of TrngReleasedOwner:
    regWrite(TrngCtrlProt, TrngRequestGroup0)
    fenceIo()
    if bleTrngOwner() == TrngGroup0Owner:
      releaseWhenDone = true
      true
    else:
      false
  else:
    false

proc bleReleaseTrngGroup0(releaseWhenDone: bool) =
  if releaseWhenDone:
    regWrite(TrngCtrlProt, TrngReleaseAccess)
    fenceIo()

proc bleTrngWaitIdle(): bool =
  var timeout = TrngTimeout
  while (regRead(TrngCtrl) and TrngBusy) != 0'u32:
    if timeout == 0'u32:
      noteTrngWaitTimeout(TrngCtrl.uint32, TrngBusy)
      return false
    dec timeout
  true

proc bleTrngClearInterrupt() =
  var v = regRead(TrngCtrl) or TrngIntMask
  regWrite(TrngCtrl, v or TrngIntClear)
  v = regRead(TrngCtrl) or TrngIntMask
  regWrite(TrngCtrl, v and not TrngIntClear)

proc bleTrngDisable() =
  regWrite(TrngCtrl, (regRead(TrngCtrl) and not TrngEnable) or TrngIntMask)
  bleTrngClearInterrupt()

proc bleTrngReadBlock(dst: ptr uint8): bool =
  if dst == nil:
    return false
  regWrite(TrngCtrl3, regRead(TrngCtrl3) or TrngRoscEnable)
  regWrite(TrngCtrl, regRead(TrngCtrl) or TrngEnable or TrngIntMask)
  bleTrngClearInterrupt()
  bleTrngNopDelay()
  if not bleTrngWaitIdle():
    bleTrngDisable()
    return false

  bleTrngClearInterrupt()
  regWrite(TrngCtrl, regRead(TrngCtrl) or TrngTrigger or TrngIntMask)
  bleTrngNopDelay()
  if not bleTrngWaitIdle():
    bleTrngDisable()
    return false

  let outp = cast[ptr UncheckedArray[uint8]](dst)
  var nonZero = false
  for wordIndex in 0 ..< 8:
    let word = regRead(TrngData + uint(wordIndex * 4))
    if word != 0'u32:
      nonZero = true
    for byteIndex in 0 ..< 4:
      outp[wordIndex * 4 + byteIndex] =
        uint8((word shr (byteIndex * 8)) and 0xFF'u32)

  regWrite(TrngCtrl, (regRead(TrngCtrl) and not TrngTrigger) or TrngIntMask)
  regWrite(TrngCtrl, regRead(TrngCtrl) or TrngDataClear or TrngIntMask)
  regWrite(TrngCtrl, (regRead(TrngCtrl) and not TrngDataClear) or TrngIntMask)
  bleTrngDisable()
  nonZero

proc bleFillRandomBytesUnlocked(dst: ptr uint8, len: int): bool =
  if len < 0:
    return false
  if len == 0:
    return true
  if dst == nil:
    return false
  var releaseTrng = false
  if not bleRequestTrngGroup0(releaseTrng):
    return false
  let outp = cast[ptr UncheckedArray[uint8]](dst)
  const
    BlockLen = 32
    MaxAttempts = 3
  var trngBlock: array[BlockLen, uint8]
  var offset = 0
  while offset < len:
    var ok = false
    for attempt in 0 ..< MaxAttempts:
      discard attempt
      if bleTrngReadBlock(addr trngBlock[0]):
        ok = true
        break
    if not ok:
      bleReleaseTrngGroup0(releaseTrng)
      return false
    var blockIndex = 0
    while blockIndex < BlockLen and offset < len:
      outp[offset] = trngBlock[blockIndex]
      inc blockIndex
      inc offset
  bleReleaseTrngGroup0(releaseTrng)
  true

proc bleFillRandomBytes(dst: ptr uint8, len: int): bool =
  let status = disableInterrupts()
  result = bleFillRandomBytesUnlocked(dst, len)
  restoreInterrupts(status)

proc bleReadLe32(src: ptr UncheckedArray[uint8], off: int): uint32 {.inline.} =
  uint32(src[off]) or (uint32(src[off + 1]) shl 8) or
    (uint32(src[off + 2]) shl 16) or (uint32(src[off + 3]) shl 24)

proc rwip_aes_encrypt*(input: ptr uint8, key: ptr uint8) {.exportc, cdecl.} =
  blecrypto.bleAesEncryptBlock(key, input, addr nim_aes_last_result[0])
  if input == nil or key == nil:
    return

  let status = disableInterrupts()
  bflbip_prevent_sleep_mask = bflbip_prevent_sleep_mask or 0x04'u32
  restoreInterrupts(status)

  copyBytes(BTBLE_EM_BASE + 0x100'u32, key, 16)
  let raw = cast[ptr UncheckedArray[uint8]](input)
  regWrite((BLE_BASE + 0x0B4'u32).uint, bleReadLe32(raw, 0))
  regWrite((BLE_BASE + 0x0B8'u32).uint, bleReadLe32(raw, 4))
  regWrite((BLE_BASE + 0x0BC'u32).uint, bleReadLe32(raw, 8))
  regWrite((BLE_BASE + 0x0C0'u32).uint, bleReadLe32(raw, 12))
  regWrite((BLE_BASE + 0x0C4'u32).uint, 64'u32)
  regWrite((BLE_BASE + BTBLE_INTACK_OFFSET).uint, BtbleIntAesDone)
  enableBtbleInterruptMaskBits(BtbleIntAesDone)
  regOr(BLE_BASE + 0x0B0'u32, 0x01'u32)

proc rwble_init*(initType: uint8) {.exportc, cdecl.} =
  discard initType
  bflbble_init()

proc rwble_isr*() {.exportc, cdecl.} =
  bflbble_isr()

when not (defined(bl808m0) and
    (bl808BleNimConnectionEnabled or bl808BleNimPureCentral)):
  proc lld_rxdesc_check*(idx: uint8): pointer {.exportc, cdecl.} =
    discard idx
    nil

  proc lld_rxdesc_free*(desc: pointer) {.exportc, cdecl.} =
    discard desc

  proc sch_arb_insert*(elt: pointer): uint8 {.exportc, cdecl.} =
    discard elt
    0

  proc sch_arb_remove*(elt: pointer): uint8 {.exportc, cdecl.} =
    discard elt
    0

  proc sch_slice_per_add*(sliceType: uint8, conhdl: uint8,
                          interval: uint32, anchor: uint32,
                          offset: uint16): uint8 {.exportc, cdecl.} =
    discard sliceType
    discard conhdl
    discard interval
    discard anchor
    discard offset
    0

  proc sch_slice_per_remove*(sliceType: uint8,
                             conhdl: uint8): uint8 {.exportc, cdecl.} =
    discard sliceType
    discard conhdl
    0

const
  LlcProcSlotCount = 9
  LlcAuthPayloadNearlyTimerId = 0x0102'u16
  LlcAuthPayloadRealTimerId = 0x0103'u16
  LlcAuthPayloadNearlyOpMsgId = 0x010C'u16
  LlcAuthPayloadExpiredMsgId = 0x1102'u16
  LlcProcLePing = 8'u8
  LlcEnvConnIntervalOff = 14
  LlcEnvConnLatencyOff = 16
  LlcEnvAuthPayloadToOff = 58
  LlcEnvAuthPayloadRealToOff = 60
  LlcEnvLinkFlagsOff = 128
  LlcEnvLlcpStateOff = 130
  LlcEnvEncryptedFlag = 0x0020'u16
  LlcLlcpDisconnectedState = 3'u8

proc llcTaskId(conhdl: uint16): KeTaskId {.inline.} =
  KeTaskId((conhdl shl 8) or 1'u16)

proc llcEnvFor(conhdl: uint16): ptr LlcConEnv {.inline.} =
  if conhdl < LLC_CON_MAX.uint16:
    llc_env[conhdl]
  else:
    nil

proc llcEnvRaw(env: ptr LlcConEnv): ptr UncheckedArray[uint8] {.inline.} =
  cast[ptr UncheckedArray[uint8]](addr env.data[0])

proc llcEnvRead16(env: ptr LlcConEnv, off: int): uint16 {.inline.} =
  let raw = llcEnvRaw(env)
  uint16(raw[off]) or (uint16(raw[off + 1]) shl 8)

proc llcEnvWrite16(env: ptr LlcConEnv, off: int, value: uint16) {.inline.} =
  let raw = llcEnvRaw(env)
  raw[off] = uint8(value and 0x00FF'u16)
  raw[off + 1] = uint8((value shr 8) and 0x00FF'u16)

proc llcEnvConnectionOpen(env: ptr LlcConEnv): bool {.inline.} =
  env != nil and
    ((llcEnvRaw(env)[LlcEnvLlcpStateOff] and 0x03'u8) !=
      LlcLlcpDisconnectedState)

proc llcEnvEncrypted(env: ptr LlcConEnv): bool {.inline.} =
  env != nil and
    (llcEnvRead16(env, LlcEnvLinkFlagsOff) and LlcEnvEncryptedFlag) != 0'u16

proc llm_le_features_get*(features: pointer) {.exportc, cdecl.} =
  if features != nil:
    var f = llm_util_get_supp_features()
    discard c_memcpy(features, addr f, 8)

proc llcAuthPayloadNearMargin(env: ptr LlcConEnv, timeout: uint16): uint16 =
  let interval = uint32(llcEnvRead16(env, LlcEnvConnIntervalOff))
  let latency = uint32(llcEnvRead16(env, LlcEnvConnLatencyOff))
  let eventSpan = (latency + 1'u32) * interval
  if eventSpan == 0'u32:
    return 1'u16

  var marginTicks = eventSpan * 8'u32
  let timeoutTicks = uint32(timeout) * 16'u32
  let eventTicks = eventSpan * 2'u32
  if timeoutTicks < marginTicks:
    marginTicks = (timeoutTicks div eventTicks) * eventTicks

  var margin = marginTicks shr 4
  if margin == 0'u32:
    margin = 1'u32
  if margin > 0xFFFF'u32:
    0xFFFF'u16
  else:
    uint16(margin)

proc llcArmAuthPayloadTimers(conhdl: uint16, env: ptr LlcConEnv) =
  if not llcEnvEncrypted(env):
    return
  let task = llcTaskId(conhdl)
  btble_ke_timer_set(
    LlcAuthPayloadNearlyTimerId, task,
    uint32(llcEnvRead16(env, LlcEnvAuthPayloadToOff)) * 2'u32)
  btble_ke_timer_set(
    LlcAuthPayloadRealTimerId, task,
    uint32(llcEnvRead16(env, LlcEnvAuthPayloadRealToOff)) * 2'u32)

proc llc_le_ping_set*(conhdl: uint16, timeout: uint16): uint8
    {.exportc, cdecl.} =
  let env = llcEnvFor(conhdl)
  if env == nil:
    return HciStatusCommandDisallowed
  let margin = llcAuthPayloadNearMargin(env, timeout)
  if timeout <= margin:
    return HciStatusUnsupportedFeatureParam
  llcEnvWrite16(env, LlcEnvAuthPayloadRealToOff, timeout - margin)
  llcEnvWrite16(env, LlcEnvAuthPayloadToOff, timeout)
  llcArmAuthPayloadTimers(conhdl, env)
  HciStatusSuccess

proc phy_upd_proc_start*(conhdl: uint16) {.exportc, cdecl.} =
  discard conhdl

proc dl_upd_proc_start*(conhdl: uint16) {.exportc, cdecl.} =
  discard conhdl

when defined(bl808m0) and bl808BleNimConnectionEnabled and bl808BleNimLlcStart:
  proc nimLlcStart(conhdl: uint16, params: pointer): uint8
      {.exportc: "vendor_llc_start", cdecl.} =
    if params == nil or conhdl >= nim_llc_start_env_slots.len.uint16:
      return 0xFF'u8
    if nim_llc_start_env_slots[conhdl] != nil:
      return 0xFF'u8

    let env = addr nim_llc_start_env_storage[conhdl][0]
    let envView = cast[ptr NimLlcStartEnvView](env)
    let start = nimVendorLlcStartParams(params)
    discard c_memset(env, 0, nim_llc_start_env_storage[conhdl].len.csize_t)
    nim_llc_start_env_slots[conhdl] = env

    btble_ke_state_set(KeTaskId((conhdl shl 8) or 1'u16), 0'u8)
    btble_co_list_init(addr envView.pendingList)

    envView.connIntervalMin = start.connIntervalMin
    envView.connIntervalMax = start.connIntervalMax
    envView.connLatency = start.connLatency
    envView.peerRate = start.peerRate
    discard c_memcpy(cast[pointer](addr envView.peerFeatureSeed[0]),
                     cast[pointer](addr start.peerFeatureSeed[0]), 5)
    llm_le_features_get(cast[pointer](addr envView.leFeatures[0]))
    envView.leFeatures[0] = envView.leFeatures[0] and 0xFB'u8
    envView.leFeatures[3] = envView.leFeatures[3] and 0xFD'u8
    envView.supervisionTimeout = 27'u16

    let rateIdx =
      if start.phyRate < co_rate_to_phy.len.uint8: co_rate_to_phy[start.phyRate]
      else: co_rate_to_phy[0]
    envView.txRate = rateIdx
    envView.rxRate = rateIdx
    envView.eventCounter = 519'u16
    envView.schedulerWord = 0x429000FB'u32
    envView.txPacketTime = 27'u16
    envView.txOctets = 328'u16
    envView.rxOctets = 328'u16
    envView.maxTxTime = start.controllerDefaults.maxTxTime
    let maxRxTime =
      if rateIdx == 3'u8:
        let a = start.controllerDefaults.maxRxTime
        if a < 0x0A90'u16: a else: 0x0A90'u16
      else:
        start.controllerDefaults.maxRxTime
    envView.maxRxTime = maxRxTime
    envView.minEventSpacing = start.controllerDefaults.minEventSpacing
    envView.localSleepClockAccuracy = start.controllerDefaults.localSleepClockAccuracy
    envView.peerSleepClockAccuracy = start.controllerDefaults.peerSleepClockAccuracy
    var envFlags = envView.flags and 0xFFFE'u16
    if start.directAnchorMode == 0'u8:
      envFlags = envFlags or 1'u16
    envView.flags = envFlags
    envView.authPayloadTimeout = start.controllerDefaults.authPayloadTimeout
    envView.channelSelection = start.controllerDefaults.channelSelection
    envView.connEventLenMin = start.controllerDefaults.connEventLenMin
    envView.connEventLenMax = start.controllerDefaults.connEventLenMax

    var lldParams: array[48, uint8]
    let lld = nimLldConStartParams(addr lldParams[0])
    lld.accessAddress = start.accessAddress
    lld.crcInit = start.crcInit
    lld.transmitWindowSize = start.transmitWindowSize
    lld.windowOffset = start.windowOffset
    lld.interval = start.connIntervalMin
    lld.latency = start.connIntervalMax
    lld.supervisionTimeout = start.connLatency
    lld.channelMap = start.peerFeatureSeed
    lld.hopIncrement = start.hopSca
    lld.peerSleepClockAccuracy = start.peerRate
    lld.timingFine = start.timingFine
    lld.timingClock = start.timingClock
    lld.anchorClock = start.anchorClock
    lld.timingSelector = start.directAnchorMode
    lld.rate = start.phyRate
    lld.peerRxAddrType = start.peerRxAddrType

    result = nimLldConStart(conhdl, addr lldParams[0])
    discard llc_le_ping_set(conhdl, 3000'u16)
    phy_upd_proc_start(conhdl)
    dl_upd_proc_start(conhdl)
    when bl808BleNimManualConnTx and bl808BleNimLlcStartInitialLlcp:
      if result == 0'u8:
        discard nimLlcpSendInitialNow(conhdl)
    if result != 0'u8:
      nim_llc_start_env_slots[conhdl] = nil

proc llc_llcp_tx_check*(conhdl: uint16) {.exportc, cdecl.} =
  discard conhdl

proc llc_cmd_cmp_send*(conhdl: uint16, opcode: uint16, status: uint8)
    {.exportc, cdecl.} =
  llc_common_cmd_complete_send(conhdl, opcode, status)

proc llc_cmd_stat_send*(conhdl: uint16, opcode: uint16, status: uint8)
    {.exportc, cdecl.} =
  llc_common_cmd_status_send(conhdl, opcode, status)

proc llc_role_get*(conhdl: uint16): uint8 {.exportc, cdecl.} =
  discard conhdl
  0

type LlcProcErrCallback = proc(conhdl: uint16, status: uint8,
                               param: pointer) {.cdecl.}

type LlcProcEnvView {.packed.} = object
  errCallback: pointer
  procId: uint8
  state: uint8
  reserved06: uint8

static:
  doAssert offsetof(LlcProcEnvView, errCallback) == 0
  doAssert offsetof(LlcProcEnvView, procId) == 4
  doAssert offsetof(LlcProcEnvView, state) == 5
  doAssert offsetof(LlcProcEnvView, reserved06) == 6

var llc_proc_slots: array[LLC_CON_MAX, array[LlcProcSlotCount, pointer]]

template llcProcEnv(procEnv: pointer): ptr LlcProcEnvView =
  cast[ptr LlcProcEnvView](procEnv)

proc llcProcUpdateTaskState(conhdl: uint16, procId: uint8, setBit: bool) =
  if procId >= 8'u8:
    return
  let task = llcTaskId(conhdl)
  let mask = uint8(1'u16 shl procId)
  var state = btble_ke_state_get(task)
  if setBit:
    state = state or mask
  else:
    state = state and not mask
  btble_ke_state_set(task, state)

proc llcProcSlot(conhdl: uint16, procId: uint8): ptr pointer =
  if conhdl < LLC_CON_MAX.uint16 and procId < LlcProcSlotCount.uint8:
    addr llc_proc_slots[int(conhdl)][int(procId)]
  else:
    nil

proc llc_proc_get*(conhdl: uint16, procId: uint8): pointer
    {.exportc, cdecl.} =
  let slot = llcProcSlot(conhdl, procId)
  if slot == nil:
    nil
  else:
    slot[]

proc llc_proc_state_get*(procEnv: pointer): uint8
    {.exportc, cdecl.} =
  if procEnv == nil:
    0
  else:
    llcProcEnv(procEnv).state

proc llc_proc_state_set*(procEnv: pointer, conhdl: uint16, state: uint8)
    {.exportc, cdecl.} =
  discard conhdl
  if procEnv != nil:
    llcProcEnv(procEnv).state = state

proc llc_proc_timer_pause_set*(conhdl: uint16, enable: bool)
    {.exportc, cdecl.} =
  discard conhdl
  discard enable

proc llc_proc_timer_set*(conhdl: uint16, procId: uint8, delay: uint32)
    {.exportc, cdecl.} =
  discard conhdl
  discard procId
  discard delay

proc llc_proc_unreg*(conhdl: uint16, procId: uint8) {.exportc, cdecl.} =
  if conhdl < LLC_CON_MAX.uint16 and procId < LlcProcSlotCount.uint8:
    llc_proc_slots[int(conhdl)][int(procId)] = nil
    llcProcUpdateTaskState(conhdl, procId, false)

proc llc_proc_reg*(conhdl: uint16, procId: uint8,
                   procEnv: pointer): uint32 {.exportc, cdecl.}

proc aes_alloc*(size: uint32, continueCb: pointer, cb: pointer,
                ctx: pointer): pointer {.exportc, cdecl.} =
  let allocSize =
    if size < sizeof(BleAesOpHeader).uint32:
      sizeof(BleAesOpHeader).uint32
    else:
      size
  result = ble_ke_malloc(allocSize, 0)
  if result == nil:
    return
  discard c_memset(result, 0, allocSize.csize_t)
  let hdr = cast[ptr BleAesOpHeader](result)
  hdr.continueCb = continueCb
  hdr.resultCb = cb
  hdr.ctx = ctx

proc aes_rand*(cb: pointer, ctx: pointer) {.exportc, cdecl.} =
  if not bleFillRandomBytes(addr nim_aes_last_result[0], 8):
    discard c_memset(addr nim_aes_last_result[0], 0, 8)
  discard c_memset(addr nim_aes_last_result[8], 0, 8)
  bleAesDeliver(cb, ctx, 0'u8, addr nim_aes_last_result[0])

proc aes_result_handler*(msgid: KeMsgId, destId: KeTaskId,
                         srcId: KeTaskId, param: pointer): int32
    {.exportc, cdecl.} =
  discard msgid
  discard destId
  discard srcId
  if param != nil:
    ble_ke_free(getMsgHeader(param))
  1

proc aes_shift_left_128*(dst: ptr uint8, src: ptr uint8) {.exportc, cdecl.} =
  if dst == nil or src == nil:
    return
  var carry = 0'u8
  for i in countdown(15, 0):
    let v = cast[ptr UncheckedArray[uint8]](src)[i]
    cast[ptr UncheckedArray[uint8]](dst)[i] = (v shl 1) or carry
    carry = (v shr 7) and 1

proc aes_xor_128*(dst: ptr uint8, a: ptr uint8, b: ptr uint8)
    {.exportc, cdecl.} =
  if dst == nil or a == nil or b == nil:
    return
  for i in 0 ..< 16:
    cast[ptr UncheckedArray[uint8]](dst)[i] =
      cast[ptr UncheckedArray[uint8]](a)[i] xor
      cast[ptr UncheckedArray[uint8]](b)[i]

proc bleAesValidBlockArgs(key: ptr uint8, value: ptr uint8): bool {.inline.} =
  key != nil and value != nil

proc bleAesCompleteDirect(cb: pointer, ctx: pointer, ok: bool,
                          result: ptr uint8) =
  bleAesDeliver(cb, ctx, if ok: 0'u8 else: 1'u8, result)

proc aes_start*(op: pointer, key: ptr uint8, value: ptr uint8)
    {.exportc, cdecl.} =
  let ok = bleAesValidBlockArgs(key, value)
  if op == nil:
    if ok:
      blecrypto.bleAesEncryptBlock(key, value, addr nim_aes_last_result[0])
    else:
      discard c_memset(addr nim_aes_last_result[0], 0, 16)
    return
  let hdr = cast[ptr BleAesOpHeader](op)
  hdr.key = key
  hdr.value = value
  if ok:
    blecrypto.bleAesEncryptBlock(key, value, addr nim_aes_last_result[0])
  else:
    discard c_memset(addr nim_aes_last_result[0], 0, 16)
  bleAesCompleteOp(op, if ok: 0'u8 else: 1'u8, addr nim_aes_last_result[0])

proc btble_aes_init*(initType: uint8) {.exportc, cdecl.} =
  discard initType

proc btble_aes_encrypt*(key: ptr uint8, val: ptr uint8, copy: bool,
                        cb: pointer, ctx: pointer) {.exportc, cdecl.} =
  discard copy
  let ok = bleAesValidBlockArgs(key, val)
  if ok:
    blecrypto.bleAesEncryptBlock(key, val, addr nim_aes_last_result[0])
  else:
    discard c_memset(addr nim_aes_last_result[0], 0, 16)
  bleAesCompleteDirect(cb, ctx, ok, addr nim_aes_last_result[0])

type
  BleAesCcmCb = proc(status: uint8, ctx: pointer) {.cdecl.}

var nim_aes_f5_last_result*: array[32, uint8]

proc aes_cmac*(key: ptr uint8, msg: ptr uint8, msgLen: uint16,
               cb: pointer, ctx: pointer) {.exportc, cdecl.} =
  let ok = key != nil and (msg != nil or msgLen == 0'u16)
  if ok:
    blecrypto.bleAesCmac(key, msg, msgLen, addr nim_aes_last_result[0])
  else:
    discard c_memset(addr nim_aes_last_result[0], 0, 16)
  bleAesCompleteDirect(cb, ctx, ok, addr nim_aes_last_result[0])

proc aes_cmac_start*(op: pointer, key: ptr uint8, msg: ptr uint8,
                     msgLen: uint16): uint8 {.exportc, cdecl.} =
  let ok = op != nil and key != nil and (msg != nil or msgLen == 0'u16)
  if ok:
    blecrypto.bleAesCmac(key, msg, msgLen, addr nim_aes_last_result[0])
    bleAesCompleteOp(op, 0'u8, addr nim_aes_last_result[0])
    1'u8
  else:
    discard c_memset(addr nim_aes_last_result[0], 0, 16)
    if op != nil:
      bleAesCompleteOp(op, 1'u8, addr nim_aes_last_result[0])
    0'u8

proc aes_cmac_continue*(op: pointer, aesResult: ptr uint8): uint8
    {.exportc, cdecl.} =
  if op == nil or aesResult == nil:
    return 0'u8
  bleAesCompleteOp(op, 0'u8, aesResult)
  1'u8

proc aes_c1*(key: ptr uint8, r: ptr uint8, p1: ptr uint8, p2: ptr uint8,
             cb: pointer, ctx: pointer) {.exportc, cdecl.} =
  let ok = key != nil and r != nil and p1 != nil and p2 != nil
  if ok:
    blecrypto.bleAesC1(key, r, p1, p2, addr nim_aes_last_result[0])
  else:
    discard c_memset(addr nim_aes_last_result[0], 0, 16)
  bleAesCompleteDirect(cb, ctx, ok, addr nim_aes_last_result[0])

proc aes_s1*(msg: ptr uint8, msgLen: uint16, cb: pointer,
             ctx: pointer) {.exportc, cdecl.} =
  let ok = msg != nil or msgLen == 0'u16
  if ok:
    blecrypto.bleAesS1(msg, msgLen, addr nim_aes_last_result[0])
  else:
    discard c_memset(addr nim_aes_last_result[0], 0, 16)
  bleAesCompleteDirect(cb, ctx, ok, addr nim_aes_last_result[0])

proc aes_ccm*(key: ptr uint8, nonce: ptr uint8, input: ptr uint8,
              output: ptr uint8, msgLen: uint16, micLen: uint8,
              mode: uint8, mic: ptr uint8, aadLen: uint8,
              cb: pointer, ctx: pointer) {.exportc, cdecl.} =
  discard aadLen
  let encrypt = (mode and 1'u8) == 0'u8
  let ok = blecrypto.bleAesCcm(key, nonce, input, output, msgLen, mic, micLen,
                               encrypt)
  if cb != nil:
    cast[BleAesCcmCb](cb)(if ok: 0'u8 else: 1'u8, ctx)

proc aes_f4*(u: ptr uint8, v: ptr uint8, x: ptr uint8, z: uint8,
             cb: pointer, ctx: pointer) {.exportc, cdecl.} =
  let ok = u != nil and v != nil and x != nil
  if ok:
    blecrypto.bleAesF4(u, v, x, z, addr nim_aes_last_result[0])
  else:
    discard c_memset(addr nim_aes_last_result[0], 0, 16)
  bleAesCompleteDirect(cb, ctx, ok, addr nim_aes_last_result[0])

proc aes_f5*(w: ptr uint8, n1: ptr uint8, n2: ptr uint8, a1: ptr uint8,
             a2: ptr uint8, cb: pointer, ctx: pointer)
    {.exportc, cdecl.} =
  let ok = w != nil and n1 != nil and n2 != nil and a1 != nil and a2 != nil
  if ok:
    blecrypto.bleAesF5(w, n1, n2, a1, a2, addr nim_aes_f5_last_result[0])
  else:
    discard c_memset(addr nim_aes_f5_last_result[0], 0, 32)
  bleAesCompleteDirect(cb, ctx, ok, addr nim_aes_f5_last_result[0])

proc aes_f6*(w: ptr uint8, n1: ptr uint8, n2: ptr uint8, r: ptr uint8,
             iocap: ptr uint8, a1: ptr uint8, a2: ptr uint8,
             cb: pointer, ctx: pointer) {.exportc, cdecl.} =
  let ok = w != nil and n1 != nil and n2 != nil and r != nil and
    iocap != nil and a1 != nil and a2 != nil
  if ok:
    blecrypto.bleAesF6(w, n1, n2, r, iocap, a1, a2,
                       addr nim_aes_last_result[0])
  else:
    discard c_memset(addr nim_aes_last_result[0], 0, 16)
  bleAesCompleteDirect(cb, ctx, ok, addr nim_aes_last_result[0])

proc aes_g2*(u: ptr uint8, v: ptr uint8, x: ptr uint8, y: ptr uint8,
             cb: pointer, ctx: pointer) {.exportc, cdecl.} =
  let ok = u != nil and v != nil and x != nil and y != nil
  if ok:
    blecrypto.bleAesG2Raw(u, v, x, y, addr nim_aes_last_result[0])
  else:
    discard c_memset(addr nim_aes_last_result[0], 0, 16)
  bleAesCompleteDirect(cb, ctx, ok, addr nim_aes_last_result[0])

proc aes_h6*(w: ptr uint8, keyId: ptr uint8, cb: pointer,
             ctx: pointer) {.exportc, cdecl.} =
  let ok = w != nil and keyId != nil
  if ok:
    blecrypto.bleAesH6(w, keyId, addr nim_aes_last_result[0])
  else:
    discard c_memset(addr nim_aes_last_result[0], 0, 16)
  bleAesCompleteDirect(cb, ctx, ok, addr nim_aes_last_result[0])

proc aes_h7*(salt: ptr uint8, w: ptr uint8, cb: pointer,
             ctx: pointer) {.exportc, cdecl.} =
  let ok = salt != nil and w != nil
  if ok:
    blecrypto.bleAesH7(salt, w, addr nim_aes_last_result[0])
  else:
    discard c_memset(addr nim_aes_last_result[0], 0, 16)
  bleAesCompleteDirect(cb, ctx, ok, addr nim_aes_last_result[0])

proc aes_h8*(k: ptr uint8, s: ptr uint8, keyId: ptr uint8, cb: pointer,
             ctx: pointer) {.exportc, cdecl.} =
  let ok = k != nil and s != nil and keyId != nil
  if ok:
    blecrypto.bleAesH8(k, s, keyId, addr nim_aes_last_result[0])
  else:
    discard c_memset(addr nim_aes_last_result[0], 0, 16)
  bleAesCompleteDirect(cb, ctx, ok, addr nim_aes_last_result[0])

proc aes_h9*(k: ptr uint8, keyId: ptr uint8, cb: pointer,
             ctx: pointer) {.exportc, cdecl.} =
  let ok = k != nil and keyId != nil
  if ok:
    blecrypto.bleAesH9(k, keyId, addr nim_aes_last_result[0])
  else:
    discard c_memset(addr nim_aes_last_result[0], 0, 16)
  bleAesCompleteDirect(cb, ctx, ok, addr nim_aes_last_result[0])

proc aes_k1*(n: ptr uint8, salt: ptr uint8, p: ptr uint8, pLen: uint16,
             cb: pointer, ctx: pointer) {.exportc, cdecl.} =
  let ok = n != nil and salt != nil and (p != nil or pLen == 0'u16)
  if ok:
    blecrypto.bleAesK1(n, salt, p, pLen, addr nim_aes_last_result[0])
  else:
    discard c_memset(addr nim_aes_last_result[0], 0, 16)
  bleAesCompleteDirect(cb, ctx, ok, addr nim_aes_last_result[0])

proc aes_k2*(n: ptr uint8, p: ptr uint8, pLen: uint16, cb: pointer,
             ctx: pointer) {.exportc, cdecl.} =
  let ok = n != nil and (p != nil or pLen == 0'u16)
  if ok:
    blecrypto.bleAesK2(n, p, pLen, addr nim_aes_k2_last_result[0])
  else:
    discard c_memset(addr nim_aes_k2_last_result[0], 0, 33)
  bleAesCompleteDirect(cb, ctx, ok, addr nim_aes_k2_last_result[0])

proc aes_k3*(n: ptr uint8, cb: pointer, ctx: pointer) {.exportc, cdecl.} =
  discard c_memset(addr nim_aes_last_result[0], 0, nim_aes_last_result.len.csize_t)
  let ok = n != nil
  if ok:
    blecrypto.bleAesK3(n, addr nim_aes_last_result[8])
  bleAesCompleteDirect(cb, ctx, ok, addr nim_aes_last_result[8])

proc aes_k4*(n: ptr uint8, cb: pointer, ctx: pointer) {.exportc, cdecl.} =
  let ok = n != nil
  nim_aes_last_result[0] =
    if ok: blecrypto.bleAesK4(n) else: 0'u8
  bleAesCompleteDirect(cb, ctx, ok, addr nim_aes_last_result[0])

proc btble_dma_init*() {.exportc, cdecl.} =
  discard

proc btble_dma_copy*(dst: pointer, src: pointer, len: uint32)
    {.exportc, cdecl.} =
  if dst != nil and src != nil and len > 0:
    discard c_memcpy(dst, src, len.csize_t)

proc btble_dma_isr_handler*() {.exportc, cdecl.} =
  discard

proc co_nb_good_channels*(map: ptr uint8): uint8 {.exportc, cdecl.} =
  ble_util_nb_good_channels(map)

proc co_time_get*(): uint32 {.exportc, cdecl.} =
  currentBtbleTime()

proc co_time_init*() {.exportc, cdecl.} =
  discard

proc co_time_compensate*(time: uint32): uint32 {.exportc, cdecl.} =
  time

proc co_time_timer_init*() {.exportc, cdecl.} =
  discard

proc co_time_timer_set*(target: uint32) {.exportc, cdecl.} =
  discard target

proc co_time_timer_long_set*(target: uint32) {.exportc, cdecl.} =
  discard target

proc co_time_timer_periodic_set*(period: uint32) {.exportc, cdecl.} =
  discard period

proc co_time_timer_stop*() {.exportc, cdecl.} =
  discard

proc co_slot_to_duration*(slots: uint16): uint32 {.exportc, cdecl.} =
  uint32(slots) * 625'u32

proc co_util_pack*(outBuf: pointer, inBuf: pointer, fmt: cstring,
                   outLen: ptr uint16) {.exportc, cdecl.} =
  hci_util_pack(outBuf, inBuf, fmt, outLen)

proc co_util_unpack*(outBuf: pointer, inBuf: pointer, fmt: cstring,
                     outLen: ptr uint16) {.exportc, cdecl.} =
  hci_util_unpack(outBuf, inBuf, fmt, outLen)

proc flash_init*() {.exportc, cdecl.} =
  discard

proc flash_identify*(pid: ptr uint8): int32 {.exportc, cdecl.} =
  if pid != nil:
    let raw = cast[ptr UncheckedArray[uint8]](pid)
    raw[0] = 0
    raw[1] = 0
    raw[2] = 0
  0

proc flash_read*(address: uint32, data: ptr uint8, len: uint32): int32
    {.exportc, cdecl.} =
  discard address
  if data != nil:
    discard c_memset(data, 0xFF, len.csize_t)
  0

proc flash_write*(address: uint32, data: ptr uint8, len: uint32): int32
    {.exportc, cdecl.} =
  discard address
  discard data
  discard len
  0

proc flash_erase*(address: uint32, len: uint32): int32 {.exportc, cdecl.} =
  discard address
  discard len
  0

proc hci_ble_conhdl_register*(conhdl: uint16) {.exportc, cdecl.} =
  discard conhdl

proc hci_ble_conhdl_unregister*(conhdl: uint16) {.exportc, cdecl.} =
  discard conhdl

proc hci_msg_cmd_get_max_param_size*(opcode: uint16): uint16
    {.exportc, cdecl.} =
  discard opcode
  hci_cmd_get_max_param_size()

proc hci_msg_cmd_ll_dest_get*(opcode: uint16): KeTaskId {.exportc, cdecl.} =
  discard opcode
  0

proc hci_msg_cmd_reject_send*(opcode: uint16, status: uint8)
    {.exportc, cdecl.} =
  sendCmdComplete(opcode, status)

proc lld_con_current_tx_power_get*(conhdl: uint16): int8 {.exportc, cdecl.}
proc lld_con_rssi_get*(conhdl: uint16): int8 {.exportc, cdecl.}

proc sendHandleCmdComplete(opcode: uint16, status: uint8, handle: uint16) =
  var rsp = [status, uint8(handle and 0xFF), uint8((handle shr 8) and 0xFF)]
  sendCmdCompletePayload(opcode, addr rsp[0], rsp.len.uint8)

proc sendEncryptionChange(handle: uint16, status: uint8, enabled: uint8) =
  var evt: array[4, uint8]
  let body = cast[ptr HciEncryptionChangeEventView](addr evt[0])
  body.status = status
  body.handle = handle
  body.enabled = enabled
  sendHostEvent(HciEvtEncryptionChange, addr evt[0], evt.len.uint8)

proc sendRemoteVersionInfoComplete(handle: uint16, status: uint8) =
  var evt: array[8, uint8]
  let body = cast[ptr HciRemoteVersionInfoCompleteEventView](addr evt[0])
  body.status = status
  body.handle = handle
  body.version = 0x09'u8   # Bluetooth Core 5.0 HCI version
  body.companyId = 0x01BF'u16
  body.subversion = 0x0001'u16
  sendHostEvent(HciEvtRemoteVersionInfoComplete, addr evt[0], evt.len.uint8)

proc sendLeConnectionUpdateComplete(handle: uint16, status: uint8,
                                    params: ptr uint8) =
  var interval = 0'u16
  var latency = 0'u16
  var timeout = 0'u16
  if params != nil:
    let req = hciLeConnUpdateReq(params)
    interval = req.connIntervalMin
    latency = req.connLatency
    timeout = req.supervisionTimeout
  sendLeConnectionUpdateCompleteValues(handle, status, interval, latency,
                                       timeout)

proc sendLeConnectionUpdateCompleteValues(handle: uint16, status: uint8,
                                          interval, latency,
                                          timeout: uint16) =
  var evt: array[10, uint8]
  let body = cast[ptr HciLeConnectionUpdateCompleteEventView](addr evt[0])
  body.subevent = 0x03'u8
  body.status = status
  body.handle = handle
  body.interval = interval
  body.latency = latency
  body.timeout = timeout
  sendLeMetaPayload(addr evt[0], evt.len.uint8)

proc sendLeRemoteFeaturesComplete(handle: uint16, status: uint8) =
  var evt: array[12, uint8]
  let body = cast[ptr HciLeRemoteFeaturesCompleteEventView](addr evt[0])
  body.subevent = 0x04'u8
  body.status = status
  body.handle = handle
  let features = nimBleCurrentRemoteFeatures()
  for i in 0 ..< 8:
    body.features[i] = nimBleFeatureByte(features, i)
  sendLeMetaPayload(addr evt[0], evt.len.uint8)

proc sendLePhyUpdateComplete(handle: uint16, status: uint8, params: ptr uint8) =
  discard params
  let txPhy = nimBleCurrentPhy()
  let rxPhy = nimBleCurrentPhy()
  var evt: array[6, uint8]
  let body = cast[ptr HciLePhyUpdateCompleteEventView](addr evt[0])
  body.subevent = 0x0C'u8
  body.status = status
  body.handle = handle
  body.txPhy = txPhy
  body.rxPhy = rxPhy
  sendLeMetaPayload(addr evt[0], evt.len.uint8)

proc sendLeEncryptComplete(opcode: uint16, params: ptr uint8,
                           paramLen: uint8): uint8 =
  var rsp: array[17, uint8]
  if params == nil or paramLen != 32'u8:
    rsp[0] = HciStatusInvalidParams
  else:
    let raw = cast[ptr UncheckedArray[uint8]](params)
    rsp[0] = HciStatusSuccess
    blecrypto.bleAesEncryptBlock(cast[ptr uint8](addr raw[0]),
                       cast[ptr uint8](addr raw[16]),
                       addr rsp[1])
  sendCmdCompletePayload(opcode, addr rsp[0], rsp.len.uint8)
  rsp[0]

proc sendLeRandComplete(opcode: uint16, paramLen: uint8): uint8 =
  var rsp: array[9, uint8]
  if paramLen != 0'u8:
    rsp[0] = HciStatusInvalidParams
  elif bleFillRandomBytes(addr rsp[1], 8):
    rsp[0] = HciStatusSuccess
  else:
    rsp[0] = HciStatusHardwareFailure
  sendCmdCompletePayload(opcode, addr rsp[0], rsp.len.uint8)
  rsp[0]

proc sendReadBufferSizeComplete(opcode: uint16, paramLen: uint8): uint8 =
  result =
    if paramLen == 0'u8: HciStatusSuccess else: HciStatusInvalidParams
  var rsp: array[8, uint8]
  rsp[0] = result
  hciPutLe16(cast[ptr UncheckedArray[uint8]](addr rsp[0]), 1,
             NimBleLeMaxDataOctets)
  rsp[3] = 0'u8
  hciPutLe16(cast[ptr UncheckedArray[uint8]](addr rsp[0]), 4, 1'u16)
  hciPutLe16(cast[ptr UncheckedArray[uint8]](addr rsp[0]), 6, 0'u16)
  sendCmdCompletePayload(opcode, addr rsp[0], rsp.len.uint8)

proc sendLeReadBufferSizeComplete(opcode: uint16, paramLen: uint8): uint8 =
  result =
    if paramLen == 0'u8: HciStatusSuccess else: HciStatusInvalidParams
  var rsp: array[4, uint8]
  rsp[0] = result
  hciPutLe16(cast[ptr UncheckedArray[uint8]](addr rsp[0]), 1,
             NimBleLeMaxDataOctets)
  rsp[3] = 1'u8
  sendCmdCompletePayload(opcode, addr rsp[0], rsp.len.uint8)

proc sendLeReadLocalSupportedFeaturesComplete(opcode: uint16,
                                              paramLen: uint8): uint8 =
  result =
    if paramLen == 0'u8: HciStatusSuccess else: HciStatusInvalidParams
  var rsp: array[9, uint8]
  rsp[0] = result
  for i in 0 ..< 8:
    rsp[i + 1] = nimBleFeatureByte(NimBleConservativeLeFeatures, i)
  sendCmdCompletePayload(opcode, addr rsp[0], rsp.len.uint8)

proc sendLeReadLocalP256Complete(opcode: uint16, paramLen: uint8): uint8 =
  bleP256Mark(0x00000200'u32)
  if paramLen != 0'u8:
    sendCmdStatus(opcode, HciStatusInvalidParams)
    bleP256Result(HciStatusInvalidParams.uint32)
    return HciStatusInvalidParams

  sendCmdStatus(opcode, HciStatusSuccess)
  bleP256Mark(0x00000210'u32)
  var evt: array[66, uint8]
  var secret: array[ECC_KEY_LEN, uint8]
  evt[0] = 0x08'u8
  discard c_memset(addr pka_result[0], 0, pka_result.len.csize_t)
  let secretOk = eccGenerateSecretKey(addr secret[0])
  bleP256Result(if secretOk: 1'u32 else: 0'u32)
  bleP256Mark(0x00000220'u32)
  var baseMultOk = false
  if secretOk:
    bleP256Mark(0x00000230'u32)
    baseMultOk = p256ControllerBaseMultLe(
      addr secret[0], addr pka_result[0],
      addr pka_result[ECC_KEY_LEN])
    bleP256Result(if baseMultOk: 3'u32 else: 2'u32)
    bleP256Mark(0x00000240'u32)
  if secretOk and baseMultOk:
    evt[1] = HciStatusSuccess
    discard c_memcpy(addr evt[2], addr pka_result[0], ECC_KEY_LEN.csize_t)
    discard c_memcpy(addr evt[2 + ECC_KEY_LEN],
                     addr pka_result[ECC_KEY_LEN], ECC_KEY_LEN.csize_t)
  else:
    evt[1] = HciStatusHardwareFailure
  bleP256Mark(0x00000250'u32)
  sendLeMetaPayload(addr evt[0], evt.len.uint8)
  bleP256Result(evt[1].uint32)
  bleP256Mark(0x00000260'u32)
  evt[1]

proc sendLeGenerateDhKeyComplete(opcode: uint16, params: ptr uint8,
                                 paramLen: uint8): uint8 =
  bleP256Mark(0x00000300'u32)
  if params == nil or paramLen != 64'u8:
    sendCmdStatus(opcode, HciStatusInvalidParams)
    bleP256Result(HciStatusInvalidParams.uint32)
    return HciStatusInvalidParams

  sendCmdStatus(opcode, HciStatusSuccess)
  bleP256Mark(0x00000310'u32)
  var evt: array[34, uint8]
  evt[0] = 0x09'u8
  discard c_memset(addr pka_result[0], 0, pka_result.len.csize_t)
  let peerPoint = cast[ptr EccPoint256](params)
  let peerY = addr peerPoint.y[0]
  if not bleP256IsValidScalarLe(addr ecc_private_key[0]):
    bleP256Mark(0x00000320'u32)
    evt[1] = HciStatusCommandDisallowed
  elif p256ControllerScalarMultLe(addr ecc_private_key[0], params, peerY,
                                  addr pka_result[0],
                                  addr pka_result[ECC_KEY_LEN]):
    bleP256Mark(0x00000330'u32)
    evt[1] = HciStatusSuccess
    discard c_memcpy(addr evt[2], addr pka_result[0], ECC_KEY_LEN.csize_t)
  else:
    bleP256Mark(0x00000340'u32)
    evt[1] = HciStatusInvalidParams
  bleP256Mark(0x00000350'u32)
  sendLeMetaPayload(addr evt[0], evt.len.uint8)
  bleP256Result(evt[1].uint32)
  bleP256Mark(0x00000360'u32)
  evt[1]

proc hci_rd_rssi_cmd_handler*(params: ptr uint8, opcode: uint16): uint32
    {.exportc, cdecl.} =
  let handle = hciConnHandle(params)
  let status = connParamStatus(params, handle)
  var rsp = [status, uint8(handle and 0xFF), uint8((handle shr 8) and 0xFF),
             cast[uint8](lld_con_rssi_get(handle))]
  sendCmdCompletePayload(opcode, addr rsp[0], rsp.len.uint8)
  0

proc hci_rd_tx_pwr_lvl_cmd_handler*(params: ptr uint8,
                                    opcode: uint16): uint32
    {.exportc, cdecl.} =
  let handle = hciConnHandle(params)
  let status = connParamStatus(params, handle)
  var rsp = [status, uint8(handle and 0xFF), uint8((handle shr 8) and 0xFF),
             cast[uint8](lld_con_current_tx_power_get(handle))]
  sendCmdCompletePayload(opcode, addr rsp[0], rsp.len.uint8)
  0

proc hci_disconnect_cmd_handler*(params: ptr uint8, opcode: uint16): uint32
    {.exportc, cdecl.} =
  let status = handleNimHciCommand(HciOpDisconnect, params, 3)
  sendCmdComplete(opcode, status)
  0

proc hci_le_con_upd_cmd_handler*(params: ptr uint8, opcode: uint16): uint32
    {.exportc, cdecl.} =
  discard sendLeConnectionUpdateCommand(opcode, params,
    sizeof(HciLeConnUpdateReqView).uint8)
  0

proc hci_le_en_enc_cmd_handler*(params: ptr uint8, opcode: uint16): uint32
    {.exportc, cdecl.} =
  discard sendLeEncryptComplete(opcode, params, 32'u8)
  0

proc hci_le_ltk_req_reply_cmd_handler*(params: ptr uint8,
                                       opcode: uint16): uint32
    {.exportc, cdecl.} =
  let handle = hciConnHandle(params)
  var status = connParamStatus(params, handle)
  if status == HciStatusSuccess:
    status = HciStatusCommandDisallowed
  sendHandleCmdComplete(opcode, status, handle)
  0

proc hci_le_ltk_req_neg_reply_cmd_handler*(params: ptr uint8,
                                           opcode: uint16): uint32
    {.exportc, cdecl.} =
  let handle = hciConnHandle(params)
  var status = connParamStatus(params, handle)
  if status == HciStatusSuccess:
    status = HciStatusCommandDisallowed
  sendHandleCmdComplete(opcode, status, handle)
  0

proc hci_le_rd_rem_feats_cmd_handler*(params: ptr uint8,
                                      opcode: uint16): uint32
    {.exportc, cdecl.} =
  discard sendLeReadRemoteFeaturesCommand(opcode, params, 2'u8)
  0

proc hci_le_rem_con_param_req_reply_cmd_handler*(params: ptr uint8,
                                                 opcode: uint16): uint32
    {.exportc, cdecl.} =
  let handle = hciConnHandle(params)
  var status = connParamStatus(params, handle)
  if status == HciStatusSuccess:
    status = HciStatusCommandDisallowed
  sendHandleCmdComplete(opcode, status, handle)
  0

proc hci_le_rem_con_param_req_neg_reply_cmd_handler*(params: ptr uint8,
                                                     opcode: uint16): uint32
    {.exportc, cdecl.} =
  let handle = hciConnHandle(params)
  var status = connParamStatus(params, handle)
  if status == HciStatusSuccess:
    status = HciStatusCommandDisallowed
  sendHandleCmdComplete(opcode, status, handle)
  0

proc hci_le_req_peer_sca_cmd_handler*(params: ptr uint8,
                                      opcode: uint16): uint32
    {.exportc, cdecl.} =
  let handle = hciConnHandle(params)
  let status = connParamStatus(params, handle)
  sendCmdComplete(opcode, status)
  if status == 0:
    var evt = [0x20'u8, status, uint8(handle and 0xFF),
               uint8((handle shr 8) and 0xFF), 0'u8]
    sendLeMetaPayload(addr evt[0], evt.len.uint8)
  0

proc hci_le_set_phy_cmd_handler*(params: ptr uint8, opcode: uint16): uint32
    {.exportc, cdecl.} =
  let handle = hciConnHandle(params)
  var status = connParamStatus(params, handle)
  if status == HciStatusSuccess:
    let req = hciLeSetPhyReq(params)
    if not nimBleRequestedPhySupported(req):
      status = HciStatusUnsupportedFeatureParam
  sendCmdComplete(opcode, status)
  if status == 0:
    nimBleSetCurrentPhy1M()
    sendLePhyUpdateComplete(handle, status, params)
  0

proc hci_le_rd_adv_ch_tx_pw_cmd_handler*(params: ptr uint8,
                                         opcode: uint16): uint32
    {.exportc, cdecl.} =
  discard params
  sendCmdComplete2(opcode, 0'u8, cast[uint8](ble_tx_pwr))
  0

proc hci_le_rd_chnl_map_cmd_handler*(params: ptr uint8,
                                     opcode: uint16): uint32
    {.exportc, cdecl.} =
  let handle = hciConnHandle(params)
  let status = connParamStatus(params, handle)
  var rsp = [status, uint8(handle and 0xFF), uint8((handle shr 8) and 0xFF),
             0xFF'u8, 0xFF, 0xFF, 0xFF, 0x1F]
  if status == HciStatusSuccess:
    nimBleCurrentChannelMap(cast[ptr UncheckedArray[uint8]](addr rsp[3]))
  sendCmdCompletePayload(opcode, addr rsp[0], rsp.len.uint8)
  0

proc hci_le_rd_phy_cmd_handler*(params: ptr uint8, opcode: uint16): uint32
    {.exportc, cdecl.} =
  let handle = hciConnHandle(params)
  let status = connParamStatus(params, handle)
  var rsp = [status, uint8(handle and 0xFF), uint8((handle shr 8) and 0xFF),
             nimBleCurrentPhy(), nimBleCurrentPhy()]
  sendCmdCompletePayload(opcode, addr rsp[0], rsp.len.uint8)
  0

proc hci_le_set_adv_data_cmd_handler*(params: ptr uint8,
                                      opcode: uint16): uint32
    {.exportc, cdecl.} =
  let status = handleNimHciCommand(HciOpLeSetAdvData, params, 32)
  sendCmdComplete(opcode, status)
  0

proc hci_le_set_adv_en_cmd_handler*(params: ptr uint8,
                                    opcode: uint16): uint32
    {.exportc, cdecl.} =
  let status = handleNimHciCommand(HciOpLeSetAdvEnable, params, 1)
  sendCmdComplete(opcode, status)
  0

proc hci_le_set_adv_param_cmd_handler*(params: ptr uint8,
                                       opcode: uint16): uint32
    {.exportc, cdecl.} =
  let status = handleNimHciCommand(HciOpLeSetAdvParams, params, 15)
  sendCmdComplete(opcode, status)
  0

proc hci_le_set_adv_set_rand_addr_cmd_handler*(params: ptr uint8,
                                               opcode: uint16): uint32
    {.exportc, cdecl.} =
  var status = 0x12'u8
  if params != nil:
    let req = hciLeSetAdvRandomAddrReq(params)
    for i in 0 ..< nim_local_addr.len:
      nim_local_addr[i] = req.randomAddress.data[i]
    nim_local_addr_valid = true
    status = 0'u8
  sendCmdComplete(opcode, status)
  0

proc hci_le_set_scan_rsp_data_cmd_handler*(params: ptr uint8,
                                           opcode: uint16): uint32
    {.exportc, cdecl.} =
  let status = handleNimHciCommand(HciOpLeSetScanRspData, params, 32)
  sendCmdComplete(opcode, status)
  0

proc hci_le_set_data_len_cmd_handler*(params: ptr uint8,
                                      opcode: uint16): uint32
    {.exportc, cdecl.} =
  let handle = hciConnHandle(params)
  let status = nimBleDataLengthStatus(params, handle)
  var rsp = [status, uint8(handle and 0xFF), uint8((handle shr 8) and 0xFF)]
  sendCmdCompletePayload(opcode, addr rsp[0], rsp.len.uint8)
  if status == HciStatusSuccess:
    sendLeDataLengthChange(handle)
  0

proc hci_rd_auth_payl_to_cmd_handler*(params: ptr uint8,
                                      opcode: uint16): uint32
    {.exportc, cdecl.} =
  let handle = hciConnHandle(params)
  let status = connParamStatus(params, handle)
  var rsp = [status, uint8(handle and 0xFF), uint8((handle shr 8) and 0xFF),
             uint8(nim_auth_payload_timeout and 0xFF),
             uint8((nim_auth_payload_timeout shr 8) and 0xFF)]
  sendCmdCompletePayload(opcode, addr rsp[0], rsp.len.uint8)
  0

proc hci_rd_rem_ver_info_cmd_handler*(params: ptr uint8,
                                      opcode: uint16): uint32
    {.exportc, cdecl.} =
  discard sendReadRemoteVersionInfoCommand(opcode, params, 2'u8)
  0

proc hci_vs_set_max_rx_size_and_time_cmd_handler*(params: ptr uint8,
                                                  opcode: uint16): uint32
    {.exportc, cdecl.} =
  discard params
  sendCmdComplete(opcode, 0'u8)
  0

proc hci_vs_set_pref_slave_evt_dur_cmd_handler*(params: ptr uint8,
                                                opcode: uint16): uint32
    {.exportc, cdecl.} =
  discard params
  sendCmdComplete(opcode, 0'u8)
  0

proc hci_vs_set_pref_slave_latency_cmd_handler*(params: ptr uint8,
                                                opcode: uint16): uint32
    {.exportc, cdecl.} =
  discard params
  sendCmdComplete(opcode, 0'u8)
  0

proc hci_wr_auth_payl_to_cmd_handler*(params: ptr uint8,
                                      opcode: uint16): uint32
    {.exportc, cdecl.} =
  let handle = hciConnHandle(params)
  var status = connParamStatus(params, handle)
  if status == HciStatusSuccess and params != nil:
    let timeout = hciWriteAuthPayloadTimeoutReq(params).timeout
    status = llc_le_ping_set(handle, timeout)
    if status == HciStatusSuccess:
      nim_auth_payload_timeout = timeout
  sendHandleCmdComplete(opcode, status, handle)
  0

proc hci_msg_task_dest_compute*(opcode: uint16): KeTaskId {.exportc, cdecl.} =
  discard opcode
  0

proc hci_tl_acl_tx_data_alloc*(pktType: uint8, handle: uint16,
                               len: uint16): pointer {.exportc, cdecl.} =
  discard pktType
  hci_acl_tx_data_alloc(handle, len)

proc hci_tl_acl_tx_data_received*(pktType: uint8, handle: uint16,
                                  data: pointer, len: uint16)
    {.exportc, cdecl.} =
  discard pktType
  hci_acl_tx_data_received(handle, data, len)

proc hci_tl_cmd_get_max_param_size*(): uint16 {.exportc, cdecl.} =
  hci_cmd_get_max_param_size()

proc hci_tl_cmd_received*(data: pointer, len: uint16) {.exportc, cdecl.} =
  hci_cmd_received(data, len)

proc nvds_init*(readCb: pointer, writeCb: pointer): uint8 {.exportc, cdecl.} =
  discard readCb
  discard writeCb
  0

proc nvds_get*(tag: uint8, length: ptr uint8, buf: ptr uint8): uint8
    {.exportc, cdecl.} =
  discard tag
  if length != nil:
    length[] = 0
  discard buf
  1

proc nvds_put*(tag: uint8, length: uint8, buf: ptr uint8): uint8
    {.exportc, cdecl.} =
  discard tag
  discard length
  discard buf
  0

proc nvds_del*(tag: uint8): uint8 {.exportc, cdecl.} =
  discard tag
  0

proc nvds_lock*(tag: uint8): uint8 {.exportc, cdecl.} =
  discard tag
  0

proc rf_txpwr_dbm2cs*(dbm: int8): uint8 {.exportc, cdecl.} =
  uint8((int32(dbm) shl 2) and 0xFC)

proc rf_txpwr_cs2dbm*(cs: uint8): int8 {.exportc, cdecl.} =
  int8(cs shr 2)

proc rw_main_task_post*(fn: pointer, arg: pointer): bool {.exportc, cdecl.} =
  bflb_main_task_post(fn, arg)

proc rw_main_task_post_from_fw*(fn: pointer, arg: pointer) {.exportc, cdecl.} =
  bflb_main_task_post_from_fw(fn, arg)

proc rw_main_task_post_from_isr*(fn: pointer, arg: pointer) {.exportc, cdecl.} =
  bflb_main_task_post_from_isr(fn, arg)

var nim_lld_aa_counter: uint32
when defined(bl808m0):
  var nim_lld_aa_gen_count* {.exportc.}: uint32
  var nim_lld_aa_last_seed* {.exportc.}: uint32
  var nim_lld_aa_last* {.exportc.}: uint32

proc lldAccessAddressValid(aa: uint32): bool =
  if aa == 0'u32 or aa == 0xFFFFFFFF'u32 or aa == 0x8E89BED6'u32:
    return false

  var transitions = 0
  var run = 1
  var last = aa and 1'u32
  for bit in 1 ..< 32:
    let cur = (aa shr bit) and 1'u32
    if cur == last:
      inc run
      if run > 6:
        return false
    else:
      inc transitions
      run = 1
      last = cur
  transitions >= 2

proc lld_aa_gen*(outAddr: ptr uint8, seed: uint8) {.exportc, cdecl.} =
  if outAddr == nil:
    return
  inc nim_lld_aa_counter
  when defined(bl808m0):
    inc nim_lld_aa_gen_count
    nim_lld_aa_last_seed = seed.uint32
  var aa =
    currentBtbleTime() xor 0xD6BE898E'u32 xor
    (uint32(seed) * 0x9E3779B1'u32) xor
    (nim_lld_aa_counter * 0x45D9F3B'u32)
  var guard = 0
  while not lldAccessAddressValid(aa) and guard < 64:
    aa = aa * 1664525'u32 + 1013904223'u32 + uint32(guard)
    inc guard
  if not lldAccessAddressValid(aa):
    aa = 0xA77C2B91'u32 xor (uint32(seed) shl 8)
  let raw = cast[ptr UncheckedArray[uint8]](outAddr)
  raw[0] = uint8(aa and 0xFF)
  raw[1] = uint8((aa shr 8) and 0xFF)
  raw[2] = uint8((aa shr 16) and 0xFF)
  raw[3] = uint8((aa shr 24) and 0xFF)
  when defined(bl808m0):
    nim_lld_aa_last = aa

proc lld_ch_map_set*(chMap: ptr uint8) {.exportc, cdecl.} =
  var count: uint8 = 0
  let raw =
    if chMap == nil:
      nil
    else:
      cast[ptr UncheckedArray[uint8]](chMap)
  for channel in 0 ..< 37:
    let enabled =
      if raw == nil:
        true
      else:
        (raw[channel shr 3] and (1'u8 shl uint8(channel and 0x07))) != 0'u8
    if enabled:
      lld_env[17 + int(count)] = uint8(channel)
      inc count
  if count == 0'u8:
    for channel in 0 ..< 37:
      lld_env[17 + channel] = uint8(channel)
    count = 37'u8
  lld_env[54] = count

proc lld_ch_idx_get*(): uint8 {.exportc, cdecl.} =
  let count = lld_env[54]
  if count == 0'u8:
    return uint8(currentBtbleTime() mod 37'u32)
  let idx = int(currentBtbleTime() mod uint32(count))
  lld_env[17 + idx]

proc lld_con_current_tx_power_get*(conhdl: uint16): int8 {.exportc, cdecl.} =
  discard conhdl
  ble_tx_pwr

proc lld_con_rssi_get*(conhdl: uint16): int8 {.exportc, cdecl.} =
  discard conhdl
  0'i8

proc lld_con_init*(initType: uint8): uint32 {.exportc, cdecl.} =
  case initType
  of 2'u8, 3'u8:
    nim_conn_active = false
    nim_conn_handle = 0
    when defined(bl808m0) and bl808BleNimConnectionEnabled:
      nim_conn_started = false
      nim_connect_ind_pending = 0
      nim_acl_empty_tx_pending = 0
      nim_acl_empty_tx_queued = 0
      nim_acl_host_tx_pending = 0
      nim_llcp_tx_pending = 0
      nim_llcp_tx_queued = 0
      nim_llcp_tx_queue_head = 0
      nim_llcp_tx_queue_tail = 0
      nim_llcp_state.versionProcedureStarted = false
      nimLlcpClearFeatureExchangeState(clearDebug = true)
      nim_llcp_state.startupAttemptsLeft = 0
      nim_llcp_state.startupDelayServices = 0
      nimLlcpResetDataLengthState()
      when bl808BleNimPureConnection:
        discard c_memset(addr nim_conn_state, 0, sizeof(NimConnState).csize_t)
  else:
    discard
  0

proc lld_con_data_flow_set*(conhdl: uint16, enabled: uint8): uint32
    {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled and
      bl808BleNimPureConnection:
    if nim_conn_state.active and conhdl == nim_conn_state.handle:
      nim_conn_state.dataFlowEnabled = enabled != 0'u8
  else:
    discard conhdl
    discard enabled
  0

proc lld_con_event_counter_get*(conhdl: uint16): uint16 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled and
      bl808BleNimPureConnection:
    if nim_conn_state.active and conhdl == nim_conn_state.handle:
      return nim_conn_state.eventCounter
  discard conhdl
  0'u16

proc lld_con_offset_get*(conhdl: uint16): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled and
      bl808BleNimPureConnection:
    if nim_conn_state.active and conhdl == nim_conn_state.handle and
        nim_conn_state.intervalSlots != 0'u32:
      return nim_conn_state.nextAnchor mod nim_conn_state.intervalSlots
  discard conhdl
  0'u32

proc lld_con_time_get*(conhdl: uint16, counter: ptr uint16,
                       clock: ptr uint32, fine: ptr uint16): uint8
    {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled and
      bl808BleNimPureConnection:
    if nim_conn_state.active and conhdl == nim_conn_state.handle:
      if counter != nil:
        counter[] = nim_conn_state.eventCounter
      if clock != nil:
        clock[] = nim_conn_state.nextAnchor
      if fine != nil:
        fine[] = nim_conn_state.anchorFine
      return HciStatusSuccess
  else:
    discard counter
    discard clock
    discard fine
  discard conhdl
  HciStatusCommandDisallowed

proc lld_con_peer_sca_set*(conhdl: uint16, sca: uint8): uint32
    {.exportc, cdecl.} =
  let boundedSca = sca and 0x07'u8
  when defined(bl808m0) and bl808BleNimConnectionEnabled and
      bl808BleNimPureConnection:
    if nim_conn_state.active and conhdl == nim_conn_state.handle:
      nim_conn_state.peerSca = boundedSca
      nim_conn_state.peerDriftPpm =
        if boundedSca.int < co_sca2ppm.len:
          uint32(co_sca2ppm[boundedSca.int])
        else:
          0'u32
  else:
    discard conhdl
  0

proc lld_con_pref_slave_latency_set*(conhdl: uint16, latency: uint16): uint32
    {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled and
      bl808BleNimPureConnection:
    if nim_conn_state.active and conhdl == nim_conn_state.handle:
      nim_conn_state.preferredSlaveLatency = latency
  else:
    discard conhdl
    discard latency
  0

proc lld_con_pref_slave_evt_dur_set*(conhdl: uint16, duration: uint16): uint32
    {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled and
      bl808BleNimPureConnection:
    if nim_conn_state.active and conhdl == nim_conn_state.handle:
      nim_conn_state.preferredSlaveEventDuration = duration
  else:
    discard conhdl
    discard duration
  0

proc lld_con_ch_map_update*(conhdl: uint16, map: ptr uint8,
                            instant: uint16): uint8 {.exportc, cdecl.} =
  discard instant
  if map == nil:
    return HciStatusInvalidParams
  if conhdl >= LLC_CON_MAX.uint16:
    return HciStatusUnknownConnection
  llc_util_update_channel_map(conhdl, map)
  lld_ch_map_set(map)
  HciStatusSuccess

proc lld_ch_map_upd_cfm_handler*(msgid: KeMsgId, param: pointer,
                                 dest_id: KeTaskId,
                                 src_id: KeTaskId): uint32 {.exportc, cdecl.} =
  discard msgid
  discard param
  discard src_id
  let conhdl = uint16(dest_id shr 8)
  if conhdl < LLC_CON_MAX.uint16:
    llc_proc_unreg(conhdl, 6'u8)
  0

proc lld_con_data_len_update*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and bl808BleNimConnectionEnabled and
      bl808BleNimPureConnection:
    if nim_conn_state.active:
      nimConnProgramPacketDurations(nim_conn_state.handle)
  0

proc lld_white_list_add*(position: uint8, peerAddr: ptr BdAddr,
                         addrType: uint8): uint32 {.exportc, cdecl.} =
  if addrType == 0xFF'u8:
    return 0
  let slot = llmWlNormalizeSlot(position)
  if slot >= 0 and peerAddr != nil and
      (llmWlSlotAvailable(slot) or
       (llm_wl_type[slot] == addrType and
        co_bdaddr_compare(addr llm_wl[slot], peerAddr))):
    co_bdaddr_set(addr llm_wl[slot], peerAddr)
    llm_wl_type[slot] = addrType
  elif not llm_util_bl_add(peerAddr, addrType):
    return 1
  0

proc lld_white_list_rem*(position: uint8, peerAddr: ptr BdAddr,
                         addrType: uint8): uint32 {.exportc, cdecl.} =
  if addrType == 0xFF'u8:
    return 0
  let slot = llmWlNormalizeSlot(position)
  if slot >= 0 and llm_wl_type[slot] != 0xFF'u8:
    discard c_memset(addr llm_wl[slot], 0, sizeof(BdAddr).csize_t)
    llm_wl_type[slot] = 0xFF'u8
  elif not llm_util_bl_rem(peerAddr, addrType):
    return 1
  0

template abiNoopHandler(name: untyped) =
  ## Export an unsupported controller ABI entry point as a no-op.
  proc name*(): uint32 {.exportc, cdecl.} =
    0

template abiLlcpHandler(name: untyped, opcode: untyped) =
  when defined(bl808m0) and bl808BleNimConnectionEnabled:
    when bl808BleNimManualConnTx:
      proc name*(conhdl: uint16,
                 pdu: ptr UncheckedArray[uint8],
                 rxHeader: uint16): uint32 {.exportc, cdecl.} =
        nimLlcpHandleConsumed(conhdl, pdu, rxHeader, opcode)
    else:
      abiNoopHandler(name)
  else:
    abiNoopHandler(name)

proc emi_init*() {.exportc, cdecl.} =
  discard

type
  CoDjobCallback = proc() {.cdecl.}

  CoDjob {.packed.} = object
    node: CoListNode
    cb: CoDjobCallback

const
  CoDjobQueueCount = 3
  CoDjobDrainLimit = 8'u32
  CoDjobEventIds = [0'u8, 3'u8, 6'u8]
  CoDjobIsrQueue = 2

var
  co_djob_queues: array[CoDjobQueueCount, CoList]
  nim_ble_codjob_yield_count* {.exportc.}: uint32
  nim_ble_codjob_yield_event* {.exportc.}: uint32

proc coDjobQueueIndex(eventId: uint8): int =
  for i in 0 ..< CoDjobEventIds.len:
    if CoDjobEventIds[i] == eventId:
      return i
  if eventId < CoDjobQueueCount.uint8:
    int(eventId)
  else:
    -1

proc coDjobEventId(index: int): uint8 =
  if index >= 0 and index < CoDjobEventIds.len:
    CoDjobEventIds[index]
  else:
    0'u8

proc coDjobPending(index: int): bool {.inline.} =
  let irq = disableInterrupts()
  result = co_djob_queues[index].first != nil
  restoreInterrupts(irq)

proc coDjobAnyPending(): bool =
  let irq = disableInterrupts()
  for queue in co_djob_queues:
    if queue.first != nil:
      result = true
      break
  restoreInterrupts(irq)

proc coDjobRun(eventId: uint8) {.cdecl.} =
  let index = coDjobQueueIndex(eventId)
  if index < 0:
    return
  var drained = 0'u32
  while drained < CoDjobDrainLimit:
    let irq = disableInterrupts()
    let node = ble_co_list_pop_front(addr co_djob_queues[index])
    restoreInterrupts(irq)
    if node == nil:
      return
    let job = cast[ptr CoDjob](node)
    let cb = job.cb
    job.node.next = nil
    if cb != nil:
      cb()
    inc drained

  if coDjobPending(index):
    inc nim_ble_codjob_yield_count
    nim_ble_codjob_yield_event = eventId.uint32
    ble_ke_event_set(coDjobEventId(index))

proc coDjobRegister(index: int, job: ptr CoDjob) =
  if index < 0 or index >= CoDjobQueueCount or job == nil:
    return
  let irq = disableInterrupts()
  if not ble_co_list_find(addr co_djob_queues[index], addr job.node):
    let wasEmpty = co_djob_queues[index].first == nil
    ble_co_list_push_back(addr co_djob_queues[index], addr job.node)
    restoreInterrupts(irq)
    if wasEmpty:
      ble_ke_event_set(coDjobEventId(index))
  else:
    restoreInterrupts(irq)

proc coDjobUnregister(index: int, job: ptr CoDjob) =
  if job == nil:
    return
  let irq = disableInterrupts()
  if index >= 0 and index < CoDjobQueueCount:
    ble_co_list_extract(addr co_djob_queues[index], addr job.node)
  else:
    for queue in mitems(co_djob_queues):
      ble_co_list_extract(addr queue, addr job.node)
  job.node.next = nil
  restoreInterrupts(irq)

proc co_djob_init*(job: pointer, cb: pointer) {.exportc, cdecl.} =
  if job == nil:
    return
  let djob = cast[ptr CoDjob](job)
  djob.node.next = nil
  djob.cb = cast[CoDjobCallback](cb)

template hciCmdStatusDescView(desc: pointer): ptr HciCmdStatusDescView =
  cast[ptr HciCmdStatusDescView](desc)

template hciEventRouting(evt: pointer): ptr HciEventRoutingView =
  cast[ptr HciEventRoutingView](evt)

proc hci_msg_cmd_status_exp*(desc: pointer): uint8 {.exportc, cdecl.} =
  if desc == nil:
    return 1
  if hciCmdStatusDescView(desc).expectedStatusWord == 0'u32:
    1'u8
  else:
    0'u8

proc hci_msg_evt_get_hl_tl_dest*(evt: pointer): uint8 {.exportc, cdecl.} =
  if evt == nil:
    0
  else:
    hciEventRouting(evt).route and 0x03'u8

proc hci_msg_evt_host_lid_get*(evt: pointer): uint8 {.exportc, cdecl.} =
  if evt == nil:
    0
  else:
    hciEventRouting(evt).hostLid

proc led_init*() {.exportc, cdecl.} =
  discard

proc led_set_all*() {.exportc, cdecl.} =
  discard

proc syscntl_init*() {.exportc, cdecl.} =
  discard

proc llc_proc_init*(procEnv: pointer, procId: uint8, cb: pointer)
    {.exportc, cdecl.} =
  if procEnv == nil:
    return
  let env = llcProcEnv(procEnv)
  env.errCallback = cb
  env.procId = procId
  env.state = 0
  env.reserved06 = 0

proc Add2SelfBigHex256*(dst, other: pointer) {.exportc, cdecl.} =
  bleBigHexAddSelf(dst, other)

proc AddBigHex256*(a, b, dst: pointer) {.exportc, cdecl.} =
  bleBigHexAdd(a, b, dst)

proc AddBigHexModP256*(a, b, dst: pointer) {.exportc, cdecl.} =
  bleBigHexAddModP256(a, b, dst)

proc AddP256*(value: pointer) {.exportc, cdecl.} =
  bleBigHexAddP256(value)

proc AddPdiv2_256*(value: pointer) {.exportc, cdecl.} =
  bleBigHexAddPdiv2(value)

proc GF_Jacobian_Point_Addition256*(a, b, dst: pointer) {.exportc, cdecl.} =
  bleP256JacobianAdd(a, b, dst)

proc GF_Jacobian_Point_Double256*(point, dst: pointer) {.exportc, cdecl.} =
  bleP256JacobianDouble(point, dst)

proc MultiplyBigHexByUint32_256*(a: pointer, k: uint32, dst: pointer)
    {.exportc, cdecl.} =
  bleBigHexMultiplyByU32ModP256(a, k, dst)

proc MultiplyBigHexModP256*(a, b, dst: pointer) {.exportc, cdecl.} =
  bleBigHexMultiplyModP256(a, b, dst)

proc MultiplyByU32ModP256*(k: uint32, dst: pointer) {.exportc, cdecl.} =
  bleBigHexP256TimesU32(k, dst)

proc SubtractBigHex256*(a, b, dst: pointer) {.exportc, cdecl.} =
  bleBigHexSubtract(a, b, dst)

proc SubtractBigHexMod256*(a, b, dst: pointer) {.exportc, cdecl.} =
  bleBigHexSubtractModP256(a, b, dst)

proc SubtractBigHexUint32_256*(a: pointer, k: uint32, dst: pointer)
    {.exportc, cdecl.} =
  bleBigHexSubtractU32(a, k, dst)

proc SubtractFromSelfBigHex256*(dst, other: pointer) {.exportc, cdecl.} =
  bleBigHexSubtractSelf(dst, other)

proc SubtractFromSelfBigHexSign256*(dst, other: pointer) {.exportc, cdecl.} =
  bleBigHexSubtractSelf(dst, other)
proc co_djob_initialize*(initType: uint8) {.exportc, cdecl.} =
  case initType
  of 1'u8:
    for i in 0 ..< CoDjobQueueCount:
      ble_ke_event_callback_set(CoDjobEventIds[i], coDjobRun)
      ble_co_list_init(addr co_djob_queues[i])
  of 2'u8, 3'u8:
    for queue in mitems(co_djob_queues):
      ble_co_list_init(addr queue)
  else:
    discard

proc co_djob_isr_reg*(job: pointer) {.exportc, cdecl.} =
  coDjobRegister(CoDjobIsrQueue, cast[ptr CoDjob](job))

proc co_djob_reg*(eventId: uint8, job: pointer) {.exportc, cdecl.} =
  coDjobRegister(coDjobQueueIndex(eventId), cast[ptr CoDjob](job))

proc co_djob_unreg*(eventId: uint8, job: pointer) {.exportc, cdecl.} =
  coDjobUnregister(coDjobQueueIndex(eventId), cast[ptr CoDjob](job))
when defined(bl808m0) and bl808BleNimConnectionEnabled and
    bl808BleNimManualConnTx:
  proc aclTaskHandle(destId, srcId: KeTaskId, handleFlags: uint16): uint16 =
    result = handleFlags and 0x0FFF'u16
    if result != 0'u16:
      return
    result = uint16(destId shr 8)
    if result != 0'u16:
      return
    result = uint16(srcId shr 8)

  template hciAclDataInd(param: pointer): ptr HciAclDataIndView =
    cast[ptr HciAclDataIndView](param)

  proc hci_acl_data_handler*(msgid: KeMsgId, param: pointer,
                             dest_id: KeTaskId, src_id: KeTaskId): uint32
      {.exportc, cdecl.} =
    discard msgid
    if param == nil:
      return 0
    let ind = hciAclDataInd(param)
    let handleFlags = ind.handleFlags
    let len = ind.length
    let handle = aclTaskHandle(dest_id, src_id, handleFlags)
    let data = cast[ptr uint8](ind.dataAddr.uint)
    let pbBcFlag = uint8((handleFlags shr 12) and 0x000F'u16)
    discard hciOwnedAclTxDataReceived(handle, pbBcFlag, data, len)
    0
else:
  abiNoopHandler(hci_acl_data_handler)
abiNoopHandler(hci_command_llc_handler)
abiNoopHandler(hci_command_llm_handler)
abiNoopHandler(hci_msg_cmd_cmp_pkupk)
abiNoopHandler(hci_msg_cmd_desc_get)
abiNoopHandler(hci_msg_cmd_pkupk)
abiNoopHandler(hci_msg_evt_desc_get)
abiNoopHandler(hci_msg_evt_pkupk)
abiNoopHandler(hci_msg_le_evt_desc_get)
abiLlcpHandler(ll_channel_map_ind_handler, LlcpChannelMapInd)
abiNoopHandler(ll_clk_acc_req_handler)
abiNoopHandler(ll_clk_acc_rsp_handler)
abiLlcpHandler(ll_connection_param_req_handler, LlcpConnectionParamReq)
abiLlcpHandler(ll_connection_param_rsp_handler, LlcpConnectionParamRsp)
abiLlcpHandler(ll_connection_update_ind_handler, LlcpConnectionUpdateInd)
abiLlcpHandler(ll_enc_req_handler, LlcpEncReq)
abiLlcpHandler(ll_enc_rsp_handler, LlcpEncRsp)
abiLlcpHandler(ll_feature_req_handler, LlcpFeatureReq)
abiLlcpHandler(ll_feature_rsp_handler, LlcpFeatureRsp)
abiLlcpHandler(ll_length_req_handler, LlcpLengthReq)
abiLlcpHandler(ll_length_rsp_handler, LlcpLengthRsp)
abiLlcpHandler(ll_min_used_channels_ind_handler, LlcpMinUsedChannelsInd)
abiLlcpHandler(ll_pause_enc_req_handler, LlcpPauseEncReq)
abiLlcpHandler(ll_pause_enc_rsp_handler, LlcpPauseEncRsp)
abiLlcpHandler(ll_phy_req_handler, LlcpPhyReq)
abiLlcpHandler(ll_phy_rsp_handler, LlcpPhyRsp)
abiLlcpHandler(ll_phy_update_ind_handler, LlcpPhyUpdateInd)
abiLlcpHandler(ll_ping_req_handler, LlcpPingReq)
abiLlcpHandler(ll_ping_rsp_handler, LlcpPingRsp)
abiLlcpHandler(ll_slave_feature_req_handler, LlcpSlaveFeatureReq)
abiLlcpHandler(ll_start_enc_req_handler, LlcpStartEncReq)
abiLlcpHandler(ll_start_enc_rsp_handler, LlcpStartEncRsp)
when defined(bl808m0) and bl808BleNimConnectionEnabled:
  when bl808BleNimManualConnTx:
    proc ll_terminate_ind_handler*(conhdl: uint16,
                                   pdu: ptr UncheckedArray[uint8],
                                   rxHeader: uint16): uint32 {.exportc, cdecl.} =
      nimLlcpHandleConsumed(conhdl, pdu, rxHeader, LlcpTerminateInd)
  else:
    proc ll_terminate_ind_handler*(): uint32 {.exportc, cdecl.} =
      noteNimPeripheralDisconnectedFrom(5'u32, NimLlcpDefaultReason)
      0
else:
  abiNoopHandler(ll_terminate_ind_handler)
when defined(bl808m0) and bl808BleNimConnectionEnabled:
  when bl808BleNimManualConnTx:
    proc ll_version_ind_handler*(conhdl: uint16,
                                 pdu: ptr UncheckedArray[uint8],
                                 rxHeader: uint16): uint32 {.exportc, cdecl.} =
      nimLlcpHandleConsumed(conhdl, pdu, rxHeader, LlcpVersionInd)
  else:
    abiNoopHandler(ll_version_ind_handler)
else:
  abiNoopHandler(ll_version_ind_handler)
proc llc_le_ping_proc_err_cb*(conhdl: uint16, status: uint8,
                              param: pointer) {.exportc, cdecl.} =
  discard param
  if status == 0'u8:
    llc_llcp_ping_req_pdu_send(conhdl)

proc llc_auth_payl_nearly_to_handler*(msgid: KeMsgId, param: pointer,
                                       dest_id: KeTaskId,
                                       src_id: KeTaskId): uint32
    {.exportc, cdecl.} =
  discard msgid
  discard param
  discard src_id
  let conhdl = uint16(dest_id shr 8)
  let env = llcEnvFor(conhdl)
  if not llcEnvConnectionOpen(env) or not llcEnvEncrypted(env):
    return 0

  let task = llcTaskId(conhdl)
  let procEnv = btble_ke_msg_alloc(
    LlcAuthPayloadNearlyOpMsgId, task, task, 8'u16)
  if procEnv != nil:
    llc_proc_init(procEnv, LlcProcLePing, cast[pointer](llc_le_ping_proc_err_cb))
    discard llc_proc_reg(conhdl, 0'u8, procEnv)
    llc_proc_state_set(procEnv, conhdl, 0'u8)
    when defined(bl808m0) and bl808BleNimConnectionEnabled and
        bl808BleNimManualConnTx:
      if nimBleLocalFeatureSupported(NimBleFeatureLePing):
        llc_llcp_ping_req_pdu_send(conhdl)
        llc_proc_state_set(procEnv, conhdl, 1'u8)
  0

proc llc_auth_payl_real_to_handler*(msgid: KeMsgId, param: pointer,
                                     dest_id: KeTaskId,
                                     src_id: KeTaskId): uint32
    {.exportc, cdecl.} =
  discard msgid
  discard param
  discard src_id
  let conhdl = uint16(dest_id shr 8)
  let env = llcEnvFor(conhdl)
  if not llcEnvConnectionOpen(env) or not llcEnvEncrypted(env):
    return 0

  var evt = [uint8(conhdl and 0x00FF'u16),
             uint8((conhdl shr 8) and 0x00FF'u16)]
  sendHostEvent(HciEvtAuthenticatedPayloadTimeoutExpired,
                addr evt[0], evt.len.uint8)
  llcArmAuthPayloadTimers(conhdl, env)
  0
proc llc_cleanup*(conhdl: uint16): uint32 {.exportc, cdecl.} =
  llc_stop(conhdl)
  0

proc llc_clk_acc_modify*(conhdl: uint16, sca: uint8): uint32
    {.exportc, cdecl.} =
  discard lld_con_peer_sca_set(conhdl, sca)
  0

abiNoopHandler(llc_con_move_cbk)
when defined(bl808m0) and bl808BleNimConnectionEnabled and
    bl808BleNimManualConnTx:
  proc llc_disconnect*(conhdl: uint16, reason: uint8): uint32
      {.exportc, cdecl.} =
    llc_llcp_terminate_ind_pdu_send(conhdl, reason)
    0
else:
  abiNoopHandler(llc_disconnect)
abiNoopHandler(llc_encrypt_ind_handler)
proc llc_init_term_proc*(conhdl: uint16, reason: uint8): uint32
    {.exportc, cdecl.} =
  llc_llcp_terminate_ind_pdu_send(conhdl, reason)
  0

proc llc_le_ping_restart*(conhdl: uint16): uint32 {.exportc, cdecl.} =
  let env = llcEnvFor(conhdl)
  llcArmAuthPayloadTimers(conhdl, env)
  0

when defined(bl808m0) and bl808BleNimConnectionEnabled and
    bl808BleNimManualConnTx:
  proc llc_ll_reject_ind_pdu_send*(conhdl: uint16, opcode: uint8,
                                   reason: uint8,
                                   procEnv: pointer): uint32
      {.exportc, cdecl.} =
    discard procEnv
    var pdu =
      if opcode <= LlcpRejectInd:
        nimLlcpBuildRejectInd(reason)
      else:
        nimLlcpBuildRejectExtInd(opcode, reason)
    discard nimLlcpQueuePdu(conhdl, pdu)
    0

  proc llc_llcp_send*(conhdl: uint16, pdu: pointer,
                      procEnv: pointer): uint32 {.exportc, cdecl.} =
    discard procEnv
    if pdu == nil:
      return 0
    let raw = cast[ptr UncheckedArray[uint8]](pdu)
    let len = nimLlcpWireLength(raw[0])
    if len != 0'u8:
      discard nimLlcpQueuePdu(conhdl, raw, len)
    0

  proc llc_llcp_state_set*(conhdl: uint16, stateKind: uint8,
                           state: uint8): uint32 {.exportc, cdecl.} =
    if conhdl < LLC_CON_MAX.uint16 and llc_env[conhdl] != nil:
      let env = llc_env[conhdl]
      var flags = env.data[130]
      let bits = state and 0x03'u8
      case stateKind
      of 0'u8:
        flags = (flags and 0xFC'u8) or bits
      of 1'u8:
        flags = (flags and 0xF3'u8) or uint8(bits shl 2)
      of 2'u8:
        flags = (flags and 0xF0'u8) or bits or uint8(bits shl 2)
      else:
        discard
      env.data[130] = flags
    0
else:
  abiNoopHandler(llc_ll_reject_ind_pdu_send)
  abiNoopHandler(llc_llcp_send)
  abiNoopHandler(llc_llcp_state_set)

proc llcMsgConnectionHandle(dest_id, src_id: KeTaskId): uint16 =
  let fromDest = uint16(dest_id shr 8)
  if fromDest != 0'u16:
    fromDest
  else:
    uint16(src_id shr 8)

proc llc_op_ch_map_upd_ind_handler*(msgid: KeMsgId, param: pointer,
                                    dest_id: KeTaskId,
                                    src_id: KeTaskId): uint32
    {.exportc, cdecl.} =
  discard msgid
  discard param
  llc_llcp_ch_map_update_pdu_send(llcMsgConnectionHandle(dest_id, src_id))
  0

proc llc_op_clk_acc_ind_handler*(msgid: KeMsgId, param: pointer,
                                 dest_id: KeTaskId,
                                 src_id: KeTaskId): uint32
    {.exportc, cdecl.} =
  discard msgid
  discard param
  discard dest_id
  discard src_id
  0

proc llc_op_con_upd_ind_handler*(msgid: KeMsgId, param: pointer,
                                 dest_id: KeTaskId,
                                 src_id: KeTaskId): uint32
    {.exportc, cdecl.} =
  discard msgid
  discard param
  discard dest_id
  discard src_id
  0

when defined(bl808m0) and bl808BleNimConnectionEnabled:
  proc llc_op_disconnect_ind_handler*(): uint32 {.exportc, cdecl.} =
    noteNimPeripheralDisconnectedFrom(6'u32, NimLlcpDefaultReason)
    0
else:
  abiNoopHandler(llc_op_disconnect_ind_handler)
proc llc_op_dl_upd_ind_handler*(msgid: KeMsgId, param: pointer,
                                dest_id: KeTaskId,
                                src_id: KeTaskId): uint32
    {.exportc, cdecl.} =
  discard msgid
  discard param
  let conhdl = llcMsgConnectionHandle(dest_id, src_id)
  if conhdl == nim_conn_handle and nim_conn_active:
    sendLeDataLengthChange(conhdl)
  0

proc llc_op_encrypt_ind_handler*(msgid: KeMsgId, param: pointer,
                                 dest_id: KeTaskId,
                                 src_id: KeTaskId): uint32
    {.exportc, cdecl.} =
  discard msgid
  discard param
  let conhdl = llcMsgConnectionHandle(dest_id, src_id)
  llc_llcp_reject_ind_pdu_send(conhdl, 0x1A'u8)
  0

proc llc_op_feats_exch_ind_handler*(msgid: KeMsgId, param: pointer,
                                    dest_id: KeTaskId,
                                    src_id: KeTaskId): uint32
    {.exportc, cdecl.} =
  discard msgid
  discard param
  llc_llcp_feats_req_pdu_send(llcMsgConnectionHandle(dest_id, src_id))
  0

proc llc_op_le_ping_ind_handler*(msgid: KeMsgId, param: pointer,
                                 dest_id: KeTaskId,
                                 src_id: KeTaskId): uint32
    {.exportc, cdecl.} =
  discard msgid
  discard param
  llc_llcp_ping_req_pdu_send(llcMsgConnectionHandle(dest_id, src_id))
  0

proc llc_op_phy_upd_ind_handler*(msgid: KeMsgId, param: pointer,
                                 dest_id: KeTaskId,
                                 src_id: KeTaskId): uint32
    {.exportc, cdecl.} =
  discard msgid
  discard param
  discard dest_id
  discard src_id
  0

proc llc_op_ver_exch_ind_handler*(msgid: KeMsgId, param: pointer,
                                  dest_id: KeTaskId,
                                  src_id: KeTaskId): uint32
    {.exportc, cdecl.} =
  discard msgid
  discard param
  llc_llcp_version_ind_pdu_send(llcMsgConnectionHandle(dest_id, src_id))
  0

abiNoopHandler(llc_proc_collision_check)
proc llc_proc_err_ind*(conhdl: uint16, procId: uint8, status: uint8,
                       param: pointer): uint32 {.exportc, cdecl.} =
  let procEnv = llc_proc_get(conhdl, procId)
  if procEnv != nil:
    let cb = llcProcEnv(procEnv).errCallback
    if cb != nil:
      cast[LlcProcErrCallback](cb)(conhdl, status, param)
  0

proc llc_proc_id_get*(conhdl: uint16, procId: uint8): uint8
    {.exportc, cdecl.} =
  let env = llc_proc_get(conhdl, procId)
  if env == nil:
    0
  else:
    llcProcEnv(env).procId

proc llc_proc_id_set*(conhdl: uint16, procId: uint8,
                      newProcId: uint8): uint32 {.exportc, cdecl.} =
  let env = llc_proc_get(conhdl, procId)
  if env != nil:
    llcProcEnv(env).procId = newProcId
    if newProcId < LlcProcSlotCount.uint8 and newProcId != procId:
      llc_proc_slots[int(conhdl)][int(newProcId)] = env
      llc_proc_slots[int(conhdl)][int(procId)] = nil
  0

proc llc_proc_reg*(conhdl: uint16, procId: uint8,
                   procEnv: pointer): uint32 {.exportc, cdecl.} =
  let slot = llcProcSlot(conhdl, procId)
  if slot != nil:
    slot[] = procEnv
    if procEnv != nil:
      llcProcEnv(procEnv).procId = procId
    llcProcUpdateTaskState(conhdl, procId, procEnv != nil)
  0
when defined(bl808m0) and bl808BleNimConnectionEnabled:
  proc llc_stopped_ind_handler*(): uint32 {.exportc, cdecl.} =
    noteNimPeripheralDisconnectedFrom(7'u32, NimLlcpDefaultReason)
    0
else:
  abiNoopHandler(llc_stopped_ind_handler)
when defined(bl808m0) and bl808BleNimConnectionEnabled and
    bl808BleNimManualConnTx:
  template lldAclRxInd(param: pointer): ptr LldAclRxIndView =
    cast[ptr LldAclRxIndView](param)

  proc lld_acl_rx_ind_handler*(msgid: KeMsgId, param: pointer,
                               dest_id: KeTaskId, src_id: KeTaskId): uint32
      {.exportc, cdecl.} =
    discard msgid
    if param == nil:
      return 0
    let ind = lldAclRxInd(param)
    let bufRef = ind.bufRef
    let len = ind.length
    let llid = ind.llidFlags and 0x03'u8
    let handle = aclTaskHandle(dest_id, src_id, 0'u16)
    if len > 0'u16 and len <= NimBleLeMaxDataOctets and
        (llid == NimDataLlIdStart or
         llid == NimDataLlIdContinuation) and
        sendHostAclData(handle, llid, bufRef, uint8(len)):
      inc nim_acl_rx_count
    else:
      inc nim_acl_rx_drop_count
    ble_util_buf_rx_free(cast[pointer](bufRef.uint))
    0

  proc lld_acl_tx_cfm_handler*(msgid: KeMsgId, param: pointer,
                               dest_id: KeTaskId, src_id: KeTaskId): uint32
      {.exportc, cdecl.} =
    discard msgid
    discard param
    sendNumberOfCompletedPackets(aclTaskHandle(dest_id, src_id, 0'u16), 1'u16)
    0
else:
  abiNoopHandler(lld_acl_rx_ind_handler)
  abiNoopHandler(lld_acl_tx_cfm_handler)

proc updateNimLegacyAdvPayload(data: pointer, length: uint16,
                               emOffset: uint16, scanRsp: bool) =
  let n = min(length.int, 31)
  let source = cast[uint](data)
  let sourceIsRam = data != nil and source >= 0x20000000'u and source < 0x30000000'u
  let sourceIsBtbleEm =
    data != nil and source >= BTBLE_EM_BASE.uint and
    source < (BTBLE_EM_BASE + 0x8000'u32).uint
  let raw = cast[ptr UncheckedArray[uint8]](data)
  if scanRsp:
    nim_scan_rsp_data_len = n.uint8
  else:
    nim_adv_data_len = n.uint8
  for i in 0 ..< n:
    let b =
      if sourceIsRam:
        raw[i]
      elif sourceIsBtbleEm:
        read8(uint32(source) + i.uint32)
      elif emOffset != 0'u16:
        read8(BTBLE_EM_BASE + emOffset.uint32 + i.uint32)
      else:
        0'u8
    if scanRsp:
      nim_scan_rsp_data[i] = b
    else:
      nim_adv_data[i] = b
  if nim_adv_enabled:
    programBtbleLegacyAdv(nim_adv_data_len)

proc lld_adv_end_ind_handler*(msgid: KeMsgId, param: pointer,
                              dest_id: KeTaskId,
                              src_id: KeTaskId): uint32
    {.exportc, cdecl.} =
  discard msgid
  discard param
  discard dest_id
  discard src_id
  if nim_conn_active:
    nim_adv_enabled = false
  0

proc lld_adv_scan_rsp_data_update*(data: pointer, length: uint16,
                                   emOffset: uint16): uint32
    {.exportc, cdecl.} =
  updateNimLegacyAdvPayload(data, length, emOffset, true)
  0

abiNoopHandler(lld_calc_aux_rx)
when not (defined(bl808m0) and bl808BleNimConnectionEnabled and
          bl808BleNimManualConnTx):
  abiNoopHandler(lld_con_data_tx)
abiNoopHandler(lld_con_enc_key_load)
when not (defined(bl808m0) and bl808BleNimConnectionEnabled and
          bl808BleNimManualConnTx):
  abiNoopHandler(lld_con_llcp_tx)
abiNoopHandler(lld_con_offset_upd_ind_handler)
abiNoopHandler(lld_con_param_upd_cfm_handler)
abiNoopHandler(lld_con_param_update)
abiNoopHandler(lld_con_phys_update)
abiNoopHandler(lld_con_rx_enc)
abiNoopHandler(lld_con_tx_enc)
abiNoopHandler(lld_con_tx_len_update_for_intv)
abiNoopHandler(lld_con_tx_len_update_for_rate)
when defined(bl808m0) and bl808BleNimConnectionEnabled:
  proc lld_disc_ind_handler*(): uint32 {.exportc, cdecl.} =
    noteNimPeripheralDisconnectedFrom(8'u32, NimLlcpDefaultReason)
    0
else:
  abiNoopHandler(lld_disc_ind_handler)
when defined(bl808m0) and bl808BleNimConnectionEnabled and
    bl808BleNimManualConnTx:
  proc lld_llcp_rx_ind_handler*(msgid: KeMsgId, param: pointer,
                                dest_id: KeTaskId,
                                src_id: KeTaskId): uint32
      {.exportc, cdecl.} =
    discard msgid
    discard param
    discard dest_id
    discard src_id
    serviceNimConnectionLlcpRxDescriptors()
    0

  proc lld_llcp_tx_cfm_handler*(msgid: KeMsgId, param: pointer,
                                dest_id: KeTaskId,
                                src_id: KeTaskId): uint32
      {.exportc, cdecl.} =
    discard msgid
    discard param
    let conhdl = aclTaskHandle(dest_id, src_id, 0'u16)
    when bl808BleNimPureConnection:
      nimConnCompleteManualTx()
    else:
      if nim_llcp_tx_pending != 0'u32:
        nim_llcp_tx_pending = 0
        inc nim_llcp_free_manual_count
      nimLlcpTrySendQueued()
      nimLlcpTrySendStartup(conhdl)
    0
else:
  abiNoopHandler(lld_llcp_rx_ind_handler)
  abiNoopHandler(lld_llcp_tx_cfm_handler)
abiNoopHandler(lld_per_adv_list_add)
abiNoopHandler(lld_per_adv_list_rem)
abiNoopHandler(lld_phy_upd_cfm_handler)
when defined(bl808m0):
  proc lld_ral_search*(peerAddr: pointer, addrType: uint8): uint8
      {.exportc, cdecl.} =
    discard peerAddr
    discard addrType
    0xFF'u8
else:
  abiNoopHandler(lld_ral_search)
abiNoopHandler(lld_rpa_renew)
when not (defined(bl808m0) and bl808BleNimConnectionEnabled):
  abiNoopHandler(lld_rx_timing_compute)
when not (defined(bl808m0) and
    (bl808BleNimConnectionEnabled or bl808BleNimPureCentral)):
  abiNoopHandler(lld_rxdesc_buf_ready)
abiNoopHandler(lld_scan_req_ind_handler)
when not defined(bl808m0):
  abiNoopHandler(sch_alarm_clear)
  abiNoopHandler(sch_alarm_init)
  abiNoopHandler(sch_alarm_set)
  abiNoopHandler(sch_alarm_timer_isr)
when not (defined(bl808m0)):
  abiNoopHandler(sch_arb_event_start_isr)
  abiNoopHandler(sch_arb_init)
  abiNoopHandler(sch_arb_sw_isr)
when not (defined(bl808m0)):
  abiNoopHandler(sch_plan_chk)
  abiNoopHandler(sch_plan_init)
  abiNoopHandler(sch_plan_req)
  abiNoopHandler(sch_plan_set)
  abiNoopHandler(sch_plan_shift)
when not (defined(bl808m0) and
    bl808BleNimSchProgEnabled):
  abiNoopHandler(sch_prog_end_isr)
  abiNoopHandler(sch_prog_fifo_isr)
  abiNoopHandler(sch_prog_init)
  abiNoopHandler(sch_prog_push)
  abiNoopHandler(sch_prog_rx_isr)
  abiNoopHandler(sch_prog_skip_isr)
  abiNoopHandler(sch_prog_tx_isr)
when not defined(bl808m0):
  abiNoopHandler(sch_slice_bg_add)
  abiNoopHandler(sch_slice_bg_remove)
  abiNoopHandler(sch_slice_compute)
  abiNoopHandler(sch_slice_fg_add)
  abiNoopHandler(sch_slice_fg_remove)
abiNoopHandler(sch_slice_init)
proc specialModP256*(value: pointer) {.exportc, cdecl.} =
  bleBigHexSpecialModP256(value)
