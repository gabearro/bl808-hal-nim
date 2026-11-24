## Feed actual Nim validator call bodies to the formally proved Lean decider.
import std/[os, osproc, strutils]
import cps/wasm/[types, validate, variable_typing]
import cps/zk/wasm_instruction_events
import zkbuild_static_test_modules, zkbuild_call_test_modules

proc require(ok: bool, message: string) =
  if not ok: raise newException(ValueError, message)

proc main() =
  require(paramCount() == 2, "usage: test_zkbuild_call_bodies CHECKER WORK_DIR")
  createDir(paramStr(2))
  let path = absolutePath(paramStr(2)/"call-bodies.txt")
  var lines: seq[string]
  var positives, negatives, ordinary, tails, direct, indirects: int
  proc emit(expected, pending, tail: bool, params, results, tokens: seq[int]) =
    var line = $ord(expected) & " " & $ord(pending) & " " & $ord(tail) & " " &
      $params.len & " " & $results.len & " " & $tokens.len
    for list in [params, results, tokens]:
      for value in list: line.add " " & $value
    lines.add line
    if expected: inc positives
    else: inc negatives
  for code in [0x10'u16, 0x11, 0x12, 0x13]:
    let pending = code in [0x11'u16, 0x13]
    let tail = code in [0x12'u16, 0x13]
    for np in [0, 1, 2, 3, 7, 17, 33]:
      for nr in [0, 1, 2, 5, 9]:
        for seed in 0..6:
          var declaredParams, declaredResults: seq[ValType]
          for i in 0..<np: declaredParams.add ValueTypes[(i+seed) mod 7]
          for i in 0..<nr: declaredResults.add ValueTypes[(3*i+seed+1) mod 7]
          var params, results: seq[int]
          for i in countdown(np-1, 0): params.add int(stackTypeTag(declaredParams[i]))
          for value in declaredResults: results.add int(stackTypeTag(value))
          for polymorphic in [false, true]:
            let module = moduleForCall(code, declaredParams, declaredResults, polymorphic)
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
            emit(true, pending, tail, params, results, tokens)
            if tail: inc tails
            else: inc ordinary
            if pending: inc indirects
            else: inc direct
            var popIndex = 0
            for i, token in tokens:
              var changed = @tokens
              changed.delete(i)
              emit(false, pending, tail, params, results, changed)
              changed = @tokens
              changed.insert(token, i)
              emit(false, pending, tail, params, results, changed)
              changed = @tokens
              if token < 8:
                let expectedTag = if pending and popIndex == 0: 0 else: params[popIndex-ord(pending)]
                changed[i] = (expectedTag+1) mod 7
                inc popIndex
              elif token < 15: changed[i] = 8+(token-8+1) mod 7
              else: changed[i] = 8
              emit(false, pending, tail, params, results, changed)
            for token in [0, 7, 8, 14, 15]:
              emit(false, pending, tail, params, results, @[token] & tokens)
              emit(false, pending, tail, params, results, tokens & @[token])
            emit(false, not pending, tail, params, results, tokens)
            emit(false, pending, not tail, params, results, tokens)
            if popIndex > 0 and tokens.len > popIndex:
              var changed = @tokens
              swap(changed[popIndex-1], changed[popIndex])
              emit(false, pending, tail, params, results, changed)
  require(positives == 1960 and ordinary == 980 and tails == 980 and direct == 980 and indirects == 980,
    "call body coverage drift")
  writeFile(path, "ZKCALLBODY1 " & $lines.len & "\n" & lines.join("\n") & "\n")
  let checked = execCmdEx(quoteShell(absolutePath(paramStr(1))) & " " & quoteShell(path))
  require(checked.exitCode == 0, "Lean call body oracle: " & checked.output)
  require(checked.output.contains("accepted=" & $positives & " rejected=" & $negatives), "call body oracle coverage mismatch")
  echo checked.output.strip()
  echo "zkbuild call bodies: PASS (", positives, " actual concrete/polymorphic bodies; ", negatives,
    " rejected mutations; four call opcodes; seven types; arities through 33/9)"

main()
