## Export the production SHA word helpers, including all production constants.
import std/[os,osproc,strutils]
import cps/zk/[r1cs,range_check,sha256_word,sha256_circuit]

type Case = tuple[kind: int, parameter: uint32]

proc build(test: Case, probe: array[3,uint32]): tuple[c: Circuit, outputs: seq[Linear]] =
  result.c = initCircuit(reuseRangeWitnesses = true)
  var inputs: array[3,Linear]
  for i in 0..2: inputs[i] = result.c.publicInput(scalar(probe[i]))
  var words: array[3,ShaWord]
  for i in 0..2:
    words[i].value = inputs[i]
    let bits = result.c.constrainUnsigned(inputs[i],32)
    for j in 0..31: words[i].bits[j] = bits[j]
  var output: ShaWord
  var expected: uint32
  let a = probe[0]
  let b = probe[1]
  let c = probe[2]
  case test.kind
  of 0:
    output = result.c.xor3(words[0],words[1],words[2])
    expected = a xor b xor c
  of 1:
    output = result.c.choose(words[0],words[1],words[2])
    expected = (a and b) or ((not a) and c)
  of 2:
    output = result.c.majority(words[0],words[1],words[2])
    expected = (a and b) or (a and c) or (b and c)
  of 3:
    var operands: seq[ShaWord]
    var total: uint64
    for i in 0..<int(test.parameter):
      operands.add words[i mod 3]
      total += uint64(probe[i mod 3])
    output = result.c.add(operands)
    expected = uint32(total and 0xffffffff'u64)
  of 4:
    output = words[0].rotate(int(test.parameter))
    expected = if test.parameter == 0: a else: (a shr test.parameter) or (a shl (32-test.parameter))
  of 5:
    output = words[0].shift(int(test.parameter))
    expected = if test.parameter == 32: 0'u32 else: a shr test.parameter
  of 6:
    output = literal(test.parameter)
    expected = test.parameter
  else:
    output = result.c.word(words[0].bits)
    expected = a
  doAssert result.c.satisfied(),"unsatisfied SHA word circuit"
  if test.kind notin [4,5]:
    doAssert output.value.evaluate(result.c.values).equals(scalar(expected)),"wrong word value"
  result.outputs.add output.value
  for i in 0..31:
    doAssert output.bits[i].evaluate(result.c.values).equals(scalar((expected shr i) and 1)),"wrong word bit"
    result.outputs.add output.bits[i]

proc hex(value: Scalar): string =
  for b in encodeScalar(value): result.add toHex(b,2).toLowerAscii()

proc line(value: Linear): string =
  result = $value.len
  for t in value: result.add " " & $t.wire & ":" & hex(t.coefficient)

proc main() =
  if paramCount() != 2: quit("usage: test_sha_words CHECKER DIRECTORY",1)
  let checker = absolutePath(paramStr(1))
  let directory = absolutePath(paramStr(2))
  createDir(directory)
  var tests: seq[Case] = @[(0,0'u32),(1,0'u32),(2,0'u32)]
  for n in 1'u32..5'u32: tests.add (3,n)
  for n in 0'u32..31'u32: tests.add (4,n)
  for n in 0'u32..32'u32: tests.add (5,n)
  for n in [0'u32,1'u32,128'u32,2147483647'u32,2147483648'u32,4294967295'u32]: tests.add (6,n)
  for n in ShaInitial: tests.add (6,n)
  for n in ShaRound: tests.add (6,n)
  tests.add (7,0'u32)
  let path = directory / "words.txt"
  let f = open(path,fmWrite)
  f.writeLine("ZKSHAWORDS1 ",tests.len)
  var gateCount = 0
  for test in tests:
    let actual = build(test,[0'u32,0,0])
    for probe in [[high(uint32),0'u32,high(uint32)],
        [0x01234567'u32,0x89abcdef'u32,0xfedcba98'u32],[3'u32,5,9]]:
      let alternate = build(test,probe)
      doAssert actual.c.sameShape(alternate.c),"witness-dependent word circuit"
      doAssert actual.outputs.len == alternate.outputs.len
      for i in 0..<actual.outputs.len:
        doAssert line(actual.outputs[i]) == line(alternate.outputs[i]),"witness-dependent word outputs"
    f.writeLine(test.kind," ",test.parameter)
    let c = actual.c
    f.writeLine("ZKR1CS1 ",c.values.len," ",c.publicCount," ",c.constraints.len," ",actual.outputs.len)
    for gate in c.constraints:
      for side in [gate.a,gate.b,gate.c]: f.writeLine(line(side))
    for output in actual.outputs: f.writeLine(line(output))
    gateCount += c.constraints.len
  f.close()
  let command = quoteShell(checker) & " " & quoteShell(path)
  let checked = execCmdEx(command)
  doAssert checked.exitCode == 0,checked.output
  stdout.write checked.output
  let source = readFile(path)
  let lines = source.splitLines()
  var failures = 0
  proc reject(name: string, data: string) =
    let path = directory / (name & ".txt")
    writeFile(path,data)
    let checked = execCmdEx(quoteShell(checker) & " " & quoteShell(path))
    doAssert checked.exitCode != 0,"accepted forged " & name
    inc failures
  var changed = lines
  changed[2] = "ZKR1CS1 166 2 164 33"
  reject("public-inputs",changed.join("\n"))
  changed = lines
  changed[3] = changed[3].replace("4:","5:")
  reject("range-wire",changed.join("\n"))
  changed = lines
  changed[1] = "0 1"
  reject("case",changed.join("\n"))
  changed = lines
  changed[0] = "ZKSHAWORDS1 0"
  reject("missing-coverage",changed.join("\n"))
  let outputStart = 3+3*164
  changed = lines
  changed[outputStart] = "1 0:" & hex(scalar(0))
  reject("word-value",changed.join("\n"))
  changed = lines
  changed[outputStart+1] = "1 0:" & hex(scalar(0))
  reject("word-bit",changed.join("\n"))
  changed = lines
  changed[3] = "1 4:" & repeat('f',64)
  reject("noncanonical",changed.join("\n"))
  reject("truncated",source[0..<source.len div 2])
  reject("trailing",source & "extra\n")
  echo "Nim SHA words PASS: ",tests.len," cases, ",gateCount," constraints, ",failures," forged matrices rejected"

main()
