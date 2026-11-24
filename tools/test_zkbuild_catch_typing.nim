import std/[os, strutils]
import cps/wasm/[types, validate]
import cps/zk/[r1cs, prover, wasm_instruction_events, wasm_catch_environment, wasm_validation_witness]
import zkbuild_catch_test_helpers
import test_wasm_catch_typing
import test_wasm_catch_oracle

proc require(ok: bool, message: string) =
  if not ok: raise newException(ValueError, message)

proc forged(module: WasmModule, rows: seq[InstructionEventRow], environment: CatchEnvironment, message: string) =
  require(fullCatch(module, rows, environment, false).satisfied(), message & " preceding partial relation")
  require(not fullCatch(module, rows, environment).satisfied(), message)

proc main() =
  var cases, forgeries, oracleCases: int
  if paramCount() == 1:
    let lines = readFile(paramStr(1)).splitLines()
    require(lines[0] == "ZKCATCH1 7560", "catch circuit oracle header")
    var lineNumber = 0
    for line in lines[1..^1]:
      if line.len == 0: continue
      if lineNumber mod 127 == 0:
        var v: seq[int]
        for item in line.splitWhitespace(): v.add parseInt(item)
        if v[0] < 4:
          let rows = catchRows(caseModule(v, skeleton = true), 64)
          let module = caseModule(v)
          let accepted = fullCatch(module, rows, buildCatchEnvironment(module)).satisfied()
          require(accepted == (v[6] == 1 and v[5] != 2), "R1CS/Lean catch case " & line)
          inc oracleCases
      inc lineNumber
    require(lineNumber == 7560 and oracleCases == 48, "catch circuit oracle coverage")
  for params in [newSeq[ValType](), @[vtI32, vtI64], @[vtF32, vtF64, vtV128], @[vtFuncRef, vtExternRef]]:
    for kind in [ckCatch, ckCatchRef, ckCatchAll, ckCatchAllRef]:
      for loop in [false, true]:
        let module = fixture(params, kind, loop)
        require(fullCatch(module, catchRows(module), buildCatchEnvironment(module)).satisfied(), "valid composed catch clause")
        inc cases
  block:
    var module = fixture(@[])
    module.codes[0].code.catchTables[0] = @[]
    require(fullCatch(module, catchRows(module), buildCatchEnvironment(module)).satisfied(), "empty catch list")
    inc cases
  block:
    var module = fixture(@[vtI32])
    module.codes[0].code.catchTables[0].add CatchClause(kind: ckCatch)
    module.imports = @[Import(kind: ikFunc, funcTypeIdx: 0)]
    require(fullCatch(module, catchRows(module), buildCatchEnvironment(module)).satisfied(), "shared catch list/imported function namespace")
    inc cases
  block:
    var module = fixture(@[vtI32])
    module.codes[0].code.code = @[Instr(op: opUnreachable), Instr(op: opI32Const), Instr(op: opBrTable)] & module.codes[0].code.code
    module.codes[0].code.brTables = @[BrTableData(defaultLabel: 0)]
    require(fullCatch(module, catchRows(module), buildCatchEnvironment(module)).satisfied(), "branch and catch markers compose")
    inc cases
  for mutation in 0..4:
    var module = fixture(@[vtI32])
    let rows = catchRows(module)
    case mutation
    of 0: module.types[1].params = @[vtI64]
    of 1: module.codes[0].code.catchTables[0][0].kind = ckCatchRef
    of 2: module.codes[0].code.catchTables[0][0].tagIdx = high(uint32)
    of 3: module.codes[0].code.catchTables[0][0].labelDepth = 1
    else: module.codes[0].code.catchTables[0][0].kind = ckCatchAll
    forged(module, rows, buildCatchEnvironment(module), "catch payload/tag/type/outer target " & $mutation)
    inc forgeries
  block:
    let module = fixture(@[])
    let rows = catchRows(module)
    var omitted: seq[InstructionEventRow]
    for row in rows:
      if row.control.operand.kind != uint8(ord(veLabelCheck)): omitted.add row
    omitted.add rows[^1]
    require(not fullCatch(module, omitted, buildCatchEnvironment(module)).satisfied(), "zero-arity catch cannot be omitted")
    inc forgeries
  block:
    var module = fixture(@[])
    let rows = catchRows(module)
    module.codes[0].code.catchTables[0][0].labelDepth = high(uint32)
    require(not fullCatch(module, rows, buildCatchEnvironment(module)).satisfied(), "catch full-width invalid depth")
    inc forgeries
  # Ordinary binary fixtures keep one matrix across i32/i64 payloads/results.
  proc binary(valueType, constantOpcode: byte): seq[byte] =
    result = @[0'u8, 97, 115, 109, 1, 0, 0, 0, 1, 9, 2, 0x60, 0, 1, valueType,
      0x60, 1, valueType, 0, 3, 2, 1, 0, 13, 3, 1, 0, 1]
    let code = @[0'u8, 2, valueType, 0x1f, 0x40, 1, 0, 0, 0, constantOpcode, 42, 8, 0, 0x0b, 0, 0x0b, 0x0b]
    result.add @[10'u8, byte(code.len+2), 1, byte(code.len)]
    result.add code
  let aw = buildFullValidationWitness(binary(0x7f, 0x41), labelChecks = true, catchChecks = true)
  let bw = buildFullValidationWitness(binary(0x7e, 0x42), labelChecks = true, catchChecks = true)
  let a = fullCatch(aw.module, buildInstructionEventRows(aw.events, 32), buildCatchEnvironment(aw.module))
  let b = fullCatch(bw.module, buildInstructionEventRows(bw.events, 32), buildCatchEnvironment(bw.module))
  require(a.satisfied() and b.satisfied() and a.sameShape(b), "i32/i64 catch binary profile")
  let key = setup(a)
  for circuit in [a, b]:
    let proof = encodeProof(prove(key, circuit))
    require(proof.len == 192 and decodeAndVerify(key.verificationKey, proof,
      circuit.values[1..circuit.publicCount]), "catch Groth16 proof")
    for index in [0, circuit.publicCount div 2, circuit.publicCount-1]:
      var changed = circuit.values[1..circuit.publicCount]
      changed[index] = changed[index]+scalar(1)
      require(not decodeAndVerify(key.verificationKey, proof, changed), "catch public substitution")
  echo "zkbuild catch typing: PASS (", oracleCases, " Lean/R1CS comparisons; ", cases, " composed traces; ", forgeries,
    " context/type/zero-arity forgeries; ", a.constraints.len, " constraints/32 rows; QAP ",
    key.domainSize, "; two 192-byte proofs)"

main()
