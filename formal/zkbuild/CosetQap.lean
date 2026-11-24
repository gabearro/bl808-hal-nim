import ZkBuild

/- Polynomial part of the coset quotient algorithm. Transform correctness is
   an explicit interface obligation: this does not assume that compiled Nim
   FFT code has already been formally refined to the mathematical DFT. -/
namespace ZkBuild.CosetQap

open Lean.Grind
attribute [local instance] Ring.intCast Semiring.natCast

abbrev Coefficients (F : Type) (n : Nat) := Fin n → F

def evaluateOn {F : Type} [CommRing F] {n : Nat} (a : Coefficients F n) (x : F) : List (Fin n) → F
  | [] => 0
  | i :: rest => a i * x^i.val + evaluateOn a x rest

def evaluate {F : Type} [CommRing F] {n : Nat} (a : Coefficients F n) (x : F) : F :=
  evaluateOn a x (List.finRange n)

def add {F : Type} [CommRing F] {n : Nat} (a b : Coefficients F n) : Coefficients F n := fun i => a i + b i
def zero {F : Type} [CommRing F] {n : Nat} : Coefficients F n := fun _ => 0
def twist {F : Type} [CommRing F] {n : Nat} (shift : F) (a : Coefficients F n) : Coefficients F n :=
  fun i => a i * shift^i.val

theorem evaluate_on_add {F : Type} [CommRing F] {n : Nat}
    (a b : Coefficients F n) (x : F) (indices : List (Fin n)) :
    evaluateOn (add a b) x indices = evaluateOn a x indices + evaluateOn b x indices := by
  induction indices with
  | nil => simp [evaluateOn, Semiring.add_zero]
  | cons i rest ih => simp only [evaluateOn, add, ih]; grind

theorem evaluate_add {F : Type} [CommRing F] {n : Nat}
    (a b : Coefficients F n) (x : F) : evaluate (add a b) x = evaluate a x + evaluate b x :=
  evaluate_on_add a b x _

theorem evaluate_on_zero {F : Type} [CommRing F] {n : Nat} (x : F) (indices : List (Fin n)) :
    evaluateOn zero x indices = 0 := by
  induction indices <;> simp_all [evaluateOn, zero, Semiring.zero_mul, Semiring.add_zero]

theorem evaluate_zero {F : Type} [CommRing F] {n : Nat} (x : F) :
    evaluate (zero (n := n)) x = 0 := evaluate_on_zero x _

theorem evaluate_on_twist {F : Type} [CommRing F] {n : Nat}
    (shift : F) (a : Coefficients F n) (x : F) (indices : List (Fin n)) :
    evaluateOn (twist shift a) x indices = evaluateOn a (shift*x) indices := by
  induction indices with
  | nil => rfl
  | cons i rest ih =>
    simp only [evaluateOn, twist, ih, CommSemiring.mul_pow]
    grind

theorem evaluate_twist {F : Type} [CommRing F] {n : Nat}
    (shift : F) (a : Coefficients F n) (x : F) :
    evaluate (twist shift a) x = evaluate a (shift*x) := evaluate_on_twist shift a x _

def dft {F : Type} [CommRing F] {n : Nat} (roots : Fin n → F) (a : Coefficients F n) : Fin n → F :=
  fun i => evaluate a (roots i)

structure InverseTransform {F : Type} [CommRing F] {n : Nat} (roots : Fin n → F) where
  inverse : (Fin n → F) → Coefficients F n
  leftInverse : ∀ a, inverse (dft roots a) = a

theorem dft_injective {F : Type} [CommRing F] {n : Nat} (roots : Fin n → F)
    (transform : InverseTransform roots) (a b : Coefficients F n) (same : dft roots a = dft roots b) : a = b := by
  have applied := congrArg transform.inverse same
  simpa only [transform.leftInverse] using applied

def splitNumerator {F : Type} [CommRing F] {n : Nat}
    (low high : Coefficients F n) (x : F) : F := evaluate low x + x^n * evaluate high x

