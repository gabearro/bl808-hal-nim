import ControlLookupSound
import ControlFrameMetadata
import FrameSignatureSource
set_option autoImplicit false
namespace ZkBuild.ControlSignatureHeads
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix OperandEvents
attribute [local instance] Ring.intCast Semiring.natCast

def index (token : Fin (2^36)) : Fin (2^32) := ⟨token.val/16,by have := token.isLt; omega⟩

theorem selected {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (splits : Splits) (tables : List ReadOnlyMatrix.Record)
    (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record) (signature : SignatureMatrix.Record) (space : SignatureNamespace.Record)
    (signatureChecked : SignatureSound.check matrix body tables splits declaration indexed signature space=true)
    (events : ValidationEventMatrix.Record) (instructions : InstructionStreamMatrix.Record) (r : StructuredMatrix.Record)
    (linked : StructuredCheck.links tables events instructions signature indexed declaration r=true)
    (lookups : ControlLookupCheck.check matrix tables indexed r=true)
    (i : Nat) (ib : i<(StructuredMatrix.stage r 4).rows.length)
    (checked : ControlTypeRowCheck.check matrix (ControlTypeRowCheck.record splits (StructuredMatrix.stage r 4) i)=true)
    (values : Nat → F) (one : values 0=1) (satisfied : Satisfied matrix values)
    (token : Fin (2^36))
    (image : ControlFrameMetadata.Image values (ControlTypeRowCheck.record splits (StructuredMatrix.stage r 4) i) token.val)
    (lookup : E values (ControlTypeRowCheck.lookup (ControlTypeRowCheck.record splits (StructuredMatrix.stage r 4) i))=1)
    (reset : E values (ControlTypeRowCheck.reset (ControlTypeRowCheck.record splits (StructuredMatrix.stage r 4) i))=1)
    (mode : token.val/4%4=0 ∨ token.val/4%4=1) :
    ∃ params results : Fin (2^32),
      E values (f (ControlTypeRowCheck.record splits (StructuredMatrix.stage r 4) i).after 7)=
        ((if token.val/4%4=0 then params.val else 0:Nat):F) ∧
      E values (f (ControlTypeRowCheck.record splits (StructuredMatrix.stage r 4) i).after 8)=(results.val:F) ∧
      CallHeadSource.Selected values body tables declaration indexed signature (decide (token.val/4%4=0)) (index token) params results := by
  let row := ControlTypeRowCheck.record splits (StructuredMatrix.stage r 4) i
  have query := ControlFrameMetadata.query matrix row checked values one satisfied token.val image lookup mode
  obtain ⟨entry,member,active,address,value⟩ := ControlLookupSound.origin matrix tables indexed r lookups values one satisfied i 0 ib (by decide) query.1
  have shape := linked
  simp only [StructuredCheck.links,StructuredCheck.entries,Bool.and_eq_true_iff] at shape
  have same : DynamicTypingMatrix.same
      (DynamicTypingCheck.entries (ControlLookupCheck.bank tables indexed r 0).entries)
      (DynamicTypingCheck.entries (SignatureMatrix.table tables signature 0).entries)=true := by
    simp only [ControlLookupCheck.bank,ControlLookupCheck.familyBank,BranchLookupCheck.bank,ite_true,
      show ¬(0:Nat)=4 from by decide,show ¬(0:Nat)=5 from by decide,ite_false,DynamicTypingCheck.entries]
    grind only
  obtain ⟨source,sm,sa,sk,sv⟩ := DynamicTypingSource.origin_member values _ _ same entry member
  have rc := checked
  simp only [ControlTypeRowCheck.check,Bool.and_eq_true_iff] at rc
  have rowShape := ControlTypeRowImages.links matrix row checked
  have interface := ControlTypeRowImages.interface matrix row checked values
  obtain ⟨params,results,pi,ri,_⟩ := ControlTypeRowImages.heads matrix row checked values one satisfied
  have single := ControlFrameMetadata.simple matrix row checked values one satisfied token.val image lookup
  have inactive : E values (ControlLookupCheck.control r i 3).active=0 := by
    have h := single.1
    rcases mode with mode | mode <;>
      simpa only [row,ControlTypeRowCheck.record,ControlLookupCheck.control,BranchMergeCheck.queryAt,
        mode,show ¬(0:Nat)=3 from by decide,show ¬(1:Nat)=3 from by decide,decide_false,flag,Bool.false_eq_true,ite_false] using h
  have zero := (ControlLookupSound.inactive matrix tables indexed r lookups values one satisfied i 3 ib (by decide) inactive).2
  have zero : E values row.singleton.value=0 := zero
  have chosen := ControlFrameMetadata.reset_heads matrix row checked values one satisfied token.val image reset
  refine ⟨params,results,?_,?_,?_⟩
  · rw [chosen.1,pi]
    by_cases typed : token.val/4%4=0 <;> simp [typed,Semiring.natCast_zero]
  · rw [chosen.2,ri,zero]; exact AddCommMonoid.add_zero _
  · exact FrameSignatureSource.selected matrix body splits tables declaration indexed signature space signatureChecked
      source sm _ rc.1.1.1.2 rowShape.2.2.2.2.2.2.2.1 rowShape.2.2.2.2.2.2.2.2.1 values one satisfied
      _ (index token) params results (sa.symm.trans active) (sk.symm.trans (address.trans query.2))
      (interface.heads.trans (value.symm.trans sv)) pi ri

#print axioms selected
end ZkBuild.ControlSignatureHeads
