import BranchFrameMetadata
import BranchLookupSound
import FrameSignatureSource
import FrameCertificate
set_option autoImplicit false
namespace ZkBuild.BranchFrameSource
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix OperandEvents
attribute [local instance] Ring.intCast Semiring.natCast

def index (token : Fin (2^36)) : Fin (2^32) := ⟨token.val/16,by have := token.isLt; omega⟩

/-- Source lists are selected through the actual merged branch query, not a
    parallel lookup or an assumed correspondence between metadata tables. -/
theorem selected {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (splits : Splits) (tables : List ReadOnlyMatrix.Record)
    (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record) (signature : SignatureMatrix.Record) (space : SignatureNamespace.Record)
    (signatureChecked : SignatureSound.check matrix body tables splits declaration indexed signature space=true)
    (events : ValidationEventMatrix.Record) (instructions : InstructionStreamMatrix.Record) (r : StructuredMatrix.Record)
    (linked : StructuredCheck.links tables events instructions signature indexed declaration r=true)
    (lookups : BranchLookupCheck.check matrix tables indexed r=true) (merged : BranchMergeCheck.checkStage matrix r=true)
    (i : Nat) (ib : i<(StructuredMatrix.stage r 5).rows.length)
    (checked : BranchTypeRowCheck.check matrix (BranchTypeRowCheck.record splits r.scratch (StructuredMatrix.stage r 5) i)=true)
    (values : Nat → F) (one : values 0=1) (satisfied : Satisfied matrix values)
    (token : Fin (2^36))
    (image : BranchFrameMetadata.Image values (BranchTypeRowCheck.record splits r.scratch (StructuredMatrix.stage r 5) i) token.val)
    (label : E values (f (BranchTypeRowCheck.record splits r.scratch (StructuredMatrix.stage r 5) i).flags 9)=1)
    (mode : token.val/4%4=0 ∨ token.val/4%4=1) :
    ∃ params results : Fin (2^32),
      E values (BranchTypeRowCheck.record splits r.scratch (StructuredMatrix.stage r 5) i).heads.low=(params.val:F) ∧
      E values (BranchTypeRowCheck.record splits r.scratch (StructuredMatrix.stage r 5) i).heads.high=(results.val:F) ∧
      E values (BranchTypeRowCheck.record splits r.scratch (StructuredMatrix.stage r 5) i).size.address=
        (BranchFrameMetadata.head token.val params.val results.val:F) ∧
      CallHeadSource.Selected values body tables declaration indexed signature (decide (token.val/4%4=0)) (index token) params results := by
  have query := BranchFrameMetadata.query matrix _ checked values one satisfied token.val image label mode
  obtain ⟨entry,member,active,address,value⟩ := BranchLookupSound.origin matrix tables indexed r lookups merged values one satisfied i 0 ib (by decide) query.1
  have shape := linked
  simp only [StructuredCheck.links,StructuredCheck.entries,Bool.and_eq_true_iff] at shape
  have same : DynamicTypingMatrix.same
      (DynamicTypingCheck.entries (BranchLookupCheck.bank tables indexed r 0).entries)
      (DynamicTypingCheck.entries (SignatureMatrix.table tables signature 0).entries)=true := by
    simp only [BranchLookupCheck.bank,ite_true,DynamicTypingCheck.entries]
    grind only
  obtain ⟨source,sm,sa,sk,sv⟩ := DynamicTypingSource.origin_member values _ _ same entry member
  have rc := checked
  simp only [BranchTypeRowCheck.check,Bool.and_eq_true_iff] at rc
  have rowShape := BranchTypeRowImages.links matrix _ checked
  have interface := BranchTypeRowImages.interface matrix _ checked values
  obtain ⟨params,results,pi,ri,_⟩ := BranchTypeRowImages.heads matrix _ checked values one satisfied
  have facts := BranchTypeRowSound.meaning matrix _ checked values one satisfied
  have single := facts.multiply
    (f (BranchTypeRowCheck.record splits r.scratch (StructuredMatrix.stage r 5) i).flags 9)
    (f (BranchTypeRowCheck.record splits r.scratch (StructuredMatrix.stage r 5) i).frame 7)
    16 (by simp [BranchTypeRowCheck.multiplies])
  have notSingle : E values (f (BranchTypeRowCheck.record splits r.scratch (StructuredMatrix.stage r 5) i).frame 7)=0 := by
    rw [image.singleton]
    rcases mode with mode | mode <;> simp [mode,flag]
  have inactive : E values (BranchMergeCheck.record r i 3).branch.active=0 := by
    have same := interface.singletonActive
    rw [single,label,notSingle] at same
    simpa only [BranchTypeRowCheck.record,BranchMergeCheck.record,BranchMergeCheck.queryAt,
      Nat.reduceMul,Semiring.mul_zero] using same
  have mc := List.all_eq_true.mp (List.all_eq_true.mp (Bool.and_eq_true_iff.mp merged).2 i (List.mem_range.mpr ib)) 3 (by simp)
  have zero := (BranchMergeSound.meaning matrix _ mc values one satisfied).branchZero inactive
  have head := BranchFrameMetadata.label_head matrix _ checked values one satisfied token.val params.val results.val image label mode pi ri zero.2
  refine ⟨params,results,pi,ri,head,?_⟩
  exact FrameSignatureSource.selected matrix body splits tables declaration indexed signature space signatureChecked
    source sm _ rc.1.1.1.1.2 rowShape.2.2.2.2.2.2.1 rowShape.2.2.2.2.2.2.2.1 values one satisfied
    _ (index token) params results (sa.symm.trans active) (sk.symm.trans (address.trans query.2))
    (interface.heads.trans (value.symm.trans sv)) pi ri

def Complete {F : Type} [Field F] (values : Nat → F) (body : ModuleAuditIO.SourceEnvelope)
    (splits : Splits) (tables : List ReadOnlyMatrix.Record) (declaration : DeclarationMatrix.Record)
    (indexed : IndexedMatrix.Record) (signature : SignatureMatrix.Record)
    (r : StructuredMatrix.Record) (rows : List Row) (ops : List Nat) : Prop :=
  ∀ i, i<rows.length → (rows.getD i default).kind=.labelCheck → ops.getD i 0=14 →
    ∃ token : Fin (2^36), FrameDescriptor.Image values (FrameRowCheck.record r.frames (StructuredMatrix.stage r 3) i) token.val ∧
      (token.val/4%4=0 ∨ token.val/4%4=1 →
        ∃ params results : Fin (2^32),
          E values (BranchTypeRowCheck.record splits r.scratch (StructuredMatrix.stage r 5) i).heads.low=(params.val:F) ∧
          E values (BranchTypeRowCheck.record splits r.scratch (StructuredMatrix.stage r 5) i).heads.high=(results.val:F) ∧
          E values (BranchTypeRowCheck.record splits r.scratch (StructuredMatrix.stage r 5) i).size.address=
            (BranchFrameMetadata.head token.val params.val results.val:F) ∧
          CallHeadSource.Selected values body tables declaration indexed signature (decide (token.val/4%4=0)) (index token) params results)

theorem sound {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (splits : Splits) (tables : List ReadOnlyMatrix.Record)
    (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record) (signature : SignatureMatrix.Record) (space : SignatureNamespace.Record)
    (signatureChecked : SignatureSound.check matrix body tables splits declaration indexed signature space=true)
    (events : ValidationEventMatrix.Record) (instructions : InstructionStreamMatrix.Record) (statics : StaticCatalog) (r : StructuredMatrix.Record)
    (linked : StructuredCheck.links tables events instructions signature indexed declaration r=true)
    (branchChecked : BranchTypeCertificate.check matrix splits tables statics events r=true)
    (lookups : BranchLookupCheck.check matrix tables indexed r=true)
    (frames : FrameCertificate.check matrix events r=true)
    (values : Nat → F) (one : values 0=1) (satisfied : Satisfied matrix values)
    (rows : List Row) (ops : List Nat)
    (images : OperandTraceSound.Represents values (ValidationEventCheck.stage events 1) rows)
    (schedule : InstructionSemanticSound.Schedule values events rows ops) :
    Complete values body splits tables declaration indexed signature r rows ops := by
  intro i ib kind code
  have parts := branchChecked
  simp only [BranchTypeCertificate.check,Bool.and_eq_true_iff] at parts
  have links := parts.2
  simp only [BranchTypeCertificate.linked,Bool.and_eq_true_iff,decide_eq_true_eq] at links
  have size := images.1
  have inside : i<(StructuredMatrix.stage r 5).rows.length := by omega
  have frame := FrameCertificate.row matrix events r frames values rows ops images schedule i ib
  obtain ⟨token,ti⟩ := FrameDescriptor.sound matrix _ frame.1 values one satisfied
  have branch := BranchTypeCertificate.row matrix splits tables statics events r branchChecked values one satisfied rows ops images schedule i ib
  have label : E values (f (BranchTypeRowCheck.record splits r.scratch (StructuredMatrix.stage r 5) i).flags 9)=1 := by
    simpa only [kind,code,flag,and_self,decide_true,ite_true] using branch.2.1.label
  refine ⟨token,ti,?_⟩
  intro mode
  exact selected matrix body splits tables declaration indexed signature space signatureChecked events instructions r linked
    lookups parts.1.2 i inside branch.1 values one satisfied token
    (BranchFrameMetadata.image matrix splits events r parts.2 i inside frame.1 values token.val ti) label mode

#print axioms selected
#print axioms sound
end ZkBuild.BranchFrameSource
