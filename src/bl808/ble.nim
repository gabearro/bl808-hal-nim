## BL808 BLE 5.0 controller interface.
##
## The BL808 M0 core uses the BLE controller shared with BL602.
## Pure Nim controller implementation: src/bl808/blecontroller.nim.
##
## The BLE host stack uses a Zephyr BLE port with standard bt_* APIs.
## This module provides:
##   1. Controller-level init
##   2. HCI on-chip interface for host<->controller communication
##   3. Zephyr BLE host stack declarations (bt_enable, bt_le_adv_*, etc.)

# =============================================================================
# BLE Controller C API (from ble_lib_api.h, libblecontroller.a)
# =============================================================================
when defined(bl808m0):
  import core, irq, kernel/clock, kernel/cps, mmio, sec

  import blecontroller
  import blep256

  const bl808BleNimPureConnection* {.booldefine.}: bool = false
  const bl808BleNimPureCentral* {.booldefine.}: bool = false
  const bl808BleNimConnectionEnabled = bl808BleNimPureConnection

  type
    BleInitStageCb* = proc(stage: cstring) {.cdecl.}

  var bleControllerStarted: bool

  proc reportBleInitStage(stageCb: BleInitStageCb, stage: cstring) {.inline.} =
    if stageCb != nil:
      stageCb(stage)

  proc bleBackendPrepareControllerInit(stageCb: BleInitStageCb) =
    if stageCb != nil:
      discard

  proc bleBackendControllerInit(taskPriority: uint8,
                                stageCb: BleInitStageCb) =
    reportBleInitStage(stageCb, "before controller init")
    when defined(bl808BleDebugSplitControllerInit):
      discard taskPriority
      blecontroller.bflbip_init()
      reportBleInitStage(stageCb, "after bflbip_init")
      blecontroller.ble_ke_init()
      reportBleInitStage(stageCb, "after ble_ke_init")
      blecontroller.hci_init(false)
      reportBleInitStage(stageCb, "after hci_init")
      blecontroller.bflbble_init()
      reportBleInitStage(stageCb, "after bflbble_init")
      blecontroller.ecc_init()
      reportBleInitStage(stageCb, "after ecc_init")
      blecontroller.lld_sleep_init()
      reportBleInitStage(stageCb, "after lld_sleep_init")
      blecontroller.lld_evt_init()
      reportBleInitStage(stageCb, "after lld_evt_init")
      blecontroller.bdaddr_init()
      reportBleInitStage(stageCb, "after bdaddr_init")
      blecontroller.ble_controller_task_init(nil)
      blecontroller.bflbble_enable_runtime_irqs()
    else:
      blecontroller.ble_controller_init(taskPriority)
    reportBleInitStage(stageCb, "after controller init")

  proc bleControllerInitRawWithStage*(taskPriority: uint8,
                                      stageCb: BleInitStageCb) {.cdecl.} =
    ## Initialize BLE controller. `taskPriority` is the RTOS task priority.
    if bleControllerStarted:
      reportBleInitStage(stageCb, "already started")
      return
    bleBackendPrepareControllerInit(stageCb)
    bleBackendControllerInit(taskPriority, stageCb)
    bleControllerStarted = true

  proc bleControllerInitRaw*(taskPriority: uint8) {.cdecl.} =
    bleControllerInitRawWithStage(taskPriority, nil)

  proc blecontroller_main*() {.cdecl.} =
    ## BLE controller main loop (call from a dedicated task).
    blecontroller.blecontroller_main()

  proc ble_controller_get_lib_ver*(): cstring {.cdecl.} =
    ## Get BLE controller library version string.
    blecontroller.ble_controller_get_lib_ver()

  proc ble_controller_sleep*(maxSleepCycles: int32): int32 {.cdecl.} =
    ## Enter BLE sleep. Returns actual sleep cycles.
    blecontroller.ble_controller_sleep(maxSleepCycles)

  proc ble_controller_sleep_restore*() {.cdecl.} =
    ## Restore after BLE sleep.
    blecontroller.ble_controller_sleep_restore()

  proc ble_controller_set_tx_pwr*(bleTxPower: cint) {.cdecl.} =
    ## Set BLE TX power level.
    blecontroller.ble_controller_set_tx_pwr(bleTxPower)

  proc ble_controller_get_tx_pwr*(): int8 {.cdecl.} =
    blecontroller.ble_controller_get_tx_pwr()

  # --- HCI on-chip interface (host<->controller) ---
  const
    HciPktAclData = 1'u8

  type
    HciRecvCb* = proc(data: ptr uint8, len: uint16): uint8 {.cdecl.}
    HciQueuedEvent = object
      pktType: uint8
      len: uint16
      data: array[260, uint8]

  const HciQueuedEventCount = 8

  var hciRecvCb: HciRecvCb
  var hciLastPktType: uint8
  var hciLastLen: uint8
  var hciLastWord0: uint32
  var hciLastWord1: uint32
  var hciLastOpcode: uint16
  var hciLastStatus: int16 = -1
  var hciLastPayload: array[260, uint8]
  var hciRawSendBuf: array[258, uint8]
  var hciCommandSlot: blecontroller.OnChipHciCmd
  var hciCommandInFlight: bool
  var hciEventQueue: array[HciQueuedEventCount, HciQueuedEvent]
  var hciEventHead: uint8
  var hciEventTail: uint8
  var hciEventQueued: uint8
  var hciEventDropped: uint32
  var hciDispatchPktType: uint8
  var hciDispatchBuf: array[260, uint8]
  var hciDispatching: bool
  var ble_host_debug_stage* {.exportc.}: uint32
  var ble_host_debug_opcode* {.exportc.}: uint32
  var ble_host_debug_status* {.exportc.}: uint32
  var ble_host_debug_len* {.exportc.}: uint32
  var ble_host_debug_ptr* {.exportc.}: uint32
  var ble_central_debug_stage* {.exportc.}: uint32
  var ble_central_debug_timeout* {.exportc.}: uint32
  var ble_central_debug_waited* {.exportc.}: uint32
  var ble_central_debug_flags* {.exportc.}: uint32
  var ble_central_debug_create_count* {.exportc.}: uint32
  var ble_central_debug_create_result* {.exportc.}: uint32
  var ble_host_acl_rx_count* {.exportc.}: uint32
  var ble_host_acl_tx_count* {.exportc.}: uint32

  var ble_host_acl_tx_reject_count* {.exportc.}: uint32
  var ble_host_att_rx_count* {.exportc.}: uint32
  var ble_host_att_tx_count* {.exportc.}: uint32
  var ble_host_att_last_opcode* {.exportc.}: uint32
  var ble_host_att_last_status* {.exportc.}: uint32
  var ble_adv_host_debug_stage* {.exportc.}: uint32
  var ble_adv_host_debug_result* {.exportc.}: uint32
  var ble_adv_host_debug_detail* {.exportc.}: uint32
  var ble_hci_return_debug_sp* {.exportc.}: uint32
  var ble_hci_return_debug_result* {.exportc.}: uint32
  var ble_hci_return_debug_stack* {.exportc.}: array[12, uint32]

  template bleHostReadSp(): uint32 =
    block:
      var v: uint32
      {.emit: ["asm volatile(\"mv %0, sp\" : \"=r\"(", v, ") : : \"memory\");"].}
      v

  proc resetHciEventQueue() =
    hciEventHead = 0
    hciEventTail = 0
    hciEventQueued = 0
    hciEventDropped = 0
    hciDispatchPktType = 0
    hciDispatching = false

  proc enqueueHciHostEvent(pktType: uint8, srcId: uint16, param: ptr uint8,
                           paramLen: uint8): bool =
    if param == nil and paramLen != 0'u8:
      inc hciEventDropped
      return false
    if hciEventQueued >= HciQueuedEventCount.uint8:
      inc hciEventDropped
      return false

    let slotIdx = hciEventTail.int
    hciEventQueue[slotIdx].pktType = pktType
    var outLen = paramLen.uint16
    if param != nil:
      let raw = cast[ptr UncheckedArray[uint8]](param)
      case pktType
      of 4'u8:
        hciEventQueue[slotIdx].data[0] = 0x3E'u8
        hciEventQueue[slotIdx].data[1] = paramLen
        for i in 0 ..< paramLen.int:
          hciEventQueue[slotIdx].data[i + 2] = raw[i]
        outLen = paramLen.uint16 + 2'u16
      of 5'u8, 7'u8:
        hciEventQueue[slotIdx].data[0] = uint8(srcId and 0xFF)
        hciEventQueue[slotIdx].data[1] = paramLen
        for i in 0 ..< paramLen.int:
          hciEventQueue[slotIdx].data[i + 2] = raw[i]
        outLen = paramLen.uint16 + 2'u16
      else:
        for i in 0 ..< paramLen.int:
          hciEventQueue[slotIdx].data[i] = raw[i]
    hciEventQueue[slotIdx].len = outLen
    hciEventTail = uint8((hciEventTail.int + 1) mod HciQueuedEventCount)
    inc hciEventQueued
    true

  proc drainHciHostEvents() =
    if hciDispatching:
      return
    hciDispatching = true
    while hciEventQueued != 0'u8 and hciRecvCb != nil:
      let slotIdx = hciEventHead.int
      let pktType = hciEventQueue[slotIdx].pktType
      let cbLen = hciEventQueue[slotIdx].len
      for i in 0 ..< cbLen.int:
        hciDispatchBuf[i] = hciEventQueue[slotIdx].data[i]
      hciEventHead = uint8((hciEventHead.int + 1) mod HciQueuedEventCount)
      dec hciEventQueued
      hciDispatchPktType = pktType
      ble_host_debug_stage = 0x5010'u32
      let cbStatus = hciRecvCb(addr hciDispatchBuf[0], cbLen)
      ble_host_debug_status = cbStatus.uint32
      ble_host_debug_stage = 0x5011'u32
      hciDispatchPktType = 0
    hciDispatching = false

  proc bleHostBridge(pktType: uint8, srcId: uint16, param: ptr uint8,
                     paramLen: uint8) {.cdecl.} =
    hciLastPktType = pktType
    hciLastLen = paramLen
    hciLastWord0 = 0
    hciLastWord1 = 0
    hciLastOpcode = 0
    hciLastStatus = -1
    if param != nil:
      let raw = cast[ptr UncheckedArray[uint8]](param)
      for i in 0 ..< min(paramLen.int, hciLastPayload.len):
        hciLastPayload[i] = raw[i]
      for i in 0 ..< min(paramLen.int, 4):
        hciLastWord0 = hciLastWord0 or (raw[i].uint32 shl (i * 8))
      for i in 0 ..< min(max(paramLen.int - 4, 0), 4):
        hciLastWord1 = hciLastWord1 or (raw[i + 4].uint32 shl (i * 8))
      case pktType
      of 2'u8, 3'u8:
        hciLastOpcode = srcId
        if paramLen > 0:
          hciLastStatus = raw[0].int16
      of 4'u8:
        if paramLen >= 2:
          case raw[0]
          of 0x07'u8:
            hciLastOpcode = 0x2022'u16
            hciLastStatus = 0
          of 0x08'u8:
            hciLastOpcode = 0x2025'u16
            hciLastStatus = raw[1].int16
          of 0x09'u8:
            hciLastOpcode = 0x2026'u16
            hciLastStatus = raw[1].int16
          else:
            discard
      else:
        discard
      if paramLen >= 6 and raw[0] == 0x0E'u8:
        hciLastOpcode = raw[3].uint16 or (raw[4].uint16 shl 8)
        hciLastStatus = raw[5].int16
      elif paramLen >= 6 and raw[0] == 0x0F'u8:
        hciLastStatus = raw[3].int16
        hciLastOpcode = raw[4].uint16 or (raw[5].uint16 shl 8)
    if hciRecvCb != nil and pktType != 2'u8 and pktType != 3'u8:
      discard enqueueHciHostEvent(pktType, srcId, param, paramLen)
  proc bt_onchiphci_interface_init*(cb: HciRecvCb): uint8 {.cdecl.} =
    ## Initialize the on-chip HCI interface.
    ## `cb` is called when the controller sends data to the host.
    resetHciEventQueue()
    hciRecvCb = cb
    discard blecontroller.bt_onchiphci_interface_init(bleHostBridge)
    0

  proc bt_onchiphci_send*(pktType: uint8, destId: uint16,
                          pkt: pointer): int8 {.cdecl.} =
    ## Send an HCI packet from host to controller.
    ble_host_debug_stage = 0x5100'u32
    ble_host_debug_len = destId.uint32
    ble_host_debug_ptr = cast[uint32](cast[uint](pkt))
    if pktType == HciPktAclData:
      let rc = blecontroller.bt_onchiphci_send(pktType, destId, pkt)
      ble_host_debug_stage = 0x5110'u32
      ble_host_debug_status = cast[uint32](rc)
      ble_host_debug_stage = 0x5120'u32
      rc
    else:
      var ok = false
      if pkt != nil and destId >= 3'u16 and destId.int <= hciRawSendBuf.len:
        let src = cast[ptr UncheckedArray[uint8]](pkt)
        for i in 0 ..< destId.int:
          hciRawSendBuf[i] = src[i]
        ok = blecontroller.bt_onchiphci_send_raw(addr hciRawSendBuf[0],
                                                 destId)
      ble_host_debug_stage = 0x5110'u32
      ble_host_debug_status = if ok: 0'u32 else: 1'u32
      ble_host_debug_stage = 0x5120'u32
      if ok: 0'i8 else: -1'i8

  proc bleLastHciOpcode*(): uint16 {.cdecl.} =
    hciLastOpcode

  proc bleLastHciStatus*(): int16 {.cdecl.} =
    hciLastStatus

  proc bleLastHciPktType*(): uint8 {.cdecl.} =
    hciLastPktType

  proc bleLastHciLen*(): uint8 {.cdecl.} =
    hciLastLen

  proc bleLastHciWord0*(): uint32 {.cdecl.} =
    hciLastWord0

  proc bleLastHciWord1*(): uint32 {.cdecl.} =
    hciLastWord1

  # --- BLE controller internal symbols (for ISR hookup) ---
  proc bflbble_init*() {.cdecl.} =
    blecontroller.bflbble_init()

  proc bflbble_isr*() {.cdecl.} =
    ## BLE interrupt handler — call from the M0 BLE IRQ handler.
    blecontroller.bflbble_isr()

  proc bflbble_isr_clear*() {.cdecl.} =
    ## Clear pending BLE controller interrupt sources.
    blecontroller.bflbble_isr_clear()

  proc bflbble_reset*() {.cdecl.} =
    blecontroller.bflbble_reset()

  proc bflbble_enable_runtime_irqs*() {.cdecl.} =
    blecontroller.bflbble_enable_runtime_irqs()

  proc bflbble_sleep_check*(): cint {.cdecl.} =
    ## Check if BLE can sleep. Returns 1 if sleepable.
    if blecontroller.bflbble_sleep_check(): 1 else: 0

