## Managed DMA transfers for memory-mapped peripheral FIFOs.

import core, dma, dmablock, mmio

type
  DmaFifoDirection* = enum dmaFifoRead, dmaFifoWrite

  DmaFifoEndpoint* = object
    controller*: DmaId
    request*: uint32
    address*, enableRegister*: uint
    enableMask*: uint32
    width*: DmaWidth
    direction*: DmaFifoDirection

  DmaFifoTransfer* = object
    endpoint: DmaFifoEndpoint
    transfer: DmaBlock
    receive: DmaReceiveBuffer
    prepared, started: bool

proc prepare*(fifo: var DmaFifoTransfer; endpoint: DmaFifoEndpoint;
              data: pointer; len: int; pad = false): bool =
  ## len is in bytes. Pad only for a peripheral whose packet length controls
  ## the number of valid bytes in the final FIFO entry.
  let width = 1 shl endpoint.width.ord
  let address = cast[uint](data)
  if fifo.prepared or not dmaBufferInRam(address, len) or
      (not pad and ((address or len.uint) and (width - 1).uint) != 0):
    return false
  when defined(bl808m0) or defined(bl808d0) or defined(bl808lp):
    if endpoint.controller != CoreDmaId: return false
  else:
    return false
  if (regRead(endpoint.enableRegister) and endpoint.enableMask) != 0: return false

  let paddedLen = ((len - 1) div width + 1) * width
  var config = DmaTransferConfig(transferSize: uint32(paddedLen div width),
    srcWidth: endpoint.width, dstWidth: endpoint.width)
  if endpoint.direction == dmaFifoRead:
    fifo.receive.prepare(data, len, alignment = width.uint, dmaSize = paddedLen)
    config.srcAddr = endpoint.address.uint32
    config.dstAddr = fifo.receive.address.uint32
    config.srcPeriph = endpoint.request
    config.dstIncrement = true
    config.flow = flowP2M_Dma
  else:
    if paddedLen != len or (address and (width - 1).uint) != 0: return false
    dcacheCleanRange(address, len.uint)
    config.srcAddr = address.uint32
    config.dstAddr = endpoint.address.uint32
    config.dstPeriph = endpoint.request
    config.srcIncrement = true
    config.flow = flowM2P_Dma
  if not fifo.transfer.prepare(openCoreDma(), config):
    fifo.receive.finish(false)
    return false
  fifo.endpoint = endpoint
  fifo.prepared = true
  true

proc start*(fifo: var DmaFifoTransfer): bool =
  ## A request can feed only one DMA channel. Claim its enable bit and
  ## start the channel together.
  if not fifo.prepared or fifo.started: return false
  withInterruptsDisabled:
    let ep = fifo.endpoint
    if (regRead(ep.enableRegister) and ep.enableMask) == 0:
      regSet(ep.enableRegister, ep.enableMask)
      fifo.transfer.start()
      fifo.started = true
  fifo.started

proc status*(fifo: DmaFifoTransfer): DmaBlockStatus =
  fifo.transfer.status()

proc release*(fifo: var DmaFifoTransfer; success = false) =
  if not fifo.prepared: return
  withInterruptsDisabled:
    if fifo.started:
      regClear(fifo.endpoint.enableRegister, fifo.endpoint.enableMask)
    fifo.transfer.release()
  fifo.receive.finish(success)
  fifo.prepared = false
  fifo.started = false
