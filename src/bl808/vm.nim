## D0 virtual memory manager built on the Sv39 MMU pager.
##
## This is intentionally small and deterministic: fixed mapping table, fixed
## frame pool, and callback-backed page fill. SD/exFAT or swap code can provide
## a reader callback without pulling filesystem code into the S-mode trap path.

when not defined(bl808d0):
  {.error: "bl808/vm is currently supported only on D0 (C906)".}

import ./mmu

const
  D0VmMaxMappings* {.intdefine.} = 16
  D0VmFrameCount* {.intdefine.} = 2

type
  D0VmStatus* = enum
    d0VmOk
    d0VmBadAddress
    d0VmNoMapping
    d0VmNoFrame
    d0VmReaderFailed
    d0VmSwapUnavailable
    d0VmSwapFull
    d0VmSwapReadFailed
    d0VmSwapWriteFailed
    d0VmFull

  D0VmSourceKind* = enum
    d0VmAnonymous
    d0VmReaderBacked

  D0VmReader* = proc(ctx: pointer, offset: uint64, dst: ptr UncheckedArray[byte],
                     len: uint): bool {.nimcall, raises: [].}
  D0VmSwapReadPage* = proc(ctx: pointer, slot: uint32,
                           dst: ptr UncheckedArray[byte]): bool {.nimcall, raises: [].}
  D0VmSwapWritePage* = proc(ctx: pointer, slot: uint32,
                            src: ptr UncheckedArray[byte]): bool {.nimcall, raises: [].}

  D0VmSwapProvider* = object
    ctx*: pointer
    slots*: uint32
    readPage*: D0VmSwapReadPage
    writePage*: D0VmSwapWritePage

  D0VmMapping* = object
    valid*: bool
    virtualBase*: uint
    length*: uint
    flags*: uint64
    sourceKind*: D0VmSourceKind
    sourceOffset*: uint64
    reader*: D0VmReader
    readerCtx*: pointer

  D0VmStats* = object
    faults*: uint32
    mappedPages*: uint32
    unmappedPages*: uint32
    evictions*: uint32
    swapIns*: uint32
    swapOuts*: uint32
    dirtyPages*: uint32
    readerPages*: uint32
    anonymousPages*: uint32
    failedFaults*: uint32
    lastStatus*: D0VmStatus
    lastAddress*: uint

var
  vmMappings: array[D0VmMaxMappings, D0VmMapping]
  vmFrames {.align: 4096.}: array[D0VmFrameCount, array[PageSize.int, byte]]
  vmFrameUsed: array[D0VmFrameCount, bool]
  vmFrameVa: array[D0VmFrameCount, uint]
  vmFrameDirty: array[D0VmFrameCount, bool]
  vmPageVa: array[D0VmMaxMappings * 8, uint]
  vmPageSwapSlot: array[D0VmMaxMappings * 8, uint32]
  vmPageHasSwap: array[D0VmMaxMappings * 8, bool]
  vmSwapSlotUsed: array[D0VmFrameCount * 4, bool]
  vmNextVictim: uint32
  vmSwap: D0VmSwapProvider
  vmStats: D0VmStats

const
  NoSwapSlot = high(uint32)

proc clearPage(frame: ptr UncheckedArray[byte]) =
  for i in 0 ..< PageSize.int:
    frame[i] = 0

proc copyReaderTailZero(frame: ptr UncheckedArray[byte], firstZero: uint) =
  var i = firstZero
  while i < PageSize:
    frame[i.int] = 0
    inc i

proc contains(mapping: D0VmMapping, virtualAddress: uint): bool {.inline.} =
  mapping.valid and virtualAddress >= mapping.virtualBase and
    virtualAddress < mapping.virtualBase + mapping.length

proc allocFrame(): ptr UncheckedArray[byte] =
  for i in 0 ..< D0VmFrameCount:
    if not vmFrameUsed[i]:
      vmFrameUsed[i] = true
      vmFrameVa[i] = 0
      vmFrameDirty[i] = false
      return cast[ptr UncheckedArray[byte]](addr vmFrames[i][0])
  nil

proc framePtr(index: int): ptr UncheckedArray[byte] {.inline.} =
  cast[ptr UncheckedArray[byte]](addr vmFrames[index][0])

proc frameIndexForVa(pageVa: uint): int =
  for i in 0 ..< D0VmFrameCount:
    if vmFrameUsed[i] and vmFrameVa[i] == pageVa:
      return i
  -1

proc swapSlotForPage(pageVa: uint): uint32 =
  for i in 0 ..< vmPageVa.len:
    if vmPageHasSwap[i] and vmPageVa[i] == pageVa:
      return vmPageSwapSlot[i]
  NoSwapSlot

