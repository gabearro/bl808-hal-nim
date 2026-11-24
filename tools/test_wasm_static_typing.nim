import std/[os, osproc, strutils]
import cps/wasm/[static_typing, validate]
import cps/zk/wasm_trace_check
import zkbuild_static_test_modules

proc require(ok: bool, message: string) =
  if not ok: raise newException(ValueError, message)

proc main() =
  require(paramCount() == 2, "usage: test_wasm_static_typing EXPORTER WORK_DIR")
  createDir(paramStr(2))
  let path = absolutePath(paramStr(2)/"static-rules.txt")
  let generated = execCmdEx(quoteShell(absolutePath(paramStr(1))) & " " & quoteShell(path))
  require(generated.exitCode == 0, "static rule oracle: " & generated.output)
  let reference = open(path)
  defer: reference.close()
  require(reference.readLine() == "ZKSTATIC1 2048 245", "static oracle header")
  var covered, traces = 0
  for code in 0..<2048:
    let row = reference.readLine().splitWhitespace()
    require(row.len == 9 and parseInt(row[0]) == code, "static oracle row")
    let rule = staticRuleForCode(uint16(code))
    let expected = [ord(rule.present), int(rule.inputCount), int(rule.outputCount), int(rule.outputType),
      int(rule.clearCount), int(rule.inputs[0]), int(rule.inputs[1]), int(rule.inputs[2])]
    for i, value in expected:
      require(value == parseInt(row[i+1]), "static rule differs from Lean: " & $code)
    if not rule.present: continue
    inc covered
    for polymorphic in [false, true]:
      let module = moduleForStaticRule(uint16(code), polymorphic)
      let events = traceModuleValidation(module)
      require(checkValidationTraceStructure(module, events).accepted, "static trace rejected " & $code)
      inc traces
  require(reference.endOfFile() and covered == 245, "static signature coverage")
  for actual in 0'u8..6'u8:
    let module = moduleForStaticRule(0x1a, wildcard = actual)
    require(checkValidationTraceStructure(module, traceModuleValidation(module)).accepted, "drop type class")
  for actual in [5'u8, 6]:
    let module = moduleForStaticRule(0xd1, wildcard = actual)
    require(checkValidationTraceStructure(module, traceModuleValidation(module)).accepted, "reference type class")
  echo "zkbuild static typing: PASS (2048 opcode tags; ", covered, " Lean signatures; ", traces,
    " concrete/polymorphic traces; vector, drop, and reference classes)"

main()
