import DynamicTypingAuditIO
import ValidationSourceSound
import ReadOnlyInactive
set_option autoImplicit false
namespace ZkBuild.DynamicTypingSound
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix DynamicTypingMatrix
attribute [local instance] Ring.intCast Semiring.natCast

def StageFacts {F : Type} [Field F] (matrix : Shape) (splits : Splits)
    (tables : List ReadOnlyMatrix.Record) (signature : SignatureMatrix.Record)
    (values : Nat → F) (s : Stage) : Prop :=
  ∃ state, (DynamicTypingCheck.replay matrix splits tables signature s).run (SourceProgram.init s.program) = .ok ((),state) ∧
    SourceProgram.finished s.program state ∧ BodySourceTheorems.StateMeaning matrix [] splits values state

def TableFacts {F : Type} [Field F] (values : Nat → F) (r : ReadOnlyMatrix.Record) : Prop :=
  (∀ q ∈ r.queries, E values q.active = 1 → ∃ entry ∈ r.entries,
    E values entry.active = 1 ∧ E values entry.address = E values q.address ∧ E values entry.value = E values q.value) ∧
  (∀ q ∈ r.queries, E values q.active = 0 → E values q.address = 0 ∧ E values q.value = 0)

theorem stage {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (splits : Splits) (tables : List ReadOnlyMatrix.Record) (signature : SignatureMatrix.Record)
    (s : Stage) (accepted : DynamicTypingCheck.checkStage matrix splits tables signature s = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values) :
    StageFacts matrix splits tables signature values s := by
  unfold DynamicTypingCheck.checkStage at accepted
  cases h : (DynamicTypingCheck.replay matrix splits tables signature s).run (SourceProgram.init s.program) with
  | error e => simp [h] at accepted
  | ok pair =>
    rcases pair with ⟨result,state⟩
    cases result
    rw [h] at accepted
    exact ⟨state,h,_root_.of_decide_eq_true (Bool.and_eq_true_iff.mp accepted).1,
      SourceProgramSound.state matrix [] splits state (Bool.and_eq_true_iff.mp accepted).2 values one satisfied⟩

theorem table {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : ReadOnlyMatrix.Record) (accepted : ReadOnlyMatrix.check matrix r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values) : TableFacts values r := by
  obtain ⟨_,_,_,_,_,_,_,_,queries⟩ := ReadOnlySound.checked_membership matrix r accepted values one satisfied
  exact ⟨queries,fun q member inactive => ReadOnlyInactive.query_zero matrix r accepted values one satisfied q member inactive⟩

theorem checked {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (splits : Splits) (tables : List ReadOnlyMatrix.Record) (signature : SignatureMatrix.Record)
    (context : ModuleContextMatrix.Record) (locals : LocalRangeMatrix.Record)
    (events : ValidationEventMatrix.Record) (r : DynamicTypingMatrix.Record)
    (accepted : DynamicTypingCheck.check matrix splits tables signature context locals events r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values) :
    (∀ s ∈ r.stages, StageFacts matrix splits tables signature values s) ∧
    (∀ s ∈ r.stages, ∀ i ∈ s.banks, TableFacts values (tables.getD i default)) := by
  have parts := accepted
  simp only [DynamicTypingCheck.check,Bool.and_eq_true_iff] at parts
  constructor
  · intro s member
    exact stage matrix splits tables signature s (List.all_eq_true.mp parts.1.1.2 s member) values one satisfied
  · intro s member i bank
    exact table matrix _ (List.all_eq_true.mp (List.all_eq_true.mp parts.1.2 s member) i bank) values one satisfied

theorem selectors {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (splits : Splits) (tables : List ReadOnlyMatrix.Record) (signature : SignatureMatrix.Record)
    (context : ModuleContextMatrix.Record) (locals : LocalRangeMatrix.Record)
    (events : ValidationEventMatrix.Record) (r : DynamicTypingMatrix.Record)
    (accepted : DynamicTypingCheck.check matrix splits tables signature context locals events r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (row column : Nat) (rb : row < (DynamicTypingCheck.stage r 0).rows.length) (cb : column < 10) :
    E values (ValidationEventMatrix.f (ValidationEventMatrix.rowAt (DynamicTypingCheck.stage r 0).outputs row) column) =
      if E values (ValidationEventMatrix.f (eventAt (DynamicTypingCheck.stage r 0) row) 8) = (DynamicSelectors.codes.getD column 0 : F) then 1 else 0 :=
  DynamicSelectors.rows matrix (DynamicTypingCheck.stage r 0) (Bool.and_eq_true_iff.mp accepted).2 values one satisfied row column rb cb

#print axioms stage
#print axioms table
#print axioms checked
#print axioms selectors
end ZkBuild.DynamicTypingSound
