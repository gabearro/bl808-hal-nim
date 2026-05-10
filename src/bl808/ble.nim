## BL808 BLE 5.0 controller interface.
##
## The BL808 M0 core uses the BLE controller shared with BL602.
## Precompiled blob: libblecontroller_bl602_m1s1.a (1 master, 1 slave)
##                or libblecontroller_bl602_m8s1.a (8 masters, 1 slave)
##
## Link flags: --passL:"-lblecontroller_bl602_m1s1"
##
## The BLE host stack uses a Zephyr BLE port with standard bt_* APIs.
## This module provides:
##   1. Controller-level init (blob API from ble_lib_api.h)
##   2. HCI on-chip interface for host<->controller communication
##   3. Zephyr BLE host stack declarations (bt_enable, bt_le_adv_*, etc.)

# =============================================================================
# BLE Controller C API (from ble_lib_api.h, libblecontroller.a)
# =============================================================================
when defined(bl808m0):
  import core, mmio

  when defined(bl808BleVendor):
    import bleblob as blecontroller
  else:
    import blecontroller

  type
    BleInitStageCb* = proc(stage: cstring) {.cdecl.}

  var bleControllerStarted: bool

  when defined(bl808BleVendorLldScanProbe):
    const BleCentralTraceBaseLocal = 0x40002F00'u32

    var bleHciSendReturnShadow: uint32
    var bleHciCommandReturnShadow: uint32
    var bleHciCommandDiag0: uint32
    var bleHciCommandDiag1: uint32
    var bleScanStartDiag: uint32

    const
      BleHciSendRaOffset = 12'u32
      BleHciCommandRaOffset = 284'u32

    template bleProbeTraceWord(offset: uint32, value: uint32) =
      regWrite((BleCentralTraceBaseLocal + offset).uint, value)

    template bleProbeTraceReadWord(offset: uint32): uint32 =
      regRead((BleCentralTraceBaseLocal + offset).uint)

    template bleHciSendReadSp(): uint32 =
      block:
        var v: uint32
        {.emit: ["asm volatile(\"mv %0, sp\" : \"=r\"(", v, "));"].}
        v

    template bleHciSendRestoreRa(expected: uint32, offset: uint32) =
      block:
        let expectedRa = expected
        if expectedRa != 0'u32:
          let slot = bleHciSendReadSp() + offset
          if regRead(slot.uint) != expectedRa:
            regWrite(slot.uint, expectedRa)

    template bleHciSendRestoreSendRaFromTrace() =
      {.emit: """
      asm volatile(
          "li t0, 0x40002F3C\n"
          "lw t1, 0(t0)\n"
          "beqz t1, 1f\n"
          "addi t0, sp, 12\n"
          "lw t2, 0(t0)\n"
          "beq t1, t2, 1f\n"
          "sw t1, 0(t0)\n"
          "1:\n"
          ::: "t0", "t1", "t2", "memory");
      """.}

    template bleHciSendRestoreCommandRaFromTrace() =
      {.emit: """
      asm volatile(
          "li t0, 0x40002F38\n"
          "lw t1, 0(t0)\n"
          "beqz t1, 1f\n"
          "addi t0, sp, 284\n"
          "lw t2, 0(t0)\n"
          "beq t1, t2, 1f\n"
          "sw t1, 0(t0)\n"
          "1:\n"
          ::: "t0", "t1", "t2", "memory");
      """.}

    template bleHciReadExpectedOpcodeFromTrace(): uint32 =
      block:
        var v: uint32
        {.emit: [
          "asm volatile(\"li t0, 0x40002F40\\n\\tlw %0, 0(t0)\" : \"=r\"(",
          v, ") : : \"t0\", \"memory\");"
        ].}
        v

  proc reportBleInitStage(stageCb: BleInitStageCb, stage: cstring) {.inline.} =
    if stageCb != nil:
      stageCb(stage)

  proc bleControllerInitRawWithStage*(taskPriority: uint8,
                                      stageCb: BleInitStageCb) {.cdecl.} =
    ## Initialize BLE controller. `taskPriority` is the RTOS task priority.
    if bleControllerStarted:
      reportBleInitStage(stageCb, "already started")
      return
    when defined(bl808BleVendor):
      reportBleInitStage(stageCb, "before wireless domain")
      blecontroller.bleBlobPrepareWirelessDomain()
      reportBleInitStage(stageCb, "after wireless domain")
      blecontroller.bleBlobAllowAssertReturn()
      reportBleInitStage(stageCb, "after assert return")
      reportBleInitStage(stageCb, "before controller init")
      blecontroller.ble_controller_init(taskPriority)
      reportBleInitStage(stageCb, "after controller init")
    else:
      discard taskPriority
      reportBleInitStage(stageCb, "before controller init")
      when defined(bl808BleDebugSplitControllerInit):
        blecontroller.bflbble_init()
        reportBleInitStage(stageCb, "after bflbble_init")
        blecontroller.bflbip_init()
        reportBleInitStage(stageCb, "after bflbip_init")
        blecontroller.ble_ke_init()
        reportBleInitStage(stageCb, "after ble_ke_init")
        blecontroller.em_buf_init()
        reportBleInitStage(stageCb, "after em_buf_init")
        blecontroller.hci_init(false)
        reportBleInitStage(stageCb, "after hci_init")
        blecontroller.llc_init()
        reportBleInitStage(stageCb, "after llc_init")
        blecontroller.lld_init(false)
        reportBleInitStage(stageCb, "after lld_init")
        blecontroller.llm_init()
        reportBleInitStage(stageCb, "after llm_init")
        blecontroller.ecc_init()
        reportBleInitStage(stageCb, "after ecc_init")
        blecontroller.lld_sleep_init()
        reportBleInitStage(stageCb, "after lld_sleep_init")
        blecontroller.lld_evt_init()
        reportBleInitStage(stageCb, "after lld_evt_init")
        blecontroller.bdaddr_init()
        reportBleInitStage(stageCb, "after bdaddr_init")
        blecontroller.ble_controller_task_init(nil)
      else:
        blecontroller.ble_controller_init(taskPriority)
      reportBleInitStage(stageCb, "after controller init")
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
    when defined(bl808BleVendor):
      blecontroller.ble_controller_sleep(maxSleepCycles)
    else:
      blecontroller.ble_controller_sleep(maxSleepCycles)

  proc ble_controller_sleep_restore*() {.cdecl.} =
    ## Restore after BLE sleep.
    when defined(bl808BleVendor):
      blecontroller.ble_controller_sleep_restore()
    else:
      blecontroller.ble_controller_sleep_restore()

  proc ble_controller_set_tx_pwr*(bleTxPower: cint) {.cdecl.} =
    ## Set BLE TX power level.
    blecontroller.ble_controller_set_tx_pwr(bleTxPower)

  proc ble_controller_get_tx_pwr*(): int8 {.cdecl.} =
    blecontroller.ble_controller_get_tx_pwr()

  # --- HCI on-chip interface (host<->controller) ---
  type
    HciRecvCb* = proc(data: ptr uint8, len: uint16): uint8 {.cdecl.}

  var hciRecvCb: HciRecvCb
  var hciLastPktType: uint8
  var hciLastLen: uint8
  var hciLastWord0: uint32
  var hciLastWord1: uint32
  var hciLastOpcode: uint16
  var hciLastStatus: int16 = -1
  var hciEventBuf: array[260, uint8]

  proc bt_onchiphci_interface_init*(cb: HciRecvCb): uint8 {.cdecl.} =
    ## Initialize the on-chip HCI interface.
    ## `cb` is called when the controller sends data to the host.
    hciRecvCb = cb
    proc bridge(pktType: uint8, srcId: uint16, param: ptr uint8,
                paramLen: uint8) {.cdecl.} =
      hciLastPktType = pktType
      hciLastLen = paramLen
      hciLastWord0 = 0
      hciLastWord1 = 0
      hciLastOpcode = 0
      hciLastStatus = -1
      if param != nil:
        let raw = cast[ptr UncheckedArray[uint8]](param)
        for i in 0 ..< min(paramLen.int, 4):
          hciLastWord0 = hciLastWord0 or (raw[i].uint32 shl (i * 8))
        for i in 0 ..< min(max(paramLen.int - 4, 0), 4):
          hciLastWord1 = hciLastWord1 or (raw[i + 4].uint32 shl (i * 8))
        case pktType
        of 2'u8, 3'u8:
          hciLastOpcode = srcId
          if paramLen > 0:
            hciLastStatus = raw[0].int16
        else:
          discard
        if paramLen >= 6 and raw[0] == 0x0E'u8:
          hciLastOpcode = raw[3].uint16 or (raw[4].uint16 shl 8)
          hciLastStatus = raw[5].int16
        elif paramLen >= 6 and raw[0] == 0x0F'u8:
          hciLastStatus = raw[3].int16
          hciLastOpcode = raw[4].uint16 or (raw[5].uint16 shl 8)
      if hciRecvCb != nil:
        var cbParam = param
        var cbLen = paramLen.uint16
        if param != nil:
          case pktType
          of 4'u8:
            hciEventBuf[0] = 0x3E'u8
            hciEventBuf[1] = paramLen
            let raw = cast[ptr UncheckedArray[uint8]](param)
            for i in 0 ..< paramLen.int:
              hciEventBuf[i + 2] = raw[i]
            cbParam = addr hciEventBuf[0]
            cbLen = paramLen.uint16 + 2
          of 5'u8, 7'u8:
            hciEventBuf[0] = uint8(srcId and 0xFF)
            hciEventBuf[1] = paramLen
            let raw = cast[ptr UncheckedArray[uint8]](param)
            for i in 0 ..< paramLen.int:
              hciEventBuf[i + 2] = raw[i]
            cbParam = addr hciEventBuf[0]
            cbLen = paramLen.uint16 + 2
          else:
            discard
        when defined(bl808BleVendorLldScanProbe):
          blecontroller.bleCentralDebugMark(
            0x930'u32, (uint32(pktType) shl 16) or uint32(srcId))
        discard hciRecvCb(cbParam, cbLen)
        when defined(bl808BleVendorLldScanProbe):
          blecontroller.bleCentralDebugMark(
            0x931'u32, (uint32(pktType) shl 16) or uint32(srcId))
    when defined(bl808BleVendor):
      discard blecontroller.bt_onchiphci_interface_init(bridge)
    else:
      discard blecontroller.bt_onchiphci_interface_init(bridge)
    0

  proc bt_onchiphci_send*(pktType: uint8, destId: uint16,
                          pkt: pointer): int8 {.cdecl.} =
    ## Send an HCI packet from host to controller.
    when defined(bl808BleVendor):
      discard pktType
      if pkt == nil or destId < 3:
        return -1'i8
      let raw = cast[ptr UncheckedArray[uint8]](pkt)
      let opcode = raw[0].uint16 or (raw[1].uint16 shl 8)
      let paramLen = raw[2]
      if destId < uint16(3 + paramLen.int):
        return -1'i8
      let params =
        if paramLen == 0: nil
        else: cast[ptr uint8](cast[uint](pkt) + 3'u)
      blecontroller.bleBlobHciCommand(opcode, params, paramLen)
    else:
      discard pktType
      when defined(bl808BleVendorLldScanProbe):
        let entrySp = bleHciSendReadSp()
        let sendReturnShadow = regRead((entrySp + BleHciSendRaOffset).uint)
        bleHciSendReturnShadow = sendReturnShadow
        bleProbeTraceWord(60'u32, sendReturnShadow)
        blecontroller.bleCentralDebugMark(0x940'u32, uint32(destId))
      let ok = blecontroller.bt_onchiphci_send_raw(pkt, destId)
      when defined(bl808BleVendorLldScanProbe):
        blecontroller.bleCentralDebugMark(0x941'u32, if ok: 1'u32 else: 0'u32)
        bleHciSendRestoreSendRaFromTrace()
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
    BlePeripheralIdleDisconnectPolls {.intdefine.}: uint32 = 1_000

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
    bleNameStorage: array[32, char]
    bleConnCb: ptr BtConnCb
    bleScanCb: BtLeScanCb
    bleScanActive: bool
    bleAdvActive: bool
    bleScanData: BtScanData
    bleConn: BtConn
    bleConnActive: bool
    bleConnPending: bool
    bleCentralTargetName: array[32, char]
    bleCentralTargetActive: bool
    bleCentralPeerFound: bool
    bleCentralPeer: BtAddrLe
    bleCentralConnected: bool
    blePeripheralConnEventsSeen: uint32
    blePeripheralDiscEventsSeen: uint32
    blePeripheralConnectedNotified: bool
    blePeripheralLastLlcpRx: uint32
    blePeripheralIdlePolls: uint32
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

  const
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
    HciEvtDisconnectComplete = 0x05'u8
    HciEvtLeMeta = 0x3E'u8
    HciLeEvtConnectionComplete = 0x01'u8
    HciLeEvtAdvertisingReport = 0x02'u8
    HciLeEvtEnhancedConnectionComplete = 0x0A'u8
    MacosCentralServiceUuidLe = [
      0xF0'u8, 0xDE, 0xBC, 0x9A, 0x78, 0x56, 0x34, 0x12,
      0x78, 0x56, 0x34, 0x12, 0x78, 0x56, 0x34, 0x12,
    ]
    bl808BleNimSyntheticCentral* {.booldefine.}: bool = true
    bl808BleCentralScanRestartMs* {.intdefine.}: int = 500

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

  proc hciCommandOk(opcode: uint16, params: ptr uint8,
                    paramLen: uint8, polls: int = 64): bool =
    when defined(bl808BleVendor):
      resetHciLast()
      if blecontroller.bleBlobHciCommand(opcode, params, paramLen) != 0:
        return false
      for _ in 0 ..< polls:
        if hciLastOpcode == opcode:
          break
        blecontroller.bleBlobPoll(16)
      hciLastOpcode == opcode and hciLastStatus == 0
    else:
      discard polls
      var pkt: array[260, uint8]
      if paramLen.int + 3 > pkt.len:
        return false
      when defined(bl808BleVendorLldScanProbe):
        let entrySp = bleHciSendReadSp()
        let commandReturnShadow =
          regRead((entrySp + BleHciCommandRaOffset).uint)
        bleHciCommandReturnShadow = commandReturnShadow
        bleProbeTraceWord(56'u32, commandReturnShadow)
      resetHciLast()
      pkt[0] = uint8(opcode and 0xFF)
      pkt[1] = uint8((opcode shr 8) and 0xFF)
      pkt[2] = paramLen
      if params != nil:
        let src = cast[ptr UncheckedArray[uint8]](params)
        for i in 0 ..< paramLen.int:
          pkt[i + 3] = src[i]
      when defined(bl808BleVendorLldScanProbe):
        bleProbeTraceWord(64'u32, uint32(opcode))
      let sendRc = bt_onchiphci_send(0, uint16(paramLen.int + 3), addr pkt[0])
      when defined(bl808BleVendorLldScanProbe):
        let expectedOpcode =
          uint16(bleHciReadExpectedOpcodeFromTrace() and 0xFFFF'u32)
      else:
        let expectedOpcode = opcode
      when defined(bl808BleVendorLldScanProbe):
        bleHciCommandDiag0 =
          (uint32(expectedOpcode) shl 16) or
          (cast[uint32](hciLastStatus) and 0xFFFF'u32)
        bleHciCommandDiag1 =
          (uint32(hciLastOpcode) shl 16) or
          ((cast[uint32](sendRc) and 0xFF'u32) shl 8)
        bleProbeTraceWord(40'u32, bleHciCommandDiag0)
        bleProbeTraceWord(44'u32, bleHciCommandDiag1)
      if sendRc != 0:
        when defined(bl808BleVendorLldScanProbe):
          blecontroller.bleCentralDebugMark(0x951'u32, bleHciCommandDiag1)
          bleHciSendRestoreCommandRaFromTrace()
        return false
      result = hciLastOpcode == expectedOpcode and hciLastStatus == 0
      when defined(bl808BleVendorLldScanProbe):
        bleHciCommandDiag1 = bleHciCommandDiag1 or
          (if result: 1'u32 else: 0'u32)
        bleProbeTraceWord(44'u32, bleHciCommandDiag1)
        if not result:
          blecontroller.bleCentralDebugMark(0x953'u32, bleHciCommandDiag1)
        bleHciSendRestoreCommandRaFromTrace()

  proc configureRandomAddress(): bool =
    when defined(bl808BleUseRandomAddr):
      var randomAddr = [0xC0'u8, 0x80, 0x80, 0x05, 0xB9, 0x18]
      hciCommandOk(HciOpLeSetRandomAddress,
                   addr randomAddr[0],
                   randomAddr.len.uint8)
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
      if (dataType == 0x06'u8 or dataType == 0x07'u8) and valueLen >= 16:
        let value = cast[ptr UncheckedArray[uint8]](
          cast[uint](data) + uint(pos + 2))
        var uuidOffset = 0
        while uuidOffset + 16 <= valueLen:
          var uuidMatches = true
          for i in 0 ..< MacosCentralServiceUuidLe.len:
            if value[uuidOffset + i] != MacosCentralServiceUuidLe[i]:
              uuidMatches = false
              break
          if uuidMatches:
            return true
          uuidOffset += 16
      pos += 1 + fieldLen
    false

  proc notifyConnected(err: uint8) =
    if bleConnCb != nil and bleConnCb.connected != nil:
      bleConnCb.connected(addr bleConn, err)

  proc notifyDisconnected(reason: uint8) =
    if bleConnCb != nil and bleConnCb.disconnected != nil:
      bleConnCb.disconnected(addr bleConn, reason)

  proc notifyPeripheralConnectedFromController() =
    when defined(bl808BleVendorLldConProbe):
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
      blePeripheralLastLlcpRx = blecontroller.bleNimDbgVendorLlcpRxCount()
      blePeripheralIdlePolls = 0
      blePeripheralConnectedNotified = true
      notifyConnected(0)

  proc blePollHostEvents*() {.cdecl.} =
    ## Drain controller-side Nim peripheral link events into the host callback
    ## API. Vendor firmware reports these through HCI; the Nim/vendor-LLD
    ## bridge records them in controller counters to avoid re-entering the HCI
    ## callback chain from the low-level connection-start path.
    when defined(bl808BleVendor):
      discard
    else:
      when defined(bl808BleVendorLldConProbe):
        let connEvents = blecontroller.bleNimPeripheralConnEventCount()
        if connEvents != blePeripheralConnEventsSeen:
          blePeripheralConnEventsSeen = connEvents
        let controllerStarted = blecontroller.bleNimDbgVendorConStarted() != 0'u32
        if (connEvents != 0'u32 or controllerStarted) and
            not blePeripheralConnectedNotified:
          notifyPeripheralConnectedFromController()

        let discEvents = blecontroller.bleNimPeripheralDiscEventCount()
        if discEvents != blePeripheralDiscEventsSeen:
          blePeripheralDiscEventsSeen = discEvents
          let reason =
            uint8(blecontroller.bleNimPeripheralDiscReason() and 0xFF'u32)
          bleConnActive = false
          bleConnPending = false
          bleCentralConnected = false
          blePeripheralIdlePolls = 0
          notifyDisconnected(reason)
          blePeripheralConnectedNotified = false
        elif bleConnActive and bleConn.role == 1'u8:
          let llcpRx = blecontroller.bleNimDbgVendorLlcpRxCount()
          if llcpRx != blePeripheralLastLlcpRx:
            blePeripheralLastLlcpRx = llcpRx
            blePeripheralIdlePolls = 0
          elif blePeripheralIdlePolls < BlePeripheralIdleDisconnectPolls:
            inc blePeripheralIdlePolls
          else:
            bleConnActive = false
            bleConnPending = false
            bleCentralConnected = false
            notifyDisconnected(0x13'u8)
      else:
        discard

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
    if not bleHostEnabled:
      bleHostEnabled = true
      discard bt_onchiphci_interface_init(bleHostHciEvent)
      discard hciCommandOk(HciOpReset, nil, 0)
    if cb != nil:
      cb(0)
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
    discard param
    discard ad
    discard adLen
    discard sd
    discard sdLen
    if not bleHostEnabled:
      return -1
    bleAdvActive = false
    blePeripheralConnectedNotified = false
    when defined(bl808BleVendorLldConProbe):
      blePeripheralConnEventsSeen =
        blecontroller.bleNimPeripheralConnEventCount()
      blePeripheralDiscEventsSeen =
        blecontroller.bleNimPeripheralDiscEventCount()
    var advParams: array[15, uint8]
    advParams[0] = 0xA0'u8
    advParams[1] = 0x00'u8
    advParams[2] = 0xA0'u8
    advParams[3] = 0x00'u8
    advParams[4] = 0x00'u8
    when defined(bl808BleUseRandomAddr):
      if not configureRandomAddress():
        return -1
      advParams[5] = 0x01'u8
    else:
      advParams[5] = 0x00'u8
    advParams[13] = 0x07'u8
    advParams[14] = 0x00'u8
    if not hciCommandOk(HciOpLeSetAdvParams,
                        addr advParams[0],
                        advParams.len.uint8):
      return -1

    var advPayload: array[32, uint8]
    var p = 1
    advPayload[p] = 2
    inc p
    advPayload[p] = 0x01
    inc p
    advPayload[p] = 0x06
    inc p
    let name = cast[ptr UncheckedArray[uint8]](addr bleNameStorage[0])
    var nameLen = 0
    while nameLen < 26 and name[nameLen] != 0:
      inc nameLen
    if nameLen > 0:
      advPayload[p] = uint8(nameLen + 1)
      inc p
      advPayload[p] = 0x09
      inc p
      for i in 0 ..< nameLen:
        advPayload[p] = name[i]
        inc p
    if adLen == 0 and p + 9 <= advPayload.len:
      advPayload[p] = 8
      inc p
      advPayload[p] = 0xFF
      inc p
      advPayload[p] = 0xFF
      inc p
      advPayload[p] = 0xFF
      inc p
      let marker = [0x42'u8, 0x4C, 0x38, 0x30, 0x38]
      for b in marker:
        advPayload[p] = b
        inc p
    advPayload[0] = uint8(p - 1)
    if not hciCommandOk(HciOpLeSetAdvData,
                        addr advPayload[0],
                        advPayload.len.uint8):
      return -1

    var scanRsp: array[32, uint8]
    p = 1
    if nameLen > 0:
      scanRsp[p] = uint8(nameLen + 1)
      inc p
      scanRsp[p] = 0x09
      inc p
      for i in 0 ..< nameLen:
        scanRsp[p] = name[i]
        inc p
    scanRsp[0] = uint8(p - 1)
    if not hciCommandOk(HciOpLeSetScanRspData,
                        addr scanRsp[0],
                        scanRsp.len.uint8):
      return -1

    var enable = 1'u8
    if not hciCommandOk(HciOpLeSetAdvEnable, addr enable, 1):
      return -1
    bleAdvActive = true
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
    when defined(bl808BleUseRandomAddr):
      if not configureRandomAddress():
        return -1
    scanParams[0] = scanType
    scanParams[1] = uint8(interval and 0xFF)
    scanParams[2] = uint8(interval shr 8)
    scanParams[3] = uint8(window and 0xFF)
    scanParams[4] = uint8(window shr 8)
    when defined(bl808BleUseRandomAddr):
      scanParams[5] = 0x01'u8
    else:
      scanParams[5] = 0x00'u8
    scanParams[6] = 0x00'u8
    when defined(bl808BleVendorLldScanProbe):
      blecontroller.bleCentralDebugMark(0x130'u32, 0)
    if not hciCommandOk(HciOpLeSetScanParams,
                        addr scanParams[0],
                        scanParams.len.uint8):
      when defined(bl808BleVendorLldScanProbe):
        bleScanStartDiag = 0x13F00000'u32 or
          (bleHciCommandDiag1 and 0x00FFFFFF'u32)
        bleProbeTraceWord(48'u32, bleScanStartDiag)
        blecontroller.bleCentralDebugMark(0x13F'u32, bleScanStartDiag)
      return -1
    when defined(bl808BleVendorLldScanProbe):
      blecontroller.bleCentralDebugMark(0x131'u32, 0)
    var enable = [0x01'u8, filterDup]
    when defined(bl808BleVendorLldScanProbe):
      blecontroller.bleCentralDebugMark(0x140'u32, uint32(filterDup))
    if not hciCommandOk(HciOpLeSetScanEnable, addr enable[0], enable.len.uint8):
      when defined(bl808BleVendorLldScanProbe):
        bleScanStartDiag = 0x14F00000'u32 or
          (bleHciCommandDiag1 and 0x00FFFFFF'u32)
        bleProbeTraceWord(48'u32, bleScanStartDiag)
        blecontroller.bleCentralDebugMark(0x14F'u32, bleScanStartDiag)
      return -1
    when defined(bl808BleVendorLldScanProbe):
      blecontroller.bleCentralDebugMark(0x141'u32, 0)
    bleScanActive = true
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
    when defined(bl808BleVendorLldScanProbe):
      blecontroller.nim_vendor_scan_report_count
    else:
      0

  proc bleControllerScanProbeStartStatus*(): uint32 {.cdecl.} =
    when defined(bl808BleVendorLldScanProbe):
      blecontroller.nim_vendor_scan_start_status
    else:
      0

  proc bleControllerScanProbeArbInsertCount*(): uint32 {.cdecl.} =
    when defined(bl808BleVendorLldScanProbe):
      blecontroller.nim_vendor_scan_arb_insert_count
    else:
      0

  proc bleControllerScanProbeArbCallbackCount*(): uint32 {.cdecl.} =
    when defined(bl808BleVendorLldScanProbe):
      blecontroller.nim_vendor_scan_arb_cb_count
    else:
      0

  proc bleControllerScanProbeSwIntCount*(): uint32 {.cdecl.} =
    when defined(bl808BleVendorLldScanProbe):
      blecontroller.nim_vendor_scan_sw_int_count
    else:
      0

  proc bleControllerScanProbeRestartCount*(): uint32 {.cdecl.} =
    when defined(bl808BleVendorLldScanProbe):
      blecontroller.nim_vendor_scan_restart_count
    else:
      0

  proc bleControllerScanProbeUnsupportedCount*(): uint32 {.cdecl.} =
    when defined(bl808BleVendorLldScanProbe):
      blecontroller.nim_vendor_scan_unsupported_count
    else:
      0

  proc bleControllerScanProbeUnsupportedHeader*(): uint32 {.cdecl.} =
    when defined(bl808BleVendorLldScanProbe):
      blecontroller.nim_vendor_scan_unsupported_header
    else:
      0

  proc bleControllerScanProbeUnsupportedLen*(): uint32 {.cdecl.} =
    when defined(bl808BleVendorLldScanProbe):
      blecontroller.nim_vendor_scan_unsupported_len
    else:
      0

  proc bleControllerScanProbeUnsupportedByte*(index: uint8): uint8 {.cdecl.} =
    when defined(bl808BleVendorLldScanProbe):
      if index.int < blecontroller.nim_vendor_scan_unsupported_data.len:
        blecontroller.nim_vendor_scan_unsupported_data[index.int]
      else:
        0
    else:
      discard index
      0

  proc bleControllerInitProbeStartStatus*(): uint32 {.cdecl.} =
    when defined(bl808BleVendorLldInitProbe):
      blecontroller.nim_vendor_init_start_status
    else:
      0

  proc bleControllerInitProbeMessageCount*(): uint32 {.cdecl.} =
    when defined(bl808BleVendorLldInitProbe):
      blecontroller.nim_vendor_init_msg_count
    else:
      0

  proc bleControllerInitProbeSuccessCount*(): uint32 {.cdecl.} =
    when defined(bl808BleVendorLldInitProbe):
      blecontroller.nim_vendor_init_success_count
    else:
      0

  proc bleControllerInitProbeFailureCount*(): uint32 {.cdecl.} =
    when defined(bl808BleVendorLldInitProbe):
      blecontroller.nim_vendor_init_failure_count
    else:
      0

  proc bleControllerInitProbeLastActivity*(): uint32 {.cdecl.} =
    when defined(bl808BleVendorLldInitProbe):
      blecontroller.nim_vendor_init_last_activity
    else:
      0

  proc bleControllerInitProbeLastMessageStatus*(): uint32 {.cdecl.} =
    when defined(bl808BleVendorLldInitProbe):
      blecontroller.nim_vendor_init_last_msg_status
    else:
      0

  proc bleControllerInitProbeCancelStatus*(): uint32 {.cdecl.} =
    when defined(bl808BleVendorLldInitProbe):
      blecontroller.nim_vendor_init_cancel_status
    else:
      0

  proc bleControllerInitProbeCancelCount*(): uint32 {.cdecl.} =
    when defined(bl808BleVendorLldInitProbe):
      blecontroller.nim_vendor_init_cancel_count
    else:
      0

  proc bleControllerInitProbeHeaderFixCount*(): uint32 {.cdecl.} =
    when defined(bl808BleVendorLldInitProbe):
      blecontroller.nim_vendor_init_header_fix_count
    else:
      0

  proc bleControllerInitProbeParamByte*(index: uint8): uint8 {.cdecl.} =
    when defined(bl808BleVendorLldInitProbe):
      blecontroller.ble_init_probe_param_byte(index)
    else:
      discard index
      0

  proc bleControllerInitProbeArbInsertCount*(): uint32 {.cdecl.} =
    when defined(bl808BleVendorLldInitProbe):
      blecontroller.nim_vendor_init_arb_insert_count
    else:
      0

  proc bleControllerInitProbeArbCallbackCount*(): uint32 {.cdecl.} =
    when defined(bl808BleVendorLldInitProbe):
      blecontroller.nim_vendor_init_arb_cb_count
    else:
      0

  proc bleControllerInitProbeArbLastWord*(index: uint8): uint32 {.cdecl.} =
    when defined(bl808BleVendorLldInitProbe):
      case index
      of 1'u8: blecontroller.nim_vendor_init_arb_last_w1
      of 2'u8: blecontroller.nim_vendor_init_arb_last_w2
      of 7'u8: blecontroller.nim_vendor_init_arb_last_w7
      of 24'u8: blecontroller.nim_vendor_init_arb_last_w24
      of 28'u8: blecontroller.nim_vendor_init_arb_last_w28
      else: 0
    else:
      discard index
      0

  proc bleControllerInitProbePeerRxCount*(): uint32 {.cdecl.} =
    when defined(bl808BleVendorLldInitProbe):
      blecontroller.nim_vendor_init_peer_rx_count
    else:
      0

  proc bleControllerInitProbePeerHitCount*(): uint32 {.cdecl.} =
    when defined(bl808BleVendorLldInitProbe):
      blecontroller.nim_vendor_init_peer_hit_count
    else:
      0

  proc bleControllerInitProbePeerRxLastHeader*(): uint32 {.cdecl.} =
    when defined(bl808BleVendorLldInitProbe):
      blecontroller.nim_vendor_init_peer_rx_last_header
    else:
      0

  proc bleControllerInitProbePeerRxLastStatus*(): uint32 {.cdecl.} =
    when defined(bl808BleVendorLldInitProbe):
      blecontroller.nim_vendor_init_peer_rx_last_status
    else:
      0

  proc bleControllerInitProbePeerRxLastMeta*(): uint32 {.cdecl.} =
    when defined(bl808BleVendorLldInitProbe):
      blecontroller.nim_vendor_init_peer_rx_last_meta
    else:
      0

  proc bleControllerInitProbeStatusFixCount*(): uint32 {.cdecl.} =
    when defined(bl808BleVendorLldInitProbe):
      blecontroller.nim_vendor_init_status_fix_count
    else:
      0

  proc bleControllerInitProbeStatusFixLast*(): uint32 {.cdecl.} =
    when defined(bl808BleVendorLldInitProbe):
      blecontroller.nim_vendor_init_status_fix_last
    else:
      0

  proc bleControllerInitProbeMessageAllocCount*(): uint32 {.cdecl.} =
    when defined(bl808BleVendorLldInitProbe):
      blecontroller.nim_vendor_init_msg_alloc_count
    else:
      0

  proc bleControllerInitProbeMessageAllocLen*(): uint32 {.cdecl.} =
    when defined(bl808BleVendorLldInitProbe):
      blecontroller.nim_vendor_init_msg_alloc_last_len
    else:
      0

  proc bleControllerInitProbeMessageAllocDest*(): uint32 {.cdecl.} =
    when defined(bl808BleVendorLldInitProbe):
      blecontroller.nim_vendor_init_msg_alloc_last_dest
    else:
      0

  proc bleControllerInitProbeMessageAllocSrc*(): uint32 {.cdecl.} =
    when defined(bl808BleVendorLldInitProbe):
      blecontroller.nim_vendor_init_msg_alloc_last_src
    else:
      0

  proc bleControllerInitProbeAccessAddressCount*(): uint32 {.cdecl.} =
    when defined(bl808BleVendorLldInitProbe):
      blecontroller.nim_lld_aa_gen_count
    else:
      0

  proc bleControllerInitProbeAccessAddress*(): uint32 {.cdecl.} =
    when defined(bl808BleVendorLldInitProbe):
      blecontroller.nim_lld_aa_last
    else:
      0

  proc bleControllerInitProbeAccessAddressSeed*(): uint32 {.cdecl.} =
    when defined(bl808BleVendorLldInitProbe):
      blecontroller.nim_lld_aa_last_seed
    else:
      0

  proc bleControllerInitProbePacketDurationCount*(): uint32 {.cdecl.} =
    when defined(bl808BleVendorLldInitProbe):
      blecontroller.nim_vendor_init_pkt_dur_count
    else:
      0

  proc bleControllerInitProbePacketDurationLen*(): uint32 {.cdecl.} =
    when defined(bl808BleVendorLldInitProbe):
      blecontroller.nim_vendor_init_pkt_dur_last_len
    else:
      0

  proc bleControllerInitProbePacketDurationRate*(): uint32 {.cdecl.} =
    when defined(bl808BleVendorLldInitProbe):
      blecontroller.nim_vendor_init_pkt_dur_last_rate
    else:
      0

  proc bleControllerSchProgFifoCount*(): uint32 {.cdecl.} =
    when defined(bl808BleVendorLldScanProbe):
      blecontroller.bleNimDbgVendorSchProgFifoCount()
    else:
      0

  proc bleControllerSchProgSkipCount*(): uint32 {.cdecl.} =
    when defined(bl808BleVendorLldScanProbe):
      blecontroller.bleNimDbgVendorSchProgSkipCount()
    else:
      0

  proc bleControllerIsrCount*(): uint32 {.cdecl.} =
    when defined(bl808BleVendor):
      0
    else:
      blecontroller.ble_dbg_isr_count()

  proc bleControllerIsrStatOr*(): uint32 {.cdecl.} =
    when defined(bl808BleVendor):
      0
    else:
      blecontroller.ble_dbg_isr_stat_or()

  proc bleControllerStat20Count*(): uint32 {.cdecl.} =
    when defined(bl808BleVendor):
      0
    else:
      blecontroller.ble_dbg_stat20_count()

  proc bleControllerStat8000Count*(): uint32 {.cdecl.} =
    when defined(bl808BleVendor):
      0
    else:
      blecontroller.ble_dbg_stat8000_count()

  proc bleControllerRxCheckCount*(): uint32 {.cdecl.} =
    when defined(bl808BleVendorLldConProbe) or defined(bl808BleVendorLldScanProbe):
      blecontroller.nim_lld_rx_check_count
    else:
      0

  proc bleControllerRxCheckHitCount*(): uint32 {.cdecl.} =
    when defined(bl808BleVendorLldConProbe) or defined(bl808BleVendorLldScanProbe):
      blecontroller.nim_lld_rx_check_hit_count
    else:
      0

  proc bleControllerRxFreeCount*(): uint32 {.cdecl.} =
    when defined(bl808BleVendorLldConProbe) or defined(bl808BleVendorLldScanProbe):
      blecontroller.nim_lld_rx_free_count
    else:
      0

  proc bleControllerRxLastStatus*(): uint32 {.cdecl.} =
    when defined(bl808BleVendorLldConProbe) or defined(bl808BleVendorLldScanProbe):
      blecontroller.nim_lld_rx_last_status
    else:
      0

  proc bleControllerRxLastHeader*(): uint32 {.cdecl.} =
    when defined(bl808BleVendorLldConProbe) or defined(bl808BleVendorLldScanProbe):
      blecontroller.nim_lld_rx_last_header
    else:
      0

  proc synthesizeCentralReportIfNeeded() =
    when not defined(bl808BleVendor):
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

  proc bt_conn_create_le*(peer: ptr BtAddrLe,
                          param: ptr BtLeConnParam): ptr BtConn {.cdecl.} =
    if not bleHostEnabled or peer == nil:
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
    connParams[0] = 0x60'u8
    connParams[1] = 0x00'u8
    connParams[2] = 0x30'u8
    connParams[3] = 0x00'u8
    connParams[4] = 0x00'u8
    connParams[5] = peer.addrType
    for i in 0 ..< peer.a.len:
      connParams[6 + i] = peer.a[i]
    when defined(bl808BleUseRandomAddr):
      if not configureRandomAddress():
        bleConnPending = false
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
    bleCentralConnected = false
    if not hciCommandOk(HciOpLeCreateConnection,
                        addr connParams[0],
                        connParams.len.uint8):
      bleConnPending = false
      return nil
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

  proc bleCentralConnectByName*(name: cstring,
                                timeoutMs: uint32 = 20_000): cint {.cdecl.} =
    if not bleHostEnabled:
      return -1
    copyCentralTargetName(name)
    bleCentralTargetActive = true
    bleCentralPeerFound = false
    bleCentralConnected = false
    bleScanReportCounter = 0
    bleScanNameMatchCounter = 0
    bleScanMatchedEventType = 0
    bleScanMatchedAddrType = 0
    bleScanMatchedDataLen = 0
    for i in 0 ..< bleScanMatchedAddr.len:
      bleScanMatchedAddr[i] = 0
    for i in 0 ..< bleScanMatchedData.len:
      bleScanMatchedData[i] = 0
    bleConnPending = false
    var scanParam = BtLeScanParam(
      scanType: 0x01'u8,
      filterDup: 0x00'u8,
      interval: 0x0060'u16,
      window: 0x0030'u16,
    )
    when defined(bl808BleVendorLldScanProbe):
      blecontroller.bleCentralDebugMark(0x100'u32, timeoutMs)
    let scanStartRc = bt_le_scan_start(addr scanParam, nil)
    if scanStartRc != 0:
      when defined(bl808BleVendorLldScanProbe):
        bleProbeTraceWord(52'u32, cast[uint32](scanStartRc))
        blecontroller.bleCentralDebugMark(0x1FF'u32, bleScanStartDiag)
      return -1
    when defined(bl808BleVendorLldScanProbe):
      blecontroller.bleCentralDebugMark(0x110'u32, 0)
    var waited = 0'u32
    var connectStarted = false
    while waited < timeoutMs:
      when defined(bl808BleVendor):
        blecontroller.bleBlobPoll(32)
      else:
        when defined(bl808BleVendorLldScanProbe):
          blecontroller.bleCentralDebugMark(0x120'u32, waited)
          blecontroller.bflbble_isr()
          blecontroller.bleCentralDebugMark(0x121'u32, waited)
          when defined(bl808BleVendorLldInitProbe) and
              defined(bl808BleVendorInitPeerComplete):
            if connectStarted:
              blecontroller.bleCentralDebugMark(0x400'u32, waited)
              if blecontroller.ble_init_probe_service_peer_complete() != 0'u8:
                blecontroller.bleCentralDebugMark(0x401'u32, waited)
                bleConn.status = 0
                bleConn.handle = 0
                bleConn.role = 0
                bleConn.peer = bleCentralPeer
                bleConnPending = false
                bleConnActive = true
                bleAdvActive = false
                bleCentralConnected = true
                notifyConnected(0)
          when bl808BleCentralScanRestartMs > 0:
            if waited != 0'u32 and
                (waited mod uint32(bl808BleCentralScanRestartMs)) == 0'u32 and
                not bleCentralPeerFound:
              discard blecontroller.ble_scan_probe_restart()
        if waited >= 250'u32:
          synthesizeCentralReportIfNeeded()
      if bleCentralConnected:
        return 0
      if bleCentralPeerFound and not connectStarted:
        when defined(bl808BleVendorLldScanProbe):
          blecontroller.bleCentralDebugMark(0x200'u32, waited)
        discard bt_le_scan_stop()
        when defined(bl808BleVendorLldScanProbe):
          blecontroller.bleCentralDebugMark(0x211'u32, waited)
        when not defined(bl808BleVendor):
          when defined(bl808BleVendorLldScanProbe):
            for drainIdx in 0 ..< 20:
              blecontroller.bleCentralDebugMark(0x220'u32, drainIdx.uint32)
              blecontroller.bflbble_isr()
              blecontroller.bleCentralDebugMark(0x221'u32, drainIdx.uint32)
              delayUs(1000)
        var connParam = BtLeConnParam(
          intervalMin: 0x0018'u16,
          intervalMax: 0x0028'u16,
          latency: 0'u16,
          timeout: 400'u16,
        )
        when defined(bl808BleVendorLldScanProbe):
          blecontroller.bleCentralDebugMark(0x300'u32, waited)
        if bt_conn_create_le(addr bleCentralPeer, addr connParam) == nil:
          when defined(bl808BleVendorLldScanProbe):
            blecontroller.bleCentralDebugMark(0x3FF'u32, waited)
          bleCentralTargetActive = false
          bleConnPending = false
          return -1
        when defined(bl808BleVendorLldScanProbe):
          blecontroller.bleCentralDebugMark(0x301'u32, waited)
        connectStarted = true
      delayUs(1000)
      inc waited
    if connectStarted:
      when defined(bl808BleVendorLldScanProbe):
        blecontroller.bleCentralDebugMark(0x500'u32, waited)
      discard hciCommandOk(HciOpLeCreateConnectionCancel, nil, 0)
    else:
      when defined(bl808BleVendorLldScanProbe):
        blecontroller.bleCentralDebugMark(0x501'u32, waited)
      discard bt_le_scan_stop()
    bleCentralTargetActive = false
    -1

  proc bleDisconnectCurrent*(reason: uint8 = 0x13'u8,
                             timeoutMs: uint32 = 2_000): cint {.cdecl.} =
    if not bleConnActive:
      return 0
    if bt_conn_disconnect(addr bleConn, reason) != 0:
      return -1
    var waited = 0'u32
    while waited < timeoutMs:
      when defined(bl808BleVendor):
        blecontroller.bleBlobPoll(32)
      if not bleConnActive:
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
    when defined(bl808BleVendor):
      let ver = ble_controller_get_lib_ver()
      if ver == nil:
        ""
      else:
        $ver
    else:
      "bl808-blecontroller-nim-1.0"

  proc bleEnable*(readyCb: BtReadyCb): BleError =
    ## Enable the Zephyr BLE host stack.
    let rc = bt_enable(readyCb)
    if rc == 0: bleOk else: bleFail

  proc bleSetName*(name: string): BleError =
    let rc = bt_set_name(name.cstring)
    if rc == 0: bleOk else: bleFail

  proc bleStartAdvertising*(param: ptr BtLeAdvParam,
                            ad: ptr BtData, adLen: int,
                            sd: ptr BtData = nil, sdLen: int = 0): BleError =
    let rc = bt_le_adv_start(param, ad, adLen.csize_t, sd, sdLen.csize_t)
    if rc == 0: bleOk else: bleFail

  proc bleStopAdvertising*(): BleError =
    let rc = bt_le_adv_stop()
    if rc == 0: bleOk else: bleFail

  proc bleCentralConnect*(name: string,
                          timeoutMs: uint32 = 20_000): BleError =
    let rc = bleCentralConnectByName(name.cstring, timeoutMs)
    if rc == 0: bleOk else: bleFail

  proc bleDisconnect*(reason: uint8 = 0x13'u8,
                      timeoutMs: uint32 = 2_000): BleError =
    let rc = bleDisconnectCurrent(reason, timeoutMs)
    if rc == 0: bleOk else: bleFail
