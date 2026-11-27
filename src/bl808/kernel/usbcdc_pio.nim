## USB CDC ACM (virtual serial port) class driver.
##
## Provides async send/recv like AsyncUart but over USB:
##
##   let cdc = initUsbCdc()
##   cdc.sendString("Hello from USB!\r\n")
##   let byte = await cdc.recv()

import ../usb, ../mmio, ../irq
import ./runtime, ./isrbridge, ./usbdev

# =============================================================================
# CDC constants
# =============================================================================
const
  # CDC class requests
  CdcSetLineCoding*    = 0x20'u8
  CdcGetLineCoding*    = 0x21'u8
  CdcSetCtrlLineState* = 0x22'u8

  # Endpoint assignments
  BulkInFifo  = 0  # FIFO0 → EP1 IN (device → host)
  BulkOutFifo = 1  # FIFO1 → EP2 OUT (host → device)
  BulkMaxPkt  = 512'u32  # High-speed bulk

  # VID/PID (generic CDC test device)
  UsbVid = 0x1209'u16  # pid.codes open-source VID
  UsbPid = 0xB808'u16  # Custom PID

# =============================================================================
# CDC state
# =============================================================================
type
  LineCoding = object
    baudRate: uint32
    stopBits: uint8   # 0=1, 1=1.5, 2=2
    parity: uint8     # 0=none, 1=odd, 2=even
    dataBits: uint8   # 5,6,7,8

  UsbCdc* = ref object
    slot: int              ## ISR bridge slot for RX
    rxBuf: array[64, uint8]
    rxLen: int
    rxPos: int
    rxGotData: bool

var
  lineCoding: LineCoding = LineCoding(
    baudRate: 115200, stopBits: 0, parity: 0, dataBits: 8)
  ctrlLineState: uint16 = 0
  cdcInstance: UsbCdc

# =============================================================================
# Descriptors
# =============================================================================

proc buildDescriptors() =
  # Device descriptor (18 bytes)
  deviceDesc = [
    18'u8,                     # bLength
    DescDevice,                # bDescriptorType
    0x00, 0x02,                # bcdUSB = 2.00
    0x02,                      # bDeviceClass = CDC
    0x02,                      # bDeviceSubClass = ACM
    0x00,                      # bDeviceProtocol
    64,                        # bMaxPacketSize0
    (UsbVid and 0xFF).uint8, (UsbVid shr 8).uint8,  # idVendor
    (UsbPid and 0xFF).uint8, (UsbPid shr 8).uint8,  # idProduct
    0x00, 0x01,                # bcdDevice = 1.00
    1, 2, 3,                   # iManufacturer, iProduct, iSerialNumber
    1,                         # bNumConfigurations
  ]

  # String descriptors
  stringDescs[1] = "BL808"
  stringDescs[2] = "CDC ACM"
  stringDescs[3] = "001"

  # Config descriptor (total = 9 + 9 + 5+4+5+5 + 7 + 9 + 7+7 = 67 bytes)
  var c: array[128, uint8]
  var p = 0

  # Configuration descriptor
  c[p] = 9; c[p+1] = DescConfig
  # wTotalLength filled below
  c[p+4] = 2  # bNumInterfaces
  c[p+5] = 1  # bConfigurationValue
  c[p+6] = 0  # iConfiguration
  c[p+7] = 0x80  # bmAttributes (bus-powered)
  c[p+8] = 250   # bMaxPower (500mA)
  p += 9

  # Interface 0: CDC Communication Interface
  c[p] = 9; c[p+1] = DescInterface
  c[p+2] = 0  # bInterfaceNumber
  c[p+3] = 0  # bAlternateSetting
  c[p+4] = 1  # bNumEndpoints (interrupt IN)
  c[p+5] = 0x02  # bInterfaceClass = CDC
  c[p+6] = 0x02  # bInterfaceSubClass = ACM
  c[p+7] = 0x01  # bInterfaceProtocol = AT commands
  p += 9

  # CDC Header Functional Descriptor
  c[p] = 5; c[p+1] = 0x24; c[p+2] = 0x00  # CS_INTERFACE, Header
  c[p+3] = 0x10; c[p+4] = 0x01  # bcdCDC = 1.10
  p += 5

  # CDC ACM Functional Descriptor
  c[p] = 4; c[p+1] = 0x24; c[p+2] = 0x02  # CS_INTERFACE, ACM
  c[p+3] = 0x02  # bmCapabilities (line coding + serial state)
  p += 4

  # CDC Union Functional Descriptor
  c[p] = 5; c[p+1] = 0x24; c[p+2] = 0x06  # CS_INTERFACE, Union
  c[p+3] = 0  # bControlInterface
  c[p+4] = 1  # bSubordinateInterface0
  p += 5

  # CDC Call Management Functional Descriptor
  c[p] = 5; c[p+1] = 0x24; c[p+2] = 0x01  # CS_INTERFACE, Call Mgmt
  c[p+3] = 0x00  # bmCapabilities
  c[p+4] = 1     # bDataInterface
  p += 5

  # Endpoint: Interrupt IN EP3 (notification, not used but required)
  c[p] = 7; c[p+1] = DescEndpoint
  c[p+2] = 0x83  # bEndpointAddress = EP3 IN
  c[p+3] = 0x03  # bmAttributes = Interrupt
  c[p+4] = 8; c[p+5] = 0  # wMaxPacketSize = 8
  c[p+6] = 255  # bInterval
  p += 7

  # Interface 1: CDC Data Interface
  c[p] = 9; c[p+1] = DescInterface
  c[p+2] = 1  # bInterfaceNumber
  c[p+3] = 0  # bAlternateSetting
  c[p+4] = 2  # bNumEndpoints
  c[p+5] = 0x0A  # bInterfaceClass = CDC Data
  p += 9

  # Endpoint: Bulk IN EP1
  c[p] = 7; c[p+1] = DescEndpoint
  c[p+2] = 0x81  # bEndpointAddress = EP1 IN
  c[p+3] = 0x02  # bmAttributes = Bulk
  c[p+4] = (BulkMaxPkt and 0xFF).uint8
  c[p+5] = (BulkMaxPkt shr 8).uint8
  c[p+6] = 0     # bInterval
  p += 7

  # Endpoint: Bulk OUT EP2
  c[p] = 7; c[p+1] = DescEndpoint
  c[p+2] = 0x02  # bEndpointAddress = EP2 OUT
  c[p+3] = 0x02  # bmAttributes = Bulk
  c[p+4] = (BulkMaxPkt and 0xFF).uint8
  c[p+5] = (BulkMaxPkt shr 8).uint8
  c[p+6] = 0     # bInterval
  p += 7

  # Fill wTotalLength in config descriptor
  c[2] = (p and 0xFF).uint8
  c[3] = (p shr 8).uint8

  configDescLen = p
  for i in 0 ..< p:
    configDesc[i] = c[i]

