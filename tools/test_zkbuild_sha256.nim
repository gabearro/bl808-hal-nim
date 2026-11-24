import std/[os,strutils]
import cps/zk/[r1cs,sha256_circuit,wasm_digest_claim,prover]

proc require(ok: bool, message: string) =
  if not ok: raise newException(ValueError,message)

proc digestHex(digest: Sha256Digest): string =
  for b in digest: result.add toHex(b,2).toLowerAscii()

proc build(data: seq[byte], capacity: int, digest: Sha256Digest): Circuit =
  result = initCircuit(reuseRangeWitnesses = true)
  let values = digestInputs(digest)
  let output = [result.publicInput(values[0]),result.publicInput(values[1])]
  let length = result.allocate(scalar(data.len))
  var bytes: seq[Linear]
  for i in 0..<capacity: bytes.add result.allocate(scalar(if i < data.len: data[i] else: 0'u8))
  result.constrainSha256(bytes,length,output)

proc main() =
  require(digestHex(sha256([])) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", "empty known answer")
  require(digestHex(sha256([97'u8,98,99])) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "abc known answer")
  var common: Circuit
  var cases = 0
  # Independent Python hashlib oracle, retained as fixed regression answers.
  const Expected = [
    "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    "a8100ae6aa1940d0b663bb31cd466142ebbdbd5187131b92d93818987832eb89",
    "1d029e62a62538764dcb402e2a4f35ebb08802a823341b44ae52b45551be494b",
    "c06f5aa56e55244f995c01403bcff530cf1b5e46cb377f789875273e69ee62d5",
    "f1cd040eea87351ba997559e0eb82826173b94aecd22c3a64784004da231f77a",
    "7f07ba9e6e2fcdb0578dc498f37b60bcd22e607d35f1e4a035d4105d69a4141d",
    "123673bc6250b4330e9a8905bcdbcefb96fd946ea7131581a27a0ae20afe3b8f",
    "9320b0b878cf24c2d0b2690544cfe07991fb72278a88396bc8a515104f53d543",
    "6cc37ec13f87c494059b116f331c6a898c36abaf1c5aa4ed9b645d0aaf6cc93b",
    "e16f1f8106aef356f1a08367f03dbcf857fc8fb2287e84d33ddd471eb9e73de3",
    "5cc6bad430c95f0f61e6c6bbc6a11b209135eca6bf614af586bfcd60a7b10458",
    "1af15d8ed818d7cf8a3c7f9fae74f92126f0c38390f87203c8d3b4200768c4ef",
    "e20df852913f1a80996be6d50827917ab0953160b3cdda18ce0974f094670da2",
    "67b3702c5dec0e000bd2835271d9bcdee8cea182cc88d1d47e356dd7bc4615a5"]
  for length in [0,1,3,31,55,56,57,63,64,65,119,120,127,128]:
    var data = newSeq[byte](length)
    for i in 0..<length: data[i] = byte((i*131+255) and 255)
    require(digestHex(sha256(data)) == Expected[cases],"independent digest oracle " & $length)
    let circuit = build(data,128,sha256(data))
    require(circuit.satisfied(), "SHA-256 boundary " & $length)
    if length == 0: common = circuit
    else: require(circuit.sameShape(common), "SHA-256 shape depends on private length")
    inc cases
  for capacity in [0,1,55,56,63,64,119,120,127]:
    var data = newSeq[byte](capacity)
    for i in 0..<capacity: data[i] = byte(i and 255)
    require(build(data,capacity,sha256(data)).satisfied(),"maximal input at capacity " & $capacity)
    inc cases
  let abc = @[97'u8,98,99]
  let a = build(abc,8,sha256(abc))
  require(a.satisfied(), "one-block SHA circuit")
  var badDigest = sha256(abc)
  badDigest[31] = badDigest[31] xor 1
  require(not build(abc,8,badDigest).satisfied(),"changed digest")
  var bad = build(abc,8,sha256(abc))
  bad.values[3] = scalar(2)
  require(not bad.satisfied(),"changed private length")
  bad = build(abc,8,sha256(abc))
  bad.values[4] = scalar(98)
  require(not bad.satisfied(),"changed private input")
  bad = build(abc,8,sha256(abc))
  bad.values[4+3] = scalar(1)
  require(not bad.satisfied(),"nonzero unused input")
  bad = build(abc,8,sha256(abc))
  bad.values[3] = scalar(9)
  require(not bad.satisfied(),"length beyond capacity")
  bad = build(abc,8,sha256(abc))
  bad.values[3] = scalar(4294967296'u64)
  require(not bad.satisfied(),"length beyond u32")
  bad = build(abc,8,sha256(abc))
  bad.values[4] = scalar(256)
  require(not bad.satisfied(),"non-byte input")
  if paramCount() == 0 or paramStr(1) != "--check-only":
    let second = @[120'u8,121]
    let b = build(second,8,sha256(second))
    require(a.sameShape(b),"SHA proof shape")
    let key = setup(a)
    for circuit in [a,b]:
      let proof = encodeProof(prove(key,circuit))
      require(decodeAndVerify(key.verificationKey,proof,circuit.values[1..2]),"SHA proof")
  echo "zkbuild SHA-256: PASS (",cases," length/capacity boundaries; seven forgeries; ",a.constraints.len," one-block constraints)"

main()
