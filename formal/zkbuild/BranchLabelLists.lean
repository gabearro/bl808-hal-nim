import BranchFrameSource
import BranchSimpleLists
set_option autoImplicit false
namespace ZkBuild.BranchLabelLists
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix OperandEvents
attribute [local instance] Ring.intCast Semiring.natCast

def Origin {F : Type} [Field F] (values : Nat → F) (body : ModuleAuditIO.SourceEnvelope)
    (tables : List ReadOnlyMatrix.Record) (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record)
    (signature : SignatureMatrix.Record) (token : Fin (2^36)) (tags : List Nat) : Prop :=
  if token.val/4%4=0 ∨ token.val/4%4=1 then
    ∃ paramsHead resultsHead : Fin (2^32), ∃ params results : List Nat,
      CallHeadSource.Selected values body tables declaration indexed signature
        (decide (token.val/4%4=0)) (BranchFrameSource.index token) paramsHead resultsHead ∧
      SignatureLists.Represents (IndexedNodeTable.table values (IndexedLengths.banks tables indexed).nodes) paramsHead.val params ∧
      SignatureLists.Represents (IndexedNodeTable.table values (IndexedLengths.banks tables indexed).nodes) resultsHead.val results ∧
      tags=(if token.val%4=1 then (if token.val/4%4=0 then params else []) else results)
  else tags=BranchSimpleLists.types token.val ∧ (token.val/4%4=3 → token.val/16<7)

def Image {F : Type} [Field F] (values : Nat → F) (tables : List ReadOnlyMatrix.Record)
    (indexed : IndexedMatrix.Record) (row : BranchTypeRowCheck.Record) (head : Fin (2^32)) (tags : List Nat) : Prop :=
  E values row.size.address=(head.val:F) ∧ E values row.size.value=(tags.length:F) ∧ tags.length<2^32 ∧
    SignatureLists.Represents (IndexedNodeTable.table values (IndexedLengths.banks tables indexed).nodes) head.val tags

/-- The length lookup supplies a complete list at the selected label head. -/
theorem decoded {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record) (splits : Splits)
    (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record)
    (accepted : IndexedSound.check matrix body tables splits declaration indexed=true)
    (r : StructuredMatrix.Record) (lookups : BranchLookupCheck.check matrix tables indexed r=true)
    (merged : BranchMergeCheck.checkStage matrix r=true)
    (i : Nat) (ib : i<(StructuredMatrix.stage r 5).rows.length)
    (checked : BranchTypeRowCheck.check matrix (BranchTypeRowCheck.record splits r.scratch (StructuredMatrix.stage r 5) i)=true)
    (values : Nat → F) (one : values 0=1) (satisfied : Satisfied matrix values)
    (label : E values (f (BranchTypeRowCheck.record splits r.scratch (StructuredMatrix.stage r 5) i).flags 9)=1) :
    ∃ head : Fin (2^32), ∃ tags : List Nat,
      Image values tables indexed (BranchTypeRowCheck.record splits r.scratch (StructuredMatrix.stage r 5) i) head tags := by
  have active := (BranchTypeRowImages.interface matrix _ checked values).sizeActive.trans label
  obtain ⟨entry,member,ea,ek,ev⟩ := BranchLookupSound.origin matrix tables indexed r lookups merged values one satisfied i 1 ib (by decide) active
  have parts := (Bool.and_eq_true_iff.mp accepted).2
  simp only [IndexedMatrix.check,Bool.and_eq_true_iff] at parts
  have links : IndexedMatrix.checkLinks tables declaration indexed=true := by grind only
  have entries := (_root_.of_decide_eq_true (Bool.and_eq_true_iff.mp links).1).2.2.1
  change entry ∈ (IndexedMatrix.table tables indexed 0).entries at member
  rw [entries] at member
  obtain ⟨source,sm,rfl⟩ := List.mem_map.mp member
  obtain ⟨head,len,tags,hb,lb,hi,li,rep,count,_⟩ := IndexedLengths.checked_lengths matrix body tables splits declaration indexed accepted values one satisfied source sm ea
  exact ⟨⟨head,hb⟩,tags,ek.symm.trans hi,by rw [count]; exact ev.symm.trans li,by omega,rep⟩

theorem identify {F : Type} [Field F] [IsCharP F scalarModulus]
    (values : Nat → F) (tables : List ReadOnlyMatrix.Record) (indexed : IndexedMatrix.Record)
    (row : BranchTypeRowCheck.Record) (head other : Fin (2^32)) (tags expected : List Nat)
    (image : Image values tables indexed row head tags)
    (address : E values row.size.address=(other.val:F))
    (rep : SignatureLists.Represents (IndexedNodeTable.table values (IndexedLengths.banks tables indexed).nodes) other.val expected) :
    head=other ∧ tags=expected := by
  have same := DeclarationLocations.natural_equal (F:=F) head.val other.val
    (by have := head.isLt; omega) (by have := other.isLt; omega) (image.1.symm.trans address)
  have eq : head=other := Fin.ext same
  rw [← eq] at rep
  exact ⟨eq,SignatureLists.represents_unique _ _ tags expected image.2.2.2 rep⟩

/-- All four descriptor modes select lists; the mode no longer leaves an
    implication whose premise can exclude empty or singleton blocks. -/
