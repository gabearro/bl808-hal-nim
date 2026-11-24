## Exact low/high field extraction from a bounded unsigned word.
import r1cs, range_check

proc pack(c: var Circuit, bits: openArray[Linear]): Linear =
  var sum: Linear
  var weight = scalar(1)
  for bit in bits:
    sum = sum+bit.scale(weight)
    weight = weight+weight
  c.materialize(sum)

proc splitPackedFields*(c: var Circuit, value: Linear, lowWidth, highWidth: int): tuple[low,high: Linear] =
  if lowWidth < 1 or highWidth < 1 or lowWidth > 64-highWidth:
    raise newException(ValueError,"invalid packed field widths")
  when defined(zkbuildBodySourceAudit):
    let sourceBlockFirst = c.gadgets.len
    let sourceBlockGate = c.constraints.len
  let bits = c.constrainUnsigned(value,lowWidth+highWidth)
  when defined(zkbuildPackedAudit):
    var record = PackedFieldsAudit(lowWidth: lowWidth,highWidth: highWidth,
      input: copyAuditExpressions([value])[0],range: c.snapshotRangeUse(),firstGate: c.constraints.len)
  result.low = c.pack(bits.toOpenArray(0,lowWidth-1))
  result.high = c.pack(bits.toOpenArray(lowWidth,bits.high))
  when defined(zkbuildPackedAudit):
    let outputs = copyAuditExpressions([result.low,result.high])
    record.low = outputs[0]
    record.high = outputs[1]
    record.lastGate = c.constraints.len
    c.packedRecords.add record

  when defined(zkbuildBodySourceAudit):
    if c.sourceProgramActive:
      c.sourceProgramBlocks.add SourceBlockAudit(kind: 1,index: c.packedRecords.high,
        firstPrimitive: sourceBlockFirst,lastPrimitive: c.gadgets.len,
        firstGate: sourceBlockGate,lastGate: c.constraints.len)
