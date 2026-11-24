import ImportCounts
set_option autoImplicit false

namespace ZkBuild.ImportMembers
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ImportMatrix ImportRules ShaProgram
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

theorem member_check (matrix : Shape) (tokens : Tokens) (splits : Splits) (exports : Linear) (items : List Row)
    (index : Nat) (cursor : Linear) (counts : List Linear) (previous : Linear)
    (checked : checkRows matrix tokens splits exports items index cursor counts previous = true)
    (target : Row) (member : target ∈ items) :
    ∃ i c cs p, checkRow matrix tokens splits exports target i c cs p = true := by
  induction items generalizing index cursor counts previous with
  | nil => simp at member
  | cons row rest ih =>
    have parts := Bool.and_eq_true_iff.mp checked
    rcases List.mem_cons.mp member with same | later
    · subst target; exact ⟨index,cursor,counts,previous,parts.1⟩
    · exact ih (index+1) (readAt row 6).cursor row.counts row.active parts.2 later

theorem member_function {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (tokens : Tokens) (splits : Splits) (exports : Linear) (items : List Row)
    (index : Nat) (cursor : Linear) (counts : List Linear) (previous : Linear)
    (checked : checkRows matrix tokens splits exports items index cursor counts previous = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (functions : Nat) (capacity : functions+items.length < 2^32)
    (fi : E values (DeclarationMatrix.get counts 0) = (functions : F))
    (target : Row) (member : target ∈ items) (active : E values target.active = 1) (kind : E values target.kind = 0) :
    ∃ functionIndex : Nat, functionIndex < 2^32 ∧ E values target.typeQuery.active = 1 ∧
      E values target.typeQuery.address = ((2*functionIndex : Nat) : F) := by
  induction items generalizing index cursor counts previous functions with
  | nil => simp at member
  | cons row rest ih =>
    have parts := Bool.and_eq_true_iff.mp checked
    obtain ⟨d,image,kb,_,indicators,step⟩ := ImportRules.decode matrix tokens splits exports row index cursor counts previous parts.1 values oneValue satisfied
    rcases List.mem_cons.mp member with same | later
    · subst target
      have enabled : d.active = true := by
        have e := image.1.symm.trans active
        cases flag : d.active with
        | true => rfl
        | false => simp only [flag,Bool.toNat_false,Semiring.natCast_zero] at e; exact False.elim (Field.zero_ne_one e)
      have zero : d.kind = 0 := DeclarationLocations.natural_equal (F := F) _ 0 (by omega) (by decide) (by simpa using image.2.symm.trans kind)
      have ind : E values (DeclarationMatrix.get row.indicators 0) = 1 := by simpa [increment,enabled,zero] using indicators 0 (by decide)
      have shaped := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp parts.1).1).1).1
      have qa : row.typeQuery.active = DeclarationMatrix.get row.indicators 0 := by simp only [ImportMatrix.shape] at shaped; grind only
      have all := ImportRules.row_holds matrix tokens splits exports row index cursor counts previous parts.1 values satisfied
      have five := ImportRules.part_holds values tokens splits exports row index cursor counts previous all 5 (by decide)
      have q := multiply_sound values (DeclarationMatrix.get row.indicators 0) (scale (DeclarationMatrix.get counts 0) 2) row.typeQuery.address (five _ (by simp [rowParts,queryGate]))
      have scaleImage := eval_scale values (DeclarationMatrix.get counts 0) 2
      change E values (scale (DeclarationMatrix.get counts 0) 2) = ((2 : Int) : F)*E values (DeclarationMatrix.get counts 0) at scaleImage
      have two : ((2 : Int) : F) = ((2 : Nat) : F) := Ring.intCast_natCast 2
      refine ⟨functions,by simp only [List.length_cons] at capacity; omega,by rw [qa,ind],?_⟩
      rw [q,ind,scaleImage,two,fi,Semiring.one_mul,Semiring.natCast_mul]
    · have incrementBound : increment d 0 ≤ 1 := by unfold increment; split <;> decide
      have next : E values (DeclarationMatrix.get row.counts 0) = ((functions+increment d 0 : Nat) : F) := by
        rw [step 0 (by decide),fi,Semiring.natCast_add]
      exact ih (index+1) (readAt row 6).cursor row.counts row.active parts.2 (functions+increment d 0)
        (by simp only [List.length_cons] at capacity; omega) next later

