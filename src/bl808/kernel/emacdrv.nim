## EMAC DMA ring driver for the BL808 kernel.
##
## Manages TX/RX buffer descriptor rings and provides an async interface
## for sending and receiving Ethernet frames:
##
##   let drv = emacDriverInit([0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x01])
##   await drv.send(frameData)
##   let (buf, len) = drv.tryRecv()
##
## The driver integrates with the CPS scheduler via the ISR bridge
## for interrupt-driven operation, with a polling fallback for QEMU.

import ../emac, ../irq, ../core, ../mmio
import ./runtime, ./isrbridge

# =============================================================================
# Configuration
# =============================================================================

const
  NumTxBd* = 8
    ## Number of TX buffer descriptors.
  NumRxBd* = 8
    ## Number of RX buffer descriptors.
  MaxFrameLen* = 1518
    ## Maximum Ethernet frame size (MTU 1500 + 14 header + 4 CRC).

# =============================================================================
# Buffer descriptor ring
# =============================================================================

type
  BdRing = object
    ## Manages a circular ring of buffer descriptors at a fixed MMIO offset.
    base: uint          ## MMIO base address of first BD
    count: int          ## Number of BDs in the ring
    next: int           ## Index of next BD to use

proc initBdRing(base: uint, count: int): BdRing =
  BdRing(base: base, count: count, next: 0)

proc bdAddr(ring: BdRing, index: int): uint {.inline.} =
  ## MMIO address of BD `index` (each BD is 8 bytes).
  ring.base + (index * 8).uint

proc readStatus(ring: BdRing, index: int): uint32 {.inline.} =
  regRead(ring.bdAddr(index))

proc writeStatus(ring: BdRing, index: int, val: uint32) {.inline.} =
  regWrite(ring.bdAddr(index), val)

proc readAddress(ring: BdRing, index: int): uint32 {.inline.} =
  regRead(ring.bdAddr(index) + 4)

proc writeAddress(ring: BdRing, index: int, val: uint32) {.inline.} =
  regWrite(ring.bdAddr(index) + 4, val)

proc advance(ring: var BdRing) {.inline.} =
  ring.next = (ring.next + 1) mod ring.count

# =============================================================================
# Packet buffers
# =============================================================================

type
  PacketBuf = array[MaxFrameLen, uint8]

# Static packet buffer pools — avoids heap allocation in the hot path
var
  txBufs: array[NumTxBd, PacketBuf]
  rxBufs: array[NumRxBd, PacketBuf]

