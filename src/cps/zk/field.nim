## BLS12-381 scalar arithmetic. All executable code is Nim.
## Constantine is pinned by tools/zkbuild_bootstrap.nim.
import constantine/named/[algebras, properties_fields]
import constantine/math/arithmetic
import constantine/math/io/[io_fields, io_bigints]
import constantine/platforms/abstractions
import scalar_encoding, scalar_words

export algebras, arithmetic, io_fields, io_bigints, abstractions

type Scalar* = Fr[BLS12_381]

# Reject a dependency/curve change that would disagree with our canonical gate.
static:
  const modulusWords = scalarWords[BaseType](ScalarModulusBE)
  const fieldModulus = Scalar.getModulus()
  doAssert fieldModulus.limbs.len == modulusWords.len
  for i, word in modulusWords:
    doAssert BaseType(fieldModulus.limbs[i]) == word

func scalar*(n: SomeInteger): Scalar = result.fromInt(n)
func `+`*(a, b: Scalar): Scalar = result.sum(a, b)
func `-`*(a, b: Scalar): Scalar = result.diff(a, b)
func `-`*(a: Scalar): Scalar = result.neg(a)
func `*`*(a, b: Scalar): Scalar = result.prod(a, b)
func equals*(a, b: Scalar): bool = bool(a == b)
func zero*(a: Scalar): bool = bool(a.isZero())

func inverse*(a: Scalar): Scalar =
  ## Callers reject zero before requesting an inverse.
  result.inv(a)

func power*(a: Scalar, n: uint64): Scalar =
  var base = a
  var e = n
  result.setOne()
  while e != 0:
    if (e and 1) != 0: result *= base
    base.square()
    e = e shr 1

func encodeScalar*(a: Scalar): array[32, byte] =
  discard result.marshal(a, bigEndian)

func decodeScalar*(bytes: array[32, byte], dst: var Scalar): bool =
  ## Reject noncanonical field encodings; never reduce untrusted inputs.
  if not isCanonicalScalarEncoding(bytes): return false
  var raw: BigInt[255]
  let words = scalarWords[BaseType](bytes)
  # This adapter targets the pinned Constantine ABI: native-width,
  # little-endian limbs. Keep upgrades subject to the conformance checks.
  static:
    doAssert WordBitWidth == 32 or WordBitWidth == 64
    doAssert sizeof(SecretWord) == sizeof(BaseType)
    doAssert raw.limbs.len == words.len
  for i in 0..<words.len: raw.limbs[i] = SecretWord(words[i])
  dst.fromBig(raw)
  true

func rootOfUnity*(n: int): Scalar =
  ## 7 is a generator of the BLS12-381 scalar multiplicative group.
  ## n must be a power of two and at most 2^32.
  var exponent: BigInt[255]
  exponent.fromHex("0x73eda753299d7d483339d80809a1d80553bda402fffe5bfeffffffff00000000")
  var k = n
  while k > 1:
    exponent.div2()
    k = k shr 1
  result = scalar(7)
  result.pow(exponent)
