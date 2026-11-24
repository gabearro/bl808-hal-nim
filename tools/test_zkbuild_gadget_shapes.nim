## Compare the real Nim primitives to Lean's independently generated matrices.
## No private witness is exported; equality therefore covers all assignments.
import std/[os,strutils,osproc]
import cps/zk/[r1cs,range_check]

type
  Case = object
    kind,width: int
    literal: Scalar
  Built = object
    circuit: Circuit
    outputs: seq[Linear]

proc build(test: Case, probe = 0): Built =
  result.circuit = initCircuit(reuseRangeWitnesses = test.kind in [8,11,12,13,14,15,16])
  let x = result.circuit.publicInput(scalar(probe))
  let y = result.circuit.publicInput(scalar(probe*2))
  let z = result.circuit.publicInput(scalar(probe*3))
  let a = x+y.scale(scalar(2))-z.scale(scalar(3))
  template c: untyped = result.circuit
  case test.kind
  of 0: result.outputs = @[c.multiply(a,z)]
  of 1: result.outputs = @[c.materialize(a)]
  of 2: result.outputs = @[c.bit(probe != 0)]
  of 3:
    c.constrainBoolean(a)
    result.outputs = @[a]
  of 4: result.outputs = @[c.zeroIndicator(a)]
  of 5: result.outputs = @[c.selectWire(x,y,z)]
  of 6: result.outputs = @[c.select(x,y,z)]
  of 7: result.outputs = c.constrainUnsigned(x,test.width)
  of 8,9:
    result.outputs = c.constrainUnsigned(x,test.width)
    result.outputs.add c.constrainUnsigned(x,test.width)
  of 10: result.outputs = c.constrainUnsigned(a,test.width)
  of 11:
    result.outputs = c.constrainUnsigned(a,test.width)
    result.outputs.add c.constrainUnsigned(a,test.width)
  of 12:
    result.outputs = c.constrainUnsigned(x,test.width)
    result.outputs.add c.constrainUnsigned(x,(test.width+1) mod 249)
  of 15:
    let value = x.scale(scalar(2))
    result.outputs = c.constrainUnsigned(value,test.width)
    result.outputs.add c.constrainUnsigned(value,test.width)
  of 16:
    result.outputs = c.constrainUnsigned(x,test.width)
    result.outputs.add c.constrainUnsigned(y,test.width)
  of 13,14:
    var value = @[Term(wire: 0,coefficient: test.literal)]
    if test.kind == 14: value = value+constant(-1)+constant(1)
    result.outputs = c.constrainUnsigned(value,test.width)
  else: raise newException(ValueError,"unknown test gadget")

proc same(a,b: seq[Linear]): bool =
  if a.len != b.len: return false
  for i in 0..<a.len:
    if a[i].len != b[i].len: return false
    for j in 0..<a[i].len:
      if a[i][j].wire != b[i][j].wire or not a[i][j].coefficient.equals(b[i][j].coefficient): return false
  true

proc hex(value: Scalar): string =
  for b in encodeScalar(value): result.add toHex(b,2).toLowerAscii()

proc line(value: Linear): string =
  result = $value.len
  for term in value: result.add " " & $term.wire & ":" & hex(term.coefficient)

proc main() =
  if paramCount() != 2: quit("usage: test_zkbuild_gadget_shapes CHECKER OUTPUT_DIR",1)
  let checker = absolutePath(paramStr(1))
  let directory = absolutePath(paramStr(2))
  createDir(directory)
  var cases: seq[Case]
  for kind in 0..6: cases.add Case(kind: kind)
  for width in 0..248:
    for kind in 7..9: cases.add Case(kind: kind,width: width)
  for width in [0,1,3,8,31,32,63,64,127,128,247,248]:
    for kind in [10,11,12,15,16]: cases.add Case(kind: kind,width: width)
  for width in 0..248:
    let limit = scalar(2).power(uint64(width))
    for literal in [scalar(0),scalar(1),limit-scalar(1),limit,scalar(-1)]:
      for kind in 13..14: cases.add Case(kind: kind,width: width,literal: literal)
  let path = directory / "gadgets.txt"
  let file = open(path,fmWrite)
  file.writeLine("ZKGADGETS1 ",cases.len)
  var gates = 0
  for test in cases:
    let actual = build(test)
    let alternate = build(test,3)
    doAssert actual.circuit.sameShape(alternate.circuit),"witness-dependent gadget matrix"
    doAssert same(actual.outputs,alternate.outputs),"witness-dependent returned expression"
    file.writeLine(test.kind," ",test.width," ",hex(test.literal))
    let c = actual.circuit
    file.writeLine("ZKR1CS1 ",c.values.len," ",c.publicCount," ",c.constraints.len," ",actual.outputs.len)
    for gate in c.constraints:
      for side in [gate.a,gate.b,gate.c]: file.writeLine(line(side))
    for output in actual.outputs: file.writeLine(line(output))
    gates += c.constraints.len
  file.close()
  let checked = execCmdEx(quoteShell(checker) & " " & quoteShell(path))
  stdout.write checked.output
  doAssert checked.exitCode == 0,"Lean rejected production gadget matrices"
  let source = readFile(path)
  let lines = source.splitLines()
  var failures = 0
  proc reject(name: string, data: string) =
    let path = directory / (name & ".txt")
    writeFile(path,data)
    let outcome = execCmdEx(quoteShell(checker) & " " & quoteShell(path))
    doAssert outcome.exitCode != 0,"Lean accepted mutated " & name
    inc failures
  var changed = lines
  changed[2] = "ZKR1CS1 99 3 1 1"
  reject("dimensions",changed.join("\n"))
  changed = lines
  changed[3][^1] = '1'
  reject("coefficient",changed.join("\n"))
  changed = lines
  changed[6] = "1 1:" & hex(scalar(1))
  reject("output",changed.join("\n"))
  changed = lines
  changed[1] = "0 249 " & hex(scalar(0))
  reject("width",changed.join("\n"))
  changed = lines
  changed.delete(4)
  reject("missing-gate-side",changed.join("\n"))
  reject("truncated",source[0..<source.len div 2])
  reject("trailing",source & "0\n")
  reject("empty-coverage","ZKGADGETS1 0\n")
  changed = lines
  changed[3] = "3 1:" & repeat('f',64) & " " & changed[3].splitWhitespace()[2..^1].join(" ")
  reject("noncanonical-scalar",changed.join("\n"))
  changed = lines
  changed[3] = changed[3].replace("1:","9999:")
  reject("invalid-wire",changed.join("\n"))
  changed = lines
  changed[3][0] = '4'
  reject("term-count",changed.join("\n"))
  changed = lines
  changed[1] = "17 0 " & hex(scalar(0))
  reject("unknown-gadget",changed.join("\n"))
  changed = lines
  changed[2] = "ZKR1CS1 5 2 1 1"
  reject("public-partition",changed.join("\n"))
  echo "gadget matrix PASS: ",cases.len," cases, ",gates," constraints, ",failures," rejected mutations"

main()
