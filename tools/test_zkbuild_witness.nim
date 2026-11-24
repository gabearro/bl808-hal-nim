## Compare every production witness wire against the independent, proved Lean
## construction, including public packing and boundaries between parser rows.
import std/[os, osproc, strutils]
import cps/zk/[r1cs, wasm_bytes_circuit]

proc require(ok: bool, message: string) =
  if not ok: raise newException(ValueError, message)

proc rawModule(code: openArray[byte], name = "run"): seq[byte] =
  result = @WasmPrefix
  for i in 0..2: result[25+i] = byte(name[i])
  result[31] = byte(code.len+4)
  result[33] = byte(code.len+2)
  result.add code
  result.add 0x0b

proc fixtures(): seq[seq[byte]] =
  for value in [0'u32, 63, 64, 127, 128, 0x7fffffff'u32, 0x80000000'u32, 0xffffffff'u32]:
    result.add encodeByteModule([Operation(kind: opConst, immediate: value)])
  for code in [@[0x41'u8, 0x0b], @[0x41'u8, 0xc0, 0],
      @[0x41'u8, 0x80, 0x80, 0x80, 0x80, 0],
      @[0x41'u8, 0x80, 0x80, 0x80, 0x80, 0x78],
      @[0x41'u8, 0xff, 0xff, 0xff, 0xff, 0x07]]:
    result.add rawModule(code)
  result.add rawModule([0x20'u8, 1], "\0\1\x7f")
  for kind in opAdd..opXor:
    result.add encodeByteModule([Operation(kind: opParam0), Operation(kind: opParam1), Operation(kind: kind)])
  var full = @[0x20'u8, 0]
  while full.len < 120: full.add 1
  result.add rawModule(full)
  var deep: seq[Operation]
  for i in 0..<8: deep.add Operation(kind: opConst, immediate: uint32(i))
  for _ in 0..<7: deep.add Operation(kind: opAdd)
  result.add encodeByteModule(deep)
  var rng = 0x9e3779b9'u32
  for _ in 0..<24:
    var program: seq[Operation]
    var depth = 0
    for _ in 0..<16:
      rng = rng xor (rng shl 13)
      rng = rng xor (rng shr 17)
      rng = rng xor (rng shl 5)
      var kind = OpKind(rng mod uint32(ord(high(OpKind))+1))
      if depth == 0: kind = opConst
      elif depth == 8: kind = opXor
      elif depth == 1 and kind.binary: kind = opParam1
      program.add Operation(kind: kind, immediate: rng)
      if kind.pushes: inc depth
      elif kind.binary: dec depth
    while depth > 1:
      program.add Operation(kind: opXor)
      dec depth
    result.add encodeByteModule(program)

proc writeCases(path: string, cases: seq[seq[byte]]) =
  let output = open(path, fmWrite)
  defer: output.close()
  output.writeLine("ZKWASM1 ", cases.len)
  for raw in cases:
    for i, value in raw:
      if i != 0: output.write(' ')
      output.write(value)
    output.writeLine("")

proc checkWitnesses(path: string, cases: seq[seq[byte]]) =
  const digits = "0123456789abcdef"
  let input = open(path)
  defer: input.close()
  require(input.readLine() == "ZKWIT1 " & $cases.len & " 6096", "reference witness header")
  for moduleIndex, raw in cases:
    let circuit = buildByteCircuit(raw)
    require(circuit.values.len == 6096 and circuit.satisfied(), "valid witness fixture")
    for wire, value in circuit.values:
      let line = input.readLine()
      require(line.len == 64, "reference scalar width")
      let encoded = encodeScalar(value)
      for i, b in encoded:
        require(line[i*2] == digits[int(b shr 4)] and line[i*2+1] == digits[int(b and 15)],
          "witness differs from Lean at module " & $moduleIndex & " wire " & $wire)
  require(input.endOfFile(), "trailing reference witness data")

proc main() =
  require(paramCount() == 2, "usage: test_zkbuild_witness EXPORT_WITNESS WORKDIR")
  let exporter = absolutePath(paramStr(1))
  let work = absolutePath(paramStr(2))
  createDir(work)
  let source = work / "witness-modules.txt"
  let reference = work / "reference-witnesses.txt"
  let cases = fixtures()
  writeCases(source, cases)
  let command = quoteShell(exporter) & " " & quoteShell(source) & " " & quoteShell(reference)
  let exported = execCmdEx(command)
  require(exported.exitCode == 0, "reference witness export failed: " & exported.output)
  checkWitnesses(reference, cases)

  # Verify the comparison actually detects a wrong assignment.
  var changed = readFile(reference)
  let firstWire = changed.find('\n') + 1
  changed[firstWire+63] = '0'
  let corrupted = work / "mutated-witnesses.txt"
  writeFile(corrupted, changed)
  var rejected = false
  try: checkWitnesses(corrupted, cases)
  except ValueError: rejected = true
  require(rejected, "mutated reference witness accepted")

  var unsupported = cases[0]
  unsupported[WasmPrefix.len] = 0xff
  let badSource = work / "invalid-module.txt"
  let badReference = work / "invalid-reference.txt"
  writeCases(badSource, @[unsupported])
  let bad = execCmdEx(quoteShell(exporter) & " " & quoteShell(badSource) & " " & quoteShell(badReference))
  require(bad.exitCode != 0 and "unsupported WASM binary" in bad.output,
    "reference exporter accepted unsupported input")
  echo "zkbuild full witness conformance: PASS (", cases.len, " modules, ",
    cases.len * 6096, " field values; mutated witness and invalid module rejected)"

main()
