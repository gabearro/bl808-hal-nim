## Integer and software-FP WebAssembly interpreter for no-FP cores.
##
## This is the BL808 LP/E902-safe runtime surface: no std/math, no native float
## operations, and no JIT/WASI dependencies. FP values are raw IEEE-754 bit
## patterns interpreted by fpemu.

import ./types
import ./binary
import ./flash_image
import ./fpemu

when defined(bl808lp) and defined(bl808WasmTrace):
  import bl808/mmio

type
  IntWasmTrap* = object of CatchableError

  IntWasmTaskState* = enum
    intTaskReady
    intTaskRunning
    intTaskYielded
    intTaskExited
    intTaskTrapped

  SparseByte = object
    offset: uint32
    value: byte

  CompactLabel = object
    continuation: int
    stackHeight: int
    isLoop: bool

  IntFuncInst = object
    funcType: FuncType
    hasCode: bool
    code: Expr
    codeIsFlash: bool
    flashCodeOffset: uint32
    flashCodeLen: uint32
    localTypes: seq[ValType]

  IntModuleInst = object
    image: WasmImageView
    types: seq[FuncType]
    funcs: seq[IntFuncInst]
    exports: seq[Export]
    memoryPages: uint32
    memoryMax: uint32
    memoryHasMax: bool
    memory: seq[SparseByte]

  IntWasmVM* = object
    modules: seq[IntModuleInst]
    stack: seq[uint32]
    locals: seq[uint32]

  IntWasmTask* = object
    moduleIdx*: int
    funcIdx*: int
    state*: IntWasmTaskState
    pc*: int
    sp*: int
    result*: int32
    trapCode*: uint32
    expr: Expr
    resultCount: int
    locals: seq[uint32]
    stack: seq[uint32]
    labels: array[32, CompactLabel]
    labelCount: int

const CompactLabelStackMax = 32

template trap(msg: string) =
  raise newException(IntWasmTrap, msg)

