## Flash-resident WebAssembly program slots.
##
## A slot contains a small fixed header followed by raw .wasm bytes. Loading a
## slot creates a FlashWasmModule view over the payload; unloading drops that
## view and leaves flash ownership to the writer/filesystem/HTTP layer.

import ./flash
import ./memmap
import cps/wasm/flash_image

when defined(bl808m0) or defined(bl808d0) or defined(bl808lp):
  import ./cache

when defined(bl808m0):
  import ./tzc

const
  WasmProgramMagic* = 0x4D53_4157'u32 # "WASM", little-endian
  WasmProgramVersion* = 1'u16
  WasmProgramHeaderLen* = 24'u32
  WasmProgramPayloadOffset* = WasmProgramHeaderLen

type
  WasmProgramChunkReader* = proc(dst: var openArray[byte]): int

  WasmProgramError* = enum
    wasmProgramOk
    wasmProgramBadSlot
    wasmProgramBadHeader
    wasmProgramTooLarge
    wasmProgramParseFailed
    wasmProgramFlashError
    wasmProgramVerifyFailed
    wasmProgramChecksumMismatch

  WasmProgramSlotState* = enum
    wasmSlotEmpty
    wasmSlotInvalid
    wasmSlotPresent

  WasmProgramSlot* = object
    index*: uint32
    flashOffset*: uint32
    slotSize*: uint32

  WasmProgramHeader* = object
    magic*: uint32
    version*: uint16
    headerLen*: uint16
    imageLen*: uint32
    flags*: uint32
    generation*: uint32
    reserved*: uint32 # CRC32 of the raw .wasm payload; 0 means unchecked.

  WasmProgramSlotInfo* = object
    slot*: WasmProgramSlot
    state*: WasmProgramSlotState
    header*: WasmProgramHeader
    validation*: WasmProgramError

  LoadedWasmProgram* = object
    loaded*: bool
    slot*: WasmProgramSlot
    header*: WasmProgramHeader
    module*: FlashWasmModule

proc initWasmProgramStore*() =
  ## Prepare the local core to update WASM program slots.
  ##
  ## M0 normally executes from SPI flash XIP, so writes go through the SF_CTRL
  ## command path. Grant M0 access to that controller before attempting erase or
  ## program operations. Other cores do not own the store writer yet.
  when defined(bl808m0):
    tzcSetMasterGroup(tzcMasterM0, 0)
    tzcSetSfCtrlGroup(tzcSfCr, 0)

proc readU16(p: ptr UncheckedArray[byte], offset: uint32): uint16 {.inline.} =
  uint16(p[offset.int]) or (uint16(p[offset.int + 1]) shl 8)

proc readU32(p: ptr UncheckedArray[byte], offset: uint32): uint32 {.inline.} =
  uint32(p[offset.int]) or
    (uint32(p[offset.int + 1]) shl 8) or
    (uint32(p[offset.int + 2]) shl 16) or
    (uint32(p[offset.int + 3]) shl 24)

proc writeU16*(p: ptr UncheckedArray[byte], offset: uint32, value: uint16) {.inline.} =
  p[offset.int] = byte(value and 0xFF)
  p[offset.int + 1] = byte((value shr 8) and 0xFF)

proc writeU32*(p: ptr UncheckedArray[byte], offset: uint32, value: uint32) {.inline.} =
  p[offset.int] = byte(value and 0xFF)
  p[offset.int + 1] = byte((value shr 8) and 0xFF)
  p[offset.int + 2] = byte((value shr 16) and 0xFF)
  p[offset.int + 3] = byte((value shr 24) and 0xFF)

