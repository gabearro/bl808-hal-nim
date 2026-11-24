import FrameOpcodes
import InstructionSemanticSound
set_option autoImplicit false
namespace ZkBuild.FrameCertificate
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix OperandEvents
attribute [local instance] Ring.intCast Semiring.natCast

def linked (events : ValidationEventMatrix.Record) (r : StructuredMatrix.Record) : Bool :=
  let frame := StructuredMatrix.stage r 3
  let operand := ValidationEventCheck.stage events 1
  let control := ValidationEventCheck.stage events 2
  decide (operand.rows.length = frame.rows.length ∧ events.rows.length = frame.rows.length ∧
    control.rows.length = frame.rows.length) &&
  (List.range frame.rows.length).all (fun i => decide (
    ModuleProgram.sameInputs (rowAt frame.rows i) ((rowAt events.rows i).take 10) ∧
    ModuleProgram.sameInputs ((rowAt frame.rows i).take 7) (OperandRowCheck.record operand i).row ∧
    ModuleProgram.sameInputs (rowAt frame.flags i) (OperandRowCheck.record operand i).tags ∧
    ModuleProgram.sameInputs [f (rowAt frame.rows i) 7] [f (ControlRowCheck.record control i).row 7]))

def check (matrix : Shape) (events : ValidationEventMatrix.Record) (r : StructuredMatrix.Record) : Bool :=
  FrameRowCheck.checkStage matrix r.frames (StructuredMatrix.stage r 3) && linked events r

structure Images {F : Type} [Field F] (values : Nat → F) (r : FrameRowCheck.Record) (row : Row) (code : Nat) : Prop where
  tags : r.flags.map (E values) = EventSelectors.codes.map
    (fun c => flag (decide (c = kindCode row.kind)))
  functionIndex : E values (f r.row 1) = (row.functionIndex : F)
  opcode : E values (f r.row 8) = (code : F)

theorem row {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (events : ValidationEventMatrix.Record) (r : StructuredMatrix.Record)
    (checked : check matrix events r = true) (values : Nat → F)
    (rows : List Row) (ops : List Nat)
    (images : OperandTraceSound.Represents values (ValidationEventCheck.stage events 1) rows)
    (schedule : InstructionSemanticSound.Schedule values events rows ops)
    (i : Nat) (ib : i < rows.length) :
    FrameRowCheck.check matrix (FrameRowCheck.record r.frames (StructuredMatrix.stage r 3) i) = true ∧
    Images values (FrameRowCheck.record r.frames (StructuredMatrix.stage r 3) i) (rows.getD i default) (ops.getD i 0) := by
  have parts := Bool.and_eq_true_iff.mp checked
  have links := parts.2
  simp only [linked,Bool.and_eq_true_iff,decide_eq_true_eq] at links
  have size : rows.length = (StructuredMatrix.stage r 3).rows.length := images.1.trans links.1.1
  have matched := _root_.of_decide_eq_true (List.all_eq_true.mp links.2 i (List.mem_range.mpr (by omega)))
  have src := (images.2 i ib).1
  have rc := List.all_eq_true.mp (Bool.and_eq_true_iff.mp parts.1).2 i (List.mem_range.mpr (by omega))
  refine ⟨rc,?_,?_,?_⟩
  · exact (SourceProgramSound.normalized_inputs values _ _ matched.2.2.1).trans src.selectors
  · have same := VariableSelectorCheck.point values _ _ matched.2.1 1
    have fi : E values (f (rowAt (StructuredMatrix.stage r 3).rows i) 1) =
        E values (f (OperandRowCheck.record (ValidationEventCheck.stage events 1) i).row 1) := by
      simpa only [f,DeclarationMatrix.get,List.getD,List.getElem?_take,show 1<7 from by decide,ite_true] using same
    exact fi.trans src.functionIndex
  · have same := VariableSelectorCheck.point values _ _ matched.1 8
    have oi : E values (f (rowAt (StructuredMatrix.stage r 3).rows i) 8) = E values (f (rowAt events.rows i) 8) := by
      simpa only [f,DeclarationMatrix.get,List.getD,List.getElem?_take,show 8<10 from by decide,ite_true] using same
    exact oi.trans (schedule.opcode i ib).2.1

theorem control_depth {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (events : ValidationEventMatrix.Record) (r : StructuredMatrix.Record)
    (checked : check matrix events r = true)
    (controls : ControlRowCheck.checkStage matrix (ValidationEventCheck.stage events 2) = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (i : Nat) (ib : i < (StructuredMatrix.stage r 3).rows.length) :
    ∃ depth : Fin (2^32), E values (f (FrameRowCheck.record r.frames (StructuredMatrix.stage r 3) i).before 0) = (depth.val : F) := by
  have links := (Bool.and_eq_true_iff.mp checked).2
  simp only [linked,Bool.and_eq_true_iff,decide_eq_true_eq] at links
  by_cases first : i=0
  · subst i
    refine ⟨0,?_⟩
    change E values z = ((0:Nat):F)
    simp only [z,eval_constant values one,Ring.intCast_zero,Semiring.natCast_zero]
  · have prior : i-1 < (StructuredMatrix.stage r 3).rows.length := by omega
    have matched := _root_.of_decide_eq_true (List.all_eq_true.mp links.2 (i-1) (List.mem_range.mpr prior))
    have rc := List.all_eq_true.mp (Bool.and_eq_true_iff.mp controls).2 (i-1) (List.mem_range.mpr (by omega))
    obtain ⟨d,db,di⟩ := (ControlRowSound.facts matrix _ rc values one satisfied).2.1
    have same := VariableSelectorCheck.point values _ _ matched.2.2.2 0
    simp only [f,DeclarationMatrix.get,List.getD_cons_zero] at same
    refine ⟨⟨d,db⟩,?_⟩
    simpa only [FrameRowCheck.record,first,ite_false,f,DeclarationMatrix.get,List.getD_cons_zero] using same.trans di

#print axioms row
#print axioms control_depth
end ZkBuild.FrameCertificate
