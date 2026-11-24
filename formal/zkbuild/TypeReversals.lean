import IndexedSignatures
import CallEvents

namespace ZkBuild.TypeReversals

open Lean.Grind SignatureLists
attribute [local instance] Semiring.natCast

theorem reversal_sound (a b : List Nat) (size : a.length = b.length)
    (points : ∀ i (ha : i < a.length) (hb : i < b.length),
      a[i]'ha = b[b.length-1-i]'(Nat.sub_one_sub_lt_of_lt hb)) : a = b.reverse := by
  apply List.ext_getElem (by simpa using size)
  intro i ha hb
  rw [List.getElem_reverse hb]
  exact points i ha (by simpa using hb)

theorem reversal_complete (a : List Nat) : a.length = a.reverse.length ∧
    ∀ i (ha : i < a.length) (hb : i < a.reverse.length),
      a[i]'ha = a.reverse[a.reverse.length-1-i]'(Nat.sub_one_sub_lt_of_lt hb) := by
  refine ⟨by simp, ?_⟩
  intro i ha hb
  rw [List.getElem_reverse]
  congr 1
  simp only [List.length_reverse]
  omega

theorem head_comparison (table : Table) (head : Nat) (target payload : List Nat)
    (normal : Represents table head target.reverse) (tagged : Represents table head payload.reverse) :
    target = payload := List.reverse_inj.mp (represents_unique table head _ _ normal tagged)

theorem opaque_head_comparison (table : Table) (head tail : Nat) (node : Node)
    (target payload : List Nat) (nonzero : head ≠ 0) (found : table head = some node)
    (kind : node.tag.val = 6) (next : node.next = tail)
    (normal : Represents table head target.reverse) (tagged : Represents table tail payload.reverse) :
    target = payload ++ [6] := by
  have rep : Represents table head (6 :: payload.reverse) := by
    simpa [kind, next] using (Represents.cons nonzero found (by simpa [next] using tagged))
  have same := represents_unique table head _ _ normal rep
  apply List.reverse_inj.mp
  simpa using same

theorem head_gate {F : Type} [Field F] [IsCharP F scalarModulus]
    (a b : Nat) (ab : a < 2^32) (bb : b < 2^32)
    (gate : (a : F)-(b : F) = 0) : a = b := by
  exact NumericEvents.nat_eq (F := F) a b
    (by simp [NumericEvents.countBound]; omega) (by simp [NumericEvents.countBound]; omega) (by grind)

#print axioms reversal_sound
#print axioms reversal_complete
#print axioms head_comparison
#print axioms opaque_head_comparison
#print axioms head_gate

end ZkBuild.TypeReversals
