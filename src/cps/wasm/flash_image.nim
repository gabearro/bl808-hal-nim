## Flash-backed WebAssembly image view.
##
## This parser does not own or copy the raw .wasm bytes. It validates section
## bounds and records offsets into the original image so compact runtimes can
## execute from XIP flash or lazily decode into a small scratch cache.

import ./types
import ./binary_order
import ./utf8_names
import ./simd_encoding
when defined(wasmFunctionReferences):
  from ./binary import WasmDecodeError, viewBinaryReader, readFunctionHeapType,
    readCoreFunctionGroup, remaining, readTableReference, readTableType,
    readTableInitializerPrefix, readGlobalType, readMemType

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
    when defined(wasmSharedCoreTypes):
      shared*: bool

  FlashWasmModule* = object
    image*: WasmImageView
    sections*: seq[WasmSectionRange]
    types*: seq[FuncType]
    imports*: seq[Import]
    funcTypeIdxs*: seq[uint32]
    tables*: seq[TableType]
    memories*: seq[MemType]
    exports*: seq[Export]
    startFunc*: int64
    codes*: seq[FlashFuncBody]
    datas*: seq[FlashDataSegment]
    dataCount*: int64

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
  if n < 0 or n > r.limit-r.pos:
    flashError("WASM skip out of bounds")
  r.pos += n

proc readU32(r: var FlashReader): uint32 =
  for i in 0..4:
    let b = r.readByte()
    if i == 4 and (b and 0xf0) != 0: flashError("LEB128 u32 overflow")
    result = result or (uint32(b and 0x7f) shl (7*i))
    if (b and 0x80) == 0: return
  flashError("LEB128 u32 overflow")

