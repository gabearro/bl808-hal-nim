import SlotBytes

/- The byte-level encoder and decoder for the fixed sixteen-slot WASM profile.
   Exact re-encoding rejects noncanonical padding, headers, and signed LEBs. -/
namespace ZkBuild.WasmEncoding

def binaryOpcode : BinOp → BitVec 8
  | .add => 0x6a
  | .sub => 0x6b
  | .mul => 0x6c
  | .band => 0x71
  | .bor => 0x72
  | .bxor => 0x73

def encodeOp : Op → List (BitVec 8)
  | .nop => [1, 1, 1, 1, 1, 1]
  | .get index => [0x20, BitVec.ofNat 8 index.val, 1, 1, 1, 1]
  | .const value => 0x41 :: SlotBytes.lebPayload value
  | .binary op => [binaryOpcode op, 1, 1, 1, 1, 1]

def header : List (BitVec 8) := CircuitShape.modulePrefix.toList.map (BitVec.ofNat 8)
def encodeWasm (ops : List Op) : List (BitVec 8) := header ++ ops.flatMap encodeOp ++ [0x0b]

def parseSlot (bytes : List (BitVec 8)) : Option Op :=
  match bytes with
  | [code, a, b, c, d, e] =>
    if code = 1 then some .nop
    else if code = 0x20 then
      if a = 0 then some (.get 0) else if a = 1 then some (.get 1) else none
    else if code = 0x41 then some (.const (decodeLeb5 (a, b, c, d, e)))
    else if code = 0x6a then some (.binary .add)
    else if code = 0x6b then some (.binary .sub)
    else if code = 0x6c then some (.binary .mul)
    else if code = 0x71 then some (.binary .band)
    else if code = 0x72 then some (.binary .bor)
    else if code = 0x73 then some (.binary .bxor)
    else none
  | _ => none

def decodeSlot (bytes : List (BitVec 8)) : Option Op :=
  (parseSlot bytes).filter fun op => decide (encodeOp op = bytes)

def decodeBody : Nat → List (BitVec 8) → Option (List Op)
  | 0, bytes => if bytes.isEmpty then some [] else none
  | count+1, bytes => do
    let op ← decodeSlot (bytes.take 6)
    let rest ← decodeBody count (bytes.drop 6)
    return op :: rest

def decodeWasm (bytes : List (BitVec 8)) : Option (List Op) :=
  (decodeBody 16 ((bytes.drop 35).take 96)).filter fun ops =>
    decide (encodeWasm ops = bytes ∧ checkProgram ops 0 = some 1)

def runWasm (bytes : List (BitVec 8)) (locals : Fin 2 → Word) : Option (List Word) :=
  (decodeWasm bytes).bind fun ops => ZkBuild.run locals ops []

theorem slot_length (op : Op) : (encodeOp op).length = 6 := by
  cases op <;> rfl

theorem header_length : header.length = 35 := by decide

theorem body_length (ops : List Op) : (ops.flatMap encodeOp).length = ops.length*6 := by
  induction ops with
  | nil => rfl
  | cons op rest ih => simp only [List.flatMap_cons, List.length_append, slot_length, ih, List.length_cons]; omega

theorem binary_length (ops : List Op) : (encodeWasm ops).length = 36+ops.length*6 := by
  simp only [encodeWasm, List.length_append, header_length, body_length, List.length_cons, List.length_nil]
  omega

theorem parse_encoded_slot (op : Op) : parseSlot (encodeOp op) = some op := by
  cases op with
  | nop => decide
  | get index =>
    have cases : index.val = 0 ∨ index.val = 1 := by have := index.isLt; omega
    rcases cases with zero | one
    · have same : index = (0 : Fin 2) := Fin.ext zero
      subst index
      decide
    · have same : index = (1 : Fin 2) := Fin.ext one
      subst index
      decide
  | const value =>
    simp only [encodeOp, SlotBytes.lebPayload, parseSlot, ↓reduceIte]
    rw [constant_leb_roundtrip]
    simp only [show (0x41 : BitVec 8) ≠ 1 from by decide,
      show (0x41 : BitVec 8) ≠ 0x20 from by decide, ite_false]
  | binary op => cases op <;> decide

theorem decode_encoded_slot (op : Op) : decodeSlot (encodeOp op) = some op := by
  simp [decodeSlot, parse_encoded_slot]

theorem decode_encoded_body (ops : List Op) : decodeBody ops.length (ops.flatMap encodeOp) = some ops := by
  induction ops with
  | nil => rfl
  | cons op rest ih =>
    simp only [List.length_cons, List.flatMap_cons, decodeBody]
    rw [List.take_left' (slot_length op), List.drop_left' (slot_length op), decode_encoded_slot, ih]
    rfl

theorem decoded_encoding (ops : List Op) (count : ops.length = 16) (checked : checkProgram ops 0 = some 1) :
    decodeWasm (encodeWasm ops) = some ops := by
  have bodyLength : (ops.flatMap encodeOp).length = 96 := by rw [body_length, count]
  have body : ((encodeWasm ops).drop 35).take 96 = ops.flatMap encodeOp := by
    rw [encodeWasm, List.append_assoc, List.drop_left' header_length, List.take_left' bodyLength]
  unfold decodeWasm
  rw [body, ← count, decode_encoded_body]
  simp [checked]

theorem encoded_execution (ops : List Op) (count : ops.length = 16) (checked : checkProgram ops 0 = some 1)
    (locals : Fin 2 → Word) : runWasm (encodeWasm ops) locals = ZkBuild.run locals ops [] := by
  rw [runWasm, decoded_encoding ops count checked]
  rfl

#print axioms decoded_encoding
#print axioms encoded_execution

end ZkBuild.WasmEncoding
