import RuntimeContextSource
set_option autoImplicit false
namespace ZkBuild.RuntimeContextOrigins
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix DynamicTypingMatrix RuntimeContextMatrix
attribute [local instance] Ring.intCast Semiring.natCast

theorem metadata_values {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record)
    (context : ModuleContextMatrix.Record) (instructions : InstructionStreamMatrix.Record)
    (events : ValidationEventMatrix.Record) (r : RuntimeContextMatrix.Record)
    (accepted : RuntimeContextCheck.check matrix body tables context instructions events r = true)
    (catalog : RuntimeContextMatrix.catalogCheck r.catalog = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (id code : Nat) (record : LookupEmbedded.Record) (member : (id,record) ∈ r.catalog)
    (bounded : code < 2^16) (image : E values record.input = (code : F)) :
    record.outputs.map (E values) = (List.range 7).map (fun field => ((InstructionMetadata.payload code).getD field 0 : F)) := by
  have facts := RuntimeContextSound.checked matrix body tables context instructions events r accepted values one satisfied
  have typed := RuntimeContextSound.catalog r.catalog catalog id record member
  have result := LookupEmbedded.checked_values matrix record (facts.2.2 _ member) 16 _ typed.2 code bounded values one satisfied image
  simpa only [typed.1,Int.ofNat_eq_natCast,Ring.intCast_natCast] using result

theorem stage_member (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record)
    (context : ModuleContextMatrix.Record) (instructions : InstructionStreamMatrix.Record)
    (events : ValidationEventMatrix.Record) (r : RuntimeContextMatrix.Record)
    (links : RuntimeContextCheck.links matrix body tables context instructions events r = true)
    (kind : Nat) (present : kind ∈ [0,1,2]) : stage r kind ∈ r.stages := by
  have shape : r.stages.map (·.kind) = [0,1,2] := by
    simp only [RuntimeContextCheck.links,Bool.and_eq_true_iff] at links
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

def origin (tables : List ReadOnlyMatrix.Record) (context : ModuleContextMatrix.Record)
    (instructions : InstructionStreamMatrix.Record) (kind : Nat) : List ReadOnlyMatrix.Entry :=
  if kind == 0 then (InstructionStreamMatrix.bank tables instructions 5).entries
  else if kind == 1 then []
  else if kind == 2 then (ModuleContextMatrix.bank tables context 0).entries
  else (ModuleContextMatrix.bank tables context 3).entries

theorem query_origin {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record)
    (context : ModuleContextMatrix.Record) (instructions : InstructionStreamMatrix.Record)
    (events : ValidationEventMatrix.Record) (r : RuntimeContextMatrix.Record)
    (accepted : RuntimeContextCheck.check matrix body tables context instructions events r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (kind index sourceKind : Nat) (route : (kind,index,sourceKind) ∈ [(0,0,0),(1,1,2),(2,0,3)])
    (q : ReadOnlyMatrix.Entry) (member : q ∈ (bank tables (stage r kind) index).queries)
    (active : E values q.active = 1) :
    ∃ source ∈ origin tables context instructions sourceKind,
      E values source.active = 1 ∧ E values source.address = E values q.address ∧ E values source.value = E values q.value := by
  have parts := accepted
  simp only [RuntimeContextCheck.check,Bool.and_eq_true_iff] at parts
  have shape := parts.1.1.1
  have links := shape
  simp only [RuntimeContextCheck.links,RuntimeContextCheck.entries,Bool.and_eq_true_iff] at shape
  have widths : (stage r 0).banks.length = 1 ∧ (stage r 1).banks.length = 2 ∧ (stage r 2).banks.length = 1 := by grind only
  have present : kind ∈ [0,1,2] := by
    simp only [List.mem_cons,List.not_mem_nil,or_false,Prod.mk.injEq] at route ⊢
    grind only
  have bound : index < (stage r kind).banks.length := by
    simp only [List.mem_cons,List.not_mem_nil,or_false,Prod.mk.injEq] at route
    rcases route with h|h|h <;> obtain ⟨rfl,rfl,rfl⟩ := h <;> omega
  have same : DynamicTypingMatrix.same (DynamicTypingCheck.entries (bank tables (stage r kind) index).entries)
      (DynamicTypingCheck.entries (origin tables context instructions sourceKind)) = true := by
    simp only [List.mem_cons,List.not_mem_nil,or_false,Prod.mk.injEq] at route
    rcases route with h|h|h <;> obtain ⟨rfl,rfl,rfl⟩ := h <;>
      simp only [origin,Nat.reduceBEq,↓reduceIte,DynamicTypingCheck.entries] <;> grind only
  have stageMem := stage_member matrix body tables context instructions events r links kind present
  have inside : (stage r kind).banks.getD index 0 ∈ (stage r kind).banks := by
    rw [← List.getElem_eq_getD 0]
    exact List.getElem_mem bound
  have table := List.all_eq_true.mp (List.all_eq_true.mp parts.1.2 _ stageMem) _ inside
  exact DynamicTypingSource.query_origin matrix _ _ table same values one satisfied q member active

theorem data_count_binding {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record)
    (context : ModuleContextMatrix.Record) (instructions : InstructionStreamMatrix.Record)
    (events : ValidationEventMatrix.Record) (r : RuntimeContextMatrix.Record)
    (accepted : RuntimeContextCheck.check matrix body tables context instructions events r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values) :
    E values (get body.envelope.outputs 48) = E values (ValidationEventMatrix.f (ValidationEventMatrix.rowAt (stage r 1).auxiliary 0) 1) ∧
    E values (get body.envelope.outputs 49) = E values (ValidationEventMatrix.f (ValidationEventMatrix.rowAt (stage r 1).auxiliary 0) 3) := by
  have shape := accepted
  simp only [RuntimeContextCheck.check,RuntimeContextCheck.links,Bool.and_eq_true_iff] at shape
  have span : MemoryEvidence.checkSpan matrix r.bindFirst r.bindLast
      [eqGate (get body.envelope.outputs 48) (ValidationEventMatrix.f (ValidationEventMatrix.rowAt (stage r 1).auxiliary 0) 1),
       eqGate (get body.envelope.outputs 49) (ValidationEventMatrix.f (ValidationEventMatrix.rowAt (stage r 1).auxiliary 0) 3)] = true := by grind only
  have holds := MemoryEvidence.span_sound matrix _ _ _ span values satisfied
  exact ⟨equality_sound values one _ _ (holds _ (by simp)),equality_sound values one _ _ (holds _ (by simp))⟩
-- Bulk element queries obtain the element tag from a source-bound module row.
theorem element_origin {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record)
    (context : ModuleContextMatrix.Record) (instructions : InstructionStreamMatrix.Record)
    (events : ValidationEventMatrix.Record) (r : RuntimeContextMatrix.Record)
    (accepted : RuntimeContextCheck.check matrix body tables context instructions events r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (q : ReadOnlyMatrix.Entry) (member : q ∈ (bank tables (stage r 1) 0).queries)
    (active : E values q.active = 1) :
    ∃ source ∈ context.bulk, source.map (E values) = [1,E values q.address,E values q.value] := by
  have parts := accepted
  simp only [RuntimeContextCheck.check,Bool.and_eq_true_iff] at parts
  have links := parts.1.1.1
  have shape := links
  simp only [RuntimeContextCheck.links,Bool.and_eq_true_iff] at shape
  have width : (stage r 1).banks.length = 2 := by grind only
  have sm := stage_member matrix body tables context instructions events r links 1 (by simp)
  have inside : (stage r 1).banks.getD 0 0 ∈ (stage r 1).banks := by
    rw [← List.getElem_eq_getD 0]
    exact List.getElem_mem (by omega)
  have checked := List.all_eq_true.mp (List.all_eq_true.mp parts.1.2 _ sm) _ inside
  obtain ⟨a,am,enabled,address,value⟩ := (DynamicTypingSound.table matrix _ checked values one satisfied).1 q member active
  have same : DynamicTypingMatrix.same (RuntimeContextCheck.entries (bank tables (stage r 1) 0).entries) context.bulk = true := by grind only
  have norm := _root_.of_decide_eq_true same
  simp only [ValidationEventMatrix.normalized,RuntimeContextCheck.entries,List.map_map,Function.comp_def] at norm
  have normalized : (entry a).map normalizeLinear ∈ context.bulk.map (List.map normalizeLinear) := by
    rw [← norm]
    exact List.mem_map.mpr ⟨a,am,rfl⟩
  obtain ⟨row,rm,image⟩ := List.mem_map.mp normalized
  have equal : row.map (E values) = (entry a).map (E values) :=
    (SourceProgramSound.normalized_inputs values row (entry a) image)
  refine ⟨row,rm,?_⟩
  rw [equal]
  simp only [entry,List.map_cons,List.map_nil,enabled,address,value]

#print axioms metadata_values
#print axioms query_origin
#print axioms data_count_binding
#print axioms element_origin
end ZkBuild.RuntimeContextOrigins
