## Resident Nim M0 anchor with USB console/flash and a UART mux.
##
## UART0 GPIO14/15 keeps the original UFA1 recovery protocol. One USB CDC
## transport multiplexes the anchor and application-owned console/UART ports.
## A cooperative M0 application is loaded from a separate flash slot into
## WRAM; the persistent wrapper is supplied by tools/hw_validate.py.

import bl808/startup
import bl808/mmio
from bl808/memmap import ClicMtimeBase
import bl808/glb, bl808/gpio, bl808/uart, bl808/flash, bl808/cache, bl808/core
import bl808/kernel/usb_anchor_serial
import bl808/kernel/usb_anchor_app_api

const
  ConsoleUartTxPin = 14'u32
  ConsoleUartRxPin = 15'u32
  ConsoleBaud {.intdefine.} = 230_400'u32
  ConsoleClkHz {.intdefine.} = 40_000_000'u32
  Uart1TxPin {.intdefine.} = 20'u32
  Uart1RxPin {.intdefine.} = 21'u32
  Uart2TxPin {.intdefine.} = 22'u32
  Uart2RxPin {.intdefine.} = 23'u32
  ReqMagic = 0x3141_4655'u32 # "UFA1"
  ReqGuard = 0x4853_5246'u32 # "FRSH"
  FlashPrefix = [0x55'u8, 0x46, 0x41, 0x31, 0x46, 0x52, 0x53, 0x48]
  RespMagic = 0x3152_4655'u32 # "UFR1"
  CmdPing = 0'u32
  CmdReadId = 1'u32
  CmdErase = 2'u32
  CmdWriteVerify = 3'u32
  CmdReboot = 4'u32
  ErrOk = 0'u32
  ErrBadCommand = 1'u32
  ErrBadLength = 2'u32
  ErrChecksum = 3'u32
  ErrTimeout = 4'u32
  ErrVerify = 5'u32
  DataMax = 4096
  FlashRxGapUs = 500_000'u32
  FlashRxTotalUs = 5_000_000'u32
  MuxPayloadMax = 48
  SfCtrlCfg1OwnerIahb = 1'u32 shl 28
  SfCtrlCfg1IfEn = 1'u32 shl 29
  SfCtrlCfg1Ahb2SifEn = 1'u32 shl 30
  PowerOnReset = 1'u32 shl 0 # BL808 GLB_SWRST_CFG2[0] resets M0
  MuxMagic0 = 0xA5'u8
  MuxMagic1 = 0x5A'u8
  MuxRegister = 1'u8
  MuxData = 2'u8
  MuxUnregister = 3'u8
  MuxOpen = 4'u8
  MuxClose = 5'u8
  MuxCredit = 6'u8
  RegistrationVersion = 1'u8
  RegistrationRoleConsole = 1'u8
  RegistrationRoleUart = 2'u8
  RegistrationRoleBridge = 3'u8
  AppRxSize = 256
  AppImageMagic = 0x3141_4D55'u32 # "UMA1"
  AppImageVersion = 1'u16
  AppImageHeaderSize = 32'u32
  AppFlashOffset = 0x0004_0000'u32
  AppRamBase = 0x2203_0000'u32
  AppRamCapacity = 112'u32 * 1024'u32

type
  Transport = enum
    viaUart, viaUsb

  Request = object
    command: uint32
    address: uint32
    length: uint32
    headerChecksum: uint32
    payloadChecksum: uint32

  PortRole = enum
    portClosed, portBridge, portAppUart, portAppConsole

var
  console: Uart
  dataBuf: array[DataMax, uint8]
  activeTransport = viaUart
  uartPorts: array[3, Uart]
  uartOpen: array[3, bool]
  uartRole: array[3, PortRole]
  uartBaud: array[3, uint32]
  appConsoleRegistered = false
  appConsoleUart = UsbAnchorVirtualConsole
  appConsoleBaud: uint32
  appRx: array[4, array[AppRxSize, uint8]]
  appRxHead, appRxTail: array[4, int]
  appPinRx: array[4, array[AppRxSize, uint8]]
  appPinHead, appPinTail: array[4, int]
  pendingCredit: array[4, uint16]
  flashBusy = false
  appApi: UsbAnchorAppApi
  appPoll: UsbAnchorAppPoll
  appRunning = false
  usbWasConfigured = false
  seenUsbConfiguration, usbInputEpoch, flashUsbInputEpoch: uint32
  usbNeedsOpen: bool
  flashRxStart, flashRxLast, muxRxLast: uint32
  usbWindow: uint32
  uartProbe: array[8, uint8]
  uartProbeLen: int
  muxState, muxKind, muxChannel, muxLength, muxPos: int
  muxPayload: array[MuxPayloadMax, uint8]
  anchorRx: array[1024, uint8]
  anchorHead, anchorTail: int
  serviceDivider: uint8

proc service()

proc anchorNow(): uint32 {.inline.} = regRead(ClicMtimeBase)

proc spin() {.inline.} =
  serviceDivider = serviceDivider + 1
  if serviceDivider == 0: service()
  discard regRead(GlbSocInfo0)

proc delayCycles(count: uint32) =
  for _ in 0'u32 ..< count:
    asm """
      nop
    """

proc sendBanner() =
  discard console.sendLine("BL808-UART-FLASH-ANCHOR v1")
  console.flushTx()

proc trySendMux(kind: uint8, channel: uint8,
                payload: openArray[uint8]): bool =
  if not configured() or payload.len > MuxPayloadMax: return false
  var frame: array[5 + MuxPayloadMax, uint8]
  frame[0] = MuxMagic0
  frame[1] = MuxMagic1
  frame[2] = kind
  frame[3] = channel
  frame[4] = payload.len.uint8
  for i in 0 ..< payload.len: frame[5 + i] = payload[i]
  trySendUsb(frame.toOpenArray(0, payload.len + 4))

proc sendMux(kind: uint8, channel: uint8, payload: openArray[uint8]) =
  discard trySendMux(kind, channel, payload)

proc sendMuxControl(kind: uint8, channel: uint8,
                    payload: openArray[uint8]): bool =
  var budget = 1_000_000
  while configured() and budget > 0:
    if trySendMux(kind, channel, payload): return true
    pollUsbAnchorSerial()
    dec budget
  false

proc sendRegistration(channel, role, uartIndex: uint8, baud: uint32) =
  let details = [RegistrationVersion, role, uartIndex,
                 (baud and 0xFF).uint8, ((baud shr 8) and 0xFF).uint8,
                 ((baud shr 16) and 0xFF).uint8, ((baud shr 24) and 0xFF).uint8]
  discard sendMuxControl(MuxRegister, channel, details)

proc refreshAppRegistration(channel, role, uartIndex: uint8, baud: uint32) =
  sendRegistration(channel, role, uartIndex, baud)
  pendingCredit[channel.int] =
    ((appRxTail[channel.int] - appRxHead[channel.int] - 1 + AppRxSize) mod AppRxSize).uint16

proc announceMuxChannels() =
  discard sendMuxControl(MuxRegister, 0, [])
  if appConsoleRegistered:
    refreshAppRegistration(UsbAnchorConsoleChannel, RegistrationRoleConsole,
                           appConsoleUart.uint8, appConsoleBaud)
  for channel in 1 .. 2:
    case uartRole[channel]
    of portBridge:
      sendRegistration(channel.uint8, RegistrationRoleBridge, channel.uint8, uartBaud[channel])
    of portAppUart:
      refreshAppRegistration(channel.uint8, RegistrationRoleUart, channel.uint8, uartBaud[channel])
    else:
      discard

proc pushAppRx(channel: int, b: uint8): bool =
  let next = (appRxHead[channel] + 1) mod AppRxSize
  if next == appRxTail[channel]: return false
  appRx[channel][appRxHead[channel]] = b
  appRxHead[channel] = next
  true

proc pushAppPinRx(channel: int, b: uint8): bool =
  let next = (appPinHead[channel] + 1) mod AppRxSize
  if next == appPinTail[channel]: return false
  appPinRx[channel][appPinHead[channel]] = b
  appPinHead[channel] = next
  true

proc readAppRx(channel: int, data: pointer, capacity: uint32): int32 =
  if data == nil or capacity == 0: return 0
  let bytes = cast[ptr UncheckedArray[uint8]](data)
  while result.uint32 < capacity and appRxTail[channel] != appRxHead[channel]:
    bytes[result.int] = appRx[channel][appRxTail[channel]]
    appRxTail[channel] = (appRxTail[channel] + 1) mod AppRxSize
    inc result
    inc pendingCredit[channel]
  while result.uint32 < capacity and appPinTail[channel] != appPinHead[channel]:
    bytes[result.int] = appPinRx[channel][appPinTail[channel]]
    appPinTail[channel] = (appPinTail[channel] + 1) mod AppRxSize
    inc result

proc deliverConsolePinByte(b: uint8) =
  if not appConsoleRegistered or appConsoleUart != 0: return
  discard pushAppPinRx(UsbAnchorConsoleChannel.int, b)
  sendMux(MuxData, UsbAnchorConsoleChannel, [b])

proc tryRecvAnchorUsb(b: var uint8): bool =
  if anchorHead == anchorTail: return false
  b = anchorRx[anchorTail]
  anchorTail = (anchorTail + 1) mod anchorRx.len
  true

proc startPhysicalUart(channel: int, baud: uint32) =
  if uartOpen[channel]:
    deinitUart(uartPorts[channel])
  let tx = if channel == 1: Uart1TxPin else: Uart2TxPin
  let rx = if channel == 1: Uart1RxPin else: Uart2RxPin
  gpioSetupUart(tx, rx, range[0..2](channel))
  enablePeriphClock(if channel == 1: periphUart1 else: periphUart2)
  uartPorts[channel] = initUart(if channel == 1: uart1 else: uart2,
    UartConfig(baudRate: baud, dataBits: data8, stopBits: stop1,
               parity: parityNone), ConsoleClkHz)
  uartOpen[channel] = true
  uartBaud[channel] = baud

proc openBridge(channel: int, baud: uint32) =
  if channel < 1 or channel > 2 or baud < 9600 or baud > 3_000_000: return
  if uartRole[channel] notin {portClosed, portBridge}: return
  startPhysicalUart(channel, baud)
  uartRole[channel] = portBridge
  sendRegistration(channel.uint8, RegistrationRoleBridge,
                   channel.uint8, baud)

proc closeBridge(channel: int) =
  if channel < 1 or channel > 2 or uartRole[channel] != portBridge: return
  deinitUart(uartPorts[channel])
  uartOpen[channel] = false
  uartRole[channel] = portClosed
  uartBaud[channel] = 0
  discard sendMuxControl(MuxUnregister, channel.uint8, [])

proc anchorUnregisterConsole(): int32 {.cdecl.} =
  if not appConsoleRegistered: return AnchorStatusOk
  if appConsoleUart in 1'u32 .. 2'u32:
    let channel = appConsoleUart.int
    deinitUart(uartPorts[channel])
    uartOpen[channel] = false
    uartRole[channel] = portClosed
    uartBaud[channel] = 0
  appConsoleRegistered = false
  appConsoleUart = UsbAnchorVirtualConsole
  appRxHead[UsbAnchorConsoleChannel.int] = 0
  appRxTail[UsbAnchorConsoleChannel.int] = 0
  appPinHead[UsbAnchorConsoleChannel.int] = 0
  appPinTail[UsbAnchorConsoleChannel.int] = 0
  pendingCredit[UsbAnchorConsoleChannel.int] = 0
  discard sendMuxControl(MuxUnregister, UsbAnchorConsoleChannel, [])
  AnchorStatusOk

proc anchorRegisterConsole(uartIndex, baud: uint32): int32 {.cdecl.} =
  if uartIndex != UsbAnchorVirtualConsole and uartIndex > 2: return AnchorStatusInvalid
  if uartIndex == UsbAnchorVirtualConsole and baud != 0: return AnchorStatusInvalid
  if uartIndex == 0 and baud != 0 and baud != ConsoleBaud:
    return AnchorStatusInvalid
  if uartIndex in 1'u32 .. 2'u32 and (baud < 9600 or baud > 3_000_000):
    return AnchorStatusInvalid
  if uartIndex in 1'u32 .. 2'u32 and
      uartRole[uartIndex.int] notin {portClosed, portAppConsole}:
    return AnchorStatusBusy
  discard anchorUnregisterConsole()
  if uartIndex in 1'u32 .. 2'u32:
    startPhysicalUart(uartIndex.int, baud)
    uartRole[uartIndex.int] = portAppConsole
  appConsoleUart = uartIndex
  appConsoleBaud = if uartIndex == 0: ConsoleBaud else: baud
  appConsoleRegistered = true
  pendingCredit[UsbAnchorConsoleChannel.int] = (AppRxSize - 1).uint16
  sendRegistration(UsbAnchorConsoleChannel, RegistrationRoleConsole,
                   uartIndex.uint8, appConsoleBaud)
  AnchorStatusOk

proc anchorRegisterUart(uartIndex, baud: uint32): int32 {.cdecl.} =
  if uartIndex < 1 or uartIndex > 2 or baud < 9600 or baud > 3_000_000:
    return AnchorStatusInvalid
  let channel = uartIndex.int
  if uartRole[channel] notin {portClosed, portAppUart}: return AnchorStatusBusy
  startPhysicalUart(channel, baud)
  uartRole[channel] = portAppUart
  appRxHead[channel] = 0
  appRxTail[channel] = 0
  appPinHead[channel] = 0
  appPinTail[channel] = 0
  pendingCredit[channel] = (AppRxSize - 1).uint16
  sendRegistration(channel.uint8, RegistrationRoleUart,
                   channel.uint8, baud)
  AnchorStatusOk

proc anchorUnregisterUart(uartIndex: uint32): int32 {.cdecl.} =
  if uartIndex < 1 or uartIndex > 2: return AnchorStatusInvalid
  let channel = uartIndex.int
  if uartRole[channel] != portAppUart: return AnchorStatusUnavailable
  deinitUart(uartPorts[channel])
  uartOpen[channel] = false
  uartRole[channel] = portClosed
  uartBaud[channel] = 0
  appRxHead[channel] = 0
  appRxTail[channel] = 0
  appPinHead[channel] = 0
  appPinTail[channel] = 0
  pendingCredit[channel] = 0
  discard sendMuxControl(MuxUnregister, channel.uint8, [])
  AnchorStatusOk

proc writeAppChannel(channel: uint8, uartIndex: uint32,
                     data: pointer, length: uint32): int32 =
  if data == nil and length != 0: return AnchorStatusInvalid
  if length == 0: return 0
  let bytes = cast[ptr UncheckedArray[uint8]](data)
  while result.uint32 < length:
    let remaining = length - result.uint32
    let chunkSize = min(48'u32, remaining).int
    if configured() and usbTxFree() < chunkSize + 5: break
    if not configured() and uartIndex == UsbAnchorVirtualConsole: break
    var chunk: array[48, uint8]
    var count = 0
    while count < chunkSize:
      let b = bytes[result.int + count]
      if uartIndex == 0:
        if not console.trySendByte(b): break
      elif uartIndex <= 2:
        if not uartPorts[uartIndex.int].trySendByte(b): break
      chunk[count] = b
      inc count
    if count == 0: break
    if configured():
      discard trySendMux(MuxData, channel, chunk.toOpenArray(0, count - 1))
    result += count.int32
    if count < chunkSize: break

proc anchorConsoleWrite(data: pointer, length: uint32): int32 {.cdecl.} =
  if not appConsoleRegistered: return AnchorStatusUnavailable
  if appConsoleUart == 0 and flashBusy: return 0
  writeAppChannel(UsbAnchorConsoleChannel, appConsoleUart, data, length)

proc anchorConsoleRead(data: pointer, capacity: uint32): int32 {.cdecl.} =
  if not appConsoleRegistered: return AnchorStatusUnavailable
  readAppRx(UsbAnchorConsoleChannel.int, data, capacity)

proc anchorUartWrite(uartIndex: uint32, data: pointer,
                     length: uint32): int32 {.cdecl.} =
  if uartIndex < 1 or uartIndex > 2: return AnchorStatusInvalid
  if uartRole[uartIndex.int] != portAppUart: return AnchorStatusUnavailable
  writeAppChannel(uartIndex.uint8, uartIndex, data, length)

proc anchorUartRead(uartIndex: uint32, data: pointer,
                    capacity: uint32): int32 {.cdecl.} =
  if uartIndex < 1 or uartIndex > 2: return AnchorStatusInvalid
  if uartRole[uartIndex.int] != portAppUart: return AnchorStatusUnavailable
  readAppRx(uartIndex.int, data, capacity)

proc initAppApi() =
  appApi.magic = UsbAnchorAppMagic
  appApi.version = UsbAnchorAppVersion
  appApi.size = sizeof(UsbAnchorAppApi).uint16
  appApi.registerConsole = anchorRegisterConsole
  appApi.unregisterConsole = anchorUnregisterConsole
  appApi.consoleWrite = anchorConsoleWrite
  appApi.consoleRead = anchorConsoleRead
  appApi.registerUart = anchorRegisterUart
  appApi.unregisterUart = anchorUnregisterUart
  appApi.uartWrite = anchorUartWrite
  appApi.uartRead = anchorUartRead

proc loadApp(): bool =
  ## The app package is a 32-byte header followed by a fixed-address WRAM
  ## image. Invalid or missing packages leave the recovery anchor running.
  sfCtrlRestoreXip()
  if flashReadXip(AppFlashOffset) != AppImageMagic: return false
  let versionAndHeader = flashReadXip(AppFlashOffset + 4)
  if (versionAndHeader and 0xFFFF) != AppImageVersion.uint32 or
      (versionAndHeader shr 16) != AppImageHeaderSize:
    return false
  let imageLen = flashReadXip(AppFlashOffset + 8)
  let memoryLen = flashReadXip(AppFlashOffset + 12)
  let initOffset = flashReadXip(AppFlashOffset + 16)
  let pollOffset = flashReadXip(AppFlashOffset + 20)
  let expectedChecksum = flashReadXip(AppFlashOffset + 24)
  if flashReadXip(AppFlashOffset + 28) != 0 or
      imageLen == 0 or imageLen > AppRamCapacity or
      memoryLen < imageLen or memoryLen > AppRamCapacity or
      initOffset >= imageLen or pollOffset >= imageLen or
      (initOffset and 1) != 0 or (pollOffset and 1) != 0:
    return false
  var checksum = 0'u32
  for i in 0'u32 ..< imageLen:
    let b = flashReadXipByte(AppFlashOffset + AppImageHeaderSize + i)
    checksum = (checksum shl 5) xor (checksum shr 27) xor b.uint32
  if checksum != expectedChecksum: return false
  let ram = cast[ptr UncheckedArray[uint8]](AppRamBase)
  for i in 0'u32 ..< imageLen:
    ram[i] = flashReadXipByte(AppFlashOffset + AppImageHeaderSize + i)
  for i in imageLen ..< memoryLen:
    ram[i] = 0
  fenceIo()
  fenceI()
  let init = cast[UsbAnchorAppInit](AppRamBase + initOffset)
  let poll = cast[UsbAnchorAppPoll](AppRamBase + pollOffset)
  if init(addr appApi) != AnchorStatusOk:
    discard anchorUnregisterConsole()
    for channel in 1 .. 2:
      if uartRole[channel] == portAppUart:
        discard anchorUnregisterUart(channel.uint32)
    return false
  appPoll = poll
  appRunning = true
  true

proc resetUsbInput(needsOpen: bool) =
  inc usbInputEpoch
  usbNeedsOpen = needsOpen
  usbWindow = 0
  anchorHead = 0
  anchorTail = 0
  muxState = 0

proc handleMuxFrame() =
  let channel = muxChannel
  case muxKind.uint8
  of MuxOpen:
    if channel == 0 and muxLength == 0:
      # A reopened CDC stream need not trigger a USB bus reset.
      resetUsbInput(false)
      announceMuxChannels()
    elif muxLength == 4:
      let baud = muxPayload[0].uint32 or (muxPayload[1].uint32 shl 8) or
        (muxPayload[2].uint32 shl 16) or (muxPayload[3].uint32 shl 24)
      openBridge(channel, baud)
  of MuxClose:
    if muxLength == 0: closeBridge(channel)
  of MuxData:
    if channel == 0:
      if usbNeedsOpen: return
      for i in 0 ..< muxLength:
        anchorRx[anchorHead] = muxPayload[i]
        anchorHead = (anchorHead + 1) mod anchorRx.len
    elif channel == UsbAnchorConsoleChannel.int and appConsoleRegistered:
      for i in 0 ..< muxLength:
        if not pushAppRx(channel, muxPayload[i]): break
    elif channel >= 1 and channel <= 2:
      case uartRole[channel]
      of portBridge:
        for i in 0 ..< muxLength:
          discard uartPorts[channel].sendByte(muxPayload[i])
      of portAppUart:
        for i in 0 ..< muxLength:
          if not pushAppRx(channel, muxPayload[i]): break
      else:
        discard
  else:
    discard

proc feedMux(b: uint8) =
  muxRxLast = anchorNow()
  case muxState
  of 0:
    if b == MuxMagic0: muxState = 1
  of 1:
    muxState = if b == MuxMagic1: 2 elif b == MuxMagic0: 1 else: 0
  of 2:
    muxKind = b.int
    muxState = 3
  of 3:
    muxChannel = b.int
    muxState = 4
  of 4:
    muxLength = b.int
    muxPos = 0
    if muxLength > muxPayload.len:
      muxState = 0
    elif muxLength == 0:
      handleMuxFrame()
      muxState = 0
    else:
      muxState = 5
  of 5:
    muxPayload[muxPos] = b
    inc muxPos
    if muxPos == muxLength:
      handleMuxFrame()
      muxState = 0
  else:
    muxState = 0

proc service() =
  pollUsbAnchorSerial()
  let epoch = usbConfigurationEpoch()
  if seenUsbConfiguration != epoch:
    seenUsbConfiguration = epoch
    resetUsbInput(false)
    usbWasConfigured = false
    for channel in 1 .. 3:
      appRxHead[channel] = 0
      appRxTail[channel] = 0
  if configured() and not usbWasConfigured:
    usbWasConfigured = true
    announceMuxChannels()
    var banner: array[28, uint8]
    for i, c in "BL808-UART-FLASH-ANCHOR v1\r\n": banner[i] = c.uint8
    discard sendMuxControl(MuxData, 0, banner)
  var b: uint8
  if configured():
    if muxState != 0 and anchorNow() - muxRxLast >= FlashRxGapUs:
      muxState = 0
    for _ in 0 ..< 64:
      # Let the USB endpoint backpressure the host rather than dropping bytes.
      if not usbNeedsOpen and
          (anchorTail - anchorHead - 1 + anchorRx.len) mod anchorRx.len < MuxPayloadMax:
        break
      if not tryRecvUsb(b): break
      feedMux(b)
  for channel in 1 .. 2:
    if not uartOpen[channel]: continue
    var bytes: array[32, uint8]
    var count = 0
    while count < bytes.len:
      let (value, ok) = uartPorts[channel].tryRecvByte()
      if not ok: break
      bytes[count] = value
      if uartRole[channel] == portAppUart:
        discard pushAppPinRx(channel, value)
      elif uartRole[channel] == portAppConsole:
        discard pushAppPinRx(UsbAnchorConsoleChannel.int, value)
      inc count
    if count > 0:
      let usbChannel = if uartRole[channel] == portAppConsole:
                         UsbAnchorConsoleChannel else: channel.uint8
      sendMux(MuxData, usbChannel, bytes.toOpenArray(0, count - 1))
  if appRunning and appPoll != nil and
      (not flashBusy or appConsoleUart != 0):
    appPoll()
  if configured():
    for channel in 1 .. 3:
      if pendingCredit[channel] == 0: continue
      let amount = pendingCredit[channel]
      let grant = [(amount and 0xFF).uint8, (amount shr 8).uint8]
      if trySendMux(MuxCredit, channel.uint8, grant):
        pendingCredit[channel] = 0

proc claimSfController() =
  var cfg1 = regRead(SfCtrlCfg1)
  cfg1 = cfg1 and not (SfCtrlCfg1OwnerIahb or SfCtrlCfg1Ahb2SifEn)
  cfg1 = cfg1 or SfCtrlCfg1IfEn
  regWrite(SfCtrlCfg1, cfg1)

proc recvFlashByte(value: var uint8): bool =
  while true:
    let now = anchorNow()
    if now - flashRxLast >= FlashRxGapUs or now - flashRxStart >= FlashRxTotalUs:
      return false
    if activeTransport == viaUart:
      let (b, ok) = console.tryRecvByte()
      if ok:
        value = b
        flashRxLast = now
        return true
    else:
      if usbInputEpoch != flashUsbInputEpoch or
          usbConfigurationEpoch() != seenUsbConfiguration:
        return false
      if tryRecvAnchorUsb(value):
        flashRxLast = now
        return true
    spin()

proc recvU32(value: var uint32): bool =
  value = 0
  for i in 0 ..< 4:
    var b: uint8
    if not recvFlashByte(b): return false
    value = value or (b.uint32 shl (i * 8))
  true

proc feedUartProbe(b: uint8): bool =
  ## Keep a possible UFA1+FRSH prefix out of application input.  Every byte
  ## that cannot belong to that prefix is passed to the mirrored console.
  uartProbe[uartProbeLen] = b
  inc uartProbeLen
  while uartProbeLen > 0:
    var prefix = true
    for i in 0 ..< uartProbeLen:
      if uartProbe[i] != FlashPrefix[i]:
        prefix = false
        break
    if prefix:
      if uartProbeLen == FlashPrefix.len:
        uartProbeLen = 0
        return true
      return false
    deliverConsolePinByte(uartProbe[0])
    for i in 1 ..< uartProbeLen:
      uartProbe[i - 1] = uartProbe[i]
    dec uartProbeLen
  false

proc flushUartProbeToApp() =
  for i in 0 ..< uartProbeLen:
    deliverConsolePinByte(uartProbe[i])
  uartProbeLen = 0

proc headerChecksum(command, address, length: uint32): uint32 =
  not (ReqGuard xor command xor address xor length)

proc recvRequest(req: var Request): bool =
  var idle = 0'u32
  while true:
    let (b, ok) = console.tryRecvByte()
    if ok:
      idle = 0
      if feedUartProbe(b):
        activeTransport = viaUart
        flashBusy = true
        break
    var usbByte: uint8
    if tryRecvAnchorUsb(usbByte):
      usbWindow = (usbWindow shr 8) or (usbByte.uint32 shl 24)
      if usbWindow == ReqMagic:
        usbWindow = 0
        activeTransport = viaUsb
        flashUsbInputEpoch = usbInputEpoch
        flashBusy = true
        break
    if not ok:
      idle.inc
      if uartProbeLen > 0 and idle >= 50_000'u32:
        flushUartProbeToApp()
      if idle >= 2_000_000'u32:
        sendBanner()
        idle = 0
    spin()
  flashRxStart = anchorNow()
  flashRxLast = flashRxStart
  if activeTransport == viaUsb:
    var guard: uint32
    if not recvU32(guard) or guard != ReqGuard: return false
  if not (recvU32(req.command) and recvU32(req.address) and
          recvU32(req.length) and recvU32(req.headerChecksum)):
    return false
  if req.headerChecksum == headerChecksum(req.command, req.address, req.length) and
      req.command == CmdWriteVerify and req.length > 0 and req.length <= DataMax.uint32:
    if not recvU32(req.payloadChecksum): return false
    for i in 0 ..< req.length.int:
      if not recvFlashByte(dataBuf[i]): return false
  true

proc checksum(length: uint32): uint32 =
  for i in 0 ..< length.int:
    result = (result shl 5) xor (result shr 27) xor dataBuf[i].uint32

proc eraseRange(address, length: uint32): uint32 =
  if length == 0:
    return ErrBadLength
  var pos = address and not (FlashSectorSize - 1'u32)
  let endAddr = (address + length + FlashSectorSize - 1'u32) and
                not (FlashSectorSize - 1'u32)
  while pos < endAddr:
    let err =
      if (pos and (FlashBlock64Size - 1'u32)) == 0 and
          (endAddr - pos) >= FlashBlock64Size:
        let e = flashEraseBlock64(pos)
        pos += FlashBlock64Size
        e
      else:
        let e = flashEraseSector(pos)
        pos += FlashSectorSize
        e
    if err != flashOk:
      return ErrTimeout
  ErrOk

proc writeVerify(address, length, expectedChecksum: uint32): uint32 =
  if length == 0 or length > DataMax.uint32:
    return ErrBadLength
  if checksum(length) != expectedChecksum:
    return ErrChecksum
  if flashWrite(address, dataBuf.toOpenArray(0, length.int - 1)) != flashOk:
    return ErrTimeout
  if not flashRawMatches(address, dataBuf.toOpenArray(0, length.int - 1)):
    return ErrVerify
  ErrOk

proc sendResponse(status, value, counter: uint32) =
  var bytes: array[16, uint8]
  for i, word in [RespMagic, status, value, counter]:
    for j in 0 ..< 4:
      bytes[i * 4 + j] = ((word shr (j * 8)) and 0xFF).uint8
  if activeTransport == viaUart:
    discard console.send(bytes)
    console.flushTx()
  else:
    discard sendMuxControl(MuxData, 0, bytes)

proc abortFlashReceive() =
  if activeTransport == viaUsb and usbInputEpoch == flashUsbInputEpoch:
    resetUsbInput(true)
    discard trySendMux(MuxUnregister, 0, [])
  flashBusy = false

proc prepareForSoftReboot() =
  discard l1cInvalidateAll()
  cciFlushAll()
  fenceIo()
  fenceI()

proc rebootChip() =
  prepareForSoftReboot()
  var value = regRead(GlbSwrstCfg2)
  value = value and not PowerOnReset
  regWrite(GlbSwrstCfg2, value)
  delayCycles(1000)
  value = value or PowerOnReset
  regWrite(GlbSwrstCfg2, value)
  delayCycles(1000)
  value = value and not PowerOnReset
  regWrite(GlbSwrstCfg2, value)
  while true:
    asm """
      wfi
    """

proc main() {.exportc, cdecl.} =
  systemInit()

  enablePeriphClock(periphUart0)
  setMcuXclkSource(mcuXclkXtal)
  setUartClock(true, uartClkXclk, 0)
  gpioSetupUart(ConsoleUartTxPin, ConsoleUartRxPin)
  console = initUart(uart0, UartConfig(
    baudRate: ConsoleBaud,
    dataBits: data8,
    stopBits: stop1,
    parity: parityNone,
  ), ConsoleClkHz)
  sendBanner()
  claimSfController()
  initUsbAnchorSerial()
  initAppApi()
  discard loadApp()
  while true:
    var req: Request
    if not recvRequest(req):
      abortFlashReceive()
      continue
    var status = ErrOk
    var value = 0'u32
    var rebootAfterResponse = false
    if req.headerChecksum != headerChecksum(req.command, req.address, req.length):
      status = ErrChecksum
    else:
      case req.command
      of CmdPing:
        value = 1
      of CmdReadId:
        let id = flashReadId()
        value = id.manufacturerId.uint32 or
          (id.memoryType.uint32 shl 8) or
          (id.capacity.uint32 shl 16)
      of CmdErase:
        status = eraseRange(req.address, req.length)
      of CmdWriteVerify:
        status = writeVerify(req.address, req.length, req.payloadChecksum)
      of CmdReboot:
        rebootAfterResponse = true
      else:
        status = ErrBadCommand
    sendResponse(status, value, req.address + req.length)
    if rebootAfterResponse:
      if activeTransport == viaUart:
        while not console.txFifoEmpty() or console.txBusy(): spin()
      else:
        var timeout = 20_000_000
        while not usbTxIdle() and timeout > 0:
          service()
          dec timeout
        delayCycles(1_000_000)
      rebootChip()
    flashBusy = false
