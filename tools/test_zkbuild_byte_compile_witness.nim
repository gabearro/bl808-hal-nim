## Compare every wire of the combined witness against independent Lean construction.
import std/[os, osproc, strutils]
import cps/zk/[r1cs, wasm_compile_bytes]

proc require(condition: bool, message: string) =
  if not condition: raise newException(ValueError, message)

proc fixtures(): seq[seq[byte]] =
  for value in [0'u32, 1, 63, 64, 0x7ff, 0x800, 0x1000, 0x7fffffff'u32,
      0x80000000'u32, 0xfffff7ff'u32, 0xfffff800'u32, 0xffffffff'u32]:
    result.add encodeByteModule([Operation(kind: opConst, immediate: value)])
  for kind in opAdd..opXor:
    result.add encodeByteModule([Operation(kind: opParam0), Operation(kind: opParam1), Operation(kind: kind)], "foo")
    var deep: seq[Operation]
    for i in 0..<8: deep.add Operation(kind: if i mod 2 == 0: opParam0 else: opParam1)
    for _ in 0..<7: deep.add Operation(kind: kind)
    result.add encodeByteModule(deep)
  for width in 1..5:
    var wasm = @WasmPrefix
    var body = @[0x41'u8]
    for i in 0..<width: body.add(if i+1 == width: 0x7f'u8 else: 0xff'u8)
    body.add 0x0b
    wasm[31] = byte(body.len+3)
    wasm[33] = byte(body.len+1)
    wasm.add body
    result.add wasm
  var nops = newSeq[Operation](119)
  nops[60] = Operation(kind: opParam0)
  result.add encodeByteModule(nops)

proc writeFixtures(path: string, fixtures: openArray[seq[byte]]) =
  let output = open(path, fmWrite)
  defer: output.close()
  output.writeLine("ZKBCW1 ", fixtures.len)
  for wasm in fixtures:
    for i, value in wasm:
      if i > 0: output.write(' ')
      output.write($value)
    output.writeLine("")

proc checkWitnesses(path: string, fixtures: openArray[seq[byte]]) =
  let input = open(path)
  defer: input.close()
  require(input.readLine() == "ZKBCW2 " & $fixtures.len & " 21277", "combined witness header")
  const digits = "0123456789abcdef"
  for index, wasm in fixtures:
    var program: Program
    require(decodeByteProgram(wasm, program), "invalid fixture")
    let circuit = buildByteCompileCircuit(wasm, encodeNative(program), program)
    require(circuit.values.len == 21277 and circuit.satisfied(), "invalid Nim combined witness")
    for wire, value in circuit.values:
      let expected = input.readLine()
      require(expected.len == 64, "reference scalar width")
      for byteIndex, b in encodeScalar(value):
        require(expected[byteIndex*2] == digits[int(b shr 4)] and expected[byteIndex*2+1] == digits[int(b and 15)],
          "combined witness mismatch at module " & $index & ", wire " & $wire)
  require(input.endOfFile(), "trailing combined witness data")

proc main() =
  require(paramCount() == 2, "usage: test_zkbuild_byte_compile_witness EXPORTER WORK_DIR")
  let exporter = absolutePath(paramStr(1))
  let work = absolutePath(paramStr(2))
  createDir(work)
  let cases = fixtures()
  require(cases.len == 30, "combined fixture count")
  let source = work / "input.txt"
  let destination = work / "witness.txt"
  writeFixtures(source, cases)
  let command = quoteShell(exporter) & " " & quoteShell(source) & " " & quoteShell(destination)
  let generated = execCmdEx(command)
  require(generated.exitCode == 0, "reference construction failed: " & generated.output)
  checkWitnesses(destination, cases)
  var changed = readFile(destination)
  let publicInput = changed.find('\n') + 1 + 65
  changed[publicInput] = if changed[publicInput] == '0': '1' else: '0'
  let corrupted = work / "changed.txt"
  writeFile(corrupted, changed)
  var rejected = false
  try: checkWitnesses(corrupted, cases)
  except ValueError: rejected = true
  require(rejected, "changed public wire accepted")
  var unsupported = @[Operation(kind: opParam0)]
  for _ in 0..<8:
    unsupported.add Operation(kind: opConst, immediate: 1)
    unsupported.add Operation(kind: opAdd)
  let invalidSource = work / "unsupported.txt"
  let invalidDestination = work / "unsupported-witness.txt"
  writeFixtures(invalidSource, [encodeByteModule(unsupported)])
  let invalid = execCmdEx(quoteShell(exporter) & " " & quoteShell(invalidSource) & " " & quoteShell(invalidDestination))
  require(invalid.exitCode != 0 and invalid.output.contains("unsupported byte compilation"), "reference failed to reject overflow")
  echo "zkbuild combined witness conformance: PASS (", cases.len, " modules, ", cases.len*21277,
    " field values; changed public input and oversized program rejected)"

main()
