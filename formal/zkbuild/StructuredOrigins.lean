import StructuredSource
set_option autoImplicit false
namespace ZkBuild.StructuredOrigins
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix DynamicTypingMatrix StructuredMatrix
attribute [local instance] Ring.intCast Semiring.natCast

theorem stage_member (tables : List ReadOnlyMatrix.Record) (events : ValidationEventMatrix.Record)
    (instructions : InstructionStreamMatrix.Record) (signature : SignatureMatrix.Record) (indexed : IndexedMatrix.Record)
    (declaration : DeclarationMatrix.Record) (r : StructuredMatrix.Record)
    (links : StructuredCheck.links tables events instructions signature indexed declaration r = true)
    (kind : Nat) (present : kind ∈ [0,1,2,3,4,5,6,9,8,7]) : stage r kind ∈ r.stages := by
  have shape : r.stages.map (·.kind) = [0,1,2,3,4,5,6,9,8,7] := by
    simp only [StructuredCheck.links,Bool.and_eq_true_iff] at links
    grind only
  unfold stage
  have found : (r.stages.find? (fun s => s.kind == kind)).isSome = true := by
    simp only [List.find?_isSome]
    have member : kind ∈ r.stages.map (·.kind) := by rw [shape]; exact present
    obtain ⟨s,sm,equal⟩ := List.mem_map.mp member
    exact ⟨s,sm,by simp only [equal,beq_self_eq_true]⟩
  cases h : r.stages.find? (fun s => s.kind == kind) with
  | none => simp [h] at found
  | some s => simpa [h] using List.mem_of_find?_eq_some h

theorem bank_checked (matrix : Shape) (splits : Splits) (tables : List ReadOnlyMatrix.Record)
    (events : ValidationEventMatrix.Record) (instructions : InstructionStreamMatrix.Record)
    (signature : SignatureMatrix.Record) (indexed : IndexedMatrix.Record) (declaration : DeclarationMatrix.Record)
    (r : StructuredMatrix.Record)
    (accepted : StructuredCheck.check matrix splits tables events instructions signature indexed declaration r = true)
    (kind index : Nat) (present : kind ∈ [0,1,2,3,4,5,6,9,8,7])
    (bound : index < (stage r kind).banks.length) :
    ReadOnlyMatrix.check matrix (bank tables (stage r kind) index) = true := by
  have parts := accepted
  simp only [StructuredCheck.check,Bool.and_eq_true_iff] at parts
  have member := stage_member tables events instructions signature indexed declaration r parts.1.1.1.1 kind present
  have inside : (stage r kind).banks.getD index 0 ∈ (stage r kind).banks := by
    rw [← List.getElem_eq_getD 0]
    exact List.getElem_mem bound
  exact List.all_eq_true.mp (List.all_eq_true.mp parts.1.1.2 _ member) _ inside