# =============================================================================
# CDC class request handler
# =============================================================================

proc cdcClassHandler(setup: SetupPacket): bool =
  case setup.bRequest
  of CdcSetLineCoding:
    # Host sends 7-byte line coding data — just ACK
    return true
  of CdcGetLineCoding:
    var lc: array[7, uint8]
    lc[0] = (lineCoding.baudRate and 0xFF).uint8
    lc[1] = ((lineCoding.baudRate shr 8) and 0xFF).uint8
    lc[2] = ((lineCoding.baudRate shr 16) and 0xFF).uint8
    lc[3] = ((lineCoding.baudRate shr 24) and 0xFF).uint8
    lc[4] = lineCoding.stopBits
    lc[5] = lineCoding.parity
    lc[6] = lineCoding.dataBits
    cxFifoWriteArr(lc)
    return true
  of CdcSetCtrlLineState:
    ctrlLineState = setup.wValue
    return true
  else:
    return false

# =============================================================================
# Bulk OUT ISR handler
# =============================================================================

proc cdcFifoOutHandler() =
  let cdc = cdcInstance
  if cdc == nil: return

  # Read available data from bulk OUT FIFO
  cdc.rxLen = usbFifoRead(BulkOutFifo, cdc.rxBuf)
  cdc.rxPos = 0
  if cdc.rxLen > 0:
    cdc.rxGotData = true
    if cdc.slot >= 0:
      completeIsrSlot(cdc.slot)
      cdc.slot = -1

# =============================================================================
# Public API
# =============================================================================

proc initUsbCdc*(): UsbCdc =
  ## Initialize USB device + CDC ACM class driver.
  buildDescriptors()
  usbDevInit()
  usbDevSetClassHandler(cdcClassHandler)

  # Configure endpoints
  usbSetInEpMaxPacket(1, BulkMaxPkt)
  usbSetOutEpMaxPacket(2, BulkMaxPkt)

  # Map: EP1 IN → FIFO0, EP2 OUT → FIFO1
  regWrite(UsbDevEpmap0, 0x10'u32)  # EP1=FIFO0(IN), EP2=FIFO1(OUT)
  regWrite(UsbDevFmap, 0x10'u32)
  regWrite(UsbDevFcfg, 0x22'u32)    # Both FIFOs enabled, bulk type

  result = UsbCdc(slot: -1)
  cdcInstance = result
  usbDevSetFifoOutHandler(cdcFifoOutHandler)

proc send*(cdc: UsbCdc, data: openArray[uint8]) =
  ## Send data to USB host via bulk IN endpoint.
  usbFifoWrite(BulkInFifo, data)

proc sendByte*(cdc: UsbCdc, b: uint8) =
  cdc.send([b])

proc sendString*(cdc: UsbCdc, s: string) =
  for c in s:
    cdc.sendByte(c.uint8)

proc sendLine*(cdc: UsbCdc, s: string) =
  cdc.sendString(s)
  cdc.send([0x0D'u8, 0x0A])

proc recv*(cdc: UsbCdc): CpsFuture[uint8] =
  ## Receive one byte from USB host (blocks until data arrives).
  # Fast path: data already buffered
  if cdc.rxPos < cdc.rxLen:
    let b = cdc.rxBuf[cdc.rxPos]
    cdc.rxPos.inc
    let fut = newLocalCpsFuture[uint8]()
    complete(fut, b)
    return fut

  # Slow path: wait for ISR
  let voidFut = newLocalCpsVoidFuture()
  let typedFut = newLocalCpsFuture[uint8]()

  cdc.rxGotData = false
  cdc.slot = registerIsrFuture(voidFut)
  if cdc.slot < 0:
    return failedFuture[uint8](newException(IOError, "ISR bridge full"))

  # Re-enable CLIC for USB
  irqClearPending(IrqM0Usb)
  irqEnable(IrqM0Usb)

  voidFut.addCallback proc() =
    if cdc.rxGotData and cdc.rxPos < cdc.rxLen:
      let b = cdc.rxBuf[cdc.rxPos]
      cdc.rxPos.inc
      complete(typedFut, b)
    else:
      complete(typedFut, 0'u8)

  typedFut
