import ParametricMode
import InstructionSemanticSound
set_option autoImplicit false
namespace ZkBuild.ParametricCertificate
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix
attribute [local instance] Ring.intCast Semiring.natCast

def linked (events : ValidationEventMatrix.Record) (parametric : Stage) : Bool :=
  let operand := ValidationEventCheck.stage events 1
  decide (operand.rows.length = parametric.rows.length ∧ events.rows.length = parametric.rows.length) &&
  (List.range parametric.rows.length).all (fun i => decide (
    ModuleProgram.sameInputs (OperandRowCheck.record operand i).row ((rowAt parametric.rows i).take 7) ∧
    ModuleProgram.sameInputs (OperandRowCheck.record operand i).tags (rowAt parametric.flags i) ∧
    ModuleProgram.sameInputs (rowAt parametric.rows i) ((rowAt events.rows i).take 10) ∧
    ModuleProgram.sameInputs (rowAt parametric.inputs i) [f (rowAt events.rows i) 10]))

def check (matrix : Shape) (statics : StaticCatalog) (events : ValidationEventMatrix.Record) : Bool :=
  InstructionSemanticSound.check matrix statics events &&
  ParametricRowCheck.checkStage matrix (ValidationEventCheck.stage events 4) &&
  linked events (ValidationEventCheck.stage events 4)

theorem row_checked (matrix : Shape) (s : Stage)
    (checked : ParametricRowCheck.checkStage matrix s = true) (i : Nat) (ib : i < s.rows.length) :
    ParametricRowCheck.check matrix (ParametricRowCheck.record s i) = true :=
  List.all_eq_true.mp (Bool.and_eq_true_iff.mp checked).2 i (List.mem_range.mpr ib)

theorem row {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (statics : StaticCatalog) (events : ValidationEventMatrix.Record)
    (accepted : check matrix statics events = true)
    (values : Nat → F) (one : values 0 = 1) (rows : List OperandEvents.Row)
    (images : OperandTraceSound.Represents values (ValidationEventCheck.stage events 1) rows)
    (i : Nat) (ib : i < rows.length) :
    ParametricRowCheck.check matrix (ParametricRowCheck.record (ValidationEventCheck.stage events 4) i) = true ∧
    ParametricRowSound.Tags values (ParametricRowCheck.record (ValidationEventCheck.stage events 4) i) (rows.getD i default).kind ∧
    E values (f (rowAt (ValidationEventCheck.stage events 4).rows i) 4) = ((rows.getD i default).valueType.val : F) ∧
    E values (f (rowAt (ValidationEventCheck.stage events 4).rows i) 8) = E values (f (rowAt events.rows i) 8) := by
  have parts := accepted
  simp only [check,Bool.and_eq_true_iff] at parts
  have links := parts.2
  simp only [linked,Bool.and_eq_true_iff,decide_eq_true_eq] at links
  have size : rows.length = (ValidationEventCheck.stage events 4).rows.length := images.1.trans links.1.1
  have matched := _root_.of_decide_eq_true (List.all_eq_true.mp links.2 i (List.mem_range.mpr (by omega)))
  have sourceRow := images.2 i ib
  have rowValues := SourceProgramSound.normalized_inputs values _ _ matched.1
  have tagValues := SourceProgramSound.normalized_inputs values _ _ matched.2.1
  have zero : E values z = 0 := by simpa [z,Ring.intCast_zero] using eval_constant values one 0
  have tagImage : ParametricRowSound.Tags values (ParametricRowCheck.record (ValidationEventCheck.stage events 4) i) (rows.getD i default).kind := by
    intro j
    have equal := tagValues.symm.trans sourceRow.1.selectors
    have point := congrArg (fun xs : List F => xs.getD j 0) equal
    have left : ((rowAt (ValidationEventCheck.stage events 4).flags i).map (E values)).getD j 0 =
        E values (f (rowAt (ValidationEventCheck.stage events 4).flags i) j) := by
      rw [← zero]; exact TokenInteger.map_getD _ _ z j
    rw [left] at point
    exact point
  refine ⟨row_checked matrix _ parts.1.2 i (by omega),tagImage,?_,?_⟩
  · have point := congrArg (fun xs : List F => xs.getD 4 0) rowValues
    rw [← zero,TokenInteger.map_getD,TokenInteger.map_getD] at point
    have equal : E values (f (OperandRowCheck.record (ValidationEventCheck.stage events 1) i).row 4) =
        E values (f (rowAt (ValidationEventCheck.stage events 4).rows i) 4) := by
      simpa [f,DeclarationMatrix.get,List.getD,List.getElem?_take] using point
    exact equal.symm.trans sourceRow.1.valueType
  · have equal := VariableSelectorCheck.point values _ _ matched.2.2.1 8
    simpa [f,DeclarationMatrix.get,List.getD,List.getElem?_take] using equal

#print axioms row
end ZkBuild.ParametricCertificate
