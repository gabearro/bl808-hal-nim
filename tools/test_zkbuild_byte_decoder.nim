## Compare the independent Lean byte decoder with Nim and the existing VM.
import std/[os, osproc, strutils]
import cps/zk/wasm_bytes
import cps/wasm/[binary, validate, runtime_int]
import zkbuild_test_vm

proc require(condition: bool, message: string) =
  if not condition: raise newException(ValueError, message)

proc bodyModule(body: openArray[byte]): seq[byte] =
  result = @WasmPrefix
  result[31] = byte(body.len+3)
  result[33] = byte(body.len+1)
  result.add body

if paramCount() != 2: quit("usage: test_zkbuild_byte_decoder EXPORTER WORK_DIR", 1)
let exporter = absolutePath(paramStr(1))
let work = absolutePath(paramStr(2))
createDir(work)
var fixtures: seq[seq[byte]]
fixtures.add encodeByteModule([Operation(kind: opParam0)])
fixtures.add encodeByteModule([Operation(kind: opParam1)], "arg")
for kind in opAdd..opXor:
  for value in [0'u32, 63, 64, 127, 128, 0x7ff, 0x800, 0x80000000'u32,
      0xfffff7ff'u32, 0xfffff800'u32, 0xffffffbf'u32, 0xffffffff'u32]:
    fixtures.add encodeByteModule([Operation(kind: opParam0),
      Operation(kind: opConst, immediate: value), Operation(kind: kind)], "foo")
for width in 1..5:
  var negative: seq[byte] = @[0x41'u8]
  var positive: seq[byte] = @[0x41'u8]
  for i in 0..<width:
    negative.add(if i+1 == width: 0x7f'u8 else: 0xff'u8)
    positive.add(if i+1 == width: 0'u8 else: 0x80'u8)
  negative.add 0x0b
  positive.add 0x0b
  fixtures.add bodyModule(negative)
  fixtures.add bodyModule(positive)
var nops = newSeq[Operation](119)
nops[57] = Operation(kind: opParam0)
fixtures.add encodeByteModule(nops)
var random = 0x5f13ab29'u32
proc nextWord(): uint32 =
  random = random xor (random shl 13)
  random = random xor (random shr 17)
  random = random xor (random shl 5)
  random
for trial in 0..<64:
  var ops = @[Operation(kind: opParam0)]
  for _ in 0..trial mod 7:
    let word = nextWord()
    if (word and 1) == 0: ops.add Operation(kind: opNop)
    ops.add Operation(kind: opConst, immediate: word)
    ops.add Operation(kind: OpKind(ord(opAdd) + int(nextWord() mod 6)))
  fixtures.add encodeByteModule(ops, "mix")
let validCount = fixtures.len
var excessive = @[Operation(kind: opParam0)]
for _ in 0..<8:
  excessive.add Operation(kind: opConst, immediate: 1)
  excessive.add Operation(kind: opAdd)
fixtures.add encodeByteModule(excessive)
fixtures.add bodyModule([0x6a'u8, 0x0b])
fixtures.add bodyModule([0x41'u8, 0xff, 0xff, 0xff, 0xff, 0x0f, 0x0b])
fixtures.add bodyModule([0x41'u8, 0x80, 0x0b])
fixtures.add bodyModule([0x20'u8, 2, 0x0b])
var wrongHeader = fixtures[0]
wrongHeader[31] = wrongHeader[31] xor 1
fixtures.add wrongHeader
var trailing = fixtures[0]
trailing.add 0
fixtures.add trailing
let inputPath = work / "input.txt"
let outputPath = work / "output.txt"
var serialized = "ZKBDEC1 " & $fixtures.len & "\n"
for bytes in fixtures:
  for i, b in bytes:
    if i > 0: serialized.add ' '
    serialized.add $b
  serialized.add '\n'
writeFile(inputPath, serialized)
let exported = execCmdEx(quoteShell(exporter) & " " & quoteShell(inputPath) & " " & quoteShell(outputPath))
require(exported.exitCode == 0, "Lean decoder exporter failed: " & exported.output)
let lines = readFile(outputPath).splitLines()
require(lines[0] == "ZKBDEC2 " & $fixtures.len, "reference decoder header")
var line = 1
var executions = 0
const inputs = [0'u32, 1, 0x7fffffff'u32, 0x80000000'u32, 0xffffffff'u32]
for fixtureIndex, wasm in fixtures:
  var program: Program
  let accepted = decodeByteProgram(wasm, program)
  require(accepted == (fixtureIndex < validCount), "Nim fixture classification " & $fixtureIndex)
  if not accepted:
    require(lines[line] == "reject", "Lean accepted invalid bytes " & $fixtureIndex)
    inc line
    continue
  let operations = lines[line].splitWhitespace()
  require(operations.len == SlotCount+1 and operations[0] == "accept", "reference program dimensions")
  for i in 0..<SlotCount:
    let expected = operations[i+1].split(':')
    require(expected.len == 2 and int(program[i].kind) == parseInt(expected[0]) and
      program[i].immediate == uint32(parseBiggestUInt(expected[1])), "decoded operation differs at " & $fixtureIndex & ":" & $i)
  inc line
  let expectedResults = lines[line].splitWhitespace()
  require(expectedResults.len == 25, "reference execution count")
  inc line
  let module = decodeModule(wasm)
  validateModule(module)
  var vm = initIntWasmVM()
  let index = vm.instantiateIntOnly(module)
  let exportName = $char(wasm[25]) & $char(wasm[26]) & $char(wasm[27])
  let native = encodeNative(program)
  var resultIndex = 0
  for a in inputs:
    for b in inputs:
      let expected = uint32(parseBiggestUInt(expectedResults[resultIndex]))
      require(cast[uint32](vm.invokeI32(index, exportName, [cast[int32](a), cast[int32](b)])) == expected,
        "existing WASM VM differs from Lean byte semantics")
      require(runRv32(native, a, b) == expected, "native code differs from Lean byte semantics")
      inc resultIndex
      inc executions
require(line == lines.len-1 and lines[^1].len == 0, "trailing reference decoder data")
echo "zkbuild byte decoder conformance: PASS (", validCount, " programs, ", executions,
  " executions, ", fixtures.len-validCount, " invalid modules rejected)"
