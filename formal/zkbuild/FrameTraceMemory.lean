import FrameTokenStack
import FrameTargetSound
set_option autoImplicit false
namespace ZkBuild.FrameTraceMemory
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix OperandEvents FrameRowCheck
attribute [local instance] Ring.intCast Semiring.natCast

theorem bool_equal {F : Type} [Field F] (a b : Bool) (same : (a.toNat:F)=(b.toNat:F)) : a=b := by
  cases a <;> cases b <;> try rfl
  all_goals simp only [Bool.toNat_true,Bool.toNat_false,Semiring.natCast_zero,Semiring.natCast_one] at same
  · exact False.elim (Field.zero_ne_one same)
  · exact False.elim (Field.zero_ne_one same.symm)

structure Facts {F : Type} [Field F]
    (values : Nat → F) (r : StructuredMatrix.Record) (rows : List Row) (entries : List MemoryTrace.Entry) : Prop where
  length : entries.length=2*rows.length
  represented : ShaProgram.Related (MemoryPacking.Represents values) (r.frames.inputs.map MemoryEvidence.AccessRef.fields) entries
  reads : MemoryTrace.Reads (fun _ => none) entries
  bounds : ∀ e ∈ entries, e.address<2^64 ∧ e.value<2^36
  projection : FrameTokenStack.Projection rows entries
  targets : ∀ i, i<rows.length → (FrameTokenStack.entry entries (2*i)).active=true →
    ∃ slot : Nat, slot<ControlDepthTrace.depth rows i ∧
      (FrameTokenStack.entry entries (2*i)).address=(rows.getD i default).functionIndex*bound+slot

