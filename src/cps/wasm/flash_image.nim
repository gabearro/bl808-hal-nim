## Flash-backed WebAssembly image view.
##
## This parser does not own or copy the raw .wasm bytes. It validates section
## bounds and records offsets into the original image so compact runtimes can
## execute from XIP flash or lazily decode into a small scratch cache.

import ./types

type
  FlashWasmError* = object of CatchableError

  WasmImageView* = object
    bytes*: ptr UncheckedArray[byte]
    len*: int

  WasmSectionRange* = object
    id*: uint8
    payloadOffset*: uint32
    payloadLen*: uint32

  FlashExprRange* = object
    offset*: uint32
    len*: uint32

  FlashFuncBody* = object
    locals*: seq[LocalDecl]
    bodyOffset*: uint32
    bodyLen*: uint32
    codeOffset*: uint32
    codeLen*: uint32

  FlashDataSegment* = object
    mode*: DataMode
    memIdx*: uint32
    offsetExpr*: FlashExprRange
    dataOffset*: uint32
    dataLen*: uint32

  FlashWasmModule* = object
    image*: WasmImageView
    sections*: seq[WasmSectionRange]
    types*: seq[FuncType]
    imports*: seq[Import]
    funcTypeIdxs*: seq[uint32]
    tables*: seq[TableType]
    memories*: seq[MemType]
    exports*: seq[Export]
    startFunc*: int32
    codes*: seq[FlashFuncBody]
    datas*: seq[FlashDataSegment]
    dataCount*: int32

  FlashReader = object
    image: WasmImageView
    pos: int
    limit: int

proc flashError(msg: string) {.noreturn.} =
  raise newException(FlashWasmError, msg)

proc initWasmImageView*(bytes: ptr UncheckedArray[byte], len: int): WasmImageView =
  if bytes == nil or len < 0:
    flashError("invalid WASM image view")
  WasmImageView(bytes: bytes, len: len)

proc initWasmImageView*(data: openArray[byte]): WasmImageView =
  if data.len == 0:
    flashError("empty WASM image")
  initWasmImageView(cast[ptr UncheckedArray[byte]](unsafeAddr data[0]), data.len)

proc initReader(image: WasmImageView, offset = 0, len = -1): FlashReader =
  let endPos = if len < 0: image.len else: offset + len
  if offset < 0 or endPos < offset or endPos > image.len:
    flashError("WASM reader range out of bounds")
  FlashReader(image: image, pos: offset, limit: endPos)

proc atEnd(r: FlashReader): bool {.inline.} =
  r.pos >= r.limit

proc remaining(r: FlashReader): int {.inline.} =
  r.limit - r.pos

proc offset(r: FlashReader): uint32 {.inline.} =
  uint32(r.pos)

proc readByte(r: var FlashReader): byte =
  if r.pos >= r.limit:
    flashError("unexpected end of WASM image")
  result = r.image.bytes[r.pos]
  inc r.pos

proc skip(r: var FlashReader, n: int) =
  if n < 0 or r.pos + n > r.limit:
    flashError("WASM skip out of bounds")
  r.pos += n

proc readU32(r: var FlashReader): uint32 =
  var shift = 0
  while true:
    let b = r.readByte()
    result = result or (uint32(b and 0x7F) shl shift)
    if (b and 0x80) == 0:
      break
    shift += 7
    if shift >= 35:
      flashError("LEB128 u32 overflow")

proc readS32(r: var FlashReader): int32 =
  var shift = 0
  var resultU: uint32 = 0
  var b: byte
  while true:
    b = r.readByte()
    resultU = resultU or (uint32(b and 0x7F) shl shift)
    shift += 7
    if (b and 0x80) == 0:
      break
    if shift >= 35:
      flashError("LEB128 s32 overflow")
  if shift < 32 and (b and 0x40) != 0:
    resultU = resultU or (not uint32(0) shl shift)
  cast[int32](resultU)

proc readName(r: var FlashReader): string =
  let length = r.readU32().int
  if length < 0 or length > r.remaining:
    flashError("WASM name exceeds section bounds")
  result = newString(length)
  for i in 0 ..< length:
    result[i] = char(r.readByte())