theorem root_constraints_determine_low {F : Type} [CommRing F] {n : Nat}
    (roots : Fin n → F) (transform : InverseTransform roots)
    (unity : ∀ i, roots i ^ n = 1) (low high : Coefficients F n)
    (satisfied : ∀ i, splitNumerator low high (roots i) = 0) : ∀ i, low i = -(high i) := by
  have same : dft roots (add low high) = dft roots zero := by
    funext i
    have row := satisfied i
    simp only [splitNumerator, unity, Semiring.one_mul] at row
    simp only [dft, evaluate_add, evaluate_zero, row]
  have coefficients := dft_injective roots transform (add low high) zero same
  intro i
  have coefficient := congrArg (fun a => a i) coefficients
  change low i + high i = 0 at coefficient
  grind

theorem split_numerator_divisible {F : Type} [CommRing F] {n : Nat}
    (low high : Coefficients F n) (cancellation : ∀ i, low i = -(high i)) (x : F) :
    splitNumerator low high x = (x^n-1) * evaluate high x := by
  have sums : add low high = zero := by
    funext i
    simp only [add, zero, cancellation]
    grind
  have sumEval : evaluate low x + evaluate high x = 0 := by
    rw [← evaluate_add, sums, evaluate_zero]
  unfold splitNumerator
  grind

theorem vanishing_constant_on_coset {F : Type} [CommRing F] {n : Nat}
    (roots : Fin n → F) (unity : ∀ i, roots i ^ n = 1) (shift : F) (i : Fin n) :
    (shift * roots i)^n-1 = shift^n-1 := by
  rw [CommSemiring.mul_pow, unity, Semiring.mul_one]

theorem untwist {F : Type} [Field F] {n : Nat} (shift : F) (nonzero : shift ≠ 0)
    (a : Coefficients F n) : twist shift⁻¹ (twist shift a) = a := by
  funext i
  have inverse := Field.mul_inv_cancel nonzero
  have powers : shift^i.val * shift⁻¹^i.val = 1 := by
    rw [← CommSemiring.mul_pow, inverse, Semiring.one_pow]
  simp only [twist]
  grind

theorem coset_roundtrip {F : Type} [Field F] {n : Nat}
    (roots : Fin n → F) (transform : InverseTransform roots)
    (shift : F) (nonzero : shift ≠ 0) (a : Coefficients F n) :
    twist shift⁻¹ (transform.inverse (dft roots (twist shift a))) = a := by
  rw [transform.leftInverse]
  exact untwist shift nonzero a

def quotientValues {F : Type} [Field F] {n : Nat}
    (roots : Fin n → F) (shift : F) (low high : Coefficients F n) : Fin n → F :=
  fun i => splitNumerator low high (shift * roots i) / (shift^n-1)

def recoverQuotient {F : Type} [Field F] {n : Nat}
    (roots : Fin n → F) (transform : InverseTransform roots) (shift : F)
    (low high : Coefficients F n) : Coefficients F n :=
  twist shift⁻¹ (transform.inverse (quotientValues roots shift low high))

theorem coset_quotient_correct {F : Type} [Field F] {n : Nat}
    (roots : Fin n → F) (transform : InverseTransform roots)
    (unity : ∀ i, roots i ^ n = 1) (shift : F) (nonzero : shift ≠ 0)
    (disjoint : shift^n-1 ≠ 0) (low high : Coefficients F n)
    (satisfied : ∀ i, splitNumerator low high (roots i) = 0) :
    recoverQuotient roots transform shift low high = high := by
  have cancellation := root_constraints_determine_low roots transform unity low high satisfied
  have quotient : quotientValues roots shift low high = dft roots (twist shift high) := by
    funext i
    simp only [quotientValues, dft, evaluate_twist]
    rw [split_numerator_divisible low high cancellation,
      vanishing_constant_on_coset roots unity shift i, Field.div_eq_mul_inv]
    have inverse := Field.mul_inv_cancel disjoint
    grind
  rw [recoverQuotient, quotient, transform.leftInverse]
  exact untwist shift nonzero high

#print axioms root_constraints_determine_low
#print axioms split_numerator_divisible
#print axioms coset_roundtrip
#print axioms coset_quotient_correct

end ZkBuild.CosetQap
