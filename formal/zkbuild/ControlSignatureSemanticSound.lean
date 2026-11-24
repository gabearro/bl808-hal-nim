import ControlSignatureLists
import ControlMemberLists
import ControlLookupMask
set_option autoImplicit false
namespace ZkBuild.ControlSignatureSemanticSound
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix OperandEvents
attribute [local instance] Ring.intCast Semiring.natCast

def Lists {F : Type} [Field F] (values : Nat → F) (body : ModuleAuditIO.SourceEnvelope)
    (splits : Splits) (tables : List ReadOnlyMatrix.Record) (declaration : DeclarationMatrix.Record)
    (indexed : IndexedMatrix.Record) (signature : SignatureMatrix.Record)
    (r : StructuredMatrix.Record) (rows : List Row) (ops : List Nat) : Prop :=
  ∀ i, i<rows.length → ControlLookupMask.active (rows.getD i default).kind (ops.getD i 0)=true →
    ∃ token : Fin (2^36), ∃ ph rh : Fin (2^32), ∃ params results : List Nat,
      FrameDescriptor.Image values (FrameRowCheck.record r.frames (StructuredMatrix.stage r 3) i) token.val ∧
      ControlLengthLists.Image values tables indexed (ControlTypeRowCheck.record splits (StructuredMatrix.stage r 4) i) ph rh params results ∧
      ControlSignatureLists.Origin values body tables declaration indexed signature token params results

def Members {F : Type} [Field F] (values : Nat → F) (splits : Splits) (tables : List ReadOnlyMatrix.Record)
    (indexed : IndexedMatrix.Record) (r : StructuredMatrix.Record) (rows : List Row) : Prop :=
  ∀ i, i<rows.length → ∀ comparison : Bool,
    E values (ControlLookupCheck.control r i (ControlMemberLists.family comparison)).active=1 →
    ∃ head ordinal : Fin (2^32), ∃ tags : List Nat,
      ControlMemberLists.Image values tables indexed (ControlTypeRowCheck.record splits (StructuredMatrix.stage r 4) i) comparison head ordinal tags

theorem sound {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (splits : Splits) (tables : List ReadOnlyMatrix.Record)
    (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record) (signature : SignatureMatrix.Record) (space : SignatureNamespace.Record)
    (signatureChecked : SignatureSound.check matrix body tables splits declaration indexed signature space=true)
    (events : ValidationEventMatrix.Record) (instructions : InstructionStreamMatrix.Record) (r : StructuredMatrix.Record)
    (linked : StructuredCheck.links tables events instructions signature indexed declaration r=true)
    (checked : ControlTypeCertificate.check matrix splits events r=true)
    (lookups : ControlLookupCheck.check matrix tables indexed r=true)
    (values : Nat → F) (one : values 0=1) (satisfied : Satisfied matrix values)
    (rows : List Row) (ops : List Nat)
    (images : OperandTraceSound.Represents values (ValidationEventCheck.stage events 1) rows)
    (schedule : InstructionSemanticSound.Schedule values events rows ops) :
    Lists values body splits tables declaration indexed signature r rows ops ∧ Members values splits tables indexed r rows := by
  have parts := checked
  simp only [ControlTypeCertificate.check,ControlTypeCertificate.linked,Bool.and_eq_true_iff,decide_eq_true_eq] at parts
  have size : rows.length=(StructuredMatrix.stage r 4).rows.length := images.1.trans parts.2.1.1
  have indexedChecked := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp signatureChecked).1).1
  constructor
  · intro i ib active
    have rc := ControlTypeCertificate.row matrix splits events r checked values rows ops images schedule i ib
    have masks := ControlTypeTrace.row_masks matrix splits events r checked values one satisfied rows ops images schedule i ib
    have mask := ControlLookupMask.images values _ _ _ (ControlTypeRowSound.meaning matrix _ rc.1 values one satisfied) masks.1 masks.2.2
    have lookup : E values (ControlTypeRowCheck.lookup (ControlTypeRowCheck.record splits (StructuredMatrix.stage r 4) i))=1 := by
      simpa only [active,flag,ite_true] using mask.1
    obtain ⟨token,ti⟩ := FrameDescriptor.sound matrix _ rc.2.2.1 values one satisfied
    have frameImage := ControlFrameMetadata.image matrix _ _ rc.2.2.1 values one _ rc.2.1 token.val ti
    obtain ⟨ph,rh,params,results,list,origin⟩ := ControlSignatureLists.selected matrix body splits tables declaration indexed signature space signatureChecked
      events instructions r linked lookups i (by omega) rc.1 values one satisfied token frameImage lookup (mask.2 active)
    exact ⟨token,ph,rh,params,results,ti,list,origin⟩
  · intro i ib comparison active
    have rc := ControlTypeCertificate.row matrix splits events r checked values rows ops images schedule i ib
    exact ControlMemberLists.selected matrix body tables splits declaration indexed indexedChecked r lookups i (by omega) rc.1 values one satisfied comparison active

#print axioms sound
end ZkBuild.ControlSignatureSemanticSound
