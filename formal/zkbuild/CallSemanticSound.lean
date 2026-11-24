import CallGuardSound
set_option autoImplicit false
namespace ZkBuild.CallSemanticSound
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix OperandEvents
attribute [local instance] Ring.intCast Semiring.natCast

def Trace {F : Type} [Field F] (values : Nat → F) (splits : Splits) (tables : List ReadOnlyMatrix.Record)
    (signature : SignatureMatrix.Record) (typing : DynamicTypingMatrix.Record) (rows : List Row) (ops : List Nat) : Prop :=
  ∃ data : Nat → CallTraceSound.Inputs, ∀ i, i < rows.length →
    let r := CallRowCheck.record splits tables signature (DynamicTypingCheck.stage typing 3) i
    CallTraceSound.DataImage values r (data i) ∧
    CallState.Image values r.before (CallTraceSound.state rows ops data i) ∧
    CallState.Image values (CallState.ready r) (CallTraceSound.ready rows ops data i) ∧
    CallState.Image values (CallState.after r) (CallTraceSound.state rows ops data (i+1)) ∧
    CallState.Masks values r (CallTraceSound.ready rows ops data i) (rows.getD i default).kind (ops.getD i 0) ∧
    CallGuardSound.Spec (CallTraceSound.ready rows ops data i) (rows.getD i default).kind (ops.getD i 0)
      (rows.getD i default).valueType (data i).tag ∧
    CallGuardSound.StartSpec values r (CallTraceSound.ready rows ops data i) (rows.getD i default).kind (ops.getD i 0) (data i).results

theorem sound {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (splits : Splits) (tables : List ReadOnlyMatrix.Record) (signature : SignatureMatrix.Record)
    (statics : StaticCatalog) (events : ValidationEventMatrix.Record) (typing : DynamicTypingMatrix.Record)
    (accepted : CallCertificate.check matrix splits tables signature statics events typing = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (rows : List Row) (ops : List Nat) (images : OperandTraceSound.Represents values (ValidationEventCheck.stage events 1) rows)
    (schedule : InstructionSemanticSound.Schedule values events rows ops) :
    Trace values splits tables signature typing rows ops := by
  obtain ⟨data,steps⟩ := CallTraceSound.sound matrix splits tables signature statics events typing accepted values one satisfied rows ops images schedule
  refine ⟨data,?_⟩
  intro i ib
  obtain ⟨inputs,before,ready,after,masks⟩ := steps i ib
  have facts := CallCertificate.row matrix splits tables signature statics events typing accepted values one rows images i ib
  have ci : E values (f (CallRowCheck.record splits tables signature (DynamicTypingCheck.stage typing 3) i).row 8) = (ops.getD i 0 : F) :=
    facts.2.2.2.trans (schedule.opcode i ib).2.1
  exact ⟨inputs,before,ready,after,masks,
    CallGuardSound.guards matrix _ facts.1 values one satisfied _ facts.2.1 _ (schedule.opcode i ib).1 ci _ ready masks _ inputs.2.2.2.1
      _ _ facts.2.2.1 inputs.2.2.1,
    CallGuardSound.start matrix _ facts.1 values one satisfied _ facts.2.1 _ (schedule.opcode i ib).1 ci _ ready _ inputs.2.1⟩

#print axioms sound
end ZkBuild.CallSemanticSound
