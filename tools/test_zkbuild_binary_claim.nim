## Compare the public claim with its canonical big-endian scalar encoding,
## independently of the arithmetic used by the packing routine.
import cps/zk/wasm_binary_claim

proc require(ok: bool, message: string) =
  if not ok: raise newException(ValueError, message)

var cases: int
for length in [0,1,2,30,31,32,61,62,63,127,128]:
  var data = newSeq[byte](length)
  for i in 0..<length: data[i] = byte((i*173+255) and 255)
  for extra in [0,1,30,31,64]:
    let capacity = length+extra
    let values = binarySourceInputs(data, capacity)
    require(values.len == 1+binarySourceLimbCount(capacity), "claim dimensions")
    let encodedLength = encodeScalar(values[0])
    for i in 0..31:
      let expected = if i == 31: byte(length) else: 0'u8
      require(encodedLength[i] == expected, "actual length, not capacity")
    for limb in 1..<values.len:
      let bytes = encodeScalar(values[limb])
      require(bytes[0] == 0, "31-byte limbs are canonical")
      for j in 0..<31:
        let position = (limb-1)*31+j
        let expected = if position < data.len: data[position] else: 0'u8
        require(bytes[31-j] == expected, "little-endian source and zero padding")
    inc cases
for badCapacity in [-1,0,1]:
  var rejected = false
  try: discard binarySourceInputs([1'u8,2], badCapacity)
  except ValueError: rejected = true
  require(rejected, "invalid claim capacity")
require(binarySourceLimbCount(high(int)) > 0, "limb count does not overflow")
echo "zkbuild binary claim: PASS (", cases, " canonical length/limb cases; invalid capacities)"
