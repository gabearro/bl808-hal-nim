import DynamicTypingSound
set_option autoImplicit false
namespace ZkBuild.DynamicTypingSource
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix DynamicTypingMatrix
attribute [local instance] Ring.intCast Semiring.natCast

def SameEntry {F : Type} [Field F] (values : Nat → F) (a b : ReadOnlyMatrix.Entry) : Prop :=
  E values a.active = E values b.active ∧ E values a.address = E values b.address ∧ E values a.value = E values b.value

theorem same_entry {F : Type} [Field F] [IsCharP F scalarModulus]
    (values : Nat → F) (a b : ReadOnlyMatrix.Entry)
    (same : ModuleProgram.sameInputs (entry a) (entry b)) : SameEntry values a b := by
  have image := SourceProgramSound.normalized_inputs values _ _ same
  simpa only [entry,List.map_cons,List.map_nil,List.cons.injEq,and_true,SameEntry] using image

theorem origin_member {F : Type} [Field F] [IsCharP F scalarModulus]
    (values : Nat → F) (actual origin : List ReadOnlyMatrix.Entry)
    (same : same (DynamicTypingCheck.entries actual) (DynamicTypingCheck.entries origin) = true)
    (a : ReadOnlyMatrix.Entry) (member : a ∈ actual) : ∃ b ∈ origin, SameEntry values a b := by
  have equal := _root_.of_decide_eq_true same
  simp only [ValidationEventMatrix.normalized,DynamicTypingCheck.entries,List.map_map,Function.comp_def] at equal
  have normalized : (entry a).map normalizeLinear ∈ origin.map (fun b => (entry b).map normalizeLinear) := by
    rw [← equal]
    exact List.mem_map.mpr ⟨a,member,rfl⟩
  obtain ⟨b,bm,image⟩ := List.mem_map.mp normalized
  exact ⟨b,bm,same_entry values a b image.symm⟩

