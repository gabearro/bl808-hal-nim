## Test-only capture of the actual pinned FIPS routine. The dependency's hook
## is compiled out unless zkbuildFipsTrace is explicitly enabled.
import cps/zk/field
import constantine/named/properties_fields

type
  FipsWords* = array[8, uint32]
  FipsRow* = array[13, uint32]
  FipsCase* = object
    a*, b*, expected*: FipsWords
    trace*: array[17, FipsRow]

var
  recordedFips*: array[17, FipsRow]
  recordedCount*: int
  recording: bool

proc zkbuildRecordFips(stage, column: cint, words: ptr UncheckedArray[uint32],
    t, u, v: uint32) {.exportc, cdecl, raises: [].} =
  if not recording: return
  if recordedCount < recordedFips.len:
    var row: FipsRow
    row[0] = uint32(stage)
    row[1] = uint32(column)
    for i in 0..<8: row[i+2] = words[i]
    row[10] = t
    row[11] = u
    row[12] = v
    recordedFips[recordedCount] = row
  inc recordedCount

proc checkFipsCase*(test: FipsCase): bool =
  static:
    doAssert WordBitWidth == 32
    doAssert defined(zkbuildFipsTrace)
  var a, b, output: BigInt[255]
  for i in 0..<8:
    a.limbs[i] = SecretWord(test.a[i])
    b.limbs[i] = SecretWord(test.b[i])
  recordedCount = 0
  recording = true
  output.getMont(a, Scalar.getModulus(), b, Scalar.getNegInvModWord(), Scalar.getSpareBits())
  recording = false
  if recordedCount != test.trace.len or recordedFips != test.trace: return false
  for i in 0..<8:
    if uint32(output.limbs[i]) != test.expected[i]: return false
  true
