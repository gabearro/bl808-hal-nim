## Channel ownership and linked transfers for bulk peripheral and memory I/O.

import core, dma, memmap
when defined(bl808d0) or defined(bl808lp):
  import mmio
when not defined(bl808d0):
  import glb

type
  DmaBlockStatus* = enum
    dmaBlockIdle, dmaBlockRunning, dmaBlockDone, dmaBlockError

  DmaBlock* = object
    ## Keep this object and its buffers alive until release. A prepared
    ## transfer owns its channel and must stay in place.
    controller: Dma
    channel: DmaChannel
    acquired: bool
    started: bool
    descriptors: seq[DmaLli]
    when defined(bl808lp):
      requestMask, savedRoutes: uint32

  DmaReceiveBuffer* = object
    data: pointer
    size: int
    busSize: int
    address*: uint
    storage: seq[byte]

const MaxDescriptorTransfers = CtrlTransferSizeMask
when defined(bl808lp):
  const McuDmaRoutes = GlbBase + 0x138'u


const CoreDmaId* =
  when defined(bl808d0): dma2
  elif defined(bl808lp): dma1
  else: dma0

proc openCoreDma*(): Dma =
  ## Each core manages its own controller and channel reservations.
  when defined(bl808d0):
    const MmDmaClockControl = MmMiscBase + 0x40'u
    regSet(MmDmaClockControl, 0xFF'u32)
  elif defined(bl808lp):
    enableDma1Clock()
  else:
    enableDma0Clock()
  openDma(CoreDmaId)

func inRange(address, size, base, capacity: uint): bool =
  address >= base and size <= capacity and address - base <= capacity - size

func dmaBufferInRam*(address: uint; len: int): bool =
  ## Check whether the DMA controller can access the full buffer directly.
  if len <= 0: return false
  let size = len.uint
  inRange(address, size, OcramBase, OcramSize + WramSize) or
    inRange(address, size, OcramCachedBase, OcramSize + WramSize) or
    inRange(address, size, DramBase, DramSize + VramSize) or
    inRange(address, size, DramCachedBase, DramSize + VramSize) or
    inRange(address, size, PsramBase, PsramSize) or
    inRange(address, size, XramBase, XramSize)

proc prepare*(buffer: var DmaReceiveBuffer; data: pointer; len: int;
              stage = false; alignment = 1'u; dmaSize = 0) =
  ## Unaligned data may share cache lines with live CPU state. Stage it in
  ## private cache lines, then copy it back after transfer completion.
  let line = max(alignment, dcacheLineSize())
  buffer.data = data
  buffer.size = len
  buffer.busSize = max(len, dmaSize)
  buffer.address = cast[uint](data)
  if stage or len != buffer.busSize or ((buffer.address or len.uint) and (line - 1)) != 0:
    let rounded = (buffer.busSize.uint + line - 1) and not (line - 1)
    buffer.storage.setLen(int(rounded + line - 1))
    let address = cast[uint](addr buffer.storage[0])
    buffer.address = (address + line - 1) and not (line - 1)
  dcacheCleanInvalidateRange(buffer.address, buffer.busSize.uint)

proc finish*(buffer: var DmaReceiveBuffer; success: bool; bytesReceived = -1) =
  if buffer.size == 0: return
  dcacheInvalidateRange(buffer.address, buffer.busSize.uint)
  if success and buffer.address != cast[uint](buffer.data):
    let count = if bytesReceived < 0: buffer.size else: min(buffer.size, bytesReceived)
    copyMem(buffer.data, cast[pointer](buffer.address), count)
  buffer.size = 0
  buffer.data = nil

proc prepare*(transfer: var DmaBlock; controller: Dma;
              cfg: DmaTransferConfig; channel = -1): bool =
  ## Reserve a channel and program its descriptors. The caller controls the
  ## peripheral request and the cache state of the data buffers.
  if transfer.acquired or cfg.transferSize == 0: return false
  let srcStride = if cfg.srcIncrement: 1'u32 shl cfg.srcWidth.ord else: 0'u32
  let dstStride = if cfg.dstIncrement: 1'u32 shl cfg.dstWidth.ord else: 0'u32
  let last = cfg.transferSize.uint64 - 1
  if cfg.srcAddr.uint64 + last * srcStride.uint64 > high(uint32).uint64 or
      cfg.dstAddr.uint64 + last * dstStride.uint64 > high(uint32).uint64:
    return false

  let slot = controller.reserveChannel(channel)
  if slot < 0: return false
  transfer.controller = controller
  transfer.channel = DmaChannel(slot)
  transfer.acquired = true

  when defined(bl808lp):
    transfer.requestMask = 0
    if controller.controllerId() == dma1:
      if cfg.flow in {flowP2M_Dma, flowP2M_PeriCtrl, flowP2P_Dma,
                      flowP2P_DstCtrl, flowP2P_SrcCtrl}:
        transfer.requestMask = 1'u32 shl (cfg.srcPeriph and 31)
      if cfg.flow in {flowM2P_Dma, flowM2P_PeriCtrl, flowP2P_Dma,
                      flowP2P_DstCtrl, flowP2P_SrcCtrl}:
        transfer.requestMask = transfer.requestMask or (1'u32 shl (cfg.dstPeriph and 31))

  var config = cfg
  config.enableTcInt = false
  controller.clearTcInterrupt(transfer.channel)
  controller.clearErrInterrupt(transfer.channel)
  if cfg.transferSize <= MaxDescriptorTransfers:
    controller.configureChannel(transfer.channel, config)
    return true

  let count = int((cfg.transferSize - 1) div MaxDescriptorTransfers + 1)
  transfer.descriptors.setLen(count)
  var offset = 0'u32
  for i in 0 ..< count:
    let size = min(MaxDescriptorTransfers, cfg.transferSize - offset)
    let next = if i + 1 < count: cast[uint32](addr transfer.descriptors[i + 1]) else: 0'u32
    transfer.descriptors[i] = buildLli(cfg.srcAddr + offset * srcStride,
      cfg.dstAddr + offset * dstStride, size, cfg.srcWidth, cfg.dstWidth,
      cfg.srcIncrement, cfg.dstIncrement, next, false, cfg.srcBurst, cfg.dstBurst)
    offset += size
  dcacheCleanRange(cast[uint](addr transfer.descriptors[0]), (count * sizeof(DmaLli)).uint)
  controller.configureChannelLli(transfer.channel, addr transfer.descriptors[0], config)
  true

proc start*(transfer: var DmaBlock) =
  doAssert transfer.acquired and not transfer.started
  when defined(bl808lp):
    # Each MCU request is wired to DMA0 or DMA1. The caller owns the MCU
    # peripheral for the duration of the transfer.
    if transfer.requestMask != 0:
      withInterruptsDisabled:
        let routes = regRead(McuDmaRoutes)
        transfer.savedRoutes = routes and transfer.requestMask
        regWrite(McuDmaRoutes, routes or transfer.requestMask)
  transfer.started = true
  transfer.controller.startChannel(transfer.channel)

proc status*(transfer: DmaBlock): DmaBlockStatus =
  if not transfer.started: return dmaBlockIdle
  let enabled = transfer.controller.channelEnabled(transfer.channel)
  if transfer.controller.rawErrInterruptPending(transfer.channel): return dmaBlockError
  if enabled: return dmaBlockRunning
  dmaBlockDone

proc destinationAddress*(transfer: DmaBlock): uint =
  ## The DMA bus address where the next receive beat will be written.
  transfer.controller.channelDstAddr(transfer.channel).uint

proc release*(transfer: var DmaBlock; nextDestination: ptr uint = nil) =
  if not transfer.acquired: return
  let controller = transfer.controller
  let channel = transfer.channel
  if transfer.started:
    controller.stopChannel(channel)
    if nextDestination != nil:
      nextDestination[] = controller.channelDstAddr(channel).uint
    when defined(bl808lp):
      if transfer.requestMask != 0:
        withInterruptsDisabled:
          regModify(McuDmaRoutes, transfer.requestMask, transfer.savedRoutes)
  controller.clearTcInterrupt(channel)
  controller.clearErrInterrupt(channel)
  controller.releaseChannel(channel)
  transfer.started = false
  transfer.acquired = false
