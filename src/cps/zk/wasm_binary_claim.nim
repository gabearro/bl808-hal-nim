## Public inputs for a source-bound validation key: actual length followed by
## zero-padded, little-endian 31-byte limbs. No parsing or proving dependency.
import field
export field

func binarySourceLimbCount*(capacity: int): int =
  ## Division before addition also works near the signed machine-word limit.
  if capacity < 0: return -1
  capacity div 31 + ord(capacity mod 31 != 0)

proc binarySourceInputs*(data: openArray[byte], capacity: int): seq[Scalar] =
  if capacity < data.len or capacity < 0 or uint64(capacity) > uint64(high(uint32)):
    raise newException(ValueError, "invalid binary source capacity")
  result = newSeq[Scalar](1+binarySourceLimbCount(capacity))
  result[0] = scalar(data.len)
  # Convert once per limb instead of doing field arithmetic for each byte.
  # A 31-byte integer is < 2^248 < the pinned scalar modulus. Unused limbs
  # are already zero, so padding costs no scalar conversions.
  for limb in 0..<binarySourceLimbCount(data.len):
    var encoded: array[32, byte]
    let start = limb*31
    for j in 0..<min(31, data.len-start): encoded[31-j] = data[start+j]
    if not decodeScalar(encoded, result[limb+1]):
      raise newException(ValueError, "noncanonical packed source limb")
