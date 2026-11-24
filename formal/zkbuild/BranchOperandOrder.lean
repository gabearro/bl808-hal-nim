import BranchFrameMetadata
import BranchTypeTrace
import FrameCertificate
set_option autoImplicit false
namespace ZkBuild.BranchOperandOrder
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix OperandEvents
attribute [local instance] Ring.intCast Semiring.natCast

/-- The ordinal is the running pop count for loops and its reverse for other
    frames. Bounded natural sums rule out field wraparound and underflow. -/
theorem selected {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (r : BranchTypeRowCheck.Record) (checked : BranchTypeRowCheck.check matrix r=true)
    (values : Nat → F) (one : values 0=1) (satisfied : Satisfied matrix values)
    (token : Nat) (frame : BranchFrameMetadata.Image values r token)
    (state : BranchTypeState.State) (si : BranchTypeState.Image values (BranchTypeState.chosen r) state)
    (lengthBound : state.length<2^32) (popBound : state.pops<2^32)
    (active : E values (BranchTypeRowCheck.argument r)=1) :
    ∃ ordinal : Fin (2^32), E values (f r.after 38)=(ordinal.val:F) ∧
      if token%4=1 then ordinal.val=state.pops else ordinal.val+1+state.pops=state.length := by
  have facts := BranchTypeRowSound.meaning matrix r checked values one satisfied
  have loop := BranchTypeScalar.indicator values one r facts (f r.frame 1) (token%4) 1 19
    (by have := Nat.mod_lt token (by decide : 0<4); omega) (by decide) frame.kind
    (by simp [BranchTypeRowCheck.zeros,n,o])
  have select := facts.select (f r.after 19) (f r.after 27) (sub (sub (f r.after 26) o) (f r.after 27)) 38
    (by simp [BranchTypeRowCheck.selects])
  obtain ⟨_,ordinal,_,_,oi,_⟩ := BranchTypeRowImages.ranges matrix r checked values one satisfied
  have masked := facts.multiply (BranchTypeRowCheck.argument r) (f r.after 38) 40 (by simp [BranchTypeRowCheck.multiplies])
  have index : E values (f r.after 38)=(ordinal.val:F) := by rw [active,oi] at masked; grind only
  simp only [BranchTypeState.Image,BranchTypeState.chosen,List.map_cons,List.map_nil,
    BranchTypeState.field_zero,BranchTypeState.field_succ] at si
  rw [loop,si.2.2.1] at select
  simp only [eval_sub,o,eval_constant values one,Ring.intCast_one,si.1,si.2.2.1] at select
  refine ⟨ordinal,index,?_⟩
  by_cases isLoop : token%4=1
  · simp only [isLoop,ite_true,flag,decide_true] at select ⊢
    exact DeclarationLocations.natural_equal (F:=F) ordinal.val state.pops
      (by have := ordinal.isLt; omega) (by omega) (by grind only)
  · simp only [isLoop,ite_false,flag,decide_false] at select ⊢
    apply DeclarationLocations.natural_equal (F:=F) (ordinal.val+1+state.pops) state.length
      (by have := ordinal.isLt; omega) (by omega)
    simp only [Semiring.natCast_add,Semiring.natCast_one]
    grind only

def Complete {F : Type} [Field F] (values : Nat → F) (splits : Splits)
    (r : StructuredMatrix.Record) (rows : List Row) (ops : List Nat) : Prop :=
  ∃ data : Nat → BranchTypeData.Data, BranchTypeTrace.Facts values splits r rows ops data ∧
    ∀ i, i<rows.length →
      E values (BranchTypeRowCheck.argument (BranchTypeRowCheck.record splits r.scratch (StructuredMatrix.stage r 5) i))=1 →
      ∃ token : Fin (2^36), ∃ ordinal : Fin (2^32),
        FrameDescriptor.Image values (FrameRowCheck.record r.frames (StructuredMatrix.stage r 3) i) token.val ∧
        E values (f (BranchTypeRowCheck.record splits r.scratch (StructuredMatrix.stage r 5) i).after 38)=(ordinal.val:F) ∧
        if token.val%4=1 then ordinal.val=(BranchTypeTrace.chosen rows ops data i).pops
        else ordinal.val+1+(BranchTypeTrace.chosen rows ops data i).pops=(BranchTypeTrace.chosen rows ops data i).length

theorem sound {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (splits : Splits) (tables : List ReadOnlyMatrix.Record) (indexed : IndexedMatrix.Record)
    (statics : StaticCatalog) (events : ValidationEventMatrix.Record) (r : StructuredMatrix.Record)
    (checked : BranchTypeCertificate.check matrix splits tables statics events r=true)
    (lookupChecked : BranchLookupCheck.check matrix tables indexed r=true)
    (frames : FrameCertificate.check matrix events r=true)
    (values : Nat → F) (one : values 0=1) (satisfied : Satisfied matrix values)
    (rows : List Row) (ops : List Nat)
    (images : OperandTraceSound.Represents values (ValidationEventCheck.stage events 1) rows)
    (schedule : InstructionSemanticSound.Schedule values events rows ops) : Complete values splits r rows ops := by
  obtain ⟨data,facts⟩ := BranchTypeTrace.sound matrix splits tables indexed statics events r checked lookupChecked values one satisfied rows ops images schedule
  have parts := checked
  simp only [BranchTypeCertificate.check,Bool.and_eq_true_iff] at parts
  have links := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp parts.2).1
  have shape := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp parts.1.1.2).1).1
  have size : rows.length=(StructuredMatrix.stage r 5).rows.length := images.1.trans links.1
  have bound : rows.length<2^32 := by rw [size]; exact shape.2.1
  refine ⟨data,facts,?_⟩
  intro i ib active
  have rc := BranchTypeCertificate.row matrix splits tables statics events r checked values one satisfied rows ops images schedule i ib
  have fc := FrameCertificate.row matrix events r frames values rows ops images schedule i ib
  obtain ⟨token,fi⟩ := FrameDescriptor.sound matrix _ fc.1 values one satisfied
  have frame := BranchFrameMetadata.image matrix splits events r parts.2 i (by omega) fc.1 values token.val fi
  have bounds := BranchTypeTrace.chosen_bounds rows ops data i
  obtain ⟨ordinal,oi,order⟩ := selected matrix _ rc.1 values one satisfied token.val frame _ (facts i ib).2.2.2.1
    bounds.1.1 (by have := bounds.2.1; omega) active
  exact ⟨token,ordinal,fi,oi,order⟩

#print axioms selected
#print axioms sound
end ZkBuild.BranchOperandOrder
