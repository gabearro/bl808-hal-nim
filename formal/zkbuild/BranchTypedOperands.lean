import BranchLabelCarry
import BranchOperandOrder
import BranchTypeSemanticSound
set_option autoImplicit false
namespace ZkBuild.BranchTypedOperands
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix OperandEvents
attribute [local instance] Ring.intCast Semiring.natCast

def index (token length offset : Nat) := if token%4=1 then offset else length-1-offset

/-- Active branch operands use the exact source-label type at their position
    after the label, in the orientation selected by that label's frame. -/
def Complete {F : Type} [Field F] (values : Nat → F) (body : ModuleAuditIO.SourceEnvelope)
    (splits : Splits) (tables : List ReadOnlyMatrix.Record) (declaration : DeclarationMatrix.Record)
    (indexed : IndexedMatrix.Record) (signature : SignatureMatrix.Record)
    (r : StructuredMatrix.Record) (rows : List Row) (ops : List Nat) : Prop :=
  ∀ i, i<rows.length →
    E values (BranchTypeRowCheck.argument (BranchTypeRowCheck.record splits r.scratch (StructuredMatrix.stage r 5) i))=1 →
    ∃ j, j<i ∧ (rows.getD j default).kind=.labelCheck ∧ ops.getD j 0=14 ∧
      ∃ token : Fin (2^36), ∃ head : Fin (2^32), ∃ tags : List Nat,
        FrameDescriptor.Image values (FrameRowCheck.record r.frames (StructuredMatrix.stage r 3) j) token.val ∧
        BranchLabelLists.Image values tables indexed (BranchTypeRowCheck.record splits r.scratch (StructuredMatrix.stage r 5) j) head tags ∧
        BranchLabelLists.Origin values body tables declaration indexed signature token tags ∧
        i-j-1<tags.length ∧
        CallEvents.InputOk (tags.getD (index token.val tags.length (i-j-1)) 0) (rows.getD i default).valueType.val ∧
        ∀ k, j<k → k≤i → BranchTypePending.reset (rows.getD k default).kind=false ∧
          BranchTypeState.mark (rows.getD k default).kind (ops.getD k 0)=false

theorem sound {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (splits : Splits) (tables : List ReadOnlyMatrix.Record)
    (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record) (signature : SignatureMatrix.Record)
    (statics : StaticCatalog) (events : ValidationEventMatrix.Record) (r : StructuredMatrix.Record)
    (checked : BranchTypeCertificate.check matrix splits tables statics events r=true)
    (lookupChecked : BranchLookupCheck.check matrix tables indexed r=true)
    (frames : FrameCertificate.check matrix events r=true)
    (values : Nat → F) (one : values 0=1) (satisfied : Satisfied matrix values)
    (rows : List Row) (ops : List Nat)
    (images : OperandTraceSound.Represents values (ValidationEventCheck.stage events 1) rows)
    (schedule : InstructionSemanticSound.Schedule values events rows ops)
    (inputs : BranchOperandSource.Inputs values body splits tables declaration indexed signature r rows ops) :
    Complete values body splits tables declaration indexed signature r rows ops := by
  obtain ⟨data,facts,guards⟩ := BranchTypeSemanticSound.sound matrix splits tables indexed statics events r checked lookupChecked
    values one satisfied rows ops images schedule
  have masks := BranchTypePending.sound matrix splits tables statics events r checked values one satisfied rows ops images schedule
  have parts := checked
  simp only [BranchTypeCertificate.check,Bool.and_eq_true_iff] at parts
  have links := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp parts.2).1
  have shape := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp parts.1.1.2).1).1
  have size : rows.length=(StructuredMatrix.stage r 5).rows.length := images.1.trans links.1
  have bound : rows.length<2^32 := by rw [size]; exact shape.2.1
  intro i ib active
  obtain ⟨j,ji,kind,code,token,head,found,tags,frame,list,origin,_,oi,inside,ok,between⟩ := inputs i ib active
  have distance : j+(i-j)=i := by omega
  have marked : BranchTypeState.mark (rows.getD j default).kind (ops.getD j 0)=true := by
    simp only [BranchTypeState.mark,kind,code,and_self,decide_true]
  have carriedFrame := BranchLabelCarry.frame matrix events r frames values one satisfied rows ops images schedule j (i-j)
    (by omega) kind code (by simpa only [distance] using between)
  have carriedState := BranchLabelCarry.state rows ops data j (i-j) marked (by simpa only [distance] using between)
  rw [distance] at carriedFrame carriedState
  have rc := BranchTypeCertificate.row matrix splits tables statics events r checked values one satisfied rows ops images schedule i ib
  have fc := FrameCertificate.row matrix events r frames values rows ops images schedule i ib
  obtain ⟨current,ci⟩ := FrameDescriptor.sound matrix _ fc.1 values one satisfied
  have same : current=token := Fin.ext (DeclarationLocations.natural_equal (F:=F) current.val token.val
    (by have := current.isLt; omega) (by have := token.isLt; omega) (ci.value.symm.trans (carriedFrame.1.trans frame.value)))
  subst current
  have image := BranchFrameMetadata.image matrix splits events r parts.2 i (by omega) fc.1 values token.val ci
  have bounds := BranchTypeTrace.chosen_bounds rows ops data i
  obtain ⟨ordinal,ordinalImage,order⟩ := BranchOperandOrder.selected matrix _ rc.1 values one satisfied token.val image _
    (facts i ib).2.2.2.1 bounds.1.1 (by have := bounds.2.1; omega) active
  have ordinalSame : ordinal=found := Fin.ext (DeclarationLocations.natural_equal (F:=F) ordinal.val found.val
    (by have := ordinal.isLt; omega) (by have := found.isLt; omega) (ordinalImage.symm.trans oi))
  subst ordinal
  have length : (data j).size.val=tags.length := DeclarationLocations.natural_equal (F:=F) _ _
    (by have := (data j).size.isLt; omega) (by have := list.2.2.1; omega)
    ((facts j (by omega)).1.1.symm.trans list.2.1)
  have pop := (guards i ib).pop (BranchTypeGuards.flag_one _ ((masks i ib).argument.symm.trans active))
  have count : (BranchTypeTrace.chosen rows ops data i).pops=i-j-1 := by
    have := pop.2.2.2.2
    have := carriedState.2
    omega
  rw [carriedState.1,length,count] at order
  have inRange : i-j-1<tags.length := by
    split at order <;> omega
  have atIndex : found.val=index token.val tags.length (i-j-1) := by
    unfold index
    split <;> rename_i h
    · simpa only [h,ite_true] using order
    · simp only [h,ite_false] at order
      omega
  exact ⟨j,ji,kind,code,token,head,tags,frame,list,origin,inRange,(by simpa only [← atIndex] using ok),between⟩

#print axioms sound
end ZkBuild.BranchTypedOperands
