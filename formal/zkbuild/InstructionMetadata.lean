import RangeConstraints
import LookupFlow

namespace ZkBuild.InstructionMetadata

open Lean.Grind BitPacking RangeConstraints
attribute [local instance] Semiring.natCast

-- Independent access widths from the scalar/SIMD instruction names. Scalar
-- IR puts alignment in imm2; the SIMD load/store IR puts it in imm1.
def accessBits : Nat → Nat
  | 40 | 42 | 52 | 53 | 54 | 56 | 62 => 32
  | 41 | 43 | 55 | 57 => 64
  | 44 | 45 | 48 | 49 | 58 | 60 => 8
  | 46 | 47 | 50 | 51 | 59 | 61 => 16
  | 768 | 769 => 128
  | _ => 0

def maximumAlignment : Nat → Nat
  | 8 => 0 | 16 => 1 | 32 => 2 | 64 => 3 | 128 => 4 | _ => 0

def laneBits : Nat → Nat
  | 777 | 778 | 779 | 780 => 2
  | 792 | 793 | 794 => 4
  | 795 | 796 | 797 => 3
  | 798 | 799 | 800 | 801 => 1
  | _ => 0

def payload (code : Nat) : List Nat :=
  let width := accessBits code
  let argument := width != 0
  [ (argument || decide (code = 63 ∨ code = 64 ∨ code = 264 ∨ code = 266 ∨ code = 267)).toNat,
    argument.toNat, (decide (code = 768 ∨ code = 769)).toNat, maximumAlignment width,
    (decide (code = 63 ∨ code = 64)).toNat, (decide (code = 770)).toNat, laneBits code ]

theorem access_cases (code : Nat) :
    accessBits code = 0 ∨ accessBits code = 8 ∨ accessBits code = 16 ∨
      accessBits code = 32 ∨ accessBits code = 64 ∨ accessBits code = 128 := by
  unfold accessBits
  split <;> simp

theorem maximum_bounded (width : Nat) : maximumAlignment width ≤ 4 := by
  unfold maximumAlignment
  split <;> decide

theorem lanes_bounded (code : Nat) : laneBits code ≤ 4 := by
  unfold laneBits
  split <;> decide

theorem natural_alignment (code : Nat) (argument : accessBits code ≠ 0) :
    2^(maximumAlignment (accessBits code)) = accessBits code / 8 := by
  rcases access_cases code with h | h | h | h | h | h <;> simp_all [maximumAlignment]

theorem alignment_sound {F : Type} [Field F] [IsCharP F scalarModulus]
    (alignment maximum gap : Nat) (ab : alignment < 2^32) (mb : maximum ≤ 4) (gb : gap < 8)
    (gate : (maximum : F)-(alignment : F) = (gap : F)) : alignment ≤ maximum := by
  have sumSmall : alignment+gap < scalarModulus := by
    have large : 2^64 < scalarModulus := by decide
    omega
  have maximumSmall : maximum < scalarModulus := by
    have large : 2^64 < scalarModulus := by decide
    omega
  have fieldEq : (maximum : F) = ((alignment+gap : Nat) : F) := by
    simp only [Semiring.natCast_add]
    grind
  have natural := (IsCharP.natCast_eq_iff_of_lt (α := F) scalarModulus maximumSmall sumSmall).mp fieldEq
  omega

theorem alignment_bytes (code alignment : Nat) (argument : accessBits code ≠ 0)
    (bounded : alignment ≤ maximumAlignment (accessBits code)) : 2^alignment ≤ accessBits code/8 := by
  rw [← natural_alignment code argument]
  exact Nat.pow_le_pow_right (by decide) bounded

theorem i32_fusion_alignment (alignment : Nat) (guard : alignment ≤ 2) : 2^alignment ≤ 4 :=
  alignment_bytes 40 alignment (by decide) (by simpa [accessBits, maximumAlignment] using guard)

theorem lane_mask_sound {F : Type} [CommRing F] [IsCharP F scalarModulus]
    (bits : List Bool) (width : Nat) (length : bits.length = 32) (wb : width ≤ 4)
    (gate : (packBits bits : F) = (packBits (bits.take width) : F)) : packBits bits < 2^width := by
  have len : (bits.take width).length = width := by simp [List.length_take, length]; omega
  have fullBound : packBits bits < 2^32 := by simpa [length] using packed_bits_bounded bits
  have shortBound : packBits (bits.take width) < 2^width := by
    simpa [len] using packed_bits_bounded (bits.take width)
  have fullSmall : packBits bits < scalarModulus := Nat.lt_trans fullBound (power_below_modulus 32 (by decide))
  have shortSmall : packBits (bits.take width) < scalarModulus :=
    Nat.lt_trans shortBound (power_below_modulus width (by omega))
  have same := (IsCharP.natCast_eq_iff_of_lt (α := F) scalarModulus fullSmall shortSmall).mp gate
  omega

theorem constant_index_sound {F : Type} [CommRing F] [IsCharP F scalarModulus]
    (index count gap : Nat) (ib : index < 2^32) (cb : count < 2^32) (gb : gap < 2^32)
    (gate : (count : F)-(index : F)-1 = (gap : F)) : index < count :=
  strict_order index count gap (2^32) ib cb gb (by decide) gate

theorem memory_present {F : Type} [Field F] (count : F) (gate : 1-count = 0) : count = 1 := by grind

#print axioms natural_alignment
#print axioms alignment_sound
#print axioms alignment_bytes
#print axioms i32_fusion_alignment
#print axioms lane_mask_sound
#print axioms constant_index_sound
#print axioms memory_present

end ZkBuild.InstructionMetadata
