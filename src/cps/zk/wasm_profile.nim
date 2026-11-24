## An explicitly restricted, canonical WASM profile for the first proof path.
## This is real WASM: (i32, i32) -> i32, exported as `run`.
## Unsupported encodings are rejected, not normalized or trusted.
import field

const
  SlotCount* = 16
  MaxStack* = 8
  WasmPrefix* = [0'u8, 0x61, 0x73, 0x6d, 1, 0, 0, 0,
    1, 7, 1, 0x60, 2, 0x7f, 0x7f, 1, 0x7f,
    3, 2, 1, 0,
    7, 7, 1, 3, 0x72, 0x75, 0x6e, 0, 0,
    10, 100, 1, 98, 0]
  WasmSize* = WasmPrefix.len + SlotCount * 6 + 1
  NativeSize* = (2 + SlotCount * 2 + 2) * 4
  StackRegisters* = [5'u32, 6, 7, 10, 11, 12, 13, 14]
  NativeNop* = 0x13'u32
  StreamWasmMaxSize* = 156 # header + up to 120 instruction bytes + end
  StreamWasmMinSize* = WasmPrefix.len + 1

type
  OpKind* = enum
    opNop, opParam0, opParam1, opConst, opAdd, opSub, opMul, opAnd, opOr, opXor
  Operation* = object
    kind*: OpKind
    immediate*: uint32
  Program* = array[SlotCount, Operation]
  ProofMode* = enum
    pmValidate, pmCompile, pmValidateBytes, pmCompileBytes

func opcode*(kind: OpKind): byte =
  case kind
  of opNop: 0x01
  of opParam0, opParam1: 0x20
  of opConst: 0x41
  of opAdd: 0x6a
  of opSub: 0x6b
  of opMul: 0x6c
  of opAnd: 0x71
  of opOr: 0x72
  of opXor: 0x73

func binary*(kind: OpKind): bool = kind >= opAdd
func pushes*(kind: OpKind): bool = kind in {opParam0, opParam1, opConst}

func checkProgram*(program: Program): bool =
  var height = 0
  for op in program:
    if op.kind.pushes:
      if height == MaxStack: return false
      inc height
    elif op.kind.binary:
      if height < 2: return false
      dec height
  height == 1

func signedLeb5*(value: uint32): array[5, byte] =
  for i in 0 ..< 4: result[i] = byte((value shr (7*i)) and 0x7f) or 0x80
  result[4] = byte(value shr 28)
  if (value and 0x80000000'u32) != 0: result[4] = result[4] or 0x70

func encodeWasm*(program: Program): seq[byte] =
  result = @WasmPrefix
  for op in program:
    var slot = [1'u8, 1, 1, 1, 1, 1]
    slot[0] = op.kind.opcode
    case op.kind
    of opParam0: slot[1] = 0
    of opParam1: slot[1] = 1
    of opConst:
      let leb = signedLeb5(op.immediate)
      for i in 0 ..< 5: slot[i+1] = leb[i]
    else: discard
    result.add slot
  result.add 0x0b

proc decodeWasm*(bytes: openArray[byte], program: var Program): bool =
  if bytes.len != WasmSize: return false
  for i, b in WasmPrefix:
    if bytes[i] != b: return false
  if bytes[^1] != 0x0b: return false
  var candidate: Program
  for i in 0 ..< SlotCount:
    let pos = WasmPrefix.len + i*6
    case bytes[pos]
    of 0x01: candidate[i].kind = opNop
    of 0x20:
      if bytes[pos+1] > 1: return false
      candidate[i].kind = if bytes[pos+1] == 0: opParam0 else: opParam1
    of 0x41:
      candidate[i].kind = opConst
      for j in 0 ..< 4:
        candidate[i].immediate = candidate[i].immediate or
          ((bytes[pos+j+1].uint32 and 0x7f) shl (7*j))
      candidate[i].immediate = candidate[i].immediate or
        ((bytes[pos+5].uint32 and 0xf) shl 28)
    of 0x6a: candidate[i].kind = opAdd
    of 0x6b: candidate[i].kind = opSub
    of 0x6c: candidate[i].kind = opMul
    of 0x71: candidate[i].kind = opAnd
    of 0x72: candidate[i].kind = opOr
    of 0x73: candidate[i].kind = opXor
    else: return false
  # Exact re-encoding rejects altered padding, overlong/sign-invalid LEBs,
  # alternate parameter indices, and all unmodeled module sections.
  if encodeWasm(candidate) != @bytes or not checkProgram(candidate): return false
  program = candidate
  true

func addi*(rd, rs: uint32): uint32 = (rs shl 15) or (rd shl 7) or 0x13

func binaryWord*(kind: OpKind, rd, right: uint32): uint32 =
  result = (right shl 20) or (rd shl 15) or (rd shl 7) or 0x33
  case kind
  of opSub: result = result or 0x40000000'u32
  of opMul: result = result or 0x02000000'u32
  of opAnd: result = result or (7'u32 shl 12)
  of opOr: result = result or (6'u32 shl 12)
  of opXor: result = result or (4'u32 shl 12)
  else: discard

proc addWord(result: var seq[byte], word: uint32) =
  for i in 0 ..< 4: result.add byte((word shr (8*i)) and 0xff)

proc encodeNative*(program: Program): seq[byte] =
  ## Standard RV32 C ABI: a0/a1 input, a0 result, caller-saved registers only.
  ## No memory, calls, relocations, or privileged instructions in this profile.
  if not checkProgram(program): raise newException(ValueError, "invalid program")
  result.addWord addi(28, 10)
  result.addWord addi(29, 11)
  var depth = 0
  for op in program:
    var a, b = NativeNop
    if op.kind.pushes:
      let rd = StackRegisters[depth]
      case op.kind
      of opParam0: a = addi(rd, 28)
      of opParam1: a = addi(rd, 29)
      of opConst:
        a = ((op.immediate + 0x800'u32) and 0xfffff000'u32) or (rd shl 7) or 0x37
        b = (op.immediate shl 20) or addi(rd, rd)
      else: discard
      inc depth
    elif op.kind.binary:
      a = binaryWord(op.kind, StackRegisters[depth-2], StackRegisters[depth-1])
      dec depth
    result.addWord a
    result.addWord b
  result.addWord addi(10, StackRegisters[0])
  result.addWord 0x00008067'u32 # jalr zero, ra, 0

func packedInputs*(bytes: openArray[byte]): seq[Scalar] =
  ## 31-byte limbs are injective in this 255-bit scalar field.
  var acc = scalar(0)
  var weight = scalar(1)
  for i, b in bytes:
    acc += scalar(b) * weight
    weight = weight * scalar(256)
    if i mod 31 == 30 or i == bytes.high:
      result.add acc
      acc = scalar(0)
      weight = scalar(1)

func publicInputs*(mode: ProofMode, wasm, native: openArray[byte]): seq[Scalar] =
  if mode in {pmValidateBytes, pmCompileBytes}:
    # Length is separately bound: padding is a circuit representation only,
    # never permission to append bytes to a submitted module.
    var padded = newSeq[byte](StreamWasmMaxSize)
    for i in 0 ..< min(wasm.len, padded.len): padded[i] = wasm[i]
    result = @[scalar(wasm.len)] & packedInputs(padded)
    if mode == pmCompileBytes: result.add packedInputs(native)
    return
  result = packedInputs(wasm)
  if mode == pmCompile: result.add packedInputs(native)
