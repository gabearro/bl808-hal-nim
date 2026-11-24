import std/[os, osproc, strutils]
import cps/wasm/[types, validate]
import cps/zk/[r1cs, prover, wasm_instruction_events, wasm_type_environment,
  wasm_signature_environment, wasm_indexed_signatures]
import zkbuild_parametric_test_helpers
import zkbuild_control_type_test_helpers
import zkbuild_parametric_plan_test_helpers

const Types = [vtI32, vtI64, vtF32, vtF64, vtV128, vtFuncRef, vtExternRef]
var planCases: seq[string]

proc require(ok: bool, message: string) =
  if not ok: raise newException(ValueError, message)

proc body(code: seq[Instr], params: seq[ValType] = @[]): WasmModule =
  WasmModule(startFunc: -1, dataCount: -1, types: @[FuncType(params: params)],
    funcTypeIdxs: @[0'u32], codes: @[FuncBody(code: Expr(code: code))])

proc check(module: WasmModule): Circuit =
  let events = traceModuleValidation(module)
  let rows = buildInstructionEventRows(events)
  planCases.add parametricPlanCases(module, events)
  result = buildParametric(rows, instructionImmediates(module, rows).p)
  require(result.satisfied(), "parametric valid trace")

proc reject(module: WasmModule, events: seq[ValidationEvent], message: string,
    immediate = -1) =
  let rows = buildInstructionEventRows(events)
  var p = instructionImmediates(module, rows).p
  if immediate >= 0:
    for i, row in rows:
      if row.control.operand.kind == uint8(ord(veInstructionBegin)) and
          row.opcode in [uint16(ord(opSelect)), uint16(ord(opSelectTyped)), uint16(ord(opRefNull))]:
        p[i] = uint32(immediate)
  require(buildParametric(rows, p, binding = false).satisfied(), message & " preceding partial relation")
  require(not buildParametric(rows, p).satisfied(), message)

proc checkPlans(checker, workDir: string): tuple[traces, finite: int] =
  createDir(workDir)
  let command = quoteShell(absolutePath(checker)) & " "
  proc run(path, contents: string, accepted, total: int) =
    writeFile(path, contents)
    let checked = execCmdEx(command & quoteShell(absolutePath(path)))
    require(checked.exitCode == ord(accepted != total) and
      checked.output.strip == "ZKPARAM1 " & $accepted & " " & $total, "Lean parametric plans: " & checked.output)
  run(workDir/"trace-plans.txt", planCases.join("\n") & "\n", planCases.len, planCases.len)
  for mutation in 0..2:
    var changed = @planCases
    var fields = changed[0].splitWhitespace()
    if mutation == 0: fields[3] = "1"
    elif mutation == 1:
      fields.delete(4)
      fields[2] = $(parseInt(fields[2])-1)
    else: fields[^1] = "21"
    changed[0] = fields.join(" ")
    run(workDir/"mutated-plans.txt", changed.join("\n") & "\n", planCases.len-1, planCases.len)
  var yes, no: string
  var yesCount, noCount: int
  proc add(line: string, accepted: bool) =
    if accepted: yes.add line & "\n"; inc yesCount
    else: no.add line & "\n"; inc noCount
  for condition in 0..7:
    for first in 0..7:
      for second in 0..7:
        for output in 0..7:
          let matched = first notin [5, 6] and second notin [5, 6] and
            (first == second or first == 7 or second == 7) and output == (if first == 7: second else: first)
          let values = " " & $condition & " " & $first & " " & $second & " " & $(16+output)
          add("27 0 4" & values, condition in [0, 7] and matched)
          for index in 0..7:
            let immediate = if index < 7: ord(Types[index]) else: 256
            add("28 " & $immediate & " 4" & values, index < 7 and condition in [0, 7] and
              first in [index, 7] and second in [index, 7] and output == index)
  for immediate in 0..255:
    for output in 0..7:
      add("208 " & $immediate & " 1 " & $(16+output),
        (immediate == 0x70 and output == 5) or (immediate == 0x6f and output == 6))
  run(workDir/"finite-valid.txt", yes, yesCount, yesCount)
  run(workDir/"finite-invalid.txt", no, 0, noCount)
  (planCases.len, yesCount+noCount)

proc main() =
  require(paramCount() == 2, "usage: test_parametric CHECKER WORK_DIR")
  var cases, forgeries: int
  for value in Types:
    for poly in [false, true]:
      var code: seq[Instr]
      if poly: code.add Instr(op: opUnreachable)
      else: code.add @[Instr(op: opLocalGet), Instr(op: opLocalGet), Instr(op: opI32Const)]
      code.add @[Instr(op: opSelectTyped, imm1: uint32(ord(value))), Instr(op: opDrop)]
      discard check(body(code, @[value]))
      inc cases
    if value notin [vtFuncRef, vtExternRef]:
      discard check(body(@[Instr(op: opLocalGet), Instr(op: opLocalGet), Instr(op: opI32Const),
        Instr(op: opSelect), Instr(op: opDrop)], @[value]))
      inc cases
      discard check(body(@[Instr(op: opUnreachable), Instr(op: opSelect), Instr(op: opLocalGet),
        Instr(op: opI32Const), Instr(op: opSelect), Instr(op: opDrop)], @[value]))
      inc cases
  discard check(body(@[Instr(op: opUnreachable), Instr(op: opSelect), Instr(op: opDrop)]))
  inc cases
  for value in [vtFuncRef, vtExternRef]:
    discard check(body(@[Instr(op: opRefNull, imm1: uint32(ord(value))), Instr(op: opDrop)]))
    inc cases
  let poly = body(@[Instr(op: opUnreachable), Instr(op: opSelect), Instr(op: opDrop)])
  let events = traceModuleValidation(poly)
  for mutation in 0..3:
    var changed = @events
    var pop = 0
    for i, event in changed:
      if event.opcode == opSelect and event.kind == veOperandPop:
        inc pop
        if mutation == 0 and pop == 1:
          changed.delete(i)
          break
        if mutation == 1 and pop == 1:
          changed.insert(event, i)
          break
      if mutation == 2 and event.opcode == opSelect and event.kind == veOperandPush:
        changed[i].valueType = svI32
        for j in i+1..<changed.len:
          if changed[j].kind == veOperandPop: changed[j].valueType = svI32; break
        break
    if mutation == 3:
      reject(poly, changed, "untyped select nonzero immediate", 1)
    else: reject(poly, changed, "parametric arity/result forgery " & $mutation)
    inc forgeries
  for value in [vtFuncRef, vtExternRef]:
    var original = body(@[Instr(op: opLocalGet), Instr(op: opLocalGet), Instr(op: opI32Const),
      Instr(op: opSelectTyped, imm1: uint32(ord(value))), Instr(op: opDrop)], @[value])
    var changed = traceModuleValidation(original)
    original.codes[0].code.code[3] = Instr(op: opSelect)
    for i, event in changed:
      if event.opcode == opSelectTyped: changed[i].opcode = opSelect
    reject(original, changed, "untyped reference select")
    inc forgeries
  block:
    var original = body(@[Instr(op: opLocalGet), Instr(op: opLocalGet, imm1: 1), Instr(op: opI32Const),
      Instr(op: opSelectTyped, imm1: uint32(ord(vtI64))), Instr(op: opDrop)], @[vtI64, vtI64])
    var changed = traceModuleValidation(original)
    original.types[0].params[0] = vtI32
    original.codes[0].code.code[3] = Instr(op: opSelect)
    var pop = 0
    for i, event in changed:
      if event.instructionIndex == 0 and event.kind == veOperandPush: changed[i].valueType = svI32
      if event.opcode == opSelectTyped:
        changed[i].opcode = opSelect
        if event.kind == veOperandPop:
          inc pop
          if pop == 3: changed[i].valueType = svI32
    reject(original, changed, "untyped incompatible concrete values")
    inc forgeries
  block:
    var original = body(@[Instr(op: opLocalGet), Instr(op: opLocalGet), Instr(op: opI32Const),
      Instr(op: opSelect), Instr(op: opDrop)], @[vtI64])
    var changed = traceModuleValidation(original)
    original.codes[0].code.code[2] = Instr(op: opI64Const)
    var firstPop = true
    for i, event in changed:
      if event.instructionIndex == 2:
        changed[i].opcode = opI64Const
        if event.kind == veOperandPush: changed[i].valueType = svI64
      if event.opcode == opSelect and event.kind == veOperandPop and firstPop:
        changed[i].valueType = svI64
        firstPop = false
    reject(original, changed, "non-i32 concrete select condition")
    inc forgeries
  let typed = body(@[Instr(op: opUnreachable), Instr(op: opSelectTyped, imm1: uint32(ord(vtI64))), Instr(op: opDrop)])
  for immediate in [0, 7, 0x80, 0x100, 0x7f]:
    reject(typed, traceModuleValidation(typed), "typed select immediate/type mismatch", immediate)
    inc forgeries
  let reference = body(@[Instr(op: opRefNull, imm1: uint32(ord(vtFuncRef))), Instr(op: opDrop)])
  for immediate in [0, 0x7f, 0x6e, 0x6f, 0x170]:
    reject(reference, traceModuleValidation(reference), "reference type immediate/mismatch", immediate)
    inc forgeries
  block:
    let events = traceModuleValidation(reference)
    let rows = buildInstructionEventRows(events)
    let im = instructionImmediates(reference, rows)
    let signatures = buildSignatureEnvironment(reference, includeSingletons = true)
    let full = buildControlTypes(rows, buildTypeEnvironment(reference), signatures,
      buildIndexedSignatures(signatures), im.p, im.s, im.pads, full = true)
    require(full.satisfied(), "parametric/structured production composition")
    planCases.add parametricPlanCases(reference, events)
    inc cases
  let aRows = buildInstructionEventRows(traceModuleValidation(reference), 16)
  let a = buildParametric(aRows, instructionImmediates(reference, aRows).p)
  let other = body(@[Instr(op: opRefNull, imm1: uint32(ord(vtExternRef))), Instr(op: opDrop)])
  let bRows = buildInstructionEventRows(traceModuleValidation(other), 16)
  let b = buildParametric(bRows, instructionImmediates(other, bRows).p)
  require(a.sameShape(b) and a.satisfied() and b.satisfied(), "parametric profile matrix")
  planCases.add parametricPlanCases(reference, traceModuleValidation(reference))
  planCases.add parametricPlanCases(other, traceModuleValidation(other))
  let plans = checkPlans(paramStr(1), paramStr(2))
  let key = setup(a)
  for circuit in [a, b]:
    let proof = encodeProof(prove(key, circuit))
    require(proof.len == 192 and decodeAndVerify(key.verificationKey, proof,
      circuit.values[1..circuit.publicCount]), "parametric proof")
  echo "zkbuild parametric events: PASS (", cases, " valid traces; ", forgeries,
    " coherent forgeries rejected; ", plans.traces, " Lean trace plans; ", plans.finite,
    " finite Lean cases; 3 Lean mutations; ", a.constraints.len,
    " constraints/16 rows; QAP ", key.domainSize, "; two 192-byte proofs)"

main()
