## BL808 I2C master driver.
##
## I2C0 at 0x2000A300 (MCU)
## I2C1 at 0x2000A900 (MCU)
## I2C2 at 0x30003000 (MM)
## I2C3 at 0x30004000 (MM)
##
## All instances share the same register layout.

import mmio, memmap
when defined(bl808m0) or defined(bl808d0) or defined(bl808lp):
  import dma, dmablock, dmafifo

# =============================================================================
# I2C register offsets
# =============================================================================
const
  I2cConfig*        = 0x00'u  # I2C configuration
  I2cIntSts*        = 0x04'u  # Interrupt status
  I2cSubAddr*       = 0x08'u  # Sub-address
  I2cBusBusy*       = 0x0C'u  # Bus busy
  I2cPrdStart*      = 0x10'u  # Start condition period
  I2cPrdStop*       = 0x14'u  # Stop condition period
  I2cPrdData*       = 0x18'u  # Data phase period
  I2cFifoConfig0*   = 0x80'u  # FIFO configuration 0
  I2cFifoConfig1*   = 0x84'u  # FIFO configuration 1
  I2cFifoWdata*     = 0x88'u  # FIFO write data
  I2cFifoRdata*     = 0x8C'u  # FIFO read data

# =============================================================================
# I2C_CONFIG fields
# =============================================================================
const
  I2cMasterEn*      = 0       # Master enable — starts transfer
  I2cPktDir*        = 1       # Packet direction: 0=write, 1=read
  I2cDeglitchEn*    = 2       # Deglitch enable
  I2cSclSyncEn*     = 3       # SCL synchronization enable
  I2cSubAddrEn*     = 4       # Sub-address enable
  I2cSubAddrBcShift* = 5      # Sub-address byte count [6:5]
  I2cSubAddrBcMask*  = 0x03'u32 shl 5
  I2cSlvAddrShift*  = 8       # Slave address [14:8]
  I2cSlvAddrMask*   = 0x7F'u32 shl 8
  I2cPktLenShift*   = 16      # Packet length [23:16] (n-1)
  I2cPktLenMask*    = 0xFF'u32 shl 16
  I2cDeglitchCycShift* = 28   # Deglitch cycle count [31:28]
  I2cDeglitchCycMask*  = 0x0F'u32 shl 28

# =============================================================================
# I2C interrupt bits
# =============================================================================
const
  I2cIntEnd*        = 0       # Transfer end
  I2cIntTxFifo*     = 1       # TX FIFO below threshold
  I2cIntRxFifo*     = 2       # RX FIFO above threshold
  I2cIntNak*        = 3       # NAK received
  I2cIntArb*        = 4       # Arbitration lost
  I2cIntFifoErr*    = 5       # FIFO error
  # Mask bits at +8
  I2cIntMaskOffset* = 8
  # Clear bits at +16
  I2cIntClrOffset* = 16

# =============================================================================
# FIFO fields
# =============================================================================
const
  I2cFifoDepth*     = 2'u32
  I2cFifoDmaTxEn*   = 0
  I2cFifoDmaRxEn*   = 1
  I2cFifoTxClr*     = 2
  I2cFifoRxClr*     = 3

  I2cFifoTxCountMask* = 0x03'u32  # TX free count
  I2cFifoRxCountShift* = 8
  I2cFifoRxCountMask*  = 0x03'u32 shl 8

# =============================================================================
# Types
# =============================================================================
type
  I2cId* = enum
    i2c0
    i2c1
    i2c2
    i2c3

  I2cSpeed* = enum
    i2cStandard   ## 100 kHz
    i2cFast       ## 400 kHz
    i2cFastPlus   ## 1 MHz

  I2cError* = enum
    i2cOk
    i2cNak
    i2cArbLost
    i2cTimeout
    i2cFifoError

  I2c* = object
    base*: uint
    id*: I2cId

# =============================================================================
# Base address lookup
# =============================================================================
proc i2cBase(id: I2cId): uint =
  case id
  of i2c0: I2c0Base
  of i2c1: I2c1Base
  of i2c2: I2c2Base
  of i2c3: I2c3Base

