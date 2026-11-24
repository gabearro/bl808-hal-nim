## Test-only capture of the pinned RV32 conversion from Montgomery form.
import cps/zk/field
import constantine/named/properties_fields

type
  CiosWords* = array[8, uint32]
  CiosRow* = array[13, uint32]
  CiosCase* = object
    input*, expected*: CiosWords
    trace*: array[73, CiosRow]

var
  recordedCios*: array[73, CiosRow]
  recordedCount*: int
  recording: bool

proc zkbuildRecordCios(outer, column: cint, words: ptr UncheckedArray[uint32],
    m, carry, low: uint32) {.exportc, cdecl, raises: [].} =
  if not recording: return
  if recordedCount < recordedCios.len:
    var row: CiosRow
    row[0] = uint32(outer)
    row[1] = uint32(column)
    for i in 0..<8: row[i+2] = words[i]
    row[10] = m
    row[11] = carry
    row[12] = low
    recordedCios[recordedCount] = row
  inc recordedCount

proc checkCiosCase*(test: CiosCase): bool =
  static:
    doAssert WordBitWidth == 32
    doAssert defined(zkbuildCiosTrace)
  var input, output: BigInt[255]
  for i in 0..<8: input.limbs[i] = SecretWord(test.input[i])
  recordedCount = 0
  recording = true
  output.fromMont(input, Scalar.getModulus(), Scalar.getNegInvModWord(), Scalar.getSpareBits())
  recording = false
  if recordedCount != test.trace.len or recordedCios != test.trace: return false
  for i in 0..<8:
    if uint32(output.limbs[i]) != test.expected[i]: return false
  true
