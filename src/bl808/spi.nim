## BL808 SPI driver (master and slave).
##
## SPI0 at 0x2000A200 (MCU subsystem, M0/LP accessible)
## SPI1 at 0x30008000 (MM subsystem, D0 accessible)
##
## Both share identical register layouts.

import mmio, memmap
when defined(bl808m0) or defined(bl808d0) or defined(bl808lp):
  import core, dma, dmablock

# =============================================================================
# SPI register offsets
# =============================================================================
const
  SpiConfigReg*     = 0x00'u  # SPI configuration register
  SpiIntSts*        = 0x04'u  # Interrupt status / mask
  SpiBusBusy*       = 0x08'u  # Bus busy flag
  SpiPrd0*          = 0x10'u  # Clock period: start, stop, data phase 0, data phase 1
  SpiPrd1*          = 0x14'u  # Clock period: interval between frames
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
  SpiSclkPh*        = 5       # Clock phase, inverted: 1 = sample on the first edge (CPHA=0)
  SpiBitInv*        = 6       # Bit order invert (MSB/LSB first)
  SpiByteInv*       = 7       # Byte order invert
  SpiRxdIgnrEn*     = 8       # RX data ignore enable
  SpiMasterContEn*  = 9       # Master continuous transfer
  SpiSlave3pinMode* = 10      # Slave 3-pin mode (no CS)
  SpiDeglitchEn*    = 11      # Deglitch enable
  SpiDeglitchCntShift* = 12   # Deglitch count [15:12]
  SpiDeglitchCntMask*  = 0x0F'u32 shl 12

# =============================================================================
# Clock period fields (each lasts value + 1 source clocks)
# =============================================================================
const
  SpiPrdStartShift*  = 0      # PRD_0 [7:0]: CS active to the first clock edge
  SpiPrdStopShift*   = 8      # PRD_0 [15:8]: last clock edge to CS inactive
  SpiPrdPhase0Shift* = 16     # PRD_0 [23:16]: first half of a bit
  SpiPrdPhase1Shift* = 24     # PRD_0 [31:24]: second half of a bit
  SpiPrdIntervalMask* = 0xFF'u32  # PRD_1 [7:0]: gap between frames

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
  SpiIntBitsMask*   = 0x3F'u32
  SpiIntMaskOffset* = 8
  SpiIntClearOffset* = 16
  SpiIntEnableOffset* = 24

# =============================================================================
# FIFO fields
# =============================================================================
const
  SpiFifoDmaTxEn*   = 0
  SpiFifoDmaRxEn*   = 1
  SpiFifoTxClr*     = 2
  SpiFifoRxClr*     = 3
  SpiFifoTxOverflow*  = 4
  SpiFifoTxUnderflow* = 5
  SpiFifoRxOverflow*  = 6
  SpiFifoRxUnderflow* = 7

  # FIFO_CONFIG1 [5:0] reports TX free entries, not TX used entries.
  SpiFifoTxFreeShift* = 0
  SpiFifoTxFreeMask*  = 0x3F'u32
  SpiFifoTxCountShift* = SpiFifoTxFreeShift
  SpiFifoTxCountMask*  = SpiFifoTxFreeMask
  SpiFifoRxCountShift* = 8
  SpiFifoRxCountMask*  = 0x3F'u32 shl 8
  SpiFifoTxThreshShift* = 16
  SpiFifoTxThreshMask*  = 0x1F'u32 shl 16
  SpiFifoRxThreshShift* = 24
  SpiFifoRxThreshMask*  = 0x1F'u32 shl 24

