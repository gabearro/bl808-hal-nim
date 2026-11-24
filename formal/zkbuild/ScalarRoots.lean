import FftForward
import Init.Data.Nat.PowMod

/- The root constants used by the Nim FFT, over any field of the BLS12-381
   scalar characteristic. Modular exponentiation certificates use kernel
   reduction; no assertion that 7 generates the full multiplicative group is
   needed for the supported radix-two domains. -/
namespace ZkBuild.ScalarRoots

open Lean.Grind FftStages FftRadix FftForward CosetQap
attribute [local instance] Semiring.natCast

theorem power_power {F : Type} [Semiring F] (a : F) (m n : Nat) :
    (a^m)^n = a^(m*n) := by
  induction n with
  | zero => simp [Semiring.pow_zero]
  | succ n ih => rw [Semiring.pow_succ, ih, Nat.mul_succ, Semiring.pow_add]

theorem pow_mod_cast {F : Type} [Semiring F] [IsCharP F scalarModulus] (base exponent : Nat) :
    ((Nat.powMod base exponent scalarModulus : Nat) : F) = (base : F)^exponent := by
  rw [Nat.powMod_def, IsCharP.natCast_emod, Semiring.natCast_pow]

set_option maxRecDepth 4096 in
theorem half_exponent_certificate :
    Nat.powMod 7 ((scalarModulus-1)/2) scalarModulus = scalarModulus-1 := by
  decide +kernel

theorem minus_one_cast {F : Type} [Field F] [IsCharP F scalarModulus] :
    ((scalarModulus-1 : Nat) : F) = -1 := by
  have characteristic : (scalarModulus : F) = 0 :=
    (IsCharP.natCast_eq_zero_iff scalarModulus scalarModulus).mpr (Nat.mod_self _)
  have modulus : scalarModulus-1+1 = scalarModulus := by decide
  have split := congrArg (fun n : Nat => (n : F)) modulus
  rw [Semiring.natCast_add, Semiring.natCast_one, characteristic] at split
  grind

theorem scalar_half_power {F : Type} [Field F] [IsCharP F scalarModulus] :
    (7 : F)^((scalarModulus-1)/2) = -1 := by
  have result := pow_mod_cast (F := F) 7 ((scalarModulus-1)/2)
  rw [half_exponent_certificate, minus_one_cast] at result
  simpa only [Semiring.natCast_eq_ofNat] using result.symm

set_option maxRecDepth 4096 in
theorem double_exponent_certificate : ∀ i : Fin 32,
    (scalarModulus-1)/2^(i.val+1) + (scalarModulus-1)/2^(i.val+1) =
      (scalarModulus-1)/2^i.val := by decide +kernel

set_option maxRecDepth 4096 in
theorem half_power_certificate : ∀ i : Fin 32,
    ((scalarModulus-1)/2^(i.val+1)) * 2^i.val = (scalarModulus-1)/2 := by decide +kernel

def root {F : Type} [Field F] (depth : Nat) : F :=
  (7 : F)^((scalarModulus-1)/2^depth)

def rootResidue (depth : Nat) : Nat :=
  Nat.powMod 7 (halve (scalarModulus-1) depth) scalarModulus

theorem root_residue_cast {F : Type} [Field F] [IsCharP F scalarModulus] (depth : Nat) :
    ((rootResidue depth : Nat) : F) = root depth := by
  rw [rootResidue, pow_mod_cast, halving_exponent, root]
  simp only [Semiring.natCast_eq_ofNat]

theorem root_nonzero {F : Type} [Field F] [IsCharP F scalarModulus] (depth : Nat) :
    root (F := F) depth ≠ 0 := by
  have seven : (7 : F) ≠ 0 := by
    simpa only [Semiring.natCast_eq_ofNat] using
      small_scalar_nonzero (F := F) 7 (by decide) (by decide)
  exact powers_nonzero 7 seven _

theorem root_square {F : Type} [Field F] (depth : Nat) (bound : depth < 32) :
    root (F := F) (depth+1) * root (depth+1) = root depth := by
  unfold root
  rw [← Semiring.pow_add, double_exponent_certificate ⟨depth, bound⟩]

theorem root_half {F : Type} [Field F] [IsCharP F scalarModulus]
    (depth : Nat) (bound : depth < 32) : root (F := F) (depth+1)^(2^depth) = -1 := by
  rw [root, power_power, half_power_certificate ⟨depth, bound⟩, scalar_half_power]

def hierarchy {F : Type} [Field F] [IsCharP F scalarModulus] (bits : Nat) (bound : bits ≤ 32) :
    RootHierarchy F bits where
  value := fun i => root i.val
  nonzero := fun i => root_nonzero i.val
  square := fun i => root_square i.val (by have := i.isLt; omega)
  half := fun i => root_half i.val (by have := i.isLt; omega)

theorem root_zero {F : Type} [Field F] [IsCharP F scalarModulus] : root (F := F) 0 = 1 := by
  have square := root_square (F := F) 0 (by decide)
  have half := root_half (F := F) 0 (by decide)
  simp only [Nat.pow_zero, Semiring.pow_one] at half
  rw [half] at square
  grind

