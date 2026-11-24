import BitPacking

namespace ZkBuild.RangeConstraints

open Lean.Grind R1CS BitPacking
attribute [local instance] Semiring.natCast

theorem unsigned_sound {F : Type} [Field F] (bits : List F) (width : Nat) (value : F)
    (length : bits.length = width)
    (boolean : ∀ bit ∈ bits, bit * (bit - 1) = 0)
    (binding : weightedValues (bitWeights width) bits = value) :
    ∃ n : Nat, n < 2^width ∧ value = (n : F) := by
  obtain ⟨decoded, same⟩ := constrained_bits_are_booleans bits boolean
  have len : decoded.length = width := by simpa [same] using length
  refine ⟨packBits decoded, ?_, ?_⟩
  · simpa [len] using packed_bits_bounded decoded
  · rw [← binding, same, weighted_booleans, ← len, binary_weights_encode_bits]

theorem power_below_modulus (width : Nat) (small : width ≤ 248) : 2^width < scalarModulus := by
  have bound := Nat.pow_le_pow_right (n := 2) (by decide) small
  have large : 2^248 < scalarModulus := by decide
  omega

theorem strict_order {F : Type} [CommRing F] [IsCharP F scalarModulus]
    (x y delta bound : Nat) (xb : x < bound) (yb : y < bound) (db : delta < bound)
    (small : 2*bound < scalarModulus)
    (equation : (y : F) - (x : F) - 1 = (delta : F)) : x < y := by
  have rightSmall : x+delta+1 < scalarModulus := by omega
  have leftSmall : y < scalarModulus := by omega
  have fieldEq : (y : F) = ((x+delta+1 : Nat) : F) := by
    simp only [Semiring.natCast_add, Semiring.natCast_one]
    grind
  have natural := (IsCharP.natCast_eq_iff_of_lt (α := F) scalarModulus leftSmall rightSmall).mp fieldEq
  omega

theorem zero_indicator {F : Type} [Field F] [DecidableEq F] (value indicator reciprocal : F)
    (zeroProduct : value * indicator = 0)
    (inverseProduct : value * reciprocal = 1 - indicator) :
    indicator = if value = 0 then 1 else 0 := by
  by_cases zero : value = 0
  · simp only [zero, ↓reduceIte]
    grind
  · simp only [zero, ↓reduceIte]
    rcases Field.of_mul_eq_zero zeroProduct with bad | good
    · exact False.elim (zero bad)
    · exact good

def packDigits : List (Nat × Nat) → Nat
  | [] => 0
  | (width, digit) :: rest => digit + 2^width * packDigits rest

def Width (digits : List (Nat × Nat)) : Nat := (digits.map Prod.fst).sum
def Bounded (digits : List (Nat × Nat)) : Prop := ∀ digit ∈ digits, digit.2 < 2^digit.1

theorem pack_bound (digits : List (Nat × Nat)) (bounded : Bounded digits) :
    packDigits digits < 2^(Width digits) := by
  induction digits with
  | nil => simp [packDigits, Width]
  | cons digit rest ih =>
    obtain ⟨width, value⟩ := digit
    have head : value < 2^width := bounded (width, value) (by simp)
    have tail : Bounded rest := by intro d hd; exact bounded d (by simp [hd])
    have restBound := ih tail
    simp only [packDigits, Width, List.map_cons, List.sum_cons]
    calc
      value + 2^width * packDigits rest < 2^width + 2^width * packDigits rest := Nat.add_lt_add_right head _
      _ = 2^width * (packDigits rest + 1) := by rw [Nat.mul_add, Nat.mul_one]; omega
      _ ≤ 2^width * 2^(Width rest) := Nat.mul_le_mul_left _ restBound
      _ = 2^(width + Width rest) := (Nat.pow_add ..).symm

theorem radix_injective (base a b x y : Nat) (ab : a < base) (xb : x < base)
    (same : a+base*b = x+base*y) : a = x ∧ b = y := by
  have low : a = x := by
    have equal := congrArg (fun n => n % base) same
    simpa [Nat.add_mod, Nat.mod_eq_of_lt ab, Nat.mod_eq_of_lt xb] using equal
  have high : base*b = base*y := by omega
  exact ⟨low, Nat.eq_of_mul_eq_mul_left (by omega) high⟩

theorem pack_injective (a b : List (Nat × Nat)) (aBound : Bounded a) (bBound : Bounded b)
    (widths : a.map Prod.fst = b.map Prod.fst) (same : packDigits a = packDigits b) : a = b := by
  induction a generalizing b with
  | nil => cases b <;> simp_all [packDigits]
  | cons digit rest ih =>
    cases b with
    | nil => simp at widths
    | cons other tail =>
      obtain ⟨w, d⟩ := digit
      obtain ⟨v, e⟩ := other
      have heads : w = v := by simpa using (List.cons.inj widths).1
      subst v
      have split := radix_injective (2^w) d (packDigits rest) e (packDigits tail)
        (aBound (w, d) (by simp)) (bBound (w, e) (by simp)) same
      have tails := ih tail (by intro x hx; exact aBound x (by simp [hx]))
        (by intro x hx; exact bBound x (by simp [hx])) (List.cons.inj widths).2 split.2
      simp [split.1, tails]

theorem packed_field_injective {F : Type} [CommRing F] [IsCharP F scalarModulus]
    (a b : List (Nat × Nat)) (aBound : Bounded a) (bBound : Bounded b)
    (widths : a.map Prod.fst = b.map Prod.fst) (small : Width a ≤ 248)
    (same : (packDigits a : F) = (packDigits b : F)) : a = b := by
  have widthEq : Width a = Width b := congrArg List.sum widths
  have aSmall : packDigits a < scalarModulus :=
    Nat.lt_trans (pack_bound a aBound) (power_below_modulus _ small)
  have bSmall : packDigits b < scalarModulus :=
    Nat.lt_trans (pack_bound b bBound) (power_below_modulus _ (by omega))
  exact pack_injective a b aBound bBound widths
    ((IsCharP.natCast_eq_iff_of_lt (α := F) scalarModulus aSmall bSmall).mp same)

#print axioms unsigned_sound
#print axioms strict_order
#print axioms zero_indicator
#print axioms packed_field_injective

end ZkBuild.RangeConstraints
