## General WASM validation regressions used by the full-proof frontend.
import std/unittest
import cps/wasm/[types, binary, validate]
import cps/zk/wasm_validation_witness
import cps/zk/wasm_trace_check
import bl808/enclave/sha256

proc single(code: openArray[byte], results: seq[ValType] = @[],
            optimize = false): WasmModule =
  result.startFunc = -1
  result.dataCount = -1
  result.types = @[FuncType(params: @[], results: results)]
  result.funcTypeIdxs = @[0'u32]
  result.codes = @[FuncBody(code: decodeExprBytes(code, optimize = optimize))]

proc leb(value: int): seq[byte] =
  var n = value
  while true:
    let b = byte(n and 127)
    n = n shr 7
    result.add(b or (if n == 0: 0'u8 else: 128'u8))
    if n == 0: break

proc section(bytes: var seq[byte], kind: byte, payload: seq[byte]) =
  bytes.add kind
  bytes.add leb(payload.len)
  bytes.add payload

proc generalModule(): seq[byte] =
  result = @[0'u8, 0x61, 0x73, 0x6d, 1, 0, 0, 0]
  result.section(1, @[2'u8, 0x60, 0, 1, 0x7f, 0x60, 0, 1, 0x7e])
  result.section(3, @[2'u8, 0, 1])
  result.section(5, @[1'u8, 0, 1])
  var first = @[0'u8, 0x03, 0x40, 0x41, 0, 0x0d, 0, 0x0b,
    0x41, 0, 0x28, 2, 0, 0x0b]
  var second = @[1'u8, 1, 0x7e]
  for _ in 0..<256: second.add 1'u8
  second.add @[0x10'u8, 0, 0x1a, 0x20, 0, 0x0b]
  var payload = @[2'u8]
  payload.add leb(first.len)
  payload.add first
  payload.add leb(second.len)
  payload.add second
  result.section(10, payload)

proc checkEventHeights(events: seq[ValidationEvent]) =
  var operands, controls: int
  for event in events:
    case event.kind
    of veFunctionBegin:
      check operands == 0 and controls == 0
    of veOperandPush:
      inc operands
    of veOperandPop:
      if event.polymorphic:
        check event.valueType == svUnknown
      else:
        dec operands
    of veControlPush: inc controls
    of veControlPop: dec controls
    of veUnreachable:
      check event.operandHeight <= operands
      operands = event.operandHeight
    of veFunctionEnd:
      check operands == 0 and controls == 0
    else: discard
    check event.operandHeight == operands
    check event.controlHeight == controls

proc copyEvents(events: seq[ValidationEvent]): seq[ValidationEvent] =
  for event in events: result.add event

suite "general WASM validation":
  test "function results and unreachable stack discipline":
    validateModule(single([0x41'u8, 1, 0x0b], @[vtI32]))
    validateModule(single([0'u8, 0x0b], @[vtI32]))
    expect ValidationError: validateModule(single([0x0b'u8], @[vtI32]))
    expect ValidationError: validateModule(single([0x41'u8, 1, 0x41, 2, 0x0b], @[vtI32]))
    expect ValidationError: validateModule(single([0'u8, 0x41, 1, 0x0b]))

  test "if with and without else":
    validateModule(single([0x41'u8, 1, 0x04, 0x40, 0x01, 0x0b, 0x0b]))
    validateModule(single([0x41'u8, 1, 0x04, 0x7f, 0x41, 2, 0x05, 0x41, 3, 0x0b, 0x0b], @[vtI32]))
    expect ValidationError:
      validateModule(single([0x41'u8, 1, 0x04, 0x7f, 0x41, 2, 0x0b, 0x0b], @[vtI32]))

  test "branch table validates values, depths and arities":
    validateModule(single([0x02'u8, 0x7f, 0x41, 7, 0x41, 0, 0x0e, 0, 0, 0x0b, 0x0b], @[vtI32]))
    expect ValidationError:
      validateModule(single([0x02'u8, 0x7f, 0x41, 0, 0x0e, 0, 0, 0x0b, 0x0b], @[vtI32]))
    expect ValidationError:
      validateModule(single([0x02'u8, 0x40, 0x41, 0, 0x0e, 0, 2, 0x0b, 0x0b]))
    expect ValidationError:
      validateModule(single([0x02'u8, 0x40, 0x02, 0x7f, 0x41, 5, 0x41, 0,
        0x0e, 1, 0, 1, 0x0b, 0x1a, 0x0b, 0x0b]))
    expect ValidationError:
      validateModule(single([0x02'u8, 0x7f, 0x02, 0x7e, 0x42, 5, 0x41, 0,
        0x0e, 1, 1, 0, 0x0b, 0x1a, 0x41, 0, 0x0b, 0x0b], @[vtI32]))
    var bad = single([0x41'u8, 0, 0x0e, 0, 0, 0x0b])
    bad.codes[0].code.code[1].imm1 = 99
    expect ValidationError: validateModule(bad)

  test "optimized conditional branches preserve label and operand validation":
    let branch = [0x02'u8, 0x7f, 0x41, 7, 0x41, 0, 0x41, 1,
      0x49, 0x0d, 0, 0x0b, 0x0b]
    let valid = single(branch, @[vtI32], optimize = true)
    check valid.codes[0].code.code[^2].op == opI32LtUBrIf
    validateModule(valid)
    var invalid = branch
    invalid[10] = 2   # branch depth
    expect ValidationError: validateModule(single(invalid, @[vtI32], optimize = true))
    invalid = branch
    invalid[2] = 0x42 # wrong type for the branch value
    expect ValidationError: validateModule(single(invalid, @[vtI32], optimize = true))
    invalid = branch
    invalid[4] = 0x42 # wrong type for the comparison
    expect ValidationError: validateModule(single(invalid, @[vtI32], optimize = true))

  test "typed select retains and checks its declared type":
    let parsed = single([0x41'u8, 1, 0x41, 2, 0x41, 0, 0x1c, 1, 0x7f, 0x0b], @[vtI32])
    check parsed.codes[0].code.code[^1].imm1 == uint32(ord(vtI32))
    validateModule(parsed)
    expect ValidationError:
      validateModule(single([0x41'u8, 1, 0x41, 2, 0x41, 0, 0x1c, 1, 0x7e, 0x0b], @[vtI32]))
    expect WasmDecodeError: discard single([0x1c'u8, 0, 0x0b])
    expect WasmDecodeError: discard single([0x1c'u8, 2, 0x7f, 0x7f, 0x0b])
    validateModule(single([0xd0'u8, 0x70, 0xd0, 0x70, 0x41, 0, 0x1c, 1, 0x70, 0x0b], @[vtFuncRef]))
    expect ValidationError:
      validateModule(single([0xd0'u8, 0x70, 0xd0, 0x70, 0x41, 0, 0x1b, 0x0b], @[vtFuncRef]))

  test "indirect call keeps distinct type and table indices":
    var module = single([0x41'u8, 3, 0x41, 0, 0x11, 1, 0, 0x0b], @[vtI64])
    module.types.add FuncType(params: @[vtI32], results: @[vtI64])
    module.tables = @[TableType(elemType: vtFuncRef, limits: Limits(min: 1))]
    validateModule(module)
    module.codes[0].code.code[^1].imm1 = 2
    expect ValidationError: validateModule(module)
    module.codes[0].code.code[^1].imm1 = 1
    module.codes[0].code.code[^1].imm2 = 1
    expect ValidationError: validateModule(module)
    module.codes[0].code.code[^1].imm2 = 0
    module.tables[0].elemType = vtExternRef
    expect ValidationError: validateModule(module)

  test "structural module and decoded-body checks":
    var missing = single([0x0b'u8])
    missing.codes.setLen(0)
    expect ValidationError: validateModule(missing)
    var extra = single([0x0b'u8])
    extra.codes.add(extra.codes[0])
    expect ValidationError: validateModule(extra)
    var nested = single([0x0b'u8])
    nested.codes[0].code.code = @[Instr(op: opBlock, pad: 0x40)]
    expect ValidationError: validateModule(nested)
    var ended = single([0x0b'u8])
    ended.codes[0].code.code = @[Instr(op: opEnd), Instr(op: opNop)]
    expect ValidationError: validateModule(ended)
    var start = single([0x41'u8, 0, 0x0b], @[vtI32])
    start.startFunc = 0
    expect ValidationError: validateModule(start)
    start = single([0x0b'u8])
    start.startFunc = 0
    validateModule(start)

  test "general witness keeps functions, control flow, memory and i64":
    var bytes = generalModule()
    let witness = buildFullValidationWitness(bytes)
    check witness.bytes.len > 156
    check witness.module.codes.len == 2
    check witness.module.memories.len == 1
    check witness.module.codes[1].locals[0].valType == vtI64
    check witness.moduleDigest == sha256(bytes)
    checkEventHeights(witness.events)
    check checkValidationTraceStructure(witness.module, witness.events).accepted
    var functions, instructions, loops, calls, loads: int
    for event in witness.events:
      if event.kind == veFunctionEnd: inc functions
      if event.kind == veInstructionBegin:
        inc instructions
        case event.opcode
        of opLoop: inc loops
        of opCall: inc calls
        of opI32Load: inc loads
        else: discard
    check functions == 2
    check instructions > 256
    check loops == 1 and calls == 1 and loads == 1
    bytes[0] = 255
    check witness.bytes[0] == 0
    check witness.moduleDigest == sha256(witness.bytes)

  test "invalid general modules do not yield witnesses":
    var bytes = generalModule()
    bytes[0] = 255
    expect WasmDecodeError: discard buildFullValidationWitness(bytes)

  test "independent trace replay rejects changed events":
    let witness = buildFullValidationWitness(generalModule())
    for index, event in witness.events:
      var changed = copyEvents(witness.events)
      changed[index].operandHeight += 1
      check not checkValidationTraceStructure(witness.module, changed).accepted
      changed = copyEvents(witness.events)
      changed[index].controlHeight += 1
      check not checkValidationTraceStructure(witness.module, changed).accepted
      changed = copyEvents(witness.events)
      changed[index].functionIndex += 1
      check not checkValidationTraceStructure(witness.module, changed).accepted
      changed = copyEvents(witness.events)
      changed[index].instructionIndex += 1
      check not checkValidationTraceStructure(witness.module, changed).accepted
      if event.kind == veOperandPop and not event.polymorphic:
        changed = copyEvents(witness.events)
        changed[index].valueType = if event.valueType == svI32: svI64 else: svI32
        check not checkValidationTraceStructure(witness.module, changed).accepted
    var truncated = copyEvents(witness.events)
    truncated.setLen(truncated.len-1)
    check checkValidationTraceStructure(witness.module, truncated).error == teIncomplete

  test "trace frame binding and polymorphic stack replay":
    for module in [
        single([0'u8, 0x0b], @[vtI32]),
        single([0x41'u8, 1, 0x04, 0x7f, 0x41, 2, 0x05, 0x41, 3, 0x0b, 0x0b], @[vtI32]),
        single([0x02'u8, 0x7f, 0x41, 7, 0x41, 0, 0x0e, 0, 0, 0x0b, 0x0b], @[vtI32])]:
      let events = traceModuleValidation(module)
      check checkValidationTraceStructure(module, events).accepted
      var changed = copyEvents(events)
      changed[1].endTypes = @[svF64]
      check not checkValidationTraceStructure(module, changed).accepted

  test "unhandled opcodes cannot become proof witnesses":
    var module = single([0x0b'u8])
    module.codes[0].code.code = @[Instr(op: opLocalI32AddInPlace)]
    let events = traceModuleValidation(module)
    check checkValidationTraceStructure(module, events).error == teUnsupported

  test "unsupported SIMD encodings and tag attributes cannot disappear":
    for optimize in [false, true]:
      for bytes in [@[0xfd'u8, 127, 0x0b], @[0xfd'u8, 0xff, 0xff, 3, 0x0b],
          @[0xfd'u8, 1, 0, 0, 0x0b]]:
        expect WasmDecodeError: discard decodeExprBytes(bytes, optimize)
    let base = @[0'u8, 97, 115, 109, 1, 0, 0, 0, 1, 4, 1, 0x60, 0, 0, 3, 2, 1, 0]
    expect WasmDecodeError:
      discard buildFullValidationWitness(base & @[10'u8, 6, 1, 4, 0, 0xfd, 127, 0x0b])
    expect WasmDecodeError:
      discard decodeModule(base & @[13'u8, 3, 1, 1, 0, 10, 4, 1, 2, 0, 0x0b], optimize = false)
    # Implemented SIMD opcodes remain visible to the validator and trace.
    let implemented = single([0'u8, 0xfd, 77, 0x1a, 0x0b])
    check implemented.codes[0].code.code[1].op == opV128Not
    validateModule(implemented)

  test "throws check tag existence, payloads, and result-free signatures":
    var empty = single([8'u8, 0, 0x0b])
    empty.tagDefs = @[WasmTagDef(typeIdx: 0)]
    validateModule(empty)
    expect ValidationError: validateModule(single([8'u8, 0, 0x0b]))
    var payload = single([0x41'u8, 7, 8, 0, 0x0b])
    payload.types.add FuncType(params: @[vtI32])
    payload.tagDefs = @[WasmTagDef(typeIdx: 1)]
    let events = traceModuleValidation(payload)
    check checkValidationTraceStructure(payload, events).accepted
    var wrongPayload = payload
    wrongPayload.codes[0].code.code[0].op = opI64Const
    expect ValidationError: validateModule(wrongPayload)
    var missingPayload = payload
    missingPayload.codes[0].code.code.delete(0)
    expect ValidationError: validateModule(missingPayload)
    var resultful = payload
    resultful.types[1].results = @[vtI32]
    expect ValidationError: validateModule(resultful)
    var unknownType = payload
    unknownType.tagDefs[0].typeIdx = high(uint32)
    expect ValidationError: validateModule(unknownType)
    var wrongTag = payload
    wrongTag.codes[0].code.code[^1].imm1 = high(uint32)
    expect ValidationError: validateModule(wrongTag)
    # An unused invalid tag is also a module validation error.
    var unused = single([0x0b'u8])
    unused.tagDefs = @[WasmTagDef(typeIdx: high(uint32))]
    expect ValidationError: validateModule(unused)

  test "tag import types and exported tag indices are validated":
    let headerAndType = @[0'u8, 97, 115, 109, 1, 0, 0, 0, 1, 4, 1, 0x60, 0, 0]
    let tagImport = @[2'u8, 8, 1, 1, byte('m'), 1, byte('t'), 4, 0, 0]
    let tagExport = @[7'u8, 5, 1, 1, byte('t'), 4, 0]
    let valid = decodeModule(headerAndType & tagImport & tagExport, optimize = false)
    validateModule(valid)
    var invalid = valid
    invalid.imports[0].tagTypeIdx = 1
    expect ValidationError: validateModule(invalid)
    invalid = valid
    invalid.types[0].results = @[vtI32]
    expect ValidationError: validateModule(invalid)
    invalid = valid
    invalid.exports[0].idx = 1
    expect ValidationError: validateModule(invalid)
    var wrongAttribute = tagImport
    wrongAttribute[^2] = 1
    expect WasmDecodeError:
      discard decodeModule(headerAndType & wrongAttribute, optimize = false)

  test "SIMD signatures, lanes, constants, and memory alignment":
    var constant = @[0xfd'u8, 12]
    constant.add newSeq[byte](16)
    var valid = constant & @[0xfd'u8, 27, 3, 0x0b]
    let module = single(valid, @[vtI32])
    check checkValidationTraceStructure(module, traceModuleValidation(module)).accepted
    expect ValidationError: validateModule(single(constant & @[0xfd'u8, 27, 4, 0x0b], @[vtI32]))
    expect ValidationError: validateModule(single([0x41'u8, 0, 0xfd, 77, 0x0b], @[vtV128]))
    var badPool = single(constant & @[0x0b'u8], @[vtV128])
    badPool.codes[0].code.code[0].imm1 = 1
    expect ValidationError: validateModule(badPool)
    var load = single([0x41'u8, 0, 0xfd, 0, 4, 0, 0x0b], @[vtV128])
    expect ValidationError: validateModule(load)
    load.memories = @[MemType(limits: Limits(min: 1))]
    validateModule(load)
    load.codes[0].code.code[1].imm1 = 5
    expect ValidationError: validateModule(load)
    expect ValidationError: validateModule(single([0xd0'u8, 0x7f, 0x0b], @[vtFuncRef]))
