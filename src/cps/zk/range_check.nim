## Fixed-width range constraints, with canonical field witnesses.
import r1cs
import std/tables

proc copyBits(bits: seq[Linear]): seq[Linear] =
  for bit in bits: result.add @bit

proc constrainUnsigned*(c: var Circuit, value: Linear, width: int): seq[Linear] =
  ## The bound is strict: value < 2^width as an integer, not modulo the field.
  ## 248 bits stay below the BLS12-381 scalar modulus. Width zero forces zero.
  if width < 0 or width > 248:
    raise newException(ValueError, "unsupported unsigned range width")
  let audit = c.auditBegin()
  if c.reuseRangeWitnesses:
    var literal = true
    var number = scalar(0)
    for term in value:
      if term.wire != 0: literal = false; break
      number = number+term.coefficient
    if literal:
      let bytes = encodeScalar(number)
      var packed = scalar(0)
      var weight = scalar(1)
      for i in 0..<width:
        let bit = (bytes[31-i div 8] and (1'u8 shl (i mod 8))) != 0
        result.add constant(ord(bit))
        if bit: packed = packed+weight
        weight = weight+weight
      if not packed.equals(number): c.assertEqual(constant(0), constant(1))
      discard c.auditFinish(audit,gkLiteralUnsigned,[value],result,width)
      return
  # Reuse is structural: the same unit-coefficient wire and exact width.
  # Values, scaled expressions, constants, and other circuits are not keys.
  let reusable = c.reuseRangeWitnesses and value.len == 1 and value[0].wire > 0 and
    value[0].coefficient.equals(scalar(1))
  let key = (wire: (if reusable: value[0].wire else: 0), width: width)
  if reusable and c.rangeWitnesses.hasKey(key):
    result = copyBits(c.rangeWitnesses[key])
    when defined(zkbuildGadgetAudit):
      if not c.auditRangeSources.hasKey(key): raise newException(ValueError,"missing audited range source")
      discard c.auditFinish(audit,gkReusedUnsigned,[value],result,width,c.auditRangeSources[key])
    return
  let bytes = encodeScalar(value.evaluate(c.values))
  var packed: Linear
  var weight = scalar(1)
  for i in 0..<width:
    let bit = c.bit((bytes[31-i div 8] and (1'u8 shl (i mod 8))) != 0)
    result.add bit
    packed = packed+bit.scale(weight)
    # Explicit doubling also avoids Nim 2.2.6's VM failure while resolving
    # Constantine's static-scalar *= overload in combined circuit modules.
    weight = weight+weight
  c.assertEqual(value, packed)
  if reusable: c.rangeWitnesses[key] = copyBits(result)
  let record = c.auditFinish(audit,gkUnsigned,[value],result,width)
  when defined(zkbuildGadgetAudit):
    if reusable: c.auditRangeSources[key] = record

proc constrainBoolean*(c: var Circuit, value: Linear) =
  let audit = c.auditBegin()
  c.constrain(value, value-constant(1), constant(0))
  discard c.auditFinish(audit,gkBoolean,[value],[])

proc zeroIndicator*(c: var Circuit, value: Linear): Linear =
  ## Two constraints imply indicator=1 exactly when value=0, otherwise 0.
  let audit = c.auditBegin()
  let actual = value.evaluate(c.values)
  result = c.allocate(scalar(ord(actual.zero())))
  let reciprocal = c.allocate(if actual.zero(): scalar(0) else: actual.inverse())
  c.constrain(value, result, constant(0))
  c.constrain(value, reciprocal, constant(1)-result)
  discard c.auditFinish(audit,gkZero,[value],[result,reciprocal])
