## Compare actual Nim validator bodies with the proved Lean body relations.
import std/[os, osproc, strutils]
import cps/wasm/[types, static_typing, variable_typing, validate]
import cps/zk/[wasm_instruction_events, wasm_type_environment]
import zkbuild_static_test_modules, zkbuild_variable_test_modules

type BodyRow = tuple[kind, opcode, tag: int]

proc require(ok: bool, message: string) =
  if not ok: raise newException(ValueError, message)

proc main() =
  require(paramCount() == 2, "usage: test_zkbuild_instruction_bodies CHECKER WORK_DIR")
  createDir(paramStr(2))
  let path = absolutePath(paramStr(2)/"instruction-bodies.txt")
  let output = open(path, fmWrite)
  output.writeLine("ZKINSTRUCTIONBODIES1")
  var positives, negatives, fixedRules, variableRules: int
  proc emit(expected: bool, family, code, declared: int, rows: seq[BodyRow]) =
    var line = $ord(expected) & " " & $family & " " & $code & " " & $declared & " " & $rows.len
    for row in rows: line.add " " & $row.kind & " " & $row.opcode & " " & $row.tag
    output.writeLine(line)
    if expected: inc positives
    else: inc negatives

  proc fixture(module: WasmModule, family, code, declared: int) =
    let allRows = buildInstructionEventRows(traceModuleValidation(module))
    var first = -1
    for i, row in allRows:
      if int(row.opcode) == code and row.control.operand.kind == uint8(ord(veInstructionBegin)): first = i
    require(first >= 0, "missing target instruction " & $code)
    var last = first+1
    while last < allRows.len and allRows[last].control.operand.kind != uint8(ord(veInstructionEnd)): inc last
    require(last < allRows.len, "missing instruction end")
    if family == 1:
      let environment = buildTypeEnvironment(module)
      let witness = buildTypeEnvironmentWitness(environment, allRows, variableImmediates(module, allRows))
      let actual = (witness.localQueries[first].value+witness.objectQueries[first].value) mod 8
      require(actual == uint64(declared), "declared type was not selected from the actual environment")
    var rows: seq[BodyRow]
    for row in allRows[first..last]:
      rows.add (int(row.control.operand.kind), int(row.opcode), int(row.control.operand.valueType))
    emit(true, family, code, declared, rows)
    for i in 0..<rows.len:
      var changed = @rows
      changed.delete(i)
      emit(false, family, code, declared, changed)
      changed = @rows
      changed.insert(rows[i], i)
      emit(false, family, code, declared, changed)
      changed = @rows
      changed[i].tag = 8
      emit(false, family, code, declared, changed)
      changed = @rows
      changed[i].opcode = code xor 1
      emit(false, family, code, declared, changed)
    for kind in [0, 1, 4, 5, 7, 8, 9, 10, 15]:
      var changed = @rows
      changed.insert((kind, code, 0), 1)
      emit(false, family, code, declared, changed)
    var popIndex = 0
    var lastPop = -1
    var firstPush = -1
    for i in 1..<rows.len-1:
      if rows[i].kind == ord(veOperandPop):
        lastPop = i
        for tag in 0..6:
          let permitted = if family == 0: staticPopMatches(staticRuleForCode(uint16(code)), popIndex, tag)
            else: int(variableRuleForCode(uint16(code), uint8(declared)).inputs[popIndex]) == tag
          if not permitted:
            var changed = @rows
            changed[i].tag = tag
            emit(false, family, code, declared, changed)
        inc popIndex
      elif rows[i].kind == ord(veOperandPush):
        if firstPush < 0: firstPush = i
        for tag in 0..7:
          if tag != rows[i].tag:
            var changed = @rows
            changed[i].tag = tag
            emit(false, family, code, declared, changed)
    if lastPop >= 0 and firstPush >= 0:
      var changed = @rows
      swap(changed[lastPop], changed[firstPush])
      emit(false, family, code, declared, changed)
    if family == 1: emit(false, family, code, 7, rows)
    emit(false, 2, code, declared, rows)

  for code in 0..<2048:
    if staticRuleForCode(uint16(code)).present:
      inc fixedRules
      for polymorphic in [false, true]: fixture(moduleForStaticRule(uint16(code), polymorphic), 0, code, 0)
    for declared in 0'u8..6'u8:
      if variableRuleForCode(uint16(code), declared).present:
        inc variableRules
        for polymorphic in [false, true]: fixture(moduleForVariable(uint16(code), declared, polymorphic), 1, code, int(declared))
  require(fixedRules == 245 and variableRules == 45 and positives == 580, "instruction body coverage drift")
  output.close()
  let checked = execCmdEx(quoteShell(absolutePath(paramStr(1))) & " " & quoteShell(path))
  require(checked.exitCode == 0, "Lean instruction body oracle: " & checked.output)
  require(checked.output.contains("accepted=" & $positives & " rejected=" & $negatives), "oracle coverage mismatch")
  echo checked.output.strip()
  echo "zkbuild instruction bodies: PASS (", fixedRules, " static rules; ", variableRules,
    " variable rules; ", positives, " actual concrete/polymorphic bodies; ", negatives, " rejected mutations)"

main()
