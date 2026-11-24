import DynamicTypingMatrix
set_option autoImplicit false
namespace ZkBuild.DynamicSelectors
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix DynamicTypingMatrix
attribute [local instance] Ring.intCast Semiring.natCast

def codes : List Nat := [32,33,34,35,36,37,38,271,272,273]
def operation (s : Stage) (row column : Nat) := s.program.base.operations.getD (10*row+column) default
def checkCell (matrix : Shape) (s : Stage) (row column : Nat) : Bool :=
  let op := operation s row column
  decide (op.call.kind = 7 ∧ op.call.inputs = [op.call.inputs.getD 0 []] ∧
    ModuleProgram.sameInputs op.call.inputs [sub (ValidationEventMatrix.f (eventAt s row) 8) (n (codes.getD column 0))] ∧
    op.call.outputs.getD 0 [] = ValidationEventMatrix.f (ValidationEventMatrix.rowAt s.outputs row) column ∧ op.source = none) &&
  GadgetAudit.check matrix op.call op.source
def check (matrix : Shape) (s : Stage) : Bool :=
  (List.range s.rows.length).all (fun row => (List.range 10).all (checkCell matrix s row))

theorem cell {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (s : Stage) (row column : Nat)
    (checked : checkCell matrix s row column = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values) :
    E values (ValidationEventMatrix.f (ValidationEventMatrix.rowAt s.outputs row) column) =
      if E values (ValidationEventMatrix.f (eventAt s row) 8) = (codes.getD column 0 : F) then 1 else 0 := by
  have shape := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp checked).1
  rcases shape with ⟨kind,input,inputMatch,output,source⟩
  let op := operation s row column
  let arg := op.call.inputs.getD 0 []
  let out := wire op.call.firstWire
  let reciprocal := wire (op.call.firstWire+1)
  let template : GadgetAudit.Template := ⟨zeroGates arg out reciprocal,[out,reciprocal],2⟩
  have description : GadgetAudit.describe op.call op.source = some template := by
    unfold GadgetAudit.describe
    rw [kind,input]
    rfl
  have relation := GadgetAudit.checked_fragment_relation matrix op.call op.source template description
    (Bool.and_eq_true_iff.mp checked).2 values satisfied
  have holds : AllHold values (zeroGates arg out reciprocal) := by
    simpa [GadgetAudit.model,template,Satisfied,AllHold,Holds] using relation.1
  have value := zero_sound values one arg out reciprocal holds
  have first := congrArg (fun xs : List F => xs.getD 0 0) relation.2
  have left : (op.call.outputs.map (E values)).getD 0 0 = E values (op.call.outputs.getD 0 []) := by
    have zero : E values ([] : Linear) = 0 := by simp [E,FullMatrix.evalLinear,interpretLinear,R1CS.eval]
    rw [← zero]
    exact TokenInteger.map_getD (E values) op.call.outputs [] 0
  rw [left,output] at first
  have image : E values arg = E values (ValidationEventMatrix.f (eventAt s row) 8) - (codes.getD column 0 : F) := by
    have matched := SourceProgramSound.normalized_inputs values _ _ inputMatch
    rw [input] at matched
    simp only [List.map_cons,List.map_nil,List.cons.injEq,and_true] at matched
    change E values arg = _ at matched
    simpa [eval_sub,n,eval_constant values one,Ring.intCast_natCast] using matched
  have result : E values (ValidationEventMatrix.f (ValidationEventMatrix.rowAt s.outputs row) column) = E values out := by
    simpa [template] using first
  rw [result,value,image]
  by_cases same : E values (ValidationEventMatrix.f (eventAt s row) 8) = (codes.getD column 0 : F)
  · simp [same]; grind
  · have different : E values (ValidationEventMatrix.f (eventAt s row) 8) - (codes.getD column 0 : F) ≠ 0 := by grind
    simp only [different,same,ite_false]

theorem rows {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (s : Stage) (checked : check matrix s = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (row column : Nat) (rb : row < s.rows.length) (cb : column < 10) :
    E values (ValidationEventMatrix.f (ValidationEventMatrix.rowAt s.outputs row) column) =
      if E values (ValidationEventMatrix.f (eventAt s row) 8) = (codes.getD column 0 : F) then 1 else 0 :=
  cell matrix s row column (List.all_eq_true.mp (List.all_eq_true.mp checked row (List.mem_range.mpr rb)) column (List.mem_range.mpr cb)) values one satisfied
#print axioms cell
#print axioms rows
end ZkBuild.DynamicSelectors
