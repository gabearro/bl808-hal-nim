## File-scoped swap storage on SD/FatFs.
##
## This module never formats and never writes raw sectors. It only creates or
## reuses a file with a BL808 swap magic header, then reads/writes fixed 4 KiB
## slots inside that file.

import ./fatfs

when defined(bl808kernel):
  import ./cps

const
  SdSwapMagic0* = 0x4253_5750'u32 # "BSWP"
  SdSwapMagic1* = 0x3030_3031'u32 # "0001"
  SdSwapHeaderBytes* = 4096'u32
  SdSwapPageBytes* = 4096'u32

type
  SdSwapStatus* = enum
    sdSwapOk
    sdSwapNotMounted
    sdSwapOpenFailed
    sdSwapCreateFailed
    sdSwapBadMagic
    sdSwapBadSlot
    sdSwapSeekFailed
    sdSwapReadFailed
    sdSwapWriteFailed
    sdSwapShortIo

  SdSwapFile* = object
    file*: Fil
    open*: bool
    slots*: uint32

proc put32(buf: var openArray[uint8], off: int, value: uint32) =
  buf[off + 0] = (value and 0xFF'u32).uint8
  buf[off + 1] = ((value shr 8) and 0xFF'u32).uint8
  buf[off + 2] = ((value shr 16) and 0xFF'u32).uint8
  buf[off + 3] = ((value shr 24) and 0xFF'u32).uint8

proc get32(buf: openArray[uint8], off: int): uint32 =
  buf[off + 0].uint32 or
    (buf[off + 1].uint32 shl 8) or
    (buf[off + 2].uint32 shl 16) or
    (buf[off + 3].uint32 shl 24)

proc slotOffset(slot: uint32): uint64 {.inline.} =
  SdSwapHeaderBytes.uint64 + slot.uint64 * SdSwapPageBytes.uint64

proc requiredSize(swap: SdSwapFile): uint64 {.inline.} =
  SdSwapHeaderBytes.uint64 + swap.slots.uint64 * SdSwapPageBytes.uint64

proc fSize(fp: ptr Fil): uint64 {.importc: "f_size", header: "ff.h".}

proc writeExact(fs: var SdFs, f: var Fil, data: openArray[uint8]): SdSwapStatus =
  let wrote = fs.write(f, data)
  if wrote < 0: sdSwapWriteFailed
  elif wrote != data.len: sdSwapShortIo
  else: sdSwapOk

proc readExact(fs: var SdFs, f: var Fil, buf: var openArray[uint8]): SdSwapStatus =
  let got = fs.read(f, buf)
  if got < 0: sdSwapReadFailed
  elif got != buf.len: sdSwapShortIo
  else: sdSwapOk

when defined(bl808kernel):
  proc writeExactPtr(f: ptr Fil, data: pointer, len: int): SdSwapStatus =
    var wrote: cuint
    let err = f_write(f, data, len.cuint, addr wrote)
    if err != frOk: sdSwapWriteFailed
    elif wrote.int != len: sdSwapShortIo
    else: sdSwapOk

  proc readExactPtr(f: ptr Fil, buf: pointer, len: int): SdSwapStatus =
    var got: cuint
    let err = f_read(f, buf, len.cuint, addr got)
    if err != frOk: sdSwapReadFailed
    elif got.int != len: sdSwapShortIo
    else: sdSwapOk

proc writeHeader(fs: var SdFs, swap: var SdSwapFile): SdSwapStatus =
  var header: array[512, uint8]
  put32(header, 0, SdSwapMagic0)
  put32(header, 4, SdSwapMagic1)
  put32(header, 8, SdSwapPageBytes)
  put32(header, 12, swap.slots)
  if fs.seek(swap.file, 0) != frOk:
    return sdSwapSeekFailed
  var off = 0'u32
  while off < SdSwapHeaderBytes:
    result = writeExact(fs, swap.file, header)
    if result != sdSwapOk:
      return
    for i in 0 ..< header.len:
      header[i] = 0
    off += header.len.uint32
  if fs.sync(swap.file) != frOk:
    return sdSwapWriteFailed

when defined(bl808kernel):
  proc writeHeaderAsync(fs: ptr SdFs, swap: ptr SdSwapFile):
      CpsFuture[SdSwapStatus] {.cps.} =
    var header: array[512, uint8]
    put32(header, 0, SdSwapMagic0)
    put32(header, 4, SdSwapMagic1)
    put32(header, 8, SdSwapPageBytes)
    put32(header, 12, swap[].slots)
    if f_lseek(addr swap[].file, 0) != frOk:
      return sdSwapSeekFailed
    await yieldNow()
    var off = 0'u32
    while off < SdSwapHeaderBytes:
      let writeStatus = writeExactPtr(addr swap[].file, addr header[0], header.len)
      if writeStatus != sdSwapOk:
        return writeStatus
      for i in 0 ..< header.len:
        header[i] = 0
      off += header.len.uint32
      await yieldNow()
    if f_sync(addr swap[].file) != frOk:
      return sdSwapWriteFailed
    await yieldNow()
    return sdSwapOk

proc validateHeader(fs: var SdFs, swap: var SdSwapFile): SdSwapStatus =
  var header: array[32, uint8]
  if fs.seek(swap.file, 0) != frOk:
    return sdSwapSeekFailed
  result = readExact(fs, swap.file, header)
  if result != sdSwapOk:
    return
  if get32(header, 0) != SdSwapMagic0 or get32(header, 4) != SdSwapMagic1 or
      get32(header, 8) != SdSwapPageBytes:
    return sdSwapBadMagic
  let fileSlots = get32(header, 12)
  if fileSlots < swap.slots:
    return sdSwapBadMagic
  swap.slots = fileSlots
  result = sdSwapOk

when defined(bl808kernel):
  proc validateHeaderAsync(fs: ptr SdFs, swap: ptr SdSwapFile):
      CpsFuture[SdSwapStatus] {.cps.} =
    var header: array[32, uint8]
    if f_lseek(addr swap[].file, 0) != frOk:
      return sdSwapSeekFailed
    await yieldNow()
    let readStatus = readExactPtr(addr swap[].file, addr header[0], header.len)
    await yieldNow()
    if readStatus != sdSwapOk:
      return readStatus
    if get32(header, 0) != SdSwapMagic0 or get32(header, 4) != SdSwapMagic1 or
        get32(header, 8) != SdSwapPageBytes:
      return sdSwapBadMagic
    let fileSlots = get32(header, 12)
    if fileSlots < swap[].slots:
      return sdSwapBadMagic
    swap[].slots = fileSlots
    return sdSwapOk

proc extendSwapFile(fs: var SdFs, swap: var SdSwapFile): SdSwapStatus =
  var zeros: array[512, uint8]
  let needed = requiredSize(swap)
  var current = fSize(addr swap.file)
  if current >= needed:
    return sdSwapOk
  if fs.seek(swap.file, current) != frOk:
    return sdSwapSeekFailed
  while current < needed:
    let remaining = needed - current
    let chunkLen =
      if remaining < zeros.len.uint64: remaining.int
      else: zeros.len
    result = writeExact(fs, swap.file, zeros.toOpenArray(0, chunkLen - 1))
    if result != sdSwapOk:
      return
    current += chunkLen.uint64
  if fs.sync(swap.file) != frOk:
    return sdSwapWriteFailed
  result = sdSwapOk

when defined(bl808kernel):
  proc extendSwapFileAsync(fs: ptr SdFs, swap: ptr SdSwapFile):
      CpsFuture[SdSwapStatus] {.cps.} =
    var zeros: array[512, uint8]
    let needed = requiredSize(swap[])
    var current = fSize(addr swap[].file)
    if current >= needed:
      return sdSwapOk
    if f_lseek(addr swap[].file, current) != frOk:
      return sdSwapSeekFailed
    await yieldNow()
    while current < needed:
      let remaining = needed - current
      let chunkLen =
        if remaining < zeros.len.uint64: remaining.int
        else: zeros.len
      let writeStatus = writeExactPtr(addr swap[].file, addr zeros[0], chunkLen)
      if writeStatus != sdSwapOk:
        return writeStatus
      current += chunkLen.uint64
      await yieldNow()
    if f_sync(addr swap[].file) != frOk:
      return sdSwapWriteFailed
    await yieldNow()
    return sdSwapOk

proc sdSwapOpenOrCreate*(fs: var SdFs, swap: var SdSwapFile, path: string,
                         slots: uint32): SdSwapStatus =
  ## Open a dedicated swap file or create it if absent.
  ##
  ## Existing non-swap files are rejected and left untouched.
  if not fs.mounted:
    return sdSwapNotMounted
  if slots == 0:
    return sdSwapBadSlot
  swap.open = false
  swap.slots = slots

  var openStatus = fs.open(swap.file, path, faRead or faWrite or faOpenExisting)
  if openStatus == frNoFile:
    openStatus = fs.open(swap.file, path, faRead or faWrite or faCreateNew)
    if openStatus != frOk:
      return sdSwapCreateFailed
    swap.open = true
    result = writeHeader(fs, swap)
    if result != sdSwapOk:
      discard fs.close(swap.file)
      swap.open = false
      return
    result = extendSwapFile(fs, swap)
    if result != sdSwapOk:
      discard fs.close(swap.file)
      swap.open = false
      return
    return sdSwapOk
  if openStatus != frOk:
    return sdSwapOpenFailed

  swap.open = true
  result = validateHeader(fs, swap)
  if result != sdSwapOk:
    discard fs.close(swap.file)
    swap.open = false
    return
  result = extendSwapFile(fs, swap)
  if result != sdSwapOk:
    discard fs.close(swap.file)
    swap.open = false
    return
  result = sdSwapOk

when defined(bl808kernel):
  proc sdSwapOpenOrCreateAsync*(fs: ptr SdFs, swap: ptr SdSwapFile,
                                path: string, slots: uint32):
      CpsFuture[SdSwapStatus] {.cps.} =
    if not fs[].mounted:
      return sdSwapNotMounted
    if slots == 0:
      return sdSwapBadSlot
    swap[].open = false
    swap[].slots = slots

    var openStatus = f_open(addr swap[].file, path.cstring, faRead or faWrite or faOpenExisting)
    await yieldNow()
    if openStatus == frNoFile:
      openStatus = f_open(addr swap[].file, path.cstring, faRead or faWrite or faCreateNew)
      await yieldNow()
      if openStatus != frOk:
        return sdSwapCreateFailed
      swap[].open = true
      let headerStatus = await writeHeaderAsync(fs, swap)
      if headerStatus != sdSwapOk:
        discard f_close(addr swap[].file)
        await yieldNow()
        swap[].open = false
        return headerStatus
      let extendStatus = await extendSwapFileAsync(fs, swap)
      if extendStatus != sdSwapOk:
        discard f_close(addr swap[].file)
        await yieldNow()
        swap[].open = false
        return extendStatus
      return sdSwapOk
    if openStatus != frOk:
      return sdSwapOpenFailed

    swap[].open = true
    let validateStatus = await validateHeaderAsync(fs, swap)
    if validateStatus != sdSwapOk:
      discard f_close(addr swap[].file)
      await yieldNow()
      swap[].open = false
      return validateStatus
    let extendStatus = await extendSwapFileAsync(fs, swap)
    if extendStatus != sdSwapOk:
      discard f_close(addr swap[].file)
      await yieldNow()
      swap[].open = false
      return extendStatus
    return sdSwapOk

proc sdSwapClose*(fs: var SdFs, swap: var SdSwapFile): SdSwapStatus =
  if not swap.open:
    return sdSwapOk
  if fs.close(swap.file) != frOk:
    return sdSwapWriteFailed
  swap.open = false
  result = sdSwapOk

when defined(bl808kernel):
  proc sdSwapCloseAsync*(fs: ptr SdFs, swap: ptr SdSwapFile):
      CpsFuture[SdSwapStatus] {.cps.} =
    if not swap[].open:
      return sdSwapOk
    if f_close(addr swap[].file) != frOk:
      return sdSwapWriteFailed
    await yieldNow()
    swap[].open = false
    return sdSwapOk

proc sdSwapReadPage*(fs: var SdFs, swap: var SdSwapFile, slot: uint32,
                     dst: ptr UncheckedArray[uint8]): SdSwapStatus =
  if not swap.open:
    return sdSwapOpenFailed
  if slot >= swap.slots:
    return sdSwapBadSlot
  if fs.seek(swap.file, slotOffset(slot)) != frOk:
    return sdSwapSeekFailed
  var off = 0'u32
  while off < SdSwapPageBytes:
    var chunk: array[512, uint8]
    result = readExact(fs, swap.file, chunk)
    if result != sdSwapOk:
      return
    for i in 0 ..< chunk.len:
      dst[(off + i.uint32).int] = chunk[i]
    off += chunk.len.uint32
  result = sdSwapOk

when defined(bl808kernel):
  proc sdSwapReadPageAsync*(fs: ptr SdFs, swap: ptr SdSwapFile, slot: uint32,
                            dst: ptr UncheckedArray[uint8]):
      CpsFuture[SdSwapStatus] {.cps.} =
    if not swap[].open:
      return sdSwapOpenFailed
    if slot >= swap[].slots:
      return sdSwapBadSlot
    if f_lseek(addr swap[].file, slotOffset(slot)) != frOk:
      return sdSwapSeekFailed
    await yieldNow()
    var off = 0'u32
    while off < SdSwapPageBytes:
      var chunk: array[512, uint8]
      let readStatus = readExactPtr(addr swap[].file, addr chunk[0], chunk.len)
      if readStatus != sdSwapOk:
        return readStatus
      for i in 0 ..< chunk.len:
        dst[(off + i.uint32).int] = chunk[i]
      off += chunk.len.uint32
      await yieldNow()
    return sdSwapOk

proc sdSwapWritePage*(fs: var SdFs, swap: var SdSwapFile, slot: uint32,
                      src: ptr UncheckedArray[uint8]): SdSwapStatus =
  if not swap.open:
    return sdSwapOpenFailed
  if slot >= swap.slots:
    return sdSwapBadSlot
  if fs.seek(swap.file, slotOffset(slot)) != frOk:
    return sdSwapSeekFailed
  var off = 0'u32
  while off < SdSwapPageBytes:
    var chunk: array[512, uint8]
    for i in 0 ..< chunk.len:
      chunk[i] = src[(off + i.uint32).int]
    result = writeExact(fs, swap.file, chunk)
    if result != sdSwapOk:
      return
    off += chunk.len.uint32
  if fs.sync(swap.file) != frOk:
    return sdSwapWriteFailed
  result = sdSwapOk

when defined(bl808kernel):
  proc sdSwapWritePageAsync*(fs: ptr SdFs, swap: ptr SdSwapFile, slot: uint32,
                             src: ptr UncheckedArray[uint8]):
      CpsFuture[SdSwapStatus] {.cps.} =
    if not swap[].open:
      return sdSwapOpenFailed
    if slot >= swap[].slots:
      return sdSwapBadSlot
    if f_lseek(addr swap[].file, slotOffset(slot)) != frOk:
      return sdSwapSeekFailed
    await yieldNow()
    var off = 0'u32
    while off < SdSwapPageBytes:
      var chunk: array[512, uint8]
      for i in 0 ..< chunk.len:
        chunk[i] = src[(off + i.uint32).int]
      let writeStatus = writeExactPtr(addr swap[].file, addr chunk[0], chunk.len)
      if writeStatus != sdSwapOk:
        return writeStatus
      off += chunk.len.uint32
      await yieldNow()
    if f_sync(addr swap[].file) != frOk:
      return sdSwapWriteFailed
    await yieldNow()
    return sdSwapOk
