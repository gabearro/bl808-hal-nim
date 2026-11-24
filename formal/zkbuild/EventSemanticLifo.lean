import EventSemanticSound
import ControlLifoTrace
import OperandRepresentationUnique
import ValidationSourceSound
set_option autoImplicit false
namespace ZkBuild.EventSemanticLifo
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix
attribute [local instance] Ring.intCast Semiring.natCast

def Trace (rows : List OperandEvents.Row) (ds : List Nat) (first : Nat) : Prop :=
  ds.length = rows.length ∧ ControlLifoTrace.frames rows rows.length = [] ∧
  (∀ i, i ≤ rows.length → ControlLifoTrace.Invariant rows ds first i) ∧
  ∀ i, i < rows.length →
    ControlLifoTrace.Context (ControlLifoTrace.frames rows i) (rows.getD i default) ∧
    OperandTraceSound.Transition rows i ∧
    ControlEvents.Spec (ControlLifoTrace.previousDepth ds i) (ds.getD i 0) (rows.getD i default)

theorem sound {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : ValidationEventMatrix.Record) (accepted : EventSemanticSound.check matrix r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ (rows : List OperandEvents.Row) (ds : List Nat) (first : Nat),
      OperandTraceSound.Represents values (ValidationEventCheck.stage r 1) rows ∧ Trace rows ds first := by
  have cc := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp accepted).1).1
  have op := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp cc).1).1
  obtain ⟨rows,ds,images,size,dsSize,steps,memory⟩ := EventSemanticSound.control matrix r accepted values one satisfied
  obtain ⟨functionRows,first,fnImages,fnSize,fb,fi,fnState,schedule⟩ := FunctionTraceSound.trace matrix r cc values one satisfied
  have same := OperandRepresentationUnique.trace values _ functionRows rows fnImages images
  subst functionRows
  obtain ⟨operandRows,opImages,opSteps,_,_⟩ := OperandCertificate.sound matrix r op values one satisfied
  have same := OperandRepresentationUnique.trace values _ operandRows rows opImages images
  subst operandRows
  have invariant := ControlLifoTrace.invariant rows ds first (fun i ib => (steps i ib).1) schedule memory
  have authentic := ControlLifoTrace.authenticated rows ds first (fun i ib => (steps i ib).1) schedule memory
  have closed := FunctionTraceSound.closed matrix _ (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp cc).1).2
    values one satisfied rows first size (fnState rows.length (by omega)).2.1
  have final := (invariant rows.length (by omega)).2.2.1 closed
  exact ⟨rows,ds,first,images,dsSize,final,invariant,fun i ib => ⟨authentic i ib,(opSteps i ib).1,(steps i ib).1⟩⟩

theorem source_bound {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (splits : Splits) (tables : List ReadOnlyMatrix.Record)
    (context : ModuleContextMatrix.Record) (code : BodySourceMatrix.Record)
    (catalog : InstructionDecodeMatrix.Catalog) (decoders : List InstructionDecodeMatrix.Record)
    (instructions : InstructionStreamMatrix.Record) (statics : StaticCatalog) (admission : LookupCatalog)
    (events : ValidationEventMatrix.Record)
    (sourceChecked : ModuleTables.check matrix body tables splits = true)
    (instructionsChecked : InstructionStreamCheck.check matrix body.tokens splits tables context code catalog decoders instructions = true)
    (catalogsChecked : ValidationEventAuditIO.catalogs statics admission = true)
    (eventsChecked : ValidationEventCheck.check matrix statics admission instructions events = true)
    (semanticChecked : EventSemanticSound.check matrix events = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ (message : List Sha256.Byte) (rows : List OperandEvents.Row) (ds : List Nat) (first : Nat),
      BinarySourceMatrix.Message values body.source.firstWire body.source.capacity body.source.length message ∧
      values 1 = (ShaHashSound.digestLimb message 0 : F) ∧ values 2 = (ShaHashSound.digestLimb message 1 : F) ∧
      (∀ other, BinarySourceMatrix.Message values body.source.firstWire body.source.capacity body.source.length other → other = message) ∧
      ValidationSourceSound.Decoders matrix body splits catalog decoders values message ∧
      ValidationSourceSound.Stream matrix body splits tables catalog decoders instructions values message ∧
      (ValidationSourceSound.projected events).map (List.map (E values)) = instructions.events.map (List.map (E values)) ∧
      OperandTraceSound.Represents values (ValidationEventCheck.stage events 1) rows ∧ Trace rows ds first := by
  obtain ⟨message,source,d0,d1,unique,_,decoded,stream,linked,_⟩ := ValidationSourceSound.checked
    matrix body splits tables context code catalog decoders instructions statics admission events
    sourceChecked instructionsChecked catalogsChecked eventsChecked values one satisfied
  obtain ⟨rows,ds,first,images,trace⟩ := sound matrix events semanticChecked values one satisfied
  exact ⟨message,rows,ds,first,source,d0,d1,unique,decoded,stream,linked,images,trace⟩

#print axioms sound
#print axioms source_bound
end ZkBuild.EventSemanticLifo
