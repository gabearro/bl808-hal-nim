## Compare both Nim artifact encoders and executable behavior against the
## whole-program Lean compiler/codec model. No proving key is needed.
import std/[os, osproc, strutils]
import cps/zk/wasm_profile
import zkbuild_test_vm

proc require(ok: bool, message: string) =
  if not ok: raise newException(ValueError, message)

proc addFixture(cases: var seq[Program], ops: openArray[Operation]) =
  require(ops.len <= SlotCount, "fixture exceeds slot budget")
  var program: Program
  for i, op in ops: program[i] = op
  require(checkProgram(program), "fixture has invalid stack")
  cases.add program

proc prefix(depth: int): seq[Operation] =
  for i in 0..<depth:
    result.add Operation(kind: if i mod 2 == 0: opParam0 else: opParam1)

proc closeStack(ops: var seq[Operation], depth: int) =
  for _ in 1..<depth: ops.add Operation(kind: opXor)

proc fixtures(): seq[Program] =
  for kind in opAdd..opXor:
    for depth in 2..MaxStack:
      var ops = prefix(depth)
      ops.add Operation(kind: kind)
      closeStack(ops, depth-1)
      result.addFixture(ops)
  for value in [0'u32, 1, 0x7ff, 0x800, 0xfff, 0x1000, 0x7fffffff'u32,
      0x80000000'u32, 0xffffe800'u32, 0xfffff7ff'u32, 0xfffff800'u32, 0xffffffff'u32]:
    for depth in 0..<MaxStack:
      var ops = prefix(depth)
      ops.add Operation(kind: opConst, immediate: value)
      closeStack(ops, depth+1)
      result.addFixture(ops)
  for kind in [opParam0, opParam1]:
    for depth in 0..<MaxStack:
      var ops = prefix(depth)
      ops.add Operation(kind: kind)
      closeStack(ops, depth+1)
      result.addFixture(ops)
  for padding in 0..<15:
    var ops: seq[Operation]
    for _ in 0..<padding: ops.add Operation(kind: opNop)
    ops.add Operation(kind: opConst, immediate: 0x12345678)
    result.addFixture(ops)
  var random = 0x9e3779b9'u32
  for _ in 0..<128:
    var ops: seq[Operation]
    var depth = 0
    for _ in 0..<12:
      random = random xor (random shl 13)
      random = random xor (random shr 17)
      random = random xor (random shl 5)
      var kind = OpKind(random mod uint32(ord(high(OpKind))+1))
      if depth == 0: kind = opConst
      elif depth == 1 and kind.binary: kind = opParam1
      elif depth == 4 and kind.pushes: kind = opSub
      ops.add Operation(kind: kind, immediate: random)
      if kind.pushes: inc depth
      elif kind.binary: dec depth
    closeStack(ops, depth)
    result.addFixture(ops)

proc writeCases(path: string, cases: openArray[Program]) =
  let output = open(path, fmWrite)
  defer: output.close()
  output.writeLine("ZKCOMP1 ", cases.len)
  for program in cases:
    for i, op in program:
      if i != 0: output.write(' ')
      output.write($ord(op.kind) & ":" & $op.immediate)
    output.writeLine("")

proc main() =
  require(paramCount() == 2, "usage: test_zkbuild_compiler_model EXPORTER WORKDIR")
  let exporter = absolutePath(paramStr(1))
  let work = absolutePath(paramStr(2))
  createDir(work)
  let source = work / "programs.txt"
  let reference = work / "artifacts.txt"
  let cases = fixtures()
  require(cases.len == 297, "complete compiler fixture set")
  writeCases(source, cases)
  let command = quoteShell(exporter) & " " & quoteShell(source) & " " & quoteShell(reference)
  let execution = execCmdEx(command)
  require(execution.exitCode == 0, "Lean compiler export failed: " & execution.output)
  let input = open(reference)
  defer: input.close()
  require(input.readLine() == "ZKCOMP2 " & $cases.len & " 144 132 25", "compiler reference header")
  const values = [0'u32, 1, 0x7fffffff'u32, 0x80000000'u32, 0xffffffff'u32]
  var byteCount, wasmByteCount, executionCount: int
  for program in cases:
    let code = encodeNative(program)
    let bytes = input.readLine().splitWhitespace()
    require(bytes.len == code.len and code.len == NativeSize, "compiler output length")
    for i, value in code:
      require(bytes[i].parseInt() == int(value), "Nim emitter differs from Lean compiler")
      inc byteCount
    let wasm = encodeWasm(program)
    let wasmBytes = input.readLine().splitWhitespace()
    require(wasmBytes.len == wasm.len and wasm.len == WasmSize, "WASM output length")
    for i, value in wasm:
      require(wasmBytes[i].parseInt() == int(value), "Nim WASM encoding differs from Lean codec")
      inc wasmByteCount
    var decoded: Program
    require(decodeWasm(wasm, decoded), "Nim rejected the verified WASM encoding")
    require(encodeWasm(decoded) == wasm, "Nim WASM codec roundtrip differs from Lean")
    require(encodeNative(decoded) == code, "WASM decoding changes the native artifact")
    let results = input.readLine().splitWhitespace()
    require(results.len == 25, "source result vector length")
    var i = 0
    for a in values:
      for b in values:
        require(runRv32(code, a, b) == uint32(results[i].parseBiggestUInt()),
          "decoded RV32 execution differs from Lean WASM semantics")
        inc i
        inc executionCount
  require(input.endOfFile(), "trailing compiler reference output")
  let rejectCommand = quoteShell(exporter) & " " & quoteShell(source) & " " &
    quoteShell(work / "rejected-native.txt")
  for invalid in 0..<3:
    var program: Program
    if invalid == 0: program[0] = Operation(kind: opAdd)
    elif invalid == 1:
      for i in 0..MaxStack: program[i] = Operation(kind: opParam0)
    require(not checkProgram(program), "invalid fixture accepted by Nim")
    writeCases(source, [program])
    let rejection = execCmdEx(rejectCommand)
    require(rejection.exitCode != 0 and rejection.output.contains("unsupported stack program"),
      "Lean did not reject the invalid stack program for the expected reason")
  echo "zkbuild compiler conformance: PASS (", cases.len, " programs, ", byteCount,
    " native bytes, ", wasmByteCount, " WASM bytes, ", executionCount,
    " executions; 3 invalid programs rejected)"

main()
