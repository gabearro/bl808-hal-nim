import PublicBinding

namespace ZkBuild.HeaderSoundness

open Lean.Grind CircuitShape FullMatrix PublicBinding
attribute [local instance] Ring.intCast Semiring.natCast

def headerPosition (i : Fin 35) : Fin 156 := ⟨i.val, by have := i.isLt; omega⟩
def prefixByte (i : Fin 35) : Nat := modulePrefix[i.val]?.getD 0

def headerGate (i : Fin 35) : Gate :=
  let target := byteLinear i.val
  if 25 ≤ i.val ∧ i.val ≤ 27 then
    ⟨sub [(8+i.val*8+7, 1)] (constant 0), constant 1, constant 0⟩
  else if i.val = 31 then
    ⟨sub target (sub [(1, 1)] (constant 32)), constant 1, constant 0⟩
  else if i.val = 33 then
    ⟨sub target (sub [(1, 1)] (constant 34)), constant 1, constant 0⟩
  else ⟨sub target (constant (Int.ofNat (prefixByte i))), constant 1, constant 0⟩

theorem header_gates_match : ∀ i : Fin 35,
    (match byteShape.gates[1254+i.val]? with
    | none => false
    | some actual => sameGate (headerGate i) actual) = true := by native_decide

theorem prefix_bytes_bounded : ∀ i : Fin 35, prefixByte i < 256 := by native_decide

theorem header_gate_holds {F : Type} [CommRing F] (ctx : Lean.RArray F) (i : Fin 35)
    (holds : Satisfied byteShape ctx.get) : R1CS.Holds ctx.get (interpretGate (headerGate i)) := by
  have equal := header_gates_match i
  cases found : byteShape.gates[1254+i.val]? with
  | none => simp [found] at equal
  | some actual =>
    apply same_gate_sound ctx _ actual (by simpa [found] using equal)
    exact holds actual (by simpa using Array.mem_of_getElem? found)

theorem equality_gate {F : Type} [CommRing F] (ctx : Lean.RArray F)
    (a b : Linear) (one : ctx.get 0 = 1)
    (holds : R1CS.Holds ctx.get (interpretGate ⟨sub a b, constant 1, constant 0⟩)) :
    evalLinear ctx.get a = evalLinear ctx.get b := by
  change evalLinear ctx.get (sub a b) * evalLinear ctx.get (constant 1) = evalLinear ctx.get (constant 0) at holds
  rw [BodySoundness.eval_sub, BodySoundness.eval_constant ctx.get one 1,
    BodySoundness.eval_constant ctx.get one 0] at holds
  grind

theorem wire_value {F : Type} [CommRing F] (ctx : Lean.RArray F) (i : Nat) :
    evalLinear ctx.get [(i, 1)] = ctx.get i := by
  simp [evalLinear, interpretLinear, R1CS.eval, Ring.intCast_one, Semiring.one_mul, Semiring.add_zero]

theorem bounded_nat_equal {F : Type} [CommRing F] [IsCharP F scalarModulus]
    (a b : Nat) (aBound : a < 256) (bBound : b < 256) (same : (a : F) = (b : F)) : a = b := by
  have modulus : 256 < scalarModulus := by decide
  exact (IsCharP.natCast_eq_iff_of_lt (α := F) scalarModulus (by omega) (by omega)).mp same

theorem high_bit_zero_ascii {F : Type} [Field F] [IsCharP F scalarModulus]
    (ctx : Lean.RArray F) (position : Fin 156) (byte : Fin 256)
    (one : ctx.get 0 = 1) (holds : Satisfied byteShape ctx.get)
    (binding : R1CS.weightedValues (BitPacking.bitWeights 8) (globalBits ctx.get position) = byte.val)
    (highZero : ctx.get (8+position.val*8+7) = 0) : byte.val < 128 := by
  have bits := BitPacking.byte_decomposition_unique (globalBits ctx.get position)
    ((InputNormalization.byteBits byte).map R1CS.boolValue)
    (by simp [globalBits]) (by simp [InputNormalization.byteBits])
    (global_bits_boolean ctx position one holds) (InputNormalization.canonical_byte_boolean byte)
    (by rw [InputNormalization.canonical_byte_field_value, binding])
  have high := congrArg (fun xs : List F => (xs[7]?).getD 0) bits
  by_cases ascii : byte.val < 128
  · exact ascii
  · have byteBound := byte.isLt
    have bitSet : byte.val / 128 % 2 = 1 := by omega
    have contradiction : (0 : F) = 1 := by
      simpa [globalBits, InputNormalization.byteBits, R1CS.boolValue, bitSet, highZero] using high
    exact False.elim (Field.zero_ne_one contradiction)