proc bufferPhysAddr(buf: var PacketBuf): uint32 =
  ## Convert a buffer's address to a physical (non-cached) DMA address.
  ## Cached 0x62xxx → non-cached 0x22xxx.
  let a = cast[uint](addr buf[0])
  if a >= 0x62000000'u:
    (a - 0x40000000'u).uint32
  else:
    a.uint32

# =============================================================================
# Driver state
# =============================================================================

type
  EmacDriver* = ref object
    txRing: BdRing
    rxRing: BdRing
    ## ISR bridge slots for async notification
    txSlot: int
    rxSlot: int
    txFuture: CpsVoidFuture
    rxFuture: CpsVoidFuture

var driver: EmacDriver

# =============================================================================
# Ring initialization
# =============================================================================

proc initTxRing(ring: var BdRing) =
  ## Set up TX buffer descriptors with pre-allocated buffers.
  for i in 0 ..< ring.count:
    var status = 0'u32
    if i == ring.count - 1:
      status = status or (1'u32 shl TxBdWrap)
    ring.writeStatus(i, status)
    ring.writeAddress(i, bufferPhysAddr(txBufs[i]))

proc initRxRing(ring: var BdRing) =
  ## Set up RX buffer descriptors with pre-allocated buffers, marked empty.
  for i in 0 ..< ring.count:
    var status = (1'u32 shl RxBdEmpty) or (1'u32 shl RxBdIrq)
    if i == ring.count - 1:
      status = status or (1'u32 shl RxBdWrap)
    ring.writeStatus(i, status)
    ring.writeAddress(i, bufferPhysAddr(rxBufs[i]))

# =============================================================================
# ISR handler
# =============================================================================

var emacIsrCount*: int = 0

proc emacIsr() {.cdecl.} =
  emacIsrCount += 1
  let status = emacReadInterruptStatus()
  if (status and (1'u32 shl EmacIntTxB)) != 0:
    emacClearInterrupt(EmacIntTxB)
    if driver != nil and driver.txSlot >= 0:
      completeIsrSlot(driver.txSlot)
      driver.txSlot = -1
  if (status and (1'u32 shl EmacIntRxB)) != 0:
    emacClearInterrupt(EmacIntRxB)
    if driver != nil and driver.rxSlot >= 0:
      completeIsrSlot(driver.rxSlot)
      driver.rxSlot = -1
  # Clear any remaining interrupt sources
  if status != 0:
    regWrite(EmacIntSrc, status)

# =============================================================================
# Initialization
# =============================================================================

proc emacDriverInit*(macAddr: array[6, uint8]): EmacDriver =
  ## Initialize the EMAC hardware and DMA descriptor rings.
  let txBdCount = NumTxBd.uint32
  result = EmacDriver(
    txRing: initBdRing(emacTxBdAddr(0), NumTxBd),
    rxRing: initBdRing(emacRxBdAddr(txBdCount, 0), NumRxBd),
    txSlot: -1,
    rxSlot: -1,
  )
  driver = result

  # Initialize EMAC hardware
  emacInit(macAddr)

  # Tell hardware how many TX BDs we have (RX BDs follow)
  regWrite(EmacTxBdNum, txBdCount)

  # Set up descriptor rings
  initTxRing(result.txRing)
  initRxRing(result.rxRing)

  # Register ISR
  registerTrapHandler(IrqM0Emac, emacIsr)
  when defined(bl808m0) or defined(bl808lp):
    irqEnable(IrqM0Emac)
    irqSetLevel(IrqM0Emac, 1)
    let mie = csrReadMie()
    csrWriteMie(mie or (1'u shl 11))

  # Enable TX and RX interrupts
  emacEnableInterrupt(EmacIntTxB)
  emacEnableInterrupt(EmacIntRxB)

  # Enable the EMAC
  emacEnableRx()
  emacEnableTx()

# =============================================================================
# Transmit
# =============================================================================

proc send*(drv: EmacDriver, data: openArray[uint8]): bool =
  ## Send an Ethernet frame synchronously.
  ## Returns false if no TX descriptor is available.
  let idx = drv.txRing.next
  let status = drv.txRing.readStatus(idx)

  # Check if BD is free (ready bit must be 0)
  if (status and (1'u32 shl TxBdReady)) != 0:
    return false

  # Copy frame data into the TX buffer
  let len = min(data.len, MaxFrameLen)
  for i in 0 ..< len:
    txBufs[idx][i] = data[i]

  # Build BD status: length + ready + irq + crc + pad + wrap
  var newStatus = (len.uint32 shl TxBdLenShift) or
                  (1'u32 shl TxBdReady) or
                  (1'u32 shl TxBdIrq) or
                  (1'u32 shl TxBdCrc) or
                  (1'u32 shl TxBdPad)
  if idx == drv.txRing.count - 1:
    newStatus = newStatus or (1'u32 shl TxBdWrap)

  core.fence()
  drv.txRing.writeStatus(idx, newStatus)
  drv.txRing.advance()
  true

proc sendAsync*(drv: EmacDriver, data: openArray[uint8]): CpsVoidFuture =
  ## Send an Ethernet frame asynchronously.
  ## Returns a future that completes when the TX descriptor is freed.
  if drv.send(data):
    let fut = newLocalCpsVoidFuture()
    drv.txSlot = registerIsrFuture(fut)
    if drv.txSlot < 0:
      return failedLocalVoidFuture(newException(IOError, "ISR bridge full"))
    drv.txFuture = fut
    fut
  else:
    failedLocalVoidFuture(newException(IOError, "EMAC: no TX descriptor"))

# =============================================================================
# Receive
# =============================================================================

type
  RecvResult* = object
    ## Result of a receive operation.
    buf*: ptr PacketBuf   ## Pointer to the buffer containing the frame
    len*: int             ## Length of the received frame

proc tryRecv*(drv: EmacDriver): RecvResult =
  ## Check if a frame has been received.
  ## Returns len=0 if no frame is available.
  let idx = drv.rxRing.next
  let status = drv.rxRing.readStatus(idx)

  # Check if BD has received data (empty bit must be 0)
  if (status and (1'u32 shl RxBdEmpty)) != 0:
    return RecvResult(buf: nil, len: 0)

  let frameLen = ((status and RxBdLenMask) shr RxBdLenShift).int
  result = RecvResult(buf: addr rxBufs[idx], len: frameLen)

proc recycleRxBd*(drv: EmacDriver) =
  ## Return the current RX BD to hardware after processing its data.
  let idx = drv.rxRing.next
  var status = (1'u32 shl RxBdEmpty) or (1'u32 shl RxBdIrq)
  if idx == drv.rxRing.count - 1:
    status = status or (1'u32 shl RxBdWrap)
  drv.rxRing.writeStatus(idx, status)
  drv.rxRing.advance()

proc recvAsync*(drv: EmacDriver): CpsVoidFuture =
  ## Return a future that completes when a frame is received.
  ## After await, call tryRecv() to get the data, then recycleRxBd().
  let rx = drv.tryRecv()
  if rx.len > 0:
    return completedLocalVoidFuture()
  let fut = newLocalCpsVoidFuture()
  drv.rxSlot = registerIsrFuture(fut)
  if drv.rxSlot < 0:
    return failedLocalVoidFuture(newException(IOError, "ISR bridge full"))
  drv.rxFuture = fut
  fut

# =============================================================================
# Polling fallback (for QEMU or when IRQ delivery is unreliable)
# =============================================================================

proc emacPoll*(drv: EmacDriver) =
  ## Check interrupt status and complete pending futures.
  ## Called from the scheduler poll hook.
  let status = emacReadInterruptStatus()
  if (status and (1'u32 shl EmacIntTxB)) != 0:
    emacClearInterrupt(EmacIntTxB)
    if drv.txSlot >= 0:
      let slot = drv.txSlot
      drv.txSlot = -1
      releaseIsrSlot(slot)
      # Complete in task context
      let fut = drv.txFuture
      drv.txFuture = nil
      if fut != nil and not fut.finished:
        complete(fut)
  if (status and (1'u32 shl EmacIntRxB)) != 0:
    emacClearInterrupt(EmacIntRxB)
    if drv.rxSlot >= 0:
      let slot = drv.rxSlot
      drv.rxSlot = -1
      releaseIsrSlot(slot)
      let fut = drv.rxFuture
      drv.rxFuture = nil
      if fut != nil and not fut.finished:
        complete(fut)
