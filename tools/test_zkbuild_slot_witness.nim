## Compare the actual Nim builder's private row wires against the constructive
## Lean witness. Matrix conformance separately checks this 743-wire row layout.
import std/[os, osproc, strutils]
import cps/zk/[r1cs, wasm_circuit]

type Fixture = object
  operation: Operation
  height: int

proc require(ok: bool, message: string) =
  if not ok: raise newException(ValueError, message)

proc fixtures(): seq[Fixture] =
  const values = [0'u32, 1, 0x7ff, 0x800, 0xfff, 0x1000, 0x7fffffff'u32,
    0x80000000'u32, 0xffffe800'u32, 0xfffff7ff'u32, 0xfffff800'u32, 0xffffffff'u32]
  for kind in OpKind:
    for height in 0..MaxStack:
      if (kind.pushes and height == MaxStack) or (kind.binary and height < 2): continue
      if kind == opConst:
        for value in values:
          result.add Fixture(operation: Operation(kind: kind, immediate: value), height: height)
      else:
        result.add Fixture(operation: Operation(kind: kind, immediate: 0xfffff800'u32), height: height)

proc programFor(fixture: Fixture): Program =
  for i in 0..<fixture.height: result[i] = Operation(kind: opParam0)
  result[fixture.height] = fixture.operation
  var next = fixture.height + 1
  var depth = fixture.height
  if fixture.operation.kind.pushes: inc depth
  elif fixture.operation.kind.binary: dec depth
  if depth == 0:
    result[next] = Operation(kind: opParam0)
    inc next
    inc depth
  while depth > 1:
    require(next < SlotCount, "fixture exceeds slot count")
    result[next] = Operation(kind: opXor)
    inc next
    dec depth
  require(checkProgram(result), "invalid surrounding program")

proc writeCases(path: string, cases: seq[Fixture]) =
  let output = open(path, fmWrite)
  defer: output.close()
  output.writeLine("ZKSLOT1 ", cases.len)
  for fixture in cases:
    output.writeLine(ord(fixture.operation.kind), " ", fixture.height, " ", fixture.operation.immediate)

proc checkWitnesses(path: string, cases: seq[Fixture]) =
  const digits = "0123456789abcdef"
  const localWires = 753
  const rowPrivateWires = 743
  let input = open(path)
  defer: input.close()
  require(input.readLine() == "ZKSLOTW1 " & $cases.len & " 753", "row witness header")
  for fixture in cases:
    let program = programFor(fixture)
    let circuit = buildCircuit(pmCompile, program, encodeWasm(program), encodeNative(program))
    require(circuit.values.len == 11899 and circuit.publicCount == 10 and circuit.satisfied(),
      "compilation fixture does not satisfy the actual matrix")
    for wire in 0..<localWires:
      let value = if wire == 0: circuit.values[0]
        elif wire < 10: scalar(ord(wire-1 == fixture.height))
        else: circuit.values[11 + fixture.height*rowPrivateWires + wire-10]
      let reference = input.readLine()
      require(reference.len == 64, "reference scalar width")
      let encoded = encodeScalar(value)
      for i, byte in encoded:
        require(reference[i*2] == digits[int(byte shr 4)] and reference[i*2+1] == digits[int(byte and 15)],
          "row witness mismatch: " & $fixture.operation.kind & " depth " & $fixture.height & " wire " & $wire)
  require(input.endOfFile(), "trailing row witness output")

proc main() =
  require(paramCount() == 2, "usage: test_zkbuild_slot_witness EXPORTER WORKDIR")
  let exporter = absolutePath(paramStr(1))
  let work = absolutePath(paramStr(2))
  createDir(work)
  let cases = fixtures()
  require(cases.len == 163, "complete row fixture set")
  let source = work / "rows.txt"
  let reference = work / "row-witnesses.txt"
  writeCases(source, cases)
  let command = quoteShell(exporter) & " " & quoteShell(source) & " " & quoteShell(reference)
  let exported = execCmdEx(command)
  require(exported.exitCode == 0, "row witness export failed: " & exported.output)
  checkWitnesses(reference, cases)

  var changed = readFile(reference)
  changed[changed.find('\n')+64] = '0' # Change the constant-one wire.
  let corrupted = work / "mutated-row-witnesses.txt"
  writeFile(corrupted, changed)
  var rejected = false
  try: checkWitnesses(corrupted, cases)
  except ValueError: rejected = true
  require(rejected, "mutated row witness accepted")
  for invalid in ["3 8 0", "4 1 0", "10 0 0", "3 9 0", "3 0 4294967296"]:
    writeFile(source, "ZKSLOT1 1\n" & invalid & "\n")
    let result = execCmdEx(command)
    require(result.exitCode != 0 and result.output.contains("unsupported row"),
      "invalid row was not rejected for the expected reason")
  echo "zkbuild row witness conformance: PASS (", cases.len, " rows, ", cases.len*753,
    " field values; mutated witness and 5 invalid rows rejected)"

main()