# =============================================================================
# Initialization
# =============================================================================
proc initI2c*(id: I2cId, speed: I2cSpeed, i2cClkHz: uint32): I2c =
  ## Initialize an I2C peripheral in master mode.
  ## `i2cClkHz` is the I2C peripheral clock frequency.
  result.base = i2cBase(id)
  result.id = id
  let base = result.base

  # Disable during configuration
  regClear(base + I2cConfig, 1'u32 shl I2cMasterEn)

  # Calculate timing periods based on speed
  let targetFreq = case speed
    of i2cStandard:  100_000'u32
    of i2cFast:      400_000'u32
    of i2cFastPlus:  1_000_000'u32

  let period = i2cClkHz div targetFreq
  let halfPeriod = period div 2

  # Phase periods: each is 4x8-bit phase values
  let phase = min(halfPeriod, 255'u32)  # 8-bit fields
  let startPrd = phase or (phase shl 8) or (phase shl 16) or (phase shl 24)
  let stopPrd = phase or (phase shl 8) or (phase shl 16) or (phase shl 24)
  let dataPrd = phase or (phase shl 8) or (phase shl 16) or (phase shl 24)

  regWrite(base + I2cPrdStart, startPrd)
  regWrite(base + I2cPrdStop, stopPrd)
  regWrite(base + I2cPrdData, dataPrd)

  # Enable deglitch, SCL sync
  var cfg = regRead(base + I2cConfig)
  cfg = cfg or (1'u32 shl I2cDeglitchEn)
  cfg = cfg or (1'u32 shl I2cSclSyncEn)
  cfg = (cfg and not I2cDeglitchCycMask) or (2'u32 shl I2cDeglitchCycShift)
  regWrite(base + I2cConfig, cfg)

  # Clear FIFOs
  regSet(base + I2cFifoConfig0,
         (1'u32 shl I2cFifoTxClr) or (1'u32 shl I2cFifoRxClr))

  # Mask all interrupts
  regSet(base + I2cIntSts, 0x3F'u32 shl I2cIntMaskOffset)

# =============================================================================
# Packet I/O shared by the synchronous and async drivers
# =============================================================================

const
  I2cPacketMax* = 256
  I2cInterrupts = 0x3F'u32
  I2cInterruptMask = I2cInterrupts shl I2cIntMaskOffset
  I2cInterruptEnable = I2cInterrupts shl 24
  I2cClearStatus = I2cInterrupts shl I2cIntClrOffset
  I2cFifoThresholdMask = (1'u32 shl 16) or (1'u32 shl 24)
  I2cFifoClear = (1'u32 shl I2cFifoTxClr) or (1'u32 shl I2cFifoRxClr)
  BytesPerFifoWord = 4

type I2cPacket* = object
  bus: I2c
  buffer: ptr UncheckedArray[byte]
  size, position: int
  reading: bool
  started: bool
  outcome: I2cError
  when defined(bl808m0) or defined(bl808d0) or defined(bl808lp):
    dma: DmaFifoTransfer
    txWords: seq[uint32]

proc maskPacketInterrupts*(bus: I2c) =
  regWrite(bus.base + I2cIntSts, I2cInterruptMask or I2cInterruptEnable)

proc enablePacketInterrupts*(packet: I2cPacket) =
  var wanted = (1'u32 shl I2cIntEnd) or (1'u32 shl I2cIntNak) or
    (1'u32 shl I2cIntArb) or (1'u32 shl I2cIntFifoErr)
  if packet.position < packet.size:
    wanted = wanted or (1'u32 shl (if packet.reading: I2cIntRxFifo else: I2cIntTxFifo))
  regWrite(packet.bus.base + I2cIntSts, I2cInterruptEnable or
    ((I2cInterrupts and not wanted) shl I2cIntMaskOffset))

func packWord(data: ptr UncheckedArray[byte]; offset, count: int): uint32 =
  for i in 0 ..< count:
    result = result or (data[offset + i].uint32 shl (8 * i))

when not (defined(bl808m0) or defined(bl808d0) or defined(bl808lp)):
  proc serviceFifo(packet: var I2cPacket) =
    let base = packet.bus.base
    while packet.position < packet.size:
      let counts = regRead(base + I2cFifoConfig1)
      let count = min(BytesPerFifoWord, packet.size - packet.position)
      if packet.reading:
        if (counts and I2cFifoRxCountMask) == 0: break
        let word = regRead(base + I2cFifoRdata)
        for i in 0 ..< count:
          packet.buffer[packet.position + i] = byte((word shr (8 * i)) and 0xFF)
      else:
        if (counts and I2cFifoTxCountMask) == 0: break
        regWrite(base + I2cFifoWdata, packWord(packet.buffer, packet.position, count))
      packet.position += count

when defined(bl808m0) or defined(bl808d0) or defined(bl808lp):
  proc preparePacketDma(packet: var I2cPacket): bool =
    let bus = packet.bus
    var endpoint = DmaFifoEndpoint(enableRegister: bus.base + I2cFifoConfig0,
                                    width: width32)
    when defined(bl808m0) or defined(bl808lp):
      endpoint.controller = CoreDmaId
      case bus.id
      of i2c0: endpoint.request = dmaPeriphI2c0Rx.uint32
      of i2c1: endpoint.request = dmaPeriphI2c1Rx.uint32
      else: return false
    else:
      endpoint.controller = dma2
      case bus.id
      of i2c2: endpoint.request = dmaMmI2c2Rx.uint32
      of i2c3: endpoint.request = dmaMmI2c3Rx.uint32
      else: return false
    if packet.reading:
      endpoint.direction = dmaFifoRead
      endpoint.address = bus.base + I2cFifoRdata
      endpoint.enableMask = 1'u32 shl I2cFifoDmaRxEn
      return packet.dma.prepare(endpoint, packet.buffer, packet.size, pad = true)

    inc endpoint.request
    endpoint.direction = dmaFifoWrite
    endpoint.address = bus.base + I2cFifoWdata
    endpoint.enableMask = 1'u32 shl I2cFifoDmaTxEn
    if ((cast[uint](packet.buffer) or packet.size.uint) and 3) == 0 and
        dmaBufferInRam(cast[uint](packet.buffer), packet.size):
      return packet.dma.prepare(endpoint, packet.buffer, packet.size)

    let words = (packet.size + 3) div 4
    packet.txWords.setLen(words)
    for i in 0 ..< words:
      let offset = 4 * i
      packet.txWords[i] = packWord(packet.buffer, offset, min(4, packet.size - offset))
    packet.dma.prepare(endpoint, addr packet.txWords[0], words * 4)

proc usesDma*(packet: I2cPacket): bool =
  when defined(bl808m0) or defined(bl808d0) or defined(bl808lp): packet.started
  else: false

proc beginPacket*(packet: var I2cPacket; bus: I2c; address: uint8;
                  data: ptr UncheckedArray[byte]; len: int; reading: bool;
                  subAddress: int = -1): bool =
  if packet.started or data == nil or len < 1 or len > I2cPacketMax or
      (regRead(bus.base + I2cConfig) and (1'u32 shl I2cMasterEn)) != 0:
    return false

  packet.bus = bus
  packet.buffer = data
  packet.size = len
  packet.position = 0
  packet.reading = reading
  packet.outcome = i2cOk
  when defined(bl808m0) or defined(bl808d0) or defined(bl808lp):
    if not packet.preparePacketDma(): return false

  let base = bus.base
  regSet(base + I2cFifoConfig0, I2cFifoClear)
  regClear(base + I2cFifoConfig1, I2cFifoThresholdMask)
  regWrite(base + I2cIntSts, I2cInterruptMask or I2cClearStatus or I2cInterruptEnable)

  var cfg = regRead(base + I2cConfig)
  cfg = cfg and not (I2cSlvAddrMask or I2cPktLenMask or
    I2cSubAddrBcMask or (1'u32 shl I2cSubAddrEn) or (1'u32 shl I2cPktDir))
  cfg = cfg or ((address.uint32 and 0x7F) shl I2cSlvAddrShift) or
    ((len - 1).uint32 shl I2cPktLenShift)
  if reading: cfg = cfg or (1'u32 shl I2cPktDir)
  if subAddress >= 0:
    cfg = cfg or (1'u32 shl I2cSubAddrEn)
    regWrite(base + I2cSubAddr, subAddress.uint32)
  regWrite(base + I2cConfig, cfg)

  when defined(bl808m0) or defined(bl808d0) or defined(bl808lp):
    if not packet.dma.start():
      packet.dma.release()
      return false
  else:
    if not reading: packet.serviceFifo()
  packet.started = true
  regSet(base + I2cConfig, 1'u32 shl I2cMasterEn)
  true

proc pollPacket*(packet: var I2cPacket): bool =
  ## Test for completion. The owner must call endPacket once, even on error.
  if not packet.started: return true
  let status = regRead(packet.bus.base + I2cIntSts)
  if (status and (1'u32 shl I2cIntNak)) != 0:
    packet.outcome = i2cNak
    return true
  if (status and (1'u32 shl I2cIntArb)) != 0:
    packet.outcome = i2cArbLost
    return true
  if (status and (1'u32 shl I2cIntFifoErr)) != 0:
    packet.outcome = i2cFifoError
    return true
  when defined(bl808m0) or defined(bl808d0) or defined(bl808lp):
    case packet.dma.status()
    of dmaBlockIdle, dmaBlockError:
      packet.outcome = i2cFifoError
      return true
    of dmaBlockRunning: return false
    of dmaBlockDone: packet.position = packet.size
  else:
    packet.serviceFifo()
  if (status and (1'u32 shl I2cIntEnd)) == 0 or
      (regRead(packet.bus.base + I2cBusBusy) and 1) != 0:
    return false
  if packet.position != packet.size:
    packet.outcome = i2cFifoError
  true

proc endPacket*(packet: var I2cPacket; cancelled = false): I2cError =
  if not packet.started: return i2cFifoError
  let base = packet.bus.base
  regWrite(base + I2cIntSts, I2cInterruptMask or I2cClearStatus or I2cInterruptEnable)
  regClear(base + I2cConfig, 1'u32 shl I2cMasterEn)
  when defined(bl808m0) or defined(bl808d0) or defined(bl808lp):
    packet.dma.release(not cancelled and packet.outcome == i2cOk)
  regSet(base + I2cFifoConfig0, I2cFifoClear)
  packet.started = false
  packet.buffer = nil
  if cancelled: i2cTimeout else: packet.outcome

proc transfer(i2c: I2c; address: uint8; data: ptr UncheckedArray[byte];
              len: int; reading: bool; subAddress = -1): I2cError =
  if len == 0: return i2cOk
  var packet: I2cPacket
  if not packet.beginPacket(i2c, address, data, len, reading, subAddress):
    return i2cFifoError
  var remaining = 500_000
  while remaining > 0:
    if packet.pollPacket():
      return packet.endPacket()
    dec remaining
  packet.endPacket(cancelled = true)

proc write*(i2c: I2c; address: uint8; data: openArray[uint8]): I2cError =
  if data.len == 0: return i2cOk
  i2c.transfer(address, cast[ptr UncheckedArray[byte]](unsafeAddr data[0]),
               data.len, reading = false)

proc read*(i2c: I2c; address: uint8; buf: var openArray[uint8]): I2cError =
  if buf.len == 0: return i2cOk
  i2c.transfer(address, cast[ptr UncheckedArray[byte]](addr buf[0]),
               buf.len, reading = true)

proc writeReg*(i2c: I2c; address, regAddr: uint8; data: openArray[uint8]): I2cError =
  if data.len == 0: return i2cOk
  i2c.transfer(address, cast[ptr UncheckedArray[byte]](unsafeAddr data[0]),
               data.len, reading = false, subAddress = regAddr.int)

proc readReg*(i2c: I2c; address, regAddr: uint8; buf: var openArray[uint8]): I2cError =
  if buf.len == 0: return i2cOk
  i2c.transfer(address, cast[ptr UncheckedArray[byte]](addr buf[0]),
               buf.len, reading = true, subAddress = regAddr.int)

proc writeRegByte*(i2c: I2c, address: uint8, regAddr: uint8, value: uint8): I2cError =
  ## Convenience: write a single byte to a register.
  var data = [value]
  i2c.writeReg(address, regAddr, data)

proc readRegByte*(i2c: I2c, address: uint8, regAddr: uint8): (uint8, I2cError) =
  ## Convenience: read a single byte from a register.
  var buf: array[1, uint8]
  let err = i2c.readReg(address, regAddr, buf)
  (buf[0], err)

# =============================================================================
# Bus status
# =============================================================================
proc busy*(i2c: I2c): bool {.inline.} =
  (regRead(i2c.base + I2cBusBusy) and 1) != 0

# =============================================================================
# Deinit / DMA
# =============================================================================
proc deinitI2c*(i2c: I2c) =
  ## Disable I2C and clear FIFOs.
  regClear(i2c.base + I2cConfig, 1'u32 shl I2cMasterEn)
  regSet(i2c.base + I2cFifoConfig0,
         (1'u32 shl I2cFifoTxClr) or (1'u32 shl I2cFifoRxClr))

proc enableDmaTx*(i2c: I2c) =
  regSet(i2c.base + I2cFifoConfig0, 1'u32 shl I2cFifoDmaTxEn)

proc enableDmaRx*(i2c: I2c) =
  regSet(i2c.base + I2cFifoConfig0, 1'u32 shl I2cFifoDmaRxEn)

proc txFifoAddr*(i2c: I2c): uint {.inline.} =
  i2c.base + I2cFifoWdata

proc rxFifoAddr*(i2c: I2c): uint {.inline.} =
  i2c.base + I2cFifoRdata