theorem root_unity {F : Type} [Field F] [IsCharP F scalarModulus]
    (bits : Nat) (bound : bits ≤ 32) : root (F := F) bits^(2^bits) = 1 := by
  induction bits with
  | zero => simp only [Nat.pow_zero, Semiring.pow_one, root_zero]
  | succ bits ih =>
    have square : root (F := F) (bits+1)^2 = root bits := by
      simpa only [Semiring.pow_succ, Semiring.pow_zero, Semiring.one_mul]
        using root_square (F := F) bits (by omega)
    calc
      root (F := F) (bits+1)^(2^(bits+1)) = (root (F := F) (bits+1)^2)^(2^bits) := by
        rw [power_power, Nat.pow_succ, Nat.mul_comm]
      _ = 1 := by rw [square, ih (by omega)]

theorem power_commute {F : Type} [Semiring F] (a : F) (m n : Nat) :
    (a^m)^n = (a^n)^m := by rw [power_power, power_power, Nat.mul_comm]

def evaluationRoots {F : Type} [Field F] (bits : Nat) : Fin (2^bits) → F :=
  fun i => root bits^i.val

theorem evaluation_roots_unity {F : Type} [Field F] [IsCharP F scalarModulus]
    (bits : Nat) (bound : bits ≤ 32) : ∀ i, evaluationRoots (F := F) bits i^(2^bits) = 1 := by
  intro i
  rw [evaluationRoots, power_commute, root_unity bits bound, Semiring.one_pow]

set_option maxRecDepth 4096 in
theorem coset_disjoint_certificate : ∀ i : Fin 33,
    Nat.powMod 7 (2^i.val) scalarModulus ≠ 1 := by decide +kernel

theorem coset_disjoint {F : Type} [Field F] [IsCharP F scalarModulus]
    (bits : Nat) (bound : bits ≤ 32) : (7 : F)^(2^bits)-1 ≠ 0 := by
  intro zero
  have eq : (7 : F)^(2^bits) = 1 := by grind
  have castEq : ((Nat.powMod 7 (2^bits) scalarModulus : Nat) : F) = ((1 : Nat) : F) := by
    rw [pow_mod_cast]
    simpa only [Semiring.natCast_eq_ofNat, Semiring.natCast_one] using eq
  have modEq := (IsCharP.natCast_ext_iff scalarModulus).mp castEq
  rw [Nat.powMod_def, Nat.mod_mod] at modEq
  have reduced : Nat.powMod 7 (2^bits) scalarModulus = 1 := by
    rw [Nat.powMod_def]
    simpa only [show 1 % scalarModulus = 1 by decide] using modEq
  exact coset_disjoint_certificate ⟨bits, by omega⟩ reduced

theorem forward_correct {F : Type} [Field F] [IsCharP F scalarModulus]
    (bits : Nat) (bound : bits ≤ 32) (a : Fin (2^bits) → F) :
    forwardFft bits (scalarStageRoots bits) (scalar_stage_roots_nonzero bits) a =
      dft (evaluationRoots bits) a := by
  have actual := hierarchy_forward_correct bits (hierarchy (F := F) bits bound) a
  change forwardFft bits (fun i => root (i.val+1)) _ a = dft (evaluationRoots bits) a at actual
  have roots : (fun i : Fin bits => root (F := F) (i.val+1)) = scalarStageRoots bits := by
    funext i
    simp only [root, scalarStageRoots, halving_exponent]
  have replace : ∀ (rs : Fin bits → F) (nz : ∀ i, rs i ≠ 0), rs = scalarStageRoots bits →
      forwardFft bits rs nz a = forwardFft bits (scalarStageRoots bits) (scalar_stage_roots_nonzero bits) a := by
    intro rs nz eq
    subst rs
    rfl
  exact (replace _ _ roots).symm.trans actual

def transform {F : Type} [Field F] [IsCharP F scalarModulus]
    (bits : Nat) (bound : bits ≤ 32) : InverseTransform (evaluationRoots (F := F) bits) :=
  inverseTransform bits (scalarStageRoots bits) (scalar_stage_roots_nonzero bits)
    (by simpa only [Semiring.natCast_eq_ofNat] using
      small_scalar_nonzero (F := F) 2 (by decide) (by decide))
    (evaluationRoots bits) (forward_correct bits bound)

theorem inverse_correct {F : Type} [Field F] [IsCharP F scalarModulus]
    (bits : Nat) (bound : bits ≤ 32) (a : Fin (2^bits) → F) :
    backwardFft bits (scalarStageRoots bits) (scalar_stage_roots_nonzero bits)
      (dft (evaluationRoots bits) a) = a := (transform bits bound).leftInverse a

theorem quotient_correct {F : Type} [Field F] [IsCharP F scalarModulus]
    (bits : Nat) (bound : bits ≤ 32) (low high : Fin (2^bits) → F)
    (satisfied : ∀ i, splitNumerator low high (evaluationRoots bits i) = 0) :
    recoverQuotient (evaluationRoots bits) (transform bits bound) 7 low high = high := by
  apply coset_quotient_correct
    (evaluationRoots bits) (transform bits bound) (evaluation_roots_unity bits bound) 7
  · simpa only [Semiring.natCast_eq_ofNat] using
      small_scalar_nonzero (F := F) 7 (by decide) (by decide)
  · exact coset_disjoint bits bound
  · exact satisfied

#print axioms half_exponent_certificate
#print axioms scalar_half_power
#print axioms root_residue_cast
#print axioms hierarchy
#print axioms root_unity
#print axioms coset_disjoint
#print axioms forward_correct
#print axioms inverse_correct
#print axioms quotient_correct

end ZkBuild.ScalarRoots
