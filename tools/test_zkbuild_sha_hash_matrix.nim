## Check the complete production private-byte/public-digest SHA matrix.
import std/[os,osproc,strutils]
import cps/zk/[r1cs,sha256_circuit,wasm_digest_claim]

proc build(bytes: seq[byte], capacity: int): Circuit =
  result = initCircuit(reuseRangeWitnesses = true)
  let digest = wasmDigestInputs(bytes)
  let output = [result.publicInput(digest[0]),result.publicInput(digest[1])]
  let length = result.allocate(scalar(bytes.len))
  var input: seq[Linear]
  for i in 0..<capacity: input.add result.allocate(scalar(if i < bytes.len: bytes[i] else: 0'u8))
  result.constrainSha256(input,length,output)

proc hex(value: Scalar): string =
  for b in encodeScalar(value): result.add toHex(b,2).toLowerAscii()
proc line(value: Linear): string =
  result = $value.len
  for t in value: result.add " " & $t.wire & ":" & hex(t.coefficient)

proc main() =
  if paramCount() != 2: quit("usage: test_sha_hash_matrix CHECKER DIRECTORY",1)
  let checker = absolutePath(paramStr(1))
  let directory = absolutePath(paramStr(2))
  createDir(directory)
  var total = 0
  for capacity in [0,8,56,128]:
    let c = build(@[],capacity)
    doAssert c.satisfied()
    for length in [capacity div 2,capacity]:
      var bytes = newSeq[byte](length)
      for i in 0..<length: bytes[i] = byte((i*131+255) and 255)
      let other = build(bytes,capacity)
      doAssert other.satisfied() and c.sameShape(other),"SHA shape depends on message/length"
    let path = directory / ("sha-" & $capacity & ".txt")
    let f = open(path,fmWrite)
    f.writeLine("ZKSHAHASH1 ",capacity," ",c.values.len," ",c.publicCount," ",c.constraints.len," 2")
    for gate in c.constraints:
      for side in [gate.a,gate.b,gate.c]: f.writeLine(line(side))
    f.writeLine(line(wire(1)))
    f.writeLine(line(wire(2)))
    f.close()
    let result = execCmdEx(quoteShell(checker) & " " & quoteShell(path))
    doAssert result.exitCode == 0,result.output
    stdout.write result.output
    total += c.constraints.len
  let original = readFile(directory / "sha-8.txt").splitLines()
  let gates = parseInt(original[0].splitWhitespace()[4])
  var rejected = 0
  proc reject(name: string, data: seq[string]) =
    let path = directory / (name & ".txt")
    writeFile(path,data.join("\n"))
    let result = execCmdEx(quoteShell(checker) & " " & quoteShell(path))
    doAssert result.exitCode != 0,"accepted forged full SHA " & name
    inc rejected
  for gate in [0,33,66,gates div 2,gates-1]:
    var changed = original
    changed[1+3*gate] = "1 0:" & hex(scalar(0))
    reject("gate-" & $gate,changed)
  var changed = original
  changed[1+3*gates] = line(wire(2))
  reject("digest-output",changed)
  changed = original
  changed[0] = changed[0].replace(" 8 "," 9 ")
  reject("capacity",changed)
  changed = original
  changed.setLen(changed.len-10)
  reject("truncated",changed)
  changed = original
  changed.add "trailing"
  reject("trailing",changed)
  echo "full SHA matrix regression PASS: four capacities, ",total," constraints, ",rejected," forgeries rejected"

main()
