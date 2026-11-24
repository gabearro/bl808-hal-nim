import ModuleProgramSound
import ModuleContextAuditIO
set_option autoImplicit false
namespace ZkBuild.ModuleContextSound
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix

def check (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record)
    (splits : Splits) (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record)
    (signature : SignatureMatrix.Record) (space : SignatureNamespace.Record) (imports : ImportMatrix.Record)
    (owned : List OwnedMatrix.Record) (frame : NameFrameMatrix.Record) (graph : NameGraphMatrix.Record)
    (source : NameSourceMatrix.Record) (constants : List ConstantSourceMatrix.Record)
    (scalar : ScalarPayloadMatrix.Record) (segments : SegmentPayloadMatrix.Record) (context : ModuleContextMatrix.Record) :=
  SegmentPayloadSound.check matrix body tables splits declaration indexed signature space imports owned frame graph source constants scalar segments &&
  ModuleContextMatrix.check matrix body tables owned space imports graph scalar segments constants context

theorem replay_sound {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record)
    (owned : List OwnedMatrix.Record) (space : SignatureNamespace.Record) (imports : ImportMatrix.Record)
    (graph : NameGraphMatrix.Record) (scalar : ScalarPayloadMatrix.Record) (segments : SegmentPayloadMatrix.Record)
    (constants : List ConstantSourceMatrix.Record) (context : ModuleContextMatrix.Record)
    (checked : ModuleContextMatrix.check matrix body tables owned space imports graph scalar segments constants context = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ result states, ModuleContextMatrix.replay matrix tables owned context = .ok (result,states) ∧
      ModuleContextMatrix.outputLinks tables context result = true ∧
      ∀ state ∈ states, (∀ c ∈ state.contracts, ModuleProgramSound.Facts values c) ∧
        ∀ r ∈ state.raw, Holds values r.value := by
  unfold ModuleContextMatrix.check at checked
  cases outcome : ModuleContextMatrix.replay matrix tables owned context with
  | error message => simp [outcome] at checked
  | ok pair =>
    rcases pair with ⟨result,states⟩
    have final := (Bool.and_eq_true_iff.mp checked).2
    rw [outcome] at final
    refine ⟨result,states,rfl,(Bool.and_eq_true_iff.mp final).1,?_⟩
    intro state member
    exact ModuleProgramSound.state matrix state
      (List.all_eq_true.mp (Bool.and_eq_true_iff.mp final).2 state member) values one satisfied

theorem start_binding {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record)
    (owned : List OwnedMatrix.Record) (space : SignatureNamespace.Record) (imports : ImportMatrix.Record)
    (graph : NameGraphMatrix.Record) (scalar : ScalarPayloadMatrix.Record) (segments : SegmentPayloadMatrix.Record)
    (constants : List ConstantSourceMatrix.Record) (context : ModuleContextMatrix.Record)
    (checked : ModuleContextMatrix.check matrix body tables owned space imports graph scalar segments constants context = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values) :
    E values (get body.envelope.outputs 32) = E values (ModuleContextMatrix.counter context 8) ∧
    E values (get body.envelope.outputs 33) = E values (ModuleContextMatrix.counter context 9) := by
  have span := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp checked).1).2
  have holds := MemoryEvidence.span_sound matrix context.startFirst context.startLast _ span values satisfied
  exact ⟨equality_sound values one _ _ (holds _ (by simp)),equality_sound values one _ _ (holds _ (by simp))⟩

#print axioms replay_sound
#print axioms start_binding
end ZkBuild.ModuleContextSound
