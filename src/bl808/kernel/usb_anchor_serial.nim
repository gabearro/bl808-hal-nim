## Polling, allocation-free USB CDC ACM transport for the persistent anchor.
## The one CDC byte stream is framed into anchor/UART channels by its caller.
## BL808 USB v2 register sequencing follows Bouffalo's bflb_usb_v2.c.

import ../usb, ../mmio, ../memmap, ../glb, ../pds, ../core

const
  RxRingSize = 1024
  TxRingSize = 1024
  PacketSize = 64
  VdmaCxAddr = UsbBase + 0x304'u
  VdmaF0Ctl = UsbBase + 0x308'u
  VdmaF0Addr = UsbBase + 0x30C'u
  VdmaF1Ctl = UsbBase + 0x310'u
  VdmaF1Addr = UsbBase + 0x314'u
  VdmaStart = 1'u32
  VdmaWrite = 2'u32
  VdmaLenShift = 8
  VdmaLenMask = 0x1FFFF'u32 shl VdmaLenShift
  UsbFifoByteCountMask = 0x7FF'u32
  UsbConfiguredValue = 1'u8
  UsbAddressAfterConfig = 1'u32 shl 7

  DeviceDesc = [18'u8, 1, 0, 2, 2, 2, 0, 64,
                0x09, 0x12, 0x08, 0xB8, 0, 1, 1, 2, 3, 1]
  ConfigDesc = [
    9'u8, 2, 67, 0, 2, 1, 0, 0x80, 250,
    9, 4, 0, 0, 1, 2, 2, 1, 0,
    5, 0x24, 0, 0x10, 1,
    4, 0x24, 2, 2,
    5, 0x24, 6, 0, 1,
    5, 0x24, 1, 0, 1,
    7, 5, 0x83, 3, 8, 0, 16,
    9, 4, 1, 0, 2, 0x0A, 0, 0, 0,
    7, 5, 0x81, 2, 64, 0, 0,
    7, 5, 0x02, 2, 64, 0, 0]
  LangDesc = [4'u8, 3, 0x09, 0x04]
  ManufacturerDesc = [12'u8, 3, 66, 0, 76, 0, 56, 0, 48, 0, 56, 0]
  ProductDesc = [32'u8, 3, 65, 0, 110, 0, 99, 0, 104, 0, 111, 0, 114, 0,
                 32, 0, 85, 0, 65, 0, 82, 0, 84, 0, 32, 0, 109, 0, 117, 0,
                 120, 0]
  SerialDesc = [26'u8, 3, 66, 0, 76, 0, 56, 0, 48, 0, 56, 0, 45, 0, 65, 0,
                78, 0, 67, 0, 72, 0, 79, 0, 82, 0]
  LineCoding = [0x00'u8, 0x84, 0x03, 0, 0, 0, 8] # 230400 8N1

static:
  doAssert ConfigDesc.len == 67
  doAssert ManufacturerDesc.len == ManufacturerDesc[0].int
  doAssert ProductDesc.len == ProductDesc[0].int
  doAssert SerialDesc.len == SerialDesc[0].int

var
  isConfigured: bool
  configurationEpoch: uint32
  rxRing: array[RxRingSize, uint8]
  rxHead, rxTail: int
  txRing: array[TxRingSize, uint8]
  txHead, txTail: int
  setupBuf {.align: 64.}: array[64, uint8]
  ctrlBuf {.align: 64.}: array[64, uint8]
  rxDmaBuf {.align: 64.}: array[64, uint8]
  txDmaBuf {.align: 64.}: array[64, uint8]
  rxBusy, txBusy: bool

proc delayCycles(count: int) =
  for _ in 0 ..< count:
    asm "nop"

proc enableUsbAnchorClock() =
  const
    UsbPllDividerPower = 1'u32 shl 29
    UsbPllResetN = 1'u32 shl 28
    Usb20AhbGate = 13'u32 # GLB_PER_Clock_UnGate(GLB_AHB_CLOCK_USB20)
  # BL808 GLB_Set_USB_CLK_From_WIFIPLL: release, assert, then release reset.
  regSet(GlbWifiPllCfg10, UsbPllDividerPower)
  regSet(GlbWifiPllCfg10, UsbPllResetN)
  delayCycles(1000)
  regClear(GlbWifiPllCfg10, UsbPllResetN)
  delayCycles(1000)
  regSet(GlbWifiPllCfg10, UsbPllResetN)
  enableSystemClock(GlbCgenCfg2, CgenCfg2Usb)
  enableSystemClock(GlbCgenCfg1, Usb20AhbGate)

proc vdmaStart(ctl, mem: uint, data: pointer, length: int, write: bool;
               uncached: static bool = false) =
  when not uncached:
    if write:
      dcacheCleanRange(cast[uint](data), length.uint)
    else:
      dcacheCleanInvalidateRange(cast[uint](data), length.uint)
  fenceIo()
  var value = regRead(ctl) and not (VdmaLenMask or VdmaWrite)
  value = value or (length.uint32 shl VdmaLenShift)
  if write: value = value or VdmaWrite
  regWrite(ctl, value)
  regWrite(mem, cast[uint32](data))
  regWrite(ctl, value or VdmaStart)

proc waitCx(): bool =
  for _ in 0 ..< 20_000_000:
    if (regRead(UsbVdmaCxfps1) and VdmaStart) == 0:
      regWrite(UsbDevIsg3, 1)
      return true
  false

proc ctrlRead(length: int): bool =
  vdmaStart(UsbVdmaCxfps1, VdmaCxAddr, addr ctrlBuf[0], length, false)
  if not waitCx(): return false
  dcacheInvalidateRange(cast[uint](addr ctrlBuf[0]), length.uint)
  true

proc ctrlWrite(data: openArray[uint8], maxLen: int): bool =
  let count = min(data.len, maxLen)
  var offset = 0
  while offset < count:
    let n = min(PacketSize, count - offset)
    for i in 0 ..< n: ctrlBuf[i] = data[offset + i]
    vdmaStart(UsbVdmaCxfps1, VdmaCxAddr, addr ctrlBuf[0], n, true)
    if not waitCx(): return false
    offset += n
    if offset < count:
      var ready = false
      for _ in 0 ..< 20_000_000:
        if (regRead(UsbDevCxcfe) and (1'u32 shl CxEmp)) != 0:
          ready = true
          break
      if not ready: return false
  true

proc sendCtrl(data: openArray[uint8], maxLen: int) =
  if ctrlWrite(data, maxLen): usbCxDone()
  else: usbCxStall()

proc handleSetup() =
  vdmaStart(UsbVdmaCxfps1, VdmaCxAddr, addr setupBuf[0], 8, false)
  if not waitCx(): return
  dcacheInvalidateRange(cast[uint](addr setupBuf[0]), 8)
  let requestType = setupBuf[0]
  let request = setupBuf[1]
  let value = setupBuf[2].uint16 or (setupBuf[3].uint16 shl 8)
  let index = setupBuf[4].uint16 or (setupBuf[5].uint16 shl 8)
  let length = (setupBuf[6].uint16 or (setupBuf[7].uint16 shl 8)).int
  if (requestType and 0x60) == 0:
    case request
    of 6: # GET_DESCRIPTOR
      case (value shr 8).uint8
      of 1: sendCtrl(DeviceDesc, length)
      of 2: sendCtrl(ConfigDesc, length)
      of 3:
        case (value and 0xFF).uint8
        of 0: sendCtrl(LangDesc, length)
        of 1: sendCtrl(ManufacturerDesc, length)
        of 2: sendCtrl(ProductDesc, length)
        of 3: sendCtrl(SerialDesc, length)
        else: usbCxStall()
      else: usbCxStall()
    of 5: # SET_ADDRESS
      usbCxDone()
      usbDeviceSetAddress(value.uint8)
    of 9: # SET_CONFIGURATION
      if value == 0 or value == UsbConfiguredValue.uint16:
        if value == 0: inc configurationEpoch
        isConfigured = value != 0
        if isConfigured: regSet(UsbDevAdr, UsbAddressAfterConfig)
        else: regClear(UsbDevAdr, UsbAddressAfterConfig)
        usbCxDone()
      else:
        usbCxStall()
    of 8: # GET_CONFIGURATION
      sendCtrl([if isConfigured: UsbConfiguredValue else: 0'u8], length)
    of 0: # GET_STATUS
      sendCtrl([0'u8, 0], length)
    else: usbCxStall()
  elif (requestType and 0x60) == 0x20 and index == 0:
    case request
    of 0x20: # SET_LINE_CODING: consume seven-byte data stage
      if length == 7 and ctrlRead(7): usbCxDone()
      else: usbCxStall()
    of 0x21: sendCtrl(LineCoding, length)
    of 0x22: usbCxDone() # SET_CONTROL_LINE_STATE
    else: usbCxStall()
  else:
    usbCxStall()

proc startRx() =
  if not isConfigured or rxBusy: return
  let free = (rxTail - rxHead - 1 + RxRingSize) mod RxRingSize
  if free < PacketSize: return
  vdmaStart(VdmaF1Ctl, VdmaF1Addr, addr rxDmaBuf[0], PacketSize, false)
  rxBusy = true

proc txFifoEmpty(): bool {.inline.} =
  (regRead(UsbDevFibc0) and UsbFifoByteCountMask) == 0

proc startTx() =
  if not isConfigured or txBusy or txHead == txTail: return
  # DMA can finish filling the single-block FIFO before the host drains it.
  if not txFifoEmpty(): return
  let txDma = cast[ptr UncheckedArray[uint8]](
    cast[uint](addr txDmaBuf[0]) - OcramCachedBase + OcramBase)
  var n = 0
  while n < PacketSize and txTail != txHead:
    txDma[n] = txRing[txTail]
    txTail = (txTail + 1) mod TxRingSize
    inc n
  vdmaStart(VdmaF0Ctl, VdmaF0Addr, txDma, n, true, uncached = true)
  txBusy = true

proc initUsbAnchorSerial*() =
  # Startup zeros BSS through the cached address; retire that copy before
  # using the uncached alias for bulk IN staging.
  dcacheCleanInvalidateRange(cast[uint](addr txDmaBuf[0]), PacketSize.uint)
  enableUsbAnchorClock()
  regClear(PdsUsbPhyCtrl, 3'u32 shl 2)
  regSet(PdsUsbPhyCtrl, (1'u32 shl 6) or 1'u32)
  delayCycles(1000)
  regClear(PdsUsbCtl, 1'u32)
  delayCycles(1000)
  regSet(PdsUsbCtl, 1'u32 shl 1)
  delayCycles(300_000)
  regSet(PdsUsbCtl, 1'u32)
  delayCycles(200_000)
  regSet(PdsUsbCtl, 1'u32 shl 5)
  regSet(UsbPhyTst, 1'u32) # disconnect until descriptors and FIFO map are ready
  usbDeviceInit(highSpeed = false)
  usbSetInEpMaxPacket(1, PacketSize)
  usbSetOutEpMaxPacket(2, PacketSize)
  usbSetInEpMaxPacket(3, 8)
  regWrite(UsbDevEpmap0, 0x0022_1100'u32)
  regWrite(UsbDevFmap, 0x0023_2221'u32)
  regWrite(UsbDevFcfg, 0x0023_2222'u32)
  regWrite(UsbDevMisg0, 0)
  regWrite(UsbDevMisg1, 0xFFFF_FFFF'u32)
  regWrite(UsbDevMisg2, 0)
  regWrite(UsbDevMisg3, 0)
  regWrite(UsbDevMigr, 0)
  regWrite(UsbGlbInt, 0)
  regSet(UsbVdmaCtrl, 1'u32)
  regClear(UsbPhyTst, 1'u32)

proc configured*(): bool = isConfigured
proc usbConfigurationEpoch*(): uint32 = configurationEpoch

proc pollUsbAnchorSerial*() =
  let groups = usbReadDeviceIntGroup()
  if (groups and (1'u32 shl IntG2)) != 0:
    let events = usbReadBusEvents()
    if (events and (1'u32 shl Isg2Rx0byte)) != 0:
      # An OUT ZLP carries no stream data. Acknowledge its endpoint latch
      # before clearing the group bit so subsequent OUT packets can proceed.
      regWrite(UsbDevRxz, regRead(UsbDevRxz))
    if (events and (1'u32 shl Isg2UsbRst)) != 0:
      inc configurationEpoch
      isConfigured = false
      rxBusy = false
      txBusy = false
      rxHead = 0
      rxTail = 0
      txHead = 0
      txTail = 0
    regWrite(UsbDevIsg2, events)
  if (groups and (1'u32 shl IntG0)) != 0:
    let events = usbReadCxEvents()
    if (events and 1) != 0: handleSetup()
    regWrite(UsbDevIsg0, events)
  if (groups and (1'u32 shl IntG3)) != 0:
    let events = regRead(UsbDevIsg3)
    regWrite(UsbDevIsg3, events)
    if (events and (1'u32 shl 1)) != 0: txBusy = false
    if (events and (1'u32 shl 2)) != 0 and rxBusy:
      let remaining = ((regRead(VdmaF1Ctl) and VdmaLenMask) shr VdmaLenShift).int
      let count = max(0, min(PacketSize - remaining, PacketSize))
      dcacheInvalidateRange(cast[uint](addr rxDmaBuf[0]), PacketSize)
      for i in 0 ..< count:
        rxRing[rxHead] = rxDmaBuf[i]
        rxHead = (rxHead + 1) mod RxRingSize
      rxBusy = false
  startRx()
  startTx()

proc tryRecvUsb*(b: var uint8): bool =
  if rxHead == rxTail: return false
  b = rxRing[rxTail]
  rxTail = (rxTail + 1) mod RxRingSize
  true

proc usbTxFree*(): int =
  (txTail - txHead - 1 + TxRingSize) mod TxRingSize

proc trySendUsb*(data: openArray[uint8]): bool =
  ## Queue one complete mux frame or none of it.  The caller can retry when
  ## USB backpressure clears instead of silently truncating a frame.
  if not isConfigured: return false
  if data.len > usbTxFree(): return false
  for b in data:
    txRing[txHead] = b
    txHead = (txHead + 1) mod TxRingSize
  startTx()
  true

proc sendUsb*(data: openArray[uint8]) =
  discard trySendUsb(data)

proc usbTxIdle*(): bool =
  txHead == txTail and not txBusy and txFifoEmpty()
