## BL808 I2C master driver.
##
## I2C0 at 0x2000A300 (MCU)
## I2C1 at 0x2000A900 (MCU)
## I2C2 at 0x30003000 (MM)
## I2C3 at 0x30004000 (MM)
##
## All instances share the same register layout.

import mmio, memmap

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
  I2cAddr10bEn*     = 7       # 10-bit address enable
  I2cSlvAddrShift*  = 8       # Slave address [17:8]
  I2cSlvAddrMask*   = 0x3FF'u32 shl 8
  I2cPktLenShift*   = 20      # Packet length [27:20] (n-1)
  I2cPktLenMask*    = 0xFF'u32 shl 20
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

# =============================================================================
# FIFO fields
# =============================================================================
const
  I2cFifoDmaRxEn*   = 0
  I2cFifoDmaTxEn*   = 1
  I2cFifoTxClr*     = 2
  I2cFifoRxClr*     = 3

  I2cFifoTxCountMask* = 0x03'u32
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
    base: uint
    id: I2cId

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

  # Phase periods: each is a 16-bit pair (phase0 | phase1<<16)
  let startPrd = (halfPeriod shl 16) or halfPeriod
  let stopPrd = (halfPeriod shl 16) or halfPeriod
  let dataPrd = (halfPeriod shl 16) or halfPeriod

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
# Transfer helpers (internal)
# =============================================================================
proc waitComplete(i2c: I2c, timeout: uint32 = 500_000): I2cError =
  ## Wait for transfer to complete. Returns error status.
  var countdown = timeout
  while countdown > 0:
    let sts = regRead(i2c.base + I2cIntSts)
    if (sts and (1'u32 shl I2cIntEnd)) != 0:
      # Clear end interrupt
      regSet(i2c.base + I2cIntSts, 1'u32 shl I2cIntEnd)
      # Check for NAK
      if (sts and (1'u32 shl I2cIntNak)) != 0:
        regSet(i2c.base + I2cIntSts, 1'u32 shl I2cIntNak)
        return i2cNak
      # Check for arbitration lost
      if (sts and (1'u32 shl I2cIntArb)) != 0:
        regSet(i2c.base + I2cIntSts, 1'u32 shl I2cIntArb)
        return i2cArbLost
      return i2cOk
    countdown.dec
  i2cTimeout

proc startTransfer(i2c: I2c, address: uint8, isRead: bool, length: uint32,
                   subAddr: uint32 = 0, subAddrLen: uint32 = 0) =
  ## Configure and start an I2C transfer.
  let base = i2c.base

  # Clear FIFOs
  regSet(base + I2cFifoConfig0,
         (1'u32 shl I2cFifoTxClr) or (1'u32 shl I2cFifoRxClr))

  # Clear all interrupt flags
  regWrite(base + I2cIntSts,
           (1'u32 shl I2cIntEnd) or (1'u32 shl I2cIntNak) or
           (1'u32 shl I2cIntArb) or (1'u32 shl I2cIntFifoErr))

  var cfg = regRead(base + I2cConfig)

  # Set slave address
  cfg = (cfg and not I2cSlvAddrMask) or ((address.uint32 and 0x7F) shl I2cSlvAddrShift)

  # Direction
  if isRead:
    cfg = cfg or (1'u32 shl I2cPktDir)
  else:
    cfg = cfg and not (1'u32 shl I2cPktDir)

  # Packet length (n-1)
  let pktLen = if length > 0: length - 1 else: 0'u32
  cfg = (cfg and not I2cPktLenMask) or ((pktLen and 0xFF) shl I2cPktLenShift)

  # Sub-address
  if subAddrLen > 0:
    cfg = cfg or (1'u32 shl I2cSubAddrEn)
    cfg = (cfg and not I2cSubAddrBcMask) or (((subAddrLen - 1) and 0x03) shl I2cSubAddrBcShift)
    regWrite(base + I2cSubAddr, subAddr)
  else:
    cfg = cfg and not (1'u32 shl I2cSubAddrEn)

  regWrite(base + I2cConfig, cfg)

  # Start transfer by setting master enable
  regSet(base + I2cConfig, 1'u32 shl I2cMasterEn)

# =============================================================================
# Public API
# =============================================================================
proc write*(i2c: I2c, address: uint8, data: openArray[uint8]): I2cError =
  ## Write data to an I2C slave.
  if data.len == 0: return i2cOk
  let base = i2c.base

  # Load TX FIFO before starting
  for i in 0 ..< min(data.len, 4):
    regWrite(base + I2cFifoWdata, data[i].uint32)

  startTransfer(i2c, address, isRead = false, length = data.len.uint32)

  # Feed remaining data
  var idx = 4
  while idx < data.len:
    let txCount = regRead(base + I2cFifoConfig1) and I2cFifoTxCountMask
    if txCount < 2:
      regWrite(base + I2cFifoWdata, data[idx].uint32)
      idx.inc

  # Wait for transfer to complete
  result = waitComplete(i2c)
  # Disable master after transfer
  regClear(base + I2cConfig, 1'u32 shl I2cMasterEn)

proc read*(i2c: I2c, address: uint8, buf: var openArray[uint8]): I2cError =
  ## Read data from an I2C slave.
  if buf.len == 0: return i2cOk
  let base = i2c.base

  startTransfer(i2c, address, isRead = true, length = buf.len.uint32)

  # Read data from RX FIFO
  var idx = 0
  var timeout = 500_000'u32
  while idx < buf.len and timeout > 0:
    let rxCount = (regRead(base + I2cFifoConfig1) and I2cFifoRxCountMask) shr I2cFifoRxCountShift
    if rxCount > 0:
      buf[idx] = (regRead(base + I2cFifoRdata) and 0xFF).uint8
      idx.inc
    else:
      timeout.dec

  if timeout == 0:
    regClear(base + I2cConfig, 1'u32 shl I2cMasterEn)
    return i2cTimeout

  result = waitComplete(i2c)
  regClear(base + I2cConfig, 1'u32 shl I2cMasterEn)

proc writeReg*(i2c: I2c, address: uint8, regAddr: uint8, data: openArray[uint8]): I2cError =
  ## Write to a register (sub-address) on an I2C slave.
  if data.len == 0: return i2cOk
  let base = i2c.base

  # Load TX data
  for i in 0 ..< min(data.len, 4):
    regWrite(base + I2cFifoWdata, data[i].uint32)

  startTransfer(i2c, address, isRead = false, length = data.len.uint32,
                subAddr = regAddr.uint32, subAddrLen = 1)

  var idx = 4
  while idx < data.len:
    let txCount = regRead(base + I2cFifoConfig1) and I2cFifoTxCountMask
    if txCount < 2:
      regWrite(base + I2cFifoWdata, data[idx].uint32)
      idx.inc

  result = waitComplete(i2c)
  regClear(base + I2cConfig, 1'u32 shl I2cMasterEn)

proc readReg*(i2c: I2c, address: uint8, regAddr: uint8, buf: var openArray[uint8]): I2cError =
  ## Read from a register (sub-address) on an I2C slave.
  if buf.len == 0: return i2cOk
  let base = i2c.base

  startTransfer(i2c, address, isRead = true, length = buf.len.uint32,
                subAddr = regAddr.uint32, subAddrLen = 1)

  var idx = 0
  var timeout = 500_000'u32
  while idx < buf.len and timeout > 0:
    let rxCount = (regRead(base + I2cFifoConfig1) and I2cFifoRxCountMask) shr I2cFifoRxCountShift
    if rxCount > 0:
      buf[idx] = (regRead(base + I2cFifoRdata) and 0xFF).uint8
      idx.inc
    else:
      timeout.dec

  if timeout == 0:
    regClear(base + I2cConfig, 1'u32 shl I2cMasterEn)
    return i2cTimeout

  result = waitComplete(i2c)
  regClear(base + I2cConfig, 1'u32 shl I2cMasterEn)

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
