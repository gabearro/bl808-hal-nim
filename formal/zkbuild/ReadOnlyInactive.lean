import ReadOnlyFacts
set_option autoImplicit false
namespace ZkBuild.ReadOnlyInactive
open Lean.Grind CircuitShape FullMatrix GadgetShape BinaryReadMemory
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

theorem same_fields {F : Type} [Field F] [IsCharP F scalarModulus] (values : Nat → F)
    (a b : MemoryPacking.Access) (same : normalizedPayload a = normalizedPayload b) :
    E values a.active = E values b.active ∧ E values a.write = E values b.write ∧
    E values a.address = E values b.address ∧ E values a.value = E values b.value := by
  have eqs := congrArg (List.map (fun l => E values (l : Linear))) same
  simpa only [normalizedPayload,List.map_map,Function.comp_def,E,FullMatrix.evalLinear,
    normalized_linear_same_field,payload,List.map_cons,List.map_nil,List.cons.injEq,and_true] using eqs

theorem access_zero {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : MemoryEvidence.AccessRef) (addressBits valueBits : Nat)
    (checked : MemoryEvidence.checkAccess matrix r addressBits valueBits = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (inactive : E values r.fields.active = 0) : E values r.fields.address = 0 ∧ E values r.fields.value = 0 := by
  have parts := checked
  simp only [MemoryEvidence.checkAccess,Bool.and_eq_true_iff] at parts
  have zeroCheck : MemoryEvidence.checkSpan matrix (r.lastGate-3) r.lastGate (MemoryEvidence.zeros r.fields) = true := by grind only
  have holds := MemoryEvidence.span_sound matrix _ _ _ zeroCheck values satisfied
  constructor
  · have eqn := holds (mulGate (sub (constant 1) r.fields.active) r.fields.address (constant 0)) (by simp [MemoryEvidence.zeros])
    change E values (sub (constant 1) r.fields.active)*E values r.fields.address = E values (constant 0) at eqn
    rw [eval_sub,eval_constant values oneValue,eval_constant values oneValue,inactive] at eqn
    simp only [Ring.intCast_one,Ring.intCast_zero] at eqn
    grind
  · have eqn := holds (mulGate (sub (constant 1) r.fields.active) r.fields.value (constant 0)) (by simp [MemoryEvidence.zeros])
    change E values (sub (constant 1) r.fields.active)*E values r.fields.value = E values (constant 0) at eqn
    rw [eval_sub,eval_constant values oneValue,eval_constant values oneValue,inactive] at eqn
    simp only [Ring.intCast_one,Ring.intCast_zero] at eqn
    grind

theorem input_checked (matrix : Shape) (addressBits valueBits offset : Nat) (inputs : List MemoryEvidence.AccessRef)
    (checked : MemoryEmbedded.checkInputs matrix addressBits valueBits offset inputs = true)
    (r : MemoryEvidence.AccessRef) (member : r ∈ inputs) : MemoryEvidence.checkAccess matrix r addressBits valueBits = true := by
  induction inputs generalizing offset with
  | nil => simp at member
  | cons h rest ih =>
    have parts := checked
    simp only [MemoryEmbedded.checkInputs,Bool.and_eq_true_iff] at parts
    rcases List.mem_cons.mp member with same | later
    · subst r; exact parts.1.1
    · exact ih (offset+1) parts.2 later

theorem query_zero {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : ReadOnlyMatrix.Record) (checked : ReadOnlyMatrix.check matrix r = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (q : ReadOnlyMatrix.Entry) (member : q ∈ r.queries) (inactive : E values q.active = 0) :
    E values q.address = 0 ∧ E values q.value = 0 := by
  have parts := checked
  simp only [ReadOnlyMatrix.check,Bool.and_eq_true_iff] at parts
  have metadata : r.steps.length = r.entries.length-1 ∧ r.entries.length+r.queries.length ≤ r.memory.inputs.length ∧
      r.memory.inputs.map (fun x => normalizedPayload x.fields) = (ReadOnlyMatrix.expected r.entries r.queries r.memory.inputs.length).map normalizedPayload := by
    exact _root_.of_decide_eq_true (by grind only)
  have found : normalizedPayload (readAccess q) ∈ r.memory.inputs.map (fun x => normalizedPayload x.fields) := by
    rw [metadata.2.2]
    apply List.mem_map.mpr
    refine ⟨readAccess q,?_,rfl⟩
    simp only [ReadOnlyMatrix.expected,List.mem_append]
    exact Or.inl (Or.inr (List.mem_map.mpr ⟨q,member,rfl⟩))
  obtain ⟨access,am,equal⟩ := List.mem_map.mp found
  have fields := same_fields values access.fields (readAccess q) equal
  have memoryCheck : MemoryEmbedded.check matrix r.memory = true := by grind only
  have inputCheck : MemoryEmbedded.checkInputs matrix r.memory.addressBits r.memory.valueBits 0 r.memory.inputs = true := by
    simp only [MemoryEmbedded.check,Bool.and_eq_true_iff] at memoryCheck
    grind only
  have zero := access_zero matrix access _ _ (input_checked matrix _ _ 0 _ inputCheck access am) values oneValue satisfied
    (fields.1.trans inactive)
  exact ⟨fields.2.2.1.symm.trans zero.1,fields.2.2.2.symm.trans zero.2⟩

#print axioms query_zero
end ZkBuild.ReadOnlyInactive
