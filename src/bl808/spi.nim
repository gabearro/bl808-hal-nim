## BL808 SPI driver (master and slave).
##
## SPI0 at 0x2000A200 (MCU subsystem, M0/LP accessible)
## SPI1 at 0x30008000 (MM subsystem, D0 accessible)
##
## Both share identical register layouts.

import mmio, memmap

# =============================================================================
# SPI register offsets
# =============================================================================
const
  SpiConfigReg*     = 0x00'u  # SPI configuration register
  SpiIntSts*        = 0x04'u  # Interrupt status / mask
  SpiBusBusy*       = 0x08'u  # Bus busy flag
  SpiPrd0*          = 0x10'u  # Clock period phase 0/1
  SpiPrd1*          = 0x14'u  # Clock period phase 2/3
  SpiRxdIgnr*       = 0x18'u  # RX data ignore count
  SpiStoValue*      = 0x1C'u  # Slave timeout value
  SpiFifoConfig0*   = 0x80'u  # FIFO configuration 0
  SpiFifoConfig1*   = 0x84'u  # FIFO configuration 1
  SpiFifoWdata*     = 0x88'u  # FIFO write data
  SpiFifoRdata*     = 0x8C'u  # FIFO read data

# =============================================================================
# SPI_CONFIG fields
# =============================================================================
const
  SpiMasterEn*      = 0       # Master mode enable
  SpiSlaveEn*       = 1       # Slave mode enable
  SpiFrameSizeShift* = 2      # Frame size [3:2]: 0=8bit, 1=16bit, 2=24bit, 3=32bit
  SpiFrameSizeMask*  = 0x03'u32 shl 2
  SpiSclkPol*       = 4       # Clock polarity (CPOL)
  SpiSclkPh*        = 5       # Clock phase (CPHA)
  SpiBitInv*        = 6       # Bit order invert (MSB/LSB first)
  SpiByteInv*       = 7       # Byte order invert
  SpiRxdIgnrEn*     = 8       # RX data ignore enable
  SpiMasterContEn*  = 9       # Master continuous transfer
  SpiSlave3pinMode* = 10      # Slave 3-pin mode (no CS)
  SpiDeglitchEn*    = 11      # Deglitch enable
  SpiDeglitchCntShift* = 12   # Deglitch count [15:12]
  SpiDeglitchCntMask*  = 0x0F'u32 shl 12

# =============================================================================
# SPI interrupt bits (in SPI_INT_STS)
# =============================================================================
const
  SpiIntEnd*        = 0       # Transfer end
  SpiIntTxFifo*     = 1       # TX FIFO ready
  SpiIntRxFifo*     = 2       # RX FIFO ready
  SpiIntSto*        = 3       # Slave timeout
  SpiIntTxUnder*    = 4       # TX FIFO underrun
  SpiIntFifoErr*    = 5       # FIFO error
  # Mask bits are at offset +8
  SpiIntMaskOffset* = 8

# =============================================================================
# FIFO fields
# =============================================================================
const
  SpiFifoDmaRxEn*   = 0
  SpiFifoDmaTxEn*   = 1
  SpiFifoTxClr*     = 2
  SpiFifoRxClr*     = 3
  SpiFifoTxOverflow*  = 4
  SpiFifoTxUnderflow* = 5
  SpiFifoRxOverflow*  = 6
  SpiFifoRxUnderflow* = 7

  SpiFifoTxCountShift* = 0
  SpiFifoTxCountMask*  = 0x1F'u32
  SpiFifoRxCountShift* = 8
  SpiFifoRxCountMask*  = 0x1F'u32 shl 8
  SpiFifoTxThreshShift* = 16
  SpiFifoTxThreshMask*  = 0x03'u32 shl 16
  SpiFifoRxThreshShift* = 24
  SpiFifoRxThreshMask*  = 0x03'u32 shl 24

# =============================================================================
# SPI types
# =============================================================================
type
  SpiId* = enum
    spi0  # MCU subsystem
    spi1  # MM subsystem

  SpiMode* = enum
    spiMode0  # CPOL=0, CPHA=0
    spiMode1  # CPOL=0, CPHA=1
    spiMode2  # CPOL=1, CPHA=0
    spiMode3  # CPOL=1, CPHA=1

  SpiFrameSize* = enum
    frame8bit  = 0
    frame16bit = 1
    frame24bit = 2
    frame32bit = 3

  SpiRole* = enum
    spiMaster
    spiSlave

  SpiError* = enum
    spiOk
    spiTimeout
    spiFifoError

  SpiConfig* = object
    mode*: SpiMode
    frameSize*: SpiFrameSize
    role*: SpiRole
    prescaler*: uint32   ## Clock phase period (sets SPI clock speed)
    deglitch*: bool

  Spi* = object
    base: uint
    id: SpiId
    frameSize: SpiFrameSize

# =============================================================================
# SPI base address
# =============================================================================
proc spiBase(id: SpiId): uint =
  case id
  of spi0: Spi0Base
  of spi1: Spi1Base

# =============================================================================
# Default config
# =============================================================================
const DefaultSpiConfig* = SpiConfig(
  mode: spiMode0,
  frameSize: frame8bit,
  role: spiMaster,
  prescaler: 4,
  deglitch: true,
)