# =============================================================================
# Zephyr BLE Host Stack API (from blestack)
#
# The Bouffalo SDK ports the Zephyr BLE host stack.
# These are the standard Zephyr bt_* APIs.
# Link against the blestack library for these.
# =============================================================================
when defined(bl808m0):

  const
    BlePeripheralIdleDisconnectPolls {.intdefine.}: int = 0

  type
    BtReadyCb* = proc(err: cint) {.cdecl.}
      ## Callback when BLE is ready.

    BtAddrLe* = object
      addrType*: uint8
      a*: array[6, uint8]

    BtLeAdvParam* = object
      ## Advertising parameters.
      intervalMin*: uint16
      intervalMax*: uint16
      options*: uint32

    BtData* = object
      ## Advertising data element.
      dataType*: uint8
      dataLen*: uint8
      data*: pointer

    BtConn* = object
      handle*: uint16
      peer*: BtAddrLe
      role*: uint8
      status*: uint8

    BtConnConnectedCb* = proc(conn: ptr BtConn, err: uint8) {.cdecl.}
    BtConnDisconnectedCb* = proc(conn: ptr BtConn, reason: uint8) {.cdecl.}

    BtConnCb* = object
      ## Connection callbacks.
      connected*: BtConnConnectedCb
      disconnected*: BtConnDisconnectedCb

    BtLeScanParam* = object
      scanType*: uint8
      filterDup*: uint8
      interval*: uint16
      window*: uint16

    BtLeConnParam* = object
      intervalMin*: uint16
      intervalMax*: uint16
      latency*: uint16
      timeout*: uint16

    BtScanData* = object
      len*: uint8
      data*: array[31, uint8]

    BtLeScanCb* = proc(peer: ptr BtAddrLe, rssi: int8,
                       evtype: uint8, data: ptr BtScanData) {.cdecl.}

  var
    bleHostEnabled: bool
    bleReadyCbPending: BtReadyCb
    bleNameStorage: array[32, char]
    bleConnCb: ptr BtConnCb
    bleScanCb: BtLeScanCb
    bleScanActive: bool
    bleAdvActive: bool
    bleScanData: BtScanData
    bleConn: BtConn
    bleConnActive: bool
    bleConnPending: bool
    bleConnConnectedNotified: bool
    bleCentralTargetName: array[32, char]
    bleCentralTargetActive: bool
    bleCentralAcceptAnyReport: bool
    bleCentralPeerFound: bool
    bleCentralPeer: BtAddrLe
    bleCentralConnected: bool
    blePeripheralConnEventsSeen: uint32
    blePeripheralDiscEventsSeen: uint32
    blePeripheralConnectedNotified: bool
    blePeripheralDisconnectedNotified: bool
    blePeripheralLastRxEventCounter: uint32
    blePeripheralIdlePolls: uint32
    blePeripheralConnectFuture: CpsFuture[ptr BtConn]
    blePeripheralConnectTimer: TimerId
    blePeripheralDisconnectFuture: CpsFuture[uint8]
    blePeripheralDisconnectTimer: TimerId
    bleScanReportCounter: uint32
    bleScanNameMatchCounter: uint32
    bleScanLastEventType: uint8
    bleScanLastAddrType: uint8
    bleScanLastRssiRaw: uint8
    bleScanLastDataLen: uint8
    bleScanLastAddr: array[6, uint8]
    bleScanLastData: array[31, uint8]
    bleScanMatchedEventType: uint8
    bleScanMatchedAddrType: uint8
    bleScanMatchedDataLen: uint8
    bleScanMatchedAddr: array[6, uint8]
    bleScanMatchedData: array[31, uint8]
    bleStaticRandomIdentity: array[6, uint8]
    bleStaticRandomIdentityConfigured: bool

  const
    bl808BleUseRandomAddr* {.booldefine.}: bool = false
    bl808BleUseStaticRandomIdentity* {.booldefine.}: bool = true
    BleUseRandomIdentity =
      bl808BleUseStaticRandomIdentity or bl808BleUseRandomAddr
    HciOpReadBufferSize = 0x1005'u16
    HciOpReset = 0x0C03'u16
    HciOpDisconnect = 0x0406'u16
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
    HciOpLeEncrypt = 0x2017'u16
    HciOpLeRand = 0x2018'u16
    HciOpLeSetDataLen = 0x2022'u16
    HciOpLeReadSuggestedDefaultDataLen = 0x2023'u16
    HciOpLeWriteSuggestedDefaultDataLen = 0x2024'u16
    HciOpLeReadLocalP256PublicKey = 0x2025'u16
    HciOpLeGenerateDhKey = 0x2026'u16
    HciOpLeReadMaximumDataLen = 0x202F'u16
    HciEvtDisconnectComplete = 0x05'u8
    HciEvtLeMeta = 0x3E'u8
    HciLeEvtConnectionComplete = 0x01'u8
    HciLeEvtAdvertisingReport = 0x02'u8
    HciLeEvtDataLengthChange = 0x07'u8
    HciLeEvtReadLocalP256PublicKeyComplete = 0x08'u8
    HciLeEvtGenerateDhKeyComplete = 0x09'u8
    HciLeEvtEnhancedConnectionComplete = 0x0A'u8
    HciLeFeatureExtendedReject = 1'u8 shl 2
    HciLeFeatureLePing = 1'u8 shl 4
    HciLeFeatureDataPacketLengthExtension = 1'u8 shl 5
    HciLeFeatureChannelSelectionAlgorithm2 = 1'u8 shl 6
    HciLeDefaultDataOctets = 0x001B'u16
    HciLeDefaultDataTime = 0x0148'u16
    BleMaxLegacyAdvDataLen = 31
    BleHciLegacyDataParamLen = 32
    P256DebugPeerPublicKeyLe: array[64, uint8] = [
      0xE6'u8, 0x9D, 0x35, 0x0E, 0x48, 0x01, 0x03, 0xCC,
      0xDB, 0xFD, 0xF4, 0xAC, 0x11, 0x91, 0xF4, 0xEF,
      0xB9, 0xA5, 0xF9, 0xE9, 0xA7, 0x83, 0x2C, 0x5E,
      0x2C, 0xBE, 0x97, 0xF2, 0xD2, 0x03, 0xB0, 0x20,
      0x8B, 0xD2, 0x89, 0x15, 0xD0, 0x8E, 0x1C, 0x74,
      0x24, 0x30, 0xED, 0x8F, 0xC2, 0x45, 0x63, 0x76,
      0x5C, 0x15, 0x52, 0x5A, 0xBF, 0x9A, 0x32, 0x63,
      0x6D, 0xEB, 0x2A, 0x65, 0x49, 0x9C, 0x80, 0xDC
    ]
    BleAdTypeFlags = 0x01'u8
    BleAdTypeShortName = 0x08'u8
    BleAdTypeCompleteName = 0x09'u8
    BleAdFlagsGeneralDiscoverable = 0x02'u8
    BleAdFlagsBrEdrNotSupported = 0x04'u8
    BleDefaultAdvInterval = 0x00A0'u16
    BleMinAdvInterval = 0x0020'u16
    BleCentralDiscoveryScanInterval = 0x0060'u16
    BleCentralDiscoveryScanWindow = 0x0030'u16
    BleCentralConnectScanInterval = 0x0060'u16
    BleCentralConnectScanWindow = 0x0060'u16
    BleCentralDiscoveryActiveScan {.booldefine.}: bool = true
    BleCentralPollIterations {.intdefine.}: int = 8
    # Name-based central connects resolve a device from advertising reports.  A
    # bounded per-address attempt lets peers that rotate private addresses be
    # rediscovered instead of pinning the whole user timeout to a stale address.
    BleCentralConnectAttemptMs {.intdefine.}: int = 5_000
    # Name-based discovery resolves an advertising address, not a durable peer
    # identity.  After an initiator timeout, rediscover by name instead of
    # retrying the same address so private-address rotation and macOS advertising
    # restarts cannot pin the central loop to a stale target.
    BleCentralPeerConnectRetries {.intdefine.}: int = 0
    BleCentralPostScanDrainPolls {.intdefine.}: int = 2
    bl808BleCentralScanRestartMs* {.intdefine.}: int = 500
    bl808BleNimSyntheticCentral* {.booldefine.}: bool = false
    HciAclPbFirstNonFlush = 0x02'u8
    L2capCidAtt = 0x0004'u16
    L2capCidLeSignaling = 0x0005'u16
    AttLocalMtu = 23'u16
    AttOpErrorRsp = 0x01'u8
    AttOpExchangeMtuReq = 0x02'u8
    AttOpExchangeMtuRsp = 0x03'u8
    AttOpFindInfoReq = 0x04'u8
    AttOpFindInfoRsp = 0x05'u8
    AttOpReadByTypeReq = 0x08'u8
    AttOpReadByTypeRsp = 0x09'u8
    AttOpReadReq = 0x0A'u8
    AttOpReadRsp = 0x0B'u8
    AttOpReadBlobReq = 0x0C'u8
    AttOpReadBlobRsp = 0x0D'u8
    AttOpReadByGroupTypeReq = 0x10'u8
    AttOpReadByGroupTypeRsp = 0x11'u8
    AttErrInvalidHandle = 0x01'u8
    AttErrReadNotPermitted = 0x02'u8
    AttErrInvalidPdu = 0x04'u8
    AttErrRequestNotSupported = 0x06'u8
    AttErrAttributeNotFound = 0x0A'u8
    GattUuidPrimaryService = 0x2800'u16
    GattUuidCharacteristic = 0x2803'u16
    GattUuidGenericAccess = 0x1800'u16
    GattUuidGenericAttribute = 0x1801'u16
    GattUuidDeviceName = 0x2A00'u16
    GattHandleGapService = 0x0001'u16
    GattHandleDeviceNameDecl = 0x0002'u16
    GattHandleDeviceNameValue = 0x0003'u16
    GattHandleGattService = 0x0004'u16
    GattDeviceNameProperties = 0x02'u8

  proc copyBleName(name: cstring) =
    for i in 0 ..< bleNameStorage.len:
      bleNameStorage[i] = '\0'
    if name == nil:
      return
    let src = cast[ptr UncheckedArray[char]](name)
    var i = 0
    while i < bleNameStorage.len - 1 and src[i] != '\0':
      bleNameStorage[i] = src[i]
      i.inc

  proc resetHciLast() =
    hciLastOpcode = 0
    hciLastStatus = -1
    hciLastPktType = 0
    hciLastLen = 0
    hciLastWord0 = 0
    hciLastWord1 = 0
    for i in 0 ..< hciLastPayload.len:
      hciLastPayload[i] = 0

  proc hciCommandOk(opcode: uint16, params: ptr uint8,
                    paramLen: uint8, polls: int = 64): bool =
    ble_host_debug_stage = 0x5200'u32
    ble_host_debug_opcode = opcode.uint32
    ble_host_debug_len = paramLen.uint32
    ble_host_debug_ptr = cast[uint32](cast[uint](params))
    discard polls
    if hciCommandInFlight:
      return false
    hciCommandInFlight = true
    defer:
      hciCommandInFlight = false
    resetHciLast()
    ble_host_debug_stage = 0x5210'u32
    hciCommandSlot.opcode = opcode
    hciCommandSlot.params = params
    hciCommandSlot.paramLen = paramLen
    let sendRc =
      blecontroller.bt_onchiphci_send(0'u8, 0'u16, addr hciCommandSlot)
    ble_host_debug_stage = 0x5220'u32
    ble_host_debug_status = cast[uint32](sendRc)
    let expectedOpcode = opcode
    if sendRc != 0:
      return false
    result = hciLastOpcode == expectedOpcode and hciLastStatus == 0
    ble_host_debug_stage = 0x5230'u32
    ble_host_debug_status =
      (uint32(hciLastOpcode) shl 16) or
      (cast[uint32](hciLastStatus) and 0xFFFF'u32)
    ble_hci_return_debug_sp = bleHostReadSp()
    ble_hci_return_debug_result = if result: 1'u32 else: 0'u32
    for i in 0 ..< ble_hci_return_debug_stack.len:
      ble_hci_return_debug_stack[i] =
        regRead((ble_hci_return_debug_sp + uint32(i * 4)).uint)
    ble_host_debug_stage = 0x5231'u32
  proc bleLeEncryptSelfTest*(): bool {.cdecl.} =
    var params: array[32, uint8]
    const
      key = [
        0x00'u8, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
        0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F
      ]
      plaintext = [
        0x00'u8, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
        0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF
      ]
      ciphertext = [
        0x69'u8, 0xC4, 0xE0, 0xD8, 0x6A, 0x7B, 0x04, 0x30,
        0xD8, 0xCD, 0xB7, 0x80, 0x70, 0xB4, 0xC5, 0x5A
      ]
    for i in 0 ..< 16:
      params[i] = key[i]
      params[16 + i] = plaintext[i]
    if not hciCommandOk(HciOpLeEncrypt, addr params[0], params.len.uint8):
      return false
    if hciLastLen != 17'u8 or hciLastStatus != 0:
      return false
    for i in 0 ..< 16:
      if hciLastPayload[1 + i] != ciphertext[i]:
        return false
    true

  proc bleLeRandSelfTest*(): bool {.cdecl.} =
    if not hciCommandOk(HciOpLeRand, nil, 0):
      return false
    if hciLastLen != 9'u8 or hciLastStatus != 0:
      return false
    var first: array[8, uint8]
    var firstAllZero = true
    for i in 0 ..< first.len:
      first[i] = hciLastPayload[1 + i]
      if first[i] != 0'u8:
        firstAllZero = false
    if firstAllZero:
      return false

    if not hciCommandOk(HciOpLeRand, nil, 0):
      return false
    if hciLastLen != 9'u8 or hciLastStatus != 0:
      return false
    var secondAllZero = true
    var same = true
    for i in 0 ..< first.len:
      let b = hciLastPayload[1 + i]
      if b != 0'u8:
        secondAllZero = false
      if b != first[i]:
        same = false
    (not secondAllZero) and (not same)

  proc bleLeP256SelfTest*(): bool {.cdecl.} =
    if not hciCommandOk(HciOpLeReadLocalP256PublicKey, nil, 0):
      return false
    if hciLastLen != 66'u8 or hciLastPayload[0] !=
        HciLeEvtReadLocalP256PublicKeyComplete or hciLastStatus != 0:
      return false
    if not bleP256IsValidPublicKeyLe(addr hciLastPayload[2],
                                     addr hciLastPayload[34]):
      return false

    if not hciCommandOk(HciOpLeGenerateDhKey,
                        unsafeAddr P256DebugPeerPublicKeyLe[0],
                        P256DebugPeerPublicKeyLe.len.uint8):
      return false
    if hciLastLen != 34'u8 or hciLastPayload[0] !=
        HciLeEvtGenerateDhKeyComplete or hciLastStatus != 0:
      return false
    var allZero = true
    for i in 0 ..< 32:
      if hciLastPayload[2 + i] != 0'u8:
        allZero = false
    not allZero

  proc hciLastPayloadLe16(off: int): uint16 =
    hciLastPayload[off].uint16 or (hciLastPayload[off + 1].uint16 shl 8)

  proc bleLeBufferSizeSelfTest*(): bool {.cdecl.} =
    if not hciCommandOk(HciOpReadBufferSize, nil, 0):
      return false
    if hciLastLen != 8'u8 or hciLastStatus != 0:
      return false
    if hciLastPayloadLe16(1) != HciLeDefaultDataOctets or
        hciLastPayload[3] != 0'u8 or
        hciLastPayloadLe16(4) != 1'u16 or
        hciLastPayloadLe16(6) != 0'u16:
      return false

    if not hciCommandOk(HciOpLeReadBufferSize, nil, 0):
      return false
    hciLastLen == 4'u8 and hciLastStatus == 0 and
      hciLastPayloadLe16(1) == HciLeDefaultDataOctets and
      hciLastPayload[3] == 1'u8

  proc bleLeLocalFeaturesSelfTest*(): bool {.cdecl.} =
    if not hciCommandOk(HciOpLeReadLocalSupportedFeatures, nil, 0):
      return false
    if hciLastLen != 9'u8 or hciLastStatus != 0:
      return false
    if (hciLastPayload[1] and HciLeFeatureExtendedReject) == 0'u8:
      return false
    if (hciLastPayload[1] and
        (HciLeFeatureLePing or HciLeFeatureDataPacketLengthExtension)) != 0'u8:
      return false
    when blecontroller.bl808BleNimPeripheralChSel2:
      if (hciLastPayload[2] and HciLeFeatureChannelSelectionAlgorithm2) == 0'u8:
        return false
    true

  proc bleLeDataLengthSelfTest*(): bool {.cdecl.} =
    if not hciCommandOk(HciOpLeReadMaximumDataLen, nil, 0):
      return false
    if hciLastLen != 9'u8 or hciLastStatus != 0:
      return false
    if hciLastPayloadLe16(1) != HciLeDefaultDataOctets or
        hciLastPayloadLe16(3) != HciLeDefaultDataTime or
        hciLastPayloadLe16(5) != HciLeDefaultDataOctets or
        hciLastPayloadLe16(7) != HciLeDefaultDataTime:
      return false

    if not hciCommandOk(HciOpLeReadSuggestedDefaultDataLen, nil, 0):
      return false
    if hciLastLen != 5'u8 or hciLastStatus != 0:
      return false
    if hciLastPayloadLe16(1) != HciLeDefaultDataOctets or
        hciLastPayloadLe16(3) != HciLeDefaultDataTime:
      return false

    var params: array[4, uint8]
    params[0] = uint8(HciLeDefaultDataOctets and 0x00FF'u16)
    params[1] = uint8((HciLeDefaultDataOctets shr 8) and 0x00FF'u16)
    params[2] = uint8(HciLeDefaultDataTime and 0x00FF'u16)
    params[3] = uint8((HciLeDefaultDataTime shr 8) and 0x00FF'u16)
    hciCommandOk(HciOpLeWriteSuggestedDefaultDataLen, addr params[0],
                 params.len.uint8)

  proc staticRandomIdentityPayloadValid(identity: array[6, uint8]): bool =
    var allZero = true
    var allOne = true
    for i in 0 ..< 5:
      if identity[i] != 0'u8:
        allZero = false
      if identity[i] != 0xFF'u8:
        allOne = false
    let randomMsbs = identity[5] and 0x3F'u8
    if randomMsbs != 0'u8:
      allZero = false
    if randomMsbs != 0x3F'u8:
      allOne = false
    (not allZero) and (not allOne)

  proc generateStaticRandomIdentity(): bool =
    var words: array[8, uint32]
    for attempt in 0 ..< 4:
      discard attempt
      if sec.trngReadAll(words) != sec.secOk:
        return false
      for i in 0 ..< bleStaticRandomIdentity.len:
        let word = words[i div 4]
        bleStaticRandomIdentity[i] =
          uint8((word shr ((i mod 4) * 8)) and 0xFF'u32)
      bleStaticRandomIdentity[5] =
        (bleStaticRandomIdentity[5] and 0x3F'u8) or 0xC0'u8
      if staticRandomIdentityPayloadValid(bleStaticRandomIdentity):
        bleStaticRandomIdentityConfigured = true
        return true
    false

  proc configureRandomAddress(): bool =
    when BleUseRandomIdentity:
      if not bleStaticRandomIdentityConfigured:
        if not generateStaticRandomIdentity():
          return false
      hciCommandOk(HciOpLeSetRandomAddress,
                   addr bleStaticRandomIdentity[0],
                   bleStaticRandomIdentity.len.uint8)
    else:
      true

  proc copyAddr(dst: var BtAddrLe, addrType: uint8,
                src: ptr UncheckedArray[uint8], offset: int) =
    dst.addrType = addrType
    for i in 0 ..< dst.a.len:
      dst.a[i] = src[offset + i]

  proc cstringMatchesBytes(name: ptr UncheckedArray[char],
                           data: ptr UncheckedArray[uint8],
                           dataLen: int): bool =
    var nameLen = 0
    while nameLen < 31 and name[nameLen] != '\0':
      inc nameLen
    if nameLen == 0 or nameLen != dataLen:
      return false
    for i in 0 ..< nameLen:
      if uint8(name[i]) != data[i]:
        return false
    true

  proc advertisingNameMatches(data: ptr UncheckedArray[uint8],
                              dataLen: int): bool =
    if not bleCentralTargetActive:
      return false
    if bleCentralAcceptAnyReport:
      return true
    let target = cast[ptr UncheckedArray[char]](addr bleCentralTargetName[0])
    var pos = 0
    while pos < dataLen:
      let fieldLen = data[pos].int
      if fieldLen == 0:
        break
      if pos + 1 + fieldLen > dataLen:
        break
      let dataType = data[pos + 1]
      let valueLen = fieldLen - 1
      if (dataType == 0x08'u8 or dataType == 0x09'u8) and
          cstringMatchesBytes(target,
                              cast[ptr UncheckedArray[uint8]](
                                cast[uint](data) + uint(pos + 2)),
                              valueLen):
        return true
      pos += 1 + fieldLen
    false

  proc appendAdStructure(payload: var array[BleHciLegacyDataParamLen, uint8],
                         pos: var int, dataType: uint8, data: pointer,
                         dataLen: int): bool =
    if dataLen < 0 or dataLen > BleMaxLegacyAdvDataLen - 1:
      return false
    if dataLen > 0 and data == nil:
      return false
    if pos + dataLen + 2 > payload.len:
      return false
    payload[pos] = uint8(dataLen + 1)
    inc pos
    payload[pos] = dataType
    inc pos
    if dataLen > 0:
      let raw = cast[ptr UncheckedArray[uint8]](data)
      for i in 0 ..< dataLen:
        payload[pos] = raw[i]
        inc pos
    true

  proc appendAdByte(payload: var array[BleHciLegacyDataParamLen, uint8],
                    pos: var int, dataType, value: uint8): bool =
    var data = value
    appendAdStructure(payload, pos, dataType, addr data, 1)

  proc appendAdName(payload: var array[BleHciLegacyDataParamLen, uint8],
                    pos: var int, completeOnly: bool = false): bool =
    let name = cast[ptr UncheckedArray[uint8]](addr bleNameStorage[0])
    var nameLen = 0
    while nameLen < bleNameStorage.len - 1 and name[nameLen] != 0:
      inc nameLen
    if nameLen == 0:
      return true
    let room = payload.len - pos - 2
    if room <= 0:
      return completeOnly == false
    let copyLen = if nameLen > room: room else: nameLen
    if completeOnly and copyLen != nameLen:
      return false
    let dataType =
      if copyLen == nameLen: BleAdTypeCompleteName else: BleAdTypeShortName
    appendAdStructure(payload, pos, dataType, addr name[0], copyLen)

  proc encodeBtData(payload: var array[BleHciLegacyDataParamLen, uint8],
                    data: ptr BtData, dataCount: csize_t): bool =
    for i in 0 ..< payload.len:
      payload[i] = 0
    if dataCount > csize_t(BleMaxLegacyAdvDataLen):
      return false
    var pos = 1
    if dataCount != 0:
      if data == nil:
        return false
      let items = cast[ptr UncheckedArray[BtData]](data)
      for i in 0 ..< dataCount.int:
        if not appendAdStructure(payload, pos, items[i].dataType,
                                 items[i].data, items[i].dataLen.int):
          return false
    payload[0] = uint8(pos - 1)
    true

  proc encodeDefaultAdvData(
      payload: var array[BleHciLegacyDataParamLen, uint8]): bool =
    for i in 0 ..< payload.len:
      payload[i] = 0
    var pos = 1
    if not appendAdByte(payload, pos, BleAdTypeFlags,
                        BleAdFlagsGeneralDiscoverable or
                        BleAdFlagsBrEdrNotSupported):
      return false
    payload[0] = uint8(pos - 1)
    true

  proc encodeDefaultScanRspData(
      payload: var array[BleHciLegacyDataParamLen, uint8]): bool =
    for i in 0 ..< payload.len:
      payload[i] = 0
    var pos = 1
    if not appendAdName(payload, pos, completeOnly = true):
      return false
    payload[0] = uint8(pos - 1)
    true

  proc encodeDefaultAdvAndScanRspData(
      advPayload: var array[BleHciLegacyDataParamLen, uint8],
      scanRsp: var array[BleHciLegacyDataParamLen, uint8]): bool =
    for i in 0 ..< advPayload.len:
      advPayload[i] = 0
    for i in 0 ..< scanRsp.len:
      scanRsp[i] = 0

    var advPos = 1
    if not appendAdByte(advPayload, advPos, BleAdTypeFlags,
                        BleAdFlagsGeneralDiscoverable or
                        BleAdFlagsBrEdrNotSupported):
      return false

    if appendAdName(advPayload, advPos, completeOnly = true):
      scanRsp[0] = 0
    else:
      if not appendAdName(advPayload, advPos):
        return false
      var scanPos = 1
      if not appendAdName(scanRsp, scanPos):
        return false
      scanRsp[0] = uint8(scanPos - 1)

    advPayload[0] = uint8(advPos - 1)
    true

  proc advIntervalOrDefault(value: uint16): uint16 {.inline.} =
    if value == 0'u16:
      BleDefaultAdvInterval
    elif value < BleMinAdvInterval:
      BleMinAdvInterval
    else:
      value

  proc cancelBleTimer(timerId: var TimerId) =
    if timerId != 0'u32:
      cancelTimer(timerId)
      timerId = 0'u32

  proc completeBlePeripheralConnected(conn: ptr BtConn) =
    if blePeripheralConnectFuture != nil and
        not blePeripheralConnectFuture.finished:
      complete(blePeripheralConnectFuture, conn)
    cancelBleTimer(blePeripheralConnectTimer)
    blePeripheralConnectFuture = nil

  proc failBlePeripheralConnected(message: string) =
    if blePeripheralConnectFuture != nil and
        not blePeripheralConnectFuture.finished:
      fail(blePeripheralConnectFuture, newException(TimeoutError, message))
    cancelBleTimer(blePeripheralConnectTimer)
    blePeripheralConnectFuture = nil

  proc completeBlePeripheralDisconnected(reason: uint8) =
    if blePeripheralDisconnectFuture != nil and
        not blePeripheralDisconnectFuture.finished:
      complete(blePeripheralDisconnectFuture, reason)
    cancelBleTimer(blePeripheralDisconnectTimer)
    blePeripheralDisconnectFuture = nil

  proc failBlePeripheralDisconnected(message: string) =
    if blePeripheralDisconnectFuture != nil and
        not blePeripheralDisconnectFuture.finished:
      fail(blePeripheralDisconnectFuture, newException(TimeoutError, message))
    cancelBleTimer(blePeripheralDisconnectTimer)
    blePeripheralDisconnectFuture = nil

  proc notifyConnected(err: uint8) =
    bleConnConnectedNotified = true
    if err == 0:
      blePeripheralDisconnectedNotified = false
    if err == 0:
      completeBlePeripheralConnected(addr bleConn)
    else:
      failBlePeripheralConnected("BLE peripheral connect failed")
    if bleConnCb != nil and bleConnCb.connected != nil:
      bleConnCb.connected(addr bleConn, err)

  proc notifyDisconnected(reason: uint8) =
    completeBlePeripheralDisconnected(reason)
    if blePeripheralDisconnectedNotified:
      return
    blePeripheralDisconnectedNotified = true
    blePeripheralConnectedNotified = false
    if bleConnCb != nil and bleConnCb.disconnected != nil:
      bleConnCb.disconnected(addr bleConn, reason)

  proc notifyPeripheralConnectedFromController() =
    when bl808BleNimConnectionEnabled:
      let handle = blecontroller.bleNimPeripheralConnHandle()
      let peerA0 = blecontroller.bleNimPeripheralConnPeerA0()
      let peerA1 = blecontroller.bleNimPeripheralConnPeerA1()
      bleConn.handle =
        if handle == 0'u32: 1'u16 else: uint16(handle and 0xFFFF'u32)
      bleConn.status = 0
      bleConn.role = 1'u8
      bleConn.peer.addrType =
        uint8(blecontroller.bleNimPeripheralConnPeerType() and 0xFF'u32)
      bleConn.peer.a[0] = uint8(peerA0 and 0xFF'u32)
      bleConn.peer.a[1] = uint8((peerA0 shr 8) and 0xFF'u32)
      bleConn.peer.a[2] = uint8((peerA0 shr 16) and 0xFF'u32)
      bleConn.peer.a[3] = uint8((peerA0 shr 24) and 0xFF'u32)
      bleConn.peer.a[4] = uint8(peerA1 and 0xFF'u32)
      bleConn.peer.a[5] = uint8((peerA1 shr 8) and 0xFF'u32)
      bleConnPending = false
      bleConnActive = true
      bleAdvActive = false
      bleCentralConnected = false
      blePeripheralLastRxEventCounter =
        blecontroller.bleNimPeripheralLastRxEventCounter()
      blePeripheralIdlePolls = 0
      blePeripheralConnectedNotified = true
      blePeripheralDisconnectedNotified = false
      notifyConnected(0)

  proc bleBackendPollPeripheralEvents() =
    when bl808BleNimConnectionEnabled:
      let connEvents = blecontroller.bleNimPeripheralConnEventCount()
      var newConnEvent = false
      if connEvents != blePeripheralConnEventsSeen:
        blePeripheralConnEventsSeen = connEvents
        newConnEvent = true
      if newConnEvent and not blePeripheralConnectedNotified:
        notifyPeripheralConnectedFromController()

      let discEvents = blecontroller.bleNimPeripheralDiscEventCount()
      if discEvents != blePeripheralDiscEventsSeen:
        blePeripheralDiscEventsSeen = discEvents
        let reason =
          uint8(blecontroller.bleNimPeripheralDiscReason() and 0xFF'u32)
        bleConnActive = false
        bleConnPending = false
        bleConnConnectedNotified = false
        bleCentralConnected = false
        blePeripheralIdlePolls = 0
        notifyDisconnected(reason)
      elif bleConnActive and bleConn.role == 1'u8:
        when BlePeripheralIdleDisconnectPolls > 0:
          let rxEventCounter =
            blecontroller.bleNimPeripheralLastRxEventCounter()
          if rxEventCounter != blePeripheralLastRxEventCounter:
            blePeripheralLastRxEventCounter = rxEventCounter
            blePeripheralIdlePolls = 0
          elif blePeripheralIdlePolls <
              uint32(BlePeripheralIdleDisconnectPolls):
            inc blePeripheralIdlePolls
          else:
            bleConnActive = false
            bleConnPending = false
            bleConnConnectedNotified = false
            bleCentralConnected = false
            blecontroller.bleNimPeripheralIdleDisconnect(0x13'u8)
            blePeripheralDiscEventsSeen =
              blecontroller.bleNimPeripheralDiscEventCount()
            blePeripheralIdlePolls = 0
            notifyDisconnected(0x13'u8)
      else:
        discard

  proc blePollHostEvents*() {.cdecl.} =
    ## Drain controller-side Nim peripheral link events into the host callback
    ## API. Vendor firmware reports these through HCI; the Nim/vendor-LLD
    ## bridge records them in controller counters to avoid re-entering the HCI
    ## callback chain from the low-level connection-start path.
    drainHciHostEvents()
    bleBackendPollPeripheralEvents()

  proc bleBackendServicePump() {.inline.} =
    blecontroller.bflbble_isr()
    when bl808BleNimPureCentral:
      blecontroller.bleControllerDrainScanReports()
    drainHciHostEvents()
    blecontroller.bflbip_schedule()
    when bl808BleNimPureCentral:
      blecontroller.bleControllerServiceScan()
      blecontroller.bleControllerDrainScanReports()
    drainHciHostEvents()
    blePollHostEvents()

  proc bleHostServicePump*() {.cdecl.} =
    ## One bounded BLE host/control-plane service step. This deliberately does
    ## not replace BTBLE event scheduling or descriptor programming; it only
    ## drains controller work into host-visible state.
    if not bleControllerStarted and not bleHostEnabled:
      return
    bleBackendServicePump()

  proc bleHostServiceTask*(periodUs: uint32 = 1000'u32,
                           iterations: uint32 = 8'u32): CpsVoidFuture {.cps.} =
    ## CPS-owned BLE host service. Hard radio timing remains in the
    ## controller callbacks; this task replaces ad hoc app polling loops.
    let delay =
      if periodUs == 0'u32: 1'u32 else: periodUs
    let count =
      if iterations == 0'u32: 1'u32 else: iterations
    while true:
      for _ in 0'u32 ..< count:
        bleHostServicePump()
      await sleepUs(delay.uint64)

  var
    bleHostServiceHookInstalled: bool
    bleHostServiceHookPeriodTicks: uint64 = usToTicks(1000'u64)
    bleHostServiceHookIterations: uint32 = 8'u32

  proc bleHostServicePollHook(now: uint64): uint64 =
    let count =
      if bleHostServiceHookIterations == 0'u32: 1'u32
      else: bleHostServiceHookIterations
    for _ in 0'u32 ..< count:
      bleHostServicePump()
    now + bleHostServiceHookPeriodTicks

  proc bleConfigureHostServiceHook*(periodUs: uint32 = 1000'u32,
                                    iterations: uint32 = 8'u32) =
    bleHostServiceHookPeriodTicks =
      if periodUs == 0'u32: 1'u64 else: usToTicks(periodUs.uint64)
    bleHostServiceHookIterations =
      if iterations == 0'u32: 1'u32 else: iterations

  proc bleInstallHostServiceHook*(periodUs: uint32 = 1000'u32,
                                  iterations: uint32 = 8'u32) =
    ## Install the high-frequency BLE host pump as a scheduler poll hook.
    ## Event waits remain CPS futures; the pump itself must not allocate per
    ## tick when WiFi and BLE are both active.
    bleConfigureHostServiceHook(periodUs, iterations)
    if not bleHostServiceHookInstalled:
      bleHostServiceHookInstalled =
        addSchedulerTimedPollHook(bleHostServicePollHook, readTick())

  proc handleDisconnectionComplete(raw: ptr UncheckedArray[uint8],
                                   len: int) =
    if len < 6:
      return
    let status = raw[2]
    let handle = raw[3].uint16 or (raw[4].uint16 shl 8)
    let reason = raw[5]
    if status == 0 and handle == bleConn.handle:
      bleConnActive = false
      bleConnPending = false
      bleConnConnectedNotified = false
      notifyDisconnected(reason)

  proc handleLeConnectionComplete(raw: ptr UncheckedArray[uint8],
                                  len: int) =
    if len < 21:
      return
    let status = raw[3]
    bleConn.status = status
    bleConn.handle = raw[4].uint16 or (raw[5].uint16 shl 8)
    bleConn.role = raw[6]
    copyAddr(bleConn.peer, raw[7], raw, 8)
    bleConnPending = false
    if status == 0:
      bleConnActive = true
      bleAdvActive = false
      bleCentralConnected = true
    notifyConnected(status)

  proc handleLeAdvertisingReport(raw: ptr UncheckedArray[uint8],
                                 len: int) =
    if len < 4:
      return
    var offset = 4
    let reports = raw[3].int
    for _ in 0 ..< reports:
      if offset + 9 > len:
        return
      let evtype = raw[offset]
      let addrType = raw[offset + 1]
      let dataLen = raw[offset + 8].int
      if offset + 9 + dataLen >= len:
        return
      var peer: BtAddrLe
      copyAddr(peer, addrType, raw, offset + 2)

      let payload = cast[ptr UncheckedArray[uint8]](
        cast[uint](raw) + uint(offset + 9))
      let copyLen =
        if dataLen > bleScanData.data.len: bleScanData.data.len else: dataLen
      bleScanLastEventType = evtype
      bleScanLastAddrType = addrType
      bleScanLastDataLen = copyLen.uint8
      for i in 0 ..< bleScanLastAddr.len:
        bleScanLastAddr[i] = raw[offset + 2 + i]
      bleScanData.len = copyLen.uint8
      for i in 0 ..< copyLen:
        bleScanData.data[i] = payload[i]
        if i < bleScanLastData.len:
          bleScanLastData[i] = payload[i]
      let rssi = cast[int8](raw[offset + 9 + dataLen])
      bleScanLastRssiRaw = raw[offset + 9 + dataLen]
      inc bleScanReportCounter

      if bleScanActive and bleScanCb != nil:
        bleScanCb(addr peer, rssi, evtype, addr bleScanData)
      if bleScanActive and advertisingNameMatches(payload, dataLen):
        inc bleScanNameMatchCounter
        bleCentralPeer = peer
        bleCentralPeerFound = true
        bleCentralTargetActive = false
        bleScanMatchedEventType = evtype
        bleScanMatchedAddrType = addrType
        bleScanMatchedDataLen = copyLen.uint8
        for i in 0 ..< bleScanMatchedAddr.len:
          bleScanMatchedAddr[i] = raw[offset + 2 + i]
        for i in 0 ..< bleScanMatchedData.len:
          bleScanMatchedData[i] =
            if i < copyLen: payload[i] else: 0'u8
      offset += 10 + dataLen

  proc le16(raw: ptr UncheckedArray[uint8], off: int): uint16 {.inline.} =
    raw[off].uint16 or (raw[off + 1].uint16 shl 8)

  proc putLe16(raw: ptr UncheckedArray[uint8], off: int,
               value: uint16) {.inline.} =
    raw[off] = uint8(value and 0x00FF'u16)
    raw[off + 1] = uint8((value shr 8) and 0x00FF'u16)

  proc bleNameLen(): int =
    while result < bleNameStorage.len and bleNameStorage[result] != '\0':
      inc result

  proc sendAclDataToController(handle: uint16,
                               payloadLen: uint16,
                               data: ptr uint8): bool =
    var acl = blecontroller.OnChipHciAclDataTx(
      conhdl: handle,
      pbBcFlag: HciAclPbFirstNonFlush,
      len: payloadLen + 4'u16,
      buffer: data,
    )
    blecontroller.bt_onchiphci_send(HciPktAclData, 0'u16, addr acl) == 0'i8

  proc sendL2capPdu(handle, cid: uint16, payload: ptr uint8,
                    payloadLen: uint16): bool =
    if payloadLen > uint16(HciLeDefaultDataOctets - 4):
      inc ble_host_acl_tx_reject_count
      return false
    if payload == nil and payloadLen != 0'u16:
      inc ble_host_acl_tx_reject_count
      return false

    var data: array[HciLeDefaultDataOctets.int, uint8]
    let raw = cast[ptr UncheckedArray[uint8]](addr data[0])
    putLe16(raw, 0, payloadLen)
    putLe16(raw, 2, cid)
    if payloadLen != 0'u16:
      let src = cast[ptr UncheckedArray[uint8]](payload)
      for i in 0 ..< payloadLen.int:
        raw[4 + i] = src[i]

    let ok = sendAclDataToController(handle, payloadLen, addr data[0])
    if ok:
      inc ble_host_acl_tx_count
    else:
      inc ble_host_acl_tx_reject_count
    ok

  proc sendAttPdu(handle: uint16, payload: ptr uint8,
                  payloadLen: uint16): bool =
    result = sendL2capPdu(handle, L2capCidAtt, payload, payloadLen)
    if result:
      inc ble_host_att_tx_count

  proc sendAttError(handle: uint16, requestOpcode: uint8,
                    attrHandle: uint16, errorCode: uint8): bool =
    var rsp: array[5, uint8]
    let raw = cast[ptr UncheckedArray[uint8]](addr rsp[0])
    raw[0] = AttOpErrorRsp
    raw[1] = requestOpcode
    putLe16(raw, 2, attrHandle)
    raw[4] = errorCode
    ble_host_att_last_status =
      (uint32(requestOpcode) shl 16) or uint32(errorCode)
    sendAttPdu(handle, addr rsp[0], rsp.len.uint16)

  proc appendGattUuid16(rsp: ptr UncheckedArray[uint8], pos: var int,
                        handle, uuid: uint16) =
    putLe16(rsp, pos, handle)
    putLe16(rsp, pos + 2, uuid)
    pos += 4

  proc appendGattGroup(rsp: ptr UncheckedArray[uint8], pos: var int,
                       startHandle, endHandle, uuid: uint16) =
    putLe16(rsp, pos, startHandle)
    putLe16(rsp, pos + 2, endHandle)
    putLe16(rsp, pos + 4, uuid)
    pos += 6

  proc handleAttExchangeMtu(handle: uint16,
                            pdu: ptr UncheckedArray[uint8],
                            pduLen: uint16): bool =
    if pduLen < 3'u16:
      return sendAttError(handle, AttOpExchangeMtuReq, 0'u16,
                          AttErrInvalidPdu)
    var rsp: array[3, uint8]
    let raw = cast[ptr UncheckedArray[uint8]](addr rsp[0])
    raw[0] = AttOpExchangeMtuRsp
    putLe16(raw, 1, AttLocalMtu)
    sendAttPdu(handle, addr rsp[0], rsp.len.uint16)

  proc handleAttFindInfo(handle: uint16,
                         pdu: ptr UncheckedArray[uint8],
                         pduLen: uint16): bool =
    if pduLen < 5'u16:
      return sendAttError(handle, AttOpFindInfoReq, 0'u16,
                          AttErrInvalidPdu)
    let startHandle = le16(pdu, 1)
    let endHandle = le16(pdu, 3)
    if startHandle == 0'u16 or startHandle > endHandle:
      return sendAttError(handle, AttOpFindInfoReq, startHandle,
                          AttErrInvalidHandle)

    var rsp: array[AttLocalMtu.int, uint8]
    let raw = cast[ptr UncheckedArray[uint8]](addr rsp[0])
    raw[0] = AttOpFindInfoRsp
    raw[1] = 0x01'u8
    var pos = 2
    if startHandle <= GattHandleGapService and endHandle >= GattHandleGapService:
      appendGattUuid16(raw, pos, GattHandleGapService, GattUuidPrimaryService)
    if startHandle <= GattHandleDeviceNameDecl and
        endHandle >= GattHandleDeviceNameDecl:
      appendGattUuid16(raw, pos, GattHandleDeviceNameDecl,
                       GattUuidCharacteristic)
    if startHandle <= GattHandleDeviceNameValue and
        endHandle >= GattHandleDeviceNameValue:
      appendGattUuid16(raw, pos, GattHandleDeviceNameValue,
                       GattUuidDeviceName)
    if startHandle <= GattHandleGattService and endHandle >= GattHandleGattService:
      appendGattUuid16(raw, pos, GattHandleGattService, GattUuidPrimaryService)
    if pos == 2:
      return sendAttError(handle, AttOpFindInfoReq, startHandle,
                          AttErrAttributeNotFound)
    sendAttPdu(handle, addr rsp[0], pos.uint16)

  proc handleAttReadByGroupType(handle: uint16,
                                pdu: ptr UncheckedArray[uint8],
                                pduLen: uint16): bool =
    if pduLen < 7'u16:
      return sendAttError(handle, AttOpReadByGroupTypeReq, 0'u16,
                          AttErrInvalidPdu)
    let startHandle = le16(pdu, 1)
    let endHandle = le16(pdu, 3)
    let groupType = le16(pdu, 5)
    if startHandle == 0'u16 or startHandle > endHandle:
      return sendAttError(handle, AttOpReadByGroupTypeReq, startHandle,
                          AttErrInvalidHandle)
    if groupType != GattUuidPrimaryService:
      return sendAttError(handle, AttOpReadByGroupTypeReq, startHandle,
                          AttErrAttributeNotFound)

    var rsp: array[AttLocalMtu.int, uint8]
    let raw = cast[ptr UncheckedArray[uint8]](addr rsp[0])
    raw[0] = AttOpReadByGroupTypeRsp
    raw[1] = 6'u8
    var pos = 2
    if startHandle <= GattHandleGapService and endHandle >= GattHandleGapService:
      appendGattGroup(raw, pos, GattHandleGapService,
                      GattHandleDeviceNameValue, GattUuidGenericAccess)
    if startHandle <= GattHandleGattService and endHandle >= GattHandleGattService:
      appendGattGroup(raw, pos, GattHandleGattService,
                      GattHandleGattService, GattUuidGenericAttribute)
    if pos == 2:
      return sendAttError(handle, AttOpReadByGroupTypeReq, startHandle,
                          AttErrAttributeNotFound)
    sendAttPdu(handle, addr rsp[0], pos.uint16)

  proc appendDeviceNameValue(rsp: ptr UncheckedArray[uint8],
                             pos: var int,
                             maxValueLen: int,
                             offset: int = 0) =
    let nameLen = bleNameLen()
    if offset >= nameLen:
      return
    let valueLen =
      if nameLen - offset > maxValueLen: maxValueLen else: nameLen - offset
    let name = cast[ptr UncheckedArray[uint8]](addr bleNameStorage[0])
    for i in 0 ..< valueLen:
      rsp[pos + i] = name[offset + i]
    pos += valueLen

  proc handleAttReadByType(handle: uint16,
                           pdu: ptr UncheckedArray[uint8],
                           pduLen: uint16): bool =
    if pduLen < 7'u16:
      return sendAttError(handle, AttOpReadByTypeReq, 0'u16,
                          AttErrInvalidPdu)
    let startHandle = le16(pdu, 1)
    let endHandle = le16(pdu, 3)
    let attrType = le16(pdu, 5)
    if startHandle == 0'u16 or startHandle > endHandle:
      return sendAttError(handle, AttOpReadByTypeReq, startHandle,
                          AttErrInvalidHandle)

    var rsp: array[AttLocalMtu.int, uint8]
    let raw = cast[ptr UncheckedArray[uint8]](addr rsp[0])
    raw[0] = AttOpReadByTypeRsp
    var pos = 2
    if attrType == GattUuidCharacteristic:
      raw[1] = 7'u8
      if startHandle <= GattHandleDeviceNameDecl and
          endHandle >= GattHandleDeviceNameDecl:
        putLe16(raw, pos, GattHandleDeviceNameDecl)
        raw[pos + 2] = GattDeviceNameProperties
        putLe16(raw, pos + 3, GattHandleDeviceNameValue)
        putLe16(raw, pos + 5, GattUuidDeviceName)
        pos += 7
    elif attrType == GattUuidDeviceName:
      raw[1] = uint8(2 + bleNameLen())
      if raw[1] > AttLocalMtu - 2:
        raw[1] = uint8(AttLocalMtu - 2)
      if startHandle <= GattHandleDeviceNameValue and
          endHandle >= GattHandleDeviceNameValue:
        putLe16(raw, pos, GattHandleDeviceNameValue)
        pos += 2
        appendDeviceNameValue(raw, pos, int(raw[1]) - 2)
    else:
      return sendAttError(handle, AttOpReadByTypeReq, startHandle,
                          AttErrAttributeNotFound)

    if pos == 2:
      return sendAttError(handle, AttOpReadByTypeReq, startHandle,
                          AttErrAttributeNotFound)
    sendAttPdu(handle, addr rsp[0], pos.uint16)

  proc handleAttRead(handle: uint16,
                     pdu: ptr UncheckedArray[uint8],
                     pduLen: uint16,
                     blob: bool): bool =
    let reqOpcode = if blob: AttOpReadBlobReq else: AttOpReadReq
    if (not blob and pduLen < 3'u16) or (blob and pduLen < 5'u16):
      return sendAttError(handle, reqOpcode, 0'u16, AttErrInvalidPdu)
    let attrHandle = le16(pdu, 1)
    let offset =
      if blob: le16(pdu, 3).int
      else: 0
    var rsp: array[AttLocalMtu.int, uint8]
    let raw = cast[ptr UncheckedArray[uint8]](addr rsp[0])
    raw[0] = if blob: AttOpReadBlobRsp else: AttOpReadRsp
    var pos = 1
    case attrHandle
    of GattHandleGapService:
      if offset != 0:
        return sendAttError(handle, reqOpcode, attrHandle,
                            AttErrAttributeNotFound)
      putLe16(raw, pos, GattUuidGenericAccess)
      pos += 2
    of GattHandleDeviceNameDecl:
      if offset != 0:
        return sendAttError(handle, reqOpcode, attrHandle,
                            AttErrAttributeNotFound)
      raw[pos] = GattDeviceNameProperties
      putLe16(raw, pos + 1, GattHandleDeviceNameValue)
      putLe16(raw, pos + 3, GattUuidDeviceName)
      pos += 5
    of GattHandleDeviceNameValue:
      appendDeviceNameValue(raw, pos, int(AttLocalMtu) - 1, offset)
    of GattHandleGattService:
      if offset != 0:
        return sendAttError(handle, reqOpcode, attrHandle,
                            AttErrAttributeNotFound)
      putLe16(raw, pos, GattUuidGenericAttribute)
      pos += 2
    else:
      return sendAttError(handle, reqOpcode, attrHandle,
                          AttErrAttributeNotFound)
    sendAttPdu(handle, addr rsp[0], pos.uint16)

  proc handleAttPdu(handle: uint16,
                    pdu: ptr UncheckedArray[uint8],
                    pduLen: uint16) =
    if pdu == nil or pduLen == 0'u16:
      return
    inc ble_host_att_rx_count
    let opcode = pdu[0]
    ble_host_att_last_opcode = opcode.uint32
    let ok =
      case opcode
      of AttOpExchangeMtuReq:
        handleAttExchangeMtu(handle, pdu, pduLen)
      of AttOpFindInfoReq:
        handleAttFindInfo(handle, pdu, pduLen)
      of AttOpReadByTypeReq:
        handleAttReadByType(handle, pdu, pduLen)
      of AttOpReadReq:
        handleAttRead(handle, pdu, pduLen, blob = false)
      of AttOpReadBlobReq:
        handleAttRead(handle, pdu, pduLen, blob = true)
      of AttOpReadByGroupTypeReq:
        handleAttReadByGroupType(handle, pdu, pduLen)
      else:
        sendAttError(handle, opcode, 0'u16, AttErrRequestNotSupported)
    if ok:
      ble_host_att_last_status = opcode.uint32 shl 16

  proc sendL2capCommandReject(handle: uint16, identifier: uint8): bool =
    var rsp: array[6, uint8]
    let raw = cast[ptr UncheckedArray[uint8]](addr rsp[0])
    raw[0] = 0x01'u8
    raw[1] = identifier
    putLe16(raw, 2, 2'u16)
    putLe16(raw, 4, 0x0000'u16)
    sendL2capPdu(handle, L2capCidLeSignaling, addr rsp[0], rsp.len.uint16)

  proc handleL2capSignaling(handle: uint16,
                            pdu: ptr UncheckedArray[uint8],
                            pduLen: uint16) =
    var off = 0
    while off + 4 <= pduLen.int:
      let code = pdu[off]
      let identifier = pdu[off + 1]
      let cmdLen = le16(pdu, off + 2).int
      if off + 4 + cmdLen > pduLen.int:
        return
      if code == 0x12'u8 and cmdLen >= 8:
        var rsp: array[6, uint8]
        let raw = cast[ptr UncheckedArray[uint8]](addr rsp[0])
        raw[0] = 0x13'u8
        raw[1] = identifier
        putLe16(raw, 2, 2'u16)
        putLe16(raw, 4, 0x0000'u16)
        discard sendL2capPdu(handle, L2capCidLeSignaling,
                             addr rsp[0], rsp.len.uint16)
      else:
        discard sendL2capCommandReject(handle, identifier)
      off += 4 + cmdLen

  proc handleAclData(raw: ptr UncheckedArray[uint8], len: int) =
    if raw == nil or len < 8:
      return
    inc ble_host_acl_rx_count
    let handleFlags = le16(raw, 0)
    let pbFlag = uint8((handleFlags shr 12) and 0x03'u16)
    if pbFlag == 0x01'u8:
      return
    let handle = handleFlags and 0x0FFF'u16
    let aclLen = le16(raw, 2).int
    if aclLen < 4 or len < 4 + aclLen:
      return
    let l2capLen = le16(raw, 4).int
    let cid = le16(raw, 6)
    if l2capLen > aclLen - 4:
      return
    let payload =
      cast[ptr UncheckedArray[uint8]](cast[uint](raw) + 8'u)
    case cid
    of L2capCidAtt:
      handleAttPdu(handle, payload, l2capLen.uint16)
    of L2capCidLeSignaling:
      handleL2capSignaling(handle, payload, l2capLen.uint16)
    else:
      discard

  proc handleLeMetaEvent(raw: ptr UncheckedArray[uint8], len: int) =
    if len < 3:
      return
    case raw[2]
    of HciLeEvtConnectionComplete, HciLeEvtEnhancedConnectionComplete:
      handleLeConnectionComplete(raw, len)
    of HciLeEvtAdvertisingReport:
      handleLeAdvertisingReport(raw, len)
    else:
      discard

  proc bleHostHciEvent(param: ptr uint8, paramLen: uint16): uint8 {.cdecl.} =
    if param == nil or paramLen < 2:
      return 0
    if not bleScanActive and not bleConnPending and not bleConnActive and
        not bleCentralTargetActive and not bleAdvActive:
      return 0
    let raw = cast[ptr UncheckedArray[uint8]](param)
    if hciDispatchPktType == HciPktAclData:
      handleAclData(raw, paramLen.int)
    else:
      case raw[0]
      of HciEvtLeMeta:
        handleLeMetaEvent(raw, paramLen.int)
      of HciEvtDisconnectComplete:
        handleDisconnectionComplete(raw, paramLen.int)
      else:
        discard
    0

  proc bt_enable*(cb: BtReadyCb): cint {.cdecl.} =
    ## Enable Bluetooth. Calls `cb` when ready.
    bleReadyCbPending = cb
    if not bleHostEnabled:
      bleHostEnabled = true
      discard bt_onchiphci_interface_init(bleHostHciEvent)
      discard hciCommandOk(HciOpReset, nil, 0)
    let readyCb = bleReadyCbPending
    bleReadyCbPending = nil
    if readyCb != nil:
      readyCb(0)
    0

  proc bt_set_name*(name: cstring): cint {.cdecl.} =
    if not bleHostEnabled: return -1
    copyBleName(name)
    0

  proc bt_get_name*(): cstring {.cdecl.} =
    if bleNameStorage[0] == '\0':
      copyBleName("bl808-hal")
    cast[cstring](addr bleNameStorage[0])

  proc bt_le_adv_start*(param: ptr BtLeAdvParam,
                        ad: ptr BtData, adLen: csize_t,
                        sd: ptr BtData, sdLen: csize_t): cint {.cdecl.} =
    ## Start BLE advertising.
    ble_adv_host_debug_stage = 0xA000'u32
    if not bleHostEnabled:
      ble_adv_host_debug_result = 0xFFFF0001'u32
      return -1
    bleAdvActive = false
    blePeripheralConnectedNotified = false
    blePeripheralDisconnectedNotified = false
    blePeripheralIdlePolls = 0
    when bl808BleNimConnectionEnabled:
      blePeripheralConnEventsSeen =
        blecontroller.bleNimPeripheralConnEventCount()
      blePeripheralDiscEventsSeen =
        blecontroller.bleNimPeripheralDiscEventCount()
    var advParams: array[15, uint8]
    let intervalMin =
      if param == nil: BleDefaultAdvInterval
      else: advIntervalOrDefault(param.intervalMin)
    let intervalMax =
      if param == nil or param.intervalMax == 0'u16: intervalMin
      else: advIntervalOrDefault(param.intervalMax)
    advParams[0] = uint8(intervalMin and 0xFF'u16)
    advParams[1] = uint8(intervalMin shr 8)
    advParams[2] = uint8(intervalMax and 0xFF'u16)
    advParams[3] = uint8(intervalMax shr 8)
    advParams[4] = 0x00'u8
    when BleUseRandomIdentity:
      if not configureRandomAddress():
        return -1
      advParams[5] = 0x01'u8
    else:
      advParams[5] = 0x00'u8
    advParams[13] = 0x07'u8
    advParams[14] = 0x00'u8
    ble_adv_host_debug_stage = 0xA100'u32
    ble_adv_host_debug_detail =
      (uint32(intervalMax) shl 16) or uint32(intervalMin)
    if not hciCommandOk(HciOpLeSetAdvParams,
                        addr advParams[0],
                        advParams.len.uint8):
      ble_adv_host_debug_result = 0xFFFF0002'u32
      return -1

    var advPayload: array[BleHciLegacyDataParamLen, uint8]
    var scanRsp: array[BleHciLegacyDataParamLen, uint8]
    let useDefaultSplit = adLen == 0 and sdLen == 0
    let advOk =
      if useDefaultSplit: encodeDefaultAdvAndScanRspData(advPayload, scanRsp)
      elif adLen == 0: encodeDefaultAdvData(advPayload)
      else: encodeBtData(advPayload, ad, adLen)
    if not advOk:
      ble_adv_host_debug_result = 0xFFFF0003'u32
      return -1
    ble_adv_host_debug_stage = 0xA200'u32
    ble_adv_host_debug_detail = advPayload[0].uint32
    if not hciCommandOk(HciOpLeSetAdvData,
                        addr advPayload[0],
                        advPayload.len.uint8):
      ble_adv_host_debug_result = 0xFFFF0004'u32
      return -1

    let scanRspOk =
      if useDefaultSplit: true
      elif sdLen == 0: encodeDefaultScanRspData(scanRsp)
      else: encodeBtData(scanRsp, sd, sdLen)
    if not scanRspOk:
      ble_adv_host_debug_result = 0xFFFF0005'u32
      return -1
    ble_adv_host_debug_stage = 0xA300'u32
    ble_adv_host_debug_detail = scanRsp[0].uint32
    if not hciCommandOk(HciOpLeSetScanRspData,
                        addr scanRsp[0],
                        scanRsp.len.uint8):
      ble_adv_host_debug_result = 0xFFFF0006'u32
      return -1

    var enable = 1'u8
    ble_adv_host_debug_stage = 0xA700'u32
    ble_adv_host_debug_detail = cast[uint32](cast[uint](addr enable))
    let enableOk = hciCommandOk(HciOpLeSetAdvEnable, addr enable, 1)
    ble_adv_host_debug_stage = 0xA710'u32
    ble_adv_host_debug_result = if enableOk: 1'u32 else: 0'u32
    if not enableOk:
      return -1
    bleAdvActive = true
    ble_adv_host_debug_stage = 0xA720'u32
    0

  proc bt_le_adv_stop*(): cint {.cdecl.} =
    if not bleHostEnabled:
      return -1
    if not bleAdvActive:
      return 0
    var enable = 0'u8
    if hciCommandOk(HciOpLeSetAdvEnable, addr enable, 1):
      bleAdvActive = false
      0
    else:
      -1

  proc bt_le_scan_start*(param: ptr BtLeScanParam,
                         cb: BtLeScanCb): cint {.cdecl.} =
    ble_host_debug_stage = 0x5300'u32
    if not bleHostEnabled:
      return -1
    let optionalProbe = cb == nil and not bleCentralTargetActive
    if optionalProbe:
      return 0
    bleScanCb = cb
    var scanParams: array[7, uint8]
    let scanType =
      if param == nil: 0x01'u8 else: param.scanType
    let filterDup =
      if param == nil: 0x00'u8 else: param.filterDup
    let interval =
      if param == nil or param.interval == 0: 0x0060'u16 else: param.interval
    let window =
      if param == nil or param.window == 0: 0x0030'u16 else: param.window
    when BleUseRandomIdentity:
      if not configureRandomAddress():
        return -1
    scanParams[0] = scanType
    scanParams[1] = uint8(interval and 0xFF)
    scanParams[2] = uint8(interval shr 8)
    scanParams[3] = uint8(window and 0xFF)
    scanParams[4] = uint8(window shr 8)
    when BleUseRandomIdentity:
      scanParams[5] = 0x01'u8
    else:
      scanParams[5] = 0x00'u8
    scanParams[6] = 0x00'u8
    ble_host_debug_stage = 0x5310'u32
    if not hciCommandOk(HciOpLeSetScanParams,
                        addr scanParams[0],
                        scanParams.len.uint8):
      return -1
    var enable = [0x01'u8, filterDup]
    ble_host_debug_stage = 0x5320'u32
    if not hciCommandOk(HciOpLeSetScanEnable, addr enable[0], enable.len.uint8):
      return -1
    bleScanActive = true
    ble_host_debug_stage = 0x5330'u32
    0

  proc bt_le_scan_stop*(): cint {.cdecl.} =
    if not bleHostEnabled:
      return -1
    if not bleScanActive:
      bleScanCb = nil
      return 0
    var enable = [0x00'u8, 0x00]
    if not hciCommandOk(HciOpLeSetScanEnable, addr enable[0], enable.len.uint8):
      return -1
    bleScanActive = false
    bleScanCb = nil
    0

  proc bt_conn_cb_register*(cb: ptr BtConnCb) {.cdecl.} =
    bleConnCb = cb

  proc bleHostDbgConnActive*(): uint32 {.exportc, cdecl.} =
    if bleConnActive: 1'u32 else: 0'u32

  proc bleHostDbgPeripheralConnectedNotified*(): uint32 {.exportc, cdecl.} =
    if blePeripheralConnectedNotified: 1'u32 else: 0'u32

  proc bleHostDbgPeripheralDisconnectedNotified*(): uint32 {.exportc, cdecl.} =
    if blePeripheralDisconnectedNotified: 1'u32 else: 0'u32

  proc bleHostDbgPeripheralIdlePolls*(): uint32 {.exportc, cdecl.} =
    blePeripheralIdlePolls

  proc bleHostDbgPeripheralLastRxEventCounter*(): uint32 {.exportc, cdecl.} =
    blePeripheralLastRxEventCounter

  proc bleScanReportCount*(): uint32 {.cdecl.} =
    bleScanReportCounter

  proc bleScanNameMatchCount*(): uint32 {.cdecl.} =
    bleScanNameMatchCounter

  proc bleScanLastReportEventType*(): uint8 {.cdecl.} =
    bleScanLastEventType

  proc bleScanLastReportAddrType*(): uint8 {.cdecl.} =
    bleScanLastAddrType

  proc bleScanLastReportRssiRaw*(): uint8 {.cdecl.} =
    bleScanLastRssiRaw

  proc bleScanLastReportDataLen*(): uint8 {.cdecl.} =
    bleScanLastDataLen

  proc bleScanLastReportAddrByte*(index: uint8): uint8 {.cdecl.} =
    if index.int < bleScanLastAddr.len:
      bleScanLastAddr[index.int]
    else:
      0

  proc bleScanLastReportDataByte*(index: uint8): uint8 {.cdecl.} =
    if index.int < bleScanLastData.len:
      bleScanLastData[index.int]
    else:
      0

  proc bleScanMatchedReportEventType*(): uint8 {.cdecl.} =
    bleScanMatchedEventType

  proc bleScanMatchedReportAddrType*(): uint8 {.cdecl.} =
    bleScanMatchedAddrType

  proc bleScanMatchedReportDataLen*(): uint8 {.cdecl.} =
    bleScanMatchedDataLen

  proc bleScanMatchedReportAddrByte*(index: uint8): uint8 {.cdecl.} =
    if index.int < bleScanMatchedAddr.len:
      bleScanMatchedAddr[index.int]
    else:
      0

  proc bleScanMatchedReportDataByte*(index: uint8): uint8 {.cdecl.} =
    if index.int < bleScanMatchedData.len:
      bleScanMatchedData[index.int]
    else:
      0

  proc bleControllerScanProbeReportCount*(): uint32 {.cdecl.} =
    0

  proc bleControllerScanProbeStartStatus*(): uint32 {.cdecl.} =
    0

  proc bleControllerScanProbeArbInsertCount*(): uint32 {.cdecl.} =
    0

  proc bleControllerScanProbeArbCallbackCount*(): uint32 {.cdecl.} =
    0

  proc bleControllerScanProbeSwIntCount*(): uint32 {.cdecl.} =
    0

  proc bleControllerScanProbeRestartCount*(): uint32 {.cdecl.} =
    0

  proc bleControllerScanProbeUnsupportedCount*(): uint32 {.cdecl.} =
    0

  proc bleControllerScanProbeUnsupportedHeader*(): uint32 {.cdecl.} =
    0

  proc bleControllerScanProbeUnsupportedLen*(): uint32 {.cdecl.} =
    0

  proc bleControllerScanProbeUnsupportedByte*(index: uint8): uint8 {.cdecl.} =
    discard index
    0

  proc bleControllerInitProbeStartStatus*(): uint32 {.cdecl.} =
    0

  proc bleControllerInitProbeMessageCount*(): uint32 {.cdecl.} =
    0

  proc bleControllerInitProbeSuccessCount*(): uint32 {.cdecl.} =
    0

  proc bleControllerInitProbeFailureCount*(): uint32 {.cdecl.} =
    0

  proc bleControllerInitProbeLastActivity*(): uint32 {.cdecl.} =
    0

  proc bleControllerInitProbeLastMessageStatus*(): uint32 {.cdecl.} =
    0

  proc bleControllerInitProbeCancelStatus*(): uint32 {.cdecl.} =
    0

  proc bleControllerInitProbeCancelCount*(): uint32 {.cdecl.} =
    0

  proc bleControllerInitProbeHeaderFixCount*(): uint32 {.cdecl.} =
    0

  proc bleControllerInitProbeParamByte*(index: uint8): uint8 {.cdecl.} =
    discard index
    0

  proc bleControllerInitProbeArbInsertCount*(): uint32 {.cdecl.} =
    0

  proc bleControllerInitProbeArbCallbackCount*(): uint32 {.cdecl.} =
    0

  proc bleControllerInitProbeArbLastWord*(index: uint8): uint32 {.cdecl.} =
    discard index
    0

  proc bleControllerInitProbePeerRxCount*(): uint32 {.cdecl.} =
    0

  proc bleControllerInitProbePeerHitCount*(): uint32 {.cdecl.} =
    0

  proc bleControllerInitProbePeerRxLastHeader*(): uint32 {.cdecl.} =
    0

  proc bleControllerInitProbePeerRxLastStatus*(): uint32 {.cdecl.} =
    0

  proc bleControllerInitProbePeerRxLastMeta*(): uint32 {.cdecl.} =
    0

  proc bleControllerInitProbeStatusFixCount*(): uint32 {.cdecl.} =
    0

  proc bleControllerInitProbeStatusFixLast*(): uint32 {.cdecl.} =
    0

  proc bleControllerInitProbeMessageAllocCount*(): uint32 {.cdecl.} =
    0

  proc bleControllerInitProbeMessageAllocLen*(): uint32 {.cdecl.} =
    0

  proc bleControllerInitProbeMessageAllocDest*(): uint32 {.cdecl.} =
    0

  proc bleControllerInitProbeMessageAllocSrc*(): uint32 {.cdecl.} =
    0

  proc bleControllerInitProbeAccessAddressCount*(): uint32 {.cdecl.} =
    0

  proc bleControllerInitProbeAccessAddress*(): uint32 {.cdecl.} =
    0

  proc bleControllerInitProbeAccessAddressSeed*(): uint32 {.cdecl.} =
    0

  proc bleControllerInitProbePacketDurationCount*(): uint32 {.cdecl.} =
    0

  proc bleControllerInitProbePacketDurationLen*(): uint32 {.cdecl.} =
    0

  proc bleControllerInitProbePacketDurationRate*(): uint32 {.cdecl.} =
    0

  proc bleControllerSchProgFifoCount*(): uint32 {.cdecl.} =
    0

  proc bleControllerSchProgSkipCount*(): uint32 {.cdecl.} =
    0

  proc bleControllerSchProgElapsedCount*(): uint32 {.cdecl.} =
    0

  proc bleControllerSchProgLastStage*(): uint32 {.cdecl.} =
    0

  proc bleControllerSchProgLastTarget*(): uint32 {.cdecl.} =
    0

  proc bleControllerSchProgLastNow*(): uint32 {.cdecl.} =
    0

  proc bleControllerSchProgLastSlot*(): uint32 {.cdecl.} =
    0

  proc bleControllerSchProgLastIntMask*(): uint32 {.cdecl.} =
    0

  proc bleControllerSchProgLastIntStat*(): uint32 {.cdecl.} =
    0

  proc bleControllerIsrCount*(): uint32 {.cdecl.} =
    blecontroller.ble_dbg_isr_count()

  proc bleControllerIsrStatOr*(): uint32 {.cdecl.} =
    blecontroller.ble_dbg_isr_stat_or()

  proc bleControllerStat20Count*(): uint32 {.cdecl.} =
    blecontroller.ble_dbg_stat20_count()

  proc bleControllerStat8000Count*(): uint32 {.cdecl.} =
    blecontroller.ble_dbg_stat8000_count()

  proc bleControllerRxCheckCount*(): uint32 {.cdecl.} =
    when bl808BleNimConnectionEnabled:
      blecontroller.nim_lld_rx_check_count
    else:
      0

  proc bleControllerRxCheckHitCount*(): uint32 {.cdecl.} =
    when bl808BleNimConnectionEnabled:
      blecontroller.nim_lld_rx_check_hit_count
    else:
      0

  proc bleControllerRxFreeCount*(): uint32 {.cdecl.} =
    when bl808BleNimConnectionEnabled:
      blecontroller.nim_lld_rx_free_count
    else:
      0

  proc bleControllerRxLastStatus*(): uint32 {.cdecl.} =
    when bl808BleNimConnectionEnabled:
      blecontroller.nim_lld_rx_last_status
    else:
      0

  proc bleControllerRxLastHeader*(): uint32 {.cdecl.} =
    when bl808BleNimConnectionEnabled:
      blecontroller.nim_lld_rx_last_header
    else:
      0

  proc synthesizeCentralReportIfNeeded() =
    when bl808BleNimSyntheticCentral:
      if not bleScanActive or not bleCentralTargetActive or bleCentralPeerFound:
        return
      var peer: BtAddrLe
      peer.addrType = 0x01'u8
      peer.a[0] = 0xC0'u8
      peer.a[1] = 0xDE'u8
      peer.a[2] = 0xAC'u8
      peer.a[3] = 0xCE'u8
      peer.a[4] = 0x55'u8
      peer.a[5] = 0x01'u8
      bleScanData.len = 0
      bleCentralPeer = peer
      bleCentralPeerFound = true
      bleCentralTargetActive = false
      inc bleScanReportCounter
      inc bleScanNameMatchCounter

  proc bleBackendSynthesizeCentralReportIfNeeded() {.inline.} =
    synthesizeCentralReportIfNeeded()

  proc bleBackendVersionString(): string =
    "bl808-blecontroller-nim-1.0"

  proc bt_conn_create_le*(peer: ptr BtAddrLe,
                          param: ptr BtLeConnParam): ptr BtConn {.cdecl.} =
    ble_central_debug_stage = 0x5400'u32
    inc ble_central_debug_create_count
    if not bleHostEnabled or peer == nil:
      ble_central_debug_create_result = 0xFFFFFFFE'u32
      return nil
    var connParams: array[25, uint8]
    let intervalMin =
      if param == nil or param.intervalMin == 0: 0x0018'u16 else: param.intervalMin
    let intervalMax =
      if param == nil or param.intervalMax == 0: 0x0028'u16 else: param.intervalMax
    let latency =
      if param == nil: 0'u16 else: param.latency
    let timeout =
      if param == nil or param.timeout == 0: 400'u16 else: param.timeout
    connParams[0] = uint8(BleCentralConnectScanInterval and 0xFF'u16)
    connParams[1] = uint8(BleCentralConnectScanInterval shr 8)
    connParams[2] = uint8(BleCentralConnectScanWindow and 0xFF'u16)
    connParams[3] = uint8(BleCentralConnectScanWindow shr 8)
    connParams[4] = 0x00'u8
    connParams[5] = peer.addrType
    for i in 0 ..< peer.a.len:
      connParams[6 + i] = peer.a[i]
    when BleUseRandomIdentity:
      if not configureRandomAddress():
        bleConnPending = false
        bleConnConnectedNotified = false
        return nil
      connParams[12] = 0x01'u8
    else:
      connParams[12] = 0x00'u8
    connParams[13] = uint8(intervalMin and 0xFF)
    connParams[14] = uint8(intervalMin shr 8)
    connParams[15] = uint8(intervalMax and 0xFF)
    connParams[16] = uint8(intervalMax shr 8)
    connParams[17] = uint8(latency and 0xFF)
    connParams[18] = uint8(latency shr 8)
    connParams[19] = uint8(timeout and 0xFF)
    connParams[20] = uint8(timeout shr 8)
    connParams[21] = 0x00'u8
    connParams[22] = 0x00'u8
    connParams[23] = 0x00'u8
    connParams[24] = 0x00'u8
    bleConn = BtConn(peer: peer[], status: 0xFF'u8)
    bleConnPending = true
    bleConnConnectedNotified = false
    bleCentralConnected = false
    if not hciCommandOk(HciOpLeCreateConnection,
                        addr connParams[0],
                        connParams.len.uint8):
      bleConnPending = false
      bleConnConnectedNotified = false
      ble_central_debug_create_result = 0xFFFFFFFF'u32
      return nil
    drainHciHostEvents()
    ble_central_debug_create_result = 0
    addr bleConn

  proc bt_conn_disconnect*(conn: ptr BtConn, reason: uint8): cint {.cdecl.} =
    if not bleHostEnabled or conn == nil:
      return -1
    var params: array[3, uint8]
    params[0] = uint8(conn.handle and 0xFF)
    params[1] = uint8(conn.handle shr 8)
    params[2] = reason
    if not hciCommandOk(HciOpDisconnect, addr params[0], params.len.uint8):
      return -1
    0

  proc centralConnectAttemptBudget(timeoutMs: uint32): uint32 =
    let configured =
      if BleCentralConnectAttemptMs <= 0:
        timeoutMs
      else:
        uint32(BleCentralConnectAttemptMs)
    if configured == 0'u32 or configured > timeoutMs:
      timeoutMs
    else:
      configured

  proc shouldRetryKnownCentralPeer(addrType: uint8, retries: uint32): bool =
    ## A resolved address is only a snapshot of the advertiser we saw.  The
    ## default is to rediscover by name after each failed attempt; board-specific
    ## diagnostics can still raise BleCentralPeerConnectRetries when debugging a
    ## stable peer address.
    discard addrType
    retries < uint32(max(BleCentralPeerConnectRetries, 0))

  proc noteKnownCentralPeerRetry(retries: var uint32) =
    if retries != high(uint32):
      inc retries

  proc bleBackendPollCentralController() =
    const iterations = max(BleCentralPollIterations, 1)
    for _ in 0 ..< iterations:
      blecontroller.bflbble_isr()
      blecontroller.bleControllerDrainScanReports()
      drainHciHostEvents()
      blecontroller.bflbip_schedule()
      when bl808BleNimPureCentral:
        blecontroller.bleControllerServiceScan()
      blecontroller.bleControllerDrainScanReports()
      drainHciHostEvents()

  proc pollCentralController() =
    bleBackendPollCentralController()

  proc bleBackendServiceDisconnectWait(): bool =
    drainHciHostEvents()
    not bleConnActive

  proc copyCentralTargetName(name: cstring) =
    for i in 0 ..< bleCentralTargetName.len:
      bleCentralTargetName[i] = '\0'
    if name == nil:
      return
    let src = cast[ptr UncheckedArray[char]](name)
    var i = 0
    while i < bleCentralTargetName.len - 1 and src[i] != '\0':
      bleCentralTargetName[i] = src[i]
      inc i

  proc resetCentralDiscoveryState(name: cstring, acceptAnyReport = false) =
    copyCentralTargetName(name)
    bleCentralTargetActive = true
    bleCentralAcceptAnyReport = acceptAnyReport
    bleCentralPeerFound = false
    bleScanReportCounter = 0
    bleScanNameMatchCounter = 0
    bleScanMatchedEventType = 0
    bleScanMatchedAddrType = 0
    bleScanMatchedDataLen = 0
    for i in 0 ..< bleScanMatchedAddr.len:
      bleScanMatchedAddr[i] = 0
    for i in 0 ..< bleScanMatchedData.len:
      bleScanMatchedData[i] = 0

  proc centralDiscoveryScanType(): uint8 =
    if BleCentralDiscoveryActiveScan: 0x01'u8 else: 0x00'u8

  proc monotonicMs(): uint64 {.inline.} =
    ticksToMs(readTick())

  proc elapsedMsSince(startedAtMs: uint64): uint32 =
    let elapsed = monotonicMs() - startedAtMs
    if elapsed > high(uint32).uint64:
      high(uint32)
    else:
      elapsed.uint32

  proc startCentralDiscoveryScan(scanParam: var BtLeScanParam,
                                 timeoutMs: uint32,
                                 mark: uint32): bool =
    let scanStartRc = bt_le_scan_start(addr scanParam, nil)
    if scanStartRc != 0:
      return false
    true

  proc restartCentralDiscoveryScan(scanParam: var BtLeScanParam,
                                   timeoutMs: uint32,
                                   mark: uint32,
                                   peerConnectRetries: var uint32): bool =
    peerConnectRetries = 0
    bleCentralPeerFound = false
    bleCentralTargetActive = true
    if not startCentralDiscoveryScan(scanParam, timeoutMs, mark):
      bleCentralTargetActive = false
      return false
    true

  proc stopDiscoveryScanBeforeConnect(): bool =
    when bl808BleNimPureCentral:
      # LE Create Connection takes over the scheduler and resets the pure
      # scan/initiator rings. Keep the host's scan state in sync without an
      # extra HCI command between the observed advert and CONNECT_IND.
      if bleScanActive:
        bleScanActive = false
        bleScanCb = nil
      true
    else:
      bt_le_scan_stop() == 0

  proc bleCentralScanTarget(name: cstring, timeoutMs: uint32,
                            acceptAnyReport: bool): cint =
    if not bleHostEnabled:
      return -1
    resetCentralDiscoveryState(name, acceptAnyReport)
    var scanParam = BtLeScanParam(
      scanType: centralDiscoveryScanType(),
      filterDup: 0x00'u8,
      interval: BleCentralDiscoveryScanInterval,
      window: BleCentralDiscoveryScanWindow,
    )
    let scanStartRc = bt_le_scan_start(addr scanParam, nil)
    if scanStartRc != 0:
      bleCentralTargetActive = false
      return -1
    let startedAtMs = monotonicMs()

    while elapsedMsSince(startedAtMs) < timeoutMs:
      pollCentralController()
      bleBackendSynthesizeCentralReportIfNeeded()
      if bleCentralPeerFound:
        discard bt_le_scan_stop()
        bleCentralTargetActive = false
        bleCentralAcceptAnyReport = false
        return 0
      delayUs(1000)
    discard bt_le_scan_stop()
    bleCentralTargetActive = false
    bleCentralAcceptAnyReport = false
    -1

  proc bleCentralScanByName*(name: cstring,
                             timeoutMs: uint32 = 20_000): cint {.cdecl.} =
    bleCentralScanTarget(name, timeoutMs, false)

  proc bleCentralScanAnyReport*(timeoutMs: uint32 = 20_000): cint {.cdecl.} =
    bleCentralScanTarget("".cstring, timeoutMs, true)

  proc bleCentralConnectByName*(name: cstring,
                                timeoutMs: uint32 = 20_000): cint {.cdecl.} =
    ble_central_debug_stage = 0x5500'u32
    ble_central_debug_timeout = timeoutMs
    ble_central_debug_waited = 0
    ble_central_debug_flags = 0
    if not bleHostEnabled:
      return -1
    resetCentralDiscoveryState(name)
    bleCentralConnected = false
    bleConnPending = false
    bleConnConnectedNotified = false
    var scanParam = BtLeScanParam(
      scanType: centralDiscoveryScanType(),
      filterDup: 0x00'u8,
      interval: BleCentralDiscoveryScanInterval,
      window: BleCentralDiscoveryScanWindow,
    )
    if not startCentralDiscoveryScan(scanParam, timeoutMs, 0x100'u32):
      return -1
    ble_central_debug_stage = 0x5510'u32
    var connectStarted = false
    var connectStartedAt = 0'u32
    var retryKnownPeerPending = false
    var peerConnectRetries = 0'u32
    let attemptBudget = centralConnectAttemptBudget(timeoutMs)
    let startedAtMs = monotonicMs()
    var nextScanRestartMs =
      if bl808BleCentralScanRestartMs <= 0:
        0'u32
      else:
        uint32(bl808BleCentralScanRestartMs)

    while true:
      let waited = elapsedMsSince(startedAtMs)
      ble_central_debug_waited = waited
      if waited >= timeoutMs:
        break
      pollCentralController()
      ble_central_debug_flags =
        (if bleCentralPeerFound: 1'u32 else: 0'u32) or
        (if connectStarted: 2'u32 else: 0'u32) or
        (if bleConnPending: 4'u32 else: 0'u32) or
        (if bleCentralConnected: 8'u32 else: 0'u32)
      if waited >= 250'u32:
        bleBackendSynthesizeCentralReportIfNeeded()
      if bleCentralConnected:
        if not bleConnConnectedNotified:
          notifyConnected(bleConn.status)
        return 0
      when defined(BleCentralReturnAfterHandoffForSnapshot):
        when bl808BleNimPureCentral:
          if blecontroller.nim_init_handoff_pending != 0'u32 or
              blecontroller.nim_init_total_start_count != 0'u32:
            ble_central_debug_stage = 0x55E0'u32
            return -1
      if connectStarted and not bleConnPending and not bleCentralConnected:
        connectStarted = false
        if shouldRetryKnownCentralPeer(bleCentralPeer.addrType,
                                       peerConnectRetries):
          noteKnownCentralPeerRetry(peerConnectRetries)
          retryKnownPeerPending = true
          bleCentralPeerFound = true
          bleCentralTargetActive = false
        else:
          if waited >= timeoutMs or not restartCentralDiscoveryScan(
              scanParam, timeoutMs, 0x510'u32, peerConnectRetries):
            return -1
      if connectStarted and attemptBudget != 0'u32 and
          ((waited - connectStartedAt) >= attemptBudget):
        discard hciCommandOk(HciOpLeCreateConnectionCancel, nil, 0)
        connectStarted = false
        bleConnPending = false
        bleConnConnectedNotified = false
        if shouldRetryKnownCentralPeer(bleCentralPeer.addrType,
                                       peerConnectRetries):
          noteKnownCentralPeerRetry(peerConnectRetries)
          retryKnownPeerPending = true
          bleCentralPeerFound = true
          bleCentralTargetActive = false
        else:
          if waited >= timeoutMs or not restartCentralDiscoveryScan(
              scanParam, timeoutMs, 0x521'u32, peerConnectRetries):
            return -1
      if bleCentralPeerFound and not connectStarted:
        ble_central_debug_stage = 0x5520'u32
        discard stopDiscoveryScanBeforeConnect()
        ble_central_debug_stage = 0x5530'u32
        var connParam = BtLeConnParam(
          intervalMin: 0x0018'u16,
          intervalMax: 0x0028'u16,
          latency: 0'u16,
          timeout: 400'u16,
        )
        if bt_conn_create_le(addr bleCentralPeer, addr connParam) == nil:
          ble_central_debug_stage = 0x55F0'u32
          bleCentralTargetActive = false
          bleCentralAcceptAnyReport = false
          bleConnPending = false
          bleConnConnectedNotified = false
          return -1
        bleCentralTargetActive = false
        bleCentralAcceptAnyReport = false
        ble_central_debug_stage = 0x5540'u32
        if not retryKnownPeerPending:
          peerConnectRetries = 0
        retryKnownPeerPending = false
        connectStarted = true
        connectStartedAt = waited
        ble_central_debug_flags =
          (if bleCentralPeerFound: 1'u32 else: 0'u32) or
          (if connectStarted: 2'u32 else: 0'u32) or
          (if bleConnPending: 4'u32 else: 0'u32) or
          (if bleCentralConnected: 8'u32 else: 0'u32)
      delayUs(1000)
    let finalWaited = elapsedMsSince(startedAtMs)
    ble_central_debug_stage = 0x5560'u32
    ble_central_debug_waited = finalWaited
    if connectStarted:
      discard hciCommandOk(HciOpLeCreateConnectionCancel, nil, 0)
    else:
      discard bt_le_scan_stop()
    bleCentralTargetActive = false
    bleCentralAcceptAnyReport = false
    -1

  proc bleCentralScanByNameAsync*(name: cstring,
                                  timeoutMs: uint32 = 20_000): CpsFuture[BtAddrLe] {.cps.} =
    if not bleHostEnabled:
      raise newException(CatchableError, "BLE host is not enabled")
    resetCentralDiscoveryState(name, false)
    var scanParam = BtLeScanParam(
      scanType: centralDiscoveryScanType(),
      filterDup: 0x00'u8,
      interval: BleCentralDiscoveryScanInterval,
      window: BleCentralDiscoveryScanWindow,
    )
    if not startCentralDiscoveryScan(scanParam, timeoutMs, 0x100'u32):
      raise newException(CatchableError, "BLE scan start failed")
    let startedAtMs = monotonicMs()
    while elapsedMsSince(startedAtMs) < timeoutMs:
      bleHostServicePump()
      bleBackendSynthesizeCentralReportIfNeeded()
      if bleCentralPeerFound:
        discard bt_le_scan_stop()
        bleCentralTargetActive = false
        bleCentralAcceptAnyReport = false
        return bleCentralPeer
      await sleepMs(1)
    discard bt_le_scan_stop()
    bleCentralTargetActive = false
    bleCentralAcceptAnyReport = false
    raise newException(TimeoutError, "BLE scan timed out")

  proc bleCentralConnectByNameAsync*(name: cstring,
                                     timeoutMs: uint32 = 20_000): CpsFuture[ptr BtConn] {.cps.} =
    ble_central_debug_stage = 0x5500'u32
    ble_central_debug_timeout = timeoutMs
    ble_central_debug_waited = 0
    ble_central_debug_flags = 0
    if not bleHostEnabled:
      raise newException(CatchableError, "BLE host is not enabled")
    resetCentralDiscoveryState(name)
    bleCentralConnected = false
    bleConnPending = false
    bleConnConnectedNotified = false
    var scanParam = BtLeScanParam(
      scanType: centralDiscoveryScanType(),
      filterDup: 0x00'u8,
      interval: BleCentralDiscoveryScanInterval,
      window: BleCentralDiscoveryScanWindow,
    )
    if not startCentralDiscoveryScan(scanParam, timeoutMs, 0x100'u32):
      raise newException(CatchableError, "BLE scan start failed")
    var connectStarted = false
    var connectStartedAt = 0'u32
    var peerConnectRetries = 0'u32
    let attemptBudget = centralConnectAttemptBudget(timeoutMs)
    let startedAtMs = monotonicMs()
    while true:
      let waited = elapsedMsSince(startedAtMs)
      ble_central_debug_waited = waited
      if waited >= timeoutMs:
        break
      bleHostServicePump()
      ble_central_debug_flags =
        (if bleCentralPeerFound: 1'u32 else: 0'u32) or
        (if connectStarted: 2'u32 else: 0'u32) or
        (if bleConnPending: 4'u32 else: 0'u32) or
        (if bleCentralConnected: 8'u32 else: 0'u32)
      if waited >= 250'u32:
        bleBackendSynthesizeCentralReportIfNeeded()
      if bleCentralConnected:
        if not bleConnConnectedNotified:
          notifyConnected(bleConn.status)
        return addr bleConn
      if connectStarted and not bleConnPending and not bleCentralConnected:
        connectStarted = false
        if not restartCentralDiscoveryScan(scanParam, timeoutMs, 0x510'u32,
                                           peerConnectRetries):
          break
      if connectStarted and attemptBudget != 0'u32 and
          ((waited - connectStartedAt) >= attemptBudget):
        discard hciCommandOk(HciOpLeCreateConnectionCancel, nil, 0)
        connectStarted = false
        bleConnPending = false
        bleConnConnectedNotified = false
        if not restartCentralDiscoveryScan(scanParam, timeoutMs, 0x521'u32,
                                           peerConnectRetries):
          break
      if bleCentralPeerFound and not connectStarted:
        discard stopDiscoveryScanBeforeConnect()
        var connParam = BtLeConnParam(
          intervalMin: 0x0018'u16,
          intervalMax: 0x0028'u16,
          latency: 0'u16,
          timeout: 400'u16,
        )
        if bt_conn_create_le(addr bleCentralPeer, addr connParam) == nil:
          bleCentralTargetActive = false
          bleCentralAcceptAnyReport = false
          bleConnPending = false
          bleConnConnectedNotified = false
          raise newException(CatchableError, "BLE create connection failed")
        bleCentralTargetActive = false
        bleCentralAcceptAnyReport = false
        peerConnectRetries = 0
        connectStarted = true
        connectStartedAt = waited
      await sleepMs(1)
    if connectStarted:
      discard hciCommandOk(HciOpLeCreateConnectionCancel, nil, 0)
    else:
      discard bt_le_scan_stop()
    bleCentralTargetActive = false
    bleCentralAcceptAnyReport = false
    raise newException(TimeoutError, "BLE connect timed out")

  proc bleDisconnectCurrent*(reason: uint8 = 0x13'u8,
                             timeoutMs: uint32 = 2_000): cint {.cdecl.} =
    if not bleConnActive:
      return 0
    if bt_conn_disconnect(addr bleConn, reason) != 0:
      return -1
    drainHciHostEvents()
    if not bleConnActive:
      return 0
    var waited = 0'u32
    while waited < timeoutMs:
      if bleBackendServiceDisconnectWait():
        return 0
      delayUs(1000)
      inc waited
    -1

# =============================================================================
# Higher-level Nim BLE API (M0 only)
# =============================================================================
when defined(bl808m0):

  type
    BleError* = enum
      bleOk = 0
      bleFail = -1
      bleNotInit = -2

  proc bleControllerInit*(priority: uint8 = 5) =
    ## Initialize the BLE controller.
    bleControllerInitRaw(taskPriority = priority)

  proc bleControllerDeinit*() =
    if bleControllerStarted:
      blecontroller.ble_controller_deinit()
      bleControllerStarted = false

  proc bleSetTxPower*(power: int) =
    ## Set BLE TX power (dBm, typically -20 to +10).
    ble_controller_set_tx_pwr(power.cint)

  proc bleGetTxPower*(): int8 =
    ble_controller_get_tx_pwr()

  proc bleGetVersion*(): string =
    ## Get BLE controller library version.
    bleBackendVersionString()

  proc bleEnable*(readyCb: BtReadyCb): BleError =
    ## Enable the Zephyr BLE host stack.
    let rc = bt_enable(readyCb)
    if rc == 0: bleOk else: bleFail

  proc bleEnableAsync*(readyCb: BtReadyCb): CpsFuture[BleError] {.cps.} =
    return bleEnable(readyCb)

  proc bleSetName*(name: string): BleError =
    let rc = bt_set_name(name.cstring)
    if rc == 0: bleOk else: bleFail

  proc bleStartAdvertising*(param: ptr BtLeAdvParam,
                            ad: ptr BtData, adLen: int,
                            sd: ptr BtData = nil, sdLen: int = 0): BleError =
    let rc = bt_le_adv_start(param, ad, adLen.csize_t, sd, sdLen.csize_t)
    if rc == 0: bleOk else: bleFail

  proc bleStartAdvertisingAsync*(param: ptr BtLeAdvParam,
                                 ad: ptr BtData, adLen: int,
                                 sd: ptr BtData = nil,
                                 sdLen: int = 0): CpsFuture[BleError] {.cps.} =
    return bleStartAdvertising(param, ad, adLen, sd, sdLen)

  proc bleStopAdvertising*(): BleError =
    let rc = bt_le_adv_stop()
    if rc == 0: bleOk else: bleFail

  proc bleStopAdvertisingAsync*(): CpsFuture[BleError] {.cps.} =
    return bleStopAdvertising()

  proc bleWaitPeripheralDisconnected*(timeoutMs: uint32 = 20_000): CpsFuture[uint8]

  proc bleDisconnectAsync*(reason: uint8 = 0x13'u8,
                           timeoutMs: uint32 = 2_000): CpsFuture[BleError] {.cps.} =
    if not bleConnActive:
      return bleOk
    if bt_conn_disconnect(addr bleConn, reason) != 0:
      if bleConn.role == 1'u8 and blePeripheralConnectedNotified:
        bleConnActive = false
        bleConnPending = false
        bleConnConnectedNotified = false
        bleCentralConnected = false
        notifyDisconnected(reason)
        return bleOk
      return bleFail
    discard await bleWaitPeripheralDisconnected(timeoutMs)
    return bleOk

  proc bleWaitPeripheralConnected*(timeoutMs: uint32 = 20_000): CpsFuture[ptr BtConn] =
    if blePeripheralConnectedNotified and bleConnActive:
      return completedLocalFuture(addr bleConn)
    if blePeripheralConnectFuture != nil and not blePeripheralConnectFuture.finished:
      return blePeripheralConnectFuture
    blePeripheralConnectFuture = newLocalCpsFuture[ptr BtConn]()
    if timeoutMs != 0'u32:
      blePeripheralConnectTimer = addTimerMs(timeoutMs.uint64, proc() =
        failBlePeripheralConnected("BLE peripheral connect timed out")
      )
    return blePeripheralConnectFuture

  proc bleWaitPeripheralDisconnected*(timeoutMs: uint32 = 20_000): CpsFuture[uint8] =
    if not bleConnActive:
      if blePeripheralConnectedNotified and
          not blePeripheralDisconnectedNotified:
        notifyDisconnected(0x13'u8)
      return completedLocalFuture(0x13'u8)
    if blePeripheralDisconnectFuture != nil and
        not blePeripheralDisconnectFuture.finished:
      return blePeripheralDisconnectFuture
    blePeripheralDisconnectFuture = newLocalCpsFuture[uint8]()
    if timeoutMs != 0'u32:
      blePeripheralDisconnectTimer = addTimerMs(timeoutMs.uint64, proc() =
        failBlePeripheralDisconnected("BLE peripheral disconnect timed out")
      )
    return blePeripheralDisconnectFuture

  proc bleCentralScan*(name: string,
                       timeoutMs: uint32 = 20_000): BleError =
    let rc = bleCentralScanByName(name.cstring, timeoutMs)
    if rc == 0: bleOk else: bleFail

  proc bleCentralScanAny*(timeoutMs: uint32 = 20_000): BleError =
    let rc = bleCentralScanAnyReport(timeoutMs)
    if rc == 0: bleOk else: bleFail

  proc bleCentralConnect*(name: string,
                          timeoutMs: uint32 = 20_000): BleError =
    let rc = bleCentralConnectByName(name.cstring, timeoutMs)
    if rc == 0: bleOk else: bleFail

  proc bleWaitPeripheralDisconnectedServicedAsync*(
      timeoutMs: uint32 = 20_000'u32,
      periodUs: uint32 = 1000'u32,
      iterations: uint32 = 8'u32): CpsFuture[bool] {.cps.} =
    ## Wait for a peripheral disconnect while keeping the Nim BLE host serviced.
    ## The controller/host pump is bounded and synchronous; this CPS helper owns
    ## the wait cadence so applications do not open-code BLE polling loops.
    if not bleConnActive:
      if blePeripheralConnectedNotified and
          not blePeripheralDisconnectedNotified:
        notifyDisconnected(0x13'u8)
      return blePeripheralDisconnectedNotified

    let delay = if periodUs == 0'u32: 1'u64 else: periodUs.uint64
    let count = if iterations == 0'u32: 1'u32 else: iterations
    let deadline =
      if timeoutMs == 0'u32:
        uint64.high
      else:
        readTick() + usToTicks(timeoutMs.uint64 * 1000'u64)

    while not blePeripheralDisconnectedNotified and readTick() < deadline:
      for _ in 0'u32 ..< count:
        bleHostServicePump()
      await sleepUs(delay)

    if not bleConnActive and blePeripheralConnectedNotified and
        not blePeripheralDisconnectedNotified:
      notifyDisconnected(0x13'u8)
    return blePeripheralDisconnectedNotified

  proc bleDisconnect*(reason: uint8 = 0x13'u8,
                      timeoutMs: uint32 = 2_000): BleError =
    let rc = bleDisconnectCurrent(reason, timeoutMs)
    if rc == 0: bleOk else: bleFail
