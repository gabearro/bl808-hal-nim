## Exhaustive conformance of the production Nim R1CS row gadget against the
## transition table exported from the proved Lean reference model.
import std/[os, strutils]
import cps/zk/[r1cs, wasm_bytes_circuit]

proc fail(message: string) {.noreturn.} = raise newException(ValueError, message)

proc indexOfOne(values: openArray[Linear], c: Circuit): int =
  result = -1
  for i, value in values:
    let v = value.evaluate(c.values)
    if v.equals(scalar(1)):
      if result != -1: fail("non-one-hot state")
      result = i
    elif not v.zero(): fail("non-Boolean state")
  if result == -1: fail("empty state")

if paramCount() != 1: fail("usage: test_zkbuild_model ROW_TABLE")
var checked = 0
for line in lines(paramStr(1)):
  let fields = line.splitWhitespace()
  if fields.len != 45: fail("bad reference table record")
  let phase = parseInt(fields[0])
  let height = parseInt(fields[1])
  let value = parseInt(fields[2])
  let expectedPhase = parseInt(fields[3])
  let expectedHeight = parseInt(fields[4])
  if phase != checked div (9*256) or height != (checked div 256) mod 9 or value != checked mod 256:
    fail("reference table is incomplete or out of order")
  var c = initCircuit()
  var bits: array[8, Linear]
  for i in 0..<8: bits[i] = c.bit((value and (1 shl i)) != 0)
  let next = c.appendByteRow(initParserWires(phase, height), bits, value.byte)
  # The template uses 25 symbolic input wires, followed by these 40 fresh
  # selector/product wires. This test supplies its state as constants and its
  # byte as 8 bit wires, so the same fresh values start at wire 9 here.
  if c.values.len != 49: fail("row witness shape changed")
  for auxiliary in 0..<40:
    let expected = scalar(parseInt(fields[5 + auxiliary]))
    if not c.values[9 + auxiliary].equals(expected):
      fail("incorrect auxiliary witness at " & $auxiliary & " for row " &
        $phase & " " & $height & " " & $value)
  if expectedPhase < 0:
    if c.satisfied(): fail("accepted invalid row " & line)
  else:
    if not c.satisfied(): fail("rejected valid row " & line)
    let phases = @[next.ready, next.index] & @(next.leb) & @[next.done]
    if indexOfOne(phases, c) != expectedPhase or indexOfOne(next.depths, c) != expectedHeight:
      fail("incorrect successor row " & line)
  if phase == 0:
    var cheating = initCircuit()
    var originalBits: array[8, Linear]
    for i in 0..<8: originalBits[i] = cheating.bit((value and (1 shl i)) != 0)
    discard cheating.appendByteRow(initParserWires(phase, height), originalBits, byte(value xor 1))
    if cheating.satisfied(): fail("unbound opcode witness " & line)
  inc checked
if checked != 8*9*256: fail("incomplete reference table")
echo "zkbuild model conformance: PASS (", checked, " exhaustive rows, ",
  checked * 40, " auxiliary witness values)"
