import ControlRowSound
import OperandCertificate
set_option autoImplicit false
namespace ZkBuild.ControlCertificate
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix
attribute [local instance] Ring.intCast Semiring.natCast

def linked (operand control : Stage) : Bool :=
  decide (operand.rows.length = control.rows.length ∧
    ModuleProgram.sameInputs operand.rows.flatten (control.rows.map (List.take 7)).flatten ∧
    ModuleProgram.sameInputs operand.flags.flatten control.flags.flatten) &&
  (List.range operand.rows.length).all (fun i =>
    decide (ModuleProgram.sameInputs (OperandRowCheck.record operand i).row ((ControlRowCheck.record control i).row.take 7) ∧
      ModuleProgram.sameInputs (OperandRowCheck.record operand i).tags (ControlRowCheck.record control i).tags))

def check (matrix : Shape) (r : ValidationEventMatrix.Record) : Bool :=
  OperandCertificate.check matrix r && ControlRowCheck.checkStage matrix (ValidationEventCheck.stage r 2) &&
  linked (ValidationEventCheck.stage r 1) (ValidationEventCheck.stage r 2)

theorem lift {F : Type} [Field F] [IsCharP F scalarModulus]
    (values : Nat → F) (operand : OperandRowCheck.Record) (control : ControlRowCheck.Record)
    (row : OperandEvents.Row) (image : OperandRowSound.Represents values operand row)
    (rowMatch : ModuleProgram.sameInputs operand.row (control.row.take 7))
    (tagMatch : ModuleProgram.sameInputs operand.tags control.tags)
    (_rowLength : control.row.length = 8) : ControlRowSound.Represents values control row := by
  have rowValues := SourceProgramSound.normalized_inputs values _ _ rowMatch
  have tagValues := SourceProgramSound.normalized_inputs values _ _ tagMatch
  have rowField (i : Nat) (ib : i < 7) : E values (f operand.row i) = E values (f control.row i) := by
    have evaluated := congrArg (fun xs : List F => xs.getD i 0) rowValues
    have zero : E values z = 0 := by simp [z,E,evalLinear,constant,interpretLinear,R1CS.eval,Ring.intCast_zero,Semiring.zero_mul,AddCommMonoid.zero_add]
    rw [← zero,TokenInteger.map_getD,TokenInteger.map_getD] at evaluated
    simpa [f,DeclarationMatrix.get,List.getD,List.getElem?_take,ib] using evaluated
  have tags (i : Nat) : E values (f control.tags i) =
      (EventSelectors.codes.map (fun code => OperandEvents.flag (decide (code = OperandEvents.kindCode row.kind)))).getD i 0 := by
    have equality := tagValues.symm.trans image.selectors
    have evaluated := congrArg (fun xs : List F => xs.getD i 0) equality
    have zero : E values z = 0 := by simp [z,E,evalLinear,constant,interpretLinear,R1CS.eval,Ring.intCast_zero,Semiring.zero_mul,AddCommMonoid.zero_add]
    have left : (control.tags.map (E values)).getD i 0 = E values (f control.tags i) := by
      rw [← zero]; exact TokenInteger.map_getD _ _ z i
    rw [left] at evaluated
    exact evaluated
  exact ⟨(rowField 1 (by decide)).symm.trans image.functionIndex,
    (rowField 2 (by decide)).symm.trans image.height,
    (rowField 3 (by decide)).symm.trans image.floor,
    (rowField 5 (by decide)).symm.trans image.polymorphic,
    (rowField 6 (by decide)).symm.trans image.unreachable,tags⟩

theorem rows {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : ValidationEventMatrix.Record) (accepted : check matrix r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ rows : List OperandEvents.Row,
      OperandTraceSound.Represents values (ValidationEventCheck.stage r 1) rows ∧
      rows.length = (ValidationEventCheck.stage r 2).rows.length ∧
      ∀ i, i < rows.length →
        ControlRowSound.Represents values (ControlRowCheck.record (ValidationEventCheck.stage r 2) i) (rows.getD i default) ∧
        ControlRowCheck.check matrix (ControlRowCheck.record (ValidationEventCheck.stage r 2) i) = true := by
  have parts := accepted
  simp only [check,Bool.and_eq_true_iff] at parts
  obtain ⟨rows,images,_⟩ := OperandCertificate.sound matrix r parts.1.1 values one satisfied
  have links := parts.2
  simp only [linked,Bool.and_eq_true_iff,decide_eq_true_eq] at links
  have length : rows.length = (ValidationEventCheck.stage r 2).rows.length := images.1.trans links.1.1
  refine ⟨rows,images,length,?_⟩
  intro i bound
  have checked := (Bool.and_eq_true_iff.mp parts.1.2).2
  have rc := List.all_eq_true.mp checked i (List.mem_range.mpr (by omega))
  have matched := List.all_eq_true.mp links.2 i (List.mem_range.mpr (by omega))
  have matched := _root_.of_decide_eq_true matched
  have dims := rc
  simp only [ControlRowCheck.check,Bool.and_eq_true_iff,decide_eq_true_eq,and_assoc] at dims
  exact ⟨lift values _ _ _ (images.2 i bound).1 matched.1 matched.2 dims.1,rc⟩

#print axioms lift
#print axioms rows
end ZkBuild.ControlCertificate