theorem function_key {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record) (splits : Splits)
    (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record) (signature : SignatureMatrix.Record)
    (space : SignatureNamespace.Record) (imports : ImportMatrix.Record)
    (checked : ImportSound.check matrix body tables splits declaration indexed signature space imports = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (target : Row) (member : target ∈ imports.rows) (active : E values target.active = 1) (kind : E values target.kind = 0) :
    ∃ functionIndex : Nat, functionIndex < 2^32 ∧ E values target.typeQuery.active = 1 ∧
      E values target.typeQuery.address = ((2*functionIndex : Nat) : F) := by
  have imp := (Bool.and_eq_true_iff.mp checked).2
  simp only [ImportMatrix.check,Bool.and_eq_true_iff] at imp
  have shape : imports.rows.length < 2^32 ∧ imports.importedFunctions = space.importedFunctions ∧ links tables signature imports := _root_.of_decide_eq_true (by grind only)
  have rc : checkRows matrix body.tokens splits imports.exportCount imports.rows 0 (DeclarationMatrix.get body.envelope.outputs 10) [z,z,z,z] o = true := by grind only
  exact member_function matrix body.tokens splits imports.exportCount imports.rows 0 (DeclarationMatrix.get body.envelope.outputs 10) [z,z,z,z] o rc values oneValue satisfied 0
    (by simpa using shape.1) (by simp [DeclarationMatrix.get,z,eval_constant values oneValue]) target member active kind

theorem source_column {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record) (splits : Splits)
    (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record) (signature : SignatureMatrix.Record)
    (space : SignatureNamespace.Record) (imports : ImportMatrix.Record)
    (checked : ImportSound.check matrix body tables splits declaration indexed signature space imports = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (target : Row) (member : target ∈ imports.rows) (active : E values target.active = 1) (kind : E values target.kind = 0) :
    ∃ functionIndex : Nat, ∃ row : SignatureMatrix.MetadataRow, functionIndex < 2^32 ∧ row ∈ signature.metadata ∧
      E values row.entry.active = 1 ∧ E values row.entry.address = ((2*functionIndex : Nat) : F) ∧
      E values target.typeQuery.address = ((2*functionIndex : Nat) : F) ∧ E values row.typeIndex = E values target.typeQuery.value := by
  obtain ⟨index,ib,qa,qk⟩ := function_key matrix body tables splits declaration indexed signature space imports checked values oneValue satisfied target member active kind
  have outer := Bool.and_eq_true_iff.mp checked
  have indexedCheck := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp outer.1).1).1
  have moduleCheck := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp indexedCheck).1).1
  obtain ⟨_,lookup⟩ := ModuleTables.checked_queries matrix body tables splits moduleCheck values oneValue satisfied
  have imp := outer.2
  simp only [ImportMatrix.check,Bool.and_eq_true_iff] at imp
  have shape : imports.rows.length < 2^32 ∧ imports.importedFunctions = space.importedFunctions ∧ links tables signature imports := _root_.of_decide_eq_true (by grind only)
  have link := shape.2.2
  simp only [links] at link
  have bank : ImportMatrix.table tables imports 2 ∈ tables := by
    have b : 2 < imports.tables.length := by rw [link.1]; decide
    have m : imports.tables.getD 2 0 ∈ imports.tables := by rw [← List.getElem_eq_getD 0]; exact List.getElem_mem b
    unfold ImportMatrix.table
    rw [← List.getElem_eq_getD default]; exact List.getElem_mem (link.2.1 _ m)
  have qm : target.typeQuery ∈ (ImportMatrix.table tables imports 2).queries := (link.2.2.2.1 target member).2.2.1
  obtain ⟨entry,em,ea,ek,ev⟩ := lookup _ bank target.typeQuery qm qa
  rw [link.2.2.1] at em
  obtain ⟨row,rm,same⟩ := List.mem_map.mp em
  subst entry
  exact ⟨index,row,ib,rm,ea,ek.trans qk,qk,ev⟩

#print axioms function_key
#print axioms source_column
end ZkBuild.ImportMembers
