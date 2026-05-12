## Async I2C driver for the BL808 kernel.
##
## Interrupt-driven I2C master operations using the ISR bridge.
## The ISR handles mid-transfer FIFO feeding/draining and signals
## completion via the ISR bridge slot mechanism.
##
##   var ai = initAsyncI2c(i2c0, i2cStandard, 32_000_000)
##   let err = await ai.writeReg(0x50, 0x00, data)
##   let err = await ai.readReg(0x50, 0x00, buf)

import ../i2c, ../mmio, ../irq
import ./runtime, ./isrbridge

# =============================================================================
# Types
# =============================================================================

type
  AsyncI2c* = ref object
    i2c*: I2c
    irqNum: uint32
    index: int
    slot: int               ## ISR bridge slot (-1 = idle)
    error: I2cError         ## Result set by ISR
    txData: ptr UncheckedArray[uint8]
    txLen: int
    txPos: int              ## Next byte to write to FIFO
    rxData: ptr UncheckedArray[uint8]
    rxLen: int
    rxPos: int              ## Next position to fill

# =============================================================================
# ISR dispatch
# =============================================================================

var asyncI2cs: array[4, AsyncI2c]

proc i2cIsrCommon(idx: int) =
  let ai = asyncI2cs[idx]
  if ai == nil: return
  let base = ai.i2c.base

  var sts = regRead(base + I2cIntSts) and 0x3F'u32  # status bits [5:0]

  # NAK — abort transfer
  if (sts and (1'u32 shl I2cIntNak)) != 0:
    ai.error = i2cNak
    # Disable master, mask all interrupts
    regClear(base + I2cConfig, 1'u32 shl I2cMasterEn)
    regSet(base + I2cIntSts, 0x3F'u32 shl I2cIntMaskOffset)
    # Clear interrupt flags
    regSet(base + I2cIntSts, 0x3F'u32 shl I2cIntClrOffset)
    if ai.slot >= 0:
      completeIsrSlot(ai.slot)
      ai.slot = -1
    return

  # Arbitration lost — abort
  if (sts and (1'u32 shl I2cIntArb)) != 0:
    ai.error = i2cArbLost
    regClear(base + I2cConfig, 1'u32 shl I2cMasterEn)
    regSet(base + I2cIntSts, 0x3F'u32 shl I2cIntMaskOffset)
    regSet(base + I2cIntSts, 0x3F'u32 shl I2cIntClrOffset)
    if ai.slot >= 0:
      completeIsrSlot(ai.slot)
      ai.slot = -1
    return

  # TX FIFO ready — feed more data
  if (sts and (1'u32 shl I2cIntTxFifo)) != 0:
    while ai.txPos < ai.txLen:
      let txFree = regRead(base + I2cFifoConfig1) and I2cFifoTxCountMask
      if txFree == 0: break
      regWrite(base + I2cFifoWdata, ai.txData[ai.txPos].uint32)
      ai.txPos.inc

  # RX FIFO ready — drain data
  if (sts and (1'u32 shl I2cIntRxFifo)) != 0:
    while ai.rxPos < ai.rxLen:
      let rxCount = (regRead(base + I2cFifoConfig1) and I2cFifoRxCountMask) shr I2cFifoRxCountShift
      if rxCount == 0: break
      ai.rxData[ai.rxPos] = (regRead(base + I2cFifoRdata) and 0xFF).uint8
      ai.rxPos.inc

  # Re-read status — FIFO operations may have completed the transfer
  sts = regRead(base + I2cIntSts) and 0x3F'u32

  # Transfer end — drain remaining RX, complete
  if (sts and (1'u32 shl I2cIntEnd)) != 0:
    # Drain any remaining RX FIFO bytes
    while ai.rxPos < ai.rxLen:
      let rxCount = (regRead(base + I2cFifoConfig1) and I2cFifoRxCountMask) shr I2cFifoRxCountShift
      if rxCount == 0: break
      ai.rxData[ai.rxPos] = (regRead(base + I2cFifoRdata) and 0xFF).uint8
      ai.rxPos.inc

    ai.error = i2cOk
    regClear(base + I2cConfig, 1'u32 shl I2cMasterEn)
    # Mask all interrupts
    regSet(base + I2cIntSts, 0x3F'u32 shl I2cIntMaskOffset)
    if ai.slot >= 0:
      completeIsrSlot(ai.slot)
      ai.slot = -1

  # Clear handled interrupt flags
  regSet(base + I2cIntSts, (sts shl I2cIntClrOffset))

# Per-instance ISR handlers
proc i2c0Isr() {.cdecl.} = i2cIsrCommon(0)
proc i2c1Isr() {.cdecl.} = i2cIsrCommon(1)
proc i2c2Isr() {.cdecl.} = i2cIsrCommon(2)
proc i2c3Isr() {.cdecl.} = i2cIsrCommon(3)

const i2cIsrs: array[4, proc() {.cdecl.}] = [i2c0Isr, i2c1Isr, i2c2Isr, i2c3Isr]

const i2cIrqNums: array[4, uint32] = [
  IrqM0I2c0.uint32,
  IrqM0I2c1.uint32,
  IrqD0I2c2.uint32,
  IrqD0I2c3.uint32,
]

# =============================================================================
# Initialization
# =============================================================================

proc initAsyncI2c*(id: I2cId, speed: I2cSpeed, clkHz: uint32): AsyncI2c =
  ## Initialize an async I2C instance. Registers the ISR and enables interrupts.
  let idx = id.int
  let irqNum = i2cIrqNums[idx]

  result = AsyncI2c(
    i2c: initI2c(id, speed, clkHz),
    irqNum: irqNum,
    index: idx,
    slot: -1,
    error: i2cOk,
  )
  asyncI2cs[idx] = result

  # Register ISR
  registerTrapHandler(irqNum, i2cIsrs[idx])
  irqEnable(irqNum)
  irqSetLevel(irqNum, 1)

  # Enable machine external interrupt (mie bit 11)
  {.emit: """
  unsigned long mie;
  asm volatile("csrr %0, mie" : "=r"(mie));
  mie |= (1UL << 11);
  asm volatile("csrw mie, %0" :: "r"(mie));
  """.}

  # Unmask I2C interrupts: End, TxFifo, RxFifo, Nak, Arb
  # Clear mask bits [13:8] for bits 0-4
  # Unmask I2C interrupts: End, TxFifo, RxFifo, Nak, Arb
  regModify(result.i2c.base + I2cIntSts, 0x3F'u32 shl I2cIntMaskOffset, 0'u32)

# =============================================================================
# Internal: start an async transfer
# =============================================================================

proc startAsync(ai: AsyncI2c, address: uint8, isRead: bool, length: int,
                subAddr: uint32 = 0, subAddrLen: uint32 = 0,
                fut: CpsVoidFuture): bool =
  let base = ai.i2c.base

  # Clear FIFOs
  regSet(base + I2cFifoConfig0,
         (1'u32 shl I2cFifoTxClr) or (1'u32 shl I2cFifoRxClr))

  # Clear all interrupt flags
  regWrite(base + I2cIntSts,
           (0x3F'u32 shl I2cIntClrOffset))

  # Unmask interrupts
  let curIntSts = regRead(base + I2cIntSts)
  regWrite(base + I2cIntSts, curIntSts and not (0x3F'u32 shl I2cIntMaskOffset))

  # Re-enable interrupt (previous ISR may have left it pending/masked)
  irqClearPending(ai.irqNum)
  irqEnable(ai.irqNum)

  # Register ISR slot
  ai.slot = registerIsrFuture(fut)
  if ai.slot < 0:
    ai.error = i2cFifoError
    return false
  ai.error = i2cOk

  # Pre-load TX FIFO for writes (FIFO depth = 2)
  if not isRead:
    let preload = min(ai.txLen, 2)
    for i in 0 ..< preload:
      regWrite(base + I2cFifoWdata, ai.txData[i].uint32)
    ai.txPos = preload

  # Configure and start transfer
  var cfg = regRead(base + I2cConfig)
  cfg = (cfg and not I2cSlvAddrMask) or ((address.uint32 and 0x7F) shl I2cSlvAddrShift)
  if isRead:
    cfg = cfg or (1'u32 shl I2cPktDir)
  else:
    cfg = cfg and not (1'u32 shl I2cPktDir)
  let pktLen = if length > 0: (length - 1).uint32 else: 0'u32
  cfg = (cfg and not I2cPktLenMask) or ((pktLen and 0xFF) shl I2cPktLenShift)
  if subAddrLen > 0:
    cfg = cfg or (1'u32 shl I2cSubAddrEn)
    cfg = (cfg and not I2cSubAddrBcMask) or (((subAddrLen - 1) and 0x03) shl I2cSubAddrBcShift)
    regWrite(base + I2cSubAddr, subAddr)
  else:
    cfg = cfg and not (1'u32 shl I2cSubAddrEn)
  regWrite(base + I2cConfig, cfg)

  # Start transfer
  regSet(base + I2cConfig, 1'u32 shl I2cMasterEn)
  true

# =============================================================================
# Public async API — ptr-based core procs + template wrappers for openArray
# =============================================================================

proc writePtr*(ai: AsyncI2c, address: uint8,
               data: ptr UncheckedArray[uint8], len: int): CpsFuture[I2cError] =
  ai.txData = data
  ai.txLen = len
  ai.txPos = 0
  ai.rxData = nil
  ai.rxLen = 0
  ai.rxPos = 0
  let voidFut = newLocalCpsVoidFuture()
  let typedFut = newLocalCpsFuture[I2cError]()
  voidFut.addCallback proc() = complete(typedFut, ai.error)
  if not startAsync(ai, address, isRead = false, length = len, fut = voidFut):
    complete(typedFut, ai.error)
  typedFut

proc readPtr*(ai: AsyncI2c, address: uint8,
              buf: ptr UncheckedArray[uint8], len: int): CpsFuture[I2cError] =
  ai.txData = nil
  ai.txLen = 0
  ai.txPos = 0
  ai.rxData = buf
  ai.rxLen = len
  ai.rxPos = 0
  let voidFut = newLocalCpsVoidFuture()
  let typedFut = newLocalCpsFuture[I2cError]()
  voidFut.addCallback proc() = complete(typedFut, ai.error)
  if not startAsync(ai, address, isRead = true, length = len, fut = voidFut):
    complete(typedFut, ai.error)
  typedFut

proc writeRegPtr*(ai: AsyncI2c, address, regAddr: uint8,
                  data: ptr UncheckedArray[uint8], len: int): CpsFuture[I2cError] =
  ai.txData = data
  ai.txLen = len
  ai.txPos = 0
  ai.rxData = nil
  ai.rxLen = 0
  ai.rxPos = 0
  let voidFut = newLocalCpsVoidFuture()
  let typedFut = newLocalCpsFuture[I2cError]()
  voidFut.addCallback proc() = complete(typedFut, ai.error)
  if not startAsync(ai, address, isRead = false, length = len,
                    subAddr = regAddr.uint32, subAddrLen = 1, fut = voidFut):
    complete(typedFut, ai.error)
  typedFut

proc readRegPtr*(ai: AsyncI2c, address, regAddr: uint8,
                 buf: ptr UncheckedArray[uint8], len: int): CpsFuture[I2cError] =
  ai.txData = nil
  ai.txLen = 0
  ai.txPos = 0
  ai.rxData = buf
  ai.rxLen = len
  ai.rxPos = 0
  let voidFut = newLocalCpsVoidFuture()
  let typedFut = newLocalCpsFuture[I2cError]()
  voidFut.addCallback proc() = complete(typedFut, ai.error)
  if not startAsync(ai, address, isRead = true, length = len,
                    subAddr = regAddr.uint32, subAddrLen = 1, fut = voidFut):
    complete(typedFut, ai.error)
  typedFut

# Template wrappers for convenient openArray usage in CPS procs
template write*(ai: AsyncI2c, address: uint8,
                data: openArray[uint8]): CpsFuture[I2cError] =
  writePtr(ai, address, cast[ptr UncheckedArray[uint8]](unsafeAddr data[0]), data.len)

template read*(ai: AsyncI2c, address: uint8,
               buf: var openArray[uint8]): CpsFuture[I2cError] =
  readPtr(ai, address, cast[ptr UncheckedArray[uint8]](addr buf[0]), buf.len)

template writeReg*(ai: AsyncI2c, address, regAddr: uint8,
                   data: openArray[uint8]): CpsFuture[I2cError] =
  writeRegPtr(ai, address, regAddr,
              cast[ptr UncheckedArray[uint8]](unsafeAddr data[0]), data.len)

template readReg*(ai: AsyncI2c, address, regAddr: uint8,
                  buf: var openArray[uint8]): CpsFuture[I2cError] =
  readRegPtr(ai, address, regAddr,
             cast[ptr UncheckedArray[uint8]](addr buf[0]), buf.len)
