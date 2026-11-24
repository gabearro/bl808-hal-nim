import FftPolynomial

namespace ZkBuild.FftForward

open Lean.Grind FftStages FftLayout FftRadix FftSplit FftPolynomial CosetQap

def successorIndex {bits : Nat} (i : Fin bits) : Fin (bits+1) :=
  ⟨i.val+1, by have := i.isLt; omega⟩

structure RootHierarchy (F : Type) [Field F] (bits : Nat) where
  value : Fin (bits+1) → F
  nonzero : ∀ i, value i ≠ 0
  square : ∀ i : Fin bits, value (successorIndex i) * value (successorIndex i) = value i.castSucc
  half : ∀ i : Fin bits, value (successorIndex i)^(2^i.val) = -1

def truncate {F : Type} [Field F] {bits : Nat} (h : RootHierarchy F (bits+1)) : RootHierarchy F bits where
  value := fun i => h.value i.castSucc
  nonzero := fun i => h.nonzero i.castSucc
  square := fun i => h.square i.castSucc
  half := fun i => h.half i.castSucc

def stageRoots {F : Type} [Field F] {bits : Nat} (h : RootHierarchy F bits) : Fin bits → F :=
  fun i => h.value (successorIndex i)

def hierarchyForward {F : Type} [Field F] {bits : Nat} (h : RootHierarchy F bits)
    (a : Fin (2^bits) → F) : Fin (2^bits) → F :=
  forwardFft bits (stageRoots h) (fun i => h.nonzero (successorIndex i)) a

def hierarchyDft {F : Type} [Field F] {bits : Nat} (h : RootHierarchy F bits)
    (a : Fin (2^bits) → F) : Fin (2^bits) → F :=
  dft (fun i => h.value (Fin.last bits)^i.val) a

theorem half_index_covers (bits : Nat) (j : Fin (2^(bits+1))) :
    ∃ (upper : Bool) (i : Fin (2^bits)), j = halfIndex bits upper i := by
  by_cases lower : j.val < 2^bits
  · refine ⟨false, ⟨j.val, lower⟩, ?_⟩
    apply Fin.ext
    simp [halfIndex]
  · have fullBound : j.val < 2^bits*2 := by simpa only [Nat.pow_succ] using j.isLt
    have bound : j.val-2^bits < 2^bits := by omega
    refine ⟨true, ⟨j.val-2^bits, bound⟩, ?_⟩
    apply Fin.ext
    simp only [halfIndex, ite_true]
    omega

theorem evaluate_half_index {F : Type} [CommRing F] (bits : Nat)
    (a : Fin (2^(bits+1)) → F) (omega : F) (halfRoot : omega^(2^bits) = -1)
    (upper : Bool) (i : Fin (2^bits)) :
    evaluate a (omega^(halfIndex bits upper i).val) =
      let even := evaluate (fun j => a (evenOddIndex bits false j)) ((omega*omega)^i.val)
      let odd := evaluate (fun j => a (evenOddIndex bits true j)) ((omega*omega)^i.val)
      if upper then even - omega^i.val * odd else even + omega^i.val * odd := by
  cases upper with
  | false =>
    change evaluate a (omega^i.val) =
      evaluate (fun j => a (evenOddIndex bits false j)) ((omega*omega)^i.val) +
      omega^i.val * evaluate (fun j => a (evenOddIndex bits true j)) ((omega*omega)^i.val)
    rw [polynomial_even_odd]
    simp only [CommSemiring.mul_pow]
  | true =>
    change evaluate a (omega^(i.val+2^bits)) =
      evaluate (fun j => a (evenOddIndex bits false j)) ((omega*omega)^i.val) -
      omega^i.val * evaluate (fun j => a (evenOddIndex bits true j)) ((omega*omega)^i.val)
    have shifted : omega^(i.val+2^bits) = -(omega^i.val) := by
      rw [Semiring.pow_add, halfRoot]
      grind
    rw [shifted, polynomial_even_odd]
    have square : -(omega^i.val) * -(omega^i.val) = omega^i.val * omega^i.val := by grind
    rw [square, CommSemiring.mul_pow]
    grind

theorem hierarchy_recurrence {F : Type} [Field F] {bits : Nat} (h : RootHierarchy F (bits+1))
    (a : Fin (2^(bits+1)) → F) (upper : Bool) (i : Fin (2^bits)) :
    hierarchyForward h a (halfIndex bits upper i) =
      let even := hierarchyForward (truncate h) (fun j => a (evenOddIndex bits false j)) i
      let odd := hierarchyForward (truncate h) (fun j => a (evenOddIndex bits true j)) i
      if upper then even - h.value (Fin.last (bits+1))^i.val * odd
      else even + h.value (Fin.last (bits+1))^i.val * odd :=
  forward_fft_recurrence bits (stageRoots h) (fun j => h.nonzero (successorIndex j)) a upper i

theorem hierarchy_forward_correct {F : Type} [Field F] (bits : Nat)
    (h : RootHierarchy F bits) (a : Fin (2^bits) → F) : hierarchyForward h a = hierarchyDft h a := by
  induction bits with
  | zero =>
    funext i
    have atZero : i = 0 := by apply Fin.ext; have := i.isLt; omega
    subst i
    simp [hierarchyForward, forwardFft, fft, radixStages, runForward, permute, reverseIndex,
      hierarchyDft, dft, evaluate, evaluateOn, List.finRange_succ, Semiring.pow_zero,
      Semiring.mul_one, Semiring.add_zero]
    congr 1
  | succ bits ih =>
    funext j
    obtain ⟨upper, i, rfl⟩ := half_index_covers bits j
    rw [hierarchy_recurrence]
    have even := congrArg (fun f => f i) (ih (truncate h) (fun k => a (evenOddIndex bits false k)))
    have odd := congrArg (fun f => f i) (ih (truncate h) (fun k => a (evenOddIndex bits true k)))
    dsimp only at even odd ⊢
    rw [even, odd]
    have square : (truncate h).value (Fin.last bits) =
        h.value (Fin.last (bits+1)) * h.value (Fin.last (bits+1)) := (h.square (Fin.last bits)).symm
    have half : h.value (Fin.last (bits+1))^(2^bits) = -1 := h.half (Fin.last bits)
    simp only [hierarchyDft, dft, square]
    exact (evaluate_half_index bits a _ half upper i).symm

#print axioms evaluate_half_index
#print axioms hierarchy_forward_correct

end ZkBuild.FftForward