# =============================================================================
# Initialization
# =============================================================================
proc initSpi*(id: SpiId, config: SpiConfig): Spi =
  ## Initialize SPI peripheral. Returns an SPI handle.
  result.base = spiBase(id)
  result.id = id
  result.frameSize = config.frameSize
  let base = result.base

  # Disable SPI during configuration
  regClear(base + SpiConfigReg, (1'u32 shl SpiMasterEn) or (1'u32 shl SpiSlaveEn))

  # Build config register
  var cfg = 0'u32

  # Role
  case config.role
  of spiMaster: cfg = cfg or (1'u32 shl SpiMasterEn)
  of spiSlave:  cfg = cfg or (1'u32 shl SpiSlaveEn)

  # Frame size
  cfg = cfg or (config.frameSize.uint32 shl SpiFrameSizeShift)

  # Clock mode
  case config.mode
  of spiMode0: discard  # CPOL=0, CPHA=0
  of spiMode1: cfg = cfg or (1'u32 shl SpiSclkPh)
  of spiMode2: cfg = cfg or (1'u32 shl SpiSclkPol)
  of spiMode3: cfg = cfg or (1'u32 shl SpiSclkPol) or (1'u32 shl SpiSclkPh)

  # Deglitch
  if config.deglitch:
    cfg = cfg or (1'u32 shl SpiDeglitchEn) or (3'u32 shl SpiDeglitchCntShift)

  regWrite(base + SpiConfigReg, cfg)

  # Clock period: prescaler sets all 4 phases
  let prd = config.prescaler and 0xFF
  regWrite(base + SpiPrd0, (prd shl 16) or prd)
  regWrite(base + SpiPrd1, (prd shl 16) or prd)

  # Clear FIFOs
  regSet(base + SpiFifoConfig0,
         (1'u32 shl SpiFifoTxClr) or (1'u32 shl SpiFifoRxClr))

  # Mask all interrupts
  regSet(base + SpiIntSts, 0x3F'u32 shl SpiIntMaskOffset)

proc deinitSpi*(spi: Spi) =
  ## Disable SPI and clear FIFOs.
  regClear(spi.base + SpiConfigReg, (1'u32 shl SpiMasterEn) or (1'u32 shl SpiSlaveEn))
  regSet(spi.base + SpiFifoConfig0,
         (1'u32 shl SpiFifoTxClr) or (1'u32 shl SpiFifoRxClr))

# =============================================================================
# FIFO status
# =============================================================================
proc txFifoCount*(spi: Spi): uint32 {.inline.} =
  regRead(spi.base + SpiFifoConfig1) and SpiFifoTxCountMask

proc rxFifoCount*(spi: Spi): uint32 {.inline.} =
  (regRead(spi.base + SpiFifoConfig1) and SpiFifoRxCountMask) shr SpiFifoRxCountShift

proc busy*(spi: Spi): bool {.inline.} =
  (regRead(spi.base + SpiBusBusy) and 1) != 0

# =============================================================================
# Blocking transfer
# =============================================================================
proc transferByte*(spi: Spi, txByte: uint8): (uint8, SpiError) =
  ## Full-duplex transfer of one byte. Returns received byte.
  var timeout = 100_000'u32

  # Wait for TX FIFO space
  while spi.txFifoCount() >= 4:
    timeout.dec
    if timeout == 0: return (0'u8, spiTimeout)

  # Write TX data
  regWrite(spi.base + SpiFifoWdata, txByte.uint32)

  # Wait for RX data
  timeout = 100_000
  while spi.rxFifoCount() == 0:
    timeout.dec
    if timeout == 0: return (0'u8, spiTimeout)

  let rxData = regRead(spi.base + SpiFifoRdata) and 0xFF
  (rxData.uint8, spiOk)

proc transfer*(spi: Spi, txBuf: openArray[uint8], rxBuf: var openArray[uint8]): SpiError =
  ## Full-duplex transfer of a buffer. txBuf and rxBuf must be the same length.
  for i in 0 ..< min(txBuf.len, rxBuf.len):
    let (rx, err) = spi.transferByte(txBuf[i])
    if err != spiOk: return err
    rxBuf[i] = rx
  spiOk

proc send*(spi: Spi, txBuf: openArray[uint8]): SpiError =
  ## Send-only SPI transfer (received data discarded).
  for b in txBuf:
    let (_, err) = spi.transferByte(b)
    if err != spiOk: return err
  spiOk

proc recv*(spi: Spi, rxBuf: var openArray[uint8]): SpiError =
  ## Receive-only SPI transfer (sends 0xFF).
  for i in 0 ..< rxBuf.len:
    let (rx, err) = spi.transferByte(0xFF)
    if err != spiOk: return err
    rxBuf[i] = rx
  spiOk

# =============================================================================
# FIFO / DMA
# =============================================================================
proc clearFifos*(spi: Spi) =
  regSet(spi.base + SpiFifoConfig0,
         (1'u32 shl SpiFifoTxClr) or (1'u32 shl SpiFifoRxClr))

proc enableDmaTx*(spi: Spi) =
  regSet(spi.base + SpiFifoConfig0, 1'u32 shl SpiFifoDmaTxEn)

proc enableDmaRx*(spi: Spi) =
  regSet(spi.base + SpiFifoConfig0, 1'u32 shl SpiFifoDmaRxEn)

proc txFifoAddr*(spi: Spi): uint {.inline.} =
  spi.base + SpiFifoWdata

proc rxFifoAddr*(spi: Spi): uint {.inline.} =
  spi.base + SpiFifoRdata

# =============================================================================
# Interrupt support
# =============================================================================
proc enableInterrupt*(spi: Spi, intBit: uint32) =
  regClear(spi.base + SpiIntSts, 1'u32 shl (intBit + SpiIntMaskOffset.uint32))

proc disableInterrupt*(spi: Spi, intBit: uint32) =
  regSet(spi.base + SpiIntSts, 1'u32 shl (intBit + SpiIntMaskOffset.uint32))

proc clearInterrupt*(spi: Spi, intBit: uint32) =
  regSet(spi.base + SpiIntSts, 1'u32 shl (intBit + 16))
