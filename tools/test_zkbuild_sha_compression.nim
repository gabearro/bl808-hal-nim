## Check the actual full compression matrix against the proved composition.
import std/[os,osproc,strutils]
import cps/zk/[r1cs,range_check,sha256_word,sha256_circuit]

proc add32(values: varargs[uint32]): uint32 =
  var sum: uint64
  for value in values: sum += uint64(value)
  uint32(sum and 0xffffffff'u64)

proc rotr(value: uint32, amount: int): uint32 =
  (value shr amount) or (value shl (32-amount))

proc reference(previous: array[8,uint32], blockWords: array[16,uint32]): array[8,uint32] =
  var schedule: array[64,uint32]
  for i in 0..15: schedule[i] = blockWords[i]
  for i in 16..63:
    let x = schedule[i-15]
    let y = schedule[i-2]
    schedule[i] = add32(schedule[i-16],rotr(x,7) xor rotr(x,18) xor (x shr 3),
      schedule[i-7],rotr(y,17) xor rotr(y,19) xor (y shr 10))
  var s = previous
  for i in 0..63:
    let t1 = add32(s[7],rotr(s[4],6) xor rotr(s[4],11) xor rotr(s[4],25),
      (s[4] and s[5]) xor ((not s[4]) and s[6]),ShaRound[i],schedule[i])
    let t2 = add32(rotr(s[0],2) xor rotr(s[0],13) xor rotr(s[0],22),
      (s[0] and s[1]) xor (s[0] and s[2]) xor (s[1] and s[2]))
    # Keep the source registers alive until every next-state word is computed.
    # Nim 2 can lower a self-referencing plain-array assignment in place.
    let next = [add32(t1,t2),s[0],s[1],s[2],add32(s[3],t1),s[4],s[5],s[6]]
    s = next
  for i in 0..7: result[i] = add32(previous[i],s[i])

proc build(previous: array[8,uint32], blockWords: array[16,uint32]): tuple[c: Circuit, outputs: seq[Linear]] =
  result.c = initCircuit(reuseRangeWitnesses = true)
  var inputs: array[24,Linear]
  for i in 0..23:
    inputs[i] = result.c.publicInput(scalar(if i < 8: previous[i] else: blockWords[i-8]))
  var words: array[24,ShaWord]
  for i in 0..23:
    words[i].value = inputs[i]
    let bits = result.c.constrainUnsigned(inputs[i],32)
    for j in 0..31: words[i].bits[j] = bits[j]
  var state: array[8,ShaWord]
  for i in 0..7: state[i] = words[i]
  var bytes: array[64,array[8,Linear]]
  for i in 0..15:
    for j in 0..3:
      for k in 0..7: bytes[4*i+j][k] = words[8+i].bits[8*(3-j)+k]
  let output = result.c.compress(state,bytes)
  let expected = reference(previous,blockWords)
  doAssert result.c.satisfied(),"compression circuit unsatisfied"
  for i in 0..7:
    doAssert output[i].value.evaluate(result.c.values).equals(scalar(expected[i])),"wrong compression word"
    result.outputs.add output[i].value
    for j in 0..31:
      doAssert output[i].bits[j].evaluate(result.c.values).equals(scalar((expected[i] shr j) and 1)),"wrong compression bit"
      result.outputs.add output[i].bits[j]

proc hex(value: Scalar): string =
  for b in encodeScalar(value): result.add toHex(b,2).toLowerAscii()

proc line(value: Linear): string =
  result = $value.len
  for t in value: result.add " " & $t.wire & ":" & hex(t.coefficient)

proc main() =
  if paramCount() != 2: quit("usage: test_sha_compression CHECKER DIRECTORY",1)
  let checker = absolutePath(paramStr(1))
  let directory = absolutePath(paramStr(2))
  createDir(directory)
  var abc: array[16,uint32]
  abc[0] = 0x61626380'u32
  abc[15] = 24
  doAssert reference(ShaInitial,abc) == [0xba7816bf'u32,0x8f01cfea'u32,0x414140de'u32,0x5dae2223'u32,
    0xb00361a3'u32,0x96177a9c'u32,0xb410ff61'u32,0xf20015ad'u32],"FIPS known answer: " & $reference(ShaInitial,abc)
  let canonical = build(ShaInitial,abc)
  for pattern in 0..2:
    var state: array[8,uint32]
    var blockWords: array[16,uint32]
    for i in 0..7: state[i] = if pattern == 0: 0'u32 elif pattern == 1: high(uint32) else: uint32(i)*0x1020304'u32
    for i in 0..15: blockWords[i] = if pattern == 0: 0'u32 elif pattern == 1: high(uint32) else: uint32(i)*0x3040506'u32
    let other = build(state,blockWords)
    doAssert canonical.c.sameShape(other.c),"witness-dependent compression matrix"
    for i in 0..<canonical.outputs.len:
      doAssert line(canonical.outputs[i]) == line(other.outputs[i]),"witness-dependent output expression"
  let path = directory / "compression.txt"
  let f = open(path,fmWrite)
  f.writeLine("ZKSHACOMPRESS1 ",canonical.c.values.len," ",canonical.c.publicCount," ",canonical.c.constraints.len," ",canonical.outputs.len)
  for gate in canonical.c.constraints:
    for side in [gate.a,gate.b,gate.c]: f.writeLine(line(side))
  for output in canonical.outputs: f.writeLine(line(output))
  f.close()
  let checked = execCmdEx(quoteShell(checker) & " " & quoteShell(path))
  doAssert checked.exitCode == 0,checked.output
  stdout.write checked.output
  let source = readFile(path)
  let original = source.splitLines()
  var failures = 0
  proc reject(name: string, data: seq[string]) =
    let path = directory / (name & ".txt")
    writeFile(path,data.join("\n"))
    let output = execCmdEx(quoteShell(checker) & " " & quoteShell(path))
    doAssert output.exitCode != 0,"accepted forged " & name
    inc failures
  var changed = original
  changed[0] = changed[0].replace(" 24 "," 23 ")
  reject("public-count",changed)
  changed = original
  changed[1] = "1 26:" & hex(scalar(1))
  reject("input-bit",changed)
  for gate in [800,canonical.c.constraints.len div 2,canonical.c.constraints.len-1]:
    changed = original
    changed[1+3*gate] = "1 0:" & hex(scalar(0))
    reject("gate-" & $gate,changed)
  changed = original
  changed[1+3*canonical.c.constraints.len] = "1 0:" & hex(scalar(0))
  reject("output-word",changed)
  changed = original
  changed[2+3*canonical.c.constraints.len] = "1 0:" & hex(scalar(0))
  reject("output-bit",changed)
  changed = original
  changed.setLen(changed.len-20)
  reject("truncated",changed)
  changed = original
  changed.add "extra"
  reject("trailing",changed)
  echo "Nim SHA compression PASS: four witnesses, ",failures," forged matrices rejected"

main()
