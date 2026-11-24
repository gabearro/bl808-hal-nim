import R1CS

namespace ZkBuild.BitPacking

open R1CS Lean.Grind
attribute [local instance] Semiring.natCast

def bitWeights : Nat → List Nat
  | 0 => []
  | n + 1 => 1 :: (bitWeights n).map (fun weight => 2 * weight)

def packBits : List Bool → Nat
  | [] => 0
  | bit :: rest => bit.toNat + 2 * packBits rest

theorem selectedCode_scaled (factor : Nat) (codes : List Nat) (bits : List Bool) :
    selectedCode (codes.map (fun weight => factor * weight)) bits =
      factor * selectedCode codes bits := by
  induction codes generalizing bits with
  | nil => simp [selectedCode]
  | cons code codes ih =>
    cases bits with
    | nil => simp [selectedCode]
    | cons bit bits =>
      cases bit <;> simp [selectedCode, ih, Nat.mul_add]

theorem binary_weights_encode_bits (bits : List Bool) :
    selectedCode (bitWeights bits.length) bits = packBits bits := by
  induction bits with
  | nil => rfl
  | cons bit bits ih =>
    cases bit <;> simp [bitWeights, selectedCode, packBits, selectedCode_scaled, ih]

theorem packed_bits_bounded (bits : List Bool) : packBits bits < 2^bits.length := by
  induction bits with
  | nil => simp [packBits]
  | cons bit bits ih =>
    have bitBound : bit.toNat ≤ 1 := by cases bit <;> decide
    simp only [packBits, List.length_cons, Nat.pow_succ]
    omega

theorem packed_bits_injective (a : List Bool) :
    ∀ b, a.length = b.length → packBits a = packBits b → a = b := by
  induction a with
  | nil => intro b len _; cases b <;> simp_all
  | cons x xs ih =>
    intro b len same
    cases b with
    | nil => simp at len
    | cons y ys =>
      have xBound : x.toNat < 2 := by cases x <;> decide
      have yBound : y.toNat < 2 := by cases y <;> decide
      have heads : x.toNat = y.toNat := by simp only [packBits] at same; omega
      have tails : packBits xs = packBits ys := by simp only [packBits] at same; omega
      have headEq : x = y := by cases x <;> cases y <;> simp_all
      have tailEq := ih ys (by simpa using len) tails
      simp [headEq, tailEq]

theorem byte_weights_exact : bitWeights 8 = [1, 2, 4, 8, 16, 32, 64, 128] := by decide

theorem byte_bits_are_a_byte {F : Type} [Field F] (values : List F)
    (length : values.length = 8)
    (bits : ∀ value ∈ values, value * (value - 1) = 0) :
    ∃ byte : Fin 256, weightedValues (bitWeights 8) values = (byte.val : F) := by
  obtain ⟨decoded, same⟩ := constrained_bits_are_booleans values bits
  have decodedLength : decoded.length = 8 := by simpa [same] using length
  have bound : packBits decoded < 256 := by simpa [decodedLength] using packed_bits_bounded decoded
  refine ⟨⟨packBits decoded, bound⟩, ?_⟩
  simp only [same, weighted_booleans]
  rw [← decodedLength, binary_weights_encode_bits]

-- Two Boolean decompositions of a public byte cannot represent different
-- continuation/sign/payload bits through cancellation in the scalar field.
theorem byte_decomposition_unique {F : Type} [Field F] [IsCharP F scalarModulus]
    (a b : List F) (aLength : a.length = 8) (bLength : b.length = 8)
    (aBits : ∀ value ∈ a, value * (value - 1) = 0)
    (bBits : ∀ value ∈ b, value * (value - 1) = 0)
    (binding : weightedValues (bitWeights 8) a = weightedValues (bitWeights 8) b) : a = b := by
  obtain ⟨aDecoded, aSame⟩ := constrained_bits_are_booleans a aBits
  obtain ⟨bDecoded, bSame⟩ := constrained_bits_are_booleans b bBits
  have aLen : aDecoded.length = 8 := by simpa [aSame] using aLength
  have bLen : bDecoded.length = 8 := by simpa [bSame] using bLength
  have aBound : packBits aDecoded < scalarModulus := by
    have bound := packed_bits_bounded aDecoded
    have large : 256 < scalarModulus := by decide
    simp only [aLen] at bound
    omega
  have bBound : packBits bDecoded < scalarModulus := by
    have bound := packed_bits_bounded bDecoded
    have large : 256 < scalarModulus := by decide
    simp only [bLen] at bound
    omega
  have sameField : (packBits aDecoded : F) = (packBits bDecoded : F) := by
    have aPacked : selectedCode (bitWeights 8) aDecoded = packBits aDecoded := by
      rw [← aLen, binary_weights_encode_bits]
    have bPacked : selectedCode (bitWeights 8) bDecoded = packBits bDecoded := by
      rw [← bLen, binary_weights_encode_bits]
    simpa [aSame, bSame, weighted_booleans, aPacked, bPacked] using binding
  have sameNat := (IsCharP.natCast_eq_iff_of_lt (α := F) scalarModulus aBound bBound).mp sameField
  have sameBits := packed_bits_injective aDecoded bDecoded (by omega) sameNat
  simp [aSame, bSame, sameBits]

#print axioms byte_bits_are_a_byte
#print axioms byte_decomposition_unique

end ZkBuild.BitPacking