-- The source instruction checker and dynamic control readers use the same
-- initializer entries in both supported byte-source representations.
theorem control_origins {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (splits : Splits) (tables : List ReadOnlyMatrix.Record)
    (events : ValidationEventMatrix.Record) (instructions : InstructionStreamMatrix.Record)
    (signature : SignatureMatrix.Record) (indexed : IndexedMatrix.Record) (declaration : DeclarationMatrix.Record)
    (r : StructuredMatrix.Record)
    (accepted : StructuredCheck.check matrix splits tables events instructions signature indexed declaration r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (kind index origin : Nat)
    (route : (kind,index,origin) ∈ [(0,0,7),(0,1,9),(0,2,10),(2,0,6),(2,1,8)])
    (q : ReadOnlyMatrix.Entry) (member : q ∈ (bank tables (stage r kind) index).queries)
    (active : E values q.active = 1) :
    ∃ source ∈ (InstructionStreamMatrix.bank tables instructions origin).entries,
      E values source.active = 1 ∧ E values source.address = E values q.address ∧ E values source.value = E values q.value := by
  have parts := accepted
  simp only [StructuredCheck.check,Bool.and_eq_true_iff] at parts
  have links := parts.1.1.1.1
  have shape := links
  simp only [StructuredCheck.links,StructuredCheck.entries,Bool.and_eq_true_iff] at shape
  have widths : (stage r 0).banks.length = 3 ∧ (stage r 2).banks.length = 2 := by grind only
  have present : kind ∈ [0,1,2,3,4,5,6,9,8,7] := by
    simp only [List.mem_cons,List.not_mem_nil,or_false,Prod.mk.injEq] at route ⊢
    grind only
  have bound : index < (stage r kind).banks.length := by
    simp only [List.mem_cons,List.not_mem_nil,or_false,Prod.mk.injEq] at route
    rcases route with h|h|h|h|h <;> obtain ⟨rfl,rfl,rfl⟩ := h <;> omega
  have same : DynamicTypingMatrix.same (DynamicTypingCheck.entries (bank tables (stage r kind) index).entries)
      (DynamicTypingCheck.entries (InstructionStreamMatrix.bank tables instructions origin).entries) = true := by
    simp only [List.mem_cons,List.not_mem_nil,or_false,Prod.mk.injEq] at route
    rcases route with h|h|h|h|h <;> obtain ⟨rfl,rfl,rfl⟩ := h <;> simp only [DynamicTypingCheck.entries] <;> grind only
  exact DynamicTypingSource.query_origin matrix _ _
    (bank_checked matrix splits tables events instructions signature indexed declaration r accepted kind index present bound)
    same values one satisfied q member active

-- The remaining control/exception type queries share the signature and
-- indexed-list initializers whose source construction is checked separately.
def typeOrigin (tables : List ReadOnlyMatrix.Record) (signature : SignatureMatrix.Record)
    (indexed : IndexedMatrix.Record) (origin : Nat) : ReadOnlyMatrix.Record :=
  if origin < 2 then SignatureMatrix.table tables signature origin
  else IndexedMatrix.table tables indexed (origin-2)

theorem type_origins {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (splits : Splits) (tables : List ReadOnlyMatrix.Record)
    (events : ValidationEventMatrix.Record) (instructions : InstructionStreamMatrix.Record)
    (signature : SignatureMatrix.Record) (indexed : IndexedMatrix.Record) (declaration : DeclarationMatrix.Record)
    (r : StructuredMatrix.Record)
    (accepted : StructuredCheck.check matrix splits tables events instructions signature indexed declaration r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (kind index origin : Nat)
    (route : (kind,index,origin) ∈ [(6,0,0),(7,0,0),(7,1,4),(7,4,1),(8,1,2),(8,2,3),(9,0,0),(9,2,1)])
    (q : ReadOnlyMatrix.Entry) (member : q ∈ (bank tables (stage r kind) index).queries)
    (active : E values q.active = 1) :
    ∃ source ∈ (typeOrigin tables signature indexed origin).entries,
      E values source.active = 1 ∧ E values source.address = E values q.address ∧ E values source.value = E values q.value := by
  have parts := accepted
  simp only [StructuredCheck.check,Bool.and_eq_true_iff] at parts
  have shape := parts.1.1.1.1
  simp only [StructuredCheck.links,StructuredCheck.entries,Bool.and_eq_true_iff] at shape
  have widths : (stage r 6).banks.length = 1 ∧ (stage r 7).banks.length = 5 ∧
      (stage r 8).banks.length = 3 ∧ (stage r 9).banks.length = 3 := by grind only
  have present : kind ∈ [0,1,2,3,4,5,6,9,8,7] := by
    simp only [List.mem_cons,List.not_mem_nil,or_false,Prod.mk.injEq] at route ⊢
    grind only
  have bound : index < (stage r kind).banks.length := by
    simp only [List.mem_cons,List.not_mem_nil,or_false,Prod.mk.injEq] at route
    rcases route with h|h|h|h|h|h|h|h <;> obtain ⟨rfl,rfl,rfl⟩ := h <;> omega
  have same : DynamicTypingMatrix.same (DynamicTypingCheck.entries (bank tables (stage r kind) index).entries)
      (DynamicTypingCheck.entries (typeOrigin tables signature indexed origin).entries) = true := by
    simp only [List.mem_cons,List.not_mem_nil,or_false,Prod.mk.injEq] at route
    rcases route with h|h|h|h|h|h|h|h <;> obtain ⟨rfl,rfl,rfl⟩ := h <;>
      simp only [typeOrigin, Nat.reduceLT, Nat.reduceSub, ↓reduceIte, DynamicTypingCheck.entries] <;> grind only
  exact DynamicTypingSource.query_origin matrix _ _
    (bank_checked matrix splits tables events instructions signature indexed declaration r accepted kind index present bound)
    same values one satisfied q member active

#print axioms stage_member
#print axioms bank_checked
#print axioms control_origins
#print axioms type_origins
end ZkBuild.StructuredOrigins