def HeaderValid (bytes : Fin 156 → Fin 256) (length : Nat) : Prop :=
  ∀ i : Fin 35,
    if 25 ≤ i.val ∧ i.val ≤ 27 then (bytes (headerPosition i)).val < 128
    else if i.val = 31 then (bytes (headerPosition i)).val = length - 32
    else if i.val = 33 then (bytes (headerPosition i)).val = length - 34
    else (bytes (headerPosition i)).val = prefixByte i

theorem header_valid {F : Type} [Field F] [IsCharP F scalarModulus]
    (ctx : Lean.RArray F) (bytes : Fin 156 → Fin 256) (length : Nat)
    (lengthBound : 36 ≤ length ∧ length ≤ 156)
    (one : ctx.get 0 = 1) (publicInputs : PublicBytesMatch ctx bytes)
    (publicLength : ctx.get 1 = (length : F)) (holds : Satisfied byteShape ctx.get) : HeaderValid bytes length := by
  have bindings := public_bytes_bind_all_bits ctx bytes one publicInputs holds
  intro i
  have gate := header_gate_holds ctx i holds
  have byteEq : evalLinear ctx.get (byteLinear i.val) = ((bytes (headerPosition i)).val : F) := by
    exact (byte_linear_value ctx (headerPosition i)).trans (bindings (headerPosition i))
  by_cases ascii : 25 ≤ i.val ∧ i.val ≤ 27
  · simp only [ascii]
    have high : ctx.get (8+i.val*8+7) = 0 := by
      have eq := equality_gate ctx [(8+i.val*8+7, 1)] (constant 0) one (by simpa [headerGate, ascii] using gate)
      simpa [wire_value, BodySoundness.eval_constant ctx.get one 0, Ring.intCast_zero] using eq
    exact high_bit_zero_ascii ctx (headerPosition i) (bytes (headerPosition i)) one holds (bindings _) high
  · by_cases codeLength : i.val = 31
    · have eq := equality_gate ctx (byteLinear i.val) (sub [(1, 1)] (constant 32)) one
        (by simpa [headerGate, ascii, codeLength] using gate)
      rw [byteEq, BodySoundness.eval_sub, wire_value, publicLength, BodySoundness.eval_constant ctx.get one 32] at eq
      have lenEq : length = length - 32 + 32 := by omega
      have packed : ((bytes (headerPosition i)).val : F) = ((length-32 : Nat) : F) := by
        rw [lenEq, Semiring.natCast_add] at eq
        grind
      have natural := bounded_nat_equal (F := F) (bytes (headerPosition i)).val (length-32)
        (bytes _).isLt (by omega) packed
      simpa [HeaderValid, ascii, codeLength] using natural
    · by_cases bodyLength : i.val = 33
      · have eq := equality_gate ctx (byteLinear i.val) (sub [(1, 1)] (constant 34)) one
          (by simpa [headerGate, ascii, codeLength, bodyLength] using gate)
        rw [byteEq, BodySoundness.eval_sub, wire_value, publicLength, BodySoundness.eval_constant ctx.get one 34] at eq
        have lenEq : length = length - 34 + 34 := by omega
        have packed : ((bytes (headerPosition i)).val : F) = ((length-34 : Nat) : F) := by
          rw [lenEq, Semiring.natCast_add] at eq
          grind
        have natural := bounded_nat_equal (F := F) (bytes (headerPosition i)).val (length-34)
          (bytes _).isLt (by omega) packed
        simpa [HeaderValid, ascii, codeLength, bodyLength] using natural
      · have eq := equality_gate ctx (byteLinear i.val) (constant (Int.ofNat (prefixByte i))) one
          (by simpa [headerGate, ascii, codeLength, bodyLength] using gate)
        rw [byteEq, BodySoundness.eval_constant ctx.get one] at eq
        have packed : ((bytes (headerPosition i)).val : F) = (prefixByte i : F) := by
          simpa [Ring.intCast_natCast] using eq
        have natural := bounded_nat_equal (F := F) (bytes (headerPosition i)).val (prefixByte i)
          (bytes _).isLt (prefix_bytes_bounded i) packed
        simpa [HeaderValid, ascii, codeLength, bodyLength] using natural

#print axioms header_valid

end ZkBuild.HeaderSoundness
