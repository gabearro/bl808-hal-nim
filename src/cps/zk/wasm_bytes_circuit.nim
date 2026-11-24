## Circuit for the actual WASM byte stream. Parser states, section lengths,
## LEB termination/sign extension, stack transitions and every byte are bound.
import r1cs, wasm_bytes
export wasm_bytes

proc total(values: openArray[Linear]): Linear =
  for value in values: result = result + value

proc weighted(bits: openArray[Linear]): Linear =
  var weight = scalar(1)
  for bit in bits:
    result = result + bit.scale(weight)
    weight = weight * scalar(2)

type ParserWires* = object
  ready*, index*, done*: Linear
  leb*: array[5, Linear]
  depths*: array[9, Linear]

proc initParserWires*(phase = 0, depth = 0): ParserWires =
  if phase < 0 or phase > 7 or depth < 0 or depth > MaxStack:
    raise newException(ValueError, "invalid initial parser state")
  result.ready = constant(ord(phase == 0))
  result.index = constant(ord(phase == 1))
  result.done = constant(ord(phase == 7))
  for i in 0..<5: result.leb[i] = constant(ord(phase == i+2))
  for i in 0..8: result.depths[i] = constant(ord(depth == i))

type ByteRowDetails* = object
  before*: ParserWires
  after*: ParserWires
  selected*: array[ByteAction, Linear]
  finishConst*, binary*: Linear

proc appendByteRowImpl(c: var Circuit, state: ParserWires,
                       bits: array[8, Linear], opcodeHint: byte, retain: static bool): ByteRowDetails =
  ## This is the production transition gadget, also exercised directly by
  ## exhaustive conformance tests against the Lean transition table.
  when retain: result.before = state
  let value = weighted(bits)
  let continuation = bits[7]
  let terminate = constant(1) - continuation
  c.constrain(state.done, value, constant(0))
  var selected: array[ByteAction, Linear]
  var selectedValue: Linear
  let wantsOpcode = state.ready.evaluate(c.values).equals(scalar(1))
  for action in ByteAction:
    selected[action] = c.bit(wantsOpcode and opcodeHint == ActionCodes[action])
    selectedValue = selectedValue + selected[action].scale(scalar(ActionCodes[action]))
  c.assertEqual(total(selected), state.ready)
  c.constrain(state.ready, value, selectedValue)
  for bit in 1 ..< 8: c.constrain(state.index, bits[bit], constant(0))
  c.constrain(state.leb[4], continuation, constant(0))
  for bit in 4 .. 6:
    c.constrain(state.leb[4], bits[bit]-bits[3], constant(0))
  let finishConst = c.multiply(total(state.leb), terminate)
  let push = state.index + finishConst
  var binary: Linear
  for action in baAdd .. baXor: binary = binary + selected[action]
  c.constrain(binary, state.depths[0] + state.depths[1], constant(0))
  let keep = constant(1) - push - binary
  for depth in 0 .. 8:
    result.after.depths[depth] = c.multiply(state.depths[depth], keep)
    if depth > 0:
      result.after.depths[depth] = result.after.depths[depth] + c.multiply(state.depths[depth-1], push)
    if depth < 8:
      result.after.depths[depth] = result.after.depths[depth] + c.multiply(state.depths[depth+1], binary)
  c.assertEqual(total(result.after.depths), constant(1))
  c.constrain(selected[baEnd], state.depths[1]-constant(1), constant(0))
  result.after.leb[0] = selected[baConst]
  for i in 1 .. 4: result.after.leb[i] = c.multiply(state.leb[i-1], continuation)
  result.after.ready = selected[baNop] + binary + state.index + finishConst
  result.after.index = selected[baGet]
  # The phase sum is one by construction. The existing selector-sum and
  # fifth-LEB constraints imply this residual equals state.done + end.
  # See R1CS.phase_residual_done in the Lean model. This saves two gates per
  # row and keeps the complete relation below the 8192-point QAP boundary.
  result.after.done = constant(1) - result.after.ready - result.after.index - total(result.after.leb)

  when retain:
    result.selected = selected
    result.finishConst = finishConst
    result.binary = binary

proc appendByteRowDetailed*(c: var Circuit, state: ParserWires,
                           bits: array[8, Linear], opcodeHint: byte): ByteRowDetails =
  c.appendByteRowImpl(state, bits, opcodeHint, true)

proc appendByteRow*(c: var Circuit, state: ParserWires,
                    bits: array[8, Linear], opcodeHint: byte): ParserWires =
  c.appendByteRowImpl(state, bits, opcodeHint, false).after

type ByteCircuitDetails* = object
  circuit*: Circuit
  bits*: array[StreamWasmMaxSize, array[8, Linear]]
  rows*: seq[ByteRowDetails]

proc buildByteCircuitImpl(wasm: openArray[byte], retain: static bool): ByteCircuitDetails =
  if wasm.len < StreamWasmMinSize or wasm.len > StreamWasmMaxSize:
    raise newException(ValueError, "WASM length is outside byte-stream profile")
  result.circuit = initCircuit()
  var public: seq[Linear]
  for value in publicInputs(pmValidateBytes, wasm, []):
    public.add result.circuit.publicInput(value)
  var bytes: array[StreamWasmMaxSize, Linear]
  var bits: array[StreamWasmMaxSize, array[8, Linear]]
  for i in 0 ..< StreamWasmMaxSize:
    let value = if i < wasm.len: wasm[i] else: 0'u8
    for j in 0 ..< 8: bits[i][j] = result.circuit.bit((value and (1'u8 shl j)) != 0)
    bytes[i] = weighted(bits[i])
  # Bind all padded bytes into the public limbs. Public length disambiguates
  # raw modules whose last limb has zero-valued high bytes.
  var limb = 1
  var packed: Linear
  var weight = scalar(1)
  for i in 0 ..< StreamWasmMaxSize:
    packed = packed + bytes[i].scale(weight)
    weight = weight * scalar(256)
    if i mod 31 == 30 or i == StreamWasmMaxSize-1:
      result.circuit.assertEqual(packed, public[limb])
      inc limb
      packed = @[]
      weight = scalar(1)
  for i, value in WasmPrefix:
    case i
    of 25..27: result.circuit.assertEqual(bits[i][7], constant(0))
    of 31: result.circuit.assertEqual(bytes[i], public[0] - constant(32))
    of 33: result.circuit.assertEqual(bytes[i], public[0] - constant(34))
    else: result.circuit.assertEqual(bytes[i], constant(value))

  var state = initParserWires()
  var processed = constant(0)
  for position in WasmPrefix.len ..< StreamWasmMaxSize:
    let value = if position < wasm.len: wasm[position] else: 0'u8
    processed = processed + constant(1) - state.done
    let row = result.circuit.appendByteRowImpl(state, bits[position], value, retain)
    when retain: result.rows.add row
    state = row.after
  result.circuit.assertEqual(state.done, constant(1))
  result.circuit.assertEqual(processed, public[0] - constant(WasmPrefix.len))
  when retain: result.bits = bits

proc buildByteCircuitDetailed*(wasm: openArray[byte]): ByteCircuitDetails =
  buildByteCircuitImpl(wasm, true)

proc buildByteCircuit*(wasm: openArray[byte]): Circuit =
  buildByteCircuitImpl(wasm, false).circuit