proc readValType(r: var FlashReader): ValType =
  case r.readByte()
  of 0x7F: vtI32
  of 0x7E: vtI64
  of 0x7D: vtF32
  of 0x7C: vtF64
  of 0x7B: vtV128
  of 0x70: vtFuncRef
  of 0x6F: vtExternRef
  else: flashError("unknown WASM value type")

proc skipBlockType(r: var FlashReader) =
  let b = r.readByte()
  if b == 0x40'u8:
    return
  if b in {0x7F'u8, 0x7E'u8, 0x7D'u8, 0x7C'u8, 0x7B'u8, 0x70'u8, 0x6F'u8}:
    return
  dec r.pos
  discard r.readS32()

proc skipExprRange(r: var FlashReader): FlashExprRange =
  let start = r.offset
  var depth = 1
  while depth > 0:
    let op = r.readByte()
    case op
    of 0x02, 0x03:
      r.skipBlockType()
      inc depth
    of 0x04:
      r.skipBlockType()
      inc depth
    of 0x05:
      discard
    of 0x0B:
      dec depth
    of 0x0C, 0x0D, 0x10:
      discard r.readU32()
    of 0x11:
      discard r.readU32()
      discard r.readU32()
    of 0x20, 0x21, 0x22, 0x23, 0x24:
      discard r.readU32()
    of 0x28..0x40:
      discard r.readU32()
      discard r.readU32()
    of 0x41:
      discard r.readS32()
    of 0x42:
      # Signed LEB64. We only need to skip it.
      var shift = 0
      while true:
        let b = r.readByte()
        if (b and 0x80) == 0: break
        shift += 7
        if shift >= 70: flashError("LEB128 s64 overflow")
    of 0x43:
      r.skip(4)
    of 0x44:
      r.skip(8)
    of 0xFC:
      let sub = r.readU32()
      case sub
      of 0, 1, 2, 3, 4, 5, 6, 7:
        discard
      of 8, 9, 10, 11, 12:
        discard r.readU32()
      of 14:
        discard r.readU32()
        discard r.readU32()
      of 15, 16, 17:
        discard r.readU32()
      else:
        flashError("unknown 0xFC sub-opcode in flash expression")
    of 0xFD:
      let sub = r.readU32()
      case sub
      of 0, 11:
        discard r.readU32()
        discard r.readU32()
      of 12:
        r.skip(16)
      of 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34:
        discard r.readByte()
      else:
        discard
    else:
      discard
  FlashExprRange(offset: start, len: r.offset - start)

proc readFuncType(r: var FlashReader): FuncType =
  if r.readByte() != 0x60:
    flashError("expected WASM function type")
  let paramCount = r.readU32().int
  result.params = newSeqOfCap[ValType](paramCount)
  for _ in 0 ..< paramCount:
    result.params.add(r.readValType())
  let resultCount = r.readU32().int
  result.results = newSeqOfCap[ValType](resultCount)
  for _ in 0 ..< resultCount:
    result.results.add(r.readValType())

proc readLimits(r: var FlashReader): Limits =
  let flag = r.readByte()
  result.min = r.readU32()
  if (flag and 0x01) != 0:
    result.hasMax = true
    result.max = r.readU32()

proc readMemType(r: var FlashReader): MemType =
  MemType(limits: r.readLimits())

proc readTableType(r: var FlashReader): TableType =
  TableType(elemType: r.readValType(), limits: r.readLimits())

proc readGlobalType(r: var FlashReader): GlobalType =
  result.valType = r.readValType()
  case r.readByte()
  of 0: result.mut = mutConst
  of 1: result.mut = mutVar
  else: flashError("invalid WASM global mutability")

proc parseTypeSection(r: var FlashReader, m: var FlashWasmModule) =
  let count = r.readU32().int
  m.types = newSeqOfCap[FuncType](count)
  for _ in 0 ..< count:
    m.types.add(r.readFuncType())

proc parseImportSection(r: var FlashReader, m: var FlashWasmModule) =
  let count = r.readU32().int
  m.imports = newSeqOfCap[Import](count)
  for _ in 0 ..< count:
    let moduleName = r.readName()
    let name = r.readName()
    case r.readByte()
    of 0x00:
      m.imports.add(Import(module: moduleName, name: name, kind: ikFunc,
                           funcTypeIdx: r.readU32()))
    of 0x01:
      m.imports.add(Import(module: moduleName, name: name, kind: ikTable,
                           tableType: r.readTableType()))
    of 0x02:
      m.imports.add(Import(module: moduleName, name: name, kind: ikMemory,
                           memType: r.readMemType()))
    of 0x03:
      m.imports.add(Import(module: moduleName, name: name, kind: ikGlobal,
                           globalType: r.readGlobalType()))
    else:
      flashError("unknown WASM import kind")

proc parseFunctionSection(r: var FlashReader, m: var FlashWasmModule) =
  let count = r.readU32().int
  m.funcTypeIdxs = newSeqOfCap[uint32](count)
  for _ in 0 ..< count:
    m.funcTypeIdxs.add(r.readU32())

proc parseTableSection(r: var FlashReader, m: var FlashWasmModule) =
  let count = r.readU32().int
  m.tables = newSeqOfCap[TableType](count)
  for _ in 0 ..< count:
    m.tables.add(r.readTableType())

proc parseMemorySection(r: var FlashReader, m: var FlashWasmModule) =
  let count = r.readU32().int
  m.memories = newSeqOfCap[MemType](count)
  for _ in 0 ..< count:
    m.memories.add(r.readMemType())

proc parseExportSection(r: var FlashReader, m: var FlashWasmModule) =
  let count = r.readU32().int
  m.exports = newSeqOfCap[Export](count)
  for _ in 0 ..< count:
    var e: Export
    e.name = r.readName()
    case r.readByte()
    of 0x00: e.kind = ekFunc
    of 0x01: e.kind = ekTable
    of 0x02: e.kind = ekMemory
    of 0x03: e.kind = ekGlobal
    else: flashError("unknown WASM export kind")
    e.idx = r.readU32()
    m.exports.add(e)

proc skipGlobalSection(r: var FlashReader) =
  let count = r.readU32().int
  for _ in 0 ..< count:
    discard r.readGlobalType()
    discard r.skipExprRange()

proc skipElementSection(r: var FlashReader) =
  let count = r.readU32().int
  for _ in 0 ..< count:
    let flags = r.readU32()
    let isPassiveOrDeclarative = (flags and 0x01) != 0
    let hasTableIdxOrElemKind = (flags and 0x02) != 0
    let usesExpressions = (flags and 0x04) != 0

    if not isPassiveOrDeclarative:
      if hasTableIdxOrElemKind:
        discard r.readU32()
      discard r.skipExprRange()

    if isPassiveOrDeclarative or hasTableIdxOrElemKind:
      if usesExpressions:
        discard r.readValType()
      else:
        let elemKind = r.readByte()
        if elemKind != 0x00'u8:
          flashError("unknown WASM elemkind")

    let elemCount = r.readU32().int
    for _ in 0 ..< elemCount:
      if usesExpressions:
        discard r.skipExprRange()
      else:
        discard r.readU32()

proc parseCodeSection(r: var FlashReader, m: var FlashWasmModule) =
  let count = r.readU32().int
  m.codes = newSeqOfCap[FlashFuncBody](count)
  for _ in 0 ..< count:
    let bodySize = r.readU32().int
    let bodyStart = r.pos
    let bodyEnd = bodyStart + bodySize
    if bodySize < 0 or bodyEnd > r.limit:
      flashError("WASM code body exceeds section bounds")
    var body: FlashFuncBody
    body.bodyOffset = uint32(bodyStart)
    body.bodyLen = uint32(bodySize)
    let localDeclCount = r.readU32().int
    body.locals = newSeqOfCap[LocalDecl](localDeclCount)
    for _ in 0 ..< localDeclCount:
      body.locals.add(LocalDecl(count: r.readU32(), valType: r.readValType()))
    body.codeOffset = uint32(r.pos)
    r.pos = bodyEnd
    body.codeLen = uint32(bodyEnd) - body.codeOffset
    m.codes.add(body)

proc parseDataSection(r: var FlashReader, m: var FlashWasmModule) =
  let count = r.readU32().int
  m.datas = newSeqOfCap[FlashDataSegment](count)
  for _ in 0 ..< count:
    var seg: FlashDataSegment
    case r.readU32()
    of 0:
      seg.mode = dataActive
      seg.memIdx = 0
      seg.offsetExpr = r.skipExprRange()
    of 1:
      seg.mode = dataPassive
      seg.memIdx = 0
    of 2:
      seg.mode = dataActive
      seg.memIdx = r.readU32()
      seg.offsetExpr = r.skipExprRange()
    else:
      flashError("unknown WASM data segment flags")
    let dataLen = r.readU32().int
    if dataLen < 0 or dataLen > r.remaining:
      flashError("WASM data segment exceeds section bounds")
    seg.dataOffset = uint32(r.pos)
    seg.dataLen = uint32(dataLen)
    r.skip(dataLen)
    m.datas.add(seg)

proc parseFlashWasmModule*(image: WasmImageView): FlashWasmModule =
  if image.len < 8:
    flashError("WASM image too short")
  var r = initReader(image)
  if r.readByte() != 0x00 or r.readByte() != 0x61 or
     r.readByte() != 0x73 or r.readByte() != 0x6D:
    flashError("invalid WASM magic")
  if r.readByte() != 0x01 or r.readByte() != 0x00 or
     r.readByte() != 0x00 or r.readByte() != 0x00:
    flashError("unsupported WASM version")

  result.image = image
  result.startFunc = -1
  result.dataCount = -1

  var lastSectionId = -1
  while not r.atEnd:
    let sectionId = r.readByte()
    let sectionSize = r.readU32().int
    if sectionSize < 0 or sectionSize > r.remaining:
      flashError("WASM section exceeds image bounds")
    let payloadOffset = r.pos
    let sectionEnd = r.pos + sectionSize
    if sectionId != 0:
      if sectionId.int <= lastSectionId:
        flashError("WASM sections out of order")
      lastSectionId = sectionId.int
    result.sections.add(WasmSectionRange(
      id: sectionId,
      payloadOffset: uint32(payloadOffset),
      payloadLen: uint32(sectionSize),
    ))

    var sr = initReader(image, payloadOffset, sectionSize)
    case sectionId
    of 0:
      sr.skip(sr.remaining)
    of 1:
      parseTypeSection(sr, result)
    of 2:
      parseImportSection(sr, result)
    of 3:
      parseFunctionSection(sr, result)
    of 4:
      parseTableSection(sr, result)
    of 5:
      parseMemorySection(sr, result)
    of 6:
      skipGlobalSection(sr)
    of 7:
      parseExportSection(sr, result)
    of 8:
      result.startFunc = int32(sr.readU32())
    of 9:
      skipElementSection(sr)
    of 10:
      parseCodeSection(sr, result)
    of 11:
      parseDataSection(sr, result)
    of 12:
      result.dataCount = int32(sr.readU32())
    else:
      sr.skip(sr.remaining)
    if not sr.atEnd:
      flashError("WASM section parser did not consume section")
    r.pos = sectionEnd

  if result.codes.len != result.funcTypeIdxs.len:
    flashError("WASM function/code count mismatch")
  if result.dataCount >= 0 and result.dataCount != result.datas.len.int32:
    flashError("WASM data count mismatch")

proc parseFlashWasmModule*(data: openArray[byte]): FlashWasmModule =
  parseFlashWasmModule(initWasmImageView(data))

proc byteAt*(image: WasmImageView, offset: uint32): byte =
  if offset >= image.len.uint32:
    flashError("WASM image byte offset out of bounds")
  image.bytes[offset.int]

proc rangePtr*(image: WasmImageView, offset, len: uint32): ptr UncheckedArray[byte] =
  if offset > image.len.uint32 or len > image.len.uint32 - offset:
    flashError("WASM image range out of bounds")
  cast[ptr UncheckedArray[byte]](cast[uint](image.bytes) + offset.uint)

proc rangeBytes*(image: WasmImageView, offset, len: uint32): seq[byte] =
  if len == 0:
    return @[]
  let p = image.rangePtr(offset, len)
  result = newSeq[byte](len.int)
  for i in 0 ..< len.int:
    result[i] = p[i]