theorem selected {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (splits : Splits) (tables : List ReadOnlyMatrix.Record)
    (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record) (signature : SignatureMatrix.Record) (space : SignatureNamespace.Record)
    (signatureChecked : SignatureSound.check matrix body tables splits declaration indexed signature space=true)
    (events : ValidationEventMatrix.Record) (instructions : InstructionStreamMatrix.Record) (r : StructuredMatrix.Record)
    (linked : StructuredCheck.links tables events instructions signature indexed declaration r=true)
    (lookups : BranchLookupCheck.check matrix tables indexed r=true) (merged : BranchMergeCheck.checkStage matrix r=true)
    (i : Nat) (ib : i<(StructuredMatrix.stage r 5).rows.length)
    (checked : BranchTypeRowCheck.check matrix (BranchTypeRowCheck.record splits r.scratch (StructuredMatrix.stage r 5) i)=true)
    (values : Nat → F) (one : values 0=1) (satisfied : Satisfied matrix values) (token : Fin (2^36))
    (image : BranchFrameMetadata.Image values (BranchTypeRowCheck.record splits r.scratch (StructuredMatrix.stage r 5) i) token.val)
    (label : E values (f (BranchTypeRowCheck.record splits r.scratch (StructuredMatrix.stage r 5) i).flags 9)=1) :
    ∃ head : Fin (2^32), ∃ tags : List Nat,
      Image values tables indexed (BranchTypeRowCheck.record splits r.scratch (StructuredMatrix.stage r 5) i) head tags ∧
      Origin values body tables declaration indexed signature token tags := by
  have indexedChecked := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp signatureChecked).1).1
  obtain ⟨head,tags,list⟩ := decoded matrix body tables splits declaration indexed indexedChecked r lookups merged i ib checked values one satisfied label
  refine ⟨head,tags,list,?_⟩
  by_cases mode : token.val/4%4=0 ∨ token.val/4%4=1
  · obtain ⟨ph,rh,_,_,hi,selected⟩ := BranchFrameSource.selected matrix body splits tables declaration indexed signature space signatureChecked
      events instructions r linked lookups merged i ib checked values one satisfied token image label mode
    have copy := selected
    obtain ⟨_,_,_,_,_,_,_,params,results,_,_,_,_,_,_,_,pr,rr,_⟩ := copy
    have hb : BranchFrameMetadata.head token.val ph.val rh.val<2^32 := by
      have := ph.isLt; have := rh.isLt
      unfold BranchFrameMetadata.head
      split
      · split <;> omega
      · exact rh.isLt
    let chosen : Fin (2^32) := ⟨BranchFrameMetadata.head token.val ph.val rh.val,hb⟩
    let expected := if token.val%4=1 then (if token.val/4%4=0 then params else []) else results
    have rep : SignatureLists.Represents (IndexedNodeTable.table values (IndexedLengths.banks tables indexed).nodes) chosen.val expected := by
      dsimp only [chosen,expected,BranchFrameMetadata.head]
      split
      · split
        · exact pr
        · exact .nil
      · exact rr
    have same := identify values tables indexed _ head chosen tags expected list hi rep
    simp only [Origin,mode,ite_true]
    exact ⟨ph,rh,params,results,selected,pr,rr,same.2⟩
  · have simple : token.val/4%4=2 ∨ token.val/4%4=3 := by omega
    obtain ⟨other,hi,rep,bound⟩ := BranchSimpleLists.selected matrix body tables splits declaration indexed indexedChecked r lookups merged i ib checked
      values one satisfied token image label simple
    have same := identify values tables indexed _ head other tags (BranchSimpleLists.types token.val) list hi rep
    simpa only [Origin,mode,ite_false] using And.intro same.2 bound

def Complete {F : Type} [Field F] (values : Nat → F) (body : ModuleAuditIO.SourceEnvelope)
    (splits : Splits) (tables : List ReadOnlyMatrix.Record) (declaration : DeclarationMatrix.Record)
    (indexed : IndexedMatrix.Record) (signature : SignatureMatrix.Record)
    (r : StructuredMatrix.Record) (rows : List Row) (ops : List Nat) : Prop :=
  ∀ i, i<rows.length → (rows.getD i default).kind=.labelCheck → ops.getD i 0=14 →
    ∃ token : Fin (2^36), ∃ head : Fin (2^32), ∃ tags : List Nat,
      FrameDescriptor.Image values (FrameRowCheck.record r.frames (StructuredMatrix.stage r 3) i) token.val ∧
      Image values tables indexed (BranchTypeRowCheck.record splits r.scratch (StructuredMatrix.stage r 5) i) head tags ∧
      Origin values body tables declaration indexed signature token tags

theorem sound {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (splits : Splits) (tables : List ReadOnlyMatrix.Record)
    (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record) (signature : SignatureMatrix.Record) (space : SignatureNamespace.Record)
    (signatureChecked : SignatureSound.check matrix body tables splits declaration indexed signature space=true)
    (events : ValidationEventMatrix.Record) (instructions : InstructionStreamMatrix.Record) (statics : StaticCatalog) (r : StructuredMatrix.Record)
    (linked : StructuredCheck.links tables events instructions signature indexed declaration r=true)
    (branchChecked : BranchTypeCertificate.check matrix splits tables statics events r=true)
    (lookups : BranchLookupCheck.check matrix tables indexed r=true) (frames : FrameCertificate.check matrix events r=true)
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
  obtain ⟨head,tags,li,origin⟩ := selected matrix body splits tables declaration indexed signature space signatureChecked
    events instructions r linked lookups parts.1.2 i inside branch.1 values one satisfied token
    (BranchFrameMetadata.image matrix splits events r parts.2 i inside frame.1 values token.val ti) label
  exact ⟨token,head,tags,ti,li,origin⟩

#print axioms sound
#print axioms decoded
#print axioms identify
#print axioms selected
end ZkBuild.BranchLabelLists
