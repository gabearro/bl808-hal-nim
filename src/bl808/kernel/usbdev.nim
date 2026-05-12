## USB device framework for the BL808 FOTG210 controller.
##
## Handles EP0 control transfers, standard USB requests,
## and descriptor management. Class drivers (CDC, etc.) register
## a handler for class-specific requests.

import ../usb, ../mmio, ../memmap, ../irq
import ./runtime, ./isrbridge, ./log

# =============================================================================
# USB standard constants
# =============================================================================
const
  # Request types (bmRequestType direction + type + recipient)
  ReqDirOut*    = 0x00'u8
  ReqDirIn*     = 0x80'u8
  ReqTypeStd*   = 0x00'u8
  ReqTypeClass* = 0x20'u8
  ReqRecipDev*  = 0x00'u8
  ReqRecipIface* = 0x01'u8
  ReqRecipEp*   = 0x02'u8

  # Standard request codes
  GetStatus*       = 0'u8
  ClearFeature*    = 1'u8
  SetFeature*      = 3'u8
  SetAddress*      = 5'u8
  GetDescriptor*   = 6'u8
  SetDescriptor*   = 7'u8
  GetConfiguration* = 8'u8
  SetConfiguration* = 9'u8

  # Descriptor types
  DescDevice*    = 1'u8
  DescConfig*    = 2'u8
  DescString*    = 3'u8
  DescInterface* = 4'u8
  DescEndpoint*  = 5'u8

# =============================================================================
# Types
# =============================================================================

type
  SetupPacket* = object
    bmRequestType*: uint8
    bRequest*: uint8
    wValue*: uint16
    wIndex*: uint16
    wLength*: uint16

  UsbDevState* = enum
    usbDefault, usbAddressed, usbConfigured

  ClassRequestHandler* = proc(setup: SetupPacket): bool

  UsbDev* = object
    state*: UsbDevState
    address: uint8
    config: uint8
    classHandler*: ClassRequestHandler
    fifoOutHandler*: proc()  ## Called when bulk OUT FIFO has data

# =============================================================================
# Descriptor storage (populated by class driver at init)
# =============================================================================
var
  deviceDesc*: array[18, uint8]
  configDesc*: array[256, uint8]
  configDescLen*: int = 0
  stringDescs*: array[4, string]

# =============================================================================
# CX FIFO read/write via VDMA port
# =============================================================================

const VdmaCxPort = UsbBase + 0x300'u

proc cxFifoWrite(data: ptr UncheckedArray[uint8], len: int) =
  ## Write data to CX FIFO (EP0 IN response to host).
  var i = 0
  while i < len:
    var word = 0'u32
    for j in 0 ..< min(4, len - i):
      word = word or (data[i + j].uint32 shl (j * 8))
    regWrite(VdmaCxPort, word)
    i += 4

proc cxFifoWriteArr*(data: openArray[uint8]) =
  cxFifoWrite(cast[ptr UncheckedArray[uint8]](unsafeAddr data[0]), data.len)

proc cxFifoRead(buf: var array[8, uint8]) =
  ## Read 8-byte setup packet from CX FIFO.
  let w0 = regRead(VdmaCxPort)
  let w1 = regRead(VdmaCxPort)
  buf[0] = (w0 and 0xFF).uint8
  buf[1] = ((w0 shr 8) and 0xFF).uint8
  buf[2] = ((w0 shr 16) and 0xFF).uint8
  buf[3] = ((w0 shr 24) and 0xFF).uint8
  buf[4] = (w1 and 0xFF).uint8
  buf[5] = ((w1 shr 8) and 0xFF).uint8
  buf[6] = ((w1 shr 16) and 0xFF).uint8
  buf[7] = ((w1 shr 24) and 0xFF).uint8

proc parseSetup(raw: array[8, uint8]): SetupPacket =
  SetupPacket(
    bmRequestType: raw[0],
    bRequest: raw[1],
    wValue: raw[2].uint16 or (raw[3].uint16 shl 8),
    wIndex: raw[4].uint16 or (raw[5].uint16 shl 8),
    wLength: raw[6].uint16 or (raw[7].uint16 shl 8),
  )

# =============================================================================
# Standard request handling
# =============================================================================

var dev: UsbDev

