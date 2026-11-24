import FftSplit

namespace ZkBuild.FftPolynomial

open Lean.Grind FftSplit CosetQap

def evalPrefix {F : Type} [CommRing F] (a : Nat → F) (x : F) : Nat → F
  | 0 => 0
  | count+1 => evalPrefix a x count + a count * x^count

theorem eval_append {F : Type} [CommRing F] {n : Nat} (a : Fin n → F) (x : F)
    (first second : List (Fin n)) :
    evaluateOn a x (first ++ second) = evaluateOn a x first + evaluateOn a x second := by
  induction first with
  | nil => simp only [List.nil_append, evaluateOn]; grind
  | cons i rest ih => simp only [List.cons_append, evaluateOn, ih]; grind

theorem eval_cast_succ {F : Type} [CommRing F] {n : Nat} (a : Fin (n+1) → F) (x : F)
    (indices : List (Fin n)) : evaluateOn a x (indices.map Fin.castSucc) =
      evaluateOn (fun i => a i.castSucc) x indices := by
  induction indices <;> simp_all [evaluateOn]

theorem evaluation_prefix {F : Type} [CommRing F] (n : Nat) (a : Fin n → F) (f : Nat → F) (x : F)
    (agree : ∀ i : Fin n, f i.val = a i) : evaluate a x = evalPrefix f x n := by
  induction n with
  | zero => simp [evaluate, evaluateOn, evalPrefix]
  | succ n ih =>
    have earlier := ih (fun i => a i.castSucc) (fun i => agree i.castSucc)
    unfold evaluate at earlier ⊢
    rw [List.finRange_succ_last, eval_append, eval_cast_succ, earlier]
    simp only [evaluateOn, Semiring.add_zero, Fin.val_last, evalPrefix]
    have last : f n = a (Fin.last n) := agree (Fin.last n)
    rw [last]

theorem power_double {F : Type} [CommRing F] (x : F) (n : Nat) : x^(2*n) = (x*x)^n := by
  rw [show 2*n = n+n by omega, Semiring.pow_add, CommSemiring.mul_pow]

theorem prefix_even_odd {F : Type} [CommRing F] (f : Nat → F) (x : F) (n : Nat) :
    evalPrefix f x (2*n) =
      evalPrefix (fun i => f (2*i)) (x*x) n + x * evalPrefix (fun i => f (2*i+1)) (x*x) n := by
  induction n with
  | zero => simp [evalPrefix, Semiring.mul_zero, Semiring.add_zero]
  | succ n ih =>
    rw [show 2*(n+1) = (2*n+1)+1 by omega]
    simp only [evalPrefix]
    rw [ih, power_double, Semiring.pow_succ, power_double]
    grind

def valueAt {F : Type} [CommRing F] {n : Nat} (a : Fin n → F) (i : Nat) : F :=
  if bound : i < n then a ⟨i, bound⟩ else 0

theorem value_at_index {F : Type} [CommRing F] {n : Nat} (a : Fin n → F) (i : Fin n) :
    valueAt a i.val = a i := by simp [valueAt, i.isLt]

theorem polynomial_even_odd {F : Type} [CommRing F] (bits : Nat)
    (a : Fin (2^(bits+1)) → F) (x : F) :
    evaluate a x = evaluate (fun i => a (evenOddIndex bits false i)) (x*x) +
      x * evaluate (fun i => a (evenOddIndex bits true i)) (x*x) := by
  let f := valueAt a
  have full := evaluation_prefix (2^(bits+1)) a f x (value_at_index a)
  have evenAgree (i : Fin (2^bits)) : f (2*i.val) = a (evenOddIndex bits false i) := by
    have bound : 2*i.val < 2^(bits+1) := by have := i.isLt; rw [Nat.pow_succ]; omega
    simp [f, valueAt, bound, evenOddIndex]
  have oddAgree (i : Fin (2^bits)) : f (2*i.val+1) = a (evenOddIndex bits true i) := by
    have bound : 2*i.val+1 < 2^(bits+1) := by have := i.isLt; rw [Nat.pow_succ]; omega
    simp [f, valueAt, bound, evenOddIndex]
  have even := evaluation_prefix (2^bits) (fun i => a (evenOddIndex bits false i))
    (fun i => f (2*i)) (x*x) evenAgree
  have odd := evaluation_prefix (2^bits) (fun i => a (evenOddIndex bits true i))
    (fun i => f (2*i+1)) (x*x) oddAgree
  rw [full, show 2^(bits+1) = 2*(2^bits) by rw [Nat.pow_succ]; omega,
    prefix_even_odd, ← even, ← odd]

theorem square_power {F : Type} [CommRing F] (x : F) (n : Nat) : (x*x)^n = x^n*x^n :=
  CommSemiring.mul_pow x x n

#print axioms polynomial_even_odd

end ZkBuild.FftPolynomial
