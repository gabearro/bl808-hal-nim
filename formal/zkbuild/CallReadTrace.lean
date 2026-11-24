import CallReadSound
import SignatureSound
set_option autoImplicit false
namespace ZkBuild.CallReadTrace
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix OperandEvents
attribute [local instance] Ring.intCast Semiring.natCast

def Facts {F : Type} [Field F] (values : Nat → F) (splits : Splits) (tables : List ReadOnlyMatrix.Record)
    (indexed : IndexedMatrix.Record) (signature : SignatureMatrix.Record) (typing : DynamicTypingMatrix.Record)
    (rows : List Row) (ops : List Nat) (data : Nat → CallTraceSound.Inputs) : Prop :=
  ∀ i, i < rows.length →
    let r := CallRowCheck.record splits tables signature (DynamicTypingCheck.stage typing 3) i
    CallTraceSound.DataImage values r (data i) ∧
    CallGuardSound.Spec (CallTraceSound.ready rows ops data i) (rows.getD i default).kind (ops.getD i 0)
      (rows.getD i default).valueType (data i).tag ∧
    CallGuardSound.StartSpec values r (CallTraceSound.ready rows ops data i) (rows.getD i default).kind (ops.getD i 0) (data i).results ∧
    CallReadSound.Reads (IndexedNodeTable.table values (IndexedLengths.banks tables indexed).nodes)
      (CallTraceSound.ready rows ops data i) (rows.getD i default).kind (ops.getD i 0) (data i)

theorem sound {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (splits : Splits) (tables : List ReadOnlyMatrix.Record)
    (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record) (signature : SignatureMatrix.Record) (space : SignatureNamespace.Record)
    (signatureChecked : SignatureSound.check matrix body tables splits declaration indexed signature space = true)
    (statics : StaticCatalog) (events : ValidationEventMatrix.Record) (typing : DynamicTypingMatrix.Record)
    (accepted : CallCertificate.check matrix splits tables signature statics events typing = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (rows : List Row) (ops : List Nat) (images : OperandTraceSound.Represents values (ValidationEventCheck.stage events 1) rows)
    (schedule : InstructionSemanticSound.Schedule values events rows ops) :
    ∃ data, Facts values splits tables indexed signature typing rows ops data := by
  have sig := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp signatureChecked).1)
  have declarationCheck := (Bool.and_eq_true_iff.mp sig.1).1
  have sourceCheck := (Bool.and_eq_true_iff.mp declarationCheck).1
  have splitChecks := (Bool.and_eq_true_iff.mp sourceCheck).2
  have tableChecks := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp sourceCheck).1).2
  have banks := IndexedLengths.checked_banks (F := F) matrix body tables splits declaration indexed sig.1
  have origins := CallNodeSource.origins matrix splits tables declaration indexed signature sig.2 tableChecks splitChecks values one satisfied
  obtain ⟨data,steps⟩ := CallSemanticSound.sound matrix splits tables signature statics events typing accepted values one satisfied rows ops images schedule
  refine ⟨data,?_⟩
  intro i ib
  obtain ⟨di,_,ready,_,masks,guards,start⟩ := steps i ib
  have rowCheck := (CallCertificate.row matrix splits tables signature statics events typing accepted values one rows images i ib).1
  have parts := accepted
  simp only [CallCertificate.check,Bool.and_eq_true_iff] at parts
  have shape := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp parts.1.2).1
  have links := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp parts.2).1
  have size : rows.length = (DynamicTypingCheck.stage typing 3).rows.length := images.1.trans links.1
  have member : (CallRowCheck.record splits tables signature (DynamicTypingCheck.stage typing 3) i).node ∈ signature.extraOperands := by
    change signature.extraOperands.getD i default ∈ signature.extraOperands
    rw [← List.getElem_eq_getD default]
    exact List.getElem_mem (by rw [shape.2.2.2.2.1,← size]; exact ib)
  have reads := CallReadSound.query matrix _ rowCheck values one satisfied _ _ _ ready masks
  refine ⟨di,guards,start,?_,?_⟩
  · intro enabled
    exact CallReadSound.consume matrix splits tables declaration indexed signature sig.2 tableChecks banks.nodesChecked values one satisfied
      origins _ member (reads.1 enabled).1 _ (reads.1 enabled).2 _ _ di.2.2.2.2.2
  · intro enabled
    exact CallReadSound.consume matrix splits tables declaration indexed signature sig.2 tableChecks banks.nodesChecked values one satisfied
      origins _ member (reads.2 enabled).1 _ (reads.2 enabled).2 _ _ di.2.2.2.2.2

#print axioms sound
end ZkBuild.CallReadTrace
