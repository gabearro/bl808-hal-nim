import ZkBuild

/- The inverse DIF schedule reverses the forward DIT butterfly stages. These
   lemmas cover arbitrary field values, not a finite set of honest inputs.
   Relating the index schedule to the DFT remains a separate obligation. -/
namespace ZkBuild.FftStages

open Lean.Grind

abbrev Values (I F : Type) := I → F

structure Pairing (I : Type) where
  partner : I → I
  left : I → Bool
  involutive : ∀ i, partner (partner i) = i
  opposite : ∀ i, left (partner i) = !left i

structure Stage (I F : Type) [Field F] where
  pairing : Pairing I
  weight : I → F
  sameWeight : ∀ i, weight (pairing.partner i) = weight i
  nonzero : ∀ i, weight i ≠ 0

def scale {I F : Type} [Field F] (factor : F) (a : Values I F) : Values I F :=
  fun i => factor * a i

def forward {I F : Type} [Field F] (s : Stage I F) (a : Values I F) : Values I F := fun i =>
  if s.pairing.left i then a i + s.weight i * a (s.pairing.partner i)
  else a (s.pairing.partner i) - s.weight i * a i

def backward {I F : Type} [Field F] (s : Stage I F) (a : Values I F) : Values I F := fun i =>
  if s.pairing.left i then a i + a (s.pairing.partner i)
  else (a (s.pairing.partner i) - a i) * (s.weight i)⁻¹

theorem butterfly_roundtrip {I F : Type} [Field F] (s : Stage I F) (a : Values I F) :
    backward s (forward s a) = scale 2 a := by
  funext i
  have side := s.pairing.opposite i
  have inverse := Field.mul_inv_cancel (s.nonzero i)
  cases left : s.pairing.left i <;>
    simp only [backward, forward, left, side, Bool.not_false, Bool.not_true,
      Bool.false_eq_true, ite_true, ite_false, s.pairing.involutive,
      s.sameWeight, scale] <;> grind

theorem backward_scale {I F : Type} [Field F] (s : Stage I F) (factor : F) (a : Values I F) :
    backward s (scale factor a) = scale factor (backward s a) := by
  funext i
  cases left : s.pairing.left i <;> simp only [backward, scale, left, ite_true] <;> grind

def runForward {I F : Type} [Field F] : List (Stage I F) → Values I F → Values I F
  | [], a => a
  | s :: rest, a => runForward rest (forward s a)

def runBackward {I F : Type} [Field F] : List (Stage I F) → Values I F → Values I F
  | [], a => a
  | s :: rest, a => backward s (runBackward rest a)

theorem stages_roundtrip_scaled {I F : Type} [Field F] (stages : List (Stage I F)) (a : Values I F) :
    runBackward stages (runForward stages a) = scale ((2 : F)^stages.length) a := by
  induction stages generalizing a with
  | nil => funext i; simp [runBackward, runForward, scale, Semiring.pow_zero, Semiring.one_mul]
  | cons s rest ih =>
    simp only [runBackward, runForward, ih, backward_scale, butterfly_roundtrip]
    funext i
    simp only [scale, List.length_cons, Semiring.pow_succ]
    grind

def permute {I F : Type} (permutation : I → I) (a : Values I F) : Values I F :=
  fun i => a (permutation i)

def fft {I F : Type} [Field F] (stages : List (Stage I F)) (permutation : I → I)
    (a : Values I F) : Values I F := runForward stages (permute permutation a)

def inverseFft {I F : Type} [Field F] (stages : List (Stage I F)) (permutation : I → I)
    (a : Values I F) : Values I F :=
  scale (((2 : F)^stages.length)⁻¹) (permute permutation (runBackward stages a))

theorem powers_nonzero {F : Type} [Field F] (a : F) (nonzero : a ≠ 0) : ∀ n : Nat, a^n ≠ 0 := by
  intro n
  induction n with
  | zero => simpa only [Semiring.pow_zero] using Ne.symm Field.zero_ne_one
  | succ n ih =>
    intro zero
    rw [Semiring.pow_succ] at zero
    rcases Field.of_mul_eq_zero zero with bad | bad
    · exact ih bad
    · exact nonzero bad

theorem inverse_fft_roundtrip {I F : Type} [Field F] (stages : List (Stage I F))
    (permutation : I → I) (involutive : ∀ i, permutation (permutation i) = i)
    (twoNonzero : (2 : F) ≠ 0) (a : Values I F) : inverseFft stages permutation (fft stages permutation a) = a := by
  rw [inverseFft, fft, stages_roundtrip_scaled]
  funext i
  have nonzero := powers_nonzero 2 twoNonzero stages.length
  have inverse := Field.inv_mul_cancel nonzero
  simp only [scale, permute, involutive]
  grind

-- A layout decomposes each index into a butterfly pair and one Boolean side.
-- The index generator must establish its bijection to the concrete array.
def paired {A : Type} : Pairing (A × Bool) where
  partner := fun i => (i.1, !i.2)
  left := fun i => i.2
  involutive := by intro i; simp
  opposite := by intro i; rfl

def weightedPairs {A F : Type} [Field F] (weight : A → F) (nonzero : ∀ i, weight i ≠ 0) :
    Stage (A × Bool) F where
  pairing := paired
  weight := fun i => weight i.1
  sameWeight := by intro i; rfl
  nonzero := fun i => nonzero i.1

#print axioms butterfly_roundtrip
#print axioms stages_roundtrip_scaled
#print axioms inverse_fft_roundtrip

end ZkBuild.FftStages
