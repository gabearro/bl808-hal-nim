import ImportMembers
set_option autoImplicit false

namespace ZkBuild.ImportFunctionBounds
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ImportMatrix ImportRules ShaProgram
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

theorem member_function_bounded {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (tokens : Tokens) (splits : Splits) (exports : Linear) (items : List Row)
    (index : Nat) (cursor : Linear) (counts : List Linear) (previous : Linear)
    (checked : checkRows matrix tokens splits exports items index cursor counts previous = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (functions : Nat) (capacity : functions+items.length < 2^32)
    (fi : E values (DeclarationMatrix.get counts 0) = (functions : F))
    (target : Row) (member : target ∈ items) (active : E values target.active = 1) (kind : E values target.kind = 0) :
    ∃ functionIndex total : Nat, functionIndex < total ∧ total < 2^32 ∧
      E values (DeclarationMatrix.get (final items cursor counts).2 0) = (total : F) ∧
      E values target.typeQuery.active = 1 ∧ E values target.typeQuery.address = ((2*functionIndex : Nat) : F) := by
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
      obtain ⟨ds,images,_,_,totals,_⟩ := ImportCounts.rows matrix tokens splits exports rest (index+1) (readAt row 6).cursor row.counts row.active parts.2 values oneValue satisfied d.active image.1
      have len := related_length _ _ _ images
      have cb := ImportCounts.count_bound ds 0
      have ci := step 0 (by decide)
      rw [fi] at ci
      have inc : increment d 0 = 1 := by simp [increment,enabled,zero]
      rw [inc] at ci
      have tf := totals 0 (by decide)
      rw [ci] at tf
      have totalImage : E values (DeclarationMatrix.get (final (row::rest) cursor counts).2 0) = ((functions+1+ImportCounts.count ds 0 : Nat) : F) := by
        simp only [final,Semiring.natCast_add,Semiring.natCast_one]
        simpa only [Semiring.natCast_one] using tf
      refine ⟨functions,functions+1+ImportCounts.count ds 0,by omega,by simp only [List.length_cons] at capacity; omega,totalImage,by rw [qa,ind],?_⟩
      rw [q,ind,scaleImage,two,fi,Semiring.one_mul,Semiring.natCast_mul]
    · have incrementBound : increment d 0 ≤ 1 := by unfold increment; split <;> decide
      have next : E values (DeclarationMatrix.get row.counts 0) = ((functions+increment d 0 : Nat) : F) := by
        rw [step 0 (by decide),fi,Semiring.natCast_add]
      simpa only [final] using ih (index+1) (readAt row 6).cursor row.counts row.active parts.2 (functions+increment d 0)
        (by simp only [List.length_cons] at capacity; omega) next later


theorem checked_bound {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record) (splits : Splits)
    (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record) (signature : SignatureMatrix.Record)
    (space : SignatureNamespace.Record) (imports : ImportMatrix.Record)
    (checked : ImportSound.check matrix body tables splits declaration indexed signature space imports = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (target : Row) (member : target ∈ imports.rows) (active : E values target.active = 1) (kind : E values target.kind = 0) :
    ∃ functionIndex total : Nat, functionIndex < total ∧ total < 2^32 ∧ E values imports.importedFunctions = (total : F) ∧
      E values target.typeQuery.active = 1 ∧ E values target.typeQuery.address = ((2*functionIndex : Nat) : F) := by
  have imp := (Bool.and_eq_true_iff.mp checked).2
  simp only [ImportMatrix.check,ImportMatrix.closeGates,Bool.and_eq_true_iff] at imp
  have shape : imports.rows.length < 2^32 ∧ imports.importedFunctions = space.importedFunctions ∧ links tables signature imports := _root_.of_decide_eq_true (by grind only)
  have rc : checkRows matrix body.tokens splits imports.exportCount imports.rows 0 (DeclarationMatrix.get body.envelope.outputs 10) [z,z,z,z] o = true := by grind only
  obtain ⟨index,total,bound,tb,ti,qa,qk⟩ := member_function_bounded matrix body.tokens splits imports.exportCount imports.rows 0 (DeclarationMatrix.get body.envelope.outputs 10) [z,z,z,z] o rc values oneValue satisfied 0
    (by simpa using shape.1) (by simp [DeclarationMatrix.get,z,eval_constant values oneValue]) target member active kind
  have close : MemoryEvidence.checkSpan matrix imports.closeStart imports.closeEnd (closeGates body imports) = true := by simpa only [closeGates] using imp.2
  have eq := equality_sound values oneValue (DeclarationMatrix.get (final imports.rows (DeclarationMatrix.get body.envelope.outputs 10) [z,z,z,z]).2 0) imports.importedFunctions
    (MemoryEvidence.span_sound matrix _ _ _ close values satisfied _ (by simp [closeGates]))
  exact ⟨index,total,bound,tb,eq.symm.trans ti,qa,qk⟩

#print axioms checked_bound
end ZkBuild.ImportFunctionBounds