proc rememberSwapSlot(pageVa: uint, slot: uint32) =
  for i in 0 ..< vmPageVa.len:
    if vmPageHasSwap[i] and vmPageVa[i] == pageVa:
      vmPageSwapSlot[i] = slot
      return
  for i in 0 ..< vmPageVa.len:
    if not vmPageHasSwap[i]:
      vmPageHasSwap[i] = true
      vmPageVa[i] = pageVa
      vmPageSwapSlot[i] = slot
      return

proc allocSwapSlot(): uint32 =
  if vmSwap.slots == 0:
    return NoSwapSlot
  let limit =
    if vmSwap.slots < vmSwapSlotUsed.len.uint32: vmSwap.slots
    else: vmSwapSlotUsed.len.uint32
  for i in 0'u32 ..< limit:
    if not vmSwapSlotUsed[i.int]:
      vmSwapSlotUsed[i.int] = true
      return i
  NoSwapSlot

proc evictFrame(): ptr UncheckedArray[byte] =
  if vmSwap.writePage == nil or vmSwap.slots == 0:
    return nil
  for attempt in 0 ..< D0VmFrameCount:
    let idx = int((vmNextVictim + attempt.uint32) mod D0VmFrameCount.uint32)
    if not vmFrameUsed[idx]:
      continue
    var slot = swapSlotForPage(vmFrameVa[idx])
    if vmFrameDirty[idx]:
      if slot == NoSwapSlot:
        slot = allocSwapSlot()
        if slot == NoSwapSlot:
          vmStats.lastStatus = d0VmSwapFull
          return nil
      if not vmSwap.writePage(vmSwap.ctx, slot, framePtr(idx)):
        vmStats.lastStatus = d0VmSwapWriteFailed
        return nil
      rememberSwapSlot(vmFrameVa[idx], slot)
      inc vmStats.swapOuts
    unmapPage(vmFrameVa[idx])
    inc vmStats.unmappedPages
    inc vmStats.evictions
    vmFrameUsed[idx] = true
    vmFrameVa[idx] = 0
    vmFrameDirty[idx] = false
    vmNextVictim = (idx.uint32 + 1'u32) mod D0VmFrameCount.uint32
    return framePtr(idx)
  nil

proc allocOrEvictFrame(): ptr UncheckedArray[byte] =
  result = allocFrame()
  if result == nil:
    result = evictFrame()

proc reserveMapping(virtualBase, length: uint, sourceKind: D0VmSourceKind,
                    flags: uint64, reader: D0VmReader,
                    readerCtx: pointer, sourceOffset: uint64): D0VmStatus =
  if not isPageAligned(virtualBase) or length == 0:
    return d0VmBadAddress
  let roundedLength = (length + PageMask) and not PageMask
  for i in 0 ..< vmMappings.len:
    if not vmMappings[i].valid:
      vmMappings[i] = D0VmMapping(
        valid: true,
        virtualBase: virtualBase,
        length: roundedLength,
        flags: flags,
        sourceKind: sourceKind,
        sourceOffset: sourceOffset,
        reader: reader,
        readerCtx: readerCtx,
      )
      return d0VmOk
  d0VmFull

proc findMapping(virtualAddress: uint): ptr D0VmMapping =
  for i in 0 ..< vmMappings.len:
    if vmMappings[i].contains(virtualAddress):
      return addr vmMappings[i]
  nil

proc d0VmMarkDirty*(virtualAddress: uint) {.raises: [].}

proc mapFaultPage(mapping: ptr D0VmMapping, faultAddress: uint): D0VmStatus =
  let pageVa = alignDown(faultAddress, PageSize)
  let existing = frameIndexForVa(pageVa)
  if existing >= 0:
    return d0VmOk
  let frame = allocOrEvictFrame()
  if frame == nil:
    if vmSwap.writePage == nil: return d0VmNoFrame
    return vmStats.lastStatus

  let swapSlot = swapSlotForPage(pageVa)
  let pageOffset = pageVa - mapping.virtualBase
  var frameIdx = -1
  for i in 0 ..< D0VmFrameCount:
    if framePtr(i) == frame:
      frameIdx = i
      break
  if frameIdx < 0:
    return d0VmNoFrame

  if swapSlot != NoSwapSlot:
    if vmSwap.readPage == nil:
      return d0VmSwapUnavailable
    if not vmSwap.readPage(vmSwap.ctx, swapSlot, frame):
      return d0VmSwapReadFailed
    inc vmStats.swapIns
  else:
    case mapping.sourceKind
    of d0VmAnonymous:
      clearPage(frame)
      inc vmStats.anonymousPages
    of d0VmReaderBacked:
      if mapping.reader == nil:
        return d0VmReaderFailed
      let remaining = mapping.length - pageOffset
      let bytesToRead = if remaining < PageSize: remaining else: PageSize
      if not mapping.reader(mapping.readerCtx, mapping.sourceOffset + pageOffset.uint64,
                            frame, bytesToRead):
        return d0VmReaderFailed
      copyReaderTailZero(frame, bytesToRead)
      inc vmStats.readerPages

  if not mapPage(pageVa, physicalAddressForTestPage(frame), mapping.flags):
    return d0VmBadAddress
  vmFrameVa[frameIdx] = pageVa
  vmFrameDirty[frameIdx] = false
  inc vmStats.mappedPages
  d0VmOk

proc vmFaultHandler(fault: D0PageFault): bool {.raises: [].} =
  if fault.kind != d0PageFaultLoad and fault.kind != d0PageFaultStore and
      fault.kind != d0PageFaultInstruction:
    return false
  inc vmStats.faults
  vmStats.lastAddress = fault.address
  let mapping = findMapping(fault.address)
  if mapping == nil:
    vmStats.lastStatus = d0VmNoMapping
    inc vmStats.failedFaults
    return false
  let status = mapFaultPage(mapping, fault.address)
  vmStats.lastStatus = status
  if status != d0VmOk:
    inc vmStats.failedFaults
    return false
  if fault.kind == d0PageFaultStore:
    d0VmMarkDirty(fault.address)
  true

proc d0VmMarkDirty*(virtualAddress: uint) {.raises: [].} =
  let idx = frameIndexForVa(alignDown(virtualAddress, PageSize))
  if idx >= 0 and not vmFrameDirty[idx]:
    vmFrameDirty[idx] = true
    inc vmStats.dirtyPages

proc d0VmInit*() =
  for i in 0 ..< vmMappings.len:
    vmMappings[i].valid = false
  for i in 0 ..< vmFrameUsed.len:
    vmFrameUsed[i] = false
    vmFrameVa[i] = 0
    vmFrameDirty[i] = false
  for i in 0 ..< vmPageVa.len:
    vmPageVa[i] = 0
    vmPageSwapSlot[i] = NoSwapSlot
    vmPageHasSwap[i] = false
  for i in 0 ..< vmSwapSlotUsed.len:
    vmSwapSlotUsed[i] = false
  vmNextVictim = 0
  vmStats.faults = 0
  vmStats.mappedPages = 0
  vmStats.unmappedPages = 0
  vmStats.evictions = 0
  vmStats.swapIns = 0
  vmStats.swapOuts = 0
  vmStats.dirtyPages = 0
  vmStats.readerPages = 0
  vmStats.anonymousPages = 0
  vmStats.failedFaults = 0
  vmStats.lastStatus = d0VmOk
  vmStats.lastAddress = 0
  d0PagerStatsClear()
  setD0PageFaultHandler(vmFaultHandler)

proc d0VmSetSwapProvider*(provider: D0VmSwapProvider) =
  vmSwap = provider
  for i in 0 ..< vmSwapSlotUsed.len:
    vmSwapSlotUsed[i] = false

proc d0VmReserveAnonymous*(virtualBase, length: uint,
                           flags: uint64 = PteKernelPage): D0VmStatus =
  reserveMapping(virtualBase, length, d0VmAnonymous, flags, nil, nil, 0)

proc d0VmReserveReaderBacked*(virtualBase, length: uint, reader: D0VmReader,
                              readerCtx: pointer = nil,
                              sourceOffset: uint64 = 0,
                              flags: uint64 = PteKernelPage): D0VmStatus =
  reserveMapping(virtualBase, length, d0VmReaderBacked, flags, reader,
                 readerCtx, sourceOffset)

proc d0VmStatsSnapshot*(): D0VmStats =
  result.faults = vmStats.faults
  result.mappedPages = vmStats.mappedPages
  result.unmappedPages = vmStats.unmappedPages
  result.evictions = vmStats.evictions
  result.swapIns = vmStats.swapIns
  result.swapOuts = vmStats.swapOuts
  result.dirtyPages = vmStats.dirtyPages
  result.readerPages = vmStats.readerPages
  result.anonymousPages = vmStats.anonymousPages
  result.failedFaults = vmStats.failedFaults
  result.lastStatus = vmStats.lastStatus
  result.lastAddress = vmStats.lastAddress

proc d0VmMappedPages*(): uint32 {.inline.} =
  vmStats.mappedPages

proc d0VmReaderPages*(): uint32 {.inline.} =
  vmStats.readerPages

proc d0VmAnonymousPages*(): uint32 {.inline.} =
  vmStats.anonymousPages

proc d0VmFailedFaults*(): uint32 {.inline.} =
  vmStats.failedFaults

proc d0VmEvictions*(): uint32 {.inline.} =
  vmStats.evictions

proc d0VmSwapIns*(): uint32 {.inline.} =
  vmStats.swapIns

proc d0VmSwapOuts*(): uint32 {.inline.} =
  vmStats.swapOuts
