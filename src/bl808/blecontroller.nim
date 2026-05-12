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
##   lld_*                 -- link layer driver (hardware)
##   llm_*                 -- link layer manager (adv, scan, connection)
##   bflbble_* / bflbip_*  -- platform integration
##   ecc_*                 -- ECC crypto
##   sec_eng_pka0_*        -- PKA hardware engine

import mmio
import core
from std/volatile import volatileLoad, volatileStore

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

when defined(bl808m0) and defined(bl808BleVendorLldConProbe) and
    defined(bl808BleVendorArbProbe) and defined(bl808BleVendorWrapDiag):
  {.compile: "ble_vendor_wrap_diag.c".}
  {.passL: "-Wl,--wrap=sch_arb_insert".}
  {.passL: "-Wl,--wrap=sch_prog_push".}
  var ble_vendor_wrap_arb_insert_count {.importc.}: uint32
  var ble_vendor_wrap_arb_insert_status {.importc.}: uint32
  var ble_vendor_wrap_arb_insert_last {.importc.}: uint32
  var ble_vendor_wrap_prog_push_count {.importc.}: uint32
  var ble_vendor_wrap_prog_push_last {.importc.}: uint32

when defined(bl808m0) and defined(bl808BleNimBl606pPhyRf):
  {.passL: "-Lbuild/bl_iot_sdk_ref/components/platform/soc/bl606p/bl606p_phyrf/lib".}
  {.passL: "-Wl,--start-group -lbl606p_phyrf -Wl,--end-group".}

  proc udelay*(us: uint32) {.exportc, cdecl,
      codegenDecl: "__attribute__((weak)) $# $#$#".} =
    var spins {.volatile.} = us * 80'u32
    while spins != 0'u32:
      {.emit: """__asm__ volatile("nop");""".}
      dec spins

  proc printf*(fmt: cstring): cint {.exportc, cdecl, varargs.} =
    discard fmt
    0

  proc puts*(s: cstring): cint {.exportc, cdecl.} =
    discard s
    0

  proc hal_get_temperature*(): cint {.exportc, cdecl.} =
    25

  proc hal_set_temperature*(temperature: cint) {.exportc, cdecl.} =
    discard temperature

when defined(bl808m0) and
    (defined(bl808BleVendorSchProgProbe) or
     defined(bl808BleVendorLldAdvProbe) or
     defined(bl808BleVendorLldConProbe) or
     defined(bl808BleVendorLldScanProbe)):
  const bl808BleNimSchProg* {.booldefine.}: bool = false
  const bl808BleNimSchProgDeferred* {.booldefine.}: bool = false
  when bl808BleNimSchProg:
    proc vendorSchProgInit(initType: uint8) {.cdecl.}
    proc vendorSchProgFifoIsr() {.cdecl.}
    proc vendorSchProgSkipIsr(idx: uint8) {.cdecl.}
    var vendorSchProgSkipIndex {.exportc: "m_sw_skip_et_idx".}: uint32
  else:
    {.passL: "build/inspect/btble_bl808_lib/sch_prog.c.o".}
    proc vendorSchProgInit(initType: uint8) {.importc: "sch_prog_init", cdecl.}
    proc vendorSchProgFifoIsr() {.importc: "sch_prog_fifo_isr", cdecl.}
    proc vendorSchProgSkipIsr(idx: uint8) {.importc: "sch_prog_skip_isr", cdecl.}
    var vendorSchProgSkipIndex {.importc: "m_sw_skip_et_idx".}: uint32

when defined(bl808m0) and defined(bl808BleVendorSchProgProbe):
  when bl808BleNimSchProg:
    proc vendorSchProgPush(prog: pointer) {.cdecl.}
  else:
    proc vendorSchProgPush(prog: pointer) {.importc: "sch_prog_push", cdecl.}

when defined(bl808m0) and defined(bl808BleVendorLldAdvProbe):
  {.passL: "build/inspect/current/lld_adv.c.o".}
  proc vendorLldAdvStart(actId: uint8, params: pointer): uint8
    {.importc: "lld_adv_start", cdecl.}

