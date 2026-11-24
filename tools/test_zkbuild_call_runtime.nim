## Compare actual validator call bodies and callRule context decisions with
## the Lean-proved executable relation, including caller and table mutations.
import std/[os, osproc, strutils]
import cps/wasm/[types, validate, variable_typing, call_typing]
import cps/zk/wasm_instruction_events
import zkbuild_static_test_modules, zkbuild_call_test_modules

proc require(ok: bool, message: string) =
  if not ok: raise newException(ValueError, message)

proc tags(values: seq[ValType]): seq[int] =
  for value in values: result.add int(stackTypeTag(value))

proc main() =
  require(paramCount() == 2, "usage: test_zkbuild_call_runtime CHECKER WORK_DIR")
  createDir(paramStr(2))
  let path = absolutePath(paramStr(2)/"call-context.txt")
  var lines: seq[string]
  var positives, negatives, modules, definedCount, importedCount: int
  proc emit(want: bool, code: uint16, tableTag: int, params, results, current, tokens: seq[int]) =
    var line = $ord(want) & " " & $code & " " & $tableTag & " " & $params.len & " " &
      $results.len & " " & $current.len & " " & $tokens.len
    for list in [params, results, current, tokens]:
      for value in list: line.add " " & $value
    lines.add line
    if want: inc positives
    else: inc negatives
  for code in [0x10'u16, 0x11, 0x12, 0x13]:
    let indirect = code in [0x11'u16, 0x13]
    let tail = code in [0x12'u16, 0x13]
    for np in [0, 1, 2, 3, 7, 17, 33]:
      for nr in [0, 1, 2, 5, 9]:
        for seed in 0..6:
          var declaredParams, declaredResults: seq[ValType]
          for i in 0..<np: declaredParams.add ValueTypes[(i+seed) mod 7]
          for i in 0..<nr: declaredResults.add ValueTypes[(3*i+seed+1) mod 7]
          var params: seq[int]
          for i in countdown(np-1, 0): params.add int(stackTypeTag(declaredParams[i]))
          let results = tags(declaredResults)
          for polymorphic in [false, true]:
            for defined in [false, true]:
              var module = moduleForCall(code, declaredParams, declaredResults, polymorphic)
              if defined:
                module.imports.delete(0)
                module.funcTypeIdxs.add 0'u32
                module.codes.add FuncBody(code: Expr(code: @[Instr(op: opUnreachable)]))
                if not indirect: module.codes[0].code.code[^1].imm1 = 1
                inc definedCount
              else: inc importedCount
              let instruction = module.codes[0].code.code[^1]
              let rule = callRule(module, 0, instruction)
              require(rule.present, "fixture call rule rejected")
              let rows = buildInstructionEventRows(traceModuleValidation(module))
              var first = -1
              for i, row in rows:
                if row.opcode == code and row.control.operand.kind == uint8(ord(veInstructionBegin)): first = i
              require(first >= 0, "missing call begin")
              var last = first+1
              while last < rows.len and rows[last].control.operand.kind != uint8(ord(veInstructionEnd)): inc last
              require(last < rows.len, "missing call end")
              var tokens: seq[int]
              for i in first+1..<last:
                let row = rows[i].control.operand
                case ValidationEventKind(row.kind)
                of veOperandPop: tokens.add int(row.valueType)
                of veOperandPush: tokens.add 8+int(row.valueType)
                of veUnreachable: tokens.add 15
                else: raise newException(ValueError, "unexpected call body event")
              inc modules
              emit(true, code, 5, params, results, results, tokens)
              var changedRoot = module
              if changedRoot.types[1].results.len == 0: changedRoot.types[1].results.add vtI32
              else: changedRoot.types[1].results[0] = ValueTypes[(results[0]+1) mod 7]
              let rootRule = callRule(changedRoot, 0, instruction)
              require(rootRule.present == not tail, "caller root mutation coverage")
              emit(rootRule.present, code, 5, params, results, tags(changedRoot.types[1].results), tokens)
              var changedTable = module
              changedTable.tables[0].elemType = vtExternRef
              let tableRule = callRule(changedTable, 0, instruction)
              require(tableRule.present == not indirect, "defined table mutation coverage")
              emit(tableRule.present, code, 6, params, results, results, tokens)
              var importedTable = instruction
              importedTable.imm2 = 0
              let importRule = callRule(module, 0, importedTable)
              require(importRule.present == not indirect, "imported table mutation coverage")
              emit(importRule.present, code, 6, params, results, results, tokens)
              var missingTable = instruction
              missingTable.imm2 = high(uint32)
              let missingRule = callRule(module, 0, missingTable)
              require(missingRule.present == not indirect, "missing table mutation coverage")
              emit(missingRule.present, code, 0, params, results, results, tokens)
              emit(false, code, 5, params, results, results, tokens & @[15])
  require(modules == 3920 and definedCount == 1960 and importedCount == 1960 and
    positives == 11760 and negatives == 11760, "call context coverage drift")
  writeFile(path, "ZKCALLCONTEXT1 " & $lines.len & "\n" & lines.join("\n") & "\n")
  let checked = execCmdEx(quoteShell(absolutePath(paramStr(1))) & " " & quoteShell(path))
  require(checked.exitCode == 0, "Lean call context oracle: " & checked.output)
  require(checked.output.contains("accepted=" & $positives & " rejected=" & $negatives), "call context oracle coverage mismatch")
  echo checked.output.strip()
  echo "zkbuild call context: PASS (", modules, " actual validator bodies; imported/defined callees; caller and table mutations; four call opcodes; seven types; arities through 33/9)"

main()
