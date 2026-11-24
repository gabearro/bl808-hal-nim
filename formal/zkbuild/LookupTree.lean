import R1CS

/- The shared-prefix lookup arithmetic. A separate static table determines
   leaf payloads; this theorem applies to every payload field independently. -/
namespace ZkBuild.LookupTree

open Lean.Grind
attribute [local instance] Semiring.natCast

inductive Tree where
  | leaf (value : Nat)
  | branch (bit : Nat) (zero one : Tree)

def evaluate (bits : Nat → Bool) : Tree → Nat
  | .leaf value => value
  | .branch bit zero one => if bits bit then evaluate bits one else evaluate bits zero

def polynomial {F : Type} [CommRing F] (bits : Nat → Bool) (active : F) : Tree → F
  | .leaf value => active * (value : F)
  | .branch bit zero one =>
    let selected : F := active * (if bits bit then 1 else 0)
    polynomial bits (active-selected) zero + polynomial bits selected one

theorem polynomial_correct {F : Type} [CommRing F] (bits : Nat → Bool) (active : F) (tree : Tree) :
    polynomial bits active tree = active * (evaluate bits tree : F) := by
  induction tree generalizing active with
  | leaf value => rfl
  | branch bit zero one left right =>
    cases h : bits bit <;> simp [polynomial, evaluate, h, left, right] <;> grind

theorem lookup_correct {F : Type} [CommRing F] (bits : Nat → Bool) (tree : Tree) :
    polynomial bits (1 : F) tree = (evaluate bits tree : F) := by
  have h := polynomial_correct bits (1 : F) tree
  grind

#print axioms lookup_correct

end ZkBuild.LookupTree
