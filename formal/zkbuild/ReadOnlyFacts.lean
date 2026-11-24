import ReadOnlySound

namespace ZkBuild.ReadOnlyFacts
open Lean.Grind CircuitShape FullMatrix GadgetShape ShaProgram BinaryReadMemory
attribute [local instance] Ring.intCast Semiring.natCast

theorem entry_fields {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : ReadOnlyMatrix.Record) (checked : ReadOnlyMatrix.check matrix r = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (entry : ReadOnlyMatrix.Entry) (member : entry ∈ r.entries) :
    ∃ active : Bool, ∃ address value : Nat,
      address < 2^r.memory.addressBits ∧ value < 2^r.memory.valueBits ∧
      E values entry.active = (active.toNat : F) ∧ E values entry.address = (address : F) ∧ E values entry.value = (value : F) := by
  obtain ⟨entries,queries,images,_,_,_,_,bounds,_⟩ := ReadOnlySound.checked_membership matrix r checked values oneValue satisfied
  obtain ⟨decoded,mem,image⟩ := left_member _ _ _ images (ReadOnlyMatrix.initializer entry) (List.mem_map.mpr ⟨entry,member,rfl⟩)
  have bounded := bounds decoded (List.mem_append_left _ mem)
  exact ⟨decoded.active,decoded.address,decoded.value,bounded.1,bounded.2.2,image.1,image.2.2.1,image.2.2.2⟩

theorem query_value {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : ReadOnlyMatrix.Record) (checked : ReadOnlyMatrix.check matrix r = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (query : ReadOnlyMatrix.Entry) (member : query ∈ r.queries) :
    ∃ value : Nat, value < 2^r.memory.valueBits ∧ E values query.value = (value : F) := by
  obtain ⟨entries,queries,_,images,_,_,_,bounds,_⟩ := ReadOnlySound.checked_membership matrix r checked values oneValue satisfied
  obtain ⟨decoded,mem,image⟩ := left_member _ _ _ images (readAccess query) (List.mem_map.mpr ⟨query,member,rfl⟩)
  exact ⟨decoded.value,(bounds decoded (List.mem_append_right _ mem)).2.2,image.2.2.2⟩

theorem queries_agree {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : ReadOnlyMatrix.Record) (checked : ReadOnlyMatrix.check matrix r = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (a b : ReadOnlyMatrix.Entry) (am : a ∈ r.queries) (bm : b ∈ r.queries)
    (aa : E values a.active = 1) (ba : E values b.active = 1) (same : E values a.address = E values b.address) :
    E values a.value = E values b.value := by
  obtain ⟨_,_,_,_,_,_,_,_,membership⟩ := ReadOnlySound.checked_membership matrix r checked values oneValue satisfied
  obtain ⟨entry,em,ea,ek,ev⟩ := membership a am aa
  have other := ReadOnlySound.checked_expected matrix r checked values oneValue satisfied b entry bm em ba ea (ek.trans same)
  exact ev.symm.trans other.symm

#print axioms entry_fields
#print axioms query_value
#print axioms queries_agree
end ZkBuild.ReadOnlyFacts
