import StructuredAuditIO
import DynamicTypingSource
set_option autoImplicit false
namespace ZkBuild.StructuredSound
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix DynamicTypingMatrix
attribute [local instance] Ring.intCast Semiring.natCast
def StageFacts {F : Type} [Field F] (matrix : Shape) (splits : Splits) (tables : List ReadOnlyMatrix.Record)
    (indexed : IndexedMatrix.Record) (r : StructuredMatrix.Record) (values : Nat → F) (s : Stage) : Prop :=
  ∃ state, (StructuredCheck.replay matrix splits tables indexed r s).run (SourceProgram.init s.program) = .ok ((),state) ∧
    SourceProgram.finished s.program state ∧ BodySourceTheorems.StateMeaning matrix [] splits values state
theorem stage {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (splits : Splits) (tables : List ReadOnlyMatrix.Record) (indexed : IndexedMatrix.Record)
    (r : StructuredMatrix.Record) (s : Stage)
    (accepted : StructuredCheck.checkStage matrix splits tables indexed r s = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values) :
    StageFacts matrix splits tables indexed r values s := by
  unfold StructuredCheck.checkStage at accepted
  cases h : (StructuredCheck.replay matrix splits tables indexed r s).run (SourceProgram.init s.program) with
  | error e => simp [h] at accepted
  | ok pair =>
    rcases pair with ⟨result,state⟩
    cases result
    rw [h] at accepted
    exact ⟨state,h,_root_.of_decide_eq_true (Bool.and_eq_true_iff.mp accepted).1,
      SourceProgramSound.state matrix [] splits state (Bool.and_eq_true_iff.mp accepted).2 values one satisfied⟩
theorem checked {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (splits : Splits) (tables : List ReadOnlyMatrix.Record)
    (events : ValidationEventMatrix.Record) (instructions : InstructionStreamMatrix.Record)
    (signature : SignatureMatrix.Record) (indexed : IndexedMatrix.Record) (declaration : DeclarationMatrix.Record)
    (r : StructuredMatrix.Record)
    (accepted : StructuredCheck.check matrix splits tables events instructions signature indexed declaration r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values) :
    (∀ s ∈ r.stages, StageFacts matrix splits tables indexed r values s) ∧
    (∀ s ∈ r.stages, ∀ i ∈ s.banks, DynamicTypingSound.TableFacts values (tables.getD i default)) ∧
    ValidationEventSound.MemoryFacts values r.frames ∧ ValidationEventSound.MemoryFacts values r.scratch := by
  have parts := accepted
  simp only [StructuredCheck.check,Bool.and_eq_true_iff] at parts
  rcases parts with ⟨⟨⟨⟨_,stages⟩,banks⟩,frames⟩,scratch⟩
  refine ⟨?_,?_,?_,?_⟩
  · intro s member
    exact stage matrix splits tables indexed r s (List.all_eq_true.mp stages s member) values one satisfied
  · intro s member i bank
    exact DynamicTypingSound.table matrix _ (List.all_eq_true.mp (List.all_eq_true.mp banks s member) i bank) values one satisfied
  · exact MemoryEmbedded.checked_memory matrix r.frames frames values one satisfied
  · exact MemoryEmbedded.checked_memory matrix r.scratch scratch values one satisfied
#print axioms stage
#print axioms checked
end ZkBuild.StructuredSound
