## Ordinary byte-stream profile: no six-byte instruction slots or rewriting.
## The module skeleton is still bounded to one (i32,i32)->i32 function, a
## three-byte ASCII export name, no local declarations, and one-byte lengths.
import wasm_profile
export wasm_profile

type ByteAction* = enum
  baNop, baGet, baConst, baAdd, baSub, baMul, baAnd, baOr, baXor, baEnd

const ActionCodes*: array[ByteAction, byte] =
  [1'u8, 0x20, 0x41, 0x6a, 0x6b, 0x6c, 0x71, 0x72, 0x73, 0x0b]

func decodeAction*(value: byte, action: var ByteAction): bool =
  for candidate in ByteAction:
    if ActionCodes[candidate] == value:
      action = candidate
      return true
  false

func isBinary*(action: ByteAction): bool = action in {baAdd..baXor}

func checkByteModule*(wasm: openArray[byte]): bool =
  if wasm.len < StreamWasmMinSize or wasm.len > StreamWasmMaxSize: return false
  for i, b in WasmPrefix:
    case i
    of 25..27:
      if wasm[i] >= 128: return false
    of 31:
      if wasm[i].int != wasm.len - 32: return false
    of 33:
      if wasm[i].int != wasm.len - 34: return false
    else:
      if wasm[i] != b: return false
  var position = WasmPrefix.len
  var depth = 0
  while position < wasm.len:
    var action: ByteAction
    if not decodeAction(wasm[position], action): return false
    inc position
    case action
    of baEnd: return position == wasm.len and depth == 1
    of baNop: discard
    of baGet:
      if position == wasm.len or wasm[position] > 1: return false
      inc position
      inc depth
    of baConst:
      var finished = false
      for i in 0 ..< 5:
        if position == wasm.len: return false
        let b = wasm[position]
        inc position
        if i == 4:
          if b >= 128: return false
          let high = b and 0x78
          if high != 0 and high != 0x78: return false
        if b < 128:
          finished = true
          break
      if not finished: return false
      inc depth
    of baAdd..baXor:
      if depth < 2: return false
      dec depth
    if depth > MaxStack: return false
  false

func signedLeb32*(value: uint32): seq[byte] =
  ## Shortest signed encoding, using exact division to avoid host shift rules.
  var remaining = int64(cast[int32](value))
  while true:
    var b = byte(cast[uint64](remaining) and 0x7f)
    remaining = (remaining - int64(b)) div 128
    let finished = (remaining == 0 and (b and 0x40) == 0) or
                   (remaining == -1 and (b and 0x40) != 0)
    if not finished: b = b or 0x80
    result.add b
    if finished: return

proc decodeByteProgram*(wasm: openArray[byte], program: var Program): bool =
  ## Decode the submitted bytes directly, retaining every non-nop operation.
  ## Leading nop slots fill the native emitter's capacity; raw bytes stay bound.
  if not checkByteModule(wasm): return false
  var operations: seq[Operation]
  var position = WasmPrefix.len
  while wasm[position] != 0x0b:
    var action: ByteAction
    if not decodeAction(wasm[position], action): return false
    inc position
    if action == baNop: continue
    if operations.len == SlotCount: return false
    var operation: Operation
    case action
    of baGet:
      operation.kind = if wasm[position] == 0: opParam0 else: opParam1
      inc position
    of baConst:
      operation.kind = opConst
      var shift = 0
      while true:
        let value = wasm[position]
        inc position
        operation.immediate = operation.immediate or (uint32(value and 0x7f) shl shift)
        shift += 7
        if value < 128:
          if shift < 32 and (value and 0x40) != 0:
            operation.immediate = operation.immediate or (uint32.high shl shift)
          break
    of baAdd..baXor:
      operation.kind = OpKind(ord(action) + 1)
    else: return false
    operations.add operation
  var candidate: Program
  for i, operation in operations:
    candidate[SlotCount - operations.len + i] = operation
  if not checkProgram(candidate): return false
  program = candidate
  true

proc encodeByteModule*(operations: openArray[Operation], name = "run"): seq[byte] =
  if name.len != 3: raise newException(ValueError, "export name must be three ASCII bytes")
  var code: seq[byte]
  for op in operations:
    code.add op.kind.opcode
    case op.kind
    of opParam0: code.add 0
    of opParam1: code.add 1
    of opConst: code.add signedLeb32(op.immediate)
    else: discard
  if code.len > 120: raise newException(ValueError, "byte-stream body is too long")
  result = @WasmPrefix
  for i in 0..2:
    if name[i].ord >= 128: raise newException(ValueError, "export name is not ASCII")
    result[25+i] = name[i].byte
  result[31] = byte(code.len+4)
  result[33] = byte(code.len+2)
  result.add code
  result.add 0x0b
  if not checkByteModule(result): raise newException(ValueError, "ill-typed byte-stream program")