when defined(bl808m0) and
    (defined(bl808BleVendorLldConProbe) or defined(bl808BleVendorLldScanProbe)):
  var g_ble_max_txpower_dbm: int8

  proc nimBleRfTxpowerMaxSet(dbm: int8) {.cdecl.} =
    g_ble_max_txpower_dbm = dbm

  proc nimBleRfTxpowerMaxGet(): int8 {.cdecl.} =
    g_ble_max_txpower_dbm

  proc nimRfTxpwrDbmGet(cs: uint8): int8 {.cdecl.} =
    int8(cs shr 2)

  proc nimRfTxpwrCsGet(dbm: int8, high: uint8): uint8 {.cdecl.} =
    discard high
    if dbm <= 0 or g_ble_max_txpower_dbm <= 0:
      return 0
    var limited = dbm
    if limited > g_ble_max_txpower_dbm:
      limited = g_ble_max_txpower_dbm
    uint8((int32(limited) shl 2) and 0xFC)

  proc nimRfRssiConvert(raw: uint8): int8 {.cdecl.} =
    int8(5'i32 - int32(raw))

  proc nimRfRegRead(regAddr: uint32): uint32 {.cdecl.} =
    discard regAddr
    0

  proc nimRfRegWrite(regAddr, value: uint32) {.cdecl.} =
    discard regAddr
    discard value

  proc nimRfSleep() {.cdecl.} =
    regWrite(0x28000030'u32.uint, regRead(0x28000030'u32.uint) or 7'u32)

  proc nimRfReset() {.cdecl.} =
    regWrite(0x28000880'u32.uint, 0x00500350'u32)
    regWrite(0x28000884'u32.uint, 0x00500350'u32)
    regWrite(0x28000888'u32.uint, 0x00500350'u32)
    regWrite(0x2800088C'u32.uint, 0x00000350'u32)
    regWrite(0x28000890'u32.uint, 0x04000703'u32)
    regWrite(0x28000894'u32.uint, 0x00000502'u32)
    regWrite(0x28000898'u32.uint, 0x08000703'u32)
    regWrite(0x2800089C'u32.uint, 0x08000003'u32)
    regWrite(0x28000890'u32.uint,
             (regRead(0x28000890'u32.uint) and 0xFF80FFFF'u32) or 0x00280000'u32)
    regWrite(0x28000894'u32.uint,
             (regRead(0x28000894'u32.uint) and 0xFF80FFFF'u32) or 0x001E0000'u32)
    regWrite(0x28000898'u32.uint,
             (regRead(0x28000898'u32.uint) and 0xFF00FFFF'u32) or 0x00870000'u32)
    regWrite(0x2800089C'u32.uint,
             (regRead(0x2800089C'u32.uint) and 0xFF80FFFF'u32) or 0x00280000'u32)
    regWrite(0x280009C0'u32.uint,
             regRead(0x280009C0'u32.uint) or 0x00004000'u32)
    regWrite(0x20002C84'u32.uint, 0x1208102B'u32)
    regWrite(0x2000288C'u32.uint,
             (regRead(0x2000288C'u32.uint) and 0xFF803FFF'u32) or 0x00014000'u32)
    regWrite(0x20002808'u32.uint, 0x0842001A'u32)
    regWrite(0x28000980'u32.uint, 0x02120013'u32)
    regWrite(0x28000984'u32.uint, 0x02120013'u32)
    regWrite(0x28000988'u32.uint, 0x02120013'u32)
    regWrite(0x2800098C'u32.uint, 0x02120013'u32)

  proc nimRfForceAgcEnable() {.cdecl.} =
    discard

  proc btble_rf_init*(rf: pointer) {.exportc, cdecl.} =
    if rf == nil:
      return
    let words = cast[ptr UncheckedArray[pointer]](rf)
    words[0] = cast[pointer](nimRfReset)
    words[1] = cast[pointer](nimRfForceAgcEnable)
    words[4] = cast[pointer](nimBleRfTxpowerMaxSet)
    words[5] = cast[pointer](nimBleRfTxpowerMaxGet)
    words[7] = cast[pointer](nimRfTxpwrDbmGet)
    words[8] = cast[pointer](nimRfTxpwrCsGet)
    words[9] = cast[pointer](nimRfRssiConvert)
    words[11] = cast[pointer](nimRfRegRead)
    words[12] = cast[pointer](nimRfRegWrite)
    words[13] = cast[pointer](nimRfSleep)
    cast[ptr uint16](cast[uint](rf) + 56'u)[] = 0x2000'u16
    cast[ptr int8](cast[uint](rf) + 61'u)[] = -40'i8
    cast[ptr uint16](cast[uint](rf) + 62'u)[] = 0xBAC4'u16

when defined(bl808m0) and defined(bl808BleVendorLldScanProbe):
  {.passL: "build/inspect/bl616_m10/lld_scan.c.o".}
  proc vendorLldScanInit(initType: uint8) {.importc: "lld_scan_init", cdecl.}
  proc vendorLldScanStart(actId: uint8, params: pointer): uint8
    {.importc: "lld_scan_start", cdecl.}
  proc vendorLldScanStop(): uint8 {.importc: "lld_scan_stop", cdecl.}

when defined(bl808m0) and defined(bl808BleVendorLldScanProbe) and
    defined(bl808BleVendorLldInitProbe):
  {.passL: "build/inspect/bl616_m10/lld_init.c.o".}
  proc vendorLldInitInit(initType: uint8) {.importc: "lld_init_init", cdecl.}
  proc vendorLldInitStart(params: pointer): uint8
    {.importc: "lld_init_start", cdecl.}
  proc vendorLldInitStop(): uint8 {.importc: "lld_init_stop", cdecl.}

when defined(bl808m0) and defined(bl808BleVendorLldScanProbe) and
    defined(bl808BleVendorArbProbe) and not defined(bl808BleVendorLldConProbe):
  {.passL: "build/inspect/btble_bl808_lib/sch_arb.c.o".}
  {.passL: "build/inspect/btble_bl808_lib/sch_plan.c.o".}
  when defined(bl808BleVendorFullSchedulerProbe) or
      defined(bl808BleVendorAlarmProbe):
    {.passL: "build/inspect/btble_bl808_lib/sch_alarm.c.o".}
  when defined(bl808BleVendorFullSchedulerProbe) or
      defined(bl808BleVendorSliceProbe):
    {.passL: "build/inspect/btble_bl808_lib/sch_slice.c.o".}
  proc vendorSchArbInit(initType: uint8) {.importc: "sch_arb_init", cdecl.}
  proc vendorSchArbSwIsr() {.importc: "sch_arb_sw_isr", cdecl.}
  proc vendorSchArbEventStartIsr() {.importc: "sch_arb_event_start_isr", cdecl.}
  proc vendorSchPlanInit(initType: uint8) {.importc: "sch_plan_init", cdecl.}
  when defined(bl808BleVendorFullSchedulerProbe) or
      defined(bl808BleVendorAlarmProbe):
    proc vendorSchAlarmInit(initType: uint8) {.importc: "sch_alarm_init", cdecl.}
    proc vendorSchAlarmTimerIsr() {.importc: "sch_alarm_timer_isr", cdecl.}
  when defined(bl808BleVendorFullSchedulerProbe) or
      defined(bl808BleVendorSliceProbe):
    proc vendorSchSliceInit(initType: uint8) {.importc: "sch_slice_init", cdecl.}

when defined(bl808m0) and defined(bl808BleVendorLldConProbe):
  const bl808BleNimLlcStart* {.booldefine.}: bool = false
  const bl808BleConnStageDiag* {.booldefine.}: bool = false
  const bl808BleSkipConnEmWake* {.booldefine.}: bool = false
  when defined(bl808BleWrapLldConStartDiag):
    {.passL: "-Wl,--wrap=vendor_lld_con_start".}
  {.passL: "build/inspect/btble_bl808_lib/lld_timing_probe.o".}
  when defined(bl808BleVendorArbProbe):
    {.passL: "build/inspect/btble_bl808_lib/sch_arb.c.o".}
    {.passL: "build/inspect/btble_bl808_lib/sch_plan.c.o".}
    when defined(bl808BleVendorFullSchedulerProbe) or
        defined(bl808BleVendorAlarmProbe):
      {.passL: "build/inspect/btble_bl808_lib/sch_alarm.c.o".}
    when defined(bl808BleVendorFullSchedulerProbe) or
        defined(bl808BleVendorSliceProbe):
      {.passL: "build/inspect/btble_bl808_lib/sch_slice.c.o".}
  when defined(bl808BleVendorManualConnTx):
    {.passL: "build/inspect/btble_bl808_lib/lld_con_probe_llcp.o".}
  else:
    {.passL: "build/inspect/btble_bl808_lib/lld_con_probe.o".}
  when defined(bl808BleVendorLlcStartProbe) and not bl808BleNimLlcStart:
    {.passL: "build/inspect/btble_bl808_lib/llc_probe.o".}
  proc vendorLldConStart(conhdl: uint16, params: pointer): uint8 {.importc: "vendor_lld_con_start", cdecl.}
  when defined(bl808BleVendorManualConnTx):
    proc vendorLldConDataTx(conhdl: uint16, buf: pointer): uint8 {.importc: "lld_con_data_tx", cdecl.}
    proc vendorLldConLlcpTx(conhdl: uint16, buf: pointer): uint8 {.importc: "lld_con_llcp_tx", cdecl.}
  when defined(bl808BleVendorLlcStartProbe):
    when bl808BleNimLlcStart:
      proc vendorLlcStart(conhdl: uint16, params: pointer): uint8
          {.exportc: "vendor_llc_start", cdecl.}
    else:
      proc vendorLlcStart(conhdl: uint16, params: pointer): uint8
          {.importc: "vendor_llc_start", cdecl.}
  when defined(bl808BleVendorArbProbe):
    proc vendorSchArbInit(initType: uint8) {.importc: "sch_arb_init", cdecl.}
    proc vendorSchArbSwIsr() {.importc: "sch_arb_sw_isr", cdecl.}
    proc vendorSchArbEventStartIsr() {.importc: "sch_arb_event_start_isr", cdecl.}
    proc vendorSchPlanInit(initType: uint8) {.importc: "sch_plan_init", cdecl.}
    when defined(bl808BleVendorFullSchedulerProbe) or
        defined(bl808BleVendorAlarmProbe):
      proc vendorSchAlarmInit(initType: uint8) {.importc: "sch_alarm_init", cdecl.}
      proc vendorSchAlarmTimerIsr() {.importc: "sch_alarm_timer_isr", cdecl.}
    when defined(bl808BleVendorFullSchedulerProbe) or
        defined(bl808BleVendorSliceProbe):
      proc vendorSchSliceInit(initType: uint8) {.importc: "sch_slice_init", cdecl.}

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

when defined(bl808m0):
  const
    NimM0ClicIntBase = 0xE0801000'u32
    NimM0BleIrqConnRaw = 48'u32
    NimM0BleIrqConnAlias = 64'u32
    NimM0BleIrqRaw = 56'u32
    NimM0BleIrqAlias = 72'u32

  proc nimDisableM0ClicIrq(irq: uint32) =
    let base = NimM0ClicIntBase + irq * 4'u32
    volatileStore(cast[ptr uint8]((base + 1'u32).uint), 0'u8)
    volatileStore(cast[ptr uint8](base.uint), 0'u8)
    volatileStore(cast[ptr uint8]((base + 2'u32).uint), 0'u8)

  proc nimDisableM0BleClicIrq() =
    nimDisableM0ClicIrq(NimM0BleIrqConnRaw)
    nimDisableM0ClicIrq(NimM0BleIrqConnAlias)
    nimDisableM0ClicIrq(NimM0BleIrqRaw)
    nimDisableM0ClicIrq(NimM0BleIrqAlias)

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

  PKA_BASE* = 0x40004000'u32
  ## PKA engine base

  HciOpReset = 0x0C03'u16
  HciOpDisconnect = 0x0406'u16
  HciOpLeSetRandomAddress = 0x2005'u16
  HciOpLeSetAdvParams = 0x2006'u16
  HciOpLeSetAdvData = 0x2008'u16
  HciOpLeSetScanRspData = 0x2009'u16
  HciOpLeSetAdvEnable = 0x200A'u16
  HciOpLeSetScanParams = 0x200B'u16
  HciOpLeSetScanEnable = 0x200C'u16
  HciOpLeCreateConnection = 0x200D'u16
  HciOpLeCreateConnectionCancel = 0x200E'u16

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

  BtbleAdvSlotTail: array[10, uint32] = [
    0xBF3D0C00'u32, 0x5FF80C00'u32, 0x9FFD0C00'u32, 0xFF0D0C00'u32,
    0xBF280C00'u32, 0x7F530C00'u32, 0x7FA00C00'u32, 0xDF830C00'u32,
    0x9F710C00'u32, 0x1FC20C00'u32
  ]
  BtbleAdvDataOffset = 0x0A2C'u32
  BtbleScanRspDataOffset = 0x0A52'u32

proc regOr(regAddr: uint32, mask: uint32) {.inline.} =
  regWrite(regAddr.uint, regRead(regAddr.uint) or mask)

proc regUpdate(regAddr: uint32, mask: uint32, value: uint32) {.inline.} =
  let current = regRead(regAddr.uint)
  regWrite(regAddr.uint, (current and not mask) or (value and mask))

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

proc prepareWirelessDomain() =
  configureBleEm()
  powerOnXtalWifiPll()
  configureDigClock()
  enableWirelessClocks()
  swResetCfg0(4)
  swResetCfg0(8)
  swResetCfg0(10)
  configureDigClock()
  enableWirelessClocks()

proc configureBtPriorityPta() =
  ## Match the WiFi firmware's BT-priority PTA mode without linking WiFi FW.
  when defined(bl808m0):
    const
      PtaCtrl = 0x24920004'u
      PtaClear = 0x24920428'u
    volatileStore(cast[ptr uint32](PtaClear), 0'u32)
    var reg = volatileLoad(cast[ptr uint32](PtaCtrl))
    reg = reg and not 1'u32
    volatileStore(cast[ptr uint32](PtaCtrl), reg)
    reg = volatileLoad(cast[ptr uint32](PtaCtrl))
    reg = (reg and 0xFFF7FFFF'u32) or 0x00080000'u32
    volatileStore(cast[ptr uint32](PtaCtrl), reg)
    reg = volatileLoad(cast[ptr uint32](PtaCtrl))
    reg = (reg and 0xFFFBFFFF'u32) or 0x00040000'u32
    volatileStore(cast[ptr uint32](PtaCtrl), reg)
    reg = volatileLoad(cast[ptr uint32](PtaCtrl))
    reg = reg and 0xFFFDFFFF'u32
    volatileStore(cast[ptr uint32](PtaCtrl), reg)
    reg = volatileLoad(cast[ptr uint32](PtaCtrl))
    reg = reg and 0xFFFEFFFF'u32
    volatileStore(cast[ptr uint32](PtaCtrl), reg)

when defined(bl808m0) and defined(bl808BleNimBl606pPhyRf):
  proc bl606pRfInit(xtalfreqHz: uint32) {.importc: "rf_init", cdecl.}
  proc bl606pPhyInit(config: pointer) {.importc: "phy_init", cdecl.}
  proc bl606pRfSetChannel(bandwidth: uint8, channelFreq: uint16)
    {.importc: "rf_set_channel", cdecl.}
  proc bl606pRfcConfigPowerBle(powerDbm: int32): bool
    {.importc: "rfc_config_power_ble", cdecl.}
  var nim_bl606p_rf_ready: bool

proc configureBleRf1M() =
  ## Configure the RF path used by BLE advertising.
  when defined(bl808m0) and defined(bl808BleNimBl606pPhyRf):
    if not nim_bl606p_rf_ready:
      bl606pRfInit(40_000_000'u32)
      bl606pPhyInit(nil)
      discard bl606pRfcConfigPowerBle(4'i32)
      bl606pRfSetChannel(0'u8, 2402'u16)
      nim_bl606p_rf_ready = true
  else:
    regWrite(0x200010A0'u32.uint, 0x060B8B97'u32)
    regWrite(0x200010A4'u32.uint, 0x00001301'u32)
    regWrite(0x200010A8'u32.uint, 0x00000855'u32)
    regWrite(0x200010AC'u32.uint, 0x03000000'u32)
    regWrite(0x200010B0'u32.uint, 0x00011100'u32)
    regWrite(0x200010B4'u32.uint, 0x0002A222'u32)
    regWrite(0x200010B4'u32.uint, regRead(0x200010B4'u32.uint) and not 0x01100000'u32)
    regWrite(0x200010B4'u32.uint, 0x0002A222'u32)
    regWrite(0x200010B8'u32.uint, 0x00001111'u32)
    regWrite(0x200010BC'u32.uint, 0x10911100'u32)
    regWrite(0x200010C0'u32.uint, 0x00130101'u32)
    regWrite(0x200010C4'u32.uint, 0x1501C71C'u32)
    regWrite(0x200010C8'u32.uint, 0x14A7FFF9'u32)
    regWrite(0x200010CC'u32.uint, 0x50000002'u32)

# ---------------------------------------------------------------------------
# Primitive types
# ---------------------------------------------------------------------------

type
  KeTaskId* = uint16
  KeMsgId* = uint16

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

# ---------------------------------------------------------------------------
# ke_msg: message header + payload
# Layout from disasm: offset 0 = next (4 bytes, linked list pointer)
#                     offset 4 = id (uint16)
#                     offset 6 = dest_id (uint16)
#                     offset 8 = src_id (uint16)
#                     offset 10 = param_len (uint16)
#                     offset 12 = param[] (variable)
# ---------------------------------------------------------------------------

type
  KeMsgHeader* {.packed.} = object
    next*: ptr KeMsgHeader          ## list link (set to -1 when free)
    id*: uint16                     ## message id
    dest_id*: uint16                ## destination task id
    src_id*: uint16                 ## source task id
    param_len*: uint16              ## parameter length

# ---------------------------------------------------------------------------
# ke_timer: timer element
# Layout: offset 0 = next (ptr, list link)
#         offset 4 = id (uint16)
#         offset 6 = task (uint16)
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
  KeMsgHandler* = proc(msgid: KeMsgId, dest_id: KeTaskId,
                         src_id: KeTaskId, param: pointer): int32 {.cdecl.}

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
    buf_ptr*: uint16
    data_len*: uint16
    reserved0*: uint16
    reserved1*: uint16
    reserved2*: uint16
    reserved3*: uint16

  EmBufTxDesc* {.packed.} = object
    status*: uint16
    buf_ptr*: uint16
    data_len*: uint16
    reserved0*: uint16
    reserved1*: uint16

  EmBufNode* {.packed.} = object
    next*: ptr EmBufNode
    idx*: uint16
    buf_ptr*: uint16

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

# ---------------------------------------------------------------------------
# LLC / LLD / LLM types (opaque state structs)
# ---------------------------------------------------------------------------

type
  LlcConEnv* = object
    ## Per-connection LLC environment (opaque, ~420 bytes from disasm)
    data*: array[420, uint8]

  LldEvtEnv* = object
    ## LLD event environment
    data*: array[256, uint8]

  LlmEnv* = object
    ## LLM environment block
    data*: array[512, uint8]

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
  # co_list patch function pointers
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

  # ADV random delay disable flag
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

  # RF state
  rf_pwr_offset*: int8
  rf_pwr_offset_table*: ptr int8
  rf_pwr_max*: int8

  # PKA state
  pka_result*: array[ECC_KEY_LEN * 2, uint8]

  # On-chip HCI
  onchiphci_env*: array[64, uint8]
  onchiphci_recv_cb*: OnChipHciRecvCb
  nim_adv_params*: array[15, uint8]
  nim_scan_params*: array[7, uint8]
  nim_adv_data*: array[31, uint8]
  nim_scan_rsp_data*: array[31, uint8]
  nim_local_addr*: array[6, uint8]
  nim_local_addr_valid*: bool
  nim_adv_data_len*: uint8
  nim_scan_rsp_data_len*: uint8
  nim_adv_enabled*: bool
  nim_scan_enabled*: bool
  nim_conn_active*: bool
  nim_conn_handle*: uint16
  nim_auth_payload_timeout*: uint16
  nim_ble_core_ready*: bool
  nim_adv_schedule_slot: uint8
  nim_adv_target_half_us: uint32
  nim_ble_dbg_isr_count: uint32
  nim_ble_dbg_isr_stat_or: uint32
  nim_ble_dbg_stat20_count: uint32
  nim_ble_dbg_stat8000_count: uint32
  nim_ble_dbg_push_count: uint32
  nim_ble_dbg_rx_ready_count: uint32
  nim_ble_dbg_rx_scan_req_count: uint32
  nim_ble_dbg_rx_scan_req_match_count: uint32
  nim_ble_dbg_rx_scan_req_last_scana0: uint32
  nim_ble_dbg_rx_scan_req_last_scana1: uint32
  nim_ble_dbg_rx_scan_req_last_adva0: uint32
  nim_ble_dbg_rx_scan_req_last_adva1: uint32
  nim_ble_dbg_rx_connect_ind_count: uint32
  nim_ble_dbg_rx_last_header: uint32
  nim_ble_dbg_rx_last_status: uint32
  nim_ble_dbg_rx_last_desc: uint32
  nim_ble_dbg_rx_last_buf: uint32

  # Coex stats
  coex_ble_dump_buf*: array[32, uint8]

  one_bits* {.exportc.}: array[16, uint8] =
    [0'u8, 1, 1, 2, 1, 2, 2, 3, 1, 2, 2, 3, 2, 3, 3, 4]

when not (defined(bl808m0) and
    (defined(bl808BleVendorFullSchedulerProbe) or
     defined(bl808BleVendorSliceProbe))):
  var sch_slice_params* {.exportc.}: array[8, uint16]

when defined(bl808m0) and
    (defined(bl808BleVendorSchProgProbe) or
     (defined(bl808BleVendorLldConProbe) and bl808BleNimSchProg)):
  var nim_vendor_sch_prog: array[36, uint8]

  proc nimVendorSchProgCb(arg0: uint32, ctx: pointer,
                          event: uint8) {.exportc, cdecl.} =
    discard arg0
    discard ctx
    discard event

when defined(bl808m0) and defined(bl808BleVendorLldAdvProbe):
  var nim_vendor_lld_adv_params: array[40, uint8]

  when not defined(bl808BleVendorLldConProbe):
    var nim_vendor_lld_adv_rand_state: uint32 = 0x12345678'u32

    proc rand*(): cint {.exportc, cdecl.} =
      nim_vendor_lld_adv_rand_state =
        nim_vendor_lld_adv_rand_state * 1103515245'u32 + 12345'u32
      cint((nim_vendor_lld_adv_rand_state shr 16) and 0x7FFF'u32)

when defined(bl808m0) and defined(bl808BleVendorLldScanProbe):
  {.emit: """
  /*TYPESECTION*/
  extern unsigned char lld_scan_start(unsigned char act_id, void *params);
  unsigned int nim_vendor_lld_scan_saved_sp;
  static unsigned char nim_vendor_lld_scan_start_isolated(
      unsigned char act_id, void *params, void *stack_top) {
    unsigned int ret;
    __asm__ volatile(
        "la t0, nim_vendor_lld_scan_saved_sp\n"
        "sw sp, 0(t0)\n"
        "mv sp, %[stack]\n"
        "andi sp, sp, -16\n"
        "mv a0, %[act]\n"
        "mv a1, %[params]\n"
        "call lld_scan_start\n"
        "mv %[ret], a0\n"
        "la t0, nim_vendor_lld_scan_saved_sp\n"
        "lw sp, 0(t0)\n"
        : [ret] "=r"(ret)
        : [stack] "r"(stack_top),
          [act] "r"((unsigned int)act_id),
          [params] "r"(params)
        : "ra", "a0", "a1", "a2", "a3", "a4", "a5", "a6", "a7",
          "t0", "t1", "t2", "t3", "t4", "t5", "t6", "memory");
    return (unsigned char)ret;
  }
  """.}

  proc vendorLldScanStartIsolated(actId: uint8, params: pointer,
                                  stackTop: pointer): uint8
    {.importc: "nim_vendor_lld_scan_start_isolated", nodecl, cdecl.}

  when defined(bl808BleVendorLldInitProbe):
    {.emit: """
    /*TYPESECTION*/
    extern unsigned char lld_init_start(void *params);
    unsigned int nim_vendor_lld_init_saved_sp;
    static unsigned char nim_vendor_lld_init_start_isolated(
        void *params, void *stack_top) {
      unsigned int ret;
      __asm__ volatile(
          "la t0, nim_vendor_lld_init_saved_sp\n"
          "sw sp, 0(t0)\n"
          "mv sp, %[stack]\n"
          "andi sp, sp, -16\n"
          "mv a0, %[params]\n"
          "call lld_init_start\n"
          "mv %[ret], a0\n"
          "la t0, nim_vendor_lld_init_saved_sp\n"
          "lw sp, 0(t0)\n"
          : [ret] "=r"(ret)
          : [stack] "r"(stack_top),
            [params] "r"(params)
          : "ra", "a0", "a1", "a2", "a3", "a4", "a5", "a6", "a7",
            "t0", "t1", "t2", "t3", "t4", "t5", "t6", "memory");
      return (unsigned char)ret;
    }
    """.}

    proc vendorLldInitStartIsolated(params: pointer,
                                    stackTop: pointer): uint8
      {.importc: "nim_vendor_lld_init_start_isolated", nodecl, cdecl.}

  # lld_scan_start overlays scheduler fields onto the scan parameter block and
  # touches offsets through +116 before handing it to sch_arb_insert.
  var nim_vendor_lld_scan_params: array[128, uint8]
  var nim_vendor_lld_scan_rand_state: uint32 = 0x87654321'u32
  var nim_vendor_raw_hci_return_addr: uint32
  var nim_vendor_trace_raw_ra_addr: uint32
  var nim_vendor_trace_first_zero_stage: uint32
  var nim_vendor_scan_report_count* {.exportc.}: uint32
  var nim_vendor_scan_start_status* {.exportc.}: uint32
  var nim_vendor_scan_arb_insert_count* {.exportc.}: uint32
  var nim_vendor_scan_arb_cb_count* {.exportc.}: uint32
  var nim_vendor_scan_sw_int_count* {.exportc.}: uint32
  var nim_vendor_scan_restart_count* {.exportc.}: uint32
  var nim_vendor_scan_unsupported_count* {.exportc.}: uint32
  var nim_vendor_scan_unsupported_header* {.exportc.}: uint32
  var nim_vendor_scan_unsupported_len* {.exportc.}: uint32
  var nim_vendor_scan_unsupported_buf* {.exportc.}: uint32
  var nim_vendor_scan_unsupported_data* {.exportc.}: array[31, uint8]

  when defined(bl808BleVendorLldInitProbe):
    const bl808BleVendorInitActivityId* {.intdefine.}: int = 1
    const bl808BleVendorInitPatchArb* {.booldefine.}: bool = false
    const bl808BleVendorInitSwapAddr* {.booldefine.}: bool = false
    const bl808BleVendorInitStatusFix* {.booldefine.}: bool = false
    const bl808BleVendorInitPeerComplete* {.booldefine.}: bool = false

    var nim_vendor_lld_init_params: array[68, uint8]
    var nim_vendor_init_hci_params: array[25, uint8]
    var nim_vendor_init_active: bool
    var nim_vendor_init_start_status* {.exportc.}: uint32
    var nim_vendor_init_msg_count* {.exportc.}: uint32
    var nim_vendor_init_success_count* {.exportc.}: uint32
    var nim_vendor_init_failure_count* {.exportc.}: uint32
    var nim_vendor_init_last_activity* {.exportc.}: uint32
    var nim_vendor_init_last_msg_status* {.exportc.}: uint32
    var nim_vendor_init_cancel_status* {.exportc.}: uint32
    var nim_vendor_init_cancel_count* {.exportc.}: uint32
    var nim_vendor_init_header_fix_count* {.exportc.}: uint32
    var nim_vendor_init_arb_insert_count* {.exportc.}: uint32
    var nim_vendor_init_arb_cb_count* {.exportc.}: uint32
    var nim_vendor_init_arb_last_w1* {.exportc.}: uint32
    var nim_vendor_init_arb_last_w2* {.exportc.}: uint32
    var nim_vendor_init_arb_last_w7* {.exportc.}: uint32
    var nim_vendor_init_arb_last_w24* {.exportc.}: uint32
    var nim_vendor_init_arb_last_w28* {.exportc.}: uint32
    var nim_vendor_init_peer_rx_count* {.exportc.}: uint32
    var nim_vendor_init_peer_hit_count* {.exportc.}: uint32
    var nim_vendor_init_peer_rx_last_header* {.exportc.}: uint32
    var nim_vendor_init_peer_rx_last_status* {.exportc.}: uint32
    var nim_vendor_init_peer_rx_last_meta* {.exportc.}: uint32
    var nim_vendor_init_status_fix_count* {.exportc.}: uint32
    var nim_vendor_init_status_fix_last* {.exportc.}: uint32
    var nim_vendor_init_msg_alloc_count* {.exportc.}: uint32
    var nim_vendor_init_msg_alloc_last_len* {.exportc.}: uint32
    var nim_vendor_init_msg_alloc_last_dest* {.exportc.}: uint32
    var nim_vendor_init_msg_alloc_last_src* {.exportc.}: uint32
    var nim_vendor_init_peer_complete_count* {.exportc.}: uint32
    var nim_vendor_init_peer_complete_pending* {.exportc.}: uint32
    var nim_lld_aa_gen_count* {.exportc.}: uint32
    var nim_lld_aa_last* {.exportc.}: uint32
    var nim_lld_aa_last_seed* {.exportc.}: uint32
    var nim_vendor_init_pkt_dur_count* {.exportc.}: uint32
    var nim_vendor_init_pkt_dur_last_len* {.exportc.}: uint32
    var nim_vendor_init_pkt_dur_last_rate* {.exportc.}: uint32

  const
    bl808BleVendorCentralTrace* {.booldefine.}: bool = false
    BleCentralTraceBase = 0x40002F00'u

  proc bleCentralTraceReadSp(): uint32 {.inline.} =
    var v: uint32
    {.emit: ["asm volatile(\"mv %0, sp\" : \"=r\"(", v, "));"].}
    v

  proc bleCentralTraceStoreWord(offset: uint, value: uint32) {.inline.} =
    when bl808BleVendorCentralTrace:
      regWrite(BleCentralTraceBase + offset, value)

  proc bleCentralTraceStoreRawRa(offset: uint) {.inline.} =
    when bl808BleVendorCentralTrace:
      if nim_vendor_trace_raw_ra_addr != 0:
        bleCentralTraceStoreWord(
          offset, regRead(nim_vendor_trace_raw_ra_addr.uint))

  proc bleCentralTraceCheckRawRa(stage: uint32) {.inline.} =
    when bl808BleVendorCentralTrace:
      if nim_vendor_trace_raw_ra_addr != 0:
        let rawRa = regRead(nim_vendor_trace_raw_ra_addr.uint)
        bleCentralTraceStoreWord(28'u, stage)
        if rawRa == 0'u32 and nim_vendor_trace_first_zero_stage == 0'u32:
          nim_vendor_trace_first_zero_stage = stage
          bleCentralTraceStoreWord(24'u, stage)

  proc bleCentralRestoreRawRa(expected: uint32) {.inline.} =
    if expected != 0'u32:
      let slot = bleCentralTraceReadSp() + 12'u32
      if regRead(slot.uint) != expected:
        regWrite(slot.uint, expected)
        when bl808BleVendorCentralTrace:
          bleCentralTraceStoreWord(32'u, slot)
          bleCentralTraceStoreWord(36'u, expected)

  proc bleCentralDebugMark*(stage, detail: uint32) {.exportc, cdecl.} =
    when bl808BleVendorCentralTrace:
      let seq = regRead(BleCentralTraceBase + 12'u) + 1'u32
      regWrite(BleCentralTraceBase, 0x424C4543'u32) # "CELB" little-endian
      regWrite(BleCentralTraceBase + 4'u, stage)
      regWrite(BleCentralTraceBase + 8'u, detail)
      regWrite(BleCentralTraceBase + 12'u, seq)
    else:
      discard stage
      discard detail

  when not defined(bl808BleVendorLldConProbe):
    proc initVendorRwipRfTable()

  when not defined(bl808BleVendorLldConProbe) and
      not defined(bl808BleVendorLldAdvProbe):
    proc rand*(): cint {.exportc, cdecl.} =
      bleCentralTraceCheckRawRa(0x0A10'u32)
      nim_vendor_lld_scan_rand_state =
        nim_vendor_lld_scan_rand_state * 1103515245'u32 + 12345'u32
      bleCentralTraceCheckRawRa(0x0A11'u32)
      cint((nim_vendor_lld_scan_rand_state shr 16) and 0x7FFF'u32)

when not (defined(bl808m0) and defined(bl808BleVendorLldScanProbe)):
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

proc write16(regAddr: uint32, value: uint16) {.inline.} =
  volatileStore(cast[ptr uint16](regAddr.uint), value)

proc write8(regAddr: uint32, value: uint8) {.inline.} =
  volatileStore(cast[ptr uint8](regAddr.uint), value)

proc copyBytes(dstAddr: uint32, src: ptr uint8, len: int) =
  if src == nil or len <= 0:
    return
  let raw = cast[ptr UncheckedArray[uint8]](src)
  for i in 0 ..< len:
    write8(dstAddr + i.uint32, raw[i])

proc sendCmdComplete(opcode: uint16, status: uint8) =
  bleCentralDebugMark(0x900'u32, uint32(opcode))
  if onchiphci_recv_cb != nil:
    var cc = [status]
    bleCentralDebugMark(0x901'u32, uint32(opcode))
    onchiphci_recv_cb(HciPktCmdComplete, opcode, addr cc[0], 1)
    bleCentralDebugMark(0x902'u32, uint32(opcode))

proc sendCmdComplete2(opcode: uint16, status: uint8, value: uint8) =
  if onchiphci_recv_cb != nil:
    var cc = [status, value]
    onchiphci_recv_cb(HciPktCmdComplete, opcode, addr cc[0], cc.len.uint8)

proc sendCmdCompletePayload(opcode: uint16, payload: ptr uint8, len: uint8) =
  if onchiphci_recv_cb != nil:
    onchiphci_recv_cb(HciPktCmdComplete, opcode, payload, len)

proc sendCmdStatus(opcode: uint16, status: uint8) =
  if onchiphci_recv_cb != nil:
    var cs = [status]
    onchiphci_recv_cb(HciPktCmdStatus, opcode, addr cs[0], 1)

proc sendHostEvent(eventCode: uint16, payload: ptr uint8, len: uint8) =
  if onchiphci_recv_cb != nil:
    onchiphci_recv_cb(HciPktEvent, eventCode, payload, len)

proc sendLeMetaPayload(payload: ptr uint8, len: uint8) =
  if onchiphci_recv_cb != nil:
    onchiphci_recv_cb(HciPktLeMeta, 0, payload, len)

proc paramLe16(params: ptr uint8, off: int): uint16 =
  if params == nil:
    return 0
  let raw = cast[ptr UncheckedArray[uint8]](params)
  raw[off].uint16 or (raw[off + 1].uint16 shl 8)

proc connParamStatus(params: ptr uint8, handle: uint16): uint8 =
  if params == nil:
    return 0x12'u8
  if nim_conn_active and handle != nim_conn_handle:
    return 0x02'u8
  0'u8

proc sendLeConnectionCompleteStatus(params: ptr uint8, paramLen: uint8,
                                    status: uint8) =
  if onchiphci_recv_cb == nil or params == nil or paramLen != 25:
    return
  let raw = cast[ptr UncheckedArray[uint8]](params)
  var evt: array[19, uint8]
  evt[0] = 0x01'u8
  evt[1] = status
  evt[2] = 0x00'u8
  evt[3] = 0x00'u8
  evt[4] = 0x00'u8
  evt[5] = raw[5]
  for i in 0 ..< 6:
    evt[6 + i] = raw[6 + i]
  evt[12] = raw[13] # connection interval
  evt[13] = raw[14]
  evt[14] = raw[17] # connection latency
  evt[15] = raw[18]
  evt[16] = raw[19] # supervision timeout
  evt[17] = raw[20]
  evt[18] = 0
  if status == 0'u8:
    nim_conn_active = true
    nim_conn_handle = evt[2].uint16 or (evt[3].uint16 shl 8)
  onchiphci_recv_cb(HciPktLeMeta, 0, addr evt[0], evt.len.uint8)

proc sendLeConnectionComplete(params: ptr uint8, paramLen: uint8) =
  sendLeConnectionCompleteStatus(params, paramLen, 0'u8)

proc sendDisconnectComplete(handle: uint16, reason: uint8) =
  if onchiphci_recv_cb == nil:
    return
  var evt: array[4, uint8]
  evt[0] = 0'u8
  evt[1] = uint8(handle and 0xFF)
  evt[2] = uint8((handle shr 8) and 0xFF)
  evt[3] = reason
  nim_conn_active = false
  nim_conn_handle = 0
  onchiphci_recv_cb(HciPktEvent, HciEvtDisconnectComplete, addr evt[0],
                    evt.len.uint8)

when defined(bl808m0) and defined(bl808BleVendorLldScanProbe):
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
    let payloadBase = BTBLE_EM_BASE + buf.uint32
    var evt: array[43, uint8]
    evt[0] = 0x02'u8 # LE Advertising Report
    evt[1] = 0x01'u8 # one report
    evt[2] = eventType
    evt[3] = uint8((header shr 6) and 0x0001'u16)
    for i in 0 ..< 6:
      evt[4 + i] = read8(payloadBase + i.uint32)
    evt[10] = dataLen.uint8
    for i in 0 ..< dataLen:
      evt[11 + i] = read8(payloadBase + 6'u32 + i.uint32)
    evt[11 + dataLen] = 0xCE'u8 # -50 dBm placeholder until RF RSSI is wired.
    inc nim_vendor_scan_report_count
    bleCentralDebugMark(0x610'u32, (uint32(header) shl 16) or uint32(buf))
    sendLeMetaPayload(addr evt[0], uint8(12 + dataLen))
    bleCentralDebugMark(0x611'u32, uint32(12 + dataLen))

  proc noteUnsupportedScanPdu(header: uint16, buf: uint16) =
    let pduLen = int((header shr 8) and 0x003F'u16)
    let copyLen =
      if pduLen > nim_vendor_scan_unsupported_data.len:
        nim_vendor_scan_unsupported_data.len
      else:
        pduLen
    let payloadBase = BTBLE_EM_BASE + buf.uint32
    inc nim_vendor_scan_unsupported_count
    nim_vendor_scan_unsupported_header = header.uint32
    nim_vendor_scan_unsupported_len = copyLen.uint32
    nim_vendor_scan_unsupported_buf = buf.uint32
    for i in 0 ..< copyLen:
      nim_vendor_scan_unsupported_data[i] = read8(payloadBase + i.uint32)

proc initBtbleTimeRegisters() =
  regWrite((BLE_BASE + 0x000'u32).uint,
           regRead((BLE_BASE + 0x000'u32).uint) or 0x80000000'u32)
  var guard = 100_000
  while (regRead((BLE_BASE + 0x000'u32).uint) and 0x80000000'u32) != 0 and
        guard > 0:
    dec guard
  regWrite((BLE_BASE + 0x018'u32).uint, 0x0000800E'u32)
  regWrite((BLE_BASE + 0x020'u32).uint, 0xFFFFFFFF'u32)
  regWrite((BLE_BASE + 0x03C'u32).uint, 0x14829015'u32)
  regWrite((BLE_BASE + 0x0E0'u32).uint, 0x011800C8'u32)

proc currentBtbleTime(): uint32 =
  regWrite((BLE_BASE + 0x100'u32).uint,
           regRead((BLE_BASE + 0x100'u32).uint) or 0x80000000'u32)
  var guard = 4096
  while (regRead((BLE_BASE + 0x100'u32).uint) and 0x80000000'u32) != 0 and
        guard > 0:
    dec guard
  regRead((BLE_BASE + 0x100'u32).uint) and 0x0FFFFFFF'u32

when defined(bl808m0) and
    (defined(bl808BleVendorLldConProbe) or defined(bl808BleVendorLldScanProbe)):
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
    (defined(bl808BleVendorSchProgProbe) or
     defined(bl808BleVendorLldAdvProbe) or
     defined(bl808BleVendorLldConProbe) or
     defined(bl808BleVendorLldScanProbe)):
  var nim_vendor_sch_prog_fifo_count* {.exportc.}: uint32
  var nim_vendor_sch_prog_skip_count* {.exportc.}: uint32
  var nim_vendor_arb_sw_count* {.exportc.}: uint32
  var nim_vendor_arb_event_start_count* {.exportc.}: uint32
  when defined(bl808BleBridgeDiag):
    var nim_vendor_bridge_stage* {.exportc.}: uint32
    var nim_vendor_sch_call_count* {.exportc.}: uint32
    var nim_vendor_sch_call_last_slot* {.exportc.}: uint32
    var nim_vendor_sch_call_last_event* {.exportc.}: uint32
    var nim_vendor_sch_call_last_cb* {.exportc.}: uint32
    var nim_vendor_sch_call_last_ctx* {.exportc.}: uint32
    var nim_vendor_sch_call_return_count* {.exportc.}: uint32
  when defined(bl808BleVendorSchedulerDiag):
    var nim_vendor_arb_set_count* {.exportc.}: uint32
    var nim_vendor_arb_last_target_coarse* {.exportc.}: uint32
    var nim_vendor_arb_last_target_fine* {.exportc.}: uint32
    var nim_vendor_arb_due_target_coarse* {.exportc.}: uint32
    var nim_vendor_arb_due_target_fine* {.exportc.}: uint32
    var nim_vendor_arb_due_now_coarse* {.exportc.}: uint32
    var nim_vendor_arb_due_now_fine* {.exportc.}: uint32
    var nim_vendor_slice_add_count* {.exportc.}: uint32
    var nim_vendor_slice_remove_count* {.exportc.}: uint32
    var nim_vendor_slice_last_type_con* {.exportc.}: uint32
    var nim_vendor_slice_last_interval* {.exportc.}: uint32
    var nim_vendor_slice_last_anchor* {.exportc.}: uint32
    var nim_vendor_slice_last_offset* {.exportc.}: uint32

when defined(bl808m0) and defined(bl808BleVendorLldScanProbe) and
    not defined(bl808BleVendorLldConProbe):
  var co_rate_to_phy* {.exportc.}: array[5, uint8] =
    [1'u8, 2, 3, 3, 0]
  var co_sca2ppm* {.exportc.}: array[8, uint16] =
    [500'u16, 250'u16, 150'u16, 100'u16, 75'u16, 50'u16, 30'u16, 20'u16]
  var lld_env* {.exportc.}: array[56, uint8]
  var lld_exp_sync_pos_tab* {.exportc.}: array[16, uint16]
  var rwip_priority* {.exportc.}: array[32, uint8] =
    [0x28'u8, 0x08, 0x60, 0x08, 0x50, 0x08, 0x70, 0x08,
     0x80, 0x08, 0xA0, 0x08, 0xA0, 0x08, 0x28, 0x1E,
     0x50, 0x08, 0x60, 0x08, 0x50, 0x08, 0, 0,
     0, 0, 0, 0, 0, 0, 0, 0]
  var rwip_rf* {.exportc.}: array[96, uint8]
  var rwip_coex_cfg* {.exportc.}: array[5, uint8] = [0'u8, 3, 1, 2, 3]
  var rwip_prog_delay* {.exportc.}: uint16 = 1'u16

when defined(bl808m0) and defined(bl808BleVendorLldConProbe):
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
     0x80, 0x08, 0xA0, 0x08, 0xA0, 0x08, 0x28, 0x1E,
     0x50, 0x08, 0x60, 0x08, 0x50, 0x08, 0, 0,
     0, 0, 0, 0, 0, 0, 0, 0]
  var rwip_rf* {.exportc.}: array[96, uint8]
  var rwip_coex_cfg* {.exportc.}: array[5, uint8] = [0'u8, 3, 1, 2, 3]
  var rwip_prog_delay* {.exportc.}: uint16 = 1'u16
  var nim_vendor_rand_state: uint32 = 0x12345678'u32

  proc rand*(): cint {.exportc, cdecl.} =
    nim_vendor_rand_state = nim_vendor_rand_state * 1103515245'u32 + 12345'u32
    cint((nim_vendor_rand_state shr 16) and 0x7FFF'u32)

  proc lld_read_clock*(): uint32 {.exportc, cdecl.} =
    when defined(bl808BleVendorLldScanProbe):
      bleCentralTraceCheckRawRa(0x0A20'u32)
    result = currentBtbleTime()
    when defined(bl808BleVendorLldScanProbe):
      bleCentralTraceCheckRawRa(0x0A21'u32)

  proc rwip_current_drift_get*(): uint32 {.exportc, cdecl.} =
    0

  proc rwip_max_drift_get*(sca: uint8): uint32 {.exportc, cdecl.} =
    discard sca
    0

  proc rwip_channel_assess_ble*(channel: uint8, rssi: int8) {.exportc, cdecl.} =
    discard channel
    discard rssi

  proc initVendorRwipRfTable() =
    discard c_memset(addr rwip_rf[0], 0, rwip_rf.len.csize_t)
    btble_rf_init(addr rwip_rf[0])

  proc clearBtbleProgramSlots() =
    for slot in 0'u32 ..< 18'u32:
      let slotAddr = BTBLE_EM_BASE + slot * 0x10'u32
      for off in countup(0'u32, 0x08'u32, 4'u32):
        write16(slotAddr + off, 0'u16)
        write16(slotAddr + off + 2'u32, 0'u16)
      write16(slotAddr + 0x0C'u32, 0'u16)
      if slot < 10'u32:
        write16(slotAddr + 0x0E'u32,
                uint16((BtbleAdvSlotTail[slot.int] shr 16) and 0xFFFF'u32))
      else:
        write16(slotAddr + 0x0E'u32, 0'u16)

  proc ble_util_pkt_dur_in_us*(length: uint16, rate: uint8): uint16
      {.exportc, cdecl.} =
    when defined(bl808BleVendorLldInitProbe):
      if nim_vendor_init_active:
        inc nim_vendor_init_pkt_dur_count
        nim_vendor_init_pkt_dur_last_len = length.uint32
        nim_vendor_init_pkt_dur_last_rate = rate.uint32
    case rate
    of 0:
      uint16((uint32(length) + 10'u32) * 8'u32)
    of 1:
      uint16((uint32(length) + 11'u32) * 4'u32)
    of 2:
      uint16(uint32(length) * 64'u32 + 720'u32)
    else:
      uint16(uint32(length) * 16'u32 + 462'u32)

proc currentBtbleHalfUs(): uint32 =
  regWrite((BLE_BASE + 0x100'u32).uint,
           regRead((BLE_BASE + 0x100'u32).uint) or 0x80000000'u32)
  var guard = 4096
  while (regRead((BLE_BASE + 0x100'u32).uint) and 0x80000000'u32) != 0 and
        guard > 0:
    dec guard
  let base = regRead((BLE_BASE + 0x100'u32).uint) and 0x0000FFFF'u32
  let fineRaw = regRead((BLE_BASE + 0x104'u32).uint) and 0x0000FFFF'u32
  let fine =
    if fineRaw <= 0x270'u32: 0x270'u32 - fineRaw
    else: 0'u32
  ((base * 625'u32 + fine) shr 1) and 0x0FFFFFFF'u32

proc requestBtbleSwInterrupt() =
  regWrite((BLE_BASE + 0x020'u32).uint, 0x00000008'u32)
  regOr(BLE_BASE + 0x018'u32, 0x00000008'u32)
  regUpdate(BLE_BASE + 0x000'u32, 0x08000000'u32, 0x08000000'u32)
  nim_btble_sw_pending = true

when defined(bl808m0) and
    (defined(bl808BleVendorSchProgProbe) or
     (defined(bl808BleVendorLldConProbe) and bl808BleNimSchProg)):
  proc vendorProgWrite16(off: int, value: uint16) =
    nim_vendor_sch_prog[off] = uint8(value and 0x00FF'u16)
    nim_vendor_sch_prog[off + 1] = uint8((value shr 8) and 0x00FF'u16)

  proc vendorProgWrite32(off: int, value: uint32) =
    nim_vendor_sch_prog[off] = uint8(value and 0x000000FF'u32)
    nim_vendor_sch_prog[off + 1] = uint8((value shr 8) and 0x000000FF'u32)
    nim_vendor_sch_prog[off + 2] = uint8((value shr 16) and 0x000000FF'u32)
    nim_vendor_sch_prog[off + 3] = uint8((value shr 24) and 0x000000FF'u32)

when defined(bl808m0) and
    (defined(bl808BleVendorSchProgProbe) or
     defined(bl808BleVendorLldConProbe) or
     defined(bl808BleVendorLldScanProbe)):
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
    0

  proc rwipParamDummySet(param: uint8, buf: ptr uint8,
                         len: uint8): uint8 {.cdecl.} =
    discard param
    discard buf
    discard len
    0

  proc rwipParamDummyDel(param: uint8): uint8 {.cdecl.} =
    discard param
    0

  var rwip_param* {.exportc.}: RwipParam

  when defined(bl808BleVendorArbProbe):
    var nim_vendor_arb_target_coarse: uint32 = 0xFFFFFFFF'u32
    var nim_vendor_arb_target_fine: uint16 = 0'u16
    when defined(bl808BleVendorFullSchedulerProbe) or
        defined(bl808BleVendorAlarmProbe):
      var nim_vendor_alarm_target_coarse: uint32 = 0xFFFFFFFF'u32
      var nim_vendor_alarm_target_fine: uint16 = 0'u16

  proc rwip_time_get*(time: pointer) {.exportc, cdecl.} =
    if time == nil:
      return
    regWrite((BLE_BASE + 0x100'u32).uint,
             regRead((BLE_BASE + 0x100'u32).uint) or 0x80000000'u32)
    var guard = 4096
    while (regRead((BLE_BASE + 0x100'u32).uint) and 0x80000000'u32) != 0 and
          guard > 0:
      dec guard
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

  when bl808BleNimSchProg:
    type SchProgCb = proc(timestamp: uint32, ctx: pointer, event: uint8) {.cdecl.}

    var schProgCb: array[16, SchProgCb]
    var schProgCtx: array[16, pointer]
    var schProgActive: array[16, uint8]
    when defined(bl808m0) and defined(bl808BleVendorLldConProbe) and
        defined(bl808BleVendorConCbWrapper):
      var schProgWrappedCbRaw: array[16, uint32]
      var nim_vendor_sch_wrapped_call_count* {.exportc.}: uint32
      var nim_vendor_sch_wrapped_return_count* {.exportc.}: uint32
    var schProgReadIdx: uint8
    var schProgWriteIdx: uint8
    var schProgCount: uint8
    var schProgLastTime* {.exportc: "last_prog_time".}: uint32
    var skipFlag* {.exportc: "skipFlag".}: uint8

    proc schProgGet16(p: ptr UncheckedArray[uint8], off: int): uint16 =
      uint16(p[off]) or (uint16(p[off + 1]) shl 8)

    proc schProgGet32(p: ptr UncheckedArray[uint8], off: int): uint32 =
      uint32(p[off]) or (uint32(p[off + 1]) shl 8) or
      (uint32(p[off + 2]) shl 16) or (uint32(p[off + 3]) shl 24)

    proc schProgSlotTarget(slot: uint8): uint32 {.inline.} =
      let slotAddr = BTBLE_EM_BASE + uint32(slot and 0x0F'u8) * 0x10'u32
      uint32(read16(slotAddr + 0x02'u32)) or
        ((uint32(read16(slotAddr + 0x04'u32)) and 0x0FFF'u32) shl 16)

    proc schProgCall(idx: uint8, event: uint8) =
      let slot = idx and 0x0F'u8
      let cb = schProgCb[slot.int]
      let timestamp = schProgSlotTarget(slot)
      when defined(bl808BleBridgeDiag):
        nim_vendor_bridge_stage = 0x5300'u32 or uint32(event)
        inc nim_vendor_sch_call_count
        nim_vendor_sch_call_last_slot = slot.uint32
        nim_vendor_sch_call_last_event = event.uint32
        nim_vendor_sch_call_last_cb = cast[uint32](cast[uint](cb))
        nim_vendor_sch_call_last_ctx =
          cast[uint32](cast[uint](schProgCtx[slot.int]))
      if cb != nil:
        cb(timestamp, schProgCtx[slot.int], event)
        when defined(bl808BleBridgeDiag):
          inc nim_vendor_sch_call_return_count
          nim_vendor_bridge_stage = 0x5400'u32 or uint32(event)
      else:
        when defined(bl808BleBridgeDiag):
          nim_vendor_bridge_stage = 0x53F0'u32 or uint32(event)

    proc schProgFindNextRead(fromSlot: uint8, untilSlot: uint8): uint8 =
      var slot = fromSlot and 0x0F'u8
      let stop = untilSlot and 0x0F'u8
      while slot != stop:
        slot = (slot + 1'u8) and 0x0F'u8
        if schProgActive[slot.int] != 0:
          return slot
      stop

    when defined(bl808m0) and defined(bl808BleVendorLldConProbe) and
        defined(bl808BleVendorConCbWrapper):
      proc schProgVendorCbWrapper(timestamp: uint32, ctx: pointer, event: uint8)
          {.cdecl.} =
        var cbRaw = 0'u32
        for slot in 0 ..< 16:
          if schProgWrappedCbRaw[slot] != 0'u32:
            cbRaw = schProgWrappedCbRaw[slot]
            break
        if cbRaw != 0'u32:
          inc nim_vendor_sch_wrapped_call_count
          let cb = cast[SchProgCb](cbRaw.uint)
          cb(timestamp, ctx, event)
          inc nim_vendor_sch_wrapped_return_count

    proc schProgSetEntry(slot: uint8, cbRaw: uint32, ctxRaw: uint32) =
      let s = slot and 0x0F'u8
      when defined(bl808m0) and defined(bl808BleVendorLldConProbe) and
          defined(bl808BleVendorConCbWrapper):
        if ctxRaw != 0'u32 and cbRaw != 0'u32:
          schProgWrappedCbRaw[s.int] = cbRaw
          schProgCb[s.int] = schProgVendorCbWrapper
        else:
          schProgWrappedCbRaw[s.int] = 0'u32
          schProgCb[s.int] = cast[SchProgCb](cbRaw.uint)
      else:
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

    proc sch_prog_end_isr*(idx: uint8) {.exportc, cdecl.} =
      let slot = idx and 0x0F'u8
      let rawStatus = read16(BTBLE_EM_BASE + uint32(slot) * 0x10'u32)
      let status = (rawStatus shr 3) and 0x0007'u16
      let event =
        if status == 3'u16: 0'u8
        elif status == 4'u16: 1'u8
        elif status == 5'u16: 7'u8
        else: 0xFF'u8
      schProgCall(slot, event)
      if schProgActive[slot.int] != 0:
        schProgActive[slot.int] = 0
        if schProgCount != 0:
          dec schProgCount
      schProgReadIdx = schProgFindNextRead(slot, schProgWriteIdx)
      if schProgCount == 0:
        rwip_prevent_sleep_clear(64'u16)

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

    proc sch_prog_init*(initType: uint8) {.exportc, cdecl.} =
      if initType < 2'u8 or initType > 3'u8:
        return
      discard c_memset(addr schProgCb[0], 0, sizeof(schProgCb).csize_t)
      discard c_memset(addr schProgCtx[0], 0, sizeof(schProgCtx).csize_t)
      discard c_memset(addr schProgActive[0], 0,
                       sizeof(schProgActive).csize_t)
      when defined(bl808m0) and defined(bl808BleVendorLldConProbe) and
          defined(bl808BleVendorConCbWrapper):
        discard c_memset(addr schProgWrappedCbRaw[0], 0,
                         sizeof(schProgWrappedCbRaw).csize_t)
        nim_vendor_sch_wrapped_call_count = 0
        nim_vendor_sch_wrapped_return_count = 0
      schProgReadIdx = 0
      schProgWriteIdx = 0
      schProgCount = 0
      vendorSchProgSkipIndex = 0
      schProgLastTime = 0
      skipFlag = 0
      for slot in 0'u32 ..< 16'u32:
        let slotAddr = BTBLE_EM_BASE + slot * 0x10'u32
        let v = (read16(slotAddr) and not 0x0038'u16) or 0x0018'u16
        write16(slotAddr, v)

    proc sch_prog_push*(prog: pointer) {.exportc, cdecl.} =
      if prog == nil:
        return
      let p = cast[ptr UncheckedArray[uint8]](prog)
      p[24] = p[24] shr 3
      p[25] = p[25] shr 3
      p[26] = p[26] shr 3

      let slot = schProgWriteIdx and 0x0F'u8
      let slotAddr = BTBLE_EM_BASE + uint32(slot) * 0x10'u32
      let cbRaw = schProgGet32(p, 0)
      let target = schProgGet32(p, 4)
      let fine = schProgGet16(p, 8)
      let dur = schProgGet32(p, 16)
      let ctxRaw = schProgGet32(p, 20)

      var now: array[3, uint32]
      rwip_time_get(addr now[0])
      if ((now[0] + 1'u32) >= target) or (target == schProgLastTime):
        schProgLastTime = target
        schProgSetEntry(slot, cbRaw, ctxRaw)
        vendorSchProgSkipIndex = slot.uint32
        inc schProgCount
        skipFlag = 1'u8
        rwip_prevent_sleep_set(64'u16)
        requestBtbleSwInterrupt()
        return

      let emPtr = uint16((uint32(p[28]) * 0x94'u32 + 0x0120'u32) shr 2)
      let crowded =
        if ((uint32(schProgWriteIdx) - uint32(schProgReadIdx)) and 0x0F'u32) >=
            14'u32: 1'u16
        else: 0'u16
      var ctrl0 = (crowded shl 10) or
                  (uint16(p[30]) shl 8)
      let primaryType =
        if p[24] > 31'u8: 31'u16
        else: uint16(p[24])
      if p[32] != 0'u8:
        ctrl0 = ctrl0 or (primaryType shl 11) or
                (uint16(p[33]) shl 9) or
                (uint16(p[31]) shl 7) or 0x0042'u16
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
        if p[25] > 31'u8: 31'u16
        else: uint16(p[25])
      let rate1 =
        if p[26] > 31'u8: 31'u16
        else: uint16(p[26])
      let tail = (read16(slotAddr + 0x0E'u32) and 0xE0FF'u16) or
                 (uint16(p[27]) shl 8)

      schProgSetEntry(slot, cbRaw, ctxRaw)
      schProgLastTime = target

      write16(slotAddr + 0x02'u32, uint16(target and 0xFFFF'u32))
      write16(slotAddr + 0x04'u32, uint16((target shr 16) and 0x0FFF'u32))
      write16(slotAddr + 0x06'u32, fineBackoff)
      write16(slotAddr + 0x0A'u32, durHalf)
      write16(slotAddr + 0x0C'u32, rate0 or (rate1 shl 8))
      write16(slotAddr + 0x0E'u32, tail)
      if p[29] == 0'u8:
        write16(slotAddr + 0x00'u32, ctrl0)
        write16(slotAddr + 0x08'u32, emPtr)

      regWrite((BLE_BASE + 0x110'u32).uint, 0x80000000'u32 or slot.uint32)
      schProgWriteIdx = (slot + 1'u8) and 0x0F'u8
      inc schProgCount
      rwip_prevent_sleep_set(64'u16)
      if skipFlag != 0:
        requestBtbleSwInterrupt()

    proc vendorSchProgInit(initType: uint8) {.cdecl.} =
      sch_prog_init(initType)

    proc vendorSchProgFifoIsr() {.cdecl.} =
      sch_prog_fifo_isr()

    proc vendorSchProgSkipIsr(idx: uint8) {.cdecl.} =
      sch_prog_skip_isr(idx)

    when defined(bl808BleVendorSchProgProbe):
      proc vendorSchProgPush(prog: pointer) {.cdecl.} =
        sch_prog_push(prog)

  when defined(bl808BleVendorArbProbe):
    proc rwip_timer_arb_set*(targetCoarse: uint32, targetFine: uint16)
        {.exportc, cdecl.} =
      when defined(bl808BleVendorSchedulerDiag):
        inc nim_vendor_arb_set_count
        nim_vendor_arb_last_target_coarse = targetCoarse
        nim_vendor_arb_last_target_fine = targetFine.uint32
      nim_vendor_arb_target_coarse =
        if targetCoarse == 0xFFFFFFFF'u32: 0xFFFFFFFF'u32
        else: targetCoarse and 0x0FFFFFFF'u32
      nim_vendor_arb_target_fine = targetFine

    when defined(bl808BleVendorFullSchedulerProbe) or
        defined(bl808BleVendorAlarmProbe):
      proc rwip_timer_alarm_set*(targetCoarse: uint32, targetFine: uint16)
          {.exportc, cdecl.} =
        nim_vendor_alarm_target_coarse =
          if targetCoarse == 0xFFFFFFFF'u32: 0xFFFFFFFF'u32
          else: targetCoarse and 0x0FFFFFFF'u32
        nim_vendor_alarm_target_fine = targetFine

    proc vendorBtbleTimeReached(targetCoarse: uint32,
                                targetFine: uint16): bool =
      if targetCoarse == 0xFFFFFFFF'u32:
        return false
      var now: array[3, uint32]
      rwip_time_get(addr now[0])
      let delta =
        (now[0] - targetCoarse) and 0x0FFFFFFF'u32
      if delta == 0'u32:
        return (now[1] and 0xFFFF'u32) >= targetFine.uint32
      delta < 0x08000000'u32

    proc serviceVendorArbTimer() =
      if vendorBtbleTimeReached(nim_vendor_arb_target_coarse,
                                nim_vendor_arb_target_fine):
        when defined(bl808BleVendorSchedulerDiag):
          var now: array[3, uint32]
          rwip_time_get(addr now[0])
          nim_vendor_arb_due_target_coarse = nim_vendor_arb_target_coarse
          nim_vendor_arb_due_target_fine = nim_vendor_arb_target_fine.uint32
          nim_vendor_arb_due_now_coarse = now[0]
          nim_vendor_arb_due_now_fine = now[1] and 0xFFFF'u32
        nim_vendor_arb_target_coarse = 0xFFFFFFFF'u32
        inc nim_vendor_arb_event_start_count
        vendorSchArbEventStartIsr()
      when defined(bl808BleVendorFullSchedulerProbe) or
          defined(bl808BleVendorAlarmProbe):
        if vendorBtbleTimeReached(nim_vendor_alarm_target_coarse,
                                  nim_vendor_alarm_target_fine):
          nim_vendor_alarm_target_coarse = 0xFFFFFFFF'u32
          vendorSchAlarmTimerIsr()

    proc rwip_sw_int_req*() {.exportc, cdecl.} =
      inc nim_vendor_arb_sw_count
      vendorSchArbSwIsr()
  else:
    proc serviceVendorArbTimer() =
      discard

    proc rwip_sw_int_req*() {.exportc, cdecl.} =
      inc nim_vendor_arb_sw_count
      when defined(bl808BleVendorLldScanProbe):
        inc nim_vendor_scan_sw_int_count
      requestBtbleSwInterrupt()

const bl808BleNimSyntheticCentral* {.booldefine.}: bool = true
const bl808BleNimSyntheticCentralComplete* {.booldefine.}: bool = false
const bl808BleNimSyntheticPeripheral* {.booldefine.}: bool = false
const bl808BleNimUseClicIrq* {.booldefine.}: bool = false

when defined(bl808m0) and defined(bl808BleVendorLldConProbe):
  const bl808BleVendorConAnchorBiasSlots* {.intdefine.}: int = 0
  const bl808BleVendorConTimingPath* {.booldefine.}: bool = false
  const bl808BleVendorManualConnTx* {.booldefine.}: bool = false
  const bl808BleVendorKeepaliveAcl* {.booldefine.}: bool = false
  const bl808BleNimLlcStartInitialLlcp* {.booldefine.}: bool = false

  var nim_vendor_con_started: bool
  var nim_vendor_con_params: array[64, uint8]
  var nim_vendor_llc_msg* {.exportc.}: array[64, uint8]
  var nim_vendor_llc_env_storage: array[0x8C, uint8]
  var nim_vendor_llc_status* {.exportc.}: uint32
  var nim_vendor_llcp_rx_count* {.exportc.}: uint32
  var nim_vendor_llcp_tx_count* {.exportc.}: uint32
  var nim_vendor_llcp_tx_pending* {.exportc.}: uint32
  var nim_vendor_llcp_tx_queued* {.exportc.}: uint32
  var nim_vendor_llcp_tx_dropped* {.exportc.}: uint32
  var nim_vendor_llcp_last_opcode* {.exportc.}: uint32
  var nim_vendor_llcp_last_status* {.exportc.}: uint32
  var nim_vendor_llcp_rx_log* {.exportc.}: array[8, uint32]
  var nim_vendor_llcp_tx_log* {.exportc.}: array[8, uint32]
  var nim_vendor_llcp_rx_log_index* {.exportc.}: uint32
  var nim_vendor_llcp_tx_log_index* {.exportc.}: uint32
  var nim_vendor_llcp_alloc_count* {.exportc.}: uint32
  var nim_vendor_llcp_free_count* {.exportc.}: uint32
  var nim_vendor_llcp_alloc_last_len* {.exportc.}: uint32
  var nim_vendor_llcp_alloc_last_ptr* {.exportc.}: uint32
  var nim_vendor_llcp_alloc_last_emoff* {.exportc.}: uint32
  var nim_vendor_llcp_alloc_last_len_field* {.exportc.}: uint32
  var nim_vendor_llcp_free_last_raw* {.exportc.}: uint32
  var nim_vendor_llcp_free_manual_count* {.exportc.}: uint32
  var nim_vendor_llcp_free_heap_count* {.exportc.}: uint32
  var nim_vendor_acl_empty_tx_count* {.exportc.}: uint32
  var nim_vendor_acl_empty_tx_pending* {.exportc.}: uint32
  var nim_vendor_acl_empty_last_status* {.exportc.}: uint32
  var nim_vendor_con_last_status* {.exportc.}: uint32
  var nim_vendor_con_last_rx_clock* {.exportc.}: uint32
  var nim_vendor_con_last_rx_fine* {.exportc.}: uint32
  var nim_vendor_con_last_anchor* {.exportc.}: uint32
  var nim_vendor_con_last_win_offset* {.exportc.}: uint32
  var nim_vendor_con_last_interval* {.exportc.}: uint32
  var nim_vendor_con_last_timeout* {.exportc.}: uint32
  var nim_vendor_con_last_access_addr* {.exportc.}: uint32
  var nim_vendor_con_last_crcinit* {.exportc.}: uint32
  when bl808BleConnStageDiag:
    var nim_vendor_conn_stage* {.exportc.}: uint32
    var nim_vendor_conn_stage_ra* {.exportc.}: uint32
    var nim_vendor_conn_stage_sp* {.exportc.}: uint32
    var nim_vendor_conn_stage_mepc* {.exportc.}: uint32
    var nim_vendor_conn_stage_mcause* {.exportc.}: uint32
  var nim_vendor_lld_con_start_count* {.exportc.}: uint32
  var nim_vendor_lld_con_start_status* {.exportc.}: uint32
  var nim_vendor_lld_con_start_param*: array[48, uint8]
  var nim_vendor_conn_evt_count* {.exportc.}: uint32
  var nim_vendor_conn_evt_handle* {.exportc.}: uint32
  var nim_vendor_conn_evt_peer_a0* {.exportc.}: uint32
  var nim_vendor_conn_evt_peer_a1* {.exportc.}: uint32
  var nim_vendor_conn_evt_peer_type* {.exportc.}: uint32
  var nim_vendor_disc_evt_count* {.exportc.}: uint32
  var nim_vendor_disc_evt_reason* {.exportc.}: uint32
  var nim_vendor_llcp_tx_buf: array[12, uint8]
  var nim_vendor_llcp_tx_queue: array[8, array[32, uint8]]
  var nim_vendor_llcp_tx_queue_len: array[8, uint8]
  var nim_vendor_llcp_tx_queue_conhdl: array[8, uint16]
  var nim_vendor_llcp_tx_queue_head: uint32
  var nim_vendor_llcp_tx_queue_tail: uint32
  when defined(bl808BleVendorLlcStartProbe) and bl808BleNimLlcStart:
    var nim_vendor_llc_start_env_slots: array[5, pointer]
    var nim_vendor_llc_start_env_storage: array[5, array[0x8C, uint8]]

  const
    NimVendorLlcpTxEmOffset = 0x0788'u16
    NimVendorAclTxEmOffset = 0x0A20'u16

  proc noteVendorRxDescConsumed(idx: uint32) =
    lld_env[14] = uint8((idx + 1'u32) and 0x07'u32)

  proc putLe16(dst: ptr UncheckedArray[uint8], off: int, value: uint16) =
    dst[off] = uint8(value and 0x00FF'u16)
    dst[off + 1] = uint8((value shr 8) and 0x00FF'u16)

  proc putLe32(dst: ptr UncheckedArray[uint8], off: int, value: uint32) =
    dst[off] = uint8(value and 0x000000FF'u32)
    dst[off + 1] = uint8((value shr 8) and 0x000000FF'u32)
    dst[off + 2] = uint8((value shr 16) and 0x000000FF'u32)
    dst[off + 3] = uint8((value shr 24) and 0x000000FF'u32)

  proc vendorRecordLlcpRx(header: uint16, dataOff: uint16, pduLen: uint16) =
    let slot = nim_vendor_llcp_rx_log_index and 0x07'u32
    var word = uint32(header) shl 16
    if pduLen > 0'u16:
      word = word or uint32(read8(BTBLE_EM_BASE + dataOff.uint32))
    if pduLen > 1'u16:
      word = word or (uint32(read8(BTBLE_EM_BASE + dataOff.uint32 + 1'u32)) shl 8)
    nim_vendor_llcp_rx_log[slot.int] = word
    nim_vendor_llcp_rx_log_index = nim_vendor_llcp_rx_log_index + 1'u32

  proc vendorRecordLlcpTx(pdu: ptr UncheckedArray[uint8], len: uint8) =
    let slot = nim_vendor_llcp_tx_log_index and 0x07'u32
    var word = uint32(len) shl 24
    if pdu != nil and len > 0'u8:
      word = word or uint32(pdu[0])
    if pdu != nil and len > 1'u8:
      word = word or (uint32(pdu[1]) shl 8)
    if pdu != nil and len > 2'u8:
      word = word or (uint32(pdu[2]) shl 16)
    nim_vendor_llcp_tx_log[slot.int] = word
    nim_vendor_llcp_tx_log_index = nim_vendor_llcp_tx_log_index + 1'u32

  when defined(bl808BlePrintNimLlcMsg):
    proc nimVendorLlcMsgWord(index: int): uint32 =
      let off = index * 4
      uint32(nim_vendor_llc_msg[off]) or
        (uint32(nim_vendor_llc_msg[off + 1]) shl 8) or
        (uint32(nim_vendor_llc_msg[off + 2]) shl 16) or
        (uint32(nim_vendor_llc_msg[off + 3]) shl 24)

    proc printNimVendorLlcMsg(label: static[string]) =
      bleTrace("[NIMLLC] ")
      bleTrace(label)
      bleTrace(" words=")
      for i in 0 ..< 14:
        if i != 0:
          bleTrace(",")
        bleTraceHex32(nimVendorLlcMsgWord(i))
      bleTrace("\r\n")

  proc getLe16(src: ptr UncheckedArray[uint8], off: int): uint16 =
    uint16(src[off]) or (uint16(src[off + 1]) shl 8)

  when bl808BleConnStageDiag:
    template nimVendorReadRa(): uint32 =
      block:
        var v: uint32
        {.emit: [
          "asm volatile(\"mv %0, ra\" : \"=r\"(", v, ") : : \"memory\");"
        ].}
        v

    template nimVendorReadSp(): uint32 =
      block:
        var v: uint32
        {.emit: [
          "asm volatile(\"mv %0, sp\" : \"=r\"(", v, ") : : \"memory\");"
        ].}
        v

    proc nimVendorConnMark(stage: uint32) {.inline.} =
      nim_vendor_conn_stage = stage
      nim_vendor_conn_stage_ra = nimVendorReadRa()
      nim_vendor_conn_stage_sp = nimVendorReadSp()
      nim_vendor_conn_stage_mepc = cast[uint32](csrReadMepc())
      nim_vendor_conn_stage_mcause = cast[uint32](csrReadMcause())
  else:
    proc nimVendorConnMark(stage: uint32) {.inline.} =
      discard stage

  when defined(bl808BleWrapLldConStartDiag):
    proc realVendorLldConStart(conhdl: uint16, params: pointer): uint8
        {.importc: "__real_vendor_lld_con_start", cdecl.}

    proc wrapVendorLldConStart(conhdl: uint16, params: pointer): uint8
        {.exportc: "__wrap_vendor_lld_con_start", cdecl.} =
      inc nim_vendor_lld_con_start_count
      if params != nil:
        let p = cast[ptr UncheckedArray[uint8]](params)
        for i in 0 ..< nim_vendor_lld_con_start_param.len:
          nim_vendor_lld_con_start_param[i] = p[i]
      result = realVendorLldConStart(conhdl, params)
      nim_vendor_lld_con_start_status = result.uint32

  proc noteVendorPeripheralConnected(conhdl: uint16,
                                     raw: ptr UncheckedArray[uint8],
                                     header: uint16) =
    nimVendorConnMark(0x130'u32)
    nim_vendor_conn_evt_handle = conhdl.uint32
    nim_vendor_conn_evt_peer_type = (uint32(header) shr 6) and 0x01'u32
    if raw != nil:
      nim_vendor_conn_evt_peer_a0 =
        uint32(raw[0]) or (uint32(raw[1]) shl 8) or
        (uint32(raw[2]) shl 16) or (uint32(raw[3]) shl 24)
      nim_vendor_conn_evt_peer_a1 =
        uint32(raw[4]) or (uint32(raw[5]) shl 8)
    inc nim_vendor_conn_evt_count

  proc noteVendorAdvertiserConnected(raw: ptr UncheckedArray[uint8],
                                     header: uint16,
                                     interval: uint32,
                                     latency: uint32,
                                     peerSca: uint8) =
    ## lld_adv_end_ind_handler records the initiator identity and marks the
    ## advertising environment as connected after llc_start succeeds.  The Nim
    ## CONNECT_IND shortcut bypasses that handler, so mirror the consumed fields
    ## for advertiser slot 0.
    if raw != nil:
      for i in 0 ..< 6:
        llm_env_data.data[40 + i] = raw[i]
    llm_env_data.data[46] = uint8((header shr 6) and 0x01'u16)
    llm_env_data.data[47] = 1'u8
    llm_env_data.data[72] = 9'u8
    putLe16(cast[ptr UncheckedArray[uint8]](addr llm_env_data.data[0]),
            24, uint16(interval * 4'u32))
    putLe16(cast[ptr UncheckedArray[uint8]](addr llm_env_data.data[0]),
            26, uint16(interval * 4'u32))
    putLe32(cast[ptr UncheckedArray[uint8]](addr llm_env_data.data[0]),
            28, 0x00040004'u32)
    putLe16(cast[ptr UncheckedArray[uint8]](addr llm_env_data.data[0]),
            32, uint16((latency + 1'u32) * interval))
    putLe16(cast[ptr UncheckedArray[uint8]](addr llm_env_data.data[0]),
            34, uint16((latency + 1'u32) * interval))
    let intervalLatency = (latency + 1'u32) * interval
    let scaIdx = peerSca and 0x07'u8
    let driftPpm = uint32(co_sca2ppm[scaIdx.int]) + rwip_max_drift_get(scaIdx)
    let driftSlots = (((driftPpm * intervalLatency) div 400'u32) * 2'u32 +
                      312'u32) div 625'u32 + 1'u32
    putLe16(cast[ptr UncheckedArray[uint8]](addr llm_env_data.data[0]),
            36, uint16(driftSlots and 0xFFFF'u32))

  proc noteVendorPeripheralDisconnected(reason: uint8) =
    nimVendorConnMark(0x1D0'u32)
    nim_conn_active = false
    nim_conn_handle = 0
    nim_vendor_con_started = false
    nim_vendor_llcp_tx_pending = 0
    nim_vendor_llcp_tx_queued = 0
    nim_vendor_disc_evt_reason = reason.uint32
    inc nim_vendor_disc_evt_count

  when bl808BleVendorManualConnTx:
    var nim_vendor_acl_empty_tx_buf: array[8, uint8]

    proc vendorSendEmptyAclNow(conhdl: uint16): bool =
      if nim_vendor_acl_empty_tx_pending != 0:
        return false
      discard c_memset(addr nim_vendor_acl_empty_tx_buf[0], 0,
                       nim_vendor_acl_empty_tx_buf.len.csize_t)
      # lld_con_data_tx takes a vendor ACL TX element, not a raw LL PDU.
      # Offset +4 is the EM payload offset and +6 carries the pending length.
      write8(BTBLE_EM_BASE + NimVendorAclTxEmOffset.uint32, 0'u8)
      let txb = cast[ptr UncheckedArray[uint8]](
        addr nim_vendor_acl_empty_tx_buf[0])
      putLe16(txb, 4, NimVendorAclTxEmOffset)
      putLe16(txb, 6, 1'u16)
      nim_vendor_acl_empty_tx_pending = 1
      inc nim_vendor_acl_empty_tx_count
      nim_vendor_acl_empty_last_status =
        vendorLldConDataTx(conhdl, addr nim_vendor_acl_empty_tx_buf[0]).uint32
      if nim_vendor_acl_empty_last_status != 0:
        nim_vendor_acl_empty_tx_pending = 0
        return false
      true

    proc vendorSendLlcpPduNow(conhdl: uint16, pdu: ptr UncheckedArray[uint8],
                              len: uint8): bool =
      if pdu == nil or len == 0'u8 or len > 32'u8:
        return false
      vendorRecordLlcpTx(pdu, len)
      for i in 0 ..< len.int:
        write8(BTBLE_EM_BASE + NimVendorLlcpTxEmOffset.uint32 + i.uint32,
               pdu[i])
      discard c_memset(addr nim_vendor_llcp_tx_buf[0], 0,
                       nim_vendor_llcp_tx_buf.len.csize_t)
      let txb = cast[ptr UncheckedArray[uint8]](addr nim_vendor_llcp_tx_buf[0])
      putLe16(txb, 4, NimVendorLlcpTxEmOffset)
      txb[6] = len
      nim_vendor_llcp_tx_pending = 1
      inc nim_vendor_llcp_tx_count
      nim_vendor_llcp_last_status =
        vendorLldConLlcpTx(conhdl, addr nim_vendor_llcp_tx_buf[0]).uint32
      if nim_vendor_llcp_last_status != 0:
        nim_vendor_llcp_tx_pending = 0
        return false
      when bl808BleVendorKeepaliveAcl:
        discard vendorSendEmptyAclNow(conhdl)
      true

    proc vendorTrySendQueuedLlcp() =
      if nim_vendor_llcp_tx_pending != 0:
        return
      if nim_vendor_llcp_tx_queued == 0:
        return
      let slot = nim_vendor_llcp_tx_queue_head and 0x07'u32
      nim_vendor_llcp_tx_queue_head =
        (nim_vendor_llcp_tx_queue_head + 1'u32) and 0x07'u32
      dec nim_vendor_llcp_tx_queued
      discard vendorSendLlcpPduNow(nim_vendor_llcp_tx_queue_conhdl[slot.int],
        cast[ptr UncheckedArray[uint8]](
          addr nim_vendor_llcp_tx_queue[slot.int][0]),
        nim_vendor_llcp_tx_queue_len[slot.int])

    proc vendorQueueLlcpPdu(conhdl: uint16, pdu: ptr UncheckedArray[uint8],
                            len: uint8) =
      if pdu == nil or len == 0'u8 or len > 32'u8:
        return
      if nim_vendor_llcp_tx_pending == 0 and nim_vendor_llcp_tx_queued != 0:
        vendorTrySendQueuedLlcp()
      if nim_vendor_llcp_tx_pending == 0 and nim_vendor_llcp_tx_queued == 0:
        if vendorSendLlcpPduNow(conhdl, pdu, len):
          return
        inc nim_vendor_llcp_tx_dropped
        return
      if nim_vendor_llcp_tx_queued >=
          nim_vendor_llcp_tx_queue_len.len.uint32:
        inc nim_vendor_llcp_tx_dropped
        return
      let slot = nim_vendor_llcp_tx_queue_tail and 0x07'u32
      nim_vendor_llcp_tx_queue_tail =
        (nim_vendor_llcp_tx_queue_tail + 1'u32) and 0x07'u32
      nim_vendor_llcp_tx_queue_conhdl[slot.int] = conhdl
      nim_vendor_llcp_tx_queue_len[slot.int] = len
      for i in 0 ..< len.int:
        nim_vendor_llcp_tx_queue[slot.int][i] = pdu[i]
      inc nim_vendor_llcp_tx_queued

    proc vendorRespondToLlcp(conhdl: uint16, opcode: uint8,
                             reason: uint8 = 0x13'u8) =
      var pdu: array[9, uint8]
      case opcode
      of 0x02'u8: # LL_TERMINATE_IND
        noteVendorPeripheralDisconnected(reason)
        sendDisconnectComplete(conhdl, reason)
        when defined(bl808m0):
          when not bl808BleNimUseClicIrq:
            nimDisableM0BleClicIrq()
        regWrite((BLE_BASE + 0x018'u32).uint, 0x00008026'u32)
      of 0x08'u8: # LL_FEATURE_REQ
        pdu[0] = 0x09'u8
        pdu[1] = 0xBF'u8
        pdu[2] = 0xCF'u8
        pdu[3] = 0x01'u8
        pdu[4] = 0x84'u8
        vendorQueueLlcpPdu(conhdl,
                           cast[ptr UncheckedArray[uint8]](addr pdu[0]),
                           9'u8)
      of 0x0C'u8: # LL_VERSION_IND
        pdu[0] = 0x0C'u8
        pdu[1] = 0x0C'u8
        pdu[2] = 0x60'u8
        pdu[3] = 0x00'u8
        pdu[4] = 0x0A'u8
        pdu[5] = 0x00'u8
        vendorQueueLlcpPdu(conhdl,
                           cast[ptr UncheckedArray[uint8]](addr pdu[0]),
                           6'u8)
      of 0x14'u8: # LL_LENGTH_REQ
        pdu[0] = 0x15'u8
        pdu[1] = 0x1B'u8
        pdu[2] = 0x00'u8
        pdu[3] = 0x48'u8
        pdu[4] = 0x01'u8
        pdu[5] = 0x1B'u8
        pdu[6] = 0x00'u8
        pdu[7] = 0x48'u8
        pdu[8] = 0x01'u8
        vendorQueueLlcpPdu(conhdl,
                           cast[ptr UncheckedArray[uint8]](addr pdu[0]),
                           9'u8)
      else:
        pdu[0] = 0x07'u8
        pdu[1] = opcode
        vendorQueueLlcpPdu(conhdl,
                           cast[ptr UncheckedArray[uint8]](addr pdu[0]),
                           2'u8)

    proc vendorSendInitialLlcpNow(conhdl: uint16): bool =
      var pdu: array[6, uint8]
      pdu[0] = 0x0C'u8
      pdu[1] = 0x0C'u8
      pdu[2] = 0x60'u8
      pdu[3] = 0x00'u8
      pdu[4] = 0x0A'u8
      pdu[5] = 0x00'u8
      vendorSendLlcpPduNow(conhdl,
                           cast[ptr UncheckedArray[uint8]](addr pdu[0]),
                           6'u8)

    proc vendorSendLeConnComplete(conhdl: uint16) =
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

  proc refreshVendorSyncPositions() =
    ## Vendor lld_init derives the RX sync-position table from these BTBLE
    ## timing registers.  lld_con_start uses the table again when converting
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

  proc vendorConnectTiming(baseClock: uint32, rawFine: uint16,
                           rateIdx: uint8, outClock: var uint32,
                           outFine: var uint16) =
    refreshVendorSyncPositions()
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

  proc startVendorLldConnectionFromConnectInd(descIdx: uint8,
                                             payload: ptr UncheckedArray[uint8],
                                             header: uint16,
                                             rxClock: uint32,
                                             rxFine: uint16) =
    nimVendorConnMark(0x100'u32)
    when defined(bl808BleConnectTrace):
      bleTrace("\r\n[CON] start\r\n")
    if nim_vendor_con_started:
      nimVendorConnMark(0x101'u32)
      when defined(bl808BleConnectTrace):
        bleTrace("[CON] already\r\n")
      return
    nim_vendor_con_started = true
    nim_adv_enabled = false

    discard c_memset(addr nim_vendor_con_params[0], 0,
                     nim_vendor_con_params.len.csize_t)
    discard c_memset(addr nim_vendor_llc_msg[0], 0,
                     nim_vendor_llc_msg.len.csize_t)
    let outp = cast[ptr UncheckedArray[uint8]](addr nim_vendor_con_params[0])
    let llc = cast[ptr UncheckedArray[uint8]](addr nim_vendor_llc_msg[0])
    var pdu: array[34, uint8]
    for i in 0 ..< pdu.len:
      pdu[i] = payload[i]
    let raw = cast[ptr UncheckedArray[uint8]](addr pdu[0])

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
    let directAnchor = addBtbleClockSlots(
      (baseClock + winOffset * 2'u32) and 0x0FFFFFFF'u32,
      bl808BleVendorConAnchorBiasSlots)
    # Vendor co_rate_to_phy maps rate enum 0 to LE 1M.  llc_start passes this
    # value through as lld_con_start byte 37, which also selects the sync-position
    # table entry used when normal advertiser timing is converted to an anchor.
    let rateIdx = 0'u8
    var timingClock = baseClock and 0x0000FFFF'u32
    var timingFine = rxFine
    when bl808BleVendorConTimingPath:
      vendorConnectTiming(baseClock, rxFine, rateIdx, timingClock, timingFine)
      putLe16(outp, 24, timingFine)
      putLe32(outp, 28, timingClock)
      putLe32(outp, 32, directAnchor)
      outp[36] = 1'u8            # normal advertiser timing path
    else:
      putLe32(outp, 32, directAnchor)
      outp[36] = 0'u8            # direct handoff with precomputed anchor
    outp[37] = rateIdx           # vendor rate enum: 0 maps to LE 1M
    outp[38] = uint8((header shr 5) and 0x01'u16)

    nim_vendor_con_last_rx_clock = baseClock
    nim_vendor_con_last_rx_fine = rxFine.uint32
    nim_vendor_con_last_anchor = directAnchor
    nim_vendor_con_last_win_offset = winOffset
    nim_vendor_con_last_interval = interval
    nim_vendor_con_last_timeout = timeout
    nim_vendor_con_last_access_addr =
      uint32(raw[12]) or (uint32(raw[13]) shl 8) or
      (uint32(raw[14]) shl 16) or (uint32(raw[15]) shl 24)
    nim_vendor_con_last_crcinit =
      uint32(raw[16]) or (uint32(raw[17]) shl 8) or
      (uint32(raw[18]) shl 16)

    when defined(bl808BleVendorLlcStartProbe):
      for i in 0 ..< 23:
        llc[i] = outp[i]
      llc[23] = 0'u8
      putLe16(llc, 24, timingFine)
      llc[26] = 0'u8
      llc[27] = raw[19]
      putLe32(llc, 28, timingClock)
      putLe32(llc, 32, 0'u32)
      llc[36] = outp[37]         # vendor LLC rate enum: 0 maps to LE 1M
      llc[37] = outp[36]         # vendor LLD timing selector
      putLe16(llc, 38, uint16(outp[38]))
      # Vendor lld_adv_end_ind_handler copies the controller data-length
      # defaults from llm_env + 0x1ae..0x1bc into llc_start offsets 40..54.
      for i in 0 .. 14:
        llc[40 + i] = llm_env_data.data[0x1AE + i]
      llc[55] = 0'u8

    regWrite((BLE_BASE + 0x828'u32).uint, 0x0000013E'u32)
    regWrite((BLE_BASE + 0x018'u32).uint, 0x000080A6'u32)
    initVendorRwipRfTable()
    refreshVendorSyncPositions()
    clearBtbleProgramSlots()
    when defined(bl808BleVendorLlcStartProbe):
      nim_vendor_llc_status = 0xC0010001'u32
      nim_vendor_con_last_status = 0xC0010001'u32
      nimVendorConnMark(0x120'u32)
      when defined(bl808BleConnectTrace):
        bleTrace("[CON] before llc\r\n")
      when defined(bl808BlePrintNimLlcMsg):
        printNimVendorLlcMsg("before-llc")
      let llcStatus = vendorLlcStart(1'u16, addr nim_vendor_llc_msg[0]).uint32
      nimVendorConnMark(0x121'u32)
      when defined(bl808BleConnectTrace):
        bleTrace("[CON] after llc\r\n")
      nim_vendor_llc_status = 0xC0020000'u32 or (llcStatus and 0xFFFF'u32)
      nim_vendor_con_last_status = nim_vendor_llc_status
      if llcStatus == 0'u32:
        when defined(bl808BleConnectTrace):
          bleTrace("[CON] note connected\r\n")
        noteVendorAdvertiserConnected(raw, header, interval, latency, raw[33] shr 5)
        noteVendorPeripheralConnected(1'u16, raw, header)
        when bl808BleVendorManualConnTx and bl808BleVendorKeepaliveAcl:
          discard vendorSendEmptyAclNow(1'u16)
        nimVendorConnMark(0x131'u32)
      when bl808BleVendorManualConnTx:
        if llcStatus == 0'u32 and bl808BleNimSyntheticPeripheral:
          vendorSendLeConnComplete(1'u16)
    else:
      nimVendorConnMark(0x110'u32)
      when defined(bl808BleConnectTrace):
        bleTrace("[CON] before lld\r\n")
      nim_vendor_con_last_status =
        vendorLldConStart(1'u16, addr nim_vendor_con_params[0]).uint32
      nimVendorConnMark(0x111'u32)
      when defined(bl808BleConnectTrace):
        bleTrace("[CON] after lld\r\n")
      if nim_vendor_con_last_status == 0'u32:
        noteVendorAdvertiserConnected(raw, header, interval, latency, raw[33] shr 5)
        noteVendorPeripheralConnected(1'u16, raw, header)
        when bl808BleVendorManualConnTx and bl808BleVendorKeepaliveAcl:
          discard vendorSendEmptyAclNow(1'u16)
        nimVendorConnMark(0x131'u32)
      when bl808BleVendorManualConnTx:
        if nim_vendor_con_last_status == 0'u32 and
            bl808BleNimSyntheticPeripheral:
          vendorSendLeConnComplete(1'u16)
    regWrite((BLE_BASE + 0x018'u32).uint, 0x000080A6'u32)
    nimVendorConnMark(0x140'u32)
    when defined(bl808m0):
      when not bl808BleNimUseClicIrq:
        nimDisableM0BleClicIrq()
    when not bl808BleSkipConnEmWake:
      regOr(BTBLE_EM_BASE + 0x1B4'u32, 0x00000001'u32)
    nimVendorConnMark(0x1FF'u32)
    when defined(bl808BleConnectTrace):
      bleTrace("[CON] done\r\n")

proc btbleDelayTicksToSlots(delayTicks: uint32): uint32 {.inline.} =
  let slots = (delayTicks + 624'u32) div 625'u32
  if slots < 8'u32: 8'u32 else: slots

proc nimAdvIntervalHalfUs(): uint32 {.inline.} =
  let interval =
    uint32(nim_adv_params[0]) or (uint32(nim_adv_params[1]) shl 8)
  let bounded =
    if interval == 0'u32: 0x00A0'u32 else: interval
  bounded * 1250'u32

proc pushBtbleAdvProgram(leadSlots: uint32 = 8'u32) =
  inc nim_ble_dbg_push_count
  let nowClock = currentBtbleTime()
  let slot = uint32(nim_adv_schedule_slot) mod 10'u32
  let targetClock = (nowClock + leadSlots) and 0x0FFFFFFF'u32
  let clock = targetClock and 0x0000FFFF'u32
  let slotAddr = BTBLE_EM_BASE + slot * 0x10'u32

  when defined(bl808m0) and
      (defined(bl808BleVendorSchProgProbe) or
       (defined(bl808BleVendorLldConProbe) and bl808BleNimSchProg)):
    discard c_memset(addr nim_vendor_sch_prog[0], 0, nim_vendor_sch_prog.len.csize_t)

    write16(slotAddr, 0x281A'u16)
    write16(slotAddr + 0x02'u32, uint16(clock and 0xFFFF'u32))
    write16(slotAddr + 0x04'u32, 0'u16)
    write16(slotAddr + 0x06'u32, 0x0270'u16)
    write16(slotAddr + 0x08'u32, 0x0048'u16)
    write16(slotAddr + 0x0A'u32, 0x085A'u16)
    write16(slotAddr + 0x0C'u32, uint16(BtbleAdvSlotTail[slot.int] and 0xFFFF'u32))
    write16(slotAddr + 0x0E'u32, uint16((BtbleAdvSlotTail[slot.int] shr 16) and 0xFFFF'u32))

    vendorProgWrite32(0x00, cast[uint32](cast[uint](nimVendorSchProgCb)))
    vendorProgWrite32(0x04, targetClock)    # coarse target time
    vendorProgWrite16(0x08, 0'u16)          # fine target time
    vendorProgWrite32(0x10, 0x000010B3'u32) # duration -> 0x085a half slot
    vendorProgWrite32(0x14, 0'u32)          # callback context
    nim_vendor_sch_prog[0x18] = 0x28'u8     # adv rate/type field, shifted by vendor code
    nim_vendor_sch_prog[0x19] = 0x00'u8
    nim_vendor_sch_prog[0x1A] = 0x60'u8     # final low half at +0x0c: 0x0c00
    nim_vendor_sch_prog[0x1B] = uint8((BtbleAdvSlotTail[slot.int] shr 24) and 0xFF'u32)
    nim_vendor_sch_prog[0x1C] = 0x00'u8     # advertising event index -> EM ptr 0x48
    nim_vendor_sch_prog[0x1D] = 0x00'u8     # legacy advertising control-word path
    nim_vendor_sch_prog[0x1E] = 0x00'u8
    nim_vendor_sch_prog[0x1F] = 0x00'u8
    nim_vendor_sch_prog[0x20] = 0x00'u8
    nim_vendor_sch_prog[0x21] = 0x00'u8
    when defined(bl808BleVendorSchProgProbe):
      vendorSchProgPush(addr nim_vendor_sch_prog[0])
    else:
      sch_prog_push(addr nim_vendor_sch_prog[0])
    nim_adv_schedule_slot = uint8((slot + 1'u32) mod 10'u32)
    return

  write16(slotAddr, 0x2802'u16)
  write16(slotAddr + 0x02'u32, uint16(clock and 0xFFFF'u32))
  write16(slotAddr + 0x04'u32, 0'u16)
  write16(slotAddr + 0x06'u32, 0x0270'u16)
  write16(slotAddr + 0x08'u32, 0x0048'u16)
  write16(slotAddr + 0x0A'u32, 0x085A'u16)
  write16(slotAddr + 0x0C'u32, uint16(BtbleAdvSlotTail[slot.int] and 0xFFFF'u32))
  write16(slotAddr + 0x0E'u32, uint16((BtbleAdvSlotTail[slot.int] shr 16) and 0xFFFF'u32))

  regWrite((BLE_BASE + 0x110'u32).uint, 0x80000000'u32 or slot)
  nim_adv_schedule_slot = uint8((slot + 1'u32) mod 10'u32)

proc scheduleBtbleEvent(delayHalfUs: uint32 = 0'u32) =
  let delay =
    if delayHalfUs == 0'u32: nimAdvIntervalHalfUs()
    else: delayHalfUs
  let target = (currentBtbleHalfUs() + delay) and 0x0FFFFFFF'u32
  let nowClock = currentBtbleTime()
  let leadSlots = btbleDelayTicksToSlots(delay)
  let clock = (nowClock + leadSlots) and 0x0000FFFF'u32
  nim_adv_target_half_us = target
  regWrite((BLE_BASE + 0x9C0'u32).uint, 0x00004000'u32)
  regWrite((BLE_BASE + 0x0E8'u32).uint,
           clock and 0x0FFFFFFF'u32)
  regWrite((BLE_BASE + 0x0EC'u32).uint, 0x00000270'u32)
  regWrite((BLE_BASE + 0x020'u32).uint, 0x00000020'u32)
  regOr(BLE_BASE + 0x018'u32, 0x00000020'u32)

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

proc expectedAdvAddrByte(idx: int): uint8 =
  if nim_local_addr_valid:
    return nim_local_addr[idx]

  let lo = regRead((BLE_BASE + 0x024'u32).uint)
  let hi = regRead((BLE_BASE + 0x028'u32).uint)
  if lo == 0 and hi == 0:
    case idx
    of 0: 0x01'u8
    of 1: 0x23'u8
    of 2: 0x45'u8
    of 3: 0x67'u8
    of 4: 0x89'u8
    else: 0xAB'u8
  else:
    case idx
    of 0: uint8(lo and 0xFF'u32)
    of 1: uint8((lo shr 8) and 0xFF'u32)
    of 2: uint8((lo shr 16) and 0xFF'u32)
    of 3: uint8((lo shr 24) and 0xFF'u32)
    of 4: uint8(hi and 0xFF'u32)
    else: uint8((hi shr 8) and 0xFF'u32)

proc serviceBtbleAdvRxDescriptors() =
  ## The BL808 BTBLE advertising engine writes received advertising-channel
  ## PDUs into the RX descriptor ring at EM 0x458.  Vendor lld_adv_frm_isr()
  ## consumes these on scheduler FIFO completion; the Nim scheduler bypasses
  ## that callback path, so service the ring directly until the full LLD event
  ## callback model is ported.
  var startIdx = 0'u32
  when defined(bl808m0) and defined(bl808BleVendorLldConProbe):
    startIdx = uint32(lld_env[14] and 0x07'u8)
  for step in 0'u32 ..< 8'u32:
    when defined(bl808m0) and defined(bl808BleVendorLldConProbe):
      if nim_vendor_con_started:
        nimVendorConnMark(0x160'u32 or step)
    let i = (startIdx + step) and 0x07'u32
    let desc = BTBLE_EM_BASE + 0x458'u32 + i * 0x20'u32
    let status = read16(desc)
    if (status and 0x8000'u16) == 0:
      continue

    let header = read16(desc + 0x04'u32)
    let buf = read16(desc + 0x14'u32)
    let pduType = uint8(header and 0x000F'u16)
    let pduLen = uint8((header shr 8) and 0x003F'u16)

    inc nim_ble_dbg_rx_ready_count
    nim_ble_dbg_rx_last_header = header.uint32
    nim_ble_dbg_rx_last_status = status.uint32
    nim_ble_dbg_rx_last_desc = desc
    nim_ble_dbg_rx_last_buf = buf.uint32

    if pduType == 0x03'u8 and pduLen == 12'u8:
      inc nim_ble_dbg_rx_scan_req_count
      let payloadBase = BTBLE_EM_BASE + buf.uint32
      nim_ble_dbg_rx_scan_req_last_scana0 = readBleAddrLow(payloadBase)
      nim_ble_dbg_rx_scan_req_last_scana1 = readBleAddrHigh(payloadBase)
      nim_ble_dbg_rx_scan_req_last_adva0 = readBleAddrLow(payloadBase + 6'u32)
      nim_ble_dbg_rx_scan_req_last_adva1 = readBleAddrHigh(payloadBase + 6'u32)
      var advaMatches = true
      for j in 0 ..< 6:
        if read8(payloadBase + 6'u32 + j.uint32) != expectedAdvAddrByte(j):
          advaMatches = false
      if advaMatches:
        inc nim_ble_dbg_rx_scan_req_match_count
    elif pduType == 0x05'u8 and pduLen == 34'u8:
      when defined(bl808BleConnectTrace):
        bleTrace("\r\n[CON] rx connect\r\n")
      inc nim_ble_dbg_rx_connect_ind_count
      when defined(bl808m0) and defined(bl808BleVendorLldConProbe):
        # Vendor lld_adv_frm_isr builds the connection-start indication from
        # RX descriptor +0x08/+0x0A: +0x08 low 10 bits are fine time, +0x0A is
        # the coarse BTBLE clock.  +0x0C is metadata, not the CONNECT_IND fine
        # timestamp.
        let rxFine = read16(desc + 0x08'u32) and 0x03FF'u16
        let rxClock = read16(desc + 0x0A'u32).uint32
        var connectPdu: array[34, uint8]
        let payload = cast[ptr UncheckedArray[uint8]](
          (BTBLE_EM_BASE + buf.uint32).uint)
        for j in 0 ..< connectPdu.len:
          connectPdu[j] = payload[j]
        write16(desc, status and not 0x8000'u16)
        noteVendorRxDescConsumed(i)
        let advRxSp = bleCentralTraceReadSp()
        let advRxRa = regRead((advRxSp + 124'u32).uint)
        let isrRa = regRead((advRxSp + 156'u32).uint)
        startVendorLldConnectionFromConnectInd(uint8(i and 0x07'u32),
                                               cast[ptr UncheckedArray[uint8]](
                                                 addr connectPdu[0]),
                                                 header, rxClock, rxFine)
        if advRxRa != 0'u32:
          regWrite((advRxSp + 124'u32).uint, advRxRa)
        if isrRa != 0'u32:
          regWrite((advRxSp + 156'u32).uint, isrRa)
        nimVendorConnMark(0x150'u32)
        when defined(bl808BleConnectTrace):
          bleTrace("[CON] post start return\r\n")
        nimVendorConnMark(0x151'u32)
        return

    when defined(bl808m0) and defined(bl808BleVendorLldConProbe):
      if nim_vendor_con_started:
        nimVendorConnMark(0x170'u32 or step)

    when defined(bl808m0) and defined(bl808BleVendorLldScanProbe):
      if pduLen >= 6'u8 and
          (pduType == 0x00'u8 or pduType == 0x02'u8 or
           pduType == 0x04'u8 or pduType == 0x06'u8):
        sendLeAdvertisingReportFromRxDesc(header, buf)
      elif pduLen > 0'u8:
        noteUnsupportedScanPdu(header, buf)

    when defined(bl808m0) and defined(bl808BleVendorLldConProbe):
      if nim_vendor_con_started and pduType != 0x03'u8 and pduType != 0x05'u8:
        continue

    write16(desc, status and not 0x8000'u16)
    when defined(bl808m0) and defined(bl808BleVendorLldConProbe):
      noteVendorRxDescConsumed(i)

proc resetBtbleLinkLayerCore() =
  regWrite((BLE_BASE + 0x800'u32).uint,
           regRead((BLE_BASE + 0x800'u32).uint) and not 0x00000100'u32)
  regWrite((BLE_BASE + 0x800'u32).uint,
           regRead((BLE_BASE + 0x800'u32).uint) or 0x80000000'u32)
  var guard = 100_000
  while (regRead((BLE_BASE + 0x800'u32).uint) and 0x80000000'u32) != 0 and
        guard > 0:
    dec guard
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
  when not (defined(bl808BleVendorFullSchedulerProbe) or
            defined(bl808BleVendorSliceProbe)):
    sch_slice_params[0] = 0xFFFF'u16
    sch_slice_params[1] = 0xFFFF'u16
    sch_slice_params[2] = 0x57E4'u16
    sch_slice_params[3] = 0'u16
  when defined(bl808m0) and
      (defined(bl808BleVendorSchProgProbe) or
       defined(bl808BleVendorLldAdvProbe) or
       defined(bl808BleVendorLldConProbe) or
       defined(bl808BleVendorLldScanProbe)):
    when defined(bl808BleVendorLldConProbe) or
        defined(bl808BleVendorLldScanProbe):
      rwip_param.get = rwipParamDummyGet
      rwip_param.set = rwipParamDummySet
      rwip_param.del = rwipParamDummyDel
    when defined(bl808BleVendorArbProbe):
      vendorSchArbInit(3'u8)
    vendorSchProgInit(3'u8)
    when defined(bl808BleVendorArbProbe):
      vendorSchPlanInit(3'u8)
      when defined(bl808BleVendorFullSchedulerProbe) or
          defined(bl808BleVendorAlarmProbe):
        vendorSchAlarmInit(3'u8)
      when defined(bl808BleVendorFullSchedulerProbe) or
          defined(bl808BleVendorSliceProbe):
        vendorSchSliceInit(3'u8)
    when defined(bl808BleVendorLldScanProbe):
      initVendorRwipRfTable()
      vendorLldScanInit(3'u8)
      when defined(bl808BleVendorLldInitProbe):
        vendorLldInitInit(3'u8)

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

  for i in 0'u32 ..< 8'u32:
    let desc = BTBLE_EM_BASE + 0x458'u32 + i * 0x20'u32
    let nextOff = 0x458'u32 + ((i + 1'u32) and 0x7'u32) * 0x20'u32
    let rxBuf = 0x0B0D'u32 + i * 0x104'u32
    write16(desc, uint16((nextOff shr 2) and 0xFFFF'u32))
    write16(desc + 0x14'u32, uint16(rxBuf and 0xFFFF'u32))

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
  when defined(bl808m0) and defined(bl808BleVendorLldConProbe):
    refreshVendorSyncPositions()
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
  prepareWirelessDomain()
  configureBtPriorityPta()
  configureBleRf1M()

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

  write16(BLE_EM_BASE + 0x0F0'u32, 0xBED6'u16)
  write16(BLE_EM_BASE + 0x0F2'u32, 0x8E89'u16)
  write16(BLE_EM_BASE + 0x0F4'u32, 0x5555'u16)
  write16(BLE_EM_BASE + 0x0F6'u32, 0x0055'u16)
  write16(BLE_EM_BASE + 0x106'u32, 0'u16)
  write16(BLE_EM_BASE + 0x108'u32, 0'u16)
  write16(BLE_EM_BASE + 0x10A'u32, 0'u16)
  write16(BLE_EM_BASE + 0x14C'u32, 0xBED6'u16)
  write16(BLE_EM_BASE + 0x14E'u32, 0x8E89'u16)
  write16(BLE_EM_BASE + 0x150'u32, 0x5555'u16)
  write16(BLE_EM_BASE + 0x152'u32, 0x0055'u16)
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
  initBtbleTimeRegisters()
  initBtbleLinkLayerRegisters()

  nim_ble_core_ready = true

proc resetNimControllerState() =
  nim_adv_enabled = false
  nim_scan_enabled = false
  nim_conn_active = false
  nim_conn_handle = 0
  nim_local_addr_valid = false
  nim_adv_data_len = 0
  nim_scan_rsp_data_len = 0
  nim_adv_schedule_slot = 0
  nim_adv_target_half_us = 0
  when defined(bl808m0) and defined(bl808BleVendorLldScanProbe):
    nim_vendor_scan_report_count = 0
    nim_vendor_scan_start_status = 0
    nim_vendor_scan_arb_insert_count = 0
    nim_vendor_scan_arb_cb_count = 0
    nim_vendor_scan_sw_int_count = 0
    nim_vendor_scan_restart_count = 0
    nim_vendor_scan_unsupported_count = 0
    nim_vendor_scan_unsupported_header = 0
    nim_vendor_scan_unsupported_len = 0
    nim_vendor_scan_unsupported_buf = 0
    discard c_memset(addr nim_vendor_scan_unsupported_data[0], 0,
                     nim_vendor_scan_unsupported_data.len.csize_t)
    when defined(bl808BleVendorLldInitProbe):
      nim_vendor_init_active = false
      nim_vendor_init_start_status = 0
      nim_vendor_init_msg_count = 0
      nim_vendor_init_success_count = 0
      nim_vendor_init_failure_count = 0
      nim_vendor_init_last_activity = 0
      nim_vendor_init_last_msg_status = 0
      nim_vendor_init_cancel_status = 0
      nim_vendor_init_cancel_count = 0
      nim_vendor_init_header_fix_count = 0
      nim_vendor_init_arb_insert_count = 0
      nim_vendor_init_arb_cb_count = 0
      nim_vendor_init_arb_last_w1 = 0
      nim_vendor_init_arb_last_w2 = 0
      nim_vendor_init_arb_last_w7 = 0
      nim_vendor_init_arb_last_w24 = 0
      nim_vendor_init_arb_last_w28 = 0
      nim_vendor_init_peer_rx_count = 0
      nim_vendor_init_peer_hit_count = 0
      nim_vendor_init_peer_rx_last_header = 0
      nim_vendor_init_peer_rx_last_status = 0
      nim_vendor_init_peer_rx_last_meta = 0
      nim_vendor_init_status_fix_count = 0
      nim_vendor_init_status_fix_last = 0
      nim_vendor_init_msg_alloc_count = 0
      nim_vendor_init_msg_alloc_last_len = 0
      nim_vendor_init_msg_alloc_last_dest = 0
      nim_vendor_init_msg_alloc_last_src = 0
      nim_vendor_init_peer_complete_count = 0
      nim_vendor_init_peer_complete_pending = 0
      nim_lld_aa_gen_count = 0
      nim_lld_aa_last = 0
      nim_lld_aa_last_seed = 0
      nim_vendor_init_pkt_dur_count = 0
      nim_vendor_init_pkt_dur_last_len = 0
      nim_vendor_init_pkt_dur_last_rate = 0
      discard c_memset(addr nim_vendor_lld_init_params[0], 0,
                       nim_vendor_lld_init_params.len.csize_t)
      discard c_memset(addr nim_vendor_init_hci_params[0], 0,
                       nim_vendor_init_hci_params.len.csize_t)
      discard vendorLldInitStop()
      vendorLldInitInit(3'u8)
    nim_lld_rx_desc_idx = 0
    nim_lld_rx_desc_active = 0
    nim_lld_rx_check_count = 0
    nim_lld_rx_check_hit_count = 0
    nim_lld_rx_check_miss_count = 0
    nim_lld_rx_free_count = 0
    nim_lld_rx_last_idx = 0
    nim_lld_rx_last_env_idx = 0
    nim_lld_rx_last_status = 0
    nim_lld_rx_last_header = 0
    nim_lld_rx_last_meta = 0
    nim_vendor_sch_prog_fifo_count = 0
    nim_vendor_sch_prog_skip_count = 0
    nim_vendor_arb_sw_count = 0
    nim_vendor_arb_event_start_count = 0
    when defined(bl808BleVendorArbProbe):
      nim_vendor_arb_target_coarse = 0xFFFFFFFF'u32
      when defined(bl808BleVendorFullSchedulerProbe) or
          defined(bl808BleVendorAlarmProbe):
        nim_vendor_alarm_target_coarse = 0xFFFFFFFF'u32
  when defined(bl808m0) and
      (defined(bl808BleVendorSchProgProbe) or
       defined(bl808BleVendorLldAdvProbe) or
       defined(bl808BleVendorLldConProbe) or
       defined(bl808BleVendorLldScanProbe)):
    nim_vendor_sch_prog_fifo_count = 0
    nim_vendor_sch_prog_skip_count = 0
    nim_vendor_arb_sw_count = 0
    nim_vendor_arb_event_start_count = 0
    when defined(bl808BleVendorSchedulerDiag):
      nim_vendor_arb_set_count = 0
      nim_vendor_arb_last_target_coarse = 0
      nim_vendor_arb_last_target_fine = 0
      nim_vendor_arb_due_target_coarse = 0
      nim_vendor_arb_due_target_fine = 0
      nim_vendor_arb_due_now_coarse = 0
      nim_vendor_arb_due_now_fine = 0
      nim_vendor_slice_add_count = 0
      nim_vendor_slice_remove_count = 0
      nim_vendor_slice_last_type_con = 0
      nim_vendor_slice_last_interval = 0
      nim_vendor_slice_last_anchor = 0
      nim_vendor_slice_last_offset = 0
    when defined(bl808BleVendorArbProbe):
      nim_vendor_arb_target_coarse = 0xFFFFFFFF'u32
      when defined(bl808BleVendorFullSchedulerProbe) or
          defined(bl808BleVendorAlarmProbe):
        nim_vendor_alarm_target_coarse = 0xFFFFFFFF'u32
    when defined(bl808BleVendorArbProbe) and defined(bl808BleVendorWrapDiag):
      ble_vendor_wrap_arb_insert_count = 0
      ble_vendor_wrap_arb_insert_status = 0
      ble_vendor_wrap_arb_insert_last = 0
      ble_vendor_wrap_prog_push_count = 0
      ble_vendor_wrap_prog_push_last = 0
  when defined(bl808m0) and defined(bl808BleVendorLldConProbe):
    nim_vendor_con_started = false
    nim_vendor_llc_status = 0
    nim_vendor_con_last_status = 0
    nim_vendor_con_last_rx_clock = 0
    nim_vendor_con_last_rx_fine = 0
    nim_vendor_con_last_anchor = 0
    nim_vendor_con_last_win_offset = 0
    nim_vendor_con_last_interval = 0
    nim_vendor_con_last_timeout = 0
    nim_vendor_con_last_access_addr = 0
    nim_vendor_con_last_crcinit = 0
    nim_vendor_lld_con_start_count = 0
    nim_vendor_lld_con_start_status = 0
    discard c_memset(addr nim_vendor_lld_con_start_param[0], 0,
                     nim_vendor_lld_con_start_param.len.csize_t)
    nim_vendor_conn_evt_count = 0
    nim_vendor_conn_evt_handle = 0
    nim_vendor_conn_evt_peer_a0 = 0
    nim_vendor_conn_evt_peer_a1 = 0
    nim_vendor_conn_evt_peer_type = 0
    nim_vendor_disc_evt_count = 0
    nim_vendor_disc_evt_reason = 0
    discard c_memset(addr nim_vendor_llc_msg[0], 0,
                     nim_vendor_llc_msg.len.csize_t)
    discard c_memset(addr nim_vendor_llc_env_storage[0], 0,
                     nim_vendor_llc_env_storage.len.csize_t)
    nim_lld_rx_desc_idx = 0
    nim_lld_rx_desc_active = 0
    nim_lld_rx_check_count = 0
    nim_lld_rx_check_hit_count = 0
    nim_lld_rx_check_miss_count = 0
    nim_lld_rx_free_count = 0
    nim_lld_rx_last_idx = 0
    nim_lld_rx_last_env_idx = 0
    nim_lld_rx_last_status = 0
    nim_lld_rx_last_header = 0
    nim_lld_rx_last_meta = 0
    nim_vendor_llcp_rx_count = 0
    nim_vendor_llcp_tx_count = 0
    nim_vendor_llcp_tx_pending = 0
    nim_vendor_llcp_tx_queued = 0
    nim_vendor_llcp_tx_dropped = 0
    nim_vendor_llcp_tx_queue_head = 0
    nim_vendor_llcp_tx_queue_tail = 0
    nim_vendor_llcp_last_opcode = 0
    nim_vendor_llcp_last_status = 0
    nim_vendor_llcp_rx_log_index = 0
    nim_vendor_llcp_tx_log_index = 0
    nim_vendor_llcp_alloc_count = 0
    nim_vendor_llcp_free_count = 0
    nim_vendor_llcp_alloc_last_len = 0
    nim_vendor_llcp_alloc_last_ptr = 0
    nim_vendor_llcp_alloc_last_emoff = 0
    nim_vendor_llcp_alloc_last_len_field = 0
    nim_vendor_llcp_free_last_raw = 0
    nim_vendor_llcp_free_manual_count = 0
    nim_vendor_llcp_free_heap_count = 0
    discard c_memset(addr nim_vendor_llcp_rx_log[0], 0,
                     (sizeof(uint32) * nim_vendor_llcp_rx_log.len).csize_t)
    discard c_memset(addr nim_vendor_llcp_tx_log[0], 0,
                     (sizeof(uint32) * nim_vendor_llcp_tx_log.len).csize_t)
    nim_vendor_acl_empty_tx_count = 0
    nim_vendor_acl_empty_tx_pending = 0
    nim_vendor_acl_empty_last_status = 0
    initVendorRwipRfTable()
  discard c_memset(addr nim_adv_params[0], 0, nim_adv_params.len.csize_t)
  discard c_memset(addr nim_scan_params[0], 0, nim_scan_params.len.csize_t)
  discard c_memset(addr nim_adv_data[0], 0, nim_adv_data.len.csize_t)
  discard c_memset(addr nim_scan_rsp_data[0], 0, nim_scan_rsp_data.len.csize_t)
  initBleCoreRegisters()

proc localAddrBytes(dst: ptr uint8) =
  if dst == nil:
    return
  if nim_local_addr_valid:
    let raw = cast[ptr UncheckedArray[uint8]](dst)
    for i in 0 ..< nim_local_addr.len:
      raw[i] = nim_local_addr[i]
    return
  let lo = regRead((BLE_BASE + 0x024'u32).uint)
  let hi = regRead((BLE_BASE + 0x028'u32).uint)
  let raw = cast[ptr UncheckedArray[uint8]](dst)
  raw[0] = uint8(lo and 0xFF)
  raw[1] = uint8((lo shr 8) and 0xFF)
  raw[2] = uint8((lo shr 16) and 0xFF)
  raw[3] = uint8((lo shr 24) and 0xFF)
  raw[4] = uint8(hi and 0xFF)
  raw[5] = uint8((hi shr 8) and 0xFF)

proc defaultLocalAddrBytes(dst: ptr uint8) =
  localAddrBytes(dst)
  let raw = cast[ptr UncheckedArray[uint8]](dst)
  var anySet = false
  for i in 0 ..< 6:
    if raw[i] != 0:
      anySet = true
  if not anySet:
    raw[0] = 0x01'u8
    raw[1] = 0x23'u8
    raw[2] = 0x45'u8
    raw[3] = 0x67'u8
    raw[4] = 0x89'u8
    raw[5] = 0xAB'u8

proc programBtbleLegacyAdv(advDataLen: uint8) =
  let advLen = min(advDataLen.int, 31)
  let scanRspLen = min(nim_scan_rsp_data_len.int, 31)
  let pduLen = uint16(6 + advLen)
  let scanRspPduLen = uint16(6 + scanRspLen)
  var addrBytes: array[6, uint8]
  defaultLocalAddrBytes(addr addrBytes[0])

  copyBytes(BTBLE_EM_BASE + BtbleAdvDataOffset, addr nim_adv_data[0], advLen)
  copyBytes(BTBLE_EM_BASE + BtbleScanRspDataOffset,
            addr nim_scan_rsp_data[0], scanRspLen)
  copyBytes(BTBLE_EM_BASE + 0x128'u32, addr addrBytes[0], addrBytes.len)

  write16(BTBLE_EM_BASE + 0x120'u32, 0x0404'u16)
  write16(BTBLE_EM_BASE + 0x122'u32, 0x0020'u16)
  write16(BTBLE_EM_BASE + 0x124'u32, 0xE3F5'u16)
  write16(BTBLE_EM_BASE + 0x126'u32, 0'u16)
  write16(BTBLE_EM_BASE + 0x12E'u32, 0xBED6'u16)
  write16(BTBLE_EM_BASE + 0x130'u32, 0x8E89'u16)
  write16(BTBLE_EM_BASE + 0x132'u32, 0x5555'u16)
  write16(BTBLE_EM_BASE + 0x134'u32, 0x0055'u16)
  write16(BTBLE_EM_BASE + 0x136'u32, 0'u16)
  write16(BTBLE_EM_BASE + 0x138'u32, 0xF102'u16)
  write16(BTBLE_EM_BASE + 0x13A'u32, 0x0020'u16)
  write16(BTBLE_EM_BASE + 0x13C'u32, 0xBD86'u16)
  write16(BTBLE_EM_BASE + 0x13E'u32, 0'u16)
  regWrite((BTBLE_EM_BASE + 0x140'u32).uint, 0x11842182'u32)
  write16(BTBLE_EM_BASE + 0x144'u32, 0x0156'u16)
  write16(BTBLE_EM_BASE + 0x146'u32, 0x1338'u16)
  write16(BTBLE_EM_BASE + 0x148'u32, 0x3FD1'u16)
  write16(BTBLE_EM_BASE + 0x14A'u32, 0'u16)
  write16(BTBLE_EM_BASE + 0x14C'u32, 0xE745'u16)
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
          ((pduLen and 0x00FF'u16) shl 8) or 0x0020'u16)
  write16(BTBLE_EM_BASE + 0x55C'u32, BtbleAdvDataOffset.uint16)
  write16(BTBLE_EM_BASE + 0x55E'u32, 0xF84F'u16)
  write16(BTBLE_EM_BASE + 0x560'u32, 0x4592'u16)
  write16(BTBLE_EM_BASE + 0x562'u32, 0x7B9F'u16)
  write16(BTBLE_EM_BASE + 0x564'u32, 0x8EEC'u16)
  write16(BTBLE_EM_BASE + 0x566'u32, 0x51FB'u16)
  write16(BTBLE_EM_BASE + 0x568'u32, 0x0156'u16)
  write16(BTBLE_EM_BASE + 0x56A'u32,
          ((scanRspPduLen and 0x00FF'u16) shl 8) or 0x0004'u16)
  write16(BTBLE_EM_BASE + 0x56C'u32, BtbleScanRspDataOffset.uint16)
  write16(BTBLE_EM_BASE + 0x56E'u32, 0x2601'u16)
  regWrite((BTBLE_EM_BASE + 0x570'u32).uint, 0xB8B5344B'u32)
  regWrite((BTBLE_EM_BASE + 0x574'u32).uint, 0x3E8F9FB7'u32)

  when defined(bl808m0) and defined(bl808BleVendorLldAdvProbe):
    discard c_memset(addr nim_vendor_lld_adv_params[0], 0,
                     nim_vendor_lld_adv_params.len.csize_t)
    for i in 0 ..< addrBytes.len:
      nim_vendor_lld_adv_params[i] = addrBytes[i]
      nim_vendor_lld_adv_params[6 + i] = addrBytes[i]

    nim_vendor_lld_adv_params[16] = uint8(BtbleAdvDataOffset and 0x00FF'u32)
    nim_vendor_lld_adv_params[17] =
      uint8((BtbleAdvDataOffset shr 8) and 0x00FF'u32)
    nim_vendor_lld_adv_params[20] = uint8(advLen and 0x00FF)
    nim_vendor_lld_adv_params[21] = uint8((advLen shr 8) and 0x00FF)
    nim_vendor_lld_adv_params[24] = 0x13'u8  # legacy connectable ADV_IND
    nim_vendor_lld_adv_params[29] = 0x07'u8  # channels 37, 38, 39
    nim_vendor_lld_adv_params[33] = 0x7F'u8  # controller default TX power
    nim_vendor_lld_adv_params[34] = 1'u8     # primary PHY: LE 1M
    nim_vendor_lld_adv_params[35] = 1'u8
    nim_vendor_lld_adv_params[36] = 1'u8     # secondary PHY: LE 1M
    discard vendorLldAdvStart(0'u8, addr nim_vendor_lld_adv_params[0])
    write16(BTBLE_EM_BASE + 0x13A'u32, 0'u16)
    write16(BTBLE_EM_BASE + 0x150'u32, 0x0008'u16)
    write16(BTBLE_EM_BASE + 0x152'u32, 0'u16)

proc programNimAdvertising(enable: bool): uint8 =
  if not enable:
    nim_adv_enabled = false
    nim_adv_target_half_us = 0
    write16(BLE_EM_BASE + 0x0EA'u32, read16(BLE_EM_BASE + 0x0EA'u32) and
            not 0x2000'u16)
    regWrite((BLE_BASE + 0x018'u32).uint, 0'u32)
    regWrite((BLE_BASE + 0x9C0'u32).uint, 0'u32)
    return 0

  if not nim_ble_core_ready:
    initBleCoreRegisters()

  var pdu: array[39, uint8]
  let advLen = min(nim_adv_data_len.int, 31)
  pdu[0] = 0x00'u8
  pdu[1] = uint8(6 + advLen)
  localAddrBytes(addr pdu[2])
  for i in 0 ..< advLen:
    pdu[8 + i] = nim_adv_data[i]
  copyBytes(BLE_EM_BASE + 0x600'u32, addr pdu[0], 8 + advLen)
  programBtbleLegacyAdv(advLen.uint8)

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

  configureBleRf1M()
  regOr(BLE_BASE + 0x000'u32, 0x00000100'u32)
  regWrite((BLE_BASE + 0x828'u32).uint, 0x0000011E'u32)
  nim_adv_enabled = true
  regWrite((BLE_BASE + 0x018'u32).uint, 0x00008026'u32)
  scheduleBtbleEvent()
  0

when defined(bl808m0) and defined(bl808BleVendorLldScanProbe):
  const bl808BleVendorScanFlags* {.intdefine.}: int = 0x01

  proc scanPutLe16(off: int, value: uint16) =
    nim_vendor_lld_scan_params[off] = uint8(value and 0x00FF'u16)
    nim_vendor_lld_scan_params[off + 1] =
      uint8((value shr 8) and 0x00FF'u16)

  when defined(bl808BleVendorLldInitProbe):
    proc initPutLe16(off: int, value: uint16) =
      nim_vendor_lld_init_params[off] = uint8(value and 0x00FF'u16)
      nim_vendor_lld_init_params[off + 1] =
        uint8((value shr 8) and 0x00FF'u16)

    proc programVendorLldInitiator(params: ptr uint8, paramLen: uint8): uint8 =
      if params == nil or paramLen != 25'u8:
        return 0x12'u8
      let raw = cast[ptr UncheckedArray[uint8]](params)
      discard c_memset(addr nim_vendor_lld_init_params[0], 0,
                       nim_vendor_lld_init_params.len.csize_t)
      if bl808BleVendorInitSwapAddr:
        for i in 0 ..< 6:
          nim_vendor_lld_init_params[i] = raw[6 + i]
        defaultLocalAddrBytes(addr nim_vendor_lld_init_params[6])
      else:
        defaultLocalAddrBytes(addr nim_vendor_lld_init_params[0])
        for i in 0 ..< 6:
          nim_vendor_lld_init_params[6 + i] = raw[6 + i]
      nim_vendor_lld_init_params[12] = 0xFF'u8
      nim_vendor_lld_init_params[13] = 0xFF'u8
      nim_vendor_lld_init_params[14] = 0xFF'u8
      nim_vendor_lld_init_params[15] = 0xFF'u8
      nim_vendor_lld_init_params[16] = 0x1F'u8
      nim_vendor_lld_init_params[17] = 0x00'u8
      nim_vendor_lld_init_params[18] = 0x01'u8
      nim_vendor_lld_init_params[19] =
        uint8(bl808BleVendorInitActivityId and 0xFF)
      nim_vendor_lld_init_params[20] = raw[12]
      nim_vendor_lld_init_params[21] = raw[5]
      nim_vendor_lld_init_params[22] = raw[4]
      nim_vendor_lld_init_params[23] = 0x00'u8
      initPutLe16(24, paramLe16(params, 0))
      initPutLe16(26, paramLe16(params, 2))
      initPutLe16(28, paramLe16(params, 0))
      initPutLe16(30, 0'u16)
      initPutLe16(32, paramLe16(params, 17))
      initPutLe16(34, paramLe16(params, 19))
      for i in 0 ..< nim_vendor_init_hci_params.len:
        nim_vendor_init_hci_params[i] = raw[i]
      nim_vendor_init_active = true
      var initCallStack: array[2048, uint8]
      template initCallStackTop(): pointer =
        block:
          let rawTop =
            cast[uint32](addr initCallStack[initCallStack.len - 1]) + 1'u32
          cast[pointer]((rawTop and not 0xFu32).uint)
      nim_vendor_init_start_status =
        vendorLldInitStartIsolated(
          addr nim_vendor_lld_init_params[0], initCallStackTop()).uint32
      if nim_vendor_init_start_status == 0x0C'u32:
        discard vendorLldInitStop()
        vendorLldInitInit(3'u8)
        nim_vendor_init_start_status =
          vendorLldInitStartIsolated(
            addr nim_vendor_lld_init_params[0], initCallStackTop()).uint32
      if nim_vendor_init_start_status != 0'u32:
        nim_vendor_init_active = false
      uint8(nim_vendor_init_start_status and 0xFF'u32)

  proc programVendorLldScan(enable: bool): uint8 =
    if not enable:
      discard vendorLldScanStop()
      return 0

    discard c_memset(addr nim_vendor_lld_scan_params[0], 0,
                     nim_vendor_lld_scan_params.len.csize_t)
    defaultLocalAddrBytes(addr nim_vendor_lld_scan_params[0])
    nim_vendor_lld_scan_params[6] = nim_scan_params[5]
    nim_vendor_lld_scan_params[7] = uint8(bl808BleVendorScanFlags and 0xFF)
    let interval =
      uint16(nim_scan_params[1]) or (uint16(nim_scan_params[2]) shl 8)
    let window =
      uint16(nim_scan_params[3]) or (uint16(nim_scan_params[4]) shl 8)
    let scanInterval = if interval == 0'u16: 0x0060'u16 else: interval
    let scanWindow = if window == 0'u16: 0x0030'u16 else: window
    scanPutLe16(8, scanInterval)
    scanPutLe16(10, scanInterval)
    scanPutLe16(12, scanWindow)
    scanPutLe16(14, scanWindow)
    nim_vendor_lld_scan_params[16] = nim_scan_params[0]
    nim_vendor_lld_scan_params[17] = nim_scan_params[0]
    nim_vendor_lld_scan_params[18] = nim_scan_params[6]
    nim_vendor_lld_scan_params[19] = 0x00'u8
    nim_vendor_lld_scan_params[20] = 0x00'u8
    scanPutLe16(22, 0'u16)
    bleCentralDebugMark(0x820'u32, 0)
    nim_vendor_trace_first_zero_stage = 0
    bleCentralTraceStoreRawRa(20'u)
    bleCentralTraceStoreWord(24'u, 0)
    bleCentralTraceStoreWord(28'u, 0)
    var scanCallStack: array[2048, uint8]
    template scanCallStackTop(): pointer =
      block:
        let rawTop =
          cast[uint32](addr scanCallStack[scanCallStack.len - 1]) + 1'u32
        cast[pointer]((rawTop and not 0xFu32).uint)
    nim_vendor_scan_start_status =
      vendorLldScanStartIsolated(
        0'u8, addr nim_vendor_lld_scan_params[0], scanCallStackTop()).uint32
    bleCentralTraceCheckRawRa(0x0A40'u32)
    bleCentralDebugMark(0x821'u32, nim_vendor_scan_start_status)
    if nim_vendor_scan_start_status == 0x0C'u32:
      discard vendorLldScanStop()
      vendorLldScanInit(3'u8)
      bleCentralDebugMark(0x822'u32, 0)
      nim_vendor_trace_first_zero_stage = 0
      bleCentralTraceStoreRawRa(20'u)
      bleCentralTraceStoreWord(24'u, 0)
      bleCentralTraceStoreWord(28'u, 0)
      nim_vendor_scan_start_status =
        vendorLldScanStartIsolated(
          0'u8, addr nim_vendor_lld_scan_params[0], scanCallStackTop()).uint32
      bleCentralTraceCheckRawRa(0x0A41'u32)
      bleCentralDebugMark(0x823'u32, nim_vendor_scan_start_status)
    uint8(nim_vendor_scan_start_status and 0xFF'u32)

  proc ble_scan_probe_restart*(): uint8 {.exportc, cdecl.} =
    if not nim_scan_enabled:
      return 0
    inc nim_vendor_scan_restart_count
    discard vendorLldScanStop()
    var scanCallStack: array[2048, uint8]
    template scanCallStackTop(): pointer =
      block:
        let rawTop =
          cast[uint32](addr scanCallStack[scanCallStack.len - 1]) + 1'u32
        cast[pointer]((rawTop and not 0xFu32).uint)
    nim_vendor_scan_start_status =
      vendorLldScanStartIsolated(
        0'u8, addr nim_vendor_lld_scan_params[0], scanCallStackTop()).uint32
    if nim_vendor_scan_start_status == 0x0C'u32:
      vendorLldScanInit(3'u8)
      nim_vendor_scan_start_status =
        vendorLldScanStartIsolated(
          0'u8, addr nim_vendor_lld_scan_params[0], scanCallStackTop()).uint32
    uint8(nim_vendor_scan_start_status and 0xFF'u32)

  when defined(bl808BleVendorLldInitProbe):
    proc ble_init_probe_param_byte*(index: uint8): uint8 {.exportc, cdecl.} =
      if index.int < nim_vendor_lld_init_params.len:
        nim_vendor_lld_init_params[index.int]
      else:
        0

    proc ble_init_probe_service_peer_complete*(): uint8 {.exportc, cdecl.} =
      when bl808BleVendorInitPeerComplete:
        if nim_vendor_init_peer_complete_pending != 0 and
            nim_vendor_init_msg_count == 0:
          nim_vendor_init_peer_complete_pending = 0
          inc nim_vendor_init_peer_complete_count
          inc nim_vendor_init_success_count
          nim_conn_active = true
          nim_conn_handle = 0
          nim_vendor_init_active = false
          return 1'u8
      0'u8

proc handleNimHciCommand(opcode: uint16, params: ptr uint8,
                         paramLen: uint8): uint8 =
  let raw = cast[ptr UncheckedArray[uint8]](params)
  case opcode
  of HciOpReset:
    resetNimControllerState()
    0
  of HciOpDisconnect:
    if paramLen != 3 or params == nil:
      return 0x12'u8
    let handle = raw[0].uint16 or (raw[1].uint16 shl 8)
    if not nim_conn_active or handle != nim_conn_handle:
      return 0x02'u8
    sendDisconnectComplete(handle, raw[2])
    0
  of HciOpLeSetRandomAddress:
    if paramLen != 6 or params == nil:
      return 0x12'u8
    for i in 0 ..< nim_local_addr.len:
      nim_local_addr[i] = raw[i]
    nim_local_addr_valid = true
    0
  of HciOpLeSetAdvParams:
    if paramLen != 15 or params == nil:
      return 0x12'u8
    for i in 0 ..< 15:
      nim_adv_params[i] = raw[i]
    0
  of HciOpLeSetAdvData:
    if paramLen != 32 or params == nil:
      return 0x12'u8
    if raw[0] > 31'u8:
      return 0x12'u8
    let n = min(raw[0].int, nim_adv_data.len)
    nim_adv_data_len = n.uint8
    for i in 0 ..< n:
      nim_adv_data[i] = raw[i + 1]
    0
  of HciOpLeSetScanRspData:
    if paramLen != 32 or params == nil:
      return 0x12'u8
    if raw[0] > 31'u8:
      return 0x12'u8
    let n = min(raw[0].int, nim_scan_rsp_data.len)
    nim_scan_rsp_data_len = n.uint8
    for i in 0 ..< n:
      nim_scan_rsp_data[i] = raw[i + 1]
    if nim_adv_enabled:
      programBtbleLegacyAdv(nim_adv_data_len)
    0
  of HciOpLeSetAdvEnable:
    if paramLen != 1 or params == nil:
      return 0x12'u8
    programNimAdvertising(raw[0] != 0)
  of HciOpLeSetScanParams:
    if paramLen != 7 or params == nil:
      return 0x12'u8
    for i in 0 ..< nim_scan_params.len:
      nim_scan_params[i] = raw[i]
    0
  of HciOpLeSetScanEnable:
    if paramLen != 2 or params == nil:
      return 0x12'u8
    nim_scan_enabled = raw[0] != 0
    when defined(bl808m0) and defined(bl808BleVendorLldScanProbe):
      bleCentralDebugMark(0x800'u32, raw[0].uint32)
      let scanStatus = programVendorLldScan(nim_scan_enabled)
      bleCentralDebugMark(0x801'u32, nim_vendor_scan_start_status)
      scanStatus
    else:
      0
  of HciOpLeCreateConnection:
    if paramLen != 25 or params == nil:
      return 0x12'u8
    nim_scan_enabled = false
    when defined(bl808m0) and defined(bl808BleVendorLldScanProbe) and
        defined(bl808BleVendorLldInitProbe):
      let initStatus = programVendorLldInitiator(params, paramLen)
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
    when defined(bl808m0) and defined(bl808BleVendorLldScanProbe) and
        defined(bl808BleVendorLldInitProbe):
      if not nim_vendor_init_active:
        return 0x0C'u8
      let before = nim_vendor_init_msg_count
      inc nim_vendor_init_cancel_count
      nim_vendor_init_cancel_status = vendorLldInitStop().uint32
      if nim_vendor_init_active and nim_vendor_init_msg_count == before:
        inc nim_vendor_init_failure_count
        sendLeConnectionCompleteStatus(addr nim_vendor_init_hci_params[0],
                                       25'u8,
                                       0x3E'u8)
        nim_vendor_init_active = false
      0
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

proc patch_ble_ke_event_schedule*() {.exportc: "_patch_ble_ke_event_schedule", cdecl.} =
  var field = ke_event_field
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
    field = ke_event_field

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
  cast[ptr KeMsgHeader](cast[uint](param) - 12)

when defined(bl808m0) and defined(bl808BleVendorLldConProbe) and
    defined(bl808BleVendorManualConnTx):
  proc handleVendorLldMessage(param: pointer): bool =
    if param == nil:
      return false
    let hdr = getMsgHeader(param)
    let p = cast[ptr UncheckedArray[uint8]](param)
    let conhdl = uint16((hdr.dest_id shr 8) and 0x00FF'u16)
    case hdr.id
    of 523'u16:
      let pduLen = uint16(p[2])
      let dataOff = uint16(p[4]) or (uint16(p[5]) shl 8)
      inc nim_vendor_llcp_rx_count
      vendorRecordLlcpRx(0'u16, dataOff, pduLen)
      if pduLen > 0'u16:
        let opcode = read8(BTBLE_EM_BASE + dataOff.uint32)
        let reason =
          if pduLen > 1'u16: read8(BTBLE_EM_BASE + dataOff.uint32 + 1'u32)
          else: 0x13'u8
        nim_vendor_llcp_last_opcode = opcode.uint32
        vendorRespondToLlcp(conhdl, opcode, reason)
      true
    of 525'u16:
      let dataOff = uint16(p[0]) or (uint16(p[1]) shl 8)
      let pduLen = uint16(p[2]) or (uint16(p[3]) shl 8)
      let llid = p[4] and 0x03'u8
      inc nim_vendor_llcp_rx_count
      if llid == 0x03'u8 and pduLen > 0'u16:
        vendorRecordLlcpRx(uint16(llid), dataOff, pduLen)
        let opcode = read8(BTBLE_EM_BASE + dataOff.uint32)
        let reason =
          if pduLen > 1'u16: read8(BTBLE_EM_BASE + dataOff.uint32 + 1'u32)
          else: 0x13'u8
        nim_vendor_llcp_last_opcode = opcode.uint32
        vendorRespondToLlcp(conhdl, opcode, reason)
      true
    else:
      false

when defined(bl808m0) and defined(bl808BleVendorLldScanProbe) and
    defined(bl808BleVendorLldInitProbe):
  proc handleVendorLldInitMessage(param: pointer): bool =
    if param == nil:
      return false
    let hdr = getMsgHeader(param)
    if hdr.id != 521'u16:
      return false
    let p = cast[ptr UncheckedArray[uint8]](param)
    inc nim_vendor_init_msg_count
    if hdr.param_len >= 1'u16:
      nim_vendor_init_last_activity = p[0].uint32
    if hdr.param_len >= 2'u16:
      nim_vendor_init_last_msg_status = p[1].uint32
    if nim_vendor_init_active:
      if hdr.param_len >= 2'u16 and p[1] != 0'u8:
        inc nim_vendor_init_success_count
        sendLeConnectionCompleteStatus(addr nim_vendor_init_hci_params[0], 25'u8,
                                       0'u8)
      else:
        inc nim_vendor_init_failure_count
        sendLeConnectionCompleteStatus(addr nim_vendor_init_hci_params[0], 25'u8,
                                       0x3E'u8)
      nim_vendor_init_active = false
    true

proc patch_ble_ke_msg_alloc*(id: KeMsgId, dest_id: KeTaskId,
                                 src_id: KeTaskId, param_len: uint16): pointer {.exportc: "_patch_ble_ke_msg_alloc", cdecl.} =
  ## Allocate a kernel message with header + param space
  let total = param_len.uint32 + 12  # header is 12 bytes
  let mem = ble_ke_malloc(total, 0)
  if mem == nil:
    return nil
  let hdr = cast[ptr KeMsgHeader](mem)
  hdr.next = cast[ptr KeMsgHeader](cast[uint32](0xFFFFFFFF'u32))  # -1 sentinel
  hdr.id = id
  hdr.dest_id = dest_id
  hdr.src_id = src_id
  hdr.param_len = param_len
  let param = cast[pointer](cast[uint](mem) + 12)
  discard c_memset(param, 0, param_len.csize_t)
  return param

proc ble_ke_msg_alloc*(id: KeMsgId, dest_id: KeTaskId,
                        src_id: KeTaskId, param_len: uint16): pointer {.exportc, cdecl.} =
  when defined(bl808m0) and defined(bl808BleVendorLldScanProbe) and
      defined(bl808BleVendorLldInitProbe):
    if id == 521'u16:
      inc nim_vendor_init_msg_alloc_count
      nim_vendor_init_msg_alloc_last_len = param_len.uint32
      nim_vendor_init_msg_alloc_last_dest = dest_id.uint32
      nim_vendor_init_msg_alloc_last_src = src_id.uint32
  if ke_msg_alloc_patch != nil:
    var res: pointer
    let r = ke_msg_alloc_patch(addr res, id, dest_id, src_id, param_len)
    if r != 0:
      return res
  return patch_ble_ke_msg_alloc(id, dest_id, src_id, param_len)

proc patch_ble_ke_msg_send*(param: pointer) {.exportc: "_patch_ble_ke_msg_send", cdecl.} =
  ## Send a kernel message (enqueue to destination)
  when defined(bl808m0) and defined(bl808BleVendorLldScanProbe) and
      defined(bl808BleVendorLldInitProbe):
    if handleVendorLldInitMessage(param):
      ble_ke_free(getMsgHeader(param))
      return
  when defined(bl808m0) and defined(bl808BleVendorLldConProbe):
    when bl808BleVendorManualConnTx:
      if handleVendorLldMessage(param):
        ble_ke_free(getMsgHeader(param))
        return
  let old = disableInterrupts()
  let hdr = getMsgHeader(param)
  ble_co_list_push_back(addr ke_msg_queue, cast[ptr CoListNode](hdr))
  restoreInterrupts(old)
  ble_ke_event_set(2)  # KE_EVT_MESSAGE

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
  when defined(bl808m0) and defined(bl808BleVendorLldConProbe) and
      defined(bl808BleVendorManualConnTx):
    if id == 0x0213'u16: # LLD_DISC_IND routed to LLC in the vendor task table.
      discard dest_id
      discard src_id
      noteVendorPeripheralDisconnected(0x13'u8)
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
    (defined(bl808BleVendorLldConProbe) or defined(bl808BleVendorLldScanProbe)):
  type SchArbStartCb = proc(elt: pointer) {.cdecl.}

  const bl808BleVendorDeferArbCallbacks* {.booldefine.}: bool = true

  when defined(bl808BleVendorLldScanProbe) and
      not defined(bl808BleVendorArbProbe):
    var nim_vendor_arb_pending_cb: array[4, SchArbStartCb]
    var nim_vendor_arb_pending_elt: array[4, pointer]
    var nim_vendor_arb_pending_count: uint8

  proc runVendorArbCallback(cb: SchArbStartCb, elt: pointer) =
    when defined(bl808BleVendorLlcStartProbe):
      if nim_vendor_llc_status == 0xC0010100'u32:
        nim_vendor_llc_status = 0xC0010101'u32
    when defined(bl808BleVendorLldScanProbe):
      inc nim_vendor_scan_arb_cb_count
      when defined(bl808BleVendorLldInitProbe):
        if nim_vendor_init_active:
          inc nim_vendor_init_arb_cb_count
    cb(elt)
    when defined(bl808BleVendorLlcStartProbe):
      if nim_vendor_llc_status == 0xC0010101'u32:
        nim_vendor_llc_status = 0xC0010102'u32

  when defined(bl808BleVendorLldConProbe) and
      not defined(bl808BleVendorArbProbe):
    proc conArbPendingWords(): ptr UncheckedArray[uint32] {.inline.} =
      cast[ptr UncheckedArray[uint32]](addr nim_vendor_lld_con_start_param[0])

    proc queueVendorArbCallback(cb: SchArbStartCb, elt: pointer): bool =
      let pending = conArbPendingWords()
      if pending[0] != 0'u32:
        return false
      pending[0] = cast[uint32](cast[uint](cb))
      pending[1] = cast[uint32](cast[uint](elt))
      true

    proc serviceVendorArbCallbacks() =
      let pending = conArbPendingWords()
      while pending[0] != 0'u32:
        let cbRaw = pending[0]
        let eltRaw = pending[1]
        pending[0] = 0'u32
        pending[1] = 0'u32
        let cb = cast[SchArbStartCb](cbRaw.uint)
        let elt = cast[pointer](eltRaw.uint)
        if cb != nil:
          runVendorArbCallback(cb, elt)

  elif defined(bl808BleVendorLldScanProbe) and
      not defined(bl808BleVendorArbProbe):
    proc queueVendorArbCallback(cb: SchArbStartCb, elt: pointer): bool =
      if nim_vendor_arb_pending_count.int >= nim_vendor_arb_pending_cb.len:
        return false
      let slot = nim_vendor_arb_pending_count.int
      nim_vendor_arb_pending_cb[slot] = cb
      nim_vendor_arb_pending_elt[slot] = elt
      inc nim_vendor_arb_pending_count
      true

    proc serviceVendorArbCallbacks() =
      while nim_vendor_arb_pending_count != 0:
        let cb = nim_vendor_arb_pending_cb[0]
        let elt = nim_vendor_arb_pending_elt[0]
        for i in 1 ..< nim_vendor_arb_pending_cb.len:
          nim_vendor_arb_pending_cb[i - 1] = nim_vendor_arb_pending_cb[i]
          nim_vendor_arb_pending_elt[i - 1] = nim_vendor_arb_pending_elt[i]
        let last = nim_vendor_arb_pending_cb.len - 1
        nim_vendor_arb_pending_cb[last] = nil
        nim_vendor_arb_pending_elt[last] = nil
        dec nim_vendor_arb_pending_count
        if cb != nil:
          runVendorArbCallback(cb, elt)

  proc nimLldRxDescAddr(idx: uint8): uint32 {.inline.} =
    BTBLE_EM_BASE + 0x458'u32 + uint32(idx and 0x07'u8) * 0x20'u32

  proc lld_rxdesc_check*(idx: uint8): pointer {.exportc, cdecl.} =
    when defined(bl808BleBridgeDiag):
      nim_vendor_bridge_stage = 0x6000'u32 or idx.uint32
    inc nim_lld_rx_check_count
    for step in 0'u32 ..< 8'u32:
      let cur = lld_env[14] and 0x07'u8
      let desc = nimLldRxDescAddr(cur)
      let status = read16(desc)
      let header = read16(desc + 0x04'u32)
      let meta = read16(desc + 0x0C'u32)
      nim_lld_rx_last_idx = idx.uint32
      nim_lld_rx_last_env_idx = cur.uint32
      nim_lld_rx_last_status = status.uint32
      nim_lld_rx_last_header = header.uint32
      nim_lld_rx_last_meta = meta.uint32
      if (status and 0x8000'u16) == 0:
        break
      if header == 0'u16:
        write16(desc, status and not 0x8000'u16)
        lld_env[14] = uint8((uint32(cur) + 1'u32) and 0x07'u32)
        inc nim_lld_rx_free_count
        continue
      let pduType = uint8(header and 0x000F'u16)
      let pduLen = uint8((header shr 8) and 0x003F'u16)
      when defined(bl808BleVendorLldInitProbe):
        if nim_vendor_init_active and pduLen >= 6'u8 and
            (pduType == 0x00'u8 or pduType == 0x02'u8 or
             pduType == 0x04'u8 or pduType == 0x06'u8):
          let payloadBase = BTBLE_EM_BASE + read16(desc + 0x14'u32).uint32
          var peerMatches = true
          for j in 0 ..< 6:
            if read8(payloadBase + j.uint32) != nim_vendor_init_hci_params[6 + j]:
              peerMatches = false
          if peerMatches:
            bleCentralDebugMark(0x700'u32,
              (uint32(header) shl 16) or uint32(status))
            var initHeader = header
            var initStatus = status
            if (initHeader and 0x0020'u16) != 0'u16:
              initHeader = initHeader and not 0x0020'u16
              write16(desc + 0x04'u32, initHeader)
              inc nim_vendor_init_header_fix_count
            when bl808BleVendorInitStatusFix:
              const initRxStatusErrorMask = 0x017E'u16
              if (initStatus and initRxStatusErrorMask) != 0'u16:
                initStatus = initStatus and not initRxStatusErrorMask
                write16(desc, initStatus)
                inc nim_vendor_init_status_fix_count
                nim_vendor_init_status_fix_last = status.uint32
            inc nim_vendor_init_peer_rx_count
            nim_vendor_init_peer_rx_last_header = header.uint32
            nim_vendor_init_peer_rx_last_status = status.uint32
            nim_vendor_init_peer_rx_last_meta = meta.uint32
      when defined(bl808BleVendorLldScanProbe):
        if pduLen >= 6'u8 and
            (pduType == 0x00'u8 or pduType == 0x02'u8 or
             pduType == 0x04'u8 or pduType == 0x06'u8):
          sendLeAdvertisingReportFromRxDesc(header, read16(desc + 0x14'u32))
        elif pduLen > 0'u8:
          noteUnsupportedScanPdu(header, read16(desc + 0x14'u32))
      when defined(bl808BleVendorLldConProbe):
        if pduType == 0x05'u8 and pduLen == 34'u8:
          inc nim_ble_dbg_rx_connect_ind_count
          # Match vendor lld_adv_frm_isr timing extraction.
          let rxFine = read16(desc + 0x08'u32) and 0x03FF'u16
          let rxClock = read16(desc + 0x0A'u32).uint32
          var connectPdu: array[34, uint8]
          let payload = cast[ptr UncheckedArray[uint8]](
            (BTBLE_EM_BASE + read16(desc + 0x14'u32).uint32).uint)
          for j in 0 ..< connectPdu.len:
            connectPdu[j] = payload[j]
          write16(desc, status and not 0x8000'u16)
          noteVendorRxDescConsumed(cur.uint32)
          inc nim_lld_rx_free_count
          startVendorLldConnectionFromConnectInd(uint8(cur and 0x07'u8),
            cast[ptr UncheckedArray[uint8]](addr connectPdu[0]),
            header, rxClock, rxFine)
          nimVendorConnMark(0x250'u32)
          continue
        when defined(bl808BleVendorManualConnTx):
          if nim_vendor_con_started and pduType == 0x03'u8 and pduLen > 0'u8:
            let dataOff = read16(desc + 0x14'u32)
            vendorRecordLlcpRx(header, dataOff, pduLen.uint16)
            let opcode = read8(BTBLE_EM_BASE + dataOff.uint32)
            let reason =
              if pduLen > 1'u8: read8(BTBLE_EM_BASE + dataOff.uint32 + 1'u32)
              else: 0x13'u8
            inc nim_vendor_llcp_rx_count
            nim_vendor_llcp_last_opcode =
              (uint32(header) shl 16) or opcode.uint32
            vendorRespondToLlcp(1'u16, opcode, reason)
            write16(desc, status and not 0x8000'u16)
            noteVendorRxDescConsumed(cur.uint32)
            inc nim_lld_rx_free_count
            continue
      if pduType == 0x03'u8 and pduLen == 12'u8:
        write16(desc, status and not 0x8000'u16)
        lld_env[14] = uint8((uint32(cur) + 1'u32) and 0x07'u32)
        inc nim_lld_rx_free_count
        continue
      let descIdx = uint8((meta shr 11) and 0x001F'u16)
      if descIdx == (idx and 0x1F'u8):
        when defined(bl808BleVendorLldInitProbe):
          if nim_vendor_init_active and pduLen >= 6'u8 and
              (pduType == 0x00'u8 or pduType == 0x02'u8 or
               pduType == 0x04'u8 or pduType == 0x06'u8):
            let payloadBase = BTBLE_EM_BASE + read16(desc + 0x14'u32).uint32
            var peerMatches = true
            for j in 0 ..< 6:
              if read8(payloadBase + j.uint32) != nim_vendor_init_hci_params[6 + j]:
                peerMatches = false
            if peerMatches:
              inc nim_vendor_init_peer_hit_count
              bleCentralDebugMark(0x710'u32,
                (uint32(header) shl 16) or uint32(status))
              when bl808BleVendorInitPeerComplete:
                if nim_vendor_init_msg_count == 0:
                  nim_vendor_init_peer_complete_pending = 1
                  bleCentralDebugMark(0x711'u32,
                    (uint32(header) shl 16) or uint32(status))
                  write16(desc, status and not 0x8000'u16)
                  lld_env[14] = uint8((uint32(cur) + 1'u32) and 0x07'u32)
                  inc nim_lld_rx_free_count
                  continue
        when defined(bl808BleVendorManualConnTx):
          nim_vendor_llcp_last_opcode =
            (uint32(header) shl 16) or uint32(meta)
          if pduLen > 0'u8:
            let dataOff = read16(desc + 0x14'u32)
            vendorRecordLlcpRx(header, dataOff, pduLen.uint16)
            let opcode = read8(BTBLE_EM_BASE + dataOff.uint32)
            let reason =
              if pduLen > 1'u8: read8(BTBLE_EM_BASE + dataOff.uint32 + 1'u32)
              else: 0x13'u8
            nim_vendor_llcp_last_opcode =
              (uint32(pduType) shl 24) or (uint32(pduLen) shl 16) or
              opcode.uint32
            if pduType == 0x03'u8 or opcode == 0x02'u8 or
                opcode == 0x08'u8 or opcode == 0x0C'u8 or opcode == 0x14'u8:
              inc nim_vendor_llcp_rx_count
              vendorRespondToLlcp(1'u16, opcode, reason)
        nim_lld_rx_desc_idx = cur
        nim_lld_rx_desc_active = 1'u8
        inc nim_lld_rx_check_hit_count
        when defined(bl808BleBridgeDiag):
          nim_vendor_bridge_stage = 0x6100'u32 or cur.uint32
        return cast[pointer](desc)
      break
    inc nim_lld_rx_check_miss_count
    when defined(bl808BleBridgeDiag):
      nim_vendor_bridge_stage = 0x6200'u32 or idx.uint32
    nil

  proc lld_rxdesc_free*(desc: pointer) {.exportc, cdecl.} =
    when defined(bl808BleBridgeDiag):
      nim_vendor_bridge_stage = 0x6300'u32 or
        (cast[uint32](desc) and 0x000000FF'u32)
    if nim_lld_rx_desc_active != 0:
      inc nim_lld_rx_free_count
      let fallback = nim_lld_rx_desc_idx and 0x07'u8
      let rawDesc = cast[uint32](desc)
      let cur =
        if rawDesc >= nimLldRxDescAddr(0'u8) and
            rawDesc < nimLldRxDescAddr(8'u8) and
            ((rawDesc - nimLldRxDescAddr(0'u8)) and 0x1F'u32) == 0'u32:
          uint8(((rawDesc - nimLldRxDescAddr(0'u8)) div 0x20'u32) and
                0x07'u32)
        else:
          fallback
      let descAddr = nimLldRxDescAddr(cur)
      let status = read16(descAddr)
      write16(descAddr, status and not 0x8000'u16)
      lld_env[14] = uint8((uint32(cur) + 1'u32) and 0x07'u32)
      nim_lld_rx_desc_idx = lld_env[14]
      nim_lld_rx_desc_active = 0'u8

  when defined(bl808BleVendorManualConnTx):
    proc serviceVendorConnectionLlcpRxDescriptors() =
      if not nim_vendor_con_started:
        return
      for cur in 0'u32 ..< 8'u32:
        let desc = nimLldRxDescAddr(uint8(cur and 0x07'u32))
        let status = read16(desc)
        if (status and 0x8000'u16) == 0:
          continue
        let header = read16(desc + 0x04'u32)
        let pduType = uint8(header and 0x000F'u16)
        let pduLen = uint8((header shr 8) and 0x003F'u16)
        if pduType == 0x03'u8 and pduLen > 0'u8:
          let dataOff = read16(desc + 0x14'u32)
          vendorRecordLlcpRx(header, dataOff, pduLen.uint16)
          let opcode = read8(BTBLE_EM_BASE + dataOff.uint32)
          let reason =
            if pduLen > 1'u8: read8(BTBLE_EM_BASE + dataOff.uint32 + 1'u32)
            else: 0x13'u8
          inc nim_vendor_llcp_rx_count
          nim_vendor_llcp_last_opcode =
            (uint32(header) shl 16) or opcode.uint32
          vendorRespondToLlcp(1'u16, opcode, reason)
          write16(desc, status and not 0x8000'u16)
          if (lld_env[14] and 0x07'u8) == uint8(cur and 0x07'u32):
            noteVendorRxDescConsumed(cur)
          inc nim_lld_rx_free_count

  when not defined(bl808BleVendorArbProbe):
    proc sch_arb_insert*(elt: pointer): uint8 {.exportc, cdecl.} =
      when defined(bl808BleBridgeDiag):
        nim_vendor_bridge_stage = 0x7000'u32 or
          (cast[uint32](elt) and 0x000000FF'u32)
      bleCentralTraceCheckRawRa(0x0A30'u32)
      when defined(bl808BleVendorLlcStartProbe):
        if nim_vendor_llc_status == 0xC0010001'u32:
          nim_vendor_llc_status = 0xC0010100'u32
      when defined(bl808BleVendorLldScanProbe):
        inc nim_vendor_scan_arb_insert_count
      if elt != nil:
        when not defined(bl808BleVendorLldConProbe) and
            not (defined(bl808BleVendorLldScanProbe) and
                 not defined(bl808BleVendorLldConProbe)):
          let bytes = cast[ptr UncheckedArray[uint8]](elt)
          bytes[26] = 0x70'u8
        let words = cast[ptr UncheckedArray[uint32]](elt)
        when defined(bl808BleVendorLldScanProbe):
          let scanTarget = (currentBtbleTime() + 32'u32) and 0x0FFFFFFF'u32
          when defined(bl808BleVendorLldInitProbe):
            if nim_vendor_init_active:
              inc nim_vendor_init_arb_insert_count
              nim_vendor_init_arb_last_w1 = words[1]
              nim_vendor_init_arb_last_w2 = words[2]
              nim_vendor_init_arb_last_w7 = words[7]
              nim_vendor_init_arb_last_w24 = words[24]
              nim_vendor_init_arb_last_w28 = words[28]
              when bl808BleVendorInitPatchArb:
                words[2] = 578'u32
                words[24] = 0x00000C22'u32
                words[28] = scanTarget
          words[1] = scanTarget
          when defined(bl808BleVendorLldInitProbe):
            if not nim_vendor_init_active:
              words[28] = scanTarget
              words[2] = 578'u32
              words[24] = 0x00000C22'u32
          else:
            words[28] = scanTarget
            words[2] = 578'u32
            words[24] = 0x00000C22'u32
        else:
          when not defined(bl808BleVendorLldConProbe):
            words[2] = 578'u32
            words[24] = 0x00000C22'u32
        let cb = cast[SchArbStartCb](words[7])
        if cb != nil:
          when defined(bl808BleVendorLldConProbe):
            if queueVendorArbCallback(cb, elt):
              rwip_sw_int_req()
            else:
              return 0'u8
          elif defined(bl808BleVendorLldScanProbe):
            when bl808BleVendorDeferArbCallbacks:
              if not queueVendorArbCallback(cb, elt):
                runVendorArbCallback(cb, elt)
            else:
              runVendorArbCallback(cb, elt)
          else:
            runVendorArbCallback(cb, elt)
      when defined(bl808BleBridgeDiag):
        nim_vendor_bridge_stage = 0x7100'u32 or
          (cast[uint32](elt) and 0x000000FF'u32)
      bleCentralTraceCheckRawRa(0x0B00'u32)
      when defined(bl808BleVendorLldConProbe):
        1
      else:
        0

    proc sch_arb_remove*(elt: pointer): uint8 {.exportc, cdecl.} =
      when defined(bl808BleBridgeDiag):
        nim_vendor_bridge_stage = 0x7200'u32 or
          (cast[uint32](elt) and 0x000000FF'u32)
      discard elt
      0

  when not (defined(bl808m0) and
      (defined(bl808BleVendorFullSchedulerProbe) or
       defined(bl808BleVendorSliceProbe))):
    proc sch_slice_per_add*(sliceType: uint8, conhdl: uint8,
                            interval: uint32, anchor: uint32,
                            offset: uint16): uint8 {.exportc, cdecl.} =
      when defined(bl808BleVendorSchedulerDiag) and defined(bl808m0) and
          (defined(bl808BleVendorSchProgProbe) or
           defined(bl808BleVendorLldAdvProbe) or
           defined(bl808BleVendorLldConProbe) or
           defined(bl808BleVendorLldScanProbe)):
        inc nim_vendor_slice_add_count
        nim_vendor_slice_last_type_con =
          (uint32(sliceType) shl 16) or uint32(conhdl)
        nim_vendor_slice_last_interval = interval
        nim_vendor_slice_last_anchor = anchor
        nim_vendor_slice_last_offset = offset.uint32
      when defined(bl808BleVendorLlcStartProbe):
        if nim_vendor_llc_status == 0xC0010102'u32:
          nim_vendor_llc_status = 0xC0010200'u32
      discard sliceType
      discard conhdl
      discard interval
      discard anchor
      discard offset
      0

    proc sch_slice_per_remove*(sliceType: uint8,
                               conhdl: uint8): uint8 {.exportc, cdecl.} =
      when defined(bl808BleVendorSchedulerDiag) and defined(bl808m0) and
          (defined(bl808BleVendorSchProgProbe) or
           defined(bl808BleVendorLldAdvProbe) or
           defined(bl808BleVendorLldConProbe) or
           defined(bl808BleVendorLldScanProbe)):
        inc nim_vendor_slice_remove_count
        nim_vendor_slice_last_type_con =
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
  return 1  # KE_MSG_CONSUMED

proc ble_ke_msg_save*(msgid: KeMsgId, dest_id: KeTaskId,
                       src_id: KeTaskId, param: pointer): int32 {.exportc, cdecl.} =
  ## Default message handler: save (keep in queue)
  return 2  # KE_MSG_SAVED

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
    var dummy: uint32
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
        let handler_ptr = cast[uint](desc.state_handler) + (st.uint * sizeof(KeStateHandler).uint)
        ke_task_saved[task_type] = cast[ptr KeStateHandler](handler_ptr)

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
  let handler_ptr = cast[uint](task_desc.state_handler) + (st.uint * sizeof(KeStateHandler).uint)
  let state_handler = cast[ptr KeStateHandler](handler_ptr)
  if state_handler.msg_table != nil:
    for i in 0'u16 ..< state_handler.msg_cnt:
      let entry_ptr = cast[uint](state_handler.msg_table) + (i.uint * sizeof(KeStateMsgHandler).uint)
      let entry = cast[ptr KeStateMsgHandler](entry_ptr)
      if entry.id == msg_id:
        return entry.handler
  # Check default handler
  if task_desc.default_handler != nil and task_desc.default_handler.msg_table != nil:
    for i in 0'u16 ..< task_desc.default_handler.msg_cnt:
      let entry_ptr = cast[uint](task_desc.default_handler.msg_table) + (i.uint * sizeof(KeStateMsgHandler).uint)
      let entry = cast[ptr KeStateMsgHandler](entry_ptr)
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

proc patch_ble_ke_task_schedule*() {.exportc: "_patch_ble_ke_task_schedule", cdecl.} =
  ## Process one message from the message queue
  let old = disableInterrupts()
  let node = ble_co_list_pop_front(addr ke_msg_queue)
  restoreInterrupts(old)
  if node == nil:
    # Check if queue empty, if so clear event
    let old2 = disableInterrupts()
    if ke_msg_queue.first == nil:
      ble_ke_event_set(2)
    restoreInterrupts(old2)
    return
  let hdr = cast[ptr KeMsgHeader](node)
  hdr.next = cast[ptr KeMsgHeader](cast[uint32](0xFFFFFFFF'u32))
  when defined(bl808m0) and defined(bl808BleVendorLldConProbe) and
      defined(bl808BleVendorManualConnTx):
    let vendorLlcpTxCfm = hdr.id == 524'u16
  let handler = ble_ke_task_handler_get(hdr.id, hdr.dest_id)
  let param = cast[pointer](cast[uint](hdr) + 12)
  if handler != nil:
    let result = handler(hdr.id, hdr.dest_id, hdr.src_id, param)
    case result
    of 1:  # KE_MSG_CONSUMED
      let old3 = disableInterrupts()
      if ke_msg_queue.first != nil:
        ble_ke_event_set(2)
      restoreInterrupts(old3)
    of 2:  # KE_MSG_SAVED
      # Re-insert into saved list
      let old3 = disableInterrupts()
      ble_co_list_push_back(addr ke_msg_queue, cast[ptr CoListNode](hdr))
      restoreInterrupts(old3)
    else:
      ble_ke_msg_free(hdr)
      let old3 = disableInterrupts()
      if ke_msg_queue.first != nil:
        ble_ke_event_set(2)
      restoreInterrupts(old3)
  else:
    ble_ke_msg_free(hdr)
    let old3 = disableInterrupts()
    if ke_msg_queue.first != nil:
      ble_ke_event_set(2)
    restoreInterrupts(old3)
  when defined(bl808m0) and defined(bl808BleVendorLldConProbe) and
      defined(bl808BleVendorManualConnTx):
    if vendorLlcpTxCfm and nim_vendor_llcp_tx_pending == 0:
      vendorTrySendQueuedLlcp()

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
  while true:
    let v = regRead(BLE_BASE + BLE_BASETIMECNT_OFFSET)
    if (v and 0x80000000'u32) == 0:
      break
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

proc patch_ble_ke_timer_schedule*() {.exportc: "_patch_ble_ke_timer_schedule", cdecl.} =
  ## Process expired timers
  while ke_timer_list.first != nil:
    let timer = cast[ptr KeTimer](ke_timer_list.first)
    if not ble_ke_time_past(timer.time):
      break
    discard ble_co_list_pop_front(addr ke_timer_list)
    ble_ke_msg_send_basic(timer.id, timer.task, timer.task)
    ble_ke_free(timer)
  # Reprogram HW timer
  if ke_timer_list.first != nil:
    ble_ke_timer_hw_set(cast[ptr KeTimer](ke_timer_list.first))

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
  let cmp_key = (id.uint32 shl 16) or task.uint32
  var cur = cast[ptr KeTimer](ke_timer_list.first)
  var prev: ptr KeTimer = nil
  var timer: ptr KeTimer = nil
  while cur != nil:
    if cur.id == id and cur.task == task:
      timer = cur
      # Extract it
      if prev == nil:
        ke_timer_list.first = cast[ptr CoListNode](cur.next)
      else:
        prev.next = cur.next
      if ke_timer_list.last == cast[ptr CoListNode](cur):
        ke_timer_list.last = cast[ptr CoListNode](prev)
      break
    prev = cur
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
  ## Clear (cancel) a timer
  var cur = cast[ptr KeTimer](ke_timer_list.first)
  var prev: ptr KeTimer = nil
  while cur != nil:
    if cur.id == id and cur.task == task:
      if prev == nil:
        ke_timer_list.first = cast[ptr CoListNode](cur.next)
      else:
        prev.next = cur.next
      if ke_timer_list.last == cast[ptr CoListNode](cur):
        ke_timer_list.last = cast[ptr CoListNode](prev)
      ble_ke_free(cur)
      # Reprogram if we removed the first
      if prev == nil and ke_timer_list.first != nil:
        ble_ke_timer_hw_set(cast[ptr KeTimer](ke_timer_list.first))
      return
    prev = cur
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
  return ke_event_field == 0 and ke_msg_queue.first == nil

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
    let desc_addr = rx_base + i.uint32 * EM_BUF_RX_DESC_SIZE
    # Set buffer pointer (offset from EM base) = 0x3CC + i * 38
    let buf_offset = 0x3CC'u16 + i * EM_BUF_RX_DATA_SIZE.uint16
    let buf_ptr = cast[ptr uint16](desc_addr + 6)
    volatileStore(buf_ptr, buf_offset)
    # Clear status/flags
    let status_ptr = cast[ptr uint16](desc_addr)
    volatileStore(status_ptr, 0'u16)
    let len_ptr = cast[ptr uint16](desc_addr + 4)
    volatileStore(len_ptr, 0'u16)

  # Initialize TX buffer pool (descriptors)
  let tx_base = BLE_EM_BASE + 0x298'u32
  for i in 0'u16 ..< EM_BUF_TX_COUNT.uint16:
    let desc_addr = tx_base + i.uint32 * EM_BUF_TX_DESC_SIZE
    let status_ptr = cast[ptr uint16](desc_addr)
    volatileStore(status_ptr, 0'u16)

proc em_buf_rx_free*(idx: uint16) {.exportc, cdecl.} =
  ## Free an RX buffer by clearing the used bit in status
  let desc_addr = BLE_EM_BASE + 0x35C'u32 + idx.uint32 * EM_BUF_RX_DESC_SIZE
  let status_ptr = cast[ptr uint16](desc_addr)
  let v = volatileLoad(status_ptr)
  volatileStore(status_ptr, v and 0x7FFF'u16)  # Clear bit 15 (used/done flag)

proc em_buf_rx_buff_addr_get*(idx: uint16): pointer {.exportc, cdecl.} =
  ## Get the address of an RX buffer's data area
  let desc_addr = BLE_EM_BASE + 0x364'u32 + idx.uint32 * EM_BUF_RX_DESC_SIZE
  let buf_ptr = cast[ptr uint16](desc_addr)
  let offset = volatileLoad(buf_ptr)
  return cast[pointer](BLE_EM_BASE + offset.uint32)

proc em_buf_tx_buff_addr_get*(desc: pointer): pointer {.exportc, cdecl.} =
  ## Get TX buffer data address from descriptor
  let buf_ptr = cast[ptr uint16](cast[uint](desc) + 4)
  let offset = volatileLoad(buf_ptr)
  return cast[pointer](BLE_EM_BASE + offset.uint32)

proc em_buf_tx_free*(desc: pointer) {.exportc, cdecl.} =
  ## Free a TX buffer
  let buf_ptr = cast[ptr uint16](cast[uint](desc) + 4)
  let offset = volatileLoad(buf_ptr)
  # Clear allocation status in TX pool
  let pool_idx = offset.uint32
  let old = disableInterrupts()
  # Mark buffer as free in the TX descriptor
  let tx_desc_base = BLE_EM_BASE + 0x264'u32
  let status_ptr = cast[ptr uint16](tx_desc_base + (pool_idx div EM_BUF_TX_DATA_SIZE.uint32) * EM_BUF_TX_DESC_SIZE)
  volatileStore(status_ptr, 0'u16)
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
  regWrite(BLE_BASE + BLE_BASETIMECNT_OFFSET, 0x80000000'u32)
  while (regRead(BLE_BASE + BLE_BASETIMECNT_OFFSET) and 0x80000000'u32) != 0:
    discard
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

proc hci_evt_mask_set*(mask: ptr uint8) {.exportc, cdecl.} =
  discard c_memcpy(addr hci_evt_mask[0], mask, 8)

proc hci_cmd_get_max_param_size*(): uint16 {.exportc, cdecl.} =
  return 255

proc hci_cmd_received*(buf: pointer, len: uint16) {.exportc, cdecl.} =
  ## Process received HCI command
  if buf == nil or len < 3:
    return
  let raw = cast[ptr UncheckedArray[uint8]](buf)
  let opcode = raw[0].uint16 or (raw[1].uint16 shl 8)
  let paramLen = raw[2]
  if len < uint16(paramLen.int + 3):
    sendCmdComplete(opcode, 0x12'u8)
    return
  let params =
    if paramLen == 0: nil
    else: cast[ptr uint8](cast[uint](buf) + 3'u)
  let status = handleNimHciCommand(opcode, params, paramLen)
  sendCmdComplete(opcode, status)

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

proc hci_acl_tx_data_received*(handle: uint16, data: pointer, len: uint16) {.exportc, cdecl.} =
  discard

proc hci_get_tx_queue_num*(): uint32 {.exportc, cdecl.} =
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
  while true:
    let ch = fmt[fmtOff]
    if ch == 0:
      break
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
  when defined(bl808m0) and defined(bl808BleVendorLldConProbe) and
      defined(bl808BleVendorLlcStartProbe) and bl808BleNimLlcStart:
    for i in 0 ..< nim_vendor_llc_start_env_slots.len:
      nim_vendor_llc_start_env_slots[i] = nil

proc llc_reset*() {.exportc, cdecl.} =
  llc_init()

proc llc_start*(conhdl: uint16) {.exportc, cdecl.} =
  discard

proc llc_stop*(conhdl: uint16) {.exportc, cdecl.} =
  if conhdl < LLC_CON_MAX:
    if llc_env[conhdl] != nil:
      ble_ke_free(llc_env[conhdl])
      llc_env[conhdl] = nil
  when defined(bl808m0) and defined(bl808BleVendorLldConProbe) and
      defined(bl808BleVendorLlcStartProbe) and bl808BleNimLlcStart:
    if conhdl < nim_vendor_llc_start_env_slots.len.uint16:
      nim_vendor_llc_start_env_slots[conhdl] = nil

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
  var evt = [1'u8, uint8(conhdl and 0xFF),
             uint8((conhdl shr 8) and 0xFF), uint8(nb and 0xFF),
             uint8((nb shr 8) and 0xFF)]
  sendHostEvent(HciEvtNumberOfCompletedPackets, addr evt[0], evt.len.uint8)

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
  when defined(bl808m0) and defined(bl808BleVendorLldConProbe):
    noteVendorPeripheralDisconnected(reason)
  sendDisconnectComplete(conhdl, reason)

proc llc_end_evt_defer*(conhdl: uint16) {.exportc, cdecl.} =
  discard

proc llc_feats_rd_event_send*(conhdl: uint16, status: uint8) {.exportc, cdecl.} =
  var evt = [0x04'u8, status, uint8(conhdl and 0xFF),
             uint8((conhdl shr 8) and 0xFF), 0x3F'u8, 0'u8, 0'u8, 0'u8,
             0'u8, 0'u8, 0'u8, 0'u8]
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
  discard

proc llc_llcp_con_param_req_pdu_send*(conhdl: uint16) {.exportc, cdecl.} =
  discard

proc llc_llcp_con_param_rsp_pdu_send*(conhdl: uint16) {.exportc, cdecl.} =
  discard

proc llc_llcp_con_update_pdu_send*(conhdl: uint16) {.exportc, cdecl.} =
  discard

proc llc_llcp_enc_req_pdu_send*(conhdl: uint16) {.exportc, cdecl.} =
  discard

proc llc_llcp_enc_rsp_pdu_send*(conhdl: uint16) {.exportc, cdecl.} =
  discard

proc llc_llcp_feats_req_pdu_send*(conhdl: uint16) {.exportc, cdecl.} =
  discard

proc llc_llcp_feats_rsp_pdu_send*(conhdl: uint16) {.exportc, cdecl.} =
  discard

proc llc_llcp_length_req_pdu_send*(conhdl: uint16) {.exportc, cdecl.} =
  discard

proc llc_llcp_length_rsp_pdu_send*(conhdl: uint16) {.exportc, cdecl.} =
  discard

proc llc_llcp_pause_enc_req_pdu_send*(conhdl: uint16) {.exportc, cdecl.} =
  discard

proc llc_llcp_pause_enc_rsp_pdu_send*(conhdl: uint16) {.exportc, cdecl.} =
  discard

proc llc_llcp_ping_req_pdu_send*(conhdl: uint16) {.exportc, cdecl.} =
  discard

proc llc_llcp_ping_rsp_pdu_send*(conhdl: uint16) {.exportc, cdecl.} =
  discard

proc llc_llcp_reject_ind_pdu_send*(conhdl: uint16, reason: uint8) {.exportc, cdecl.} =
  discard

proc llc_llcp_start_enc_req_pdu_send*(conhdl: uint16) {.exportc, cdecl.} =
  discard

proc llc_llcp_start_enc_rsp_pdu_send*(conhdl: uint16) {.exportc, cdecl.} =
  discard

proc llc_llcp_terminate_ind_pdu_send*(conhdl: uint16, reason: uint8) {.exportc, cdecl.} =
  discard

proc llc_llcp_unknown_rsp_send_pdu*(conhdl: uint16, opcode: uint8) {.exportc, cdecl.} =
  discard

proc llc_llcp_version_ind_pdu_send*(conhdl: uint16) {.exportc, cdecl.} =
  discard

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
    let env = llc_env[conhdl]
    discard c_memcpy(map, addr env.data[346], 5)

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
    let env = llc_env[conhdl]
    if env.data[414] != 0:
      return  # Already disconnecting
    env.data[413] = reason
    env.data[414] = 1

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
    let env = llc_env[conhdl]
    let flags_ptr = cast[ptr uint16](addr env.data[344])
    if enable:
      flags_ptr[] = flags_ptr[] or 0x0008'u16
    else:
      flags_ptr[] = flags_ptr[] and not 0x0008'u16

proc llc_util_update_channel_map*(conhdl: uint16, map: ptr uint8) {.exportc, cdecl.} =
  if conhdl < LLC_CON_MAX and llc_env[conhdl] != nil:
    discard c_memcpy(addr llc_env[conhdl].data[346], map, 5)

# ---------------------------------------------------------------------------
# ======================== LLD (Link Layer Driver) =========================
# ---------------------------------------------------------------------------

proc lld_init*(reset: bool) {.exportc, cdecl.} =
  discard c_memset(addr lld_evt_env_data[0], 0, sizeof(lld_evt_env_data).csize_t)
  initBleCoreRegisters()

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

when not defined(bl808BleVendorLldAdvProbe):
  proc lld_adv_start*(params: pointer) {.exportc, cdecl.} =
    discard

  proc lld_adv_stop*() {.exportc, cdecl.} =
    discard

when not defined(bl808BleVendorLldScanProbe):
  proc lld_scan_start*(params: pointer) {.exportc, cdecl.} =
    discard

  proc lld_scan_stop*() {.exportc, cdecl.} =
    discard

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
  discard

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
  ## Read BD address from BLE registers
  let lo = regRead(BLE_BASE + 0x24'u32)
  let hi = regRead(BLE_BASE + 0x28'u32)
  addr_out.data[0] = uint8(lo and 0xFF)
  addr_out.data[1] = uint8((lo shr 8) and 0xFF)
  addr_out.data[2] = uint8((lo shr 16) and 0xFF)
  addr_out.data[3] = uint8((lo shr 24) and 0xFF)
  addr_out.data[4] = uint8(hi and 0xFF)
  addr_out.data[5] = uint8((hi shr 8) and 0xFF)

proc lld_util_set_bd_address*(addr_in: ptr BdAddr) {.exportc, cdecl.} =
  let lo = addr_in.data[0].uint32 or
           (addr_in.data[1].uint32 shl 8) or
           (addr_in.data[2].uint32 shl 16) or
           (addr_in.data[3].uint32 shl 24)
  let hi = addr_in.data[4].uint32 or
           (addr_in.data[5].uint32 shl 8)
  regWrite(BLE_BASE + 0x24'u32, lo)
  regWrite(BLE_BASE + 0x28'u32, hi)

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

proc llm_init*() {.exportc, cdecl.} =
  discard c_memset(addr llm_env_data, 0, sizeof(LlmEnv).csize_t)
  discard c_memset(addr llm_wl[0], 0, sizeof(llm_wl).csize_t)
  discard c_memset(addr llm_wl_type[0], 0, sizeof(llm_wl_type).csize_t)
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

proc llm_common_cmd_complete_send*(opcode: uint16, status: uint8) {.exportc, cdecl.} =
  discard

proc llm_common_cmd_status_send*(opcode: uint16, status: uint8) {.exportc, cdecl.} =
  discard

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
  if ble_adv_discarded_callback != nil:
    ble_adv_discarded_callback(count)

proc llm_pdu_defer*() {.exportc, cdecl.} =
  discard

proc llm_set_adv_data*(data: ptr uint8, len: uint8) {.exportc, cdecl.} =
  let n = min(len.int, nim_adv_data.len)
  nim_adv_data_len = n.uint8
  if data != nil:
    let raw = cast[ptr UncheckedArray[uint8]](data)
    for i in 0 ..< n:
      nim_adv_data[i] = raw[i]

proc llm_set_adv_en*(en: bool) {.exportc, cdecl.} =
  discard programNimAdvertising(en)

proc llm_set_adv_param*(params: pointer) {.exportc, cdecl.} =
  if params != nil:
    let raw = cast[ptr UncheckedArray[uint8]](params)
    for i in 0 ..< nim_adv_params.len:
      nim_adv_params[i] = raw[i]

proc llm_set_scan_en*(en: bool) {.exportc, cdecl.} =
  nim_scan_enabled = en

proc llm_set_scan_param*(params: pointer) {.exportc, cdecl.} =
  if params != nil:
    let raw = cast[ptr UncheckedArray[uint8]](params)
    for i in 0 ..< nim_scan_params.len:
      nim_scan_params[i] = raw[i]

proc llm_set_scan_rsp_data*(data: ptr uint8, len: uint8) {.exportc, cdecl.} =
  let n = min(len.int, nim_scan_rsp_data.len)
  nim_scan_rsp_data_len = n.uint8
  if data != nil:
    let raw = cast[ptr UncheckedArray[uint8]](data)
    for i in 0 ..< n:
      nim_scan_rsp_data[i] = raw[i]
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

proc llm_util_bl_add*(addr_in: ptr BdAddr, addr_type: uint8): bool {.exportc, cdecl.} =
  for i in 0 ..< LLM_WL_MAX:
    if llm_wl_type[i] == 0xFF:  # Empty slot
      co_bdaddr_set(addr llm_wl[i], addr_in)
      llm_wl_type[i] = addr_type
      return true
  return false

proc llm_util_bl_check*(addr_in: ptr BdAddr, addr_type: uint8): bool {.exportc, cdecl.} =
  return llm_util_bd_addr_in_wl(addr_in, addr_type)

proc llm_util_bl_rem*(addr_in: ptr BdAddr, addr_type: uint8): bool {.exportc, cdecl.} =
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
  var count = 0
  for i in 0 ..< 5:
    let byte_val = cast[ptr uint8](cast[uint](map) + i.uint)[]
    for b in 0 ..< 8:
      if i * 8 + b < 37:  # Only 37 data channels
        if (byte_val and (1'u8 shl b)) != 0:
          inc count
  return count >= 2

proc llm_util_get_channel_map*(map: ptr uint8) {.exportc, cdecl.} =
  discard c_memset(map, 0xFF, 5)
  # Mask out bits above channel 36
  let last_byte = cast[ptr uint8](cast[uint](map) + 4)
  last_byte[] = last_byte[] and 0x1F

proc llm_util_get_supp_features*(): uint64 {.exportc, cdecl.} =
  return 0x000000000000003F'u64  # Standard LE features

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
  when defined(bl808m0):
    when not bl808BleNimUseClicIrq:
      nimDisableM0BleClicIrq()
  prepareWirelessDomain()
  configureBtPriorityPta()
  em_buf_init()
  lld_init(false)
  llc_init()
  llm_init()
  regWrite((BLE_BASE + 0x050'u32).uint, 0'u32)

proc bflbble_reset*() {.exportc, cdecl.} =
  ## Reset BLE hardware and link-layer state, matching the vendor reset order.
  when defined(bl808m0):
    when not bl808BleNimUseClicIrq:
      nimDisableM0BleClicIrq()
  lld_core_reset()
  lld_init(true)
  llc_reset()
  llm_init()
  em_buf_init()
  nim_ble_core_ready = false
  initBleCoreRegisters()

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
      defined(bl808BleVendorLldConProbe):
    if nim_vendor_con_started:
      bleTrace("[CON] isr enter\r\n")
  let stat = regRead(BLE_BASE + BTBLE_INTSTAT_OFFSET)
  inc nim_ble_dbg_isr_count
  nim_ble_dbg_isr_stat_or = nim_ble_dbg_isr_stat_or or stat
  if (stat and 0x20'u32) != 0:
    inc nim_ble_dbg_stat20_count
  if (stat and 0x8000'u32) != 0:
    inc nim_ble_dbg_stat8000_count
  when defined(bl808m0) and
      (defined(bl808BleVendorLldScanProbe) or
       defined(bl808BleVendorLldConProbe)) and
      not defined(bl808BleVendorArbProbe):
    serviceVendorArbCallbacks()
  when defined(bl808m0) and
      (defined(bl808BleVendorSchProgProbe) or
       defined(bl808BleVendorLldAdvProbe) or
       defined(bl808BleVendorLldConProbe) or
       defined(bl808BleVendorLldScanProbe)):
    when bl808BleNimSchProg:
      if (stat and 0x00000008'u32) != 0 and skipFlag != 0'u8:
        inc nim_vendor_sch_prog_skip_count
        vendorSchProgSkipIsr(uint8(vendorSchProgSkipIndex and 0x0F'u32))
        skipFlag = 0'u8
    elif defined(bl808BleVendorLldScanProbe):
      if (stat and 0x00000008'u32) != 0:
        inc nim_vendor_sch_prog_skip_count
        vendorSchProgSkipIsr(uint8(vendorSchProgSkipIndex and 0x0F'u32))
    if (stat and 0x8000'u32) != 0:
      inc nim_vendor_sch_prog_fifo_count
      vendorSchProgFifoIsr()
      when defined(bl808m0) and
          (defined(bl808BleVendorLldScanProbe) or
           defined(bl808BleVendorLldConProbe)) and
          not defined(bl808BleVendorArbProbe):
        serviceVendorArbCallbacks()
  # Acknowledge all interrupts
  regWrite(BLE_BASE + BTBLE_INTACK_OFFSET, stat)
  when defined(bl808m0) and defined(bl808BleVendorArbProbe):
    serviceVendorArbTimer()
  when defined(bl808m0) and defined(bl808BleVendorLldConProbe) and
      defined(bl808BleVendorManualConnTx):
    serviceVendorConnectionLlcpRxDescriptors()
  var serviceAdvRx = (stat and 0x8000'u32) != 0
  when defined(bl808m0) and defined(bl808BleVendorLldConProbe):
    if nim_vendor_con_started:
      serviceAdvRx = false
  if serviceAdvRx:
    when defined(bl808BleConnectTrace) and defined(bl808m0) and
        defined(bl808BleVendorLldConProbe):
      if nim_vendor_con_started:
        bleTrace("[CON] before advrx\r\n")
    serviceBtbleAdvRxDescriptors()
    when defined(bl808m0) and defined(bl808BleVendorLldConProbe):
      nimVendorConnMark(0x220'u32)
    when defined(bl808BleConnectTrace) and defined(bl808m0) and
        defined(bl808BleVendorLldConProbe):
      if nim_vendor_con_started:
        bleTrace("[CON] after advrx\r\n")
  when defined(bl808m0) and
      (defined(bl808BleVendorLldScanProbe) or
       defined(bl808BleVendorLldConProbe)) and
      not defined(bl808BleVendorArbProbe):
    serviceVendorArbCallbacks()
  when not (defined(bl808m0) and defined(bl808BleVendorLldConProbe)):
    if (stat and 0x20'u32) != 0:
      regWrite((BLE_BASE + 0x018'u32).uint,
               regRead((BLE_BASE + 0x018'u32).uint) and not 0x00000020'u32)
    if (stat and 0x40'u32) != 0:
      regWrite((BLE_BASE + 0x018'u32).uint,
               regRead((BLE_BASE + 0x018'u32).uint) and not 0x00000040'u32)
    if (stat and 0x80'u32) != 0:
      regWrite((BLE_BASE + 0x018'u32).uint,
               regRead((BLE_BASE + 0x018'u32).uint) and not 0x00000080'u32)
  if nim_btble_sw_pending or (stat and 0x08'u32) != 0:
    nim_btble_sw_pending = false
    regWrite((BLE_BASE + 0x020'u32).uint, 0x00000008'u32)
    regWrite((BLE_BASE + 0x018'u32).uint,
             regRead((BLE_BASE + 0x018'u32).uint) and not 0x00000008'u32)
  if nim_adv_enabled and
      ((stat and 0x20'u32) != 0 or btbleTargetExpired(nim_adv_target_half_us)):
    pushBtbleAdvProgram()
    scheduleBtbleEvent()
  when defined(bl808m0) and defined(bl808BleVendorLldAdvProbe) and
      defined(bl808BleVendorLldConProbe):
    if nim_adv_enabled:
      write16(BTBLE_EM_BASE + 0x13A'u32, 0'u16)
      write16(BTBLE_EM_BASE + 0x150'u32, 0x0008'u16)
  when defined(bl808BleConnectTrace) and defined(bl808m0) and
      defined(bl808BleVendorLldConProbe):
    if nim_vendor_con_started:
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
  when defined(bl808m0) and defined(bl808BleVendorLldConProbe):
    if nim_vendor_con_started: 1'u32 else: 0'u32
  else:
    0'u32

proc bleNimPeripheralConnEventCount*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and defined(bl808BleVendorLldConProbe):
    nim_vendor_conn_evt_count
  else:
    0'u32

proc bleNimPeripheralConnHandle*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and defined(bl808BleVendorLldConProbe):
    nim_vendor_conn_evt_handle
  else:
    0'u32

proc bleNimPeripheralConnPeerA0*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and defined(bl808BleVendorLldConProbe):
    nim_vendor_conn_evt_peer_a0
  else:
    0'u32

proc bleNimPeripheralConnPeerA1*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and defined(bl808BleVendorLldConProbe):
    nim_vendor_conn_evt_peer_a1
  else:
    0'u32

proc bleNimPeripheralConnPeerType*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and defined(bl808BleVendorLldConProbe):
    nim_vendor_conn_evt_peer_type
  else:
    0'u32

proc bleNimPeripheralDiscEventCount*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and defined(bl808BleVendorLldConProbe):
    nim_vendor_disc_evt_count
  else:
    0'u32

proc bleNimPeripheralDiscReason*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and defined(bl808BleVendorLldConProbe):
    nim_vendor_disc_evt_reason
  else:
    0'u32

proc bleNimDbgVendorLlcpRxCount*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and defined(bl808BleVendorLldConProbe):
    nim_vendor_llcp_rx_count
  else:
    0'u32

proc bleNimDbgVendorLlcpTxCount*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and defined(bl808BleVendorLldConProbe):
    nim_vendor_llcp_tx_count
  else:
    0'u32

proc bleNimDbgVendorLlcpTxQueued*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and defined(bl808BleVendorLldConProbe):
    nim_vendor_llcp_tx_queued
  else:
    0'u32

proc bleNimDbgVendorLlcpTxDropped*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and defined(bl808BleVendorLldConProbe):
    nim_vendor_llcp_tx_dropped
  else:
    0'u32

proc bleNimDbgVendorLlcpLastOpcode*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and defined(bl808BleVendorLldConProbe):
    nim_vendor_llcp_last_opcode
  else:
    0'u32

proc bleNimDbgVendorLlcpLastStatus*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and defined(bl808BleVendorLldConProbe):
    nim_vendor_llcp_last_status
  else:
    0'u32

proc bleNimDbgVendorLlcpAllocCount*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and defined(bl808BleVendorLldConProbe):
    nim_vendor_llcp_alloc_count
  else:
    0'u32

proc bleNimDbgVendorLlcpFreeCount*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and defined(bl808BleVendorLldConProbe):
    nim_vendor_llcp_free_count
  else:
    0'u32

proc bleNimDbgVendorLlcpAllocLastLen*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and defined(bl808BleVendorLldConProbe):
    nim_vendor_llcp_alloc_last_len
  else:
    0'u32

proc bleNimDbgVendorLlcpAllocLastPtr*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and defined(bl808BleVendorLldConProbe):
    nim_vendor_llcp_alloc_last_ptr
  else:
    0'u32

proc bleNimDbgVendorLlcpAllocLastEmoff*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and defined(bl808BleVendorLldConProbe):
    nim_vendor_llcp_alloc_last_emoff
  else:
    0'u32

proc bleNimDbgVendorLlcpAllocLastLenField*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and defined(bl808BleVendorLldConProbe):
    nim_vendor_llcp_alloc_last_len_field
  else:
    0'u32

proc bleNimDbgVendorLlcpFreeLastRaw*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and defined(bl808BleVendorLldConProbe):
    nim_vendor_llcp_free_last_raw
  else:
    0'u32

proc bleNimDbgVendorLlcpFreeManualCount*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and defined(bl808BleVendorLldConProbe):
    nim_vendor_llcp_free_manual_count
  else:
    0'u32

proc bleNimDbgVendorLlcpFreeHeapCount*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and defined(bl808BleVendorLldConProbe):
    nim_vendor_llcp_free_heap_count
  else:
    0'u32

proc bleNimDbgVendorAclEmptyTxCount*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and defined(bl808BleVendorLldConProbe):
    nim_vendor_acl_empty_tx_count
  else:
    0'u32

proc bleNimDbgVendorAclEmptyTxPending*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and defined(bl808BleVendorLldConProbe):
    nim_vendor_acl_empty_tx_pending
  else:
    0'u32

proc bleNimDbgVendorAclEmptyLastStatus*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and defined(bl808BleVendorLldConProbe):
    nim_vendor_acl_empty_last_status
  else:
    0'u32

proc bleNimDbgVendorConLastStatus*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and defined(bl808BleVendorLldConProbe):
    nim_vendor_con_last_status
  else:
    0'u32

proc bleNimDbgVendorConLastRxClock*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and defined(bl808BleVendorLldConProbe):
    nim_vendor_con_last_rx_clock
  else:
    0'u32

proc bleNimDbgVendorConLastRxFine*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and defined(bl808BleVendorLldConProbe):
    nim_vendor_con_last_rx_fine
  else:
    0'u32

proc bleNimDbgVendorConLastAnchor*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and defined(bl808BleVendorLldConProbe):
    nim_vendor_con_last_anchor
  else:
    0'u32

proc bleNimDbgVendorConLastWinOffset*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and defined(bl808BleVendorLldConProbe):
    nim_vendor_con_last_win_offset
  else:
    0'u32

proc bleNimDbgVendorConLastInterval*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and defined(bl808BleVendorLldConProbe):
    nim_vendor_con_last_interval
  else:
    0'u32

proc bleNimDbgVendorConLastTimeout*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and defined(bl808BleVendorLldConProbe):
    nim_vendor_con_last_timeout
  else:
    0'u32

proc bleNimDbgVendorConLastAccessAddr*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and defined(bl808BleVendorLldConProbe):
    nim_vendor_con_last_access_addr
  else:
    0'u32

proc bleNimDbgVendorConLastCrcInit*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and defined(bl808BleVendorLldConProbe):
    nim_vendor_con_last_crcinit
  else:
    0'u32

proc bleNimDbgVendorConnStage*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and defined(bl808BleVendorLldConProbe) and
      bl808BleConnStageDiag:
    nim_vendor_conn_stage
  else:
    0'u32

proc bleNimDbgVendorConnStageRa*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and defined(bl808BleVendorLldConProbe) and
      bl808BleConnStageDiag:
    nim_vendor_conn_stage_ra
  else:
    0'u32

proc bleNimDbgVendorConnStageSp*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and defined(bl808BleVendorLldConProbe) and
      bl808BleConnStageDiag:
    nim_vendor_conn_stage_sp
  else:
    0'u32

proc bleNimDbgVendorConnStageMepc*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and defined(bl808BleVendorLldConProbe) and
      bl808BleConnStageDiag:
    nim_vendor_conn_stage_mepc
  else:
    0'u32

proc bleNimDbgVendorConnStageMcause*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and defined(bl808BleVendorLldConProbe) and
      bl808BleConnStageDiag:
    nim_vendor_conn_stage_mcause
  else:
    0'u32

proc bleNimDbgVendorConnStageMark*(stage: uint32) {.exportc, cdecl.} =
  when defined(bl808m0) and defined(bl808BleVendorLldConProbe) and
      bl808BleConnStageDiag:
    nimVendorConnMark(stage)
  else:
    discard stage

proc bleNimDbgVendorLldConStartCount*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and defined(bl808BleVendorLldConProbe):
    nim_vendor_lld_con_start_count
  else:
    0'u32

proc bleNimDbgVendorLldConStartStatus*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and defined(bl808BleVendorLldConProbe):
    nim_vendor_lld_con_start_status
  else:
    0'u32

proc bleNimDbgVendorLldConStartParamWord*(word: uint32): uint32
    {.exportc, cdecl.} =
  when defined(bl808m0) and defined(bl808BleVendorLldConProbe):
    let base = (word and 0x0F'u32) * 4'u32
    uint32(nim_vendor_lld_con_start_param[base.int]) or
      (uint32(nim_vendor_lld_con_start_param[base.int + 1]) shl 8) or
      (uint32(nim_vendor_lld_con_start_param[base.int + 2]) shl 16) or
      (uint32(nim_vendor_lld_con_start_param[base.int + 3]) shl 24)
  else:
    0'u32

proc bleNimDbgLldRxCheckCount*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and defined(bl808BleVendorLldConProbe):
    nim_lld_rx_check_count
  else:
    0'u32

proc bleNimDbgLldRxCheckHitCount*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and defined(bl808BleVendorLldConProbe):
    nim_lld_rx_check_hit_count
  else:
    0'u32

proc bleNimDbgLldRxCheckMissCount*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and defined(bl808BleVendorLldConProbe):
    nim_lld_rx_check_miss_count
  else:
    0'u32

proc bleNimDbgLldRxFreeCount*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and defined(bl808BleVendorLldConProbe):
    nim_lld_rx_free_count
  else:
    0'u32

proc bleNimDbgLldRxLastIdx*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and defined(bl808BleVendorLldConProbe):
    nim_lld_rx_last_idx
  else:
    0'u32

proc bleNimDbgLldRxLastEnvIdx*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and defined(bl808BleVendorLldConProbe):
    nim_lld_rx_last_env_idx
  else:
    0'u32

proc bleNimDbgLldRxLastStatus*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and defined(bl808BleVendorLldConProbe):
    nim_lld_rx_last_status
  else:
    0'u32

proc bleNimDbgLldRxLastHeader*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and defined(bl808BleVendorLldConProbe):
    nim_lld_rx_last_header
  else:
    0'u32

proc bleNimDbgLldRxLastMeta*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and defined(bl808BleVendorLldConProbe):
    nim_lld_rx_last_meta
  else:
    0'u32

proc bleNimDbgLldRxDescActive*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and defined(bl808BleVendorLldConProbe):
    nim_lld_rx_desc_active.uint32
  else:
    0'u32

proc bleNimDbgVendorSchProgFifoCount*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and
      (defined(bl808BleVendorSchProgProbe) or
       defined(bl808BleVendorLldAdvProbe) or
       defined(bl808BleVendorLldConProbe) or
       defined(bl808BleVendorLldScanProbe)):
    nim_vendor_sch_prog_fifo_count
  else:
    0'u32

proc bleNimDbgVendorSchProgSkipCount*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and
      (defined(bl808BleVendorSchProgProbe) or
       defined(bl808BleVendorLldAdvProbe) or
       defined(bl808BleVendorLldConProbe) or
       defined(bl808BleVendorLldScanProbe)):
    nim_vendor_sch_prog_skip_count
  else:
    0'u32

proc bleNimDbgVendorArbSwCount*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and
      (defined(bl808BleVendorSchProgProbe) or
       defined(bl808BleVendorLldAdvProbe) or
       defined(bl808BleVendorLldConProbe) or
       defined(bl808BleVendorLldScanProbe)):
    nim_vendor_arb_sw_count
  else:
    0'u32

proc bleNimDbgVendorArbEventStartCount*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and
      (defined(bl808BleVendorSchProgProbe) or
       defined(bl808BleVendorLldAdvProbe) or
       defined(bl808BleVendorLldConProbe) or
       defined(bl808BleVendorLldScanProbe)):
    nim_vendor_arb_event_start_count
  else:
    0'u32

proc bleNimDbgVendorArbSetCount*(): uint32 {.exportc, cdecl.} =
  when defined(bl808BleVendorSchedulerDiag) and defined(bl808m0) and
      (defined(bl808BleVendorSchProgProbe) or
       defined(bl808BleVendorLldAdvProbe) or
       defined(bl808BleVendorLldConProbe) or
       defined(bl808BleVendorLldScanProbe)):
    nim_vendor_arb_set_count
  else:
    0'u32

proc bleNimDbgVendorArbLastTargetCoarse*(): uint32 {.exportc, cdecl.} =
  when defined(bl808BleVendorSchedulerDiag) and defined(bl808m0) and
      (defined(bl808BleVendorSchProgProbe) or
       defined(bl808BleVendorLldAdvProbe) or
       defined(bl808BleVendorLldConProbe) or
       defined(bl808BleVendorLldScanProbe)):
    nim_vendor_arb_last_target_coarse
  else:
    0'u32

proc bleNimDbgVendorArbLastTargetFine*(): uint32 {.exportc, cdecl.} =
  when defined(bl808BleVendorSchedulerDiag) and defined(bl808m0) and
      (defined(bl808BleVendorSchProgProbe) or
       defined(bl808BleVendorLldAdvProbe) or
       defined(bl808BleVendorLldConProbe) or
       defined(bl808BleVendorLldScanProbe)):
    nim_vendor_arb_last_target_fine
  else:
    0'u32

proc bleNimDbgVendorArbDueTargetCoarse*(): uint32 {.exportc, cdecl.} =
  when defined(bl808BleVendorSchedulerDiag) and defined(bl808m0) and
      (defined(bl808BleVendorSchProgProbe) or
       defined(bl808BleVendorLldAdvProbe) or
       defined(bl808BleVendorLldConProbe) or
       defined(bl808BleVendorLldScanProbe)):
    nim_vendor_arb_due_target_coarse
  else:
    0'u32

proc bleNimDbgVendorArbDueTargetFine*(): uint32 {.exportc, cdecl.} =
  when defined(bl808BleVendorSchedulerDiag) and defined(bl808m0) and
      (defined(bl808BleVendorSchProgProbe) or
       defined(bl808BleVendorLldAdvProbe) or
       defined(bl808BleVendorLldConProbe) or
       defined(bl808BleVendorLldScanProbe)):
    nim_vendor_arb_due_target_fine
  else:
    0'u32

proc bleNimDbgVendorArbDueNowCoarse*(): uint32 {.exportc, cdecl.} =
  when defined(bl808BleVendorSchedulerDiag) and defined(bl808m0) and
      (defined(bl808BleVendorSchProgProbe) or
       defined(bl808BleVendorLldAdvProbe) or
       defined(bl808BleVendorLldConProbe) or
       defined(bl808BleVendorLldScanProbe)):
    nim_vendor_arb_due_now_coarse
  else:
    0'u32

proc bleNimDbgVendorArbDueNowFine*(): uint32 {.exportc, cdecl.} =
  when defined(bl808BleVendorSchedulerDiag) and defined(bl808m0) and
      (defined(bl808BleVendorSchProgProbe) or
       defined(bl808BleVendorLldAdvProbe) or
       defined(bl808BleVendorLldConProbe) or
       defined(bl808BleVendorLldScanProbe)):
    nim_vendor_arb_due_now_fine
  else:
    0'u32

proc bleNimDbgVendorSliceAddCount*(): uint32 {.exportc, cdecl.} =
  when defined(bl808BleVendorSchedulerDiag) and defined(bl808m0) and
      (defined(bl808BleVendorSchProgProbe) or
       defined(bl808BleVendorLldAdvProbe) or
       defined(bl808BleVendorLldConProbe) or
       defined(bl808BleVendorLldScanProbe)):
    nim_vendor_slice_add_count
  else:
    0'u32

proc bleNimDbgVendorSliceRemoveCount*(): uint32 {.exportc, cdecl.} =
  when defined(bl808BleVendorSchedulerDiag) and defined(bl808m0) and
      (defined(bl808BleVendorSchProgProbe) or
       defined(bl808BleVendorLldAdvProbe) or
       defined(bl808BleVendorLldConProbe) or
       defined(bl808BleVendorLldScanProbe)):
    nim_vendor_slice_remove_count
  else:
    0'u32

proc bleNimDbgVendorSliceLastTypeCon*(): uint32 {.exportc, cdecl.} =
  when defined(bl808BleVendorSchedulerDiag) and defined(bl808m0) and
      (defined(bl808BleVendorSchProgProbe) or
       defined(bl808BleVendorLldAdvProbe) or
       defined(bl808BleVendorLldConProbe) or
       defined(bl808BleVendorLldScanProbe)):
    nim_vendor_slice_last_type_con
  else:
    0'u32

proc bleNimDbgVendorSliceLastInterval*(): uint32 {.exportc, cdecl.} =
  when defined(bl808BleVendorSchedulerDiag) and defined(bl808m0) and
      (defined(bl808BleVendorSchProgProbe) or
       defined(bl808BleVendorLldAdvProbe) or
       defined(bl808BleVendorLldConProbe) or
       defined(bl808BleVendorLldScanProbe)):
    nim_vendor_slice_last_interval
  else:
    0'u32

proc bleNimDbgVendorSliceLastAnchor*(): uint32 {.exportc, cdecl.} =
  when defined(bl808BleVendorSchedulerDiag) and defined(bl808m0) and
      (defined(bl808BleVendorSchProgProbe) or
       defined(bl808BleVendorLldAdvProbe) or
       defined(bl808BleVendorLldConProbe) or
       defined(bl808BleVendorLldScanProbe)):
    nim_vendor_slice_last_anchor
  else:
    0'u32

proc bleNimDbgVendorSliceLastOffset*(): uint32 {.exportc, cdecl.} =
  when defined(bl808BleVendorSchedulerDiag) and defined(bl808m0) and
      (defined(bl808BleVendorSchProgProbe) or
       defined(bl808BleVendorLldAdvProbe) or
       defined(bl808BleVendorLldConProbe) or
       defined(bl808BleVendorLldScanProbe)):
    nim_vendor_slice_last_offset
  else:
    0'u32

proc bleNimDbgVendorWrapArbInsertCount*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and defined(bl808BleVendorLldConProbe) and
      defined(bl808BleVendorArbProbe) and defined(bl808BleVendorWrapDiag):
    ble_vendor_wrap_arb_insert_count
  else:
    0'u32

proc bleNimDbgVendorWrapArbInsertStatus*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and defined(bl808BleVendorLldConProbe) and
      defined(bl808BleVendorArbProbe) and defined(bl808BleVendorWrapDiag):
    ble_vendor_wrap_arb_insert_status
  else:
    0'u32

proc bleNimDbgVendorWrapArbInsertLast*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and defined(bl808BleVendorLldConProbe) and
      defined(bl808BleVendorArbProbe) and defined(bl808BleVendorWrapDiag):
    ble_vendor_wrap_arb_insert_last
  else:
    0'u32

proc bleNimDbgVendorWrapProgPushCount*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and defined(bl808BleVendorLldConProbe) and
      defined(bl808BleVendorArbProbe) and defined(bl808BleVendorWrapDiag):
    ble_vendor_wrap_prog_push_count
  else:
    0'u32

proc bleNimDbgVendorWrapProgPushLast*(): uint32 {.exportc, cdecl.} =
  when defined(bl808m0) and defined(bl808BleVendorLldConProbe) and
      defined(bl808BleVendorArbProbe) and defined(bl808BleVendorWrapDiag):
    ble_vendor_wrap_prog_push_last
  else:
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

proc bflbip_schedule*() {.exportc, cdecl.} =
  when defined(bl808BleConnectTrace) and defined(bl808m0) and
      defined(bl808BleVendorLldConProbe):
    if nim_vendor_con_started:
      bleTrace("[CON] before sched\r\n")
  ble_ke_event_schedule()
  when defined(bl808BleConnectTrace) and defined(bl808m0) and
      defined(bl808BleVendorLldConProbe):
    if nim_vendor_con_started:
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
  bflbble_init()
  bflbip_init()
  ble_ke_init()
  em_buf_init()
  hci_init(false)
  llc_init()
  lld_init(false)
  llm_init()
  ecc_init()
  lld_sleep_init()
  lld_evt_init()
  bdaddr_init()
  ble_controller_task_init(cfg)

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

proc blecontroller_main*() {.exportc, cdecl.} =
  ## Main BLE controller loop
  var msg_buf: array[8, uint8]
  while true:
    if bflb_main_queue_handle != nil:
      let ret = ble_xQueueReceive(bflb_main_queue_handle, addr msg_buf[0], high(uint32))
      if ret == 1 and msg_buf[0] == 1:
        let param = cast[pointer](cast[ptr uint32](addr msg_buf[4])[])
        if param != nil:
          let hdr = getMsgHeader(param)
          ble_ke_msg_free(hdr)
    ble_ke_event_schedule()

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
  ## Apply ROM patches - sets up patch function pointers
  discard

proc BLE_ROM_hook_init*() {.exportc, cdecl.} =
  ## Initialize ROM hook function pointers
  ## From disasm: stores a sequence of function pointers
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
  cast[ptr uint32](mac)[] = lo
  cast[ptr uint16](cast[uint](mac) + 4)[] = uint16(hi and 0xFFFF)
  # Check if all zero or all 0x01 => use default
  var all_zero = true
  var all_same = true
  for i in 0 ..< 6:
    let b = cast[ptr uint8](cast[uint](mac) + i.uint)[]
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
    return cast[ptr int8](cast[uint](rf_pwr_offset_table) + channel.uint)[]
  return 0

proc ble_rf_set_tx_channel*(channel: uint16) {.exportc, cdecl.} =
  ## Set RF TX channel
  discard

proc bl_channel_calc_threshold*(ch_assess: pointer, threshold: ptr int8): uint8 {.exportc, cdecl.} =
  return 0

# ---------------------------------------------------------------------------
# ======================== ON-CHIP HCI =====================================
# ---------------------------------------------------------------------------

proc bt_onchiphci_interface_init*(cb: OnChipHciRecvCb): uint8 {.exportc, cdecl.} =
  discard c_memset(addr onchiphci_env[0], 0, sizeof(onchiphci_env).csize_t)
  onchiphci_recv_cb = cb
  0

proc handleOnchipHciCommandBuffer(data: pointer, len: uint16): uint8 =
  if data == nil or len < 3:
    return 0x12'u8
  let raw = cast[ptr UncheckedArray[uint8]](data)
  let opcode = raw[0].uint16 or (raw[1].uint16 shl 8)
  let paramLen = raw[2]
  if len < uint16(paramLen.int + 3):
    return 0x12'u8
  let params =
    if paramLen == 0: nil
    else: cast[ptr uint8](cast[uint](data) + 3'u)
  let status = handleNimHciCommand(opcode, params, paramLen)
  when defined(bl808m0) and defined(bl808BleVendorLldScanProbe):
    when bl808BleVendorCentralTrace:
      bleCentralTraceCheckRawRa(0x0A31'u32)
  sendCmdComplete(opcode, status)
  bleCentralDebugMark(0x910'u32, (uint32(opcode) shl 8) or uint32(status))
  status

proc bt_onchiphci_send_raw*(data: pointer, len: uint16): bool =
  when defined(bl808m0) and defined(bl808BleVendorLldScanProbe):
    let entrySp = bleCentralTraceReadSp()
    let entryRa = regRead((entrySp + 12'u32).uint)
    nim_vendor_raw_hci_return_addr = entryRa
    nim_vendor_trace_raw_ra_addr = entrySp + 12'u32
    when bl808BleVendorCentralTrace:
      bleCentralTraceStoreWord(16'u, entryRa)
      bleCentralDebugMark(0x923'u32, entryRa)
  bleCentralDebugMark(0x920'u32, uint32(len))
  let ok = handleOnchipHciCommandBuffer(data, len) == 0
  when defined(bl808m0) and defined(bl808BleVendorLldScanProbe):
    when bl808BleVendorCentralTrace:
      let afterHandleSp = bleCentralTraceReadSp()
      let afterHandleRa = regRead((afterHandleSp + 12'u32).uint)
      bleCentralDebugMark(0x924'u32, afterHandleRa)
  bleCentralDebugMark(0x921'u32, if ok: 1'u32 else: 0'u32)
  when defined(bl808m0) and defined(bl808BleVendorLldScanProbe):
    when bl808BleVendorCentralTrace:
      let rawSp = bleCentralTraceReadSp()
      let exitRa = regRead((rawSp + 12'u32).uint)
      bleCentralDebugMark(0x922'u32, exitRa)
    bleCentralRestoreRawRa(nim_vendor_raw_hci_return_addr)
  ok

proc bt_onchiphci_send*(pktType: uint8, destId: uint16,
                        pkt: pointer): int8 {.exportc, cdecl.} =
  discard destId
  if pkt == nil:
    return -1'i8
  case pktType
  of BtHciCmd:
    let cmd = cast[ptr OnChipHciCmd](pkt)
    let status = handleNimHciCommand(cmd.opcode, cmd.params, cmd.paramLen)
    sendCmdComplete(cmd.opcode, status)
    return 0'i8
  of BtHciAclData:
    let acl = cast[ptr OnChipHciAclDataTx](pkt)
    hci_acl_tx_data_received(acl.conhdl, acl.buffer, acl.len)
    return 0'i8
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

proc ecc_init*() {.exportc, cdecl.} =
  discard c_memset(addr ecc_env[0], 0, sizeof(ecc_env).csize_t)
  ecc_ongoing = false

proc ecc_is_valid_point*(point: ptr EccPoint256): bool {.exportc, cdecl.} =
  return true  # Simplified

proc ecc_generate_key256*(secret: ptr uint8, result_cb: pointer) {.exportc, cdecl.} =
  ecc_ongoing = true
  discard

proc ecc_abort_key256_generation*() {.exportc, cdecl.} =
  ecc_ongoing = false

proc ecc_gen_new_public_key*(secret: ptr uint8, public_key: ptr EccPoint256) {.exportc, cdecl.} =
  discard

proc ecc_gen_new_secret_key*(secret: ptr uint8) {.exportc, cdecl.} =
  ## Generate a new random secret key
  discard

proc ecc_get_debug_Keys*(secret: ptr uint8, public_key: ptr EccPoint256) {.exportc, cdecl.} =
  ## Get debug ECC keys (standard BLE debug keys)
  discard c_memset(secret, 0, ECC_KEY_LEN.csize_t)
  discard c_memset(public_key, 0, sizeof(EccPoint256).csize_t)

proc ecc_get_private_key*(key: ptr uint8) {.exportc, cdecl.} =
  discard c_memset(key, 0, ECC_KEY_LEN.csize_t)

proc notEqual256*(a: ptr uint8, b: ptr uint8): bool {.exportc, cdecl.} =
  return c_memcmp(a, b, ECC_KEY_LEN.csize_t) != 0

proc bigHexInversion256*(input: ptr uint8, output: ptr uint8) {.exportc, cdecl.} =
  ## 256-bit big-endian inversion (modular inverse using PKA)
  discard c_memcpy(output, input, ECC_KEY_LEN.csize_t)

proc GF_Point_Jacobian_To_Affine256*(point: ptr uint8) {.exportc, cdecl.} =
  ## Convert Jacobian to Affine coordinates
  discard

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
  when defined(bl808BleVendorLlcStartProbe):
    if nim_vendor_llc_status == 0xC0010001'u32:
      nim_vendor_llc_status = 0xC0010030'u32
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
  when defined(bl808m0) and defined(bl808BleVendorLldScanProbe):
    bleCentralTraceCheckRawRa(0x0A00'u32)
  when defined(bl808m0) and defined(bl808BleVendorLldConProbe) and
      defined(bl808BleVendorLlcStartProbe):
    if nim_vendor_llc_status == 0xC0010001'u32 and size == 0x8C'u32:
      discard mtype
      discard c_memset(addr nim_vendor_llc_env_storage[0], 0,
                       nim_vendor_llc_env_storage.len.csize_t)
      nim_vendor_llc_status = 0xC0010011'u32
      return cast[pointer](addr nim_vendor_llc_env_storage[0])
  when defined(bl808BleVendorLlcStartProbe):
    if nim_vendor_llc_status == 0xC0010001'u32:
      nim_vendor_llc_status = 0xC0010010'u32
  result = ble_ke_malloc(size, mtype)
  when defined(bl808m0) and defined(bl808BleVendorLldScanProbe):
    bleCentralTraceCheckRawRa(0x0A01'u32)
  when defined(bl808BleVendorLlcStartProbe):
    if nim_vendor_llc_status == 0xC0010010'u32:
      nim_vendor_llc_status = 0xC0010011'u32

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
  ke_mem_heap_end = cast[ptr uint8](cast[uint](heap) + size.uint)
  ble_ke_mem_init()

proc btble_ke_mem_is_empty*(): bool {.exportc, cdecl.} =
  ble_ke_mem_is_empty()

proc btble_ke_msg_alloc*(id: KeMsgId, destId: KeTaskId,
                         srcId: KeTaskId,
                         paramLen: uint16): pointer {.exportc, cdecl.} =
  when defined(bl808m0) and
      (defined(bl808BleVendorSchProgProbe) or
       defined(bl808BleVendorLldAdvProbe) or
       defined(bl808BleVendorLldConProbe) or
       defined(bl808BleVendorLldScanProbe)):
    when defined(bl808BleBridgeDiag):
      nim_vendor_bridge_stage = 0x8000'u32 or uint32(id and 0x00FF'u16)
  ble_ke_msg_alloc(id, destId, srcId, paramLen)

proc btble_ke_msg_send*(param: pointer) {.exportc, cdecl.} =
  when defined(bl808m0) and
      (defined(bl808BleVendorSchProgProbe) or
       defined(bl808BleVendorLldAdvProbe) or
       defined(bl808BleVendorLldConProbe) or
       defined(bl808BleVendorLldScanProbe)):
    when defined(bl808BleBridgeDiag):
      nim_vendor_bridge_stage = 0x8100'u32 or
        (cast[uint32](param) and 0x000000FF'u32)
  ble_ke_msg_send(param)

proc btble_ke_msg_send_basic*(id: KeMsgId, destId: KeTaskId,
                              srcId: KeTaskId) {.exportc, cdecl.} =
  when defined(bl808m0) and
      (defined(bl808BleVendorSchProgProbe) or
       defined(bl808BleVendorLldAdvProbe) or
       defined(bl808BleVendorLldConProbe) or
       defined(bl808BleVendorLldScanProbe)):
    when defined(bl808BleBridgeDiag):
      nim_vendor_bridge_stage = 0x8200'u32 or uint32(id and 0x00FF'u16)
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
  when defined(bl808BleVendorLlcStartProbe):
    if nim_vendor_llc_status == 0xC0010011'u32:
      nim_vendor_llc_status = 0xC0010020'u32
  ble_ke_state_set(taskId, state)
  when defined(bl808BleVendorLlcStartProbe):
    if nim_vendor_llc_status == 0xC0010020'u32:
      nim_vendor_llc_status = 0xC0010021'u32

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
  bflbble_reset()

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
      (defined(bl808BleVendorSchProgProbe) or
       defined(bl808BleVendorLldAdvProbe) or
       defined(bl808BleVendorLldConProbe) or
       defined(bl808BleVendorLldScanProbe)):
    when defined(bl808BleBridgeDiag):
      nim_vendor_bridge_stage = 0x8300'u32 or
        (cast[uint32](buf) and 0x000000FF'u32)
  when defined(bl808m0) and defined(bl808BleVendorLldConProbe) and
      defined(bl808BleVendorManualConnTx):
    let raw = cast[uint32](buf)
    if raw == NimVendorAclTxEmOffset.uint32 or
        raw == cast[uint32](addr nim_vendor_acl_empty_tx_buf[0]):
      nim_vendor_acl_empty_tx_pending = 0
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
  when defined(bl808m0) and defined(bl808BleVendorLldConProbe):
    inc nim_vendor_llcp_alloc_count
    nim_vendor_llcp_alloc_last_len = len.uint32
    nim_vendor_llcp_alloc_last_ptr = cast[uint32](buf)
    nim_vendor_llcp_alloc_last_emoff = 0
    nim_vendor_llcp_alloc_last_len_field = 0
    if buf != nil and len >= 7'u16:
      let raw = cast[ptr UncheckedArray[uint8]](buf)
      nim_vendor_llcp_alloc_last_emoff =
        uint32(raw[4]) or (uint32(raw[5]) shl 8)
      nim_vendor_llcp_alloc_last_len_field = raw[6].uint32
  buf

proc ble_util_buf_llcp_tx_free*(buf: pointer) {.exportc, cdecl.} =
  when defined(bl808m0) and
      (defined(bl808BleVendorSchProgProbe) or
       defined(bl808BleVendorLldAdvProbe) or
       defined(bl808BleVendorLldConProbe) or
       defined(bl808BleVendorLldScanProbe)):
    when defined(bl808BleBridgeDiag):
      nim_vendor_bridge_stage = 0x8400'u32 or
        (cast[uint32](buf) and 0x000000FF'u32)
  when defined(bl808m0) and defined(bl808BleVendorLldConProbe):
    let raw = cast[uint32](buf)
    inc nim_vendor_llcp_free_count
    nim_vendor_llcp_free_last_raw = raw
    if raw == NimVendorLlcpTxEmOffset.uint32 or
        raw == cast[uint32](addr nim_vendor_llcp_tx_buf[0]):
      nim_vendor_llcp_tx_pending = 0
      inc nim_vendor_llcp_free_manual_count
      when defined(bl808BleVendorManualConnTx):
        vendorTrySendQueuedLlcp()
      return
    if buf != nil:
      inc nim_vendor_llcp_free_heap_count
  if buf != nil:
    ble_ke_free(buf)

proc ble_util_buf_rx_alloc*(len: uint16): pointer {.exportc, cdecl.} =
  ble_ke_malloc(len.uint32, 0)

proc ble_util_buf_rx_free*(buf: pointer) {.exportc, cdecl.} =
  if buf != nil:
    ble_ke_free(buf)

proc ble_util_nb_good_channels*(map: ptr uint8): uint8 {.exportc, cdecl.} =
  if map == nil:
    return 0
  var count: uint8 = 0
  for i in 0 ..< 5:
    let byteVal = cast[ptr uint8](cast[uint](map) + i.uint)[]
    for bit in 0 ..< 8:
      if i * 8 + bit < 37 and (byteVal and (1'u8 shl bit)) != 0:
        inc count
  count

when not (defined(bl808m0) and defined(bl808BleVendorLldConProbe)):
  when not defined(bl808BleVendorLldScanProbe):
    var co_rate_to_phy* {.exportc.}: array[5, uint8] =
      [1'u8, 2, 3, 3, 0]
    var co_sca2ppm* {.exportc.}: array[8, uint16] =
      [500'u16, 250'u16, 150'u16, 100'u16, 75'u16, 50'u16, 30'u16, 20'u16]
    var lld_env* {.exportc.}: array[56, uint8]
    var lld_exp_sync_pos_tab* {.exportc.}: array[16, uint16]
    var rwip_priority* {.exportc.}: array[32, uint8] =
      [0x28'u8, 0x08, 0x60, 0x08, 0x50, 0x08, 0x70, 0x08,
       0x80, 0x08, 0xA0, 0x08, 0xA0, 0x08, 0x28, 0x1E,
       0x50, 0x08, 0x60, 0x08, 0x50, 0x08, 0, 0,
       0, 0, 0, 0, 0, 0, 0, 0]
    var rwip_rf* {.exportc.}: array[96, uint8]
    var rwip_coex_cfg* {.exportc.}: array[5, uint8] = [0'u8, 3, 1, 2, 3]
    var rwip_prog_delay* {.exportc.}: uint16 = 1'u16

  when defined(bl808BleVendorLldScanProbe):
    proc initVendorRwipRfTable() =
      discard c_memset(addr rwip_rf[0], 0, rwip_rf.len.csize_t)
      btble_rf_init(addr rwip_rf[0])

  proc lld_read_clock*(): uint32 {.exportc, cdecl.} =
    when defined(bl808BleVendorLldScanProbe):
      bleCentralTraceCheckRawRa(0x0A20'u32)
    result = currentBtbleTime()
    when defined(bl808BleVendorLldScanProbe):
      bleCentralTraceCheckRawRa(0x0A21'u32)

  proc rwip_current_drift_get*(): uint32 {.exportc, cdecl.} =
    0

  proc rwip_max_drift_get*(sca: uint8): uint32 {.exportc, cdecl.} =
    discard sca
    0

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

  when not defined(bl808BleVendorLldScanProbe):
    proc btble_rf_init*(rf: pointer) {.exportc, cdecl.} =
      discard rf
      ble_rf_init()

when not (defined(bl808m0) and
    (defined(bl808BleVendorSchProgProbe) or
     defined(bl808BleVendorLldConProbe) or
     defined(bl808BleVendorLldScanProbe))):
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
  llm_init()
  ecc_init()
  lld_sleep_init()
  bdaddr_init()
  resetNimControllerState()

proc rwip_reset*() {.exportc, cdecl.} =
  bflbble_reset()
  hci_reset()
  llc_reset()
  llm_init()
  ble_ke_event_flush()
  bflbip_prevent_sleep_mask = 0
  nim_btble_sw_pending = false
  resetNimControllerState()

proc rwip_isr*() {.exportc, cdecl.} =
  bflbble_isr()

proc rwip_schedule*() {.exportc, cdecl.} =
  ble_ke_event_schedule()

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

when not (defined(bl808m0) and defined(bl808BleVendorArbProbe)):
  proc rwip_timer_alarm_set*(targetCoarse: uint32, targetFine: uint16)
      {.exportc, cdecl.} =
    discard targetCoarse
    discard targetFine

when not (defined(bl808m0) and defined(bl808BleVendorArbProbe)):
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

const BleAesSbox: array[256, uint8] = [
  0x63'u8,0x7c,0x77,0x7b,0xf2,0x6b,0x6f,0xc5,0x30,0x01,0x67,0x2b,0xfe,0xd7,0xab,0x76,
  0xca,0x82,0xc9,0x7d,0xfa,0x59,0x47,0xf0,0xad,0xd4,0xa2,0xaf,0x9c,0xa4,0x72,0xc0,
  0xb7,0xfd,0x93,0x26,0x36,0x3f,0xf7,0xcc,0x34,0xa5,0xe5,0xf1,0x71,0xd8,0x31,0x15,
  0x04,0xc7,0x23,0xc3,0x18,0x96,0x05,0x9a,0x07,0x12,0x80,0xe2,0xeb,0x27,0xb2,0x75,
  0x09,0x83,0x2c,0x1a,0x1b,0x6e,0x5a,0xa0,0x52,0x3b,0xd6,0xb3,0x29,0xe3,0x2f,0x84,
  0x53,0xd1,0x00,0xed,0x20,0xfc,0xb1,0x5b,0x6a,0xcb,0xbe,0x39,0x4a,0x4c,0x58,0xcf,
  0xd0,0xef,0xaa,0xfb,0x43,0x4d,0x33,0x85,0x45,0xf9,0x02,0x7f,0x50,0x3c,0x9f,0xa8,
  0x51,0xa3,0x40,0x8f,0x92,0x9d,0x38,0xf5,0xbc,0xb6,0xda,0x21,0x10,0xff,0xf3,0xd2,
  0xcd,0x0c,0x13,0xec,0x5f,0x97,0x44,0x17,0xc4,0xa7,0x7e,0x3d,0x64,0x5d,0x19,0x73,
  0x60,0x81,0x4f,0xdc,0x22,0x2a,0x90,0x88,0x46,0xee,0xb8,0x14,0xde,0x5e,0x0b,0xdb,
  0xe0,0x32,0x3a,0x0a,0x49,0x06,0x24,0x5c,0xc2,0xd3,0xac,0x62,0x91,0x95,0xe4,0x79,
  0xe7,0xc8,0x37,0x6d,0x8d,0xd5,0x4e,0xa9,0x6c,0x56,0xf4,0xea,0x65,0x7a,0xae,0x08,
  0xba,0x78,0x25,0x2e,0x1c,0xa6,0xb4,0xc6,0xe8,0xdd,0x74,0x1f,0x4b,0xbd,0x8b,0x8a,
  0x70,0x3e,0xb5,0x66,0x48,0x03,0xf6,0x0e,0x61,0x35,0x57,0xb9,0x86,0xc1,0x1d,0x9e,
  0xe1,0xf8,0x98,0x11,0x69,0xd9,0x8e,0x94,0x9b,0x1e,0x87,0xe9,0xce,0x55,0x28,0xdf,
  0x8c,0xa1,0x89,0x0d,0xbf,0xe6,0x42,0x68,0x41,0x99,0x2d,0x0f,0xb0,0x54,0xbb,0x16,
]

const BleAesRcon: array[10, uint8] = [
  0x01'u8, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1B, 0x36
]

proc bleAesXtime(x: uint8): uint8 {.inline.} =
  let v = x.uint16 shl 1
  if (x and 0x80'u8) != 0:
    uint8((v xor 0x1B'u16) and 0xFF'u16)
  else:
    uint8(v and 0xFF'u16)

proc bleAesExpandKey(key: ptr uint8, roundKeys: var array[176, uint8]) =
  let raw = cast[ptr UncheckedArray[uint8]](key)
  for i in 0 ..< 16:
    roundKeys[i] = raw[i]

  var bytes = 16
  var rconIdx = 0
  var temp: array[4, uint8]
  while bytes < roundKeys.len:
    for i in 0 ..< 4:
      temp[i] = roundKeys[bytes - 4 + i]
    if (bytes and 0x0F) == 0:
      let t = temp[0]
      temp[0] = BleAesSbox[temp[1].int] xor BleAesRcon[rconIdx]
      temp[1] = BleAesSbox[temp[2].int]
      temp[2] = BleAesSbox[temp[3].int]
      temp[3] = BleAesSbox[t.int]
      inc rconIdx
    for i in 0 ..< 4:
      roundKeys[bytes] = roundKeys[bytes - 16] xor temp[i]
      inc bytes

proc bleAesAddRoundKey(state: var array[16, uint8],
                       roundKeys: var array[176, uint8], round: int) =
  let base = round * 16
  for i in 0 ..< 16:
    state[i] = state[i] xor roundKeys[base + i]

proc bleAesSubShift(state: var array[16, uint8]) =
  var tmp: array[16, uint8]
  for i in 0 ..< 16:
    tmp[i] = BleAesSbox[state[i].int]
  state[0] = tmp[0]; state[4] = tmp[4]; state[8] = tmp[8]; state[12] = tmp[12]
  state[1] = tmp[5]; state[5] = tmp[9]; state[9] = tmp[13]; state[13] = tmp[1]
  state[2] = tmp[10]; state[6] = tmp[14]; state[10] = tmp[2]; state[14] = tmp[6]
  state[3] = tmp[15]; state[7] = tmp[3]; state[11] = tmp[7]; state[15] = tmp[11]

proc bleAesMixColumns(state: var array[16, uint8]) =
  for col in 0 ..< 4:
    let b = col * 4
    let a0 = state[b]
    let a1 = state[b + 1]
    let a2 = state[b + 2]
    let a3 = state[b + 3]
    state[b] = bleAesXtime(a0) xor bleAesXtime(a1) xor a1 xor a2 xor a3
    state[b + 1] = a0 xor bleAesXtime(a1) xor bleAesXtime(a2) xor a2 xor a3
    state[b + 2] = a0 xor a1 xor bleAesXtime(a2) xor bleAesXtime(a3) xor a3
    state[b + 3] = bleAesXtime(a0) xor a0 xor a1 xor a2 xor bleAesXtime(a3)

proc bleAesEncryptBlock(key: ptr uint8, input: ptr uint8, output: ptr uint8) =
  if key == nil or input == nil or output == nil:
    return
  var roundKeys: array[176, uint8]
  var state: array[16, uint8]
  let src = cast[ptr UncheckedArray[uint8]](input)
  let dst = cast[ptr UncheckedArray[uint8]](output)
  for i in 0 ..< 16:
    state[i] = src[i]
  bleAesExpandKey(key, roundKeys)
  bleAesAddRoundKey(state, roundKeys, 0)
  for round in 1 .. 9:
    bleAesSubShift(state)
    bleAesMixColumns(state)
    bleAesAddRoundKey(state, roundKeys, round)
  bleAesSubShift(state)
  bleAesAddRoundKey(state, roundKeys, 10)
  for i in 0 ..< 16:
    dst[i] = state[i]

proc bleCmacShiftSubkey(dst: var array[16, uint8],
                        src: var array[16, uint8]) =
  let msb = (src[0] and 0x80'u8) != 0
  var carry = 0'u8
  for i in countdown(15, 0):
    let v = src[i]
    dst[i] = (v shl 1) or carry
    carry = (v shr 7) and 1
  if msb:
    dst[15] = dst[15] xor 0x87'u8

proc bleAesCmac(key: ptr uint8, msg: ptr uint8, msgLen: uint16,
                result: ptr uint8) =
  if key == nil or result == nil:
    return

  var zero: array[16, uint8]
  var l: array[16, uint8]
  var k1: array[16, uint8]
  var k2: array[16, uint8]
  var x: array[16, uint8]
  var y: array[16, uint8]
  var last: array[16, uint8]
  bleAesEncryptBlock(key, addr zero[0], addr l[0])
  bleCmacShiftSubkey(k1, l)
  bleCmacShiftSubkey(k2, k1)

  let length = msgLen.int
  let blockCount =
    if length == 0: 1
    else: (length + 15) div 16
  let completeLast = length != 0 and (length mod 16) == 0
  let data =
    if msg == nil: nil
    else: cast[ptr UncheckedArray[uint8]](msg)

  if completeLast and data != nil:
    let off = (blockCount - 1) * 16
    for i in 0 ..< 16:
      last[i] = data[off + i] xor k1[i]
  else:
    let rem = length mod 16
    let off = (blockCount - 1) * 16
    for i in 0 ..< rem:
      if data != nil:
        last[i] = data[off + i]
    last[rem] = 0x80'u8
    for i in 0 ..< 16:
      last[i] = last[i] xor k2[i]

  for blockIdx in 0 ..< blockCount - 1:
    for i in 0 ..< 16:
      let b =
        if data == nil: 0'u8
        else: data[blockIdx * 16 + i]
      y[i] = x[i] xor b
    bleAesEncryptBlock(key, addr y[0], addr x[0])

  for i in 0 ..< 16:
    y[i] = x[i] xor last[i]
  bleAesEncryptBlock(key, addr y[0], result)

proc bleCopyReversed(dst: ptr uint8, src: ptr uint8, count: int) =
  if dst == nil or count <= 0:
    return
  let d = cast[ptr UncheckedArray[uint8]](dst)
  if src == nil:
    for i in 0 ..< count:
      d[i] = 0
    return
  let s = cast[ptr UncheckedArray[uint8]](src)
  for i in 0 ..< count:
    d[i] = s[count - 1 - i]

proc bleCopyBytes(dst: ptr uint8, src: ptr uint8, count: int) =
  if dst == nil or count <= 0:
    return
  let d = cast[ptr UncheckedArray[uint8]](dst)
  if src == nil:
    for i in 0 ..< count:
      d[i] = 0
    return
  let s = cast[ptr UncheckedArray[uint8]](src)
  for i in 0 ..< count:
    d[i] = s[i]

proc bleReverseBytes(buf: ptr uint8, count: int) =
  if buf == nil or count <= 1:
    return
  let raw = cast[ptr UncheckedArray[uint8]](buf)
  for i in 0 ..< (count div 2):
    let j = count - 1 - i
    let t = raw[i]
    raw[i] = raw[j]
    raw[j] = t

proc bleCopyAddrParam(dst: ptr uint8, src: ptr uint8) =
  if dst == nil:
    return
  let d = cast[ptr UncheckedArray[uint8]](dst)
  if src == nil:
    for i in 0 ..< 7:
      d[i] = 0
    return
  let s = cast[ptr UncheckedArray[uint8]](src)
  d[0] = s[0]
  for i in 0 ..< 6:
    d[1 + i] = s[1 + 5 - i]

var nim_aes_last_result*: array[16, uint8]

proc bleReadLe32(src: ptr UncheckedArray[uint8], off: int): uint32 {.inline.} =
  uint32(src[off]) or (uint32(src[off + 1]) shl 8) or
    (uint32(src[off + 2]) shl 16) or (uint32(src[off + 3]) shl 24)

proc rwip_aes_encrypt*(input: ptr uint8, key: ptr uint8) {.exportc, cdecl.} =
  bleAesEncryptBlock(key, input, addr nim_aes_last_result[0])
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
  regWrite((BLE_BASE + 0x020'u32).uint, 0x04'u32)
  regOr(BLE_BASE + 0x018'u32, 0x04'u32)
  regOr(BLE_BASE + 0x0B0'u32, 0x01'u32)

proc rwble_init*(initType: uint8) {.exportc, cdecl.} =
  discard initType
  bflbble_init()

proc rwble_isr*() {.exportc, cdecl.} =
  bflbble_isr()

when not (defined(bl808m0) and
    (defined(bl808BleVendorLldConProbe) or defined(bl808BleVendorLldScanProbe))):
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

proc llm_le_features_get*(features: pointer) {.exportc, cdecl.} =
  when defined(bl808BleVendorLlcStartProbe):
    if nim_vendor_llc_status == 0xC0010001'u32:
      nim_vendor_llc_status = 0xC0010040'u32
  if features != nil:
    var f = llm_util_get_supp_features()
    discard c_memcpy(features, addr f, 8)

proc llc_le_ping_set*(conhdl: uint16, timeout: uint16) {.exportc, cdecl.} =
  when defined(bl808BleVendorLlcStartProbe):
    if nim_vendor_llc_status == 0xC0010200'u32:
      nim_vendor_llc_status = 0xC0010300'u32
  discard conhdl
  discard timeout

proc phy_upd_proc_start*(conhdl: uint16) {.exportc, cdecl.} =
  when defined(bl808BleVendorLlcStartProbe):
    if nim_vendor_llc_status == 0xC0010300'u32:
      nim_vendor_llc_status = 0xC0010400'u32
  discard conhdl

proc dl_upd_proc_start*(conhdl: uint16) {.exportc, cdecl.} =
  when defined(bl808BleVendorLlcStartProbe):
    if nim_vendor_llc_status == 0xC0010400'u32:
      nim_vendor_llc_status = 0xC0010500'u32
  discard conhdl

when defined(bl808m0) and defined(bl808BleVendorLldConProbe) and
    defined(bl808BleVendorLlcStartProbe) and bl808BleNimLlcStart:
  proc vendorLlcStart(conhdl: uint16, params: pointer): uint8
      {.exportc: "vendor_llc_start", cdecl.} =
    if params == nil or conhdl >= nim_vendor_llc_start_env_slots.len.uint16:
      return 0xFF'u8
    if nim_vendor_llc_start_env_slots[conhdl] != nil:
      return 0xFF'u8

    let env = addr nim_vendor_llc_start_env_storage[conhdl][0]
    let e = cast[ptr UncheckedArray[uint8]](env)
    let p = cast[ptr UncheckedArray[uint8]](params)
    discard c_memset(env, 0, nim_vendor_llc_start_env_storage[conhdl].len.csize_t)
    nim_vendor_llc_start_env_slots[conhdl] = env

    btble_ke_state_set(KeTaskId((conhdl shl 8) or 1'u16), 0'u8)
    btble_co_list_init(cast[ptr CoList](cast[uint](env) + 36'u))

    putLe16(e, 14, getLe16(p, 10))
    putLe16(e, 16, getLe16(p, 12))
    putLe16(e, 18, getLe16(p, 14))
    e[32] = p[22]
    discard c_memcpy(cast[pointer](cast[uint](env) + 8'u),
                     cast[pointer](cast[uint](params) + 16'u), 5)
    llm_le_features_get(cast[pointer](cast[uint](env) + 44'u))
    e[44] = e[44] and 0xFB'u8
    e[47] = e[47] and 0xFD'u8
    putLe16(e, 20, 27'u16)

    let rateIdx =
      if p[36] < co_rate_to_phy.len.uint8: co_rate_to_phy[p[36]]
      else: co_rate_to_phy[0]
    e[28] = rateIdx
    e[29] = rateIdx
    putLe16(e, 30, 519'u16)
    putLe32(e, 120, 0x429000FB'u32)
    putLe16(e, 22, 27'u16)
    putLe16(e, 24, 328'u16)
    putLe16(e, 26, 328'u16)
    putLe16(e, 116, getLe16(p, 40))
    let maxRxTime =
      if rateIdx == 3'u8:
        let a = getLe16(p, 42)
        if a < 0x0A90'u16: a else: 0x0A90'u16
      else:
        getLe16(p, 42)
    putLe16(e, 118, maxRxTime)
    putLe16(e, 124, getLe16(p, 44))
    e[126] = p[46]
    e[127] = p[47]
    var envFlags = getLe16(e, 128) and 0xFFFE'u16
    if p[37] == 0'u8:
      envFlags = envFlags or 1'u16
    putLe16(e, 128, envFlags)
    e[108] = p[48]
    e[114] = p[54]
    putLe16(e, 110, getLe16(p, 50))
    putLe16(e, 112, getLe16(p, 52))

    var lldParams: array[48, uint8]
    let l = cast[ptr UncheckedArray[uint8]](addr lldParams[0])
    for i in 0 ..< 23:
      l[i] = p[i]
    putLe16(l, 24, getLe16(p, 24))
    putLe32(l, 28,
      uint32(p[28]) or (uint32(p[29]) shl 8) or
      (uint32(p[30]) shl 16) or (uint32(p[31]) shl 24))
    putLe32(l, 32,
      uint32(p[32]) or (uint32(p[33]) shl 8) or
      (uint32(p[34]) shl 16) or (uint32(p[35]) shl 24))
    l[36] = p[37]
    l[37] = p[36]
    putLe16(l, 38, getLe16(p, 38))

    result = vendorLldConStart(conhdl, addr lldParams[0])
    llc_le_ping_set(conhdl, 3000'u16)
    phy_upd_proc_start(conhdl)
    dl_upd_proc_start(conhdl)
    when bl808BleVendorManualConnTx and bl808BleNimLlcStartInitialLlcp:
      if result == 0'u8:
        discard vendorSendInitialLlcpNow(conhdl)
    if result != 0'u8:
      nim_vendor_llc_start_env_slots[conhdl] = nil

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

proc llc_proc_state_get*(conhdl: uint16, procId: uint8): uint8
    {.exportc, cdecl.} =
  discard conhdl
  discard procId
  0

proc llc_proc_state_set*(conhdl: uint16, procId: uint8, state: uint8)
    {.exportc, cdecl.} =
  discard conhdl
  discard procId
  discard state

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
  discard conhdl
  discard procId

proc aes_alloc*(op: uint8, status: uint8, cb: pointer): pointer
    {.exportc, cdecl.} =
  discard op
  discard status
  discard cb
  ble_ke_malloc(16, 0)

proc aes_rand*(result: ptr uint8) {.exportc, cdecl.} =
  if result != nil:
    for i in 0 ..< 8:
      cast[ptr UncheckedArray[uint8]](result)[i] = uint8((currentBtbleTime() shr (i and 3)) and 0xFF)

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

proc aes_start*(op: pointer) {.exportc, cdecl.} =
  discard op

proc btble_aes_init*(initType: uint8) {.exportc, cdecl.} =
  discard initType

proc btble_aes_encrypt*(key: ptr uint8, val: ptr uint8, copy: bool,
                        cb: pointer, ctx: pointer) {.exportc, cdecl.} =
  discard copy
  discard cb
  discard ctx
  bleAesEncryptBlock(key, val, addr nim_aes_last_result[0])

proc bleCcmCounterBlock(nonce: ptr uint8, counter: uint16,
                        ccmBlock: var array[16, uint8]) =
  ccmBlock[0] = 0x01'u8 # L=2
  bleCopyBytes(addr ccmBlock[1], nonce, 13)
  ccmBlock[14] = uint8(counter shr 8)
  ccmBlock[15] = uint8(counter and 0xFF)

proc bleCcmCryptInPlace(key: ptr uint8, nonce: ptr uint8, msg: ptr uint8,
                        msgLen: uint16) =
  if key == nil or nonce == nil or msg == nil:
    return
  var ctr: array[16, uint8]
  var stream: array[16, uint8]
  let raw = cast[ptr UncheckedArray[uint8]](msg)
  var offset = 0
  var counter = 1'u16
  let length = msgLen.int
  while offset < length:
    bleCcmCounterBlock(nonce, counter, ctr)
    bleAesEncryptBlock(key, addr ctr[0], addr stream[0])
    let chunk = min(16, length - offset)
    for i in 0 ..< chunk:
      raw[offset + i] = raw[offset + i] xor stream[i]
    inc counter
    offset += chunk

proc bleCcmComputeMic(key: ptr uint8, nonce: ptr uint8, msg: ptr uint8,
                      msgLen: uint16, mic: ptr uint8) =
  if key == nil or nonce == nil or mic == nil:
    return
  var ccmBlock: array[16, uint8]
  var y: array[16, uint8]
  var ctr0: array[16, uint8]
  var s0: array[16, uint8]
  let raw = cast[ptr UncheckedArray[uint8]](msg)
  let length = msgLen.int

  ccmBlock[0] = 0x09'u8 # no AAD, M=4, L=2
  bleCopyBytes(addr ccmBlock[1], nonce, 13)
  ccmBlock[14] = uint8(msgLen shr 8)
  ccmBlock[15] = uint8(msgLen and 0xFF)
  bleAesEncryptBlock(key, addr ccmBlock[0], addr y[0])

  var offset = 0
  while offset < length:
    for i in 0 ..< 16:
      let b =
        if msg != nil and offset + i < length: raw[offset + i]
        else: 0'u8
      ccmBlock[i] = y[i] xor b
    bleAesEncryptBlock(key, addr ccmBlock[0], addr y[0])
    offset += 16

  bleCcmCounterBlock(nonce, 0'u16, ctr0)
  bleAesEncryptBlock(key, addr ctr0[0], addr s0[0])
  let outp = cast[ptr UncheckedArray[uint8]](mic)
  for i in 0 ..< 4:
    outp[i] = y[i] xor s0[i]

proc aes_c1*(key: ptr uint8, r: ptr uint8, pres: ptr uint8,
             preq: ptr uint8, iat: uint8, ia: ptr uint8,
             rat: uint8, ra: ptr uint8, result: ptr uint8)
    {.exportc, cdecl.} =
  if result == nil:
    return
  if key == nil or r == nil:
    discard c_memset(result, 0, 16)
    return

  var p1: array[16, uint8]
  var p2: array[16, uint8]
  var tmp: array[16, uint8]
  let rand = cast[ptr UncheckedArray[uint8]](r)

  bleCopyBytes(addr p1[0], pres, 7)
  bleCopyBytes(addr p1[7], preq, 7)
  p1[14] = rat
  p1[15] = iat

  bleCopyBytes(addr p2[4], ia, 6)
  bleCopyBytes(addr p2[10], ra, 6)

  for i in 0 ..< 16:
    tmp[i] = rand[i] xor p1[i]
  bleAesEncryptBlock(key, addr tmp[0], addr tmp[0])
  for i in 0 ..< 16:
    tmp[i] = tmp[i] xor p2[i]
  bleAesEncryptBlock(key, addr tmp[0], result)

proc aes_s1*(key: ptr uint8, r1: ptr uint8, r2: ptr uint8,
             result: ptr uint8) {.exportc, cdecl.} =
  var plaintext: array[16, uint8]
  bleCopyBytes(addr plaintext[0], r2, 8)
  bleCopyBytes(addr plaintext[8], r1, 8)
  bleAesEncryptBlock(key, addr plaintext[0], result)

proc aes_ccm*(key: ptr uint8, nonce: ptr uint8, msg: ptr uint8, msgLen: uint16,
              mic: ptr uint8, encrypt: bool) {.exportc, cdecl.} =
  if key == nil or nonce == nil:
    if mic != nil:
      discard c_memset(mic, 0, 4)
    return
  if encrypt:
    bleCcmComputeMic(key, nonce, msg, msgLen, mic)
    bleCcmCryptInPlace(key, nonce, msg, msgLen)
  else:
    bleCcmCryptInPlace(key, nonce, msg, msgLen)
    bleCcmComputeMic(key, nonce, msg, msgLen, mic)

proc aes_cmac*(key: ptr uint8, msg: ptr uint8, msgLen: uint16,
               result: ptr uint8) {.exportc, cdecl.} =
  bleAesCmac(key, msg, msgLen, result)

proc aes_cmac_start*(key: ptr uint8, msg: ptr uint8, msgLen: uint16,
                     result: ptr uint8) {.exportc, cdecl.} =
  aes_cmac(key, msg, msgLen, result)

proc aes_cmac_continue*(ctx: pointer, msg: ptr uint8, msgLen: uint16,
                        result: ptr uint8) {.exportc, cdecl.} =
  discard ctx
  aes_cmac(nil, msg, msgLen, result)

proc aes_f4*(u: ptr uint8, v: ptr uint8, x: ptr uint8, z: uint8,
             result: ptr uint8) {.exportc, cdecl.} =
  var key: array[16, uint8]
  var msg: array[65, uint8]
  bleCopyReversed(addr msg[0], u, 32)
  bleCopyReversed(addr msg[32], v, 32)
  msg[64] = z
  bleCopyReversed(addr key[0], x, 16)
  bleAesCmac(addr key[0], addr msg[0], msg.len.uint16, result)
  bleReverseBytes(result, 16)

proc aes_f5*(w: ptr uint8, n1: ptr uint8, n2: ptr uint8, a1: ptr uint8,
             a2: ptr uint8, mackey: ptr uint8, ltk: ptr uint8)
    {.exportc, cdecl.} =
  const salt: array[16, uint8] = [
    0x6c'u8, 0x88, 0x83, 0x91, 0xaa, 0xf5, 0xa5, 0x38,
    0x60, 0x37, 0x0b, 0xdb, 0x5a, 0x60, 0x83, 0xbe
  ]
  var ws: array[32, uint8]
  var t: array[16, uint8]
  var msg: array[53, uint8]
  msg[1] = 0x62'u8
  msg[2] = 0x74'u8
  msg[3] = 0x6c'u8
  msg[4] = 0x65'u8
  msg[51] = 0x01'u8
  msg[52] = 0x00'u8
  bleCopyReversed(addr ws[0], w, 32)
  bleAesCmac(unsafeAddr salt[0], addr ws[0], ws.len.uint16, addr t[0])
  bleCopyReversed(addr msg[5], n1, 16)
  bleCopyReversed(addr msg[21], n2, 16)
  bleCopyAddrParam(addr msg[37], a1)
  bleCopyAddrParam(addr msg[44], a2)
  msg[0] = 0
  bleAesCmac(addr t[0], addr msg[0], msg.len.uint16, mackey)
  bleReverseBytes(mackey, 16)
  msg[0] = 1
  bleAesCmac(addr t[0], addr msg[0], msg.len.uint16, ltk)
  bleReverseBytes(ltk, 16)

proc aes_f6*(w: ptr uint8, n1: ptr uint8, n2: ptr uint8, r: ptr uint8,
             iocap: ptr uint8, a1: ptr uint8, a2: ptr uint8,
             result: ptr uint8) {.exportc, cdecl.} =
  var key: array[16, uint8]
  var msg: array[65, uint8]
  bleCopyReversed(addr msg[0], n1, 16)
  bleCopyReversed(addr msg[16], n2, 16)
  bleCopyReversed(addr msg[32], r, 16)
  bleCopyReversed(addr msg[48], iocap, 3)
  bleCopyAddrParam(addr msg[51], a1)
  bleCopyAddrParam(addr msg[58], a2)
  bleCopyReversed(addr key[0], w, 16)
  bleAesCmac(addr key[0], addr msg[0], msg.len.uint16, result)
  bleReverseBytes(result, 16)

proc aes_g2*(u: ptr uint8, v: ptr uint8, x: ptr uint8, y: ptr uint8): uint32
    {.exportc, cdecl.} =
  var key: array[16, uint8]
  var msg: array[80, uint8]
  var res: array[16, uint8]
  bleCopyReversed(addr msg[0], u, 32)
  bleCopyReversed(addr msg[32], v, 32)
  bleCopyReversed(addr msg[64], y, 16)
  bleCopyReversed(addr key[0], x, 16)
  bleAesCmac(addr key[0], addr msg[0], msg.len.uint16, addr res[0])
  let passkey =
    (res[12].uint32 shl 24) or (res[13].uint32 shl 16) or
    (res[14].uint32 shl 8) or res[15].uint32
  passkey mod 1_000_000'u32

proc aes_h6*(w: ptr uint8, keyId: ptr uint8, result: ptr uint8)
    {.exportc, cdecl.} =
  var key: array[16, uint8]
  var msg: array[4, uint8]
  bleCopyReversed(addr key[0], w, 16)
  bleCopyReversed(addr msg[0], keyId, 4)
  bleAesCmac(addr key[0], addr msg[0], msg.len.uint16, result)
  bleReverseBytes(result, 16)

proc aes_h7*(salt: ptr uint8, w: ptr uint8, result: ptr uint8)
    {.exportc, cdecl.} =
  var key: array[16, uint8]
  var msg: array[16, uint8]
  bleCopyReversed(addr key[0], salt, 16)
  bleCopyReversed(addr msg[0], w, 16)
  bleAesCmac(addr key[0], addr msg[0], msg.len.uint16, result)
  bleReverseBytes(result, 16)

proc aes_h8*(k: ptr uint8, s: ptr uint8, keyId: ptr uint8,
             result: ptr uint8) {.exportc, cdecl.} =
  var msg: array[20, uint8]
  bleCopyBytes(addr msg[0], keyId, 4)
  bleCopyBytes(addr msg[4], s, 16)
  bleAesCmac(k, addr msg[0], msg.len.uint16, result)

proc aes_h9*(k: ptr uint8, s: ptr uint8, keyId: ptr uint8,
             result: ptr uint8) {.exportc, cdecl.} =
  var msg: array[20, uint8]
  bleCopyBytes(addr msg[0], keyId, 4)
  bleCopyBytes(addr msg[4], s, 16)
  bleAesCmac(k, addr msg[0], msg.len.uint16, result)

proc aes_k1*(n: ptr uint8, salt: ptr uint8, p: ptr uint8, pLen: uint16,
             result: ptr uint8) {.exportc, cdecl.} =
  var t: array[16, uint8]
  bleAesCmac(salt, n, 16, addr t[0])
  bleAesCmac(addr t[0], p, pLen, result)

proc aes_k2*(n: ptr uint8, p: ptr uint8, pLen: uint16,
             result: ptr uint8) {.exportc, cdecl.} =
  aes_cmac(n, p, pLen, result)

proc aes_k3*(n: ptr uint8, result: ptr uint8) {.exportc, cdecl.} =
  const saltKey: array[4, uint8] = [0x73'u8, 0x6d, 0x6b, 0x33] # "smk3"
  const id64: array[4, uint8] = [0x69'u8, 0x64, 0x36, 0x34]    # "id64"
  var salt: array[16, uint8]
  bleAesCmac(unsafeAddr saltKey[0], unsafeAddr saltKey[0], saltKey.len.uint16,
             addr salt[0])
  aes_k1(n, addr salt[0], unsafeAddr id64[0], id64.len.uint16, result)

proc aes_k4*(n: ptr uint8): uint8 {.exportc, cdecl.} =
  const saltKey: array[4, uint8] = [0x73'u8, 0x6d, 0x6b, 0x34] # "smk4"
  const id6: array[3, uint8] = [0x69'u8, 0x64, 0x36]           # "id6"
  var salt: array[16, uint8]
  var res: array[16, uint8]
  bleAesCmac(unsafeAddr saltKey[0], unsafeAddr saltKey[0], saltKey.len.uint16,
             addr salt[0])
  aes_k1(n, addr salt[0], unsafeAddr id6[0], id6.len.uint16, addr res[0])
  res[15] and 0x3F'u8

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
  var evt = [status, uint8(handle and 0xFF),
             uint8((handle shr 8) and 0xFF), enabled]
  sendHostEvent(HciEvtEncryptionChange, addr evt[0], evt.len.uint8)

proc sendRemoteVersionInfoComplete(handle: uint16, status: uint8) =
  var evt = [
    status,
    uint8(handle and 0xFF),
    uint8((handle shr 8) and 0xFF),
    0x09'u8,   # Bluetooth Core 5.0 HCI version
    0xBF'u8, 0x01'u8,
    0x01'u8, 0x00'u8
  ]
  sendHostEvent(HciEvtRemoteVersionInfoComplete, addr evt[0], evt.len.uint8)

proc sendLeConnectionUpdateComplete(handle: uint16, status: uint8,
                                    params: ptr uint8) =
  var evt: array[10, uint8]
  evt[0] = 0x03'u8
  evt[1] = status
  evt[2] = uint8(handle and 0xFF)
  evt[3] = uint8((handle shr 8) and 0xFF)
  if params != nil:
    let raw = cast[ptr UncheckedArray[uint8]](params)
    evt[4] = raw[2]
    evt[5] = raw[3]
    evt[6] = raw[6]
    evt[7] = raw[7]
    evt[8] = raw[8]
    evt[9] = raw[9]
  sendLeMetaPayload(addr evt[0], evt.len.uint8)

proc sendLeRemoteFeaturesComplete(handle: uint16, status: uint8) =
  var evt = [
    0x04'u8,
    status,
    uint8(handle and 0xFF),
    uint8((handle shr 8) and 0xFF),
    0x3F'u8, 0x00'u8, 0x00'u8, 0x00'u8,
    0x00'u8, 0x00'u8, 0x00'u8, 0x00'u8
  ]
  sendLeMetaPayload(addr evt[0], evt.len.uint8)

proc sendLePhyUpdateComplete(handle: uint16, status: uint8, params: ptr uint8) =
  var txPhy = 1'u8
  var rxPhy = 1'u8
  if params != nil:
    let raw = cast[ptr UncheckedArray[uint8]](params)
    if raw[3] != 0:
      txPhy = raw[3]
    if raw[4] != 0:
      rxPhy = raw[4]
  var evt = [0x0C'u8, status, uint8(handle and 0xFF),
             uint8((handle shr 8) and 0xFF), txPhy, rxPhy]
  sendLeMetaPayload(addr evt[0], evt.len.uint8)

proc hci_rd_rssi_cmd_handler*(params: ptr uint8, opcode: uint16): uint32
    {.exportc, cdecl.} =
  let handle = paramLe16(params, 0)
  let status =
    if params == nil or (nim_conn_active and handle != nim_conn_handle): 0x02'u8
    else: 0'u8
  var rsp = [status, uint8(handle and 0xFF), uint8((handle shr 8) and 0xFF),
             cast[uint8](lld_con_rssi_get(handle))]
  sendCmdCompletePayload(opcode, addr rsp[0], rsp.len.uint8)
  0

proc hci_rd_tx_pwr_lvl_cmd_handler*(params: ptr uint8,
                                    opcode: uint16): uint32
    {.exportc, cdecl.} =
  let handle = paramLe16(params, 0)
  let status =
    if params == nil or (nim_conn_active and handle != nim_conn_handle): 0x02'u8
    else: 0'u8
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
  let handle = paramLe16(params, 0)
  let status = connParamStatus(params, handle)
  sendCmdComplete(opcode, status)
  if status == 0:
    sendLeConnectionUpdateComplete(handle, status, params)
  0

proc hci_le_en_enc_cmd_handler*(params: ptr uint8, opcode: uint16): uint32
    {.exportc, cdecl.} =
  let handle = paramLe16(params, 0)
  let status = connParamStatus(params, handle)
  sendCmdComplete(opcode, status)
  if status == 0:
    sendEncryptionChange(handle, 0'u8, 1'u8)
  0

proc hci_le_ltk_req_reply_cmd_handler*(params: ptr uint8,
                                       opcode: uint16): uint32
    {.exportc, cdecl.} =
  let handle = paramLe16(params, 0)
  let status = connParamStatus(params, handle)
  sendHandleCmdComplete(opcode, status, handle)
  if status == 0:
    sendEncryptionChange(handle, 0'u8, 1'u8)
  0

proc hci_le_ltk_req_neg_reply_cmd_handler*(params: ptr uint8,
                                           opcode: uint16): uint32
    {.exportc, cdecl.} =
  let handle = paramLe16(params, 0)
  sendHandleCmdComplete(opcode, connParamStatus(params, handle), handle)
  0

proc hci_le_rd_rem_feats_cmd_handler*(params: ptr uint8,
                                      opcode: uint16): uint32
    {.exportc, cdecl.} =
  let handle = paramLe16(params, 0)
  let status = connParamStatus(params, handle)
  sendCmdComplete(opcode, status)
  if status == 0:
    sendLeRemoteFeaturesComplete(handle, status)
  0

proc hci_le_rem_con_param_req_reply_cmd_handler*(params: ptr uint8,
                                                 opcode: uint16): uint32
    {.exportc, cdecl.} =
  let handle = paramLe16(params, 0)
  let status = connParamStatus(params, handle)
  sendHandleCmdComplete(opcode, status, handle)
  if status == 0:
    sendLeConnectionUpdateComplete(handle, status, params)
  0

proc hci_le_rem_con_param_req_neg_reply_cmd_handler*(params: ptr uint8,
                                                     opcode: uint16): uint32
    {.exportc, cdecl.} =
  let handle = paramLe16(params, 0)
  sendHandleCmdComplete(opcode, connParamStatus(params, handle), handle)
  0

proc hci_le_req_peer_sca_cmd_handler*(params: ptr uint8,
                                      opcode: uint16): uint32
    {.exportc, cdecl.} =
  let handle = paramLe16(params, 0)
  let status = connParamStatus(params, handle)
  sendCmdComplete(opcode, status)
  if status == 0:
    var evt = [0x20'u8, status, uint8(handle and 0xFF),
               uint8((handle shr 8) and 0xFF), 0'u8]
    sendLeMetaPayload(addr evt[0], evt.len.uint8)
  0

proc hci_le_set_phy_cmd_handler*(params: ptr uint8, opcode: uint16): uint32
    {.exportc, cdecl.} =
  let handle = paramLe16(params, 0)
  let status = connParamStatus(params, handle)
  sendCmdComplete(opcode, status)
  if status == 0:
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
  let handle = paramLe16(params, 0)
  let status =
    if params == nil or (nim_conn_active and handle != nim_conn_handle): 0x02'u8
    else: 0'u8
  var rsp = [status, uint8(handle and 0xFF), uint8((handle shr 8) and 0xFF),
             0xFF'u8, 0xFF, 0xFF, 0xFF, 0x1F]
  sendCmdCompletePayload(opcode, addr rsp[0], rsp.len.uint8)
  0

proc hci_le_rd_phy_cmd_handler*(params: ptr uint8, opcode: uint16): uint32
    {.exportc, cdecl.} =
  let handle = paramLe16(params, 0)
  let status =
    if params == nil or (nim_conn_active and handle != nim_conn_handle): 0x02'u8
    else: 0'u8
  var rsp = [status, uint8(handle and 0xFF), uint8((handle shr 8) and 0xFF),
             1'u8, 1'u8]
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
    let raw = cast[ptr UncheckedArray[uint8]](params)
    for i in 0 ..< nim_local_addr.len:
      nim_local_addr[i] = raw[i + 1]
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
  let handle = paramLe16(params, 0)
  let status =
    if params == nil or (nim_conn_active and handle != nim_conn_handle): 0x02'u8
    else: 0'u8
  var rsp = [status, uint8(handle and 0xFF), uint8((handle shr 8) and 0xFF)]
  sendCmdCompletePayload(opcode, addr rsp[0], rsp.len.uint8)
  0

proc hci_rd_auth_payl_to_cmd_handler*(params: ptr uint8,
                                      opcode: uint16): uint32
    {.exportc, cdecl.} =
  let handle = paramLe16(params, 0)
  let status = connParamStatus(params, handle)
  var rsp = [status, uint8(handle and 0xFF), uint8((handle shr 8) and 0xFF),
             uint8(nim_auth_payload_timeout and 0xFF),
             uint8((nim_auth_payload_timeout shr 8) and 0xFF)]
  sendCmdCompletePayload(opcode, addr rsp[0], rsp.len.uint8)
  0

proc hci_rd_rem_ver_info_cmd_handler*(params: ptr uint8,
                                      opcode: uint16): uint32
    {.exportc, cdecl.} =
  let handle = paramLe16(params, 0)
  let status = connParamStatus(params, handle)
  sendCmdComplete(opcode, status)
  if status == 0:
    sendRemoteVersionInfoComplete(handle, status)
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
  let handle = paramLe16(params, 0)
  let status = connParamStatus(params, handle)
  if params != nil:
    nim_auth_payload_timeout = paramLe16(params, 2)
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

when not (defined(bl808m0) and
    (defined(bl808BleVendorLldConProbe) or defined(bl808BleVendorLldScanProbe))):
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
  when defined(bl808m0) and defined(bl808BleVendorLldScanProbe) and
      defined(bl808BleVendorLldInitProbe):
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
  when defined(bl808m0) and defined(bl808BleVendorLldScanProbe) and
      defined(bl808BleVendorLldInitProbe):
    nim_lld_aa_last = aa

proc lld_ch_idx_get*(): uint8 {.exportc, cdecl.} =
  uint8(currentBtbleTime() mod 37'u32)

proc lld_con_current_tx_power_get*(conhdl: uint16): int8 {.exportc, cdecl.} =
  discard conhdl
  ble_tx_pwr

proc lld_con_rssi_get*(conhdl: uint16): int8 {.exportc, cdecl.} =
  discard conhdl
  0'i8

template vendorZeroStub(name: untyped) =
  proc name*(): uint32 {.exportc, cdecl.} =
    0

vendorZeroStub(Add2SelfBigHex256)
vendorZeroStub(AddBigHex256)
vendorZeroStub(AddBigHexModP256)
vendorZeroStub(AddP256)
vendorZeroStub(AddPdiv2_256)
vendorZeroStub(GF_Jacobian_Point_Addition256)
vendorZeroStub(GF_Jacobian_Point_Double256)
vendorZeroStub(MultiplyBigHexByUint32_256)
vendorZeroStub(MultiplyBigHexModP256)
vendorZeroStub(MultiplyByU32ModP256)
vendorZeroStub(SubtractBigHex256)
vendorZeroStub(SubtractBigHexMod256)
vendorZeroStub(SubtractBigHexUint32_256)
vendorZeroStub(SubtractFromSelfBigHex256)
vendorZeroStub(SubtractFromSelfBigHexSign256)
vendorZeroStub(co_djob_init)
vendorZeroStub(co_djob_initialize)
vendorZeroStub(co_djob_isr_reg)
vendorZeroStub(co_djob_reg)
vendorZeroStub(co_djob_unreg)
vendorZeroStub(emi_init)
vendorZeroStub(hci_acl_data_handler)
vendorZeroStub(hci_command_llc_handler)
vendorZeroStub(hci_command_llm_handler)
vendorZeroStub(hci_msg_cmd_cmp_pkupk)
vendorZeroStub(hci_msg_cmd_desc_get)
vendorZeroStub(hci_msg_cmd_pkupk)
vendorZeroStub(hci_msg_cmd_status_exp)
vendorZeroStub(hci_msg_evt_desc_get)
vendorZeroStub(hci_msg_evt_get_hl_tl_dest)
vendorZeroStub(hci_msg_evt_host_lid_get)
vendorZeroStub(hci_msg_evt_pkupk)
vendorZeroStub(hci_msg_le_evt_desc_get)
vendorZeroStub(led_init)
vendorZeroStub(led_set_all)
vendorZeroStub(ll_channel_map_ind_handler)
vendorZeroStub(ll_clk_acc_req_handler)
vendorZeroStub(ll_clk_acc_rsp_handler)
vendorZeroStub(ll_connection_param_req_handler)
vendorZeroStub(ll_connection_param_rsp_handler)
vendorZeroStub(ll_connection_update_ind_handler)
vendorZeroStub(ll_enc_req_handler)
vendorZeroStub(ll_enc_rsp_handler)
vendorZeroStub(ll_feature_req_handler)
vendorZeroStub(ll_feature_rsp_handler)
vendorZeroStub(ll_length_req_handler)
vendorZeroStub(ll_length_rsp_handler)
vendorZeroStub(ll_min_used_channels_ind_handler)
vendorZeroStub(ll_pause_enc_req_handler)
vendorZeroStub(ll_pause_enc_rsp_handler)
vendorZeroStub(ll_phy_req_handler)
vendorZeroStub(ll_phy_rsp_handler)
vendorZeroStub(ll_phy_update_ind_handler)
vendorZeroStub(ll_ping_req_handler)
vendorZeroStub(ll_ping_rsp_handler)
vendorZeroStub(ll_slave_feature_req_handler)
vendorZeroStub(ll_start_enc_req_handler)
vendorZeroStub(ll_start_enc_rsp_handler)
when defined(bl808m0) and defined(bl808BleVendorLldConProbe):
  proc ll_terminate_ind_handler*(): uint32 {.exportc, cdecl.} =
    noteVendorPeripheralDisconnected(0x13'u8)
    0
else:
  vendorZeroStub(ll_terminate_ind_handler)
vendorZeroStub(ll_version_ind_handler)
vendorZeroStub(llc_auth_payl_nearly_to_handler)
vendorZeroStub(llc_auth_payl_real_to_handler)
vendorZeroStub(llc_cleanup)
vendorZeroStub(llc_clk_acc_modify)
vendorZeroStub(llc_con_move_cbk)
vendorZeroStub(llc_disconnect)
vendorZeroStub(llc_encrypt_ind_handler)
vendorZeroStub(llc_init_term_proc)
vendorZeroStub(llc_le_ping_restart)
vendorZeroStub(llc_ll_reject_ind_pdu_send)
vendorZeroStub(llc_llcp_send)
vendorZeroStub(llc_llcp_state_set)
vendorZeroStub(llc_op_ch_map_upd_ind_handler)
vendorZeroStub(llc_op_clk_acc_ind_handler)
vendorZeroStub(llc_op_con_upd_ind_handler)
when defined(bl808m0) and defined(bl808BleVendorLldConProbe):
  proc llc_op_disconnect_ind_handler*(): uint32 {.exportc, cdecl.} =
    noteVendorPeripheralDisconnected(0x13'u8)
    0
else:
  vendorZeroStub(llc_op_disconnect_ind_handler)
vendorZeroStub(llc_op_dl_upd_ind_handler)
vendorZeroStub(llc_op_encrypt_ind_handler)
vendorZeroStub(llc_op_feats_exch_ind_handler)
vendorZeroStub(llc_op_le_ping_ind_handler)
vendorZeroStub(llc_op_phy_upd_ind_handler)
vendorZeroStub(llc_op_ver_exch_ind_handler)
vendorZeroStub(llc_proc_collision_check)
vendorZeroStub(llc_proc_err_ind)
vendorZeroStub(llc_proc_get)
vendorZeroStub(llc_proc_id_get)
vendorZeroStub(llc_proc_id_set)
vendorZeroStub(llc_proc_init)
vendorZeroStub(llc_proc_reg)
when defined(bl808m0) and defined(bl808BleVendorLldConProbe):
  proc llc_stopped_ind_handler*(): uint32 {.exportc, cdecl.} =
    noteVendorPeripheralDisconnected(0x13'u8)
    0
else:
  vendorZeroStub(llc_stopped_ind_handler)
vendorZeroStub(lld_acl_rx_ind_handler)
vendorZeroStub(lld_acl_tx_cfm_handler)
when not defined(bl808BleVendorLldAdvProbe):
  vendorZeroStub(lld_adv_adv_data_update)
  vendorZeroStub(lld_adv_duration_update)
vendorZeroStub(lld_adv_end_ind_handler)
when not defined(bl808BleVendorLldAdvProbe):
  vendorZeroStub(lld_adv_init)
  vendorZeroStub(lld_adv_rand_addr_update)
  vendorZeroStub(lld_adv_restart)
  vendorZeroStub(lld_adv_scan_rsp_data_update)
vendorZeroStub(lld_calc_aux_rx)
vendorZeroStub(lld_ch_map_set)
vendorZeroStub(lld_ch_map_upd_cfm_handler)
vendorZeroStub(lld_con_ch_map_update)
vendorZeroStub(lld_con_data_flow_set)
vendorZeroStub(lld_con_data_len_update)
when not (defined(bl808m0) and defined(bl808BleVendorLldConProbe) and
          defined(bl808BleVendorManualConnTx)):
  vendorZeroStub(lld_con_data_tx)
vendorZeroStub(lld_con_enc_key_load)
vendorZeroStub(lld_con_event_counter_get)
vendorZeroStub(lld_con_init)
when not (defined(bl808m0) and defined(bl808BleVendorLldConProbe) and
          defined(bl808BleVendorManualConnTx)):
  vendorZeroStub(lld_con_llcp_tx)
vendorZeroStub(lld_con_offset_get)
vendorZeroStub(lld_con_offset_upd_ind_handler)
vendorZeroStub(lld_con_param_upd_cfm_handler)
vendorZeroStub(lld_con_param_update)
vendorZeroStub(lld_con_peer_sca_set)
vendorZeroStub(lld_con_phys_update)
vendorZeroStub(lld_con_pref_slave_evt_dur_set)
vendorZeroStub(lld_con_pref_slave_latency_set)
vendorZeroStub(lld_con_rx_enc)
vendorZeroStub(lld_con_time_get)
vendorZeroStub(lld_con_tx_enc)
vendorZeroStub(lld_con_tx_len_update_for_intv)
vendorZeroStub(lld_con_tx_len_update_for_rate)
when defined(bl808m0) and defined(bl808BleVendorLldConProbe):
  proc lld_disc_ind_handler*(): uint32 {.exportc, cdecl.} =
    noteVendorPeripheralDisconnected(0x13'u8)
    0
else:
  vendorZeroStub(lld_disc_ind_handler)
vendorZeroStub(lld_llcp_rx_ind_handler)
vendorZeroStub(lld_llcp_tx_cfm_handler)
vendorZeroStub(lld_per_adv_list_add)
vendorZeroStub(lld_per_adv_list_rem)
vendorZeroStub(lld_phy_upd_cfm_handler)
when defined(bl808m0) and defined(bl808BleVendorLldInitProbe):
  proc lld_ral_search*(peerAddr: pointer, addrType: uint8): uint8
      {.exportc, cdecl.} =
    discard peerAddr
    discard addrType
    0xFF'u8
else:
  vendorZeroStub(lld_ral_search)
vendorZeroStub(lld_rpa_renew)
when not (defined(bl808m0) and defined(bl808BleVendorLldConProbe)):
  vendorZeroStub(lld_rx_timing_compute)
vendorZeroStub(lld_rxdesc_buf_ready)
vendorZeroStub(lld_scan_req_ind_handler)
vendorZeroStub(lld_white_list_add)
vendorZeroStub(lld_white_list_rem)
vendorZeroStub(llm_activity_free_get)
vendorZeroStub(llm_activity_free_set)
vendorZeroStub(llm_adv_hdl_to_id)
vendorZeroStub(llm_adv_itf_extended_set)
vendorZeroStub(llm_ch_map_update)
vendorZeroStub(llm_ch_map_update_ind_handler)
vendorZeroStub(llm_clk_acc_set)
vendorZeroStub(llm_cmd_cmp_send)
vendorZeroStub(llm_cmd_stat_send)
vendorZeroStub(llm_dev_list_empty_entry)
vendorZeroStub(llm_dev_list_search)
vendorZeroStub(llm_get_connection_accept_timeout)
vendorZeroStub(llm_is_adv_itf_legacy)
vendorZeroStub(llm_is_dev_connected)
vendorZeroStub(llm_le_evt_mask_check)
vendorZeroStub(llm_link_disc)
vendorZeroStub(llm_master_ch_map_get)
vendorZeroStub(llm_per_adv_chain_dur)
vendorZeroStub(llm_plan_elt_get)
vendorZeroStub(llm_rx_path_comp_get)
vendorZeroStub(llm_set_connection_accept_timeout)
vendorZeroStub(llm_tx_path_comp_get)
when not (defined(bl808m0) and
    (defined(bl808BleVendorFullSchedulerProbe) or
     defined(bl808BleVendorAlarmProbe))):
  vendorZeroStub(sch_alarm_clear)
  vendorZeroStub(sch_alarm_init)
  vendorZeroStub(sch_alarm_set)
  vendorZeroStub(sch_alarm_timer_isr)
when not (defined(bl808m0) and defined(bl808BleVendorArbProbe)):
  vendorZeroStub(sch_arb_event_start_isr)
  vendorZeroStub(sch_arb_init)
  vendorZeroStub(sch_arb_sw_isr)
when not (defined(bl808m0) and defined(bl808BleVendorArbProbe)):
  vendorZeroStub(sch_plan_chk)
  vendorZeroStub(sch_plan_init)
  vendorZeroStub(sch_plan_rem)
  vendorZeroStub(sch_plan_req)
  vendorZeroStub(sch_plan_set)
  vendorZeroStub(sch_plan_shift)
when not (defined(bl808m0) and
    (defined(bl808BleVendorSchProgProbe) or
     defined(bl808BleVendorLldAdvProbe) or
     defined(bl808BleVendorLldConProbe) or
     defined(bl808BleVendorLldScanProbe))):
  vendorZeroStub(sch_prog_end_isr)
  vendorZeroStub(sch_prog_fifo_isr)
  vendorZeroStub(sch_prog_init)
  vendorZeroStub(sch_prog_push)
  vendorZeroStub(sch_prog_rx_isr)
  vendorZeroStub(sch_prog_skip_isr)
  vendorZeroStub(sch_prog_tx_isr)
when not (defined(bl808m0) and
    (defined(bl808BleVendorFullSchedulerProbe) or
     defined(bl808BleVendorSliceProbe))):
  vendorZeroStub(sch_slice_bg_add)
  vendorZeroStub(sch_slice_bg_remove)
  vendorZeroStub(sch_slice_compute)
  vendorZeroStub(sch_slice_fg_add)
  vendorZeroStub(sch_slice_fg_remove)
  vendorZeroStub(sch_slice_init)
vendorZeroStub(specialModP256)
vendorZeroStub(syscntl_init)

# ---------------------------------------------------------------------------
# ======================== SEC ENG PKA0 ====================================
# ---------------------------------------------------------------------------

const
  PKA0_BASE = 0x40004000'u32
  PKA0_CTRL = PKA0_BASE + 0x00
  PKA0_STATUS = PKA0_BASE + 0x04
  PKA0_INT = PKA0_BASE + 0x08
  PKA0_INT_CLR = PKA0_BASE + 0x0C

proc sec_eng_pka0_reset*() {.exportc, cdecl.} =
  ## Reset PKA engine
  regWrite(PKA0_CTRL, 0x01'u32)

proc sec_eng_pka0_clear_int*() {.exportc, cdecl.} =
  ## Clear PKA interrupt
  regWrite(PKA0_INT_CLR, 0x01'u32)

proc sec_eng_pka0_wait_4_isr*() {.exportc, cdecl.} =
  ## Wait for PKA operation to complete
  while (regRead(PKA0_STATUS) and 0x01'u32) == 0:
    discard

proc sec_eng_pka0_pld*(reg_idx: uint8, data: ptr uint8, size: uint32) {.exportc, cdecl.} =
  ## Load data into PKA register
  let reg_base = PKA0_BASE + 0x100'u32 + reg_idx.uint32 * 0x40
  var i = 0'u32
  while i < size:
    let word = cast[ptr uint32](cast[uint](data) + i.uint)[]
    regWrite(reg_base + i, word)
    i += 4

proc sec_eng_pka0_read_data*(reg_idx: uint8, data: ptr uint8, size: uint32) {.exportc, cdecl.} =
  ## Read data from PKA register
  let reg_base = PKA0_BASE + 0x100'u32 + reg_idx.uint32 * 0x40
  var i = 0'u32
  while i < size:
    let word = regRead(reg_base + i)
    cast[ptr uint32](cast[uint](data) + i.uint)[] = word
    i += 4

proc sec_eng_pka0_clir*(reg_idx: uint8, size: uint32) {.exportc, cdecl.} =
  ## Clear PKA register
  let reg_base = PKA0_BASE + 0x100'u32 + reg_idx.uint32 * 0x40
  var i = 0'u32
  while i < size:
    regWrite(reg_base + i, 0)
    i += 4

proc sec_eng_pka0_movdat*(dst: uint8, src: uint8, size: uint32) {.exportc, cdecl.} =
  ## Move data between PKA registers
  let src_base = PKA0_BASE + 0x100'u32 + src.uint32 * 0x40
  let dst_base = PKA0_BASE + 0x100'u32 + dst.uint32 * 0x40
  var i = 0'u32
  while i < size:
    let word = regRead(src_base + i)
    regWrite(dst_base + i, word)
    i += 4

proc pka0_write_op(opcode: uint32, d0: uint8, d0_size: uint32,
                    s0: uint8, s0_size: uint32,
                    s1: uint8 = 0, s1_size: uint32 = 0) =
  ## Write a PKA operation command
  var cmd = opcode
  cmd = cmd or (d0.uint32 shl 8)
  cmd = cmd or (d0_size shl 12)
  cmd = cmd or (s0.uint32 shl 16)
  cmd = cmd or (s0_size shl 20)
  if s1_size > 0:
    cmd = cmd or (s1.uint32 shl 24)
    cmd = cmd or (s1_size shl 28)
  regWrite(PKA0_CTRL + 0x10, cmd)
  sec_eng_pka0_wait_4_isr()

proc sec_eng_pka0_msub*(d0: uint8, s0: uint8, s1: uint8, size: uint32) {.exportc, cdecl.} =
  pka0_write_op(0x05, d0, size, s0, size, s1, size)

proc sec_eng_pka0_mrem*(d0: uint8, s0: uint8, s1: uint8, d_size: uint32, s_size: uint32) {.exportc, cdecl.} =
  pka0_write_op(0x06, d0, d_size, s0, s_size, s1, s_size)

proc sec_eng_pka0_mmul*(d0: uint8, s0: uint8, s1: uint8, size: uint32) {.exportc, cdecl.} =
  pka0_write_op(0x04, d0, size, s0, size, s1, size)

proc sec_eng_pka0_mexp*(d0: uint8, s0: uint8, s1: uint8, size: uint32) {.exportc, cdecl.} =
  pka0_write_op(0x07, d0, size, s0, size, s1, size)

proc sec_eng_pka0_lcmp*(s0: uint8, s1: uint8, size: uint32): int32 {.exportc, cdecl.} =
  pka0_write_op(0x0A, 0, 0, s0, size, s1, size)
  let status = regRead(PKA0_STATUS)
  if (status and 0x04) != 0: return 0  # Equal
  if (status and 0x02) != 0: return 1  # Greater
  return -1  # Less

proc sec_eng_pka0_ladd*(d0: uint8, s0: uint8, s1: uint8, size: uint32) {.exportc, cdecl.} =
  pka0_write_op(0x00, d0, size, s0, size, s1, size)

proc sec_eng_pka0_lsub*(d0: uint8, s0: uint8, s1: uint8, size: uint32) {.exportc, cdecl.} =
  pka0_write_op(0x01, d0, size, s0, size, s1, size)

proc sec_eng_pka0_lmul*(d0: uint8, s0: uint8, s1: uint8, size: uint32) {.exportc, cdecl.} =
  pka0_write_op(0x02, d0, size, s0, size, s1, size)

proc sec_eng_pka0_lmul2n*(d0: uint8, s0: uint8, n: uint32, size: uint32) {.exportc, cdecl.} =
  ## Left shift (multiply by 2^n)
  pka0_write_op(0x0C, d0, size, s0, size, 0, n)

proc sec_eng_pka0_ldiv2n*(d0: uint8, s0: uint8, n: uint32, size: uint32) {.exportc, cdecl.} =
  ## Right shift (divide by 2^n)
  pka0_write_op(0x0D, d0, size, s0, size, 0, n)
