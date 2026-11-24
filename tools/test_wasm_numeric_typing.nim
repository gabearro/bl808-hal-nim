## Check the fixed numeric rule table and its validation traces against Lean.
import std/[os, osproc, strutils]
import cps/wasm/[types, numeric_typing, validate]
import cps/zk/wasm_trace_check

proc require(ok: bool, message: string) =
  if not ok: raise newException(ValueError, message)

proc moduleFor(code: int, count: int, input, output: ValType, unreachable = false): WasmModule =
  result.startFunc = -1
  result.dataCount = -1
  var parameters: seq[ValType]
  var body: seq[Instr]
  if unreachable:
    body.add Instr(op: opUnreachable)
  else:
    for i in 0..<count:
      parameters.add input
      body.add Instr(op: opLocalGet, imm1: uint32(i))
  body.add Instr(op: Opcode(code))
  result.types = @[FuncType(params: parameters, results: @[output])]
  result.funcTypeIdxs = @[0'u32]
  result.codes = @[FuncBody(code: Expr(code: body))]

proc main() =
  require(paramCount() == 2, "usage: test_wasm_numeric_typing EXPORTER WORK_DIR")
  createDir(paramStr(2))
  let path = absolutePath(paramStr(2) / "numeric-rules.txt")
  let generated = execCmdEx(quoteShell(absolutePath(paramStr(1))) & " " & quoteShell(path))
  require(generated.exitCode == 0, "numeric rule oracle failed: " & generated.output)
  let reference = open(path)
  defer: reference.close()
  require(reference.readLine() == "ZKNUM1 1024 140", "numeric rule header")
  var covered = 0
  for code in 0..<1024:
    let row = reference.readLine().splitWhitespace()
    require(row.len == 5 and parseInt(row[0]) == code, "numeric rule order")
    let rule = numericRuleForCode(uint16(code))
    require(rule.present == (row[1] == "1"), "numeric rule coverage")
    if not rule.present: continue
    let count = parseInt(row[2])
    let input = ValType(parseInt(row[3]))
    let output = ValType(parseInt(row[4]))
    require(int(rule.inputCount) == count and rule.inputType == input and rule.outputType == output,
      "numeric signature differs from Lean at " & $code)
    for unreachable in [false, true]:
      let module = moduleFor(code, count, input, output, unreachable)
      let events = traceModuleValidation(module)
      require(checkValidationTraceStructure(module, events).accepted, "valid numeric trace rejected")
      var changed: seq[ValidationEvent]
      for event in events: changed.add event
      let wrong = if output == vtI32: svI64 else: svI32
      var produced = false
      for i in 0..<changed.len:
        if changed[i].kind == veInstructionBegin and changed[i].opcode == Opcode(code):
          produced = true
        if produced and changed[i].kind in {veOperandPush, veOperandPop}:
          changed[i].valueType = wrong
      require(not checkValidationTraceStructure(module, changed).accepted,
        "coherently mistyped numeric trace accepted")
    if count > 0:
      var rejected = false
      try:
        validateModule(moduleFor(code, count, vtFuncRef, output))
      except ValidationError:
        rejected = true
      require(rejected, "numeric instruction consumed a reference operand")
    inc covered
  require(reference.endOfFile() and covered == 140, "numeric coverage count")
  echo "zkbuild numeric typing: PASS (1024 tags, 140 signatures, concrete/polymorphic traces and type mutations)"

main()
