## Audit-only serialization of the actual circuit and its primitive call spans.
## This metadata is never part of a proof/key and contains no witness values.
import std/strutils
import r1cs
import ../../bl808/enclave/sha256

proc hex(value: Scalar): string =
  for b in encodeScalar(value): result.add toHex(b,2).toLowerAscii()

proc linearLine(value: Linear): string =
  result = $value.len
  for term in value: result.add " " & $term.wire & ":" & hex(term.coefficient)

proc fingerprints*(c: Circuit): tuple[matrix,witness: string] =
  var matrix,witness: Sha256Ctx
  matrix.sha256Init()
  witness.sha256Init()
  var matrixBytes,witnessBytes: uint64
  template feed(ctx: var Sha256Ctx, total: var uint64, bytes: untyped) =
    block:
      let data = bytes
      if total+uint64(data.len) > uint64(high(uint32))-72:
        raise newException(ValueError,"audit fingerprint exceeds SHA-256 stream capacity")
      ctx.sha256Update(data)
      total += uint64(data.len)
  proc word(value: int): array[8,byte] =
    if value < 0: raise newException(ValueError,"negative circuit dimension")
    for i in 0..7: result[i] = byte((uint64(value) shr (8*i)) and 255)
  feed(matrix,matrixBytes,word(c.values.len))
  feed(matrix,matrixBytes,word(c.publicCount))
  feed(matrix,matrixBytes,word(c.constraints.len))
  for gate in c.constraints:
    for side in [gate.a,gate.b,gate.c]:
      feed(matrix,matrixBytes,word(side.len))
      for term in side:
        feed(matrix,matrixBytes,word(term.wire))
        feed(matrix,matrixBytes,encodeScalar(term.coefficient))
  feed(witness,witnessBytes,word(c.values.len))
  for value in c.values: feed(witness,witnessBytes,encodeScalar(value))
  for b in matrix.sha256Final(): result.matrix.add toHex(b,2).toLowerAscii()
  for b in witness.sha256Final(): result.witness.add toHex(b,2).toLowerAscii()

proc writeGadgetAudit*(path: string, c: Circuit) =
  when not defined(zkbuildGadgetAudit):
    raise newException(ValueError,"gadget audit requires -d:zkbuildGadgetAudit")
  else:
    let f = open(path,fmWrite)
    defer: f.close()
    f.writeLine("ZKAUDIT1 ",c.values.len," ",c.publicCount," ",c.constraints.len," ",c.gadgets.len)
    for gate in c.constraints:
      for side in [gate.a,gate.b,gate.c]: f.writeLine(linearLine(side))
    for row in c.gadgets:
      f.writeLine("R ",ord(row.kind)," ",row.width," ",row.firstWire," ",row.lastWire,
        " ",row.firstGate," ",row.lastGate," ",row.reference+1," ",row.inputs.len," ",row.outputs.len)
      for value in row.inputs: f.writeLine(linearLine(value))
      for value in row.outputs: f.writeLine(linearLine(value))