proc handleGetDescriptor(setup: SetupPacket): bool =
  let descType = (setup.wValue shr 8).uint8
  let descIdx = (setup.wValue and 0xFF).uint8
  let maxLen = setup.wLength.int

  case descType
  of DescDevice:
    let len = min(deviceDesc.len, maxLen)
    cxFifoWriteArr(deviceDesc[0 ..< len])
    return true
  of DescConfig:
    let len = min(configDescLen, maxLen)
    cxFifoWriteArr(configDesc[0 ..< len])
    return true
  of DescString:
    if descIdx == 0:
      # Language ID descriptor
      let langDesc = [4'u8, DescString, 0x09, 0x04]  # English (US)
      cxFifoWriteArr(langDesc)
      return true
    elif descIdx.int < stringDescs.len and stringDescs[descIdx.int].len > 0:
      let s = stringDescs[descIdx.int]
      # USB string descriptor: UTF-16LE encoded
      var buf: array[64, uint8]
      let strLen = min(s.len, 30)  # max 30 chars
      buf[0] = (2 + strLen * 2).uint8  # bLength
      buf[1] = DescString
      for i in 0 ..< strLen:
        buf[2 + i * 2] = s[i].uint8
        buf[2 + i * 2 + 1] = 0
      let len = min(buf[0].int, maxLen)
      cxFifoWriteArr(buf[0 ..< len])
      return true
  else:
    discard
  false

proc handleStandardRequest(setup: SetupPacket): bool =
  case setup.bRequest
  of GetDescriptor:
    return handleGetDescriptor(setup)

  of SetAddress:
    dev.address = (setup.wValue and 0x7F).uint8
    usbDeviceSetAddress(dev.address)
    dev.state = usbAddressed
    return true

  of SetConfiguration:
    dev.config = (setup.wValue and 0xFF).uint8
    if dev.config > 0:
      dev.state = usbConfigured
    else:
      dev.state = usbAddressed
    return true

  of GetConfiguration:
    var cfg = [dev.config]
    cxFifoWriteArr(cfg)
    return true

  of GetStatus:
    var status = [0'u8, 0]  # Self-powered, no remote wakeup
    cxFifoWriteArr(status)
    return true

  of ClearFeature, SetFeature:
    return true  # ACK, no action

  else:
    return false

# =============================================================================
# USB ISR handler
# =============================================================================

proc usbIsrHandler() {.cdecl.} =
  # Check device interrupt group
  let igr = usbReadDeviceIntGroup()

  # G2: Bus events (USB reset, suspend, resume)
  if (igr and (1'u32 shl IntG2)) != 0:
    let bus = usbReadBusEvents()
    if (bus and (1'u32 shl Isg2UsbRst)) != 0:
      dev.state = usbDefault
      dev.address = 0
      dev.config = 0
      # Clear reset event
      regWrite(UsbDevIsg2, 1'u32 shl Isg2UsbRst)

  # G0: CX (EP0) events
  if (igr and (1'u32 shl IntG0)) != 0:
    let cx = usbReadCxEvents()
    if (cx and 1) != 0:  # Setup packet received (bit 0)
      var raw: array[8, uint8]
      cxFifoRead(raw)
      let setup = parseSetup(raw)

      var handled = false
      let reqType = setup.bmRequestType and 0x60  # type field

      if reqType == ReqTypeClass and dev.classHandler != nil:
        handled = dev.classHandler(setup)

      if not handled and reqType == ReqTypeStd:
        handled = handleStandardRequest(setup)

      if handled:
        usbCxDone()
      else:
        usbCxStall()

  # G1: FIFO events (bulk data)
  if (igr and (1'u32 shl IntG1)) != 0:
    let fifo = usbReadFifoEvents()
    # FIFO1 OUT data ready (bit 2 from QEMU model)
    if (fifo and (1'u32 shl 2)) != 0 and dev.fifoOutHandler != nil:
      dev.fifoOutHandler()

# =============================================================================
# Data FIFO read/write (bulk endpoints)
# =============================================================================

const DataFifoBase = UsbBase + 0x200'u

proc usbFifoWrite*(fifo: int, data: openArray[uint8]) =
  ## Write data to a data FIFO (bulk IN).
  let port = DataFifoBase + fifo.uint * 4
  var i = 0
  while i < data.len:
    var word = 0'u32
    for j in 0 ..< min(4, data.len - i):
      word = word or (data[i + j].uint32 shl (j * 8))
    regWrite(port, word)
    i += 4

proc usbFifoRead*(fifo: int, buf: var openArray[uint8]): int =
  ## Read data from a data FIFO (bulk OUT). Returns bytes read.
  let port = DataFifoBase + fifo.uint * 4
  let available = usbGetFifoByteCount(fifo.uint32).int
  let toRead = min(available, buf.len)
  var i = 0
  while i < toRead:
    let word = regRead(port)
    for j in 0 ..< min(4, toRead - i):
      buf[i + j] = ((word shr (j * 8)) and 0xFF).uint8
    i += 4
  toRead

# =============================================================================
# Initialization
# =============================================================================

proc usbDevInit*() =
  ## Initialize the USB device framework. Must be called before class driver init.
  dev = UsbDev(state: usbDefault)
  usbDeviceInit(highSpeed = true)

  # Register ISR
  registerTrapHandler(IrqM0Usb, usbIsrHandler)
  irqEnable(IrqM0Usb)
  irqSetLevel(IrqM0Usb, 1)

  # Enable machine external interrupt
  {.emit: """
  unsigned long mie;
  asm volatile("csrr %0, mie" : "=r"(mie));
  mie |= (1UL << 11);
  asm volatile("csrw mie, %0" :: "r"(mie));
  """.}

  # Unmask all interrupt groups and sub-groups
  regWrite(UsbDevMisg0, 0)  # Unmask CX events
  regWrite(UsbDevMisg1, 0)  # Unmask FIFO events
  regWrite(UsbDevMisg2, 0)  # Unmask bus events
  regWrite(UsbGlbInt, 0)    # Unmask global

proc usbDevSetClassHandler*(handler: ClassRequestHandler) =
  dev.classHandler = handler

proc usbDevSetFifoOutHandler*(handler: proc()) =
  dev.fifoOutHandler = handler

proc usbDevGetState*(): UsbDevState =
  dev.state