proc intRuntimeStage(code: uint32) {.inline.} =
  when defined(bl808lp) and defined(bl808WasmTrace):
    regWrite(0x40002E84'u, code)
  else:
    discard code

proc initIntWasmVM*(): IntWasmVM =
  result.stack = newSeq[uint32](64)
  result.locals = newSeq[uint32](32)

proc requireLpValueType(vt: ValType) =
  if vt notin {vtI32, vtF32}:
    trap("unsupported value type in LP runtime")

proc requireLpFuncType(ft: FuncType) =
  for vt in ft.params:
    requireLpValueType(vt)
  for vt in ft.results:
    requireLpValueType(vt)

proc evalOffset(expr: Expr): uint32 =
  for instr in expr.code:
    case instr.op
    of opI32Const:
      return instr.imm1
    else:
      trap("unsupported compact runtime data offset expression")
  trap("data offset expression did not produce a value")

proc decodeFlashExpr(image: WasmImageView, offset, len: uint32): Expr =
  decodeExprBytes(image.rangeBytes(offset, len))

proc evalFlashOffset(image: WasmImageView, expr: FlashExprRange): uint32 =
  evalOffset(decodeFlashExpr(image, expr.offset, expr.len))

proc memoryLimitBytes(inst: IntModuleInst): uint64 {.inline.} =
  uint64(inst.memoryPages) * 65536'u64

proc checkMem(inst: IntModuleInst, offset: uint32, width: uint32) =
  if inst.memoryPages == 0:
    trap("linear memory is not defined")
  let endAddr = uint64(offset) + uint64(width)
  if endAddr > inst.memoryLimitBytes():
    trap("out of bounds compact linear memory access")

proc effectiveOffset(inst: IntModuleInst, base, offset, width: uint32): uint32 =
  let ea = uint64(base) + uint64(offset)
  if ea > uint64(high(uint32)):
    trap("compact linear memory address overflow")
  result = uint32(ea)
  inst.checkMem(result, width)

proc loadByte(inst: IntModuleInst, offset: uint32): byte =
  for cell in inst.memory:
    if cell.offset == offset:
      return cell.value
  0

proc storeByte(inst: var IntModuleInst, offset: uint32, value: byte) =
  for i in 0 ..< inst.memory.len:
    if inst.memory[i].offset == offset:
      if value == 0:
        inst.memory.delete(i)
      else:
        inst.memory[i].value = value
      return
  if value != 0:
    inst.memory.add(SparseByte(offset: offset, value: value))

proc loadU32(inst: IntModuleInst, offset: uint32): uint32 =
  inst.checkMem(offset, 4)
  uint32(inst.loadByte(offset)) or
    (uint32(inst.loadByte(offset + 1)) shl 8) or
    (uint32(inst.loadByte(offset + 2)) shl 16) or
    (uint32(inst.loadByte(offset + 3)) shl 24)

proc loadU16(inst: IntModuleInst, offset: uint32): uint32 =
  inst.checkMem(offset, 2)
  uint32(inst.loadByte(offset)) or (uint32(inst.loadByte(offset + 1)) shl 8)

proc storeU32(inst: var IntModuleInst, offset, value: uint32) =
  inst.checkMem(offset, 4)
  inst.storeByte(offset, byte(value and 0xFF))
  inst.storeByte(offset + 1, byte((value shr 8) and 0xFF))
  inst.storeByte(offset + 2, byte((value shr 16) and 0xFF))
  inst.storeByte(offset + 3, byte((value shr 24) and 0xFF))

proc storeU16(inst: var IntModuleInst, offset, value: uint32) =
  inst.checkMem(offset, 2)
  inst.storeByte(offset, byte(value and 0xFF))
  inst.storeByte(offset + 1, byte((value shr 8) and 0xFF))

proc i32Clz(v: uint32): uint32 =
  if v == 0:
    return 32
  var bit = 0x8000_0000'u32
  while (v and bit) == 0:
    inc result
    bit = bit shr 1

proc i32Ctz(v: uint32): uint32 =
  if v == 0:
    return 32
  var bit = 1'u32
  while (v and bit) == 0:
    inc result
    bit = bit shl 1

proc i32Popcnt(v: uint32): uint32 =
  var x = v
  while x != 0:
    result += x and 1'u32
    x = x shr 1

proc i32Rotl(v, n: uint32): uint32 =
  let s = n and 31'u32
  if s == 0: v else: (v shl s) or (v shr (32'u32 - s))

proc i32Rotr(v, n: uint32): uint32 =
  let s = n and 31'u32
  if s == 0: v else: (v shr s) or (v shl (32'u32 - s))

proc divRemU32(n, d: uint32, remOut: var uint32): uint32 =
  if d == 0:
    trap("integer divide by zero")
  var rem = 0'u32
  for bit in countdown(31, 0):
    rem = (rem shl 1) or ((n shr bit) and 1'u32)
    if rem >= d:
      rem = rem - d
      result = result or (1'u32 shl bit)
  remOut = rem

proc i32Magnitude(v: int32): uint32 =
  if v == int32.low:
    0x8000_0000'u32
  elif v < 0:
    uint32(-v)
  else:
    uint32(v)

proc divS32(a, b: uint32): uint32 =
  let ai = cast[int32](a)
  let bi = cast[int32](b)
  if bi == 0:
    trap("integer divide by zero")
  if ai == int32.low and bi == -1'i32:
    trap("integer divide overflow")
  var rem: uint32
  let q = divRemU32(i32Magnitude(ai), i32Magnitude(bi), rem)
  if (ai < 0) != (bi < 0):
    cast[uint32](-cast[int32](q))
  else:
    q

proc remS32(a, b: uint32): uint32 =
  let ai = cast[int32](a)
  let bi = cast[int32](b)
  if bi == 0:
    trap("integer divide by zero")
  if ai == int32.low and bi == -1'i32:
    return 0
  var rem: uint32
  discard divRemU32(i32Magnitude(ai), i32Magnitude(bi), rem)
  if ai < 0:
    cast[uint32](-cast[int32](rem))
  else:
    rem

proc divU32(a, b: uint32): uint32 =
  var rem: uint32
  divRemU32(a, b, rem)

proc remU32(a, b: uint32): uint32 =
  var rem: uint32
  discard divRemU32(a, b, rem)
  rem

proc findMatchingEnd(code: openArray[Instr], startPc: int): int =
  var depth = 0
  for i in startPc + 1 ..< code.len:
    case code[i].op
    of opBlock, opLoop, opIf:
      inc depth
    of opEnd:
      if depth == 0:
        return i
      dec depth
    else:
      discard
  trap("matching end not found")

proc instantiateIntOnly*(vm: var IntWasmVM, module: WasmModule): int =
  intRuntimeStage(0x57536000'u32)
  if module.imports.len != 0:
    trap("imports are not supported by integer-only runtime")
  if module.tables.len != 0 or module.globals.len != 0:
    trap("tables and globals are not supported by integer-only runtime")
  if module.memories.len > 1:
    trap("only one compact linear memory is supported")
  if module.startFunc >= 0:
    trap("start functions are not supported by integer-only runtime")

  intRuntimeStage(0x57536010'u32)
  var inst = IntModuleInst(types: module.types, exports: module.exports)
  if module.memories.len == 1:
    inst.memoryPages = module.memories[0].limits.min
    inst.memoryHasMax = module.memories[0].limits.hasMax
    inst.memoryMax = module.memories[0].limits.max

  intRuntimeStage(0x57536020'u32)
  for ft in module.types:
    requireLpFuncType(ft)

  intRuntimeStage(0x57536030'u32)
  for i in 0 ..< module.funcTypeIdxs.len:
    intRuntimeStage(0x57536100'u32 or uint32(i and 0xFF))
    let typeIdx = module.funcTypeIdxs[i].int
    if typeIdx >= module.types.len:
      trap("function type index out of range")
    let ft = module.types[typeIdx]
    var localTypes: seq[ValType] = @[]
    for p in ft.params:
      localTypes.add(p)
    if i < module.codes.len:
      for ld in module.codes[i].locals:
        requireLpValueType(ld.valType)
        for _ in 0'u32 ..< ld.count:
          localTypes.add(ld.valType)
    if i < module.codes.len:
      inst.funcs.add(IntFuncInst(
        funcType: ft,
        hasCode: true,
        code: module.codes[i].code,
        localTypes: localTypes,
      ))
    else:
      inst.funcs.add(IntFuncInst(
        funcType: ft,
        hasCode: false,
        localTypes: localTypes,
      ))

  intRuntimeStage(0x57536040'u32)
  for ds in module.datas:
    intRuntimeStage(0x57536200'u32)
    if ds.mode != dataActive:
      trap("passive data segments are not supported by compact runtime")
    if ds.memIdx != 0:
      trap("only memory 0 is supported by compact runtime")
    let offset = evalOffset(ds.offset)
    if uint64(offset) + uint64(ds.data.len) > inst.memoryLimitBytes():
      trap("active data segment exceeds compact linear memory")
    for i in 0 ..< ds.data.len:
      intRuntimeStage(0x57536300'u32 or uint32(i and 0xFF))
      inst.storeByte(offset + uint32(i), ds.data[i])

  intRuntimeStage(0x57536050'u32)
  result = vm.modules.len
  vm.modules.add(inst)
  intRuntimeStage(0x57536060'u32)

proc instantiateFlashIntOnly*(vm: var IntWasmVM, module: FlashWasmModule): int =
  intRuntimeStage(0x5753A000'u32)
  if module.imports.len != 0:
    trap("imports are not supported by integer-only runtime")
  if module.tables.len != 0:
    trap("tables are not supported by integer-only runtime")
  if module.memories.len > 1:
    trap("only one compact linear memory is supported")
  if module.startFunc >= 0:
    trap("start functions are not supported by integer-only runtime")
  if module.codes.len != module.funcTypeIdxs.len:
    trap("function/code count mismatch in flash module")

  intRuntimeStage(0x5753A010'u32)
  var inst = IntModuleInst(
    image: module.image,
    types: module.types,
    exports: module.exports,
  )
  if module.memories.len == 1:
    inst.memoryPages = module.memories[0].limits.min
    inst.memoryHasMax = module.memories[0].limits.hasMax
    inst.memoryMax = module.memories[0].limits.max

  intRuntimeStage(0x5753A020'u32)
  for ft in module.types:
    requireLpFuncType(ft)

  intRuntimeStage(0x5753A030'u32)
  for i in 0 ..< module.funcTypeIdxs.len:
    let typeIdx = module.funcTypeIdxs[i].int
    if typeIdx < 0 or typeIdx >= module.types.len:
      trap("function type index out of range")
    let ft = module.types[typeIdx]
    var localTypes: seq[ValType] = @[]
    for p in ft.params:
      localTypes.add(p)
    for ld in module.codes[i].locals:
      requireLpValueType(ld.valType)
      for _ in 0'u32 ..< ld.count:
        localTypes.add(ld.valType)
    inst.funcs.add(IntFuncInst(
      funcType: ft,
      hasCode: true,
      codeIsFlash: true,
      flashCodeOffset: module.codes[i].codeOffset,
      flashCodeLen: module.codes[i].codeLen,
      localTypes: localTypes,
    ))

  intRuntimeStage(0x5753A040'u32)
  for ds in module.datas:
    if ds.mode != dataActive:
      trap("passive data segments are not supported by compact runtime")
    if ds.memIdx != 0:
      trap("only memory 0 is supported by compact runtime")
    let offset = evalFlashOffset(module.image, ds.offsetExpr)
    if uint64(offset) + uint64(ds.dataLen) > inst.memoryLimitBytes():
      trap("active data segment exceeds compact linear memory")
    let data = module.image.rangePtr(ds.dataOffset, ds.dataLen)
    for i in 0 ..< ds.dataLen.int:
      inst.storeByte(offset + uint32(i), data[i])

  intRuntimeStage(0x5753A050'u32)
  result = vm.modules.len
  vm.modules.add(inst)
  intRuntimeStage(0x5753A060'u32)

proc push(vm: var IntWasmVM, value: uint32, sp: var int) {.inline.} =
  if sp >= vm.stack.len:
    vm.stack.setLen(vm.stack.len * 2)
  vm.stack[sp] = value
  inc sp

proc pop(vm: var IntWasmVM, sp: var int): uint32 {.inline.} =
  if sp <= 0:
    trap("operand stack underflow")
  dec sp
  vm.stack[sp]

proc pushCompactLabel(labels: var array[CompactLabelStackMax, CompactLabel],
                      count: var int,
                      continuation, stackHeight: int,
                      isLoop: bool) {.inline.} =
  if count >= labels.len:
    trap("compact label stack overflow")
  labels[count] = CompactLabel(
    continuation: continuation,
    stackHeight: stackHeight,
    isLoop: isLoop,
  )
  inc count

proc popCompletedCompactLabel(labels: var array[CompactLabelStackMax, CompactLabel],
                              count: var int,
                              pc: int) {.inline.} =
  if count != 0 and labels[count - 1].continuation == pc + 1:
    dec count

proc compactBranchTo(labels: var array[CompactLabelStackMax, CompactLabel],
                     count: var int,
                     depth: uint32,
                     sp: var int): int {.inline.} =
  if depth > uint32(high(int)):
    trap("branch depth out of range")
  let idx = count - 1 - depth.int
  if idx < 0 or idx >= count:
    trap("branch depth out of range")
  let target = labels[idx]
  sp = target.stackHeight
  if target.isLoop:
    count = idx + 1
  else:
    count = idx
  target.continuation

proc executeInt(vm: var IntWasmVM, moduleIdx: int, funcIdx: int,
                args: openArray[int32]): int32 =
  if moduleIdx < 0 or moduleIdx >= vm.modules.len:
    trap("module index out of range")
  let inst = addr vm.modules[moduleIdx]
  if funcIdx < 0 or funcIdx >= inst.funcs.len:
    trap("function index out of range")
  let fn = addr inst.funcs[funcIdx]
  if not fn.hasCode:
    trap("missing function body")
  if fn.funcType.params.len != args.len:
    trap("argument count mismatch")

  while fn.localTypes.len > vm.locals.len:
    vm.locals.setLen(vm.locals.len * 2)
  for i in 0 ..< args.len:
    vm.locals[i] = cast[uint32](args[i])
  for i in args.len ..< fn.localTypes.len:
    vm.locals[i] = 0

  var sp = 0
  var pc = 0
  let expr =
    if fn.codeIsFlash:
      decodeFlashExpr(inst.image, fn.flashCodeOffset, fn.flashCodeLen)
    else:
      fn.code
  var labels: array[CompactLabelStackMax, CompactLabel]
  var labelCount = 0

  while pc < expr.code.len:
    intRuntimeStage(0x57537000'u32 or (uint32(funcIdx and 0xF) shl 8) or uint32(pc and 0xFF))
    let instr = expr.code[pc]
    case instr.op
    of opUnreachable:
      trap("unreachable executed")
    of opNop:
      discard
    of opBlock:
      if instr.imm1.int < pc or instr.imm1.int >= expr.code.len:
        trap("block end out of range")
      pushCompactLabel(labels, labelCount, instr.imm1.int + 1, sp, false)
    of opLoop:
      if instr.imm1.int < pc or instr.imm1.int >= expr.code.len:
        trap("loop end out of range")
      pushCompactLabel(labels, labelCount, pc + 1, sp, true)
    of opIf:
      let cond = vm.pop(sp)
      if instr.imm1.int < pc or instr.imm1.int >= expr.code.len:
        trap("if end out of range")
      if cond == 0:
        let target = instr.imm2.int
        if target < 0 or target >= expr.code.len:
          trap("if target out of range")
        if instr.imm2 != instr.imm1:
          pushCompactLabel(labels, labelCount, instr.imm1.int + 1, sp, false)
        pc = target + 1
        continue
      else:
        pushCompactLabel(labels, labelCount, instr.imm1.int + 1, sp, false)
    of opElse:
      if labelCount != 0:
        dec labelCount
      pc = findMatchingEnd(expr.code, pc) + 1
      continue
    of opBr:
      pc = compactBranchTo(labels, labelCount, instr.imm1, sp)
      continue
    of opBrIf:
      let cond = vm.pop(sp)
      if cond != 0:
        pc = compactBranchTo(labels, labelCount, instr.imm1, sp)
        continue
    of opI32EqzBrIf:
      let a = vm.pop(sp)
      if a == 0:
        pc = compactBranchTo(labels, labelCount, instr.imm1, sp)
        continue
    of opI32EqBrIf:
      let b = vm.pop(sp)
      let a = vm.pop(sp)
      if a == b:
        pc = compactBranchTo(labels, labelCount, instr.imm1, sp)
        continue
    of opI32NeBrIf:
      let b = vm.pop(sp)
      let a = vm.pop(sp)
      if a != b:
        pc = compactBranchTo(labels, labelCount, instr.imm1, sp)
        continue
    of opI32LtSBrIf:
      let b = cast[int32](vm.pop(sp))
      let a = cast[int32](vm.pop(sp))
      if a < b:
        pc = compactBranchTo(labels, labelCount, instr.imm1, sp)
        continue
    of opI32GeSBrIf:
      let b = cast[int32](vm.pop(sp))
      let a = cast[int32](vm.pop(sp))
      if a >= b:
        pc = compactBranchTo(labels, labelCount, instr.imm1, sp)
        continue
    of opI32GtSBrIf:
      let b = cast[int32](vm.pop(sp))
      let a = cast[int32](vm.pop(sp))
      if a > b:
        pc = compactBranchTo(labels, labelCount, instr.imm1, sp)
        continue
    of opI32LeSBrIf:
      let b = cast[int32](vm.pop(sp))
      let a = cast[int32](vm.pop(sp))
      if a <= b:
        pc = compactBranchTo(labels, labelCount, instr.imm1, sp)
        continue
    of opI32LtUBrIf:
      let b = vm.pop(sp)
      let a = vm.pop(sp)
      if a < b:
        pc = compactBranchTo(labels, labelCount, instr.imm1, sp)
        continue
    of opI32GeUBrIf:
      let b = vm.pop(sp)
      let a = vm.pop(sp)
      if a >= b:
        pc = compactBranchTo(labels, labelCount, instr.imm1, sp)
        continue
    of opI32GtUBrIf:
      let b = vm.pop(sp)
      let a = vm.pop(sp)
      if a > b:
        pc = compactBranchTo(labels, labelCount, instr.imm1, sp)
        continue
    of opI32LeUBrIf:
      let b = vm.pop(sp)
      let a = vm.pop(sp)
      if a <= b:
        pc = compactBranchTo(labels, labelCount, instr.imm1, sp)
        continue
    of opI32ConstI32EqBrIf:
      let a = vm.pop(sp)
      if a == instr.imm1:
        pc = compactBranchTo(labels, labelCount, instr.imm2, sp)
        continue
    of opI32ConstI32NeBrIf:
      let a = vm.pop(sp)
      if a != instr.imm1:
        pc = compactBranchTo(labels, labelCount, instr.imm2, sp)
        continue
    of opI32ConstI32LtSBrIf:
      let a = cast[int32](vm.pop(sp))
      if a < cast[int32](instr.imm1):
        pc = compactBranchTo(labels, labelCount, instr.imm2, sp)
        continue
    of opI32ConstI32GeSBrIf:
      let a = cast[int32](vm.pop(sp))
      if a >= cast[int32](instr.imm1):
        pc = compactBranchTo(labels, labelCount, instr.imm2, sp)
        continue
    of opI32ConstI32GtUBrIf:
      let a = vm.pop(sp)
      if a > instr.imm1:
        pc = compactBranchTo(labels, labelCount, instr.imm2, sp)
        continue
    of opI32ConstI32LeUBrIf:
      let a = vm.pop(sp)
      if a <= instr.imm1:
        pc = compactBranchTo(labels, labelCount, instr.imm2, sp)
        continue
    of opCall:
      let calleeIdx = instr.imm1.int
      if calleeIdx < 0 or calleeIdx >= vm.modules[moduleIdx].funcs.len:
        trap("call function index out of range")
      let callee = addr vm.modules[moduleIdx].funcs[calleeIdx]
      if callee.funcType.results.len > 1:
        trap("unsupported multi-value call result")
      let callerLocalCount = fn.localTypes.len
      var savedLocals = newSeq[uint32](callerLocalCount)
      for i in 0 ..< callerLocalCount:
        savedLocals[i] = vm.locals[i]

      let paramCount = callee.funcType.params.len
      var callArgs = newSeq[int32](paramCount)
      if paramCount > 0:
        for i in countdown(paramCount - 1, 0):
          callArgs[i] = cast[int32](vm.pop(sp))

      var savedStack = newSeq[uint32](sp)
      for i in 0 ..< sp:
        savedStack[i] = vm.stack[i]

      let callResult = vm.executeInt(moduleIdx, calleeIdx, callArgs)

      while callerLocalCount > vm.locals.len:
        vm.locals.setLen(vm.locals.len * 2)
      for i in 0 ..< callerLocalCount:
        vm.locals[i] = savedLocals[i]
      while sp > vm.stack.len:
        vm.stack.setLen(vm.stack.len * 2)
      for i in 0 ..< sp:
        vm.stack[i] = savedStack[i]
      if callee.funcType.results.len == 1:
        vm.push(cast[uint32](callResult), sp)
    of opI32Const:
      vm.push(instr.imm1, sp)
    of opF32Const:
      vm.push(instr.imm1, sp)
    of opLocalGet:
      let idx = instr.imm1.int
      if idx < 0 or idx >= fn.localTypes.len:
        trap("local.get index out of range")
      vm.push(vm.locals[idx], sp)
    of opLocalSet:
      let idx = instr.imm1.int
      if idx < 0 or idx >= fn.localTypes.len:
        trap("local.set index out of range")
      vm.locals[idx] = vm.pop(sp)
    of opLocalTee:
      let idx = instr.imm1.int
      if idx < 0 or idx >= fn.localTypes.len:
        trap("local.tee index out of range")
      let value = vm.pop(sp)
      vm.locals[idx] = value
      vm.push(value, sp)
    of opLocalSetLocalGet:
      let setIdx = instr.imm1.int
      let getIdx = instr.imm2.int
      if setIdx < 0 or setIdx >= fn.localTypes.len or getIdx < 0 or getIdx >= fn.localTypes.len:
        trap("local.set/local.get index out of range")
      vm.locals[setIdx] = vm.pop(sp)
      vm.push(vm.locals[getIdx], sp)
    of opLocalTeeLocalGet:
      let teeIdx = instr.imm1.int
      let getIdx = instr.imm2.int
      if teeIdx < 0 or teeIdx >= fn.localTypes.len or getIdx < 0 or getIdx >= fn.localTypes.len:
        trap("local.tee/local.get index out of range")
      let value = vm.pop(sp)
      vm.locals[teeIdx] = value
      vm.push(value, sp)
      vm.push(vm.locals[getIdx], sp)
    of opLocalGetLocalTee:
      let getIdx = instr.imm1.int
      let teeIdx = instr.imm2.int
      if getIdx < 0 or getIdx >= fn.localTypes.len or teeIdx < 0 or teeIdx >= fn.localTypes.len:
        trap("local.get/local.tee index out of range")
      vm.push(vm.locals[getIdx], sp)
      let value = vm.pop(sp)
      vm.locals[teeIdx] = value
      vm.push(value, sp)
    of opLocalGetLocalGet:
      let aIdx = instr.imm1.int
      let bIdx = instr.imm2.int
      if aIdx < 0 or aIdx >= fn.localTypes.len or bIdx < 0 or bIdx >= fn.localTypes.len:
        trap("local.get/local.get index out of range")
      vm.push(vm.locals[aIdx], sp)
      vm.push(vm.locals[bIdx], sp)
    of opLocalGetI32Add:
      let idx = instr.imm1.int
      if idx < 0 or idx >= fn.localTypes.len:
        trap("local.get/i32.add index out of range")
      let a = vm.pop(sp)
      vm.push(a + vm.locals[idx], sp)
    of opLocalGetI32Sub:
      let idx = instr.imm1.int
      if idx < 0 or idx >= fn.localTypes.len:
        trap("local.get/i32.sub index out of range")
      let a = vm.pop(sp)
      vm.push(a - vm.locals[idx], sp)
    of opLocalGetI32Mul:
      let idx = instr.imm1.int
      if idx < 0 or idx >= fn.localTypes.len:
        trap("local.get/i32.mul index out of range")
      let a = vm.pop(sp)
      vm.push(a * vm.locals[idx], sp)
    of opLocalGetI32GtS:
      let idx = instr.imm1.int
      if idx < 0 or idx >= fn.localTypes.len:
        trap("local.get/i32.gt_s index out of range")
      let a = cast[int32](vm.pop(sp))
      let b = cast[int32](vm.locals[idx])
      vm.push(if a > b: 1'u32 else: 0'u32, sp)
    of opLocalGetLocalGetI32Add:
      let aIdx = instr.imm1.int
      let bIdx = instr.imm2.int
      if aIdx < 0 or aIdx >= fn.localTypes.len or bIdx < 0 or bIdx >= fn.localTypes.len:
        trap("local.get/local.get/i32.add index out of range")
      vm.push(vm.locals[aIdx] + vm.locals[bIdx], sp)
    of opLocalGetLocalGetI32Sub:
      let aIdx = instr.imm1.int
      let bIdx = instr.imm2.int
      if aIdx < 0 or aIdx >= fn.localTypes.len or bIdx < 0 or bIdx >= fn.localTypes.len:
        trap("local.get/local.get/i32.sub index out of range")
      vm.push(vm.locals[aIdx] - vm.locals[bIdx], sp)
    of opLocalGetI32ConstI32Add:
      let idx = instr.imm1.int
      if idx < 0 or idx >= fn.localTypes.len:
        trap("local.get/i32.const/i32.add index out of range")
      vm.push(vm.locals[idx] + instr.imm2, sp)
    of opLocalGetI32ConstI32Sub:
      let idx = instr.imm1.int
      if idx < 0 or idx >= fn.localTypes.len:
        trap("local.get/i32.const/i32.sub index out of range")
      vm.push(vm.locals[idx] - instr.imm2, sp)
    of opI32ConstI32Add:
      let a = vm.pop(sp)
      vm.push(a + instr.imm1, sp)
    of opI32ConstI32Sub:
      let a = vm.pop(sp)
      vm.push(a - instr.imm1, sp)
    of opI32ConstI32Eq:
      let a = vm.pop(sp)
      vm.push(if a == instr.imm1: 1'u32 else: 0'u32, sp)
    of opI32ConstI32Ne:
      let a = vm.pop(sp)
      vm.push(if a != instr.imm1: 1'u32 else: 0'u32, sp)
    of opI32ConstI32GtU:
      let a = vm.pop(sp)
      vm.push(if a > instr.imm1: 1'u32 else: 0'u32, sp)
    of opI32ConstI32LtS:
      let a = cast[int32](vm.pop(sp))
      vm.push(if a < cast[int32](instr.imm1): 1'u32 else: 0'u32, sp)
    of opI32ConstI32GeS:
      let a = cast[int32](vm.pop(sp))
      vm.push(if a >= cast[int32](instr.imm1): 1'u32 else: 0'u32, sp)
    of opI32ConstI32And:
      let a = vm.pop(sp)
      vm.push(a and instr.imm1, sp)
    of opI32ConstI32Mul:
      let a = vm.pop(sp)
      vm.push(a * instr.imm1, sp)
    of opI32AddLocalSet:
      let idx = instr.imm1.int
      if idx < 0 or idx >= fn.localTypes.len:
        trap("i32.add/local.set index out of range")
      let b = vm.pop(sp)
      let a = vm.pop(sp)
      vm.locals[idx] = a + b
    of opI32SubLocalSet:
      let idx = instr.imm1.int
      if idx < 0 or idx >= fn.localTypes.len:
        trap("i32.sub/local.set index out of range")
      let b = vm.pop(sp)
      let a = vm.pop(sp)
      vm.locals[idx] = a - b
    of opLocalI32AddInPlace:
      let idx = instr.imm1.int
      if idx < 0 or idx >= fn.localTypes.len:
        trap("local i32 add-in-place index out of range")
      vm.locals[idx] = cast[uint32](cast[int32](vm.locals[idx]) + cast[int32](instr.imm2))
    of opLocalI32SubInPlace:
      let idx = instr.imm1.int
      if idx < 0 or idx >= fn.localTypes.len:
        trap("local i32 sub-in-place index out of range")
      vm.locals[idx] = cast[uint32](cast[int32](vm.locals[idx]) - cast[int32](instr.imm2))
    of opLocalGetLocalGetI32AddLocalSet:
      let x = int(instr.imm1 and 0xFFFF'u32)
      let y = int(instr.imm1 shr 16)
      let z = instr.imm2.int
      if x < 0 or x >= fn.localTypes.len or y < 0 or y >= fn.localTypes.len or
          z < 0 or z >= fn.localTypes.len:
        trap("local.get/local.get/i32.add/local.set index out of range")
      vm.locals[z] = vm.locals[x] + vm.locals[y]
    of opLocalGetLocalGetI32SubLocalSet:
      let x = int(instr.imm1 and 0xFFFF'u32)
      let y = int(instr.imm1 shr 16)
      let z = instr.imm2.int
      if x < 0 or x >= fn.localTypes.len or y < 0 or y >= fn.localTypes.len or
          z < 0 or z >= fn.localTypes.len:
        trap("local.get/local.get/i32.sub/local.set index out of range")
      vm.locals[z] = vm.locals[x] - vm.locals[y]
    of opI32Add:
      let b = vm.pop(sp)
      let a = vm.pop(sp)
      vm.push(a + b, sp)
    of opI32Sub:
      let b = vm.pop(sp)
      let a = vm.pop(sp)
      vm.push(a - b, sp)
    of opI32Mul:
      let b = vm.pop(sp)
      let a = vm.pop(sp)
      vm.push(a * b, sp)
    of opI32DivS:
      let b = vm.pop(sp)
      let a = vm.pop(sp)
      vm.push(divS32(a, b), sp)
    of opI32DivU:
      let b = vm.pop(sp)
      let a = vm.pop(sp)
      vm.push(divU32(a, b), sp)
    of opI32RemS:
      let b = vm.pop(sp)
      let a = vm.pop(sp)
      vm.push(remS32(a, b), sp)
    of opI32RemU:
      let b = vm.pop(sp)
      let a = vm.pop(sp)
      vm.push(remU32(a, b), sp)
    of opI32And:
      let b = vm.pop(sp)
      let a = vm.pop(sp)
      vm.push(a and b, sp)
    of opI32Or:
      let b = vm.pop(sp)
      let a = vm.pop(sp)
      vm.push(a or b, sp)
    of opI32Xor:
      let b = vm.pop(sp)
      let a = vm.pop(sp)
      vm.push(a xor b, sp)
    of opI32Shl:
      let b = vm.pop(sp) and 31'u32
      let a = vm.pop(sp)
      vm.push(a shl b, sp)
    of opI32ShrU:
      let b = vm.pop(sp) and 31'u32
      let a = vm.pop(sp)
      vm.push(a shr b, sp)
    of opI32ShrS:
      let b = vm.pop(sp) and 31'u32
      let a = cast[int32](vm.pop(sp))
      vm.push(cast[uint32](a shr b), sp)
    of opI32Rotl:
      let b = vm.pop(sp)
      let a = vm.pop(sp)
      vm.push(i32Rotl(a, b), sp)
    of opI32Rotr:
      let b = vm.pop(sp)
      let a = vm.pop(sp)
      vm.push(i32Rotr(a, b), sp)
    of opI32Clz:
      vm.push(i32Clz(vm.pop(sp)), sp)
    of opI32Ctz:
      vm.push(i32Ctz(vm.pop(sp)), sp)
    of opI32Popcnt:
      vm.push(i32Popcnt(vm.pop(sp)), sp)
    of opI32Eqz:
      vm.push(if vm.pop(sp) == 0: 1'u32 else: 0'u32, sp)
    of opI32Eq:
      let b = vm.pop(sp)
      let a = vm.pop(sp)
      vm.push(if a == b: 1'u32 else: 0'u32, sp)
    of opI32Ne:
      let b = vm.pop(sp)
      let a = vm.pop(sp)
      vm.push(if a != b: 1'u32 else: 0'u32, sp)
    of opI32LtS:
      let b = cast[int32](vm.pop(sp))
      let a = cast[int32](vm.pop(sp))
      vm.push(if a < b: 1'u32 else: 0'u32, sp)
    of opI32LtU:
      let b = vm.pop(sp)
      let a = vm.pop(sp)
      vm.push(if a < b: 1'u32 else: 0'u32, sp)
    of opI32GtS:
      let b = cast[int32](vm.pop(sp))
      let a = cast[int32](vm.pop(sp))
      vm.push(if a > b: 1'u32 else: 0'u32, sp)
    of opI32GtU:
      let b = vm.pop(sp)
      let a = vm.pop(sp)
      vm.push(if a > b: 1'u32 else: 0'u32, sp)
    of opI32LeS:
      let b = cast[int32](vm.pop(sp))
      let a = cast[int32](vm.pop(sp))
      vm.push(if a <= b: 1'u32 else: 0'u32, sp)
    of opI32LeU:
      let b = vm.pop(sp)
      let a = vm.pop(sp)
      vm.push(if a <= b: 1'u32 else: 0'u32, sp)
    of opI32GeS:
      let b = cast[int32](vm.pop(sp))
      let a = cast[int32](vm.pop(sp))
      vm.push(if a >= b: 1'u32 else: 0'u32, sp)
    of opI32GeU:
      let b = vm.pop(sp)
      let a = vm.pop(sp)
      vm.push(if a >= b: 1'u32 else: 0'u32, sp)
    of opI32Extend8S:
      vm.push(cast[uint32](int32(cast[int8](byte(vm.pop(sp) and 0xFF'u32)))), sp)
    of opI32Extend16S:
      vm.push(cast[uint32](int32(cast[int16](uint16(vm.pop(sp) and 0xFFFF'u32)))), sp)
    of opI32Load:
      let base = vm.pop(sp)
      let ea = vm.modules[moduleIdx].effectiveOffset(base, instr.imm1, 4)
      vm.push(vm.modules[moduleIdx].loadU32(ea), sp)
    of opLocalGetI32Load:
      let idx = instr.imm1.int
      if idx < 0 or idx >= fn.localTypes.len:
        trap("local.get/i32.load index out of range")
      let ea = vm.modules[moduleIdx].effectiveOffset(vm.locals[idx], instr.imm2, 4)
      vm.push(vm.modules[moduleIdx].loadU32(ea), sp)
    of opLocalGetI32LoadI32Add:
      let idx = instr.imm1.int
      if idx < 0 or idx >= fn.localTypes.len:
        trap("local.get/i32.load/i32.add index out of range")
      let a = vm.pop(sp)
      let ea = vm.modules[moduleIdx].effectiveOffset(vm.locals[idx], instr.imm2, 4)
      vm.push(a + vm.modules[moduleIdx].loadU32(ea), sp)
    of opF32Load:
      let base = vm.pop(sp)
      let ea = vm.modules[moduleIdx].effectiveOffset(base, instr.imm1, 4)
      vm.push(vm.modules[moduleIdx].loadU32(ea), sp)
    of opI32Load8U:
      let base = vm.pop(sp)
      let ea = vm.modules[moduleIdx].effectiveOffset(base, instr.imm1, 1)
      vm.push(uint32(vm.modules[moduleIdx].loadByte(ea)), sp)
    of opI32Load8S:
      let base = vm.pop(sp)
      let ea = vm.modules[moduleIdx].effectiveOffset(base, instr.imm1, 1)
      vm.push(cast[uint32](int32(cast[int8](vm.modules[moduleIdx].loadByte(ea)))), sp)
    of opI32Load16U:
      let base = vm.pop(sp)
      let ea = vm.modules[moduleIdx].effectiveOffset(base, instr.imm1, 2)
      vm.push(vm.modules[moduleIdx].loadU16(ea), sp)
    of opI32Load16S:
      let base = vm.pop(sp)
      let ea = vm.modules[moduleIdx].effectiveOffset(base, instr.imm1, 2)
      let value = uint16(vm.modules[moduleIdx].loadU16(ea))
      vm.push(cast[uint32](int32(cast[int16](value))), sp)
    of opI32Store:
      let value = vm.pop(sp)
      let base = vm.pop(sp)
      let ea = vm.modules[moduleIdx].effectiveOffset(base, instr.imm1, 4)
      vm.modules[moduleIdx].storeU32(ea, value)
    of opLocalGetI32Store:
      let idx = instr.imm1.int
      if idx < 0 or idx >= fn.localTypes.len:
        trap("local.get/i32.store index out of range")
      let value = vm.pop(sp)
      let ea = vm.modules[moduleIdx].effectiveOffset(vm.locals[idx], instr.imm2, 4)
      vm.modules[moduleIdx].storeU32(ea, value)
    of opF32Store:
      let value = vm.pop(sp)
      let base = vm.pop(sp)
      let ea = vm.modules[moduleIdx].effectiveOffset(base, instr.imm1, 4)
      vm.modules[moduleIdx].storeU32(ea, value)
    of opI32Store8:
      let value = vm.pop(sp)
      let base = vm.pop(sp)
      let ea = vm.modules[moduleIdx].effectiveOffset(base, instr.imm1, 1)
      vm.modules[moduleIdx].storeByte(ea, byte(value and 0xFF))
    of opI32Store16:
      let value = vm.pop(sp)
      let base = vm.pop(sp)
      let ea = vm.modules[moduleIdx].effectiveOffset(base, instr.imm1, 2)
      vm.modules[moduleIdx].storeU16(ea, value)
    of opMemorySize:
      if instr.imm1 != 0:
        trap("only memory 0 is supported by compact runtime")
      vm.push(vm.modules[moduleIdx].memoryPages, sp)
    of opMemoryGrow:
      if instr.imm1 != 0:
        trap("only memory 0 is supported by compact runtime")
      let delta = vm.pop(sp)
      let oldPages = vm.modules[moduleIdx].memoryPages
      let newPages = oldPages + delta
      if cast[int32](delta) < 0 or newPages < oldPages or
          (vm.modules[moduleIdx].memoryHasMax and newPages > vm.modules[moduleIdx].memoryMax):
        vm.push(0xFFFF_FFFF'u32, sp)
      else:
        vm.modules[moduleIdx].memoryPages = newPages
        vm.push(oldPages, sp)
    of opF32Add:
      let b = vm.pop(sp)
      let a = vm.pop(sp)
      vm.push(f32Add(a, b), sp)
    of opF32Sub:
      let b = vm.pop(sp)
      let a = vm.pop(sp)
      vm.push(f32Sub(a, b), sp)
    of opF32Mul:
      let b = vm.pop(sp)
      let a = vm.pop(sp)
      vm.push(f32Mul(a, b), sp)
    of opF32Min:
      let b = vm.pop(sp)
      let a = vm.pop(sp)
      vm.push(f32Min(a, b), sp)
    of opF32Max:
      let b = vm.pop(sp)
      let a = vm.pop(sp)
      vm.push(f32Max(a, b), sp)
    of opF32Copysign:
      let b = vm.pop(sp)
      let a = vm.pop(sp)
      vm.push(f32Copysign(a, b), sp)
    of opF32Abs:
      vm.push(f32Abs(vm.pop(sp)), sp)
    of opF32Neg:
      vm.push(f32Neg(vm.pop(sp)), sp)
    of opF32Eq:
      let b = vm.pop(sp)
      let a = vm.pop(sp)
      vm.push(if f32Eq(a, b): 1'u32 else: 0'u32, sp)
    of opF32Ne:
      let b = vm.pop(sp)
      let a = vm.pop(sp)
      vm.push(if not f32Eq(a, b): 1'u32 else: 0'u32, sp)
    of opF32Lt:
      let b = vm.pop(sp)
      let a = vm.pop(sp)
      vm.push(if f32Lt(a, b): 1'u32 else: 0'u32, sp)
    of opF32Gt:
      let b = vm.pop(sp)
      let a = vm.pop(sp)
      vm.push(if f32Lt(b, a): 1'u32 else: 0'u32, sp)
    of opF32Le:
      let b = vm.pop(sp)
      let a = vm.pop(sp)
      vm.push(if f32Le(a, b): 1'u32 else: 0'u32, sp)
    of opF32Ge:
      let b = vm.pop(sp)
      let a = vm.pop(sp)
      vm.push(if f32Le(b, a): 1'u32 else: 0'u32, sp)
    of opF32ConvertI32S:
      vm.push(i32ToF32(cast[int32](vm.pop(sp))), sp)
    of opF32ConvertI32U:
      vm.push(u32ToF32(vm.pop(sp)), sp)
    of opI32ReinterpretF32, opF32ReinterpretI32:
      discard
    of opDrop:
      discard vm.pop(sp)
    of opReturn:
      break
    of opEnd:
      if pc == expr.code.len - 1:
        break
      popCompletedCompactLabel(labels, labelCount, pc)
    else:
      trap("unsupported opcode in integer-only runtime: " & $instr.op)
    intRuntimeStage(0x57538000'u32 or (uint32(funcIdx and 0xF) shl 8) or uint32(pc and 0xFF))
    inc pc

  if fn.funcType.results.len == 0:
    return 0
  if fn.funcType.results.len != 1:
    trap("unsupported multi-value result")
  if sp != 1:
    trap("unexpected operand stack height")
  cast[int32](vm.pop(sp))

proc invokeI32*(vm: var IntWasmVM, moduleIdx: int, name: string,
                args: openArray[int32]): int32 =
  if moduleIdx < 0 or moduleIdx >= vm.modules.len:
    trap("module index out of range")
  let inst = addr vm.modules[moduleIdx]
  for i in 0 ..< inst.exports.len:
    if inst.exports[i].name == name:
      if inst.exports[i].kind != ekFunc:
        trap("export is not a function")
      return vm.executeInt(moduleIdx, inst.exports[i].idx.int, args)
  trap("export not found: " & name)

proc taskPush(task: var IntWasmTask, value: uint32) {.inline.} =
  if task.sp >= task.stack.len:
    task.stack.setLen(task.stack.len * 2)
  task.stack[task.sp] = value
  inc task.sp

proc taskPop(task: var IntWasmTask): uint32 {.inline.} =
  if task.sp <= 0:
    trap("task operand stack underflow")
  dec task.sp
  task.stack[task.sp]

proc findExportedFunc(vm: var IntWasmVM, moduleIdx: int, name: string): int =
  if moduleIdx < 0 or moduleIdx >= vm.modules.len:
    trap("module index out of range")
  let inst = addr vm.modules[moduleIdx]
  for i in 0 ..< inst.exports.len:
    if inst.exports[i].name == name:
      if inst.exports[i].kind != ekFunc:
        trap("export is not a function")
      return inst.exports[i].idx.int
  trap("export not found: " & name)

proc initIntWasmTaskI32*(vm: var IntWasmVM, moduleIdx: int, name: string,
                         args: openArray[int32]): IntWasmTask =
  ## Create a resumable compact WASM task. The task owns PC, operand stack,
  ## locals, and label stack so the scheduler can resume it after a fuel yield.
  let funcIdx = vm.findExportedFunc(moduleIdx, name)
  let inst = addr vm.modules[moduleIdx]
  if funcIdx < 0 or funcIdx >= inst.funcs.len:
    trap("function index out of range")
  let fn = addr inst.funcs[funcIdx]
  if not fn.hasCode:
    trap("missing function body")
  if fn.funcType.params.len != args.len:
    trap("argument count mismatch")
  if fn.funcType.results.len > 1:
    trap("task runtime does not support multi-value results")

  result.moduleIdx = moduleIdx
  result.funcIdx = funcIdx
  result.state = intTaskReady
  result.expr =
    if fn.codeIsFlash:
      decodeFlashExpr(inst.image, fn.flashCodeOffset, fn.flashCodeLen)
    else:
      fn.code
  result.resultCount = fn.funcType.results.len
  result.locals = newSeq[uint32](max(fn.localTypes.len, 1))
  for i in 0 ..< args.len:
    result.locals[i] = cast[uint32](args[i])
  for i in args.len ..< fn.localTypes.len:
    result.locals[i] = 0
  result.stack = newSeq[uint32](64)

proc finishTask(task: var IntWasmTask) =
  if task.resultCount == 0:
    task.result = 0
    task.state = intTaskExited
    return
  if task.resultCount != 1:
    trap("task runtime does not support multi-value results")
  if task.sp != 1:
    trap("unexpected task operand stack height")
  task.result = cast[int32](taskPop(task))
  task.state = intTaskExited

proc resumeTaskCore(vm: var IntWasmVM, task: var IntWasmTask,
                    fuel: uint32): IntWasmTaskState =
  if task.state == intTaskExited or task.state == intTaskTrapped:
    return task.state
  if fuel == 0:
    task.state = intTaskYielded
    return task.state
  if task.moduleIdx < 0 or task.moduleIdx >= vm.modules.len:
    trap("task module index out of range")
  task.state = intTaskRunning
  var remaining = fuel

  while task.pc < task.expr.code.len:
    if remaining == 0:
      task.state = intTaskYielded
      return task.state
    dec remaining

    let instr = task.expr.code[task.pc]
    case instr.op
    of opUnreachable:
      trap("unreachable executed")
    of opNop:
      discard
    of opBlock:
      if instr.imm1.int < task.pc or instr.imm1.int >= task.expr.code.len:
        trap("block end out of range")
      pushCompactLabel(task.labels, task.labelCount, instr.imm1.int + 1,
                       task.sp, false)
    of opLoop:
      if instr.imm1.int < task.pc or instr.imm1.int >= task.expr.code.len:
        trap("loop end out of range")
      pushCompactLabel(task.labels, task.labelCount, task.pc + 1, task.sp, true)
    of opIf:
      let cond = taskPop(task)
      if instr.imm1.int < task.pc or instr.imm1.int >= task.expr.code.len:
        trap("if end out of range")
      if cond == 0:
        let target = instr.imm2.int
        if target < 0 or target >= task.expr.code.len:
          trap("if target out of range")
        if instr.imm2 != instr.imm1:
          pushCompactLabel(task.labels, task.labelCount, instr.imm1.int + 1,
                           task.sp, false)
        task.pc = target + 1
        continue
      else:
        pushCompactLabel(task.labels, task.labelCount, instr.imm1.int + 1,
                         task.sp, false)
    of opElse:
      if task.labelCount != 0:
        dec task.labelCount
      task.pc = findMatchingEnd(task.expr.code, task.pc) + 1
      continue
    of opBr:
      task.pc = compactBranchTo(task.labels, task.labelCount, instr.imm1, task.sp)
      continue
    of opBrIf:
      if taskPop(task) != 0:
        task.pc = compactBranchTo(task.labels, task.labelCount, instr.imm1, task.sp)
        continue
    of opI32EqzBrIf:
      if taskPop(task) == 0:
        task.pc = compactBranchTo(task.labels, task.labelCount, instr.imm1, task.sp)
        continue
    of opI32EqBrIf:
      let b = taskPop(task)
      let a = taskPop(task)
      if a == b:
        task.pc = compactBranchTo(task.labels, task.labelCount, instr.imm1, task.sp)
        continue
    of opI32NeBrIf:
      let b = taskPop(task)
      let a = taskPop(task)
      if a != b:
        task.pc = compactBranchTo(task.labels, task.labelCount, instr.imm1, task.sp)
        continue
    of opI32GeSBrIf:
      let b = cast[int32](taskPop(task))
      let a = cast[int32](taskPop(task))
      if a >= b:
        task.pc = compactBranchTo(task.labels, task.labelCount, instr.imm1, task.sp)
        continue
    of opI32LtSBrIf:
      let b = cast[int32](taskPop(task))
      let a = cast[int32](taskPop(task))
      if a < b:
        task.pc = compactBranchTo(task.labels, task.labelCount, instr.imm1, task.sp)
        continue
    of opI32ConstI32GeSBrIf:
      let a = cast[int32](taskPop(task))
      if a >= cast[int32](instr.imm1):
        task.pc = compactBranchTo(task.labels, task.labelCount, instr.imm2, task.sp)
        continue
    of opI32ConstI32LtSBrIf:
      let a = cast[int32](taskPop(task))
      if a < cast[int32](instr.imm1):
        task.pc = compactBranchTo(task.labels, task.labelCount, instr.imm2, task.sp)
        continue
    of opCall:
      let calleeIdx = instr.imm1.int
      if calleeIdx < 0 or calleeIdx >= vm.modules[task.moduleIdx].funcs.len:
        trap("call function index out of range")
      let callee = addr vm.modules[task.moduleIdx].funcs[calleeIdx]
      if callee.funcType.results.len > 1:
        trap("unsupported multi-value call result")
      let paramCount = callee.funcType.params.len
      var callArgs = newSeq[int32](paramCount)
      if paramCount > 0:
        for i in countdown(paramCount - 1, 0):
          callArgs[i] = cast[int32](taskPop(task))
      let callResult = vm.executeInt(task.moduleIdx, calleeIdx, callArgs)
      if callee.funcType.results.len == 1:
        taskPush(task, cast[uint32](callResult))
    of opI32Const, opF32Const:
      taskPush(task, instr.imm1)
    of opLocalGet:
      let idx = instr.imm1.int
      if idx < 0 or idx >= task.locals.len:
        trap("local.get index out of range")
      taskPush(task, task.locals[idx])
    of opLocalSet:
      let idx = instr.imm1.int
      if idx < 0 or idx >= task.locals.len:
        trap("local.set index out of range")
      task.locals[idx] = taskPop(task)
    of opLocalTee:
      let idx = instr.imm1.int
      if idx < 0 or idx >= task.locals.len:
        trap("local.tee index out of range")
      let value = taskPop(task)
      task.locals[idx] = value
      taskPush(task, value)
    of opLocalSetLocalGet:
      let setIdx = instr.imm1.int
      let getIdx = instr.imm2.int
      if setIdx < 0 or setIdx >= task.locals.len or
          getIdx < 0 or getIdx >= task.locals.len:
        trap("local.set/local.get index out of range")
      task.locals[setIdx] = taskPop(task)
      taskPush(task, task.locals[getIdx])
    of opLocalGetLocalGet:
      let aIdx = instr.imm1.int
      let bIdx = instr.imm2.int
      if aIdx < 0 or aIdx >= task.locals.len or
          bIdx < 0 or bIdx >= task.locals.len:
        trap("local.get/local.get index out of range")
      taskPush(task, task.locals[aIdx])
      taskPush(task, task.locals[bIdx])
    of opLocalGetLocalGetI32Add:
      let aIdx = instr.imm1.int
      let bIdx = instr.imm2.int
      if aIdx < 0 or aIdx >= task.locals.len or
          bIdx < 0 or bIdx >= task.locals.len:
        trap("local.get/local.get/i32.add index out of range")
      taskPush(task, task.locals[aIdx] + task.locals[bIdx])
    of opLocalGetLocalGetI32Sub:
      let aIdx = instr.imm1.int
      let bIdx = instr.imm2.int
      if aIdx < 0 or aIdx >= task.locals.len or
          bIdx < 0 or bIdx >= task.locals.len:
        trap("local.get/local.get/i32.sub index out of range")
      taskPush(task, task.locals[aIdx] - task.locals[bIdx])
    of opI32AddLocalSet:
      let idx = instr.imm1.int
      if idx < 0 or idx >= task.locals.len:
        trap("i32.add/local.set index out of range")
      let b = taskPop(task)
      let a = taskPop(task)
      task.locals[idx] = a + b
    of opI32SubLocalSet:
      let idx = instr.imm1.int
      if idx < 0 or idx >= task.locals.len:
        trap("i32.sub/local.set index out of range")
      let b = taskPop(task)
      let a = taskPop(task)
      task.locals[idx] = a - b
    of opLocalI32AddInPlace:
      let idx = instr.imm1.int
      if idx < 0 or idx >= task.locals.len:
        trap("local i32 add-in-place index out of range")
      task.locals[idx] = cast[uint32](cast[int32](task.locals[idx]) + cast[int32](instr.imm2))
    of opLocalI32SubInPlace:
      let idx = instr.imm1.int
      if idx < 0 or idx >= task.locals.len:
        trap("local i32 sub-in-place index out of range")
      task.locals[idx] = cast[uint32](cast[int32](task.locals[idx]) - cast[int32](instr.imm2))
    of opLocalGetLocalGetI32AddLocalSet:
      let x = int(instr.imm1 and 0xFFFF'u32)
      let y = int(instr.imm1 shr 16)
      let z = instr.imm2.int
      if x < 0 or x >= task.locals.len or y < 0 or y >= task.locals.len or
          z < 0 or z >= task.locals.len:
        trap("local.get/local.get/i32.add/local.set index out of range")
      task.locals[z] = task.locals[x] + task.locals[y]
    of opI32ConstI32Add:
      taskPush(task, taskPop(task) + instr.imm1)
    of opI32ConstI32Sub:
      taskPush(task, taskPop(task) - instr.imm1)
    of opLocalGetI32ConstI32Add:
      let idx = instr.imm1.int
      if idx < 0 or idx >= task.locals.len:
        trap("local.get/i32.const/i32.add index out of range")
      taskPush(task, task.locals[idx] + instr.imm2)
    of opLocalGetI32ConstI32Sub:
      let idx = instr.imm1.int
      if idx < 0 or idx >= task.locals.len:
        trap("local.get/i32.const/i32.sub index out of range")
      taskPush(task, task.locals[idx] - instr.imm2)
    of opI32Add:
      let b = taskPop(task)
      let a = taskPop(task)
      taskPush(task, a + b)
    of opI32Sub:
      let b = taskPop(task)
      let a = taskPop(task)
      taskPush(task, a - b)
    of opI32Mul:
      let b = taskPop(task)
      let a = taskPop(task)
      taskPush(task, a * b)
    of opI32Eqz:
      taskPush(task, if taskPop(task) == 0: 1'u32 else: 0'u32)
    of opI32Eq:
      let b = taskPop(task)
      let a = taskPop(task)
      taskPush(task, if a == b: 1'u32 else: 0'u32)
    of opI32Ne:
      let b = taskPop(task)
      let a = taskPop(task)
      taskPush(task, if a != b: 1'u32 else: 0'u32)
    of opI32GeS:
      let b = cast[int32](taskPop(task))
      let a = cast[int32](taskPop(task))
      taskPush(task, if a >= b: 1'u32 else: 0'u32)
    of opI32LtS:
      let b = cast[int32](taskPop(task))
      let a = cast[int32](taskPop(task))
      taskPush(task, if a < b: 1'u32 else: 0'u32)
    of opDrop:
      discard taskPop(task)
    of opReturn:
      finishTask(task)
      return task.state
    of opEnd:
      if task.pc == task.expr.code.len - 1:
        finishTask(task)
        return task.state
      popCompletedCompactLabel(task.labels, task.labelCount, task.pc)
    else:
      trap("unsupported opcode in task runtime: " & $instr.op)

    inc task.pc

  finishTask(task)
  task.state

proc resumeIntWasmTask*(vm: var IntWasmVM, task: var IntWasmTask,
                        fuel: uint32): IntWasmTaskState =
  try:
    result = vm.resumeTaskCore(task, fuel)
  except CatchableError:
    task.state = intTaskTrapped
    task.trapCode = 1
    result = task.state
