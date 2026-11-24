import BodySourceSound
import SourceProgramSound
set_option autoImplicit false
namespace ZkBuild.BodySourceTheorems
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix

def StateMeaning {F : Type} [Field F] (matrix : Shape) (tokens : Tokens) (splits : Splits)
    (values : Nat → F) (s : SourceProgram.State) : Prop :=
  ((∀ c ∈ s.base.contracts, ModuleProgramSound.Facts values c) ∧ ∀ r ∈ s.base.raw, Holds values r.value) ∧
    ∀ c ∈ s.contracts, SourceProgram.checkContract matrix tokens splits c = true

theorem code {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (splits : Splits) (tables : List ReadOnlyMatrix.Record)
    (space : SignatureNamespace.Record) (indexed : IndexedMatrix.Record) (locals : LocalDeclarationMatrix.Record)
    (r : BodySourceMatrix.Record) (checked : BodySourceSound.checkCode matrix body splits tables space indexed locals r = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ result state, BodySourceMatrix.replay matrix body.tokens splits tables body r = .ok (result,state) ∧
      SourceProgram.finished r.program state ∧ BodySourceSound.outputLinks tables r result = true ∧
      StateMeaning matrix body.tokens splits values state := by
  unfold BodySourceSound.checkCode at checked
  cases h : BodySourceMatrix.replay matrix body.tokens splits tables body r with
  | error message => simp [h] at checked
  | ok pair =>
    rcases pair with ⟨result,state⟩
    have rest := (Bool.and_eq_true_iff.mp checked).2
    rw [h] at rest
    have facts := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp rest).1)
    exact ⟨result,state,rfl,(_root_.of_decide_eq_true facts.1).1,facts.2,
      SourceProgramSound.state matrix body.tokens splits state (Bool.and_eq_true_iff.mp rest).2 values oneValue satisfied⟩

theorem declarations {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (splits : Splits) (tables : List ReadOnlyMatrix.Record)
    (space : SignatureNamespace.Record) (indexed : IndexedMatrix.Record) (context : ModuleContextMatrix.Record) (r : LocalDeclarationMatrix.Record)
    (checked : LocalDeclarationMatrix.check matrix body splits tables space indexed context r = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ result state, (LocalDeclarationMatrix.replayProgram matrix body.tokens splits tables r).run (SourceProgram.init r.program) = .ok (result,state) ∧
      SourceProgram.finished r.program state ∧ StateMeaning matrix body.tokens splits values state := by
  unfold LocalDeclarationMatrix.check at checked
  cases h : (LocalDeclarationMatrix.replayProgram matrix body.tokens splits tables r).run (SourceProgram.init r.program) with
  | error message => simp [h] at checked
  | ok pair =>
    rcases pair with ⟨result,state⟩
    have rest := (Bool.and_eq_true_iff.mp checked).2
    rw [h] at rest
    have shape := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp rest).1).1
    exact ⟨result,state,rfl,shape.1,
      SourceProgramSound.state matrix body.tokens splits state (Bool.and_eq_true_iff.mp rest).2 values oneValue satisfied⟩

theorem ranges {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (splits : Splits) (tables : List ReadOnlyMatrix.Record)
    (declarations : LocalDeclarationMatrix.Record) (r : LocalRangeMatrix.Record)
    (checked : LocalRangeMatrix.check matrix body splits tables declarations r = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ result state, (LocalRangeMatrix.replayProgram matrix body.tokens splits tables r).run (SourceProgram.init r.program) = .ok (result,state) ∧
      SourceProgram.finished r.program state ∧ StateMeaning matrix body.tokens splits values state := by
  unfold LocalRangeMatrix.check at checked
  cases h : (LocalRangeMatrix.replayProgram matrix body.tokens splits tables r).run (SourceProgram.init r.program) with
  | error message => simp [h] at checked
  | ok pair =>
    rcases pair with ⟨⟨data,tags⟩,state⟩
    have rest := (Bool.and_eq_true_iff.mp checked).2
    rw [h] at rest
    have shape := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp rest).1
    exact ⟨(data,tags),state,rfl,shape.1,
      SourceProgramSound.state matrix body.tokens splits state (Bool.and_eq_true_iff.mp rest).2 values oneValue satisfied⟩

#print axioms code
#print axioms declarations
#print axioms ranges
end ZkBuild.BodySourceTheorems
