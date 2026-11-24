import CallEntrySource
import CallRootTrace
set_option autoImplicit false
namespace ZkBuild.CallRootSource
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix OperandEvents
attribute [local instance] Ring.intCast Semiring.natCast

theorem schedule {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (splits : Splits) (tables : List ReadOnlyMatrix.Record) (signature : SignatureMatrix.Record)
    (statics : StaticCatalog) (events : ValidationEventMatrix.Record) (typing : DynamicTypingMatrix.Record)
    (checked : CallCertificate.check matrix splits tables signature statics events typing = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (rows : List Row) (images : OperandTraceSound.Represents values (ValidationEventCheck.stage events 1) rows) :
    ∃ first, CallRootTrace.Schedule rows first := by
  have cc : ControlCertificate.check matrix events = true := by
    simp only [CallCertificate.check,VariableSemanticCheck.check,VariableCertificate.check,InstructionSemanticSound.check,
      InstructionCertificate.check,EventSemanticSound.check,Bool.and_eq_true_iff] at checked
    grind only
  obtain ⟨other,first,otherImages,_,_,_,_,fnSchedule⟩ := FunctionTraceSound.trace matrix events cc values one satisfied
  have same := OperandRepresentationUnique.trace values _ other rows otherImages images
  subst other
  exact ⟨first,fnSchedule⟩

def Roots {F : Type} [Field F] (values : Nat → F) (body : ModuleAuditIO.SourceEnvelope)
    (tables : List ReadOnlyMatrix.Record) (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record)
    (signature : SignatureMatrix.Record) (rows : List Row) (ops : List Nat) (data : Nat → CallTraceSound.Inputs) : Prop :=
  ∀ i, i < rows.length → (rows.getD i default).kind = .instructionBegin →
    ∃ start, ∃ caller : Fin (2^32), start < i ∧ (rows.getD start default).kind = .functionBegin ∧
      caller.val = (rows.getD i default).functionIndex ∧
      CallHeadSource.Selected values body tables declaration indexed signature false caller (data start).params (data start).results ∧
      (CallTraceSound.ready rows ops data i).root = (data start).results ∧
      (CallMode.tail (ops.getD i 0) = true → (data i).results = (data start).results)

theorem sound {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (splits : Splits) (tables : List ReadOnlyMatrix.Record)
    (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record) (signature : SignatureMatrix.Record) (space : SignatureNamespace.Record)
    (signatureChecked : SignatureSound.check matrix body tables splits declaration indexed signature space = true)
    (statics : StaticCatalog) (events : ValidationEventMatrix.Record) (typing : DynamicTypingMatrix.Record)
    (checked : CallCertificate.check matrix splits tables signature statics events typing = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (rows : List Row) (ops : List Nat) (images : OperandTraceSound.Represents values (ValidationEventCheck.stage events 1) rows)
    (data : Nat → CallTraceSound.Inputs) (facts : CallReadTrace.Facts values splits tables indexed signature typing rows ops data) :
    Roots values body tables declaration indexed signature rows ops data := by
  obtain ⟨first,fnSchedule⟩ := schedule matrix splits tables signature statics events typing checked values one satisfied rows images
  intro i ib kind
  obtain ⟨start,earlier,beginKind,sameIndex,root⟩ := CallRootTrace.instruction rows ops data first fnSchedule i ib kind
  have sb : start < rows.length := by omega
  obtain ⟨caller,callerIndex,selected⟩ := CallEntrySource.selected matrix body splits tables declaration indexed signature space signatureChecked
    statics events typing checked values one satisfied rows images start sb beginKind (data start) (facts start sb).1
  refine ⟨start,caller,earlier,beginKind,callerIndex.trans sameIndex,selected,root,?_⟩
  intro tail
  exact ((facts i ib).2.2.1.tailResults kind tail).trans root

#print axioms schedule
#print axioms sound
end ZkBuild.CallRootSource
