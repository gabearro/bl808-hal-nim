import IndexedBridge

namespace ZkBuild.IndexedBoundary
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix EnvelopeMatrix IndexedMatrix
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

theorem length_empty {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (r : LengthRow) (checked : checkLength matrix r = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (active : E values r.entry.active = 1) :
    (E values r.entry.address = 0 ↔ E values r.entry.value = 0) ∧
    E values r.firstMember.active = (if E values r.entry.address = 0 then 0 else 1) ∧
    E values r.firstMember.address = (if E values r.entry.address = 0 then 0 else ((2^32 : Nat) : F)*E values r.entry.address) := by
  have fields : r.firstMember.active = r.nonempty := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp checked).1
  have all := MemoryEvidence.span_sound matrix _ _ _ (Bool.and_eq_true_iff.mp checked).2 values satisfied
  have head := zero_sound values oneValue r.entry.address (wire r.headZero) (wire (r.headZero+1))
    (by intro g gm; exact all g (by simp only [lengthGates,List.mem_append]; exact Or.inl (Or.inl gm)))
  have len := zero_sound values oneValue r.entry.value (wire r.lengthZero) (wire (r.lengthZero+1))
    (by intro g gm; exact all g (by simp only [lengthGates,List.mem_append]; exact Or.inl (Or.inr gm)))
  have same := all (gate r.entry.active (sub (wire r.headZero) (wire r.lengthZero))) (by simp [lengthGates])
  change E values r.entry.active*E values (sub (wire r.headZero) (wire r.lengthZero)) = E values z at same
  have zero : E values z = 0 := by simp [z,eval_constant values oneValue]
  have one : E values o = 1 := by simp [o,eval_constant values oneValue]
  rw [active,eval_sub,head,len,zero] at same
  have empty : E values r.entry.address = 0 ↔ E values r.entry.value = 0 := by
    by_cases h : E values r.entry.address = 0 <;> by_cases l : E values r.entry.value = 0
    all_goals simp only [h,l,↓reduceIte] at same ⊢
    all_goals have bad : (1 : F) = 0 := by grind
    all_goals exact False.elim (Field.zero_ne_one bad.symm)
  have nonempty := multiply_sound values r.entry.active (sub o (wire r.headZero)) r.nonempty (all _ (by simp [lengthGates]))
  rw [active,eval_sub,one,head,Semiring.one_mul] at nonempty
  have ni : E values r.nonempty = if E values r.entry.address = 0 then 0 else 1 := by
    by_cases h : E values r.entry.address = 0 <;> simp only [h,↓reduceIte] at nonempty ⊢ <;> grind
  have first := multiply_sound values r.nonempty (scale r.entry.address (Int.ofNat (2^32))) r.firstMember.address (all _ (by simp [lengthGates]))
  have scaled := eval_scale values r.entry.address (Int.ofNat (2^32))
  change E values (scale r.entry.address (Int.ofNat (2^32))) = (Int.ofNat (2^32) : F)*E values r.entry.address at scaled
  have cast : (Int.ofNat (2^32) : F) = ((2^32 : Nat) : F) := Ring.intCast_natCast _
  rw [ni,scaled,cast] at first
  refine ⟨empty,by rw [fields]; exact ni,?_⟩
  by_cases h : E values r.entry.address = 0 <;> simpa only [h,↓reduceIte,Semiring.zero_mul,Semiring.one_mul] using first

theorem singleton {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : SingletonRow) (index : Nat) (checked : checkSingleton matrix r index = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) :
    E values r.entry.active = 1 ∧ E values r.entry.address = (index : F) ∧
    E values r.nodeQuery.active = 1 ∧ E values r.nodeQuery.address = E values r.entry.value ∧ E values r.nodeQuery.value = (index : F) := by
  have fields : r.nodeQuery.active = o := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp checked).1
  have all := MemoryEvidence.span_sound matrix _ _ _ (Bool.and_eq_true_iff.mp checked).2 values satisfied
  have one : E values o = 1 := by simp [o,eval_constant values oneValue]
  have literal : E values (n index) = (index : F) := (eval_constant values oneValue (Int.ofNat index)).trans (Ring.intCast_natCast index)
  have active := equality_sound values oneValue r.entry.active o (all _ (by simp [singletonGates]))
  have address := equality_sound values oneValue r.entry.address (n index) (all _ (by simp [singletonGates]))
  have key := multiply_sound values o r.entry.value r.nodeQuery.address (all _ (by simp [singletonGates,queryGate]))
  have value := equality_sound values oneValue r.nodeQuery.value (n index) (all _ (by simp [singletonGates]))
  exact ⟨active.trans one,address.trans literal,by rw [fields]; exact one,by simpa only [one,Semiring.one_mul] using key,value.trans literal⟩

#print axioms length_empty
#print axioms singleton
end ZkBuild.IndexedBoundary
