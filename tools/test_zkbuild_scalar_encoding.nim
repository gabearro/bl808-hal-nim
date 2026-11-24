## Compare the production canonical scalar gate to Lean's integer specification.
import std/[os, osproc, strutils]
import cps/zk/[field, scalar_encoding, scalar_words]
import constantine/named/properties_fields

proc require(condition: bool, message: string) =
  if not condition: raise newException(ValueError, message)

proc unhex(value: string): seq[byte] =
  if value == "-": return @[]
  require(value.len mod 2 == 0, "odd scalar fixture length")
  for i in countup(0, value.len-1, 2): result.add byte(parseHexInt(value[i..i+1]))

proc oldPredicate(bytes: array[32, byte], modulus: BigInt[255]): bool =
  if (bytes[0] and 0x80) != 0: return false
  var raw: BigInt[255]
  discard raw.unmarshal(bytes, bigEndian)
  not bool(raw >= modulus)

func rawBytes(value: BigInt[255]): array[32, byte] =
  discard result.marshal(value, bigEndian)

proc readParameter(reference: File, name: string): string =
  let row = reference.readLine().splitWhitespace()
  require(row.len == 2 and row[0] == name, "scalar parameter " & name)
  row[1]

proc main() =
  require(paramCount() == 2, "usage: test_zkbuild_scalar_encoding EXPORTER WORK_DIR")
  let exporter = absolutePath(paramStr(1))
  let work = absolutePath(paramStr(2))
  createDir(work)
  let path = work / "scalar-vectors.txt"
  let generated = execCmdEx(quoteShell(exporter) & " " & quoteShell(path))
  require(generated.exitCode == 0, "scalar oracle failed: " & generated.output)
  let reference = open(path)
  defer: reference.close()
  require(reference.readLine() == "ZKSCALAR3 131072 25670", "scalar fixture header")
  let header = reference.readLine().splitWhitespace()
  require(header.len == 2 and header[0] == "MODULUS", "scalar modulus header")
  require(unhex(header[1]) == @ScalarModulusBE, "scalar modulus differs from formal constant")
  var modulus: BigInt[255]
  modulus.fromHex("0x" & header[1])
  require(@(rawBytes(Scalar.getModulus())) == @ScalarModulusBE, "backend scalar modulus")
  require(@(rawBytes(Scalar.getR2modP())) == unhex(readParameter(reference, "R2")), "backend Montgomery R2")
  require(@(rawBytes(Scalar.getMontyOne())) == unhex(readParameter(reference, "ONE")), "backend Montgomery one")
  let n32 = parseBiggestUInt(readParameter(reference, "N32"))
  let n64 = parseBiggestUInt(readParameter(reference, "N64"))
  require(uint64(Scalar.getNegInvModWord()) == (when WordBitWidth == 32: n32 else: n64),
    "backend Montgomery negative inverse")
  let radix = scalar(256)
  var borrowCases, vectorCases, acceptedCases, rejectedCases, malformedCases, wordCases: int
  for a in 0..255:
    for b in 0..255:
      for incoming in 0..1:
        let row = reference.readLine().splitWhitespace()
        require(row.len == 5 and row[0] == "B", "borrow fixture")
        require(parseInt(row[1]) == a and parseInt(row[2]) == b and parseInt(row[3]) == incoming,
          "borrow fixture order")
        let expected = parseInt(row[4])
        require(int(scalarBorrowStep(byte(a), byte(b), uint16(incoming))) == expected,
          "16-bit borrow differs from formal model")
        inc borrowCases
  for _ in 0..<25670:
    let row = reference.readLine().splitWhitespace()
    require(row.len == 4 and row[0] == "V", "encoding fixture")
    let bytes = unhex(row[3])
    require(bytes.len == parseInt(row[1]), "encoding fixture length")
    let expected = row[2] == "1"
    require(isCanonicalScalarEncoding(bytes) == expected, "canonical scalar integer bound")
    if bytes.len == 32:
      var encoded: array[32, byte]
      for i in 0..<32: encoded[i] = bytes[i]
      let words32 = scalarWords[uint32](encoded)
      let words64 = scalarWords[uint64](encoded)
      let row32 = reference.readLine().splitWhitespace()
      let row64 = reference.readLine().splitWhitespace()
      require(row32.len == 9 and row32[0] == "W32", "32-bit word fixture")
      require(row64.len == 5 and row64[0] == "W64", "64-bit word fixture")
      for i, value in words32:
        require(uint64(value) == parseBiggestUInt(row32[i+1]), "32-bit word differs from Lean")
      for i, value in words64:
        require(value == parseBiggestUInt(row64[i+1]), "64-bit word differs from Lean")
      var original: BigInt[255]
      discard original.unmarshal(encoded, bigEndian)
      when WordBitWidth == 32:
        for i, value in words32:
          require(uint32(original.limbs[i]) == value, "pinned 32-bit limb ABI mismatch")
      else:
        for i, value in words64:
          require(uint64(original.limbs[i]) == value, "pinned 64-bit limb ABI mismatch")
      inc wordCases
      require(oldPredicate(encoded, modulus) == expected, "prior scalar predicate disagrees")
      var decoded = scalar(42)
      require(decodeScalar(encoded, decoded) == expected, "scalar decoder result")
      if expected:
        let montgomery = unhex(readParameter(reference, "M"))
        let natural = unhex(readParameter(reference, "F"))
        require(@(rawBytes(decoded.mres)) == montgomery, "raw Montgomery residue differs from Lean")
        var stored: Scalar
        stored.mres = original
        require(@(encodeScalar(stored)) == natural, "from-Montgomery residue differs from Lean")
        var numeric = scalar(0)
        for value in encoded: numeric = numeric * radix + scalar(value)
        require(decoded.equals(numeric), "decoded scalar integer value")
        require(encodeScalar(decoded) == encoded, "canonical scalar roundtrip")
        inc acceptedCases
      else:
        require(decoded.equals(scalar(42)), "rejected scalar changed destination")
        inc rejectedCases
    else:
      require(not expected, "malformed-length oracle accepted")
      inc malformedCases
    inc vectorCases
  require(reference.endOfFile(), "trailing scalar fixtures")
  require(acceptedCases > 0 and rejectedCases > 0 and malformedCases == 67, "scalar fixture coverage")
  require(wordCases == 25603, "word fixture coverage")
  echo "zkbuild scalar encoding: PASS (", borrowCases, " borrow cases, ", vectorCases,
    " encodings, ", wordCases, " dual-width word arrays, ", acceptedCases,
    " direct Montgomery conversions in each direction; ", WordBitWidth, "-bit backend)"

main()