proc readS32(r: var FlashReader): int32 =
  var bits = 0'u32
  for i in 0..4:
    let b = r.readByte()
    let payload = b and 0x7f
    if i == 4 and ((b and 0x80) != 0 or (payload > 7 and payload < 0x78)):
      flashError("LEB128 s32 overflow")
    bits = bits or (uint32(payload) shl (7*i))
    if (b and 0x80) == 0:
      let consumed = 7*(i+1)
      if consumed < 32 and (b and 0x40) != 0: bits = bits or (not 0'u32 shl consumed)
      return cast[int32](bits)
  flashError("LEB128 s32 overflow")

proc readCount(r: var FlashReader): int =
  let count = r.readU32()
  if uint64(count) > uint64(r.remaining): flashError("vector exceeds available bytes")
  int(count)

proc readName(r: var FlashReader): string =
  let length = r.readCount()
  if length < 0 or length > r.remaining:
    flashError("WASM name exceeds section bounds")
  result = newString(length)
  for i in 0 ..< length:
    result[i] = char(r.readByte())
  if not validWasmName(result): flashError("invalid UTF-8 name")

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

when defined(wasmFunctionReferences):
  proc readFunctionHeapType(r: var FlashReader): tuple[lane: ValType, index: uint32, shared: bool] =
    let length = r.remaining()
    if length == 0: flashError("missing reference heap type")
    var reader = viewBinaryReader(r.image.bytes.toOpenArray(r.pos, r.limit - 1))
    try:
      result = reader.readFunctionHeapType()
    except WasmDecodeError as error:
      flashError(error.msg)
    r.pos += length - reader.remaining()

proc skipBlockType(r: var FlashReader) =
  let b = r.readByte()
  if b == 0x40'u8:
    return
  if b in {0x7F'u8, 0x7E'u8, 0x7D'u8, 0x7C'u8, 0x7B'u8, 0x70'u8, 0x6F'u8}:
    return
  dec r.pos
  for i in 0..4:
    let value = r.readByte()
    if i == 4 and ((value and 0x7f) > 15 or (value and 0x80) != 0): flashError("block type s33 overflow")
    if (value and 0x80) == 0:
      if i < 4 and (value and 0x40) != 0: flashError("negative block type index")
      return
  flashError("block type s33 overflow")

proc skipS64(r: var FlashReader) =
  for i in 0..9:
    let b = r.readByte()
    if i == 9 and ((b and 0x80) != 0 or (b and 0x7f) notin [0'u8, 0x7f]):
      flashError("LEB128 s64 overflow")
    if (b and 0x80) == 0: return
  flashError("LEB128 s64 overflow")

proc skipExprRange(r: var FlashReader): FlashExprRange =
  let start = r.offset
  var depth = 1
  while depth > 0:
    let op = r.readByte()
    case op
    of 0x02, 0x03, 0x04:
      r.skipBlockType()
      inc depth
    of 0x1f:
      r.skipBlockType()
      let count = r.readCount()
      for _ in 0..<count:
        let kind = r.readByte()
        if kind > 3: flashError("invalid catch kind")
        if kind < 2: discard r.readU32()
        discard r.readU32()
      inc depth
    of 0x0b: dec depth
    of 0x00, 0x01, 0x05, 0x0a, 0x0f, 0x1a, 0x1b, 0x45..0xc4, 0xd1: discard
    of 0x08, 0x0c, 0x0d, 0x10, 0x12, 0x20..0x26, 0x3f, 0x40, 0xd2:
      discard r.readU32()
    of 0x11, 0x13:
      discard r.readU32()
      discard r.readU32()
    of 0x14, 0x15:
      when defined(wasmFunctionReferences): discard r.readU32()
      else: flashError("typed function references are disabled")
    of 0x0e:
      let count = r.readCount()
      for _ in 0..count: discard r.readU32()
    of 0x1c:
      if r.readU32() != 1: flashError("typed select requires one type")
      discard r.readValType()
    of 0x28..0x3e:
      discard r.readU32()
      discard r.readU32()
    of 0x41: discard r.readS32()
    of 0x42: r.skipS64()
    of 0x43: r.skip(4)
    of 0x44: r.skip(8)
    of 0xd0:
      when defined(wasmFunctionReferences): discard r.readFunctionHeapType()
      else:
        if r.readValType() notin {vtFuncRef, vtExternRef}: flashError("invalid reference type")
    of 0xd4:
      when not defined(wasmFunctionReferences): flashError("typed function references are disabled")
    of 0xfc:
      case r.readU32()
      of 0..7: discard
      of 8, 10, 12, 14:
        discard r.readU32()
        discard r.readU32()
      of 9, 11, 13, 15, 16, 17: discard r.readU32()
      else: flashError("unsupported 0xFC opcode")
    of 0xfd:
      let sub = r.readU32()
      if simdOpcode(sub) == 0: flashError("unsupported SIMD opcode")
      case sub
      of 0, 11:
        discard r.readU32()
        discard r.readU32()
      of 12: r.skip(16)
      of 21..34: discard r.readByte()
      else: discard
    else: flashError("unsupported opcode in flash expression")
  FlashExprRange(offset: start, len: r.offset-start)

proc readFuncType(r: var FlashReader): FuncType =
  if r.readByte() != 0x60:
    flashError("expected WASM function type")
  let paramCount = r.readCount()
  result.params = newSeqOfCap[ValType](paramCount)
  for _ in 0 ..< paramCount:
    result.params.add(r.readValType())
  let resultCount = r.readCount()
  result.results = newSeqOfCap[ValType](resultCount)
  for _ in 0 ..< resultCount:
    result.results.add(r.readValType())

proc readLimits(r: var FlashReader): Limits =
  let flag = r.readByte()
  if flag notin [0'u8, 1]: flashError("unsupported limits flags")
  result.min = r.readU32()
  if (flag and 0x01) != 0:
    result.hasMax = true
    result.max = r.readU32()

proc readMemType(r: var FlashReader): MemType =
  when defined(wasmSharedCoreTypes):
    if r.remaining() == 0: flashError("missing memory type")
    var reader = viewBinaryReader(r.image.bytes.toOpenArray(r.pos, r.limit - 1))
    try:
      result = reader.readMemType()
    except WasmDecodeError as error:
      flashError(error.msg)
    r.pos = r.limit - reader.remaining()
  else:
    MemType(limits: r.readLimits())

proc readTableType(r: var FlashReader, types: openArray[FuncType],
                   hasInitializer: ptr bool = nil): TableType =
  when defined(wasmFunctionReferences):
    if r.remaining() == 0: flashError("missing table type")
    var reader = viewBinaryReader(r.image.bytes.toOpenArray(r.pos, r.limit - 1))
    try:
      if hasInitializer != nil:
        hasInitializer[] = reader.readTableInitializerPrefix()
      result = reader.readTableType(types)
    except WasmDecodeError as error:
      flashError(error.msg)
    r.pos = r.limit - reader.remaining()
  else:
    TableType(elemType: r.readValType(), limits: r.readLimits())

proc readGlobalType(r: var FlashReader, types: openArray[FuncType]): GlobalType =
  when defined(wasmFunctionReferences):
    if r.remaining() == 0: flashError("missing global type")
    var reader = viewBinaryReader(r.image.bytes.toOpenArray(r.pos, r.limit - 1))
    try:
      result = reader.readGlobalType(types)
    except WasmDecodeError as error:
      flashError(error.msg)
    r.pos = r.limit - reader.remaining()
  else:
    result.valType = r.readValType()
    case r.readByte()
    of 0: result.mut = mutConst
    of 1: result.mut = mutVar
    else: flashError("invalid WASM global mutability")

proc parseTypeSection(r: var FlashReader, m: var FlashWasmModule) =
  let count = r.readCount()
  m.types = newSeqOfCap[FuncType](count)
  for _ in 0 ..< count:
    when defined(wasmFunctionReferences):
      if r.remaining() == 0: flashError("missing core function type")
      var reader = viewBinaryReader(r.image.bytes.toOpenArray(r.pos, r.limit - 1))
      try:
        m.types.add(reader.readCoreFunctionGroup(m.types))
      except WasmDecodeError as error:
        flashError(error.msg)
      r.pos = r.limit - reader.remaining()
    else:
      m.types.add(r.readFuncType())

proc parseImportSection(r: var FlashReader, m: var FlashWasmModule) =
  let count = r.readCount()
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
                           tableType: r.readTableType(m.types)))
    of 0x02:
      m.imports.add(Import(module: moduleName, name: name, kind: ikMemory,
                           memType: r.readMemType()))
    of 0x03:
      m.imports.add(Import(module: moduleName, name: name, kind: ikGlobal,
                           globalType: r.readGlobalType(m.types)))
    else:
      flashError("unknown WASM import kind")

proc parseFunctionSection(r: var FlashReader, m: var FlashWasmModule) =
  let count = r.readCount()
  m.funcTypeIdxs = newSeqOfCap[uint32](count)
  for _ in 0 ..< count:
    m.funcTypeIdxs.add(r.readU32())

proc parseTableSection(r: var FlashReader, m: var FlashWasmModule) =
  let count = r.readCount()
  m.tables = newSeqOfCap[TableType](count)
  for _ in 0 ..< count:
    when defined(wasmFunctionReferences):
      var hasInitializer: bool
      m.tables.add(r.readTableType(m.types, addr hasInitializer))
      if hasInitializer: discard r.skipExprRange()
    else:
      m.tables.add(r.readTableType(m.types))

proc parseMemorySection(r: var FlashReader, m: var FlashWasmModule) =
  let count = r.readCount()
  m.memories = newSeqOfCap[MemType](count)
  for _ in 0 ..< count:
    m.memories.add(r.readMemType())

proc parseExportSection(r: var FlashReader, m: var FlashWasmModule) =
  let count = r.readCount()
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

proc skipGlobalSection(r: var FlashReader, types: openArray[FuncType]) =
  let count = r.readCount()
  for _ in 0 ..< count:
    discard r.readGlobalType(types)
    discard r.skipExprRange()

proc skipElementSection(r: var FlashReader, types: openArray[FuncType]) =
  let count = r.readCount()
  for _ in 0 ..< count:
    let flags = r.readU32()
    when defined(wasmSharedCoreTypes):
      if flags > 15: flashError("invalid WASM element flags")
    else:
      if flags > 7: flashError("invalid WASM element flags")
    let isPassiveOrDeclarative = (flags and 0x01) != 0
    let hasTableIdxOrElemKind = (flags and 0x02) != 0
    let usesExpressions = (flags and 0x04) != 0

    if not isPassiveOrDeclarative:
      if hasTableIdxOrElemKind:
        discard r.readU32()
      discard r.skipExprRange()

    if isPassiveOrDeclarative or hasTableIdxOrElemKind:
      if usesExpressions:
        when defined(wasmFunctionReferences):
          if r.remaining() == 0: flashError("missing element reference type")
          var reader = viewBinaryReader(r.image.bytes.toOpenArray(r.pos, r.limit - 1))
          try:
            discard reader.readTableReference(types)
          except WasmDecodeError as error:
            flashError(error.msg)
          r.pos = r.limit - reader.remaining()
        else: discard r.readValType()
      else:
        let elemKind = r.readByte()
        if elemKind != 0x00'u8:
          flashError("unknown WASM elemkind")

    let elemCount = r.readCount()
    for _ in 0 ..< elemCount:
      if usesExpressions:
        discard r.skipExprRange()
      else:
        discard r.readU32()

proc parseCodeSection(r: var FlashReader, m: var FlashWasmModule) =
  let count = r.readCount()
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
    let localDeclCount = r.readCount()
    body.locals = newSeqOfCap[LocalDecl](localDeclCount)
    for _ in 0 ..< localDeclCount:
      var declaration = LocalDecl(count: r.readU32())
      when defined(wasmFunctionReferences):
        let prefix = r.readByte()
        if prefix in [0x63'u8, 0x73'u8, 0x65'u8]:
          if prefix != 0x63: dec r.pos
          let heapType = r.readFunctionHeapType()
          declaration.valType = heapType.lane
          declaration.functionType = heapType.index
          when defined(wasmSharedCoreTypes): declaration.sharedReference = heapType.shared
        else:
          dec r.pos
          declaration.valType = r.readValType()
      else: declaration.valType = r.readValType()
      body.locals.add(declaration)
    body.codeOffset = uint32(r.pos)
    r.pos = bodyEnd
    body.codeLen = uint32(bodyEnd) - body.codeOffset
    m.codes.add(body)

proc parseDataSection(r: var FlashReader, m: var FlashWasmModule) =
  let count = r.readCount()
  m.datas = newSeqOfCap[FlashDataSegment](count)
  for _ in 0 ..< count:
    var seg: FlashDataSegment
    let rawFlags = r.readU32()
    when defined(wasmSharedCoreTypes):
      seg.shared = (rawFlags and 8) != 0
      let flags = rawFlags and not 8'u32
    else:
      let flags = rawFlags
    case flags
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

  var lastSectionOrder = 0
  while not r.atEnd:
    let sectionId = r.readByte()
    let encodedSize = r.readU32()
    if uint64(encodedSize) > uint64(r.remaining):
      flashError("WASM section exceeds image bounds")
    let sectionSize = int(encodedSize)
    let payloadOffset = r.pos
    let sectionEnd = r.pos + sectionSize
    let order = binarySectionOrder(int(sectionId))
    if order < 0: flashError("unknown WASM section ID")
    if sectionId != 0:
      if order <= lastSectionOrder:
        flashError("WASM sections out of order")
      lastSectionOrder = order
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
      skipGlobalSection(sr, result.types)
    of 7:
      parseExportSection(sr, result)
    of 8:
      result.startFunc = int64(sr.readU32())
    of 9:
      skipElementSection(sr, result.types)
    of 10:
      parseCodeSection(sr, result)
    of 11:
      parseDataSection(sr, result)
    of 12:
      result.dataCount = int64(sr.readU32())
    else:
      sr.skip(sr.remaining)
    if not sr.atEnd:
      flashError("WASM section parser did not consume section")
    r.pos = sectionEnd

  if result.codes.len != result.funcTypeIdxs.len:
    flashError("WASM function/code count mismatch")
  if result.dataCount >= 0 and result.dataCount != int64(result.datas.len):
    flashError("WASM data count mismatch")
  if result.startFunc >= 0:
    var functions = uint64(result.funcTypeIdxs.len)
    for item in result.imports:
      if item.kind == ikFunc: inc functions
    if uint64(result.startFunc) >= functions: flashError("WASM start function index out of range")

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
