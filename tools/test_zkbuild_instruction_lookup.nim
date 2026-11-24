import std/[os, osproc, strutils]
import cps/zk/[r1cs, instruction_lookup]

proc require(ok: bool, message: string) =
  if not ok: raise newException(ValueError, message)

proc build(code: uint64, payload: array[7, int]): Circuit =
  result = initCircuit()
  let op = result.publicInput(scalar(code))
  var public: array[7, Linear]
  for i, value in payload: public[i] = result.publicInput(scalar(value))
  let found = result.constrainInstructionMetadata(op)
  let fields = [found.memoryRequired, found.memoryArgument, found.vectorArgument,
    found.maxAlignment, found.memoryIndex, found.vectorConstant, found.laneBits]
  for i in 0..<7: result.assertEqual(fields[i], public[i])

proc main() =
  require(paramCount() == 2, "usage: test_instruction_lookup EXPORTER WORK_DIR")
  createDir(paramStr(2))
  let path = absolutePath(paramStr(2)/"metadata.txt")
  require(execCmd(quoteShell(absolutePath(paramStr(1))) & " " & quoteShell(path)) == 0, "Lean metadata export")
  let lines = readFile(path).splitLines()
  require(lines[0] == "ZKMETA1 65536", "metadata export header")
  let shape = build(0, default(array[7, int]))
  var matrixCases, mutations: int
  for code in 0..65535:
    let words = lines[code+1].splitWhitespace()
    require(words.len == 8 and parseInt(words[0]) == code, "metadata export row")
    var expected: array[7, int]
    for i in 0..<7: expected[i] = parseInt(words[i+1])
    require(instructionPayload(uint16(code)) == expected, "Nim/Lean immediate metadata " & $code)
    require(lookupInstructionValue(uint16(code)) == expected, "decision DAG metadata " & $code)
    if code < 1024 or code in [0x103f, 0x8302, 65535]:
      var circuit = build(uint64(code), expected)
      require(circuit.satisfied() and circuit.sameShape(shape), "metadata matrix depends on opcode")
      for wire in 1..8:
        let original = circuit.values[wire]
        circuit.values[wire] = original+scalar(1)
        require(not circuit.satisfied(), "metadata public substitution")
        circuit.values[wire] = original
        inc mutations
      inc matrixCases
  require(not build(65536, default(array[7, int])).satisfied(), "high opcode aliases low bits")
  echo "zkbuild instruction lookup: PASS (65536 independent Lean opcode cases; ", matrixCases,
    " matrix cases; ", mutations, " public substitutions; ", instructionLookupBranches(),
    " DAG branches; ", shape.constraints.len, " constraints)"

main()
