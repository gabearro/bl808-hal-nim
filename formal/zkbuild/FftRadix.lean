import FftLayout
import CosetQap

namespace ZkBuild.FftRadix

open Lean.Grind FftStages FftLayout
attribute [local instance] Semiring.natCast

theorem stage_size (bits index : Nat) (bound : index < bits) :
    2^(bits-index-1) * (2 * 2^index) = 2^bits := by
  rw [Nat.mul_comm 2 (2^index), ← Nat.pow_succ, ← Nat.pow_add]
  congr 1
  omega

def radixStage {F : Type} [Field F] (bits : Nat) (index : Fin bits)
    (root : F) (nonzero : root ≠ 0) : Stage (Fin (2^bits)) F :=
  (stage_size bits index.val index.isLt) ▸
    arrayStage (2^(bits-index.val-1)) (2^index.val) (Nat.two_pow_pos _) root nonzero

def radixStages {F : Type} [Field F] (bits : Nat) (roots : Fin bits → F)
    (nonzero : ∀ i, roots i ≠ 0) : List (Stage (Fin (2^bits)) F) :=
  (List.finRange bits).map fun i => radixStage bits i (roots i) (nonzero i)

theorem stage_count {F : Type} [Field F] (bits : Nat) (roots : Fin bits → F)
    (nonzero : ∀ i, roots i ≠ 0) : (radixStages bits roots nonzero).length = bits := by
  simp [radixStages]

theorem inverse_power {F : Type} [Field F] (a : F) (n : Nat) : (a^n)⁻¹ = a⁻¹^n := by
  induction n with
  | zero => simp [Semiring.pow_zero, Field.inv_one]
  | succ n ih => rw [Semiring.pow_succ, Field.inv_mul, ih, Semiring.pow_succ]

theorem right_inverse_twiddle {F : Type} [Field F] {blocks half : Nat} (positive : 0 < half)
    (root : F) (nonzero : root ≠ 0) (block : Fin blocks) (offset : Fin half)
    (a : Fin (blocks*(2*half)) → F) :
    backward (arrayStage blocks half positive root nonzero) a (pack ((block, offset), false)) =
      (a (pack ((block, offset), true)) - a (pack ((block, offset), false))) * root⁻¹^offset.val := by
  rw [right_backward, inverse_power]

def forwardFft {F : Type} [Field F] (bits : Nat) (roots : Fin bits → F)
    (nonzero : ∀ i, roots i ≠ 0) (a : Fin (2^bits) → F) : Fin (2^bits) → F :=
  fft (radixStages bits roots nonzero) (reverseIndex bits) a

def backwardFft {F : Type} [Field F] (bits : Nat) (roots : Fin bits → F)
    (nonzero : ∀ i, roots i ≠ 0) (a : Fin (2^bits) → F) : Fin (2^bits) → F :=
  scale (((2^bits : Nat) : F)⁻¹)
    (permute (reverseIndex bits) (runBackward (radixStages bits roots nonzero) a))

theorem normalization_matches_size {F : Type} [Field F] (bits : Nat) :
    ((2^bits : Nat) : F) = (2 : F)^bits := by
  rw [Semiring.natCast_pow]
  simp only [Semiring.natCast_eq_ofNat (α := F)]

theorem radix_inverse_roundtrip {F : Type} [Field F] (bits : Nat) (roots : Fin bits → F)
    (nonzero : ∀ i, roots i ≠ 0) (twoNonzero : (2 : F) ≠ 0) (a : Fin (2^bits) → F) :
    backwardFft bits roots nonzero (forwardFft bits roots nonzero a) = a := by
  unfold backwardFft
  rw [normalization_matches_size]
  have result := inverse_fft_roundtrip (radixStages bits roots nonzero) (reverseIndex bits)
    (reverse_index_involutive bits) twoNonzero a
  simpa only [inverseFft, stage_count, forwardFft] using result

def halve (value : Nat) : Nat → Nat
  | 0 => value
  | count+1 => halve (value/2) count

theorem halving_exponent (value count : Nat) : halve value count = value/(2^count) := by
  induction count generalizing value with
  | zero => simp [halve]
  | succ count ih =>
    rw [halve, ih, Nat.div_div_eq_div_mul]
    congr 1
    simp [Nat.pow_succ, Nat.mul_comm]

def scalarStageRoots {F : Type} [Field F] (bits : Nat) (i : Fin bits) : F :=
  (7 : F)^halve (scalarModulus-1) (i.val+1)

theorem small_scalar_nonzero {F : Type} [Field F] [IsCharP F scalarModulus]
    (value : Nat) (positive : 0 < value) (bound : value < scalarModulus) : (value : F) ≠ 0 := by
  intro zero
  have eq : value = 0 := (IsCharP.natCast_eq_iff_of_lt (α := F) scalarModulus bound
    (by decide : 0 < scalarModulus)).mp (by simpa only [Semiring.natCast_zero] using zero)
  omega

theorem scalar_stage_roots_nonzero {F : Type} [Field F] [IsCharP F scalarModulus]
    (bits : Nat) : ∀ i : Fin bits, scalarStageRoots (F := F) bits i ≠ 0 := by
  intro i
  have seven : (7 : F) ≠ 0 := by
    simpa only [Semiring.natCast_eq_ofNat] using small_scalar_nonzero (F := F) 7 (by decide) (by decide)
  exact powers_nonzero 7 seven _

theorem scalar_radix_inverse_roundtrip {F : Type} [Field F] [IsCharP F scalarModulus]
    (bits : Nat) (a : Fin (2^bits) → F) :
    backwardFft bits (scalarStageRoots bits) (scalar_stage_roots_nonzero bits)
      (forwardFft bits (scalarStageRoots bits) (scalar_stage_roots_nonzero bits) a) = a := by
  have two : (2 : F) ≠ 0 := by
    simpa only [Semiring.natCast_eq_ofNat] using small_scalar_nonzero (F := F) 2 (by decide) (by decide)
  exact radix_inverse_roundtrip bits (scalarStageRoots bits) (scalar_stage_roots_nonzero bits) two a

-- The inverse interface required by the quotient proof follows from a forward
-- DFT proof. ScalarRoots supplies that proof for the concrete Nim root rule.
def inverseTransform {F : Type} [Field F] (bits : Nat) (stageRoots : Fin bits → F)
    (nonzero : ∀ i, stageRoots i ≠ 0) (twoNonzero : (2 : F) ≠ 0)
    (evaluationRoots : Fin (2^bits) → F)
    (forwardCorrect : ∀ a, forwardFft bits stageRoots nonzero a = CosetQap.dft evaluationRoots a) :
    CosetQap.InverseTransform evaluationRoots where
  inverse := backwardFft bits stageRoots nonzero
  leftInverse := by
    intro a
    rw [← forwardCorrect]
    exact radix_inverse_roundtrip bits stageRoots nonzero twoNonzero a

#print axioms stage_size
#print axioms radix_inverse_roundtrip
#print axioms halving_exponent
#print axioms scalar_radix_inverse_roundtrip

end ZkBuild.FftRadix