theorem sound {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (splits : Splits) (tables : List ReadOnlyMatrix.Record)
    (events : ValidationEventMatrix.Record) (r : StructuredMatrix.Record)
    (checked : FrameCertificate.check matrix events r=true)
    (depthsChecked : FrameDepthCheck.checkStage matrix splits tables r=true)
    (controls : ControlCertificate.check matrix events=true)
    (values : Nat → F) (one : values 0=1) (satisfied : Satisfied matrix values)
    (rows : List Row) (ops : List Nat)
    (images : OperandTraceSound.Represents values (ValidationEventCheck.stage events 1) rows)
    (schedule : InstructionSemanticSound.Schedule values events rows ops) :
    ∃ entries, Facts values r rows entries := by
  have depths := ControlDepthTrace.sound matrix events controls values one satisfied rows images
  have linked := (Bool.and_eq_true_iff.mp checked).2
  have shape := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp linked).1
  have size : rows.length=(StructuredMatrix.stage r 3).rows.length := images.1.trans shape.1
  have parts := (Bool.and_eq_true_iff.mp checked).1
  simp only [FrameRowCheck.checkStage,Bool.and_eq_true_iff,decide_eq_true_eq] at parts
  have ms := parts.1.1.1.2.2.2.2.2.2.1
  obtain ⟨entries,_,related,_,_,reads,bounded,_,_⟩ := MemoryEmbedded.checked_memory matrix r.frames parts.1.1.2 values one satisfied
  have length : entries.length=2*rows.length := by
    have h := ShaProgram.related_length _ _ _ related
    simp only [List.length_map] at h
    omega
  have bounds : ∀ e ∈ entries, e.address<2^64 ∧ e.value<2^36 := by
    intro e em
    have h := bounded e em
    exact ⟨by simpa only [parts.1.1.1.2.2.2.2.2.2.2.1] using h.1,
      by simpa only [parts.1.1.1.2.2.2.2.2.2.2.2] using h.2.2⟩
  have boundAt (i : Nat) (ib : i<entries.length) := bounds (FrameTokenStack.entry entries i) (by
    rw [FrameTokenStack.entry,← List.getElem_eq_getD (h:=ib) MemoryPriorWrite.zero]; exact List.getElem_mem ib)
  have row := FrameCertificate.row matrix events r checked values rows ops images schedule
  have before := ControlDepthTrace.frame_before events r linked values one rows depths
  refine ⟨entries,length,related,reads,bounds,?_,?_⟩
  · intro i ib
    have rc := row i ib
    have faces := FrameRowImages.interface matrix _ rc.1 values
    simp only [List.map_cons,List.map_nil,List.cons.injEq,and_true] at faces
    have tag := FrameSelectors.tags values one _ _ _ rc.2
    have readRep := FrameMemorySound.represented_at values r.frames entries related (2*i) (by omega)
    have writeRep := FrameMemorySound.represented_at values r.frames entries related (2*i+1) (by omega)
    have wa : (FrameTokenStack.entry entries (2*i+1)).active = decide ((rows.getD i default).kind=.controlPush) := by
      apply bool_equal (F:=F)
      exact writeRep.1.symm.trans (faces.2.2.2.2.1.trans (tag.controlPush.trans (OperandMemorySound.flag_nat _)))
    have ww : (FrameTokenStack.entry entries (2*i+1)).write = decide ((rows.getD i default).kind=.controlPush) := by
      apply bool_equal (F:=F)
      exact writeRep.2.1.symm.trans (faces.2.2.2.2.2.1.trans (tag.controlPush.trans (OperandMemorySound.flag_nat _)))
    refine ⟨?_,wa,ww,?_⟩
    · apply bool_equal (F:=F) _ false
      have zero : E values (record r.frames (StructuredMatrix.stage r 3) i).read.write=0 := by
        simpa only [z,eval_constant values one,Ring.intCast_zero] using faces.2.1
      simpa only [FrameTokenStack.entry,Bool.toNat_false,Semiring.natCast_zero] using readRep.2.1.symm.trans zero
    · intro push
      have enabled : E values (f (record r.frames (StructuredMatrix.stage r 3) i).flags 4)=1 := by
        simpa only [push,decide_true,flag,ite_true] using tag.controlPush
      have addr := (FrameAccessSound.write_address matrix _ rc.1 values one satisfied
        (rows.getD i default).functionIndex (ControlDepthTrace.depth rows i) rc.2.functionIndex (before i (by omega)) enabled).2.2.1
      exact DeclarationLocations.natural_equal (F:=F) _ _ (boundAt (2*i+1) (by omega)).1
        (ControlAddressBounds.index_bound _ _ (images.2 i ib).2.1 (depths.bounded i (by omega)))
        (writeRep.2.2.1.symm.trans addr)
  · intro i ib active
    change (entries.getD (2*i) MemoryPriorWrite.zero).active=true at active
    have rc := row i ib
    have tag := FrameSelectors.tags values one _ _ _ rc.2
    have cats := FrameOpcodes.categories matrix _ rc.1 values one satisfied _ (schedule.opcode i ib).1 rc.2.opcode
    have selector := FrameOpcodes.selectors matrix _ rc.1 values one satisfied _ (schedule.opcode i ib).1 rc.2.opcode 8 (by decide)
    simp only [FrameRowCheck.codes,List.getD_cons_zero,List.getD_cons_succ] at selector
    have faces := FrameRowImages.interface matrix _ rc.1 values
    simp only [List.map_cons,List.map_nil,List.cons.injEq,and_true] at faces
    have readRep := FrameMemorySound.represented_at values r.frames entries related (2*i) (by omega)
    have enabled : E values (readActive (record r.frames (StructuredMatrix.stage r 3) i))=1 := by
      have h := faces.1.symm.trans readRep.1
      simpa only [active,Bool.toNat_true,Semiring.natCast_one] using h
    have dc := List.all_eq_true.mp depthsChecked i (List.mem_range.mpr (by omega))
    obtain ⟨label,li⟩ := FrameDepthCheck.bounded matrix _ dc values one satisfied
    obtain ⟨depth,di⟩ := FrameTargetSound.selected_depth matrix _ rc.1 values one satisfied label li _ _ tag cats
    obtain ⟨slot,sb,si,_,_⟩ := FrameTargetSound.slot matrix _ rc.1 values one satisfied
      ⟨ControlDepthTrace.depth rows i,depths.bounded i (by omega)⟩ depth (before i (by omega)) di enabled _ selector
    have addr := (FrameAccessSound.read_address matrix _ rc.1 values one satisfied
      (rows.getD i default).functionIndex slot rc.2.functionIndex si enabled).2.2
    refine ⟨slot,sb,?_⟩
    exact DeclarationLocations.natural_equal (F:=F) _ _ (boundAt (2*i) (by omega)).1
      (ControlAddressBounds.index_bound _ _ (images.2 i ib).2.1 (Nat.lt_trans sb (depths.bounded i (by omega))))
      (readRep.2.2.1.symm.trans addr)

#print axioms bool_equal
#print axioms sound
end ZkBuild.FrameTraceMemory
