## Direct matrix checks for the byte/word, length and digest wiring in SHA.
import std/[os,osproc,strutils]
import cps/zk/[r1cs,range_check,sha256_word,sha256_boundary,wasm_digest_claim]

type Case = tuple[kind,parameter: int]

proc build(test: Case, values: array[4,uint32]): tuple[c: Circuit, outputs: seq[Linear]] =
  result.c = initCircuit(reuseRangeWitnesses = true)
  case test.kind
  of 0:
    var input: array[4,Linear]
    var bytes: array[4,ShaByteBits]
    var expected = 0'u32
    for i in 0..3:
      input[i] = result.c.publicInput(scalar(values[i] and 255))
      expected = (expected shl 8) or (values[i] and 255)
    for i in 0..3:
      let bits = result.c.constrainUnsigned(input[i],8)
      for j in 0..7: bytes[i][j] = bits[j]
    let word = result.c.word(shaWordBits(bytes))
    doAssert word.value.evaluate(result.c.values).equals(scalar(expected))
    result.outputs.add word.value
    for bit in word.bits: result.outputs.add bit
  of 1:
    var input: array[4,Linear]
    for i in 0..3: input[i] = result.c.publicInput(scalar(values[i]))
    for value in input: discard result.c.constrainUnsigned(value,32)
    let limb = shaDigestLimb(input)
    var expected = scalar(0)
    var bytes: Sha256Digest
    for i in 0..3:
      expected = expected*scalar(4294967296'u64)+scalar(values[i])
      for j in 0..3: bytes[4*i+j] = byte((values[i] shr (8*(3-j))) and 255)
    doAssert limb.evaluate(result.c.values).equals(expected)
    doAssert digestInputs(bytes)[0].equals(expected),"host digest encoding differs from circuit"
    result.outputs = @[limb]
  else:
    let length = result.c.publicInput(scalar(values[0]))
    let bits = result.c.constrainUnsigned(length,32)
    let output = shaLengthByte(bits,test.parameter)
    let expected = if test.parameter < 56: 0'u64 else:
      (uint64(values[0])*8 shr (8*(63-test.parameter))) and 255
    doAssert output.evaluate(result.c.values).equals(scalar(expected)),"wrong length-field byte"
    result.outputs = @[output]
  doAssert result.c.satisfied()

proc hex(value: Scalar): string =
  for b in encodeScalar(value): result.add toHex(b,2).toLowerAscii()
proc line(value: Linear): string =
  result = $value.len
  for t in value: result.add " " & $t.wire & ":" & hex(t.coefficient)

proc main() =
  if paramCount() != 2: quit("usage: test_sha_boundaries CHECKER DIRECTORY",1)
  let checker = absolutePath(paramStr(1))
  let directory = absolutePath(paramStr(2))
  createDir(directory)
  var cases: seq[Case] = @[(0,0),(1,0)]
  for offset in 0..63: cases.add (2,offset)
  let path = directory / "boundaries.txt"
  let f = open(path,fmWrite)
  f.writeLine("ZKSHABOUNDARIES1 ",cases.len)
  var starts: seq[int]
  var outputStarts: seq[int]
  var position = 1
  var total = 0
  for test in cases:
    let actual = build(test,[0'u32,0,0,0])
    for data in [[high(uint32),high(uint32),high(uint32),high(uint32)],
        [1'u32,128,255,64],[0x01234567'u32,0x89abcdef'u32,0xfedcba98'u32,0x76543210'u32]]:
      let other = build(test,data)
      doAssert actual.c.sameShape(other.c),"witness-dependent boundary matrix"
      for i in 0..<actual.outputs.len: doAssert line(actual.outputs[i]) == line(other.outputs[i])
    if test.kind == 2:
      for n in [1'u32,55,56,57,63,64,127,128]: discard build(test,[n,0,0,0])
    starts.add position
    let c = actual.c
    f.writeLine(test.kind," ",test.parameter)
    f.writeLine("ZKR1CS1 ",c.values.len," ",c.publicCount," ",c.constraints.len," ",actual.outputs.len)
    for gate in c.constraints:
      for side in [gate.a,gate.b,gate.c]: f.writeLine(line(side))
    outputStarts.add position+2+3*c.constraints.len
    for output in actual.outputs: f.writeLine(line(output))
    position += 2+3*c.constraints.len+actual.outputs.len
    total += c.constraints.len
  f.close()
  let checked = execCmdEx(quoteShell(checker) & " " & quoteShell(path))
  doAssert checked.exitCode == 0,checked.output
  stdout.write checked.output
  let original = readFile(path).splitLines()
  var failures = 0
  proc reject(name: string, data: seq[string]) =
    let path = directory / (name & ".txt")
    writeFile(path,data.join("\n"))
    let output = execCmdEx(quoteShell(checker) & " " & quoteShell(path))
    doAssert output.exitCode != 0,"accepted forged " & name
    inc failures
  for test in [0,1,2+56,2+63]:
    var changed = original
    changed[outputStarts[test]] = "1 1:" & hex(scalar(1))
    reject("output-" & $test,changed)
  var changed = original
  changed[outputStarts[0]+1] = "1 5:" & hex(scalar(1))
  reject("byte-order",changed)
  changed = original
  changed[starts[2+56]] = "2 63"
  reject("length-position",changed)
  changed = original
  changed[0] = "ZKSHABOUNDARIES1 0"
  reject("coverage",changed)
  changed = original
  changed.setLen(changed.len-10)
  reject("truncated",changed)
  changed = original
  changed.add "trailing"
  reject("trailing",changed)
  echo "SHA boundaries PASS: ",cases.len," cases, ",total," constraints, ",failures," forged exports rejected"

main()
