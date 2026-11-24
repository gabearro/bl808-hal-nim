import InstructionSemanticSource
import VariableRuleImageSound
set_option autoImplicit false
namespace ZkBuild.VariableCertificate
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix
attribute [local instance] Ring.intCast Semiring.natCast

def linked (operand : Stage) (variables : DynamicTypingMatrix.Stage) : Bool :=
  decide (operand.rows.length = variables.rows.length) &&
  (List.range operand.rows.length).all (fun i => decide (
    ModuleProgram.sameInputs (OperandRowCheck.record operand i).row ((rowAt variables.rows i).take 7) ∧
    ModuleProgram.sameInputs (OperandRowCheck.record operand i).tags (rowAt variables.flags i)))

def check (matrix : Shape) (statics : StaticCatalog) (events : ValidationEventMatrix.Record)
    (typing : DynamicTypingMatrix.Record) : Bool :=
  InstructionSemanticSound.check matrix statics events &&
  VariableRowCheck.checkStage matrix (DynamicTypingCheck.stage typing 2) &&
  linked (ValidationEventCheck.stage events 1) (DynamicTypingCheck.stage typing 2)

theorem row_checked (matrix : Shape) (s : DynamicTypingMatrix.Stage)
    (checked : VariableRowCheck.checkStage matrix s = true) (i : Nat) (ib : i < s.rows.length) :
    VariableRowCheck.check matrix (VariableRowCheck.record s i) = true :=
  List.all_eq_true.mp (Bool.and_eq_true_iff.mp checked).2 i (List.mem_range.mpr ib)

theorem rows {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (statics : StaticCatalog) (events : ValidationEventMatrix.Record)
    (typing : DynamicTypingMatrix.Record) (accepted : check matrix statics events typing = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ rows : List OperandEvents.Row,
      OperandTraceSound.Represents values (ValidationEventCheck.stage events 1) rows ∧
      rows.length = (DynamicTypingCheck.stage typing 2).rows.length ∧
      ∀ i, i < rows.length →
        VariableRowCheck.check matrix (VariableRowCheck.record (DynamicTypingCheck.stage typing 2) i) = true ∧
        VariableRowSound.Tags values (VariableRowCheck.record (DynamicTypingCheck.stage typing 2) i) (rows.getD i default).kind ∧
        E values (f (rowAt (DynamicTypingCheck.stage typing 2).rows i) 4) = ((rows.getD i default).valueType.val : F) := by
  have parts := accepted
  simp only [check,Bool.and_eq_true_iff] at parts
  have ic := (Bool.and_eq_true_iff.mp parts.1.1).1
  obtain ⟨rows,images,_,_⟩ := InstructionCertificate.rows matrix statics events ic values one satisfied
  have links := parts.2
  simp only [linked,Bool.and_eq_true_iff,decide_eq_true_eq] at links
  have size : rows.length = (DynamicTypingCheck.stage typing 2).rows.length := images.1.trans links.1
  refine ⟨rows,images,size,?_⟩
  intro i ib
  have matched := _root_.of_decide_eq_true (List.all_eq_true.mp links.2 i (List.mem_range.mpr (by omega)))
  have sourceRow := images.2 i ib
  have rowValues := SourceProgramSound.normalized_inputs values _ _ matched.1
  have tagValues := SourceProgramSound.normalized_inputs values _ _ matched.2
  have zero : E values z = 0 := by simpa [z,Ring.intCast_zero] using eval_constant values one 0
  have tagImage : VariableRowSound.Tags values (VariableRowCheck.record (DynamicTypingCheck.stage typing 2) i) (rows.getD i default).kind := by
    intro j
    have equal := tagValues.symm.trans sourceRow.1.selectors
    have point := congrArg (fun xs : List F => xs.getD j 0) equal
    have left : ((rowAt (DynamicTypingCheck.stage typing 2).flags i).map (E values)).getD j 0 =
        E values (f (rowAt (DynamicTypingCheck.stage typing 2).flags i) j) := by
      rw [← zero]; exact TokenInteger.map_getD _ _ z j
    rw [left] at point
    exact point
  refine ⟨row_checked matrix _ parts.1.2 i (by omega),tagImage,?_⟩
  have point := congrArg (fun xs : List F => xs.getD 4 0) rowValues
  rw [← zero,TokenInteger.map_getD,TokenInteger.map_getD] at point
  have equal : E values (f (OperandRowCheck.record (ValidationEventCheck.stage events 1) i).row 4) =
      E values (f (rowAt (DynamicTypingCheck.stage typing 2).rows i) 4) := by
    simpa [f,DeclarationMatrix.get,List.getD,List.getElem?_take] using point
  exact equal.symm.trans sourceRow.1.valueType

#print axioms rows
end ZkBuild.VariableCertificate
