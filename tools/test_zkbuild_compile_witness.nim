## Check the complete compilation witness, including public packing and all
## shared row boundaries, against the constructive completeness model.
import std/[os, osproc, strutils]
import cps/zk/[r1cs, wasm_circuit]

proc require(ok: bool, message: string) =
  if not ok: raise newException(ValueError, message)

proc addFixture(cases: var seq[Program], ops: openArray[Operation]) =
  require(ops.len <= SlotCount, "too many fixture operations")
  var program: Program
  for i, op in ops: program[i] = op
  require(checkProgram(program), "invalid fixture program")
  cases.add program

proc reduce(ops: var seq[Operation], depth: int) =
  for _ in 1..<depth: ops.add Operation(kind: opXor)

proc fixtures(): seq[Program] =
  for value in [0'u32, 1, 0x7ff, 0x800, 0xfff, 0x1000, 0x7fffffff'u32,
      0x80000000'u32, 0xffffe800'u32, 0xfffff7ff'u32, 0xfffff800'u32, 0xffffffff'u32]:
    result.addFixture([Operation(kind: opConst, immediate: value)])
  for kind in opAdd..opXor:
    for depth in [2, 8]:
      var ops: seq[Operation]
      for i in 0..<depth: ops.add Operation(kind: if i mod 2 == 0: opParam0 else: opParam1)
      ops.add Operation(kind: kind)
      ops.reduce(depth-1)
      result.addFixture(ops)
  for kind in [opParam0, opParam1]:
    for depth in [0, 7]:
      var ops: seq[Operation]
      for _ in 0..<depth: ops.add Operation(kind: opParam0)
      ops.add Operation(kind: kind)
      ops.reduce(depth+1)
      result.addFixture(ops)
  var rng = 0x9e3779b9'u32
  for _ in 0..<16:
    var ops: seq[Operation]
    var depth = 0
    for _ in 0..<12:
      rng = rng xor (rng shl 13)
      rng = rng xor (rng shr 17)
      rng = rng xor (rng shl 5)
      var kind = OpKind(rng mod uint32(ord(high(OpKind))+1))
      if depth == 0: kind = opConst
      elif depth == 1 and kind.binary: kind = opParam1
      elif depth == 4 and kind.pushes: kind = opSub
      ops.add Operation(kind: kind, immediate: if kind == opConst: rng else: 0'u32)
      if kind.pushes: inc depth
      elif kind.binary: dec depth
    ops.reduce(depth)
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

proc checkWitnesses(path: string, cases: openArray[Program]) =
  const digits = "0123456789abcdef"
  let input = open(path)
  defer: input.close()
  require(input.readLine() == "ZKCOMPW1 " & $cases.len & " 11899", "compilation witness header")
  for moduleIndex, program in cases:
    let circuit = buildCircuit(pmCompile, program, encodeWasm(program), encodeNative(program))
    require(circuit.values.len == 11899 and circuit.satisfied(), "invalid compilation witness")
    for wire, value in circuit.values:
      let line = input.readLine()
      require(line.len == 64, "reference scalar width")
      let encoded = encodeScalar(value)
      for i, byte in encoded:
        require(line[i*2] == digits[int(byte shr 4)] and line[i*2+1] == digits[int(byte and 15)],
          "compilation witness mismatch: module " & $moduleIndex & " wire " & $wire)
  require(input.endOfFile(), "trailing compilation witness data")

proc main() =
  require(paramCount() == 2, "usage: test_zkbuild_compile_witness EXPORTER WORKDIR")
  let exporter = absolutePath(paramStr(1))
  let work = absolutePath(paramStr(2))
  createDir(work)
  let cases = fixtures()
  require(cases.len == 44, "complete compilation fixture set")
  let source = work / "programs.txt"
  let reference = work / "compilation-witnesses.txt"
  writeCases(source, cases)
  let command = quoteShell(exporter) & " " & quoteShell(source) & " " & quoteShell(reference)
  let exported = execCmdEx(command)
  require(exported.exitCode == 0, "compilation witness export failed: " & exported.output)
  checkWitnesses(reference, cases)
  var changed = readFile(reference)
  # Mutate the first public input rather than a redundant sample marker.
  let publicWire = changed.find('\n') + 1 + 65
  changed[publicWire] = if changed[publicWire] == '0': '1' else: '0'
  let corrupted = work / "mutated-compilation-witnesses.txt"
  writeFile(corrupted, changed)
  var rejected = false
  try: checkWitnesses(corrupted, cases)
  except ValueError: rejected = true
  require(rejected, "mutated public input accepted")
  var invalid: Program
  invalid[0] = Operation(kind: opAdd)
  writeCases(source, [invalid])
  let bad = execCmdEx(command)
  require(bad.exitCode != 0 and bad.output.contains("unsupported stack program"),
    "invalid program not rejected for the expected reason")
  echo "zkbuild compilation witness conformance: PASS (", cases.len, " modules, ", cases.len*11899,
    " field values; mutated public input and invalid program rejected)"

main()