# =============================================================================
# SPI types
# =============================================================================
type
  SpiId* = enum
    spi0  # MCU subsystem
    spi1  # MM subsystem

  SpiMode* = enum
    ## The standard SPI modes. The hardware's phase bit is the inverse of
    ## CPHA (`SpiSclkPh` set = sample on the first clock edge).
    spiMode0  # CPOL=0, CPHA=0: idle low, sample on the rising edge
    spiMode1  # CPOL=0, CPHA=1: idle low, sample on the falling edge
    spiMode2  # CPOL=1, CPHA=0: idle high, sample on the falling edge
    spiMode3  # CPOL=1, CPHA=1: idle high, sample on the rising edge

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
    spiCancelled   ## The transfer was abandoned before it finished

  SpiConfig* = object
    mode*: SpiMode
    frameSize*: SpiFrameSize
    role*: SpiRole
    prescaler*: uint32   ## Half a bit lasts prescaler + 1 source clocks:
                         ## SCLK = source / (2 * (prescaler + 1))
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

const
  # GLB_PARM_CFG0: whether the SPI pads act as a master's or a slave's.
  GlbParmCfg0 = GlbBase + 0x510'u
  GlbSpi0MasterMode = 12
  GlbMmSpiMasterMode = 27

proc selectPadRole(id: SpiId, role: SpiRole) =
  let bit = 1'u32 shl (if id == spi0: GlbSpi0MasterMode else: GlbMmSpiMasterMode)
  regModify(GlbParmCfg0, bit, if role == spiMaster: bit else: 0'u32)

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
proc setPrescaler*(spi: Spi, prescaler: uint32) =
  ## Set the clock period: the start and stop delays, each half of a bit
  ## and the frame interval all last (`prescaler` + 1) source clocks, so
  ## SCLK = source / (2 * (prescaler + 1)). Change it only between transfers.
  let prd = prescaler and 0xFF
  regWrite(spi.base + SpiPrd0,
           (prd shl SpiPrdStartShift) or (prd shl SpiPrdStopShift) or
           (prd shl SpiPrdPhase0Shift) or (prd shl SpiPrdPhase1Shift))
  regModify(spi.base + SpiPrd1, SpiPrdIntervalMask, prd)

proc initSpi*(id: SpiId, config: SpiConfig): Spi =
  ## Initialize SPI peripheral. Returns an SPI handle.
  ## The peripheral clock, its source and divider, and the pins are the
  ## caller's (see `glb` and `gpioSetupSpi`).
  selectPadRole(id, config.role)
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

  # Clock mode (the phase bit is set for CPHA=0)
  case config.mode
  of spiMode0: cfg = cfg or (1'u32 shl SpiSclkPh)
  of spiMode1: discard
  of spiMode2: cfg = cfg or (1'u32 shl SpiSclkPol) or (1'u32 shl SpiSclkPh)
  of spiMode3: cfg = cfg or (1'u32 shl SpiSclkPol)

  # Deglitch
  if config.deglitch:
    cfg = cfg or (1'u32 shl SpiDeglitchEn) or (3'u32 shl SpiDeglitchCntShift)

  regWrite(base + SpiConfigReg, cfg)

  # Clock period: start, stop, both halves of a bit and the frame interval
  result.setPrescaler(config.prescaler)

  # Clear FIFOs
  regSet(base + SpiFifoConfig0,
         (1'u32 shl SpiFifoTxClr) or (1'u32 shl SpiFifoRxClr))

  # Enable interrupt sources in the peripheral but keep them masked.
  regWrite(base + SpiIntSts,
           (SpiIntBitsMask shl SpiIntEnableOffset) or
           (SpiIntBitsMask shl SpiIntMaskOffset) or
           (SpiIntBitsMask shl SpiIntClearOffset))

proc deinitSpi*(spi: Spi) =
  ## Disable SPI and clear FIFOs.
  regClear(spi.base + SpiConfigReg, (1'u32 shl SpiMasterEn) or (1'u32 shl SpiSlaveEn))
  regSet(spi.base + SpiFifoConfig0,
         (1'u32 shl SpiFifoTxClr) or (1'u32 shl SpiFifoRxClr))

proc baseAddr*(spi: Spi): uint {.inline.} =
  ## Return the SPI MMIO base address.
  spi.base

# =============================================================================
# FIFO status
# =============================================================================
proc fifoDepth*(spi: Spi): uint32 {.inline.} =
  case spi.frameSize
  of frame8bit: 32'u32
  of frame16bit: 16'u32
  of frame24bit, frame32bit: 8'u32

proc txFifoFree*(spi: Spi): uint32 {.inline.} =
  regRead(spi.base + SpiFifoConfig1) and SpiFifoTxFreeMask

proc txFifoCount*(spi: Spi): uint32 {.inline.} =
  let depth = spi.fifoDepth()
  let free = spi.txFifoFree()
  if free >= depth: 0'u32 else: depth - free

proc rxFifoCount*(spi: Spi): uint32 {.inline.} =
  (regRead(spi.base + SpiFifoConfig1) and SpiFifoRxCountMask) shr SpiFifoRxCountShift

proc busy*(spi: Spi): bool {.inline.} =
  (regRead(spi.base + SpiBusBusy) and 1) != 0

# =============================================================================
# FIFO / DMA
# =============================================================================
proc clearFifos*(spi: Spi) =
  regSet(spi.base + SpiFifoConfig0,
         (1'u32 shl SpiFifoTxClr) or (1'u32 shl SpiFifoRxClr))

proc setFifoThresholds*(spi: Spi, tx, rx: uint32) =
  ## The TX FIFO interrupt (and DMA request) is raised while more than `tx`
  ## entries are free, the RX one while more than `rx` entries are waiting.
  regModify(spi.base + SpiFifoConfig1, SpiFifoTxThreshMask or SpiFifoRxThreshMask,
            (tx shl SpiFifoTxThreshShift) or (rx shl SpiFifoRxThreshShift))

proc enableDmaTx*(spi: Spi) =
  regSet(spi.base + SpiFifoConfig0, 1'u32 shl SpiFifoDmaTxEn)

proc enableDmaRx*(spi: Spi) =
  regSet(spi.base + SpiFifoConfig0, 1'u32 shl SpiFifoDmaRxEn)

proc txFifoAddr*(spi: Spi): uint {.inline.} =
  spi.base + SpiFifoWdata

proc rxFifoAddr*(spi: Spi): uint {.inline.} =
  spi.base + SpiFifoRdata

# =============================================================================
# Data transfers
# =============================================================================
when defined(bl808m0) or defined(bl808d0) or defined(bl808lp):
  const SpiEnableMask = (1'u32 shl SpiMasterEn) or (1'u32 shl SpiSlaveEn)

  type SpiDmaTransfer* = object
    spi: Spi
    tx, rx: DmaBlock
    rxBuffer: DmaReceiveBuffer
    txStaging, rxStaging: seq[byte]
    rxData: ptr UncheckedArray[byte]
    frames, stride: int
    dummyTx: uint32
    running: bool

  proc start*(transfer: var SpiDmaTransfer; spi: Spi;
              tx, rx: ptr UncheckedArray[byte]; len: int): bool =
    ## Start an SPI DMA transaction. The caller owns CS and keeps the buffers
    ## alive until completion or cancellation. False leaves the bus idle.
    when defined(bl808m0) or defined(bl808lp):
      const
        SpiBase = Spi0Base
        TxRequest = dmaPeriphSpi0Tx.uint32
        RxRequest = dmaPeriphSpi0Rx.uint32
    elif defined(bl808d0):
      const
        SpiBase = Spi1Base
        TxRequest = dmaMmSpi1Tx.uint32
        RxRequest = dmaMmSpi1Rx.uint32
    if transfer.running or spi.baseAddr() != SpiBase or len <= 0 or
        (tx == nil and rx == nil) or
        (rx != nil and not dmaBufferInRam(cast[uint](rx), len)):
      return false
    let base = spi.baseAddr()
    if (regRead(base + SpiConfigReg) and SpiEnableMask) == 0 or
        (regRead(base + SpiFifoConfig0) and
          ((1'u32 shl SpiFifoDmaTxEn) or (1'u32 shl SpiFifoDmaRxEn))) != 0:
      return false

    let width = case spi.frameSize
      of frame8bit: width8
      of frame16bit: width16
      of frame24bit, frame32bit: width32
    let stride = 1 shl ord(width)
    if len > high(int) div stride or len.uint64 > high(uint32).uint64: return false

    transfer.dummyTx = 0xFF
    var txAddress = cast[uint](addr transfer.dummyTx)
    if tx != nil:
      txAddress = cast[uint](tx)
      if stride != 1 or not dmaBufferInRam(txAddress, len):
        transfer.txStaging.setLen(len * stride)
        for i in 0 ..< len:
          transfer.txStaging[i * stride] = tx[i]
        txAddress = cast[uint](addr transfer.txStaging[0])

    let controller = openCoreDma()
    let txConfig = DmaTransferConfig(
      srcAddr: txAddress.uint32, dstAddr: spi.txFifoAddr().uint32,
      transferSize: len.uint32, srcWidth: width, dstWidth: width,
      srcIncrement: tx != nil, flow: flowM2P_Dma, dstPeriph: TxRequest)
    if not transfer.tx.prepare(controller, txConfig): return false

    if rx != nil:
      let dest = cast[uint](rx)
      let source = cast[uint](tx)
      let overlaps = tx != nil and dest < source + len.uint and source < dest + len.uint
      if stride == 1:
        transfer.rxBuffer.prepare(rx, len, stage = overlaps)
      else:
        transfer.rxStaging.setLen(len * stride)
        transfer.rxBuffer.prepare(addr transfer.rxStaging[0], len * stride)
      let rxConfig = DmaTransferConfig(
        srcAddr: spi.rxFifoAddr().uint32, dstAddr: transfer.rxBuffer.address.uint32,
        transferSize: len.uint32, srcWidth: width, dstWidth: width,
        dstIncrement: true, flow: flowP2M_Dma, srcPeriph: RxRequest)
      if not transfer.rx.prepare(controller, rxConfig):
        transfer.rxBuffer.finish(false)
        transfer.tx.release()
        return false

    transfer.spi = spi
    transfer.rxData = rx
    transfer.stride = stride
    transfer.frames = len
    transfer.running = true
    dcacheCleanRange(txAddress, (if tx == nil: stride else: len * stride).uint)

    spi.clearFifos()
    spi.setFifoThresholds(0, 0)
    if rx != nil:
      spi.enableDmaRx()
      transfer.rx.start()
    spi.enableDmaTx()
    transfer.tx.start()
    true

  proc release(transfer: var SpiDmaTransfer; success: bool) =
    let spi = transfer.spi
    let base = spi.baseAddr()
    regClear(base + SpiFifoConfig0, (1'u32 shl SpiFifoDmaTxEn) or (1'u32 shl SpiFifoDmaRxEn))
    transfer.tx.release()
    transfer.rx.release()
    if success:
      spi.clearFifos()
    else:
      let enabled = regRead(base + SpiConfigReg) and SpiEnableMask
      regClear(base + SpiConfigReg, SpiEnableMask)
      spi.clearFifos()
      regSet(base + SpiConfigReg, enabled)
    transfer.rxBuffer.finish(success)
    if success and transfer.rxData != nil and transfer.stride != 1:
      for i in 0 ..< transfer.frames:
        transfer.rxData[i] = transfer.rxStaging[i * transfer.stride]
    transfer.rxData = nil
    transfer.running = false

  proc poll*(transfer: var SpiDmaTransfer): DmaBlockStatus =
    ## Completion includes the last byte on the wire, beyond DMA completion.
    if not transfer.running: return dmaBlockIdle
    let tx = transfer.tx.status()
    let rx = transfer.rx.status()
    if tx == dmaBlockError or rx == dmaBlockError:
      transfer.release(false)
      return dmaBlockError
    if tx == dmaBlockRunning or rx == dmaBlockRunning or
        transfer.spi.txFifoCount() != 0 or transfer.spi.busy():
      return dmaBlockRunning
    transfer.release(true)
    dmaBlockDone

  proc cancel*(transfer: var SpiDmaTransfer) =
    if transfer.running:
      transfer.release(false)

  proc blockingTransfer(spi: Spi; tx, rx: ptr UncheckedArray[byte]; len: int): SpiError =
    if len == 0: return spiOk
    var transfer: SpiDmaTransfer
    if not transfer.start(spi, tx, rx, len): return spiFifoError
    # Keep the per-frame wait budget of the blocking byte interface.
    var remaining = 100_000'u64 * len.uint64
    while remaining > 0:
      case transfer.poll()
      of dmaBlockDone: return spiOk
      of dmaBlockIdle, dmaBlockError: return spiFifoError
      of dmaBlockRunning: dec remaining
    transfer.cancel()
    spiTimeout

  proc transferByte*(spi: Spi; txByte: uint8): (uint8, SpiError) =
    ## Full-duplex transfer of one byte.
    var rx: byte
    let err = spi.blockingTransfer(cast[ptr UncheckedArray[byte]](unsafeAddr txByte),
                                   cast[ptr UncheckedArray[byte]](addr rx), 1)
    (rx, err)

  proc transfer*(spi: Spi; txBuf: openArray[uint8]; rxBuf: var openArray[uint8]): SpiError =
    ## Full-duplex transfer of a buffer.
    let len = min(txBuf.len, rxBuf.len)
    if len == 0: return spiOk
    spi.blockingTransfer(cast[ptr UncheckedArray[byte]](unsafeAddr txBuf[0]),
                         cast[ptr UncheckedArray[byte]](addr rxBuf[0]), len)

  proc send*(spi: Spi; txBuf: openArray[uint8]): SpiError =
    ## Send the buffer, discarding input.
    if txBuf.len == 0: return spiOk
    spi.blockingTransfer(cast[ptr UncheckedArray[byte]](unsafeAddr txBuf[0]), nil, txBuf.len)

  proc recv*(spi: Spi; rxBuf: var openArray[uint8]): SpiError =
    ## Receive while sending 0xFF on each frame.
    if rxBuf.len == 0: return spiOk
    spi.blockingTransfer(nil, cast[ptr UncheckedArray[byte]](addr rxBuf[0]), rxBuf.len)
else:
  proc transferByte*(spi: Spi, txByte: uint8): (uint8, SpiError) =
    ## Full-duplex transfer of one byte. Returns received byte.
    var timeout = 100_000'u32

    # Wait for TX FIFO space
    while spi.txFifoFree() == 0:
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
# Interrupt support
# =============================================================================
proc enableInterrupt*(spi: Spi, intBit: uint32) =
  let bit = 1'u32 shl intBit
  let cur = regRead(spi.base + SpiIntSts)
  let enableBits = ((cur shr SpiIntEnableOffset) and SpiIntBitsMask) or bit
  let maskBits = ((cur shr SpiIntMaskOffset) and SpiIntBitsMask) and not bit
  regWrite(spi.base + SpiIntSts,
           (enableBits shl SpiIntEnableOffset) or
           (maskBits shl SpiIntMaskOffset))

proc disableInterrupt*(spi: Spi, intBit: uint32) =
  let bit = 1'u32 shl intBit
  let cur = regRead(spi.base + SpiIntSts)
  let enableBits = (cur shr SpiIntEnableOffset) and SpiIntBitsMask
  let maskBits = ((cur shr SpiIntMaskOffset) and SpiIntBitsMask) or bit
  regWrite(spi.base + SpiIntSts,
           (enableBits shl SpiIntEnableOffset) or
           (maskBits shl SpiIntMaskOffset))

proc clearInterrupt*(spi: Spi, intBit: uint32) =
  let cur = regRead(spi.base + SpiIntSts)
  regWrite(spi.base + SpiIntSts,
           (cur and ((SpiIntBitsMask shl SpiIntEnableOffset) or
                     (SpiIntBitsMask shl SpiIntMaskOffset))) or
           (1'u32 shl (intBit + SpiIntClearOffset.uint32)))
