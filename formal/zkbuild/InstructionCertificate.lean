import EventSemanticLifo
import InstructionStaticSound
set_option autoImplicit false
namespace ZkBuild.InstructionCertificate
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix
attribute [local instance] Ring.intCast Semiring.natCast

def record (statics : StaticCatalog) (s : Stage) (i : Nat) :=
  InstructionRowCheck.record s i ((InstructionRowCheck.rule statics s i).getD default)

def linked (operand instruction : Stage) : Bool :=
  decide (operand.rows.length = instruction.rows.length) &&
  (List.range operand.rows.length).all (fun i =>
    decide (ModuleProgram.sameInputs (OperandRowCheck.record operand i).row ((rowAt instruction.rows i).take 7) ∧
      ModuleProgram.sameInputs (OperandRowCheck.record operand i).tags (rowAt instruction.flags i)))

def check (matrix : Shape) (statics : StaticCatalog) (r : ValidationEventMatrix.Record) : Bool :=
  EventSemanticSound.check matrix r && InstructionRowCheck.checkStage matrix statics (ValidationEventCheck.stage r 3) &&
  linked (ValidationEventCheck.stage r 1) (ValidationEventCheck.stage r 3)

theorem row_checked (matrix : Shape) (statics : StaticCatalog) (s : Stage)
    (checked : InstructionRowCheck.checkStage matrix statics s = true) (i : Nat) (ib : i < s.rows.length) :
    InstructionRowCheck.check matrix (record statics s i) = true := by
  have row := List.all_eq_true.mp (Bool.and_eq_true_iff.mp checked).2 i (List.mem_range.mpr ib)
  cases rule : InstructionRowCheck.rule statics s i with
  | none => simp [rule] at row
  | some r => simpa [record,rule] using row

theorem rows {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (statics : StaticCatalog) (r : ValidationEventMatrix.Record) (accepted : check matrix statics r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ rows : List OperandEvents.Row,
      OperandTraceSound.Represents values (ValidationEventCheck.stage r 1) rows ∧
      rows.length = (ValidationEventCheck.stage r 3).rows.length ∧
      ∀ i, i < rows.length →
        InstructionRowCheck.check matrix (record statics (ValidationEventCheck.stage r 3) i) = true ∧
        InstructionRowSound.Tags values (record statics (ValidationEventCheck.stage r 3) i) (rows.getD i default).kind ∧
        E values (f (record statics (ValidationEventCheck.stage r 3) i).row 4) = ((rows.getD i default).valueType.val : F) := by
  have parts := accepted
  simp only [check,Bool.and_eq_true_iff] at parts
  have cc := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp parts.1.1).1).1
  have op := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp cc).1).1
  obtain ⟨rows,images,_⟩ := OperandCertificate.sound matrix r op values one satisfied
  have links := parts.2
  simp only [linked,Bool.and_eq_true_iff,decide_eq_true_eq] at links
  have size : rows.length = (ValidationEventCheck.stage r 3).rows.length := images.1.trans links.1
  refine ⟨rows,images,size,?_⟩
  intro i ib
  have matched := _root_.of_decide_eq_true (List.all_eq_true.mp links.2 i (List.mem_range.mpr (by omega)))
  have sourceRow := images.2 i ib
  have rowValues := SourceProgramSound.normalized_inputs values _ _ matched.1
  have tagValues := SourceProgramSound.normalized_inputs values _ _ matched.2
  have zero : E values z = 0 := by simpa [z,Ring.intCast_zero] using eval_constant values one 0
  have tagImage : InstructionRowSound.Tags values (record statics (ValidationEventCheck.stage r 3) i) (rows.getD i default).kind := by
    intro j
    have equal := tagValues.symm.trans sourceRow.1.selectors
    have point := congrArg (fun xs : List F => xs.getD j 0) equal
    have left : ((rowAt (ValidationEventCheck.stage r 3).flags i).map (E values)).getD j 0 =
        E values (f (rowAt (ValidationEventCheck.stage r 3).flags i) j) := by
      rw [← zero]; exact TokenInteger.map_getD _ _ z j
    rw [left] at point
    exact point
  refine ⟨row_checked matrix statics _ parts.1.2 i (by omega),tagImage,?_⟩
  have point := congrArg (fun xs : List F => xs.getD 4 0) rowValues
  rw [← zero,TokenInteger.map_getD,TokenInteger.map_getD] at point
  have equal : E values (f (OperandRowCheck.record (ValidationEventCheck.stage r 1) i).row 4) =
      E values (f (rowAt (ValidationEventCheck.stage r 3).rows i) 4) := by
    simpa [f,DeclarationMatrix.get,List.getD,List.getElem?_take] using point
  exact equal.symm.trans sourceRow.1.valueType

#print axioms row_checked
#print axioms rows
end ZkBuild.InstructionCertificate