theorem query_origin {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (actual : ReadOnlyMatrix.Record) (origin : List ReadOnlyMatrix.Entry)
    (checked : ReadOnlyMatrix.check matrix actual = true)
    (same : same (DynamicTypingCheck.entries actual.entries) (DynamicTypingCheck.entries origin) = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (q : ReadOnlyMatrix.Entry) (member : q ∈ actual.queries) (active : E values q.active = 1) :
    ∃ source ∈ origin, E values source.active = 1 ∧ E values source.address = E values q.address ∧
      E values source.value = E values q.value := by
  obtain ⟨a,am,enabled,address,value⟩ := (DynamicTypingSound.table matrix actual checked values one satisfied).1 q member active
  obtain ⟨b,bm,flags,keys,vals⟩ := origin_member values actual.entries origin same a am
  exact ⟨b,bm,flags.symm.trans enabled,keys.symm.trans address,vals.symm.trans value⟩

theorem environment_origins {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (splits : Splits) (tables : List ReadOnlyMatrix.Record)
    (signature : SignatureMatrix.Record) (context : ModuleContextMatrix.Record) (locals : LocalRangeMatrix.Record)
    (events : ValidationEventMatrix.Record) (typing : DynamicTypingMatrix.Record)
    (accepted : DynamicTypingCheck.check matrix splits tables signature context locals events typing = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values) :
    let environment := DynamicTypingCheck.stage typing 1
    let calls := DynamicTypingCheck.stage typing 3
    (∀ q ∈ (bank tables environment 0).queries, E values q.active = 1 → ∃ source ∈ locals.locals,
      E values source.active = 1 ∧ E values source.address = E values q.address ∧ E values source.value = E values q.value) ∧
    (∀ q ∈ (bank tables environment 1).queries, E values q.active = 1 → ∃ source ∈ (ModuleContextMatrix.bank tables context 0).entries,
      E values source.active = 1 ∧ E values source.address = E values q.address ∧ E values source.value = E values q.value) ∧
    (∀ q ∈ (bank tables calls 0).queries, E values q.active = 1 → ∃ source ∈ (ModuleContextMatrix.bank tables context 0).entries,
      E values source.active = 1 ∧ E values source.address = E values q.address ∧ E values source.value = E values q.value) := by
  have parts := accepted
  simp only [DynamicTypingCheck.check,Bool.and_eq_true_iff] at parts
  have links := parts.1.1.1
  simp only [DynamicTypingCheck.links,Bool.and_eq_true_iff] at links
  have kindShape : typing.stages.map (·.kind) = [0,1,2,3] := by grind only
  have environmentMember : DynamicTypingCheck.stage typing 1 ∈ typing.stages := by
    unfold DynamicTypingCheck.stage
    have found : (typing.stages.find? (fun s => s.kind == 1)).isSome = true := by
      simp only [List.find?_isSome]
      have member : 1 ∈ typing.stages.map (·.kind) := by rw [kindShape]; simp
      obtain ⟨s,sm,kind⟩ := List.mem_map.mp member
      exact ⟨s,sm,by simpa only [kind,beq_self_eq_true]⟩
    cases h : typing.stages.find? (fun s => s.kind == 1) with
    | none => simp [h] at found
    | some s => simpa [h] using List.mem_of_find?_eq_some h
  have callsMember : DynamicTypingCheck.stage typing 3 ∈ typing.stages := by
    unfold DynamicTypingCheck.stage
    have found : (typing.stages.find? (fun s => s.kind == 3)).isSome = true := by
      simp only [List.find?_isSome]
      have member : 3 ∈ typing.stages.map (·.kind) := by rw [kindShape]; simp
      obtain ⟨s,sm,kind⟩ := List.mem_map.mp member
      exact ⟨s,sm,by simpa only [kind,beq_self_eq_true]⟩
    cases h : typing.stages.find? (fun s => s.kind == 3) with
    | none => simp [h] at found
    | some s => simpa [h] using List.mem_of_find?_eq_some h
  have banks := parts.1.2
  have shape := accepted
  simp only [DynamicTypingCheck.check,DynamicTypingCheck.links,Bool.and_eq_true_iff,decide_eq_true_eq] at shape
  have envBanks : (DynamicTypingCheck.stage typing 1).banks.length = 2 := by grind only
  have callBanks : (DynamicTypingCheck.stage typing 3).banks.length = 1 := by grind only
  have checkEnv (i : Nat) (bound : i < 2) : ReadOnlyMatrix.check matrix (bank tables (DynamicTypingCheck.stage typing 1) i) = true := by
    exact List.all_eq_true.mp (List.all_eq_true.mp banks _ environmentMember) _ (by rw [← List.getElem_eq_getD 0]; exact List.getElem_mem (by omega))
  have checkCall : ReadOnlyMatrix.check matrix (bank tables (DynamicTypingCheck.stage typing 3) 0) = true := by
    exact List.all_eq_true.mp (List.all_eq_true.mp banks _ callsMember) _ (by rw [← List.getElem_eq_getD 0]; exact List.getElem_mem (by omega))
  refine ⟨?_,?_,?_⟩
  · exact query_origin matrix _ _ (checkEnv 0 (by decide)) (by grind only) values one satisfied
  · exact query_origin matrix _ _ (checkEnv 1 (by decide)) (by grind only) values one satisfied
  · exact query_origin matrix _ _ checkCall (by grind only) values one satisfied

theorem source_bound {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (splits : Splits) (tables : List ReadOnlyMatrix.Record)
    (context : ModuleContextMatrix.Record) (code : BodySourceMatrix.Record) (locals : LocalRangeMatrix.Record)
    (catalog : InstructionDecodeMatrix.Catalog) (decoders : List InstructionDecodeMatrix.Record)
    (instructions : InstructionStreamMatrix.Record) (statics : ValidationEventMatrix.StaticCatalog)
    (admission : ValidationEventMatrix.LookupCatalog) (events : ValidationEventMatrix.Record)
    (signature : SignatureMatrix.Record) (typing : DynamicTypingMatrix.Record)
    (sourceChecked : ModuleTables.check matrix body tables splits = true)
    (instructionsChecked : InstructionStreamCheck.check matrix body.tokens splits tables context code catalog decoders instructions = true)
    (catalogsChecked : ValidationEventAuditIO.catalogs statics admission = true)
    (eventsChecked : ValidationEventCheck.check matrix statics admission instructions events = true)
    (typingChecked : DynamicTypingCheck.check matrix splits tables signature context locals events typing = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ message : List Sha256.Byte,
      BinarySourceMatrix.Message values body.source.firstWire body.source.capacity body.source.length message ∧
      values 1 = (ShaHashSound.digestLimb message 0 : F) ∧ values 2 = (ShaHashSound.digestLimb message 1 : F) ∧
      (∀ other, BinarySourceMatrix.Message values body.source.firstWire body.source.capacity body.source.length other → other = message) ∧
      ValidationSourceSound.Decoders matrix body splits catalog decoders values message ∧
      ValidationSourceSound.Stream matrix body splits tables catalog decoders instructions values message ∧
      (ValidationSourceSound.projected events).map (List.map (E values)) = instructions.events.map (List.map (E values)) ∧
      (∀ s ∈ events.stages, ValidationEventSound.StageFacts matrix statics admission values s) ∧
      (∀ s ∈ typing.stages, DynamicTypingSound.StageFacts matrix splits tables signature values s) ∧
      (∀ s ∈ typing.stages, ∀ i ∈ s.banks, DynamicTypingSound.TableFacts values (tables.getD i default)) := by
  obtain ⟨message,source,d0,d1,unique,_,decoders,stream,linked,_,stages,_,_,_,_⟩ :=
    ValidationSourceSound.checked matrix body splits tables context code catalog decoders instructions statics admission events
      sourceChecked instructionsChecked catalogsChecked eventsChecked values one satisfied
  have dynamic := DynamicTypingSound.checked matrix splits tables signature context locals events typing typingChecked values one satisfied
  exact ⟨message,source,d0,d1,unique,decoders,stream,linked,stages,dynamic⟩

#print axioms origin_member
#print axioms query_origin
#print axioms environment_origins
#print axioms source_bound
end ZkBuild.DynamicTypingSource
