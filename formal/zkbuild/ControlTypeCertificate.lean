import ControlTypeRowImages
import FrameCertificate
import FrameOpcodes
set_option autoImplicit false
namespace ZkBuild.ControlTypeCertificate
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix OperandEvents
attribute [local instance] Ring.intCast Semiring.natCast

def linked (events : ValidationEventMatrix.Record) (r : StructuredMatrix.Record) : Bool :=
  let operand := ValidationEventCheck.stage events 1
  let typed := StructuredMatrix.stage r 4
  decide (operand.rows.length=typed.rows.length ∧ events.rows.length=typed.rows.length ∧
    (StructuredMatrix.stage r 3).rows.length=typed.rows.length) &&
  (List.range typed.rows.length).all (fun i => decide (
    ModuleProgram.sameInputs (rowAt typed.rows i) ((rowAt events.rows i).take 10) ∧
    ModuleProgram.sameInputs ((rowAt typed.rows i).take 7) (OperandRowCheck.record operand i).row ∧
    ModuleProgram.sameInputs (rowAt typed.flags i) (OperandRowCheck.record operand i).tags ∧
    ModuleProgram.sameInputs (rowAt typed.selectors i) (rowAt (StructuredMatrix.stage r 3).outputs i)))

def check (matrix : Shape) (splits : Splits) (events : ValidationEventMatrix.Record) (r : StructuredMatrix.Record) : Bool :=
  ControlTypeRowCheck.checkStage matrix splits (StructuredMatrix.stage r 4) &&
    FrameCertificate.check matrix events r && linked events r

structure Images {F : Type} [Field F] (values : Nat → F) (r : ControlTypeRowCheck.Record)
    (frame : FrameRowCheck.Record) (row : Row) : Prop where
  flags : r.flags.map (E values)=(EventSelectors.codes.map (fun c => flag (F:=F) (decide (c=kindCode row.kind))))
  actual : E values (f r.row 4)=(row.valueType.val:F)
  frame : r.frame.map (E values)=frame.outputs.map (E values)

theorem row {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (splits : Splits) (events : ValidationEventMatrix.Record) (r : StructuredMatrix.Record)
    (checked : check matrix splits events r=true) (values : Nat → F)
    (rows : List Row) (ops : List Nat)
    (images : OperandTraceSound.Represents values (ValidationEventCheck.stage events 1) rows)
    (schedule : InstructionSemanticSound.Schedule values events rows ops) (i : Nat) (ib : i<rows.length) :
    ControlTypeRowCheck.check matrix (ControlTypeRowCheck.record splits (StructuredMatrix.stage r 4) i)=true ∧
    Images values (ControlTypeRowCheck.record splits (StructuredMatrix.stage r 4) i)
      (FrameRowCheck.record r.frames (StructuredMatrix.stage r 3) i) (rows.getD i default) ∧
    FrameRowCheck.check matrix (FrameRowCheck.record r.frames (StructuredMatrix.stage r 3) i)=true ∧
    FrameCertificate.Images values (FrameRowCheck.record r.frames (StructuredMatrix.stage r 3) i) (rows.getD i default) (ops.getD i 0) := by
  have parts := checked
  simp only [check,Bool.and_eq_true_iff] at parts
  have links := parts.2
  simp only [linked,Bool.and_eq_true_iff,decide_eq_true_eq] at links
  have size : rows.length=(StructuredMatrix.stage r 4).rows.length := images.1.trans links.1.1
  have matched := _root_.of_decide_eq_true (List.all_eq_true.mp links.2 i (List.mem_range.mpr (by omega)))
  have source := (images.2 i ib).1
  have flagEq := SourceProgramSound.normalized_inputs values _ _ matched.2.2.1
  have frameEq := SourceProgramSound.normalized_inputs values _ _ matched.2.2.2
  have valueEq := VariableSelectorCheck.point values _ _ matched.2.1 4
  have actual : E values (f (rowAt (StructuredMatrix.stage r 4).rows i) 4)=((rows.getD i default).valueType.val:F) := by
    have same : E values (f (rowAt (StructuredMatrix.stage r 4).rows i) 4)=E values (f (OperandRowCheck.record (ValidationEventCheck.stage events 1) i).row 4) := by
      simpa [f,DeclarationMatrix.get,List.getD,List.getElem?_take] using valueEq
    exact same.trans source.valueType
  have rc := List.all_eq_true.mp (Bool.and_eq_true_iff.mp parts.1.1).2 i (List.mem_range.mpr (by omega))
  exact ⟨rc,⟨flagEq.trans source.selectors,actual,frameEq⟩,
    FrameCertificate.row matrix events r parts.1.2 values rows ops images schedule i ib⟩

theorem tag {F : Type} [Field F] (values : Nat → F) (one : values 0=1)
    (r : ControlTypeRowCheck.Record) (frame : FrameRowCheck.Record) (row : Row)
    (image : Images values r frame row) (j : Nat) :
    E values (f r.flags j)=(EventSelectors.codes.map (fun c => flag (F:=F) (decide (c=kindCode row.kind)))).getD j 0 := by
  have zero : E values z=0 := by simpa only [z,Ring.intCast_zero] using eval_constant values one 0
  have h := congrArg (fun xs : List F => xs.getD j 0) image.flags
  rw [← zero,TokenInteger.map_getD] at h
  simpa only [f,DeclarationMatrix.get,zero] using h

#print axioms row
#print axioms tag
end ZkBuild.ControlTypeCertificate
