## Compare the exact packed-record and sorting-key wires with Lean and bits.
import std/[os,osproc,strutils]
import cps/zk/[r1cs,memory_consistency]

proc hex(value: Scalar): string =
  for b in encodeScalar(value): result.add toHex(b,2).toLowerAscii()
proc line(value: Linear): string =
  result = $value.len
  for term in value: result.add " " & $term.wire & ":" & hex(term.coefficient)
proc maxBits(width: int): uint64 =
  if width == 64: high(uint64) else: (1'u64 shl width)-1
proc putBits(outBytes: var array[32,byte], value: uint64, width, offset: int) =
  for bit in 0..<width:
    if ((value shr bit) and 1) != 0:
      let position = offset+bit
      outBytes[31-position div 8] = outBytes[31-position div 8] or (1'u8 shl (position mod 8))

proc main() =
  if paramCount() != 2: quit("usage: test_memory_layout CHECKER DIRECTORY",1)
  let checker = absolutePath(paramStr(1))
  let directory = absolutePath(paramStr(2))
  createDir(directory)
  var text = "ZKMEMLAYOUT1 80\n"
  var cases = 0
  for a in [1,8,32,64]:
    for t in [0,1,8,32,64]:
      for v in [1,8,32,64]:
        var c = initCircuit()
        let access = MemoryAccessWires(active: c.publicInput(scalar(0)),write: c.publicInput(scalar(0)),
          address: c.publicInput(scalar(0)),value: c.publicInput(scalar(0)))
        let clock = c.publicInput(scalar(0))
        let packed = pack(access,clock,t,v)
        let order = orderKey(TimedMemoryWires(access: access,clock: clock),a,t)
        text.add "C " & $a & " " & $t & " " & $v & "\n" & line(packed) & "\n" & line(order) & "\n"
        for sample in 0..2:
          let active = uint64(ord(sample == 1))
          let write = uint64(ord(sample != 0))
          let address = if sample == 0: 0'u64 else: maxBits(a)
          let value = if sample == 0: 0'u64 else: maxBits(v)
          let time = if sample == 0: 0'u64 else: maxBits(t)
          for i,n in [active,write,address,value,time]: c.values[i+1] = scalar(n)
          var expected,expectedOrder: array[32,byte]
          putBits(expected,value,v,0)
          putBits(expected,write,1,v)
          putBits(expected,active,1,v+1)
          putBits(expected,time,t,v+2)
          putBits(expected,address,a,v+2+t)
          putBits(expectedOrder,time,t,0)
          putBits(expectedOrder,address,a,t)
          putBits(expectedOrder,1-active,1,t+a)
          doAssert encodeScalar(packed.evaluate(c.values)) == expected,"record bit layout"
          doAssert encodeScalar(order.evaluate(c.values)) == expectedOrder,"sorting key bit layout"
        inc cases
  let path = directory / "layout.txt"
  writeFile(path,text)
  let good = execCmdEx(quoteShell(checker) & " " & quoteShell(path))
  doAssert good.exitCode == 0,good.output
  stdout.write good.output
  let original = text.splitLines()
  var rejected = 0
  proc reject(name: string, data: seq[string]) =
    let path = directory / (name & ".txt")
    writeFile(path,data.join("\n"))
    let response = execCmdEx(quoteShell(checker) & " " & quoteShell(path))
    doAssert response.exitCode != 0,"accepted forged memory layout " & name
    inc rejected
  for index in [2,3,2+3*79,3+3*79]:
    var changed = original
    changed[index] = "1 0:" & repeat('0',64)
    reject("expression-" & $index,changed)
  var changed = original
  swap(changed[2],changed[3])
  reject("field-order",changed)
  changed = original
  changed[1] = "C 1 1 1"
  reject("width",changed)
  changed = original
  changed[4] = changed[1]
  reject("duplicate-profile",changed)
  changed = original
  changed[2] = "1 0:" & repeat('f',64)
  reject("noncanonical",changed)
  changed = original
  changed.setLen(changed.len-4)
  reject("truncated",changed)
  changed = original
  changed.add "trailing"
  reject("trailing",changed)
  echo "memory layout regression PASS: ",cases," profiles, 240 bit-layout checks, ",rejected," forgeries rejected"

main()