proc crc32Step(crc: uint32, b: byte): uint32 {.inline.} =
  result = crc xor uint32(b)
  for _ in 0 ..< 8:
    if (result and 1'u32) != 0:
      result = (result shr 1) xor 0xEDB8_8320'u32
    else:
      result = result shr 1

proc wasmPayloadCrc32Init*(): uint32 {.inline.} =
  0xFFFF_FFFF'u32

proc wasmPayloadCrc32Update*(crc: uint32, data: openArray[byte]): uint32 =
  result = crc
  for b in data:
    result = crc32Step(result, b)

proc wasmPayloadCrc32Finish*(crc: uint32): uint32 {.inline.} =
  not crc

proc wasmPayloadCrc32*(payload: ptr UncheckedArray[byte], len: uint32): uint32 =
  ## IEEE CRC32 over a flash/RAM-backed payload.
  if payload == nil or len == 0:
    return 0
  var crc = wasmPayloadCrc32Init()
  for i in 0'u32 ..< len:
    crc = crc32Step(crc, payload[i.int])
  wasmPayloadCrc32Finish(crc)

proc wasmPayloadCrc32*(payload: openArray[byte]): uint32 =
  if payload.len == 0:
    return 0
  wasmPayloadCrc32(cast[ptr UncheckedArray[byte]](unsafeAddr payload[0]), payload.len.uint32)

proc wasmProgramSlot*(index: uint32): WasmProgramSlot =
  if index >= Ox64WasmSlotCount.uint32:
    return WasmProgramSlot(index: index, flashOffset: 0, slotSize: 0)
  WasmProgramSlot(
    index: index,
    flashOffset: Ox64WasmStoreOffset.uint32 + index * Ox64WasmSlotSize.uint32,
    slotSize: Ox64WasmSlotSize.uint32,
  )

proc valid*(slot: WasmProgramSlot): bool {.inline.} =
  slot.slotSize >= WasmProgramHeaderLen and
    slot.flashOffset >= Ox64WasmStoreOffset.uint32 and
    slot.flashOffset + slot.slotSize <= Ox64FlashSize.uint32

proc slotPayloadCapacity*(slot: WasmProgramSlot): uint32 {.inline.} =
  if not slot.valid: 0'u32 else: slot.slotSize - WasmProgramHeaderLen

proc xipPtr*(slot: WasmProgramSlot, offset = 0'u32): ptr UncheckedArray[byte] =
  if not slot.valid or offset >= slot.slotSize:
    return nil
  cast[ptr UncheckedArray[byte]](flashXipAddr(slot.flashOffset + offset))

proc readWasmProgramHeader*(base: ptr UncheckedArray[byte]): WasmProgramHeader =
  result.magic = readU32(base, 0)
  result.version = readU16(base, 4)
  result.headerLen = readU16(base, 6)
  result.imageLen = readU32(base, 8)
  result.flags = readU32(base, 12)
  result.generation = readU32(base, 16)
  result.reserved = readU32(base, 20)

proc validateWasmProgramHeader*(slot: WasmProgramSlot,
                                header: WasmProgramHeader): WasmProgramError =
  if slot.slotSize < WasmProgramHeaderLen:
    return wasmProgramBadSlot
  if header.magic != WasmProgramMagic or
      header.version != WasmProgramVersion or
      header.headerLen.uint32 < WasmProgramHeaderLen:
    return wasmProgramBadHeader
  if header.imageLen == 0 or header.imageLen > slot.slotSize - header.headerLen.uint32:
    return wasmProgramTooLarge
  wasmProgramOk

proc wasmProgramChecksum*(header: WasmProgramHeader): uint32 {.inline.} =
  header.reserved

proc isEmptyHeader(header: WasmProgramHeader): bool {.inline.} =
  header.magic == 0xFFFF_FFFF'u32 and
    header.version == 0xFFFF'u16 and
    header.headerLen == 0xFFFF'u16

proc verifyWasmProgramPayload(base: ptr UncheckedArray[byte],
                              header: WasmProgramHeader): WasmProgramError =
  if header.reserved == 0:
    return wasmProgramOk
  let payload = cast[ptr UncheckedArray[byte]](cast[uint](base) + header.headerLen.uint)
  if wasmPayloadCrc32(payload, header.imageLen) != header.reserved:
    return wasmProgramChecksumMismatch
  wasmProgramOk

proc syncWasmProgramXip() {.inline.} =
  ## Flash program/erase operations update the SPI NOR behind the XIP cache.
  ## Drop cached lines before parsing or invoking a just-written slot.
  when defined(bl808m0) or defined(bl808d0) or defined(bl808lp):
    discard l1cInvalidateAll()

proc loadWasmProgramFromView*(base: ptr UncheckedArray[byte], len: uint32,
                              program: var LoadedWasmProgram): WasmProgramError =
  if base == nil or len < WasmProgramHeaderLen:
    return wasmProgramBadHeader
  let slot = WasmProgramSlot(index: 0, flashOffset: 0, slotSize: len)
  let header = readWasmProgramHeader(base)
  result = validateWasmProgramHeader(slot, header)
  if result != wasmProgramOk:
    return
  result = verifyWasmProgramPayload(base, header)
  if result != wasmProgramOk:
    return
  try:
    let payload = cast[ptr UncheckedArray[byte]](cast[uint](base) + header.headerLen.uint)
    program = LoadedWasmProgram(
      loaded: true,
      slot: slot,
      header: header,
      module: parseFlashWasmModule(initWasmImageView(payload, header.imageLen.int)),
    )
    result = wasmProgramOk
  except CatchableError:
    result = wasmProgramParseFailed

proc loadWasmProgramSlot*(index: uint32, program: var LoadedWasmProgram): WasmProgramError =
  let slot = wasmProgramSlot(index)
  if not slot.valid:
    return wasmProgramBadSlot
  syncWasmProgramXip()
  let base = slot.xipPtr()
  let header = readWasmProgramHeader(base)
  result = validateWasmProgramHeader(slot, header)
  if result != wasmProgramOk:
    return
  result = verifyWasmProgramPayload(base, header)
  if result != wasmProgramOk:
    return
  try:
    let payload = slot.xipPtr(header.headerLen.uint32)
    program = LoadedWasmProgram(
      loaded: true,
      slot: slot,
      header: header,
      module: parseFlashWasmModule(initWasmImageView(payload, header.imageLen.int)),
    )
    result = wasmProgramOk
  except CatchableError:
    result = wasmProgramParseFailed

proc unload*(program: var LoadedWasmProgram) =
  program = LoadedWasmProgram()

proc writeWasmProgramHeader*(dst: ptr UncheckedArray[byte], dstLen: uint32,
                             imageLen: uint32,
                             generation = 1'u32,
                             flags = 0'u32,
                             checksum = 0'u32): WasmProgramError =
  if dst == nil or dstLen < WasmProgramHeaderLen:
    return wasmProgramBadHeader
  if imageLen == 0:
    return wasmProgramTooLarge
  writeU32(dst, 0, WasmProgramMagic)
  writeU16(dst, 4, WasmProgramVersion)
  writeU16(dst, 6, WasmProgramHeaderLen.uint16)
  writeU32(dst, 8, imageLen)
  writeU32(dst, 12, flags)
  writeU32(dst, 16, generation)
  writeU32(dst, 20, checksum)
  wasmProgramOk

proc initWasmProgramImage*(dst: ptr UncheckedArray[byte], dstLen: uint32,
                           wasm: openArray[byte],
                           generation = 1'u32,
                           flags = 0'u32): WasmProgramError =
  ## Build a program image in caller-provided storage. This is intended for
  ## tests and upload buffers; persistent writers still need to erase/program
  ## flash before the image becomes visible in a physical slot.
  if dst == nil or dstLen < WasmProgramHeaderLen:
    return wasmProgramBadHeader
  if wasm.len == 0 or wasm.len.uint32 > dstLen - WasmProgramHeaderLen:
    return wasmProgramTooLarge
  result = writeWasmProgramHeader(
    dst,
    dstLen,
    wasm.len.uint32,
    generation,
    flags,
    checksum = wasmPayloadCrc32(wasm),
  )
  if result != wasmProgramOk:
    return
  for i in 0 ..< wasm.len:
    dst[WasmProgramHeaderLen.int + i] = wasm[i]
  result = wasmProgramOk

proc eraseWasmProgramSlot*(index: uint32): WasmProgramError =
  let slot = wasmProgramSlot(index)
  if not slot.valid:
    return wasmProgramBadSlot
  if flashEraseBlock64(slot.flashOffset) != flashOk:
    return wasmProgramFlashError
  result = wasmProgramOk

proc queryWasmProgramSlot*(index: uint32): WasmProgramSlotInfo =
  ## Inspect one managed program slot without parsing the payload.
  let slot = wasmProgramSlot(index)
  result.slot = slot
  if not slot.valid:
    result.state = wasmSlotInvalid
    result.validation = wasmProgramBadSlot
    return
  syncWasmProgramXip()
  let base = slot.xipPtr()
  result.header = readWasmProgramHeader(base)
  if result.header.isEmptyHeader:
    result.state = wasmSlotEmpty
    result.validation = wasmProgramBadHeader
    return
  result.validation = validateWasmProgramHeader(slot, result.header)
  if result.validation != wasmProgramOk:
    result.state = wasmSlotInvalid
    return
  result.validation = verifyWasmProgramPayload(base, result.header)
  if result.validation != wasmProgramOk:
    result.state = wasmSlotInvalid
    return
  result.state = wasmSlotPresent

proc findEmptyWasmProgramSlot*(startIndex = 0'u32): int32 =
  ## Return the first erased slot index, or -1 when the fixed store is full.
  if startIndex >= Ox64WasmSlotCount.uint32:
    return -1
  for index in startIndex ..< Ox64WasmSlotCount.uint32:
    if queryWasmProgramSlot(index).state == wasmSlotEmpty:
      return index.int32
  -1

proc flashMatchesHeader(slot: WasmProgramSlot, header: WasmProgramHeader): bool =
  var bytes: array[WasmProgramHeaderLen.int, byte]
  writeU32(cast[ptr UncheckedArray[byte]](addr bytes[0]), 0, header.magic)
  writeU16(cast[ptr UncheckedArray[byte]](addr bytes[0]), 4, header.version)
  writeU16(cast[ptr UncheckedArray[byte]](addr bytes[0]), 6, header.headerLen)
  writeU32(cast[ptr UncheckedArray[byte]](addr bytes[0]), 8, header.imageLen)
  writeU32(cast[ptr UncheckedArray[byte]](addr bytes[0]), 12, header.flags)
  writeU32(cast[ptr UncheckedArray[byte]](addr bytes[0]), 16, header.generation)
  writeU32(cast[ptr UncheckedArray[byte]](addr bytes[0]), 20, header.reserved)
  flashRawMatches(slot.flashOffset, bytes)

proc writeWasmProgramSlot*(index: uint32, wasm: openArray[byte],
                           generation = 1'u32,
                           flags = 0'u32): WasmProgramError =
  ## Erase a physical flash slot and write one program image. The header is
  ## programmed last so an interrupted upload is not visible as a valid slot.
  let slot = wasmProgramSlot(index)
  if not slot.valid:
    return wasmProgramBadSlot
  if wasm.len == 0 or wasm.len.uint32 > slot.slotPayloadCapacity:
    return wasmProgramTooLarge

  try:
    discard parseFlashWasmModule(initWasmImageView(wasm))
  except CatchableError:
    return wasmProgramParseFailed

  result = eraseWasmProgramSlot(index)
  if result != wasmProgramOk:
    return

  if flashWrite(slot.flashOffset + WasmProgramHeaderLen, wasm) != flashOk:
    return wasmProgramFlashError

  var headerBytes: array[WasmProgramHeaderLen.int, byte]
  result = writeWasmProgramHeader(
    cast[ptr UncheckedArray[byte]](addr headerBytes[0]),
    WasmProgramHeaderLen,
    wasm.len.uint32,
    generation,
    flags,
    checksum = wasmPayloadCrc32(wasm),
  )
  if result != wasmProgramOk:
    return
  if flashWrite(slot.flashOffset, headerBytes) != flashOk:
    return wasmProgramFlashError

  syncWasmProgramXip()
  if not flashRawMatches(slot.flashOffset + WasmProgramHeaderLen, wasm):
    return wasmProgramVerifyFailed
  let header = readWasmProgramHeader(cast[ptr UncheckedArray[byte]](addr headerBytes[0]))
  if not flashMatchesHeader(slot, header):
    return wasmProgramVerifyFailed

  result = wasmProgramOk

proc writeWasmProgramSlotFromReader*(index: uint32,
                                     imageLen: uint32,
                                     readChunk: WasmProgramChunkReader,
                                     scratch: var openArray[byte],
                                     generation = 1'u32,
                                     flags = 0'u32): WasmProgramError =
  ## Stream a WASM payload into a physical flash slot without holding the whole
  ## image in RAM. The slot header is programmed last, so an interrupted stream
  ## never appears as a valid installed program.
  let slot = wasmProgramSlot(index)
  if not slot.valid:
    return wasmProgramBadSlot
  if imageLen == 0 or imageLen > slot.slotPayloadCapacity:
    return wasmProgramTooLarge
  if readChunk == nil or scratch.len == 0:
    return wasmProgramBadHeader

  result = eraseWasmProgramSlot(index)
  if result != wasmProgramOk:
    return

  var remaining = imageLen
  var offset = 0'u32
  var crc = wasmPayloadCrc32Init()
  while remaining > 0:
    let maxChunk = min(remaining.int, scratch.len)
    let n = readChunk(scratch.toOpenArray(0, maxChunk - 1))
    if n <= 0 or n > maxChunk:
      discard eraseWasmProgramSlot(index)
      return wasmProgramFlashError
    crc = wasmPayloadCrc32Update(crc, scratch.toOpenArray(0, n - 1))
    if flashWrite(slot.flashOffset + WasmProgramHeaderLen + offset,
                  scratch.toOpenArray(0, n - 1)) != flashOk:
      discard eraseWasmProgramSlot(index)
      return wasmProgramFlashError
    if not flashRawMatches(slot.flashOffset + WasmProgramHeaderLen + offset,
                           scratch.toOpenArray(0, n - 1)):
      discard eraseWasmProgramSlot(index)
      return wasmProgramVerifyFailed
    offset += n.uint32
    remaining -= n.uint32

  syncWasmProgramXip()
  try:
    discard parseFlashWasmModule(
      initWasmImageView(slot.xipPtr(WasmProgramHeaderLen), imageLen.int)
    )
  except CatchableError:
    discard eraseWasmProgramSlot(index)
    return wasmProgramParseFailed

  var headerBytes: array[WasmProgramHeaderLen.int, byte]
  result = writeWasmProgramHeader(
    cast[ptr UncheckedArray[byte]](addr headerBytes[0]),
    WasmProgramHeaderLen,
    imageLen,
    generation,
    flags,
    checksum = wasmPayloadCrc32Finish(crc),
  )
  if result != wasmProgramOk:
    discard eraseWasmProgramSlot(index)
    return
  if flashWrite(slot.flashOffset, headerBytes) != flashOk:
    discard eraseWasmProgramSlot(index)
    return wasmProgramFlashError

  syncWasmProgramXip()
  let header = readWasmProgramHeader(cast[ptr UncheckedArray[byte]](addr headerBytes[0]))
  if not flashMatchesHeader(slot, header):
    discard eraseWasmProgramSlot(index)
    return wasmProgramVerifyFailed

  result = wasmProgramOk
