import ScalarPayloadSound
set_option autoImplicit false
namespace ZkBuild.ScalarPayloadRules
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ScalarPayloadMatrix ShaProgram
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

theorem metadata (matrix : Shape) (tokens : Tokens) (splits : Splits) (imports : ImportMatrix.Record)
    (constants : List ConstantSourceMatrix.Record) (kind : Nat) (row : Row) (i : Nat) (start previous : Linear)
    (checked : checkRow matrix tokens splits imports constants kind row i start previous = true) :
    shape tokens splits constants kind row start := by
  exact _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp checked).1).1

theorem row_holds {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (tokens : Tokens) (splits : Splits) (imports : ImportMatrix.Record)
    (constants : List ConstantSourceMatrix.Record) (kind : Nat) (row : Row) (i : Nat) (start previous : Linear)
    (checked : checkRow matrix tokens splits imports constants kind row i start previous = true)
    (values : Nat → F) (satisfied : Satisfied matrix values) :
    AllHold values (rowGates tokens splits imports constants kind row i start previous) :=
  MemoryEvidence.span_sound matrix row.firstGate row.lastGate _ (Bool.and_eq_true_iff.mp checked).2 values satisfied

theorem member_check (matrix : Shape) (tokens : Tokens) (splits : Splits) (imports : ImportMatrix.Record)
    (constants : List ConstantSourceMatrix.Record) (kind : Nat) (rows : List Row) (i : Nat) (start previous : Linear)
    (checked : checkRows matrix tokens splits imports constants kind rows i start previous = true)
    (row : Row) (member : row ∈ rows) : ∃ j s p, checkRow matrix tokens splits imports constants kind row j s p = true := by
  induction rows generalizing i start previous with
  | nil => simp at member
  | cons r rs ih =>
    have c := Bool.and_eq_true_iff.mp checked
    rcases List.mem_cons.mp member with same | later
    · subst row; exact ⟨i,start,previous,c.1⟩
    · exact ih (i+1) (rowEnd constants kind r) r.active c.2 later

theorem kind_checked (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record)
    (splits : Splits) (imports : ImportMatrix.Record) (constants : List ConstantSourceMatrix.Record) (r : ScalarPayloadMatrix.Record)
    (checked : ScalarPayloadMatrix.check matrix body tables splits imports constants r = true) (kind : Nat) (kb : kind < 4) :
    checkRows matrix body.tokens splits imports constants kind (getRows r kind) 0 (ScalarPayloadMatrix.start body kind) o = true ∧
    MemoryEvidence.checkSpan matrix (r.closeStarts.getD kind 0) (r.closeEnds.getD kind 0) (closeGates body constants r kind) = true := by
  exact Bool.and_eq_true_iff.mp (List.all_eq_true.mp (Bool.and_eq_true_iff.mp checked).2 kind (List.mem_range.mpr kb))

theorem first_read (tokens : Tokens) (splits : Splits) (constants : List ConstantSourceMatrix.Record)
    (kind : Nat) (kb : kind < 4) (row : Row) (start : Linear)
    (sh : shape tokens splits constants kind row start) :
    (readAt row 0).token < tokens.length ∧ (EnvelopeMatrix.token tokens (readAt row 0).token).kind = 0 ∧
      (EnvelopeMatrix.token tokens (readAt row 0).token).activeMode = row.active := by
  have cases : kind = 0 ∨ kind = 1 ∨ kind = 2 ∨ kind = 3 := by omega
  rcases cases with rfl | rfl | rfl | rfl
  · have read := sh.2.2.1
    exact ⟨read.1,read.2.1,read.2.2.1⟩
  · have read := sh.2.2.2.2.1
    exact ⟨read.1,read.2.1,read.2.2.1⟩
  · have read := sh.2.2.2.1
    exact ⟨read.1,read.2.1,read.2.2.1⟩
  · have read := sh.2.2.2.1
    exact ⟨read.1,read.2.1,read.2.2.1⟩

theorem active_boolean {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (tokens : Tokens) (tokenChecks : tokens.all (BinaryTokenMatrix.check matrix) = true)
    (splits : Splits) (imports : ImportMatrix.Record) (constants : List ConstantSourceMatrix.Record)
    (kind : Nat) (kb : kind < 4) (row : Row) (i : Nat) (start previous : Linear)
    (checked : checkRow matrix tokens splits imports constants kind row i start previous = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) :
    E values row.active = 0 ∨ E values row.active = 1 := by
  have first := first_read tokens splits constants kind kb row start (metadata matrix tokens splits imports constants kind row i start previous checked)
  let t := EnvelopeMatrix.token tokens (readAt row 0).token
  have tm : t ∈ tokens := by unfold t; rw [EnvelopeMatrix.token,← List.getElem_eq_getD default]; exact List.getElem_mem first.1
  have tc := List.all_eq_true.mp tokenChecks t tm
  have all := BinaryTokenMatrix.checked_holds matrix t tc values satisfied
  have kind : t.kind = 0 := first.2.1
  have bit := boolean_sound values oneValue t.activeMode (all _ (by simp [BinaryTokenMatrix.gates,BinaryTokenMatrix.prologue,kind]))
  have image : t.activeMode = row.active := first.2.2
  rw [image] at bit
  exact bit

theorem global_constant (matrix : Shape) (tokens : Tokens) (splits : Splits) (imports : ImportMatrix.Record)
    (constants : List ConstantSourceMatrix.Record) (row : Row) (i : Nat) (start previous : Linear)
    (checked : checkRow matrix tokens splits imports constants 2 row i start previous = true) :
    constAt constants row ∈ constants ∧
      ConstantSourceMatrix.same (ConstantSourceMatrix.field (constAt constants row) 0) row.active ∧
      ConstantSourceMatrix.same (ConstantSourceMatrix.field (constAt constants row) 1) o ∧
      ConstantSourceMatrix.same (ConstantSourceMatrix.field (constAt constants row) 2) (readAt row 1).cursor := by
  have sh := metadata matrix tokens splits imports constants 2 row i start previous checked
  refine ⟨?_,sh.2.2.2.2.2.1,sh.2.2.2.2.2.2.1,sh.2.2.2.2.2.2.2⟩
  unfold constAt
  rw [← List.getElem_eq_getD default]
  exact List.getElem_mem sh.2.2.1

theorem closing {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record)
    (splits : Splits) (imports : ImportMatrix.Record) (constants : List ConstantSourceMatrix.Record) (r : ScalarPayloadMatrix.Record)
    (checked : ScalarPayloadMatrix.check matrix body tables splits imports constants r = true)
    (kind : Nat) (kb : kind < 4) (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) :
    E values (final constants kind (getRows r kind) (ScalarPayloadMatrix.start body kind)) = E values (finish body kind) ∧
      E values (count (getRows r kind)) = E values (size body kind) := by
  have all := MemoryEvidence.span_sound matrix _ _ _ (kind_checked matrix body tables splits imports constants r checked kind kb).2 values satisfied
  exact ⟨equality_sound values oneValue _ _ (all _ (by simp [closeGates])),
    equality_sound values oneValue _ _ (all _ (by simp [closeGates]))⟩

#print axioms active_boolean
#print axioms global_constant
#print axioms closing
end ZkBuild.ScalarPayloadRules
