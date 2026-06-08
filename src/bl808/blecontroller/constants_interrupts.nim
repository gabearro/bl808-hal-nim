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

