import BranchRowImages
import ParametricCertificate
set_option autoImplicit false
namespace ZkBuild.BranchCertificate
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix OperandEvents
attribute [local instance] Ring.intCast Semiring.natCast

def labelGates (events : ValidationEventMatrix.Record) (r : StructuredMatrix.Record) (i : Nat) : List Gate :=
  let original := OperandRowCheck.record (ValidationEventCheck.stage events 1) i
  let branch := StructuredMatrix.stage r 2
  let filterStage := StructuredMatrix.stage r 1
  let op := filterStage.program.base.operations.getD (2*i) default
  let selected := op.call.outputs.getD 0 []
  zeroGates (sub (f (rowAt branch.rows i) 8) (n 14)) selected (op.call.outputs.getD 1 []) ++
    [mulGate (f original.tags 9) selected (f (rowAt branch.flags i) 9)]

def linked (matrix : Shape) (events : ValidationEventMatrix.Record) (r : StructuredMatrix.Record) : Bool :=
  let operand := ValidationEventCheck.stage events 1
  let branch := StructuredMatrix.stage r 2
  let filterStage := StructuredMatrix.stage r 1
  decide (operand.rows.length = branch.rows.length ∧ events.rows.length = branch.rows.length ∧
    filterStage.program.base.operations.length = 2*branch.rows.length) &&
  (List.range branch.rows.length).all (fun i =>
    decide (ModuleProgram.sameInputs (rowAt branch.rows i) ((rowAt events.rows i).take 10) ∧
      ModuleProgram.sameInputs ((rowAt branch.rows i).take 7) (OperandRowCheck.record operand i).row ∧
      ModuleProgram.sameInputs ([0,1,7].map (f (rowAt branch.flags i))) ([0,1,7].map (f (OperandRowCheck.record operand i).tags)) ∧
      ModuleProgram.sameInputs (rowAt branch.inputs i) [f (rowAt events.rows i) 10]) &&
    OperandRowCheck.includes matrix (filterStage.program.base.operations.getD (2*i) default).call.firstGate
      (filterStage.program.base.operations.getD (2*i+1) default).call.lastGate (labelGates events r i))

def check (matrix : Shape) (splits : Splits) (tables : List ReadOnlyMatrix.Record)
    (statics : StaticCatalog) (events : ValidationEventMatrix.Record) (r : StructuredMatrix.Record) : Bool :=
  ParametricCertificate.check matrix statics events &&
  BranchRowCheck.checkStage matrix splits tables (StructuredMatrix.stage r 2) && linked matrix events r

def Tags {F : Type} [Field F] (values : Nat → F) (r : BranchRowCheck.Record) (kind : Kind) (code : Nat) : Prop :=
  E values (f r.flags 0) = flag (decide (kind = .functionBegin)) ∧
  E values (f r.flags 1) = flag (decide (kind = .instructionBegin)) ∧
  E values (f r.flags 7) = flag (decide (kind = .instructionEnd)) ∧
  E values (f r.flags 9) = flag (decide (kind = .labelCheck ∧ code = 14))

theorem row {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (splits : Splits) (tables : List ReadOnlyMatrix.Record)
    (statics : StaticCatalog) (events : ValidationEventMatrix.Record) (r : StructuredMatrix.Record)
    (checked : check matrix splits tables statics events r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (rows : List Row) (ops : List Nat)
    (images : OperandTraceSound.Represents values (ValidationEventCheck.stage events 1) rows)
    (schedule : InstructionSemanticSound.Schedule values events rows ops) (i : Nat) (ib : i < rows.length) :
    BranchRowCheck.check matrix (BranchRowCheck.record splits tables (StructuredMatrix.stage r 2) i) = true ∧
    Tags values (BranchRowCheck.record splits tables (StructuredMatrix.stage r 2) i) (rows.getD i default).kind (ops.getD i 0) ∧
    E values (f (rowAt (StructuredMatrix.stage r 2).rows i) 1) = ((rows.getD i default).functionIndex : F) ∧
    E values (f (rowAt (StructuredMatrix.stage r 2).rows i) 8) = (ops.getD i 0 : F) := by
  have parts := checked
  simp only [check,Bool.and_eq_true_iff] at parts
  have links := parts.2
  simp only [linked,Bool.and_eq_true_iff,decide_eq_true_eq] at links
  have size : rows.length = (StructuredMatrix.stage r 2).rows.length := images.1.trans links.1.1
  have linkedRow := List.all_eq_true.mp links.2 i (List.mem_range.mpr (by omega))
  have matched := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp linkedRow).1
  have rc := List.all_eq_true.mp (Bool.and_eq_true_iff.mp parts.1.2).2 i (List.mem_range.mpr (by omega))
  have opcode := VariableSelectorCheck.point values _ _ matched.1 8
  have codeImage : E values (f (rowAt (StructuredMatrix.stage r 2).rows i) 8) = (ops.getD i 0 : F) := by
    have canon : E values (f (rowAt (StructuredMatrix.stage r 2).rows i) 8) = E values (f (rowAt events.rows i) 8) := by
      simpa [f,DeclarationMatrix.get,List.getD,List.getElem?_take] using opcode
    exact canon.trans (schedule.opcode i ib).2.1
  have source := (images.2 i ib).1
  have zero : E values z = 0 := by simpa [z,Ring.intCast_zero] using eval_constant values one 0
  have tags (j : Nat) : E values (f (OperandRowCheck.record (ValidationEventCheck.stage events 1) i).tags j) =
      (EventSelectors.codes.map (fun c => flag (F := F) (decide (c = kindCode (rows.getD i default).kind)))).getD j 0 := by
    have point := congrArg (fun xs : List F => xs.getD j 0) source.selectors
    rw [← zero,TokenInteger.map_getD] at point
    simpa only [f,DeclarationMatrix.get,zero] using point
  have canonical := InstructionRowSound.selectors values ⟨[],(OperandRowCheck.record (ValidationEventCheck.stage events 1) i).tags,[],[],default,default,0,0,0,0⟩ _ tags
  have smallFlags := SourceProgramSound.normalized_inputs values _ _ matched.2.2.1
  simp only [List.map_cons,List.map_nil,List.cons.injEq,and_true] at smallFlags
  have all := OperandRowSound.includes_sound matrix _ _ _ (Bool.and_eq_true_iff.mp linkedRow).2 values satisfied
  have indicator := CallRowSound.indicator values one (ops.getD i 0) 14 (schedule.opcode i ib).1 (by decide) _ _ _ codeImage
    (fun g member => all g (by simp only [labelGates,List.mem_append]; exact Or.inl member))
  have filtered := all _ (by simp [labelGates] : mulGate
    (f (OperandRowCheck.record (ValidationEventCheck.stage events 1) i).tags 9)
    (((StructuredMatrix.stage r 1).program.base.operations.getD (2*i) default).call.outputs.getD 0 [])
    (f (rowAt (StructuredMatrix.stage r 2).flags i) 9) ∈ labelGates events r i)
  change E values (f (OperandRowCheck.record (ValidationEventCheck.stage events 1) i).tags 9) *
    E values (((StructuredMatrix.stage r 1).program.base.operations.getD (2*i) default).call.outputs.getD 0 []) =
    E values (f (rowAt (StructuredMatrix.stage r 2).flags i) 9) at filtered
  rw [canonical.2.2.2.2.2.2.2.2.2.1,indicator] at filtered
  refine ⟨rc,⟨?_,?_,?_,?_⟩,?_,codeImage⟩
  · exact smallFlags.1.trans canonical.1
  · exact smallFlags.2.1.trans canonical.2.1
  · exact smallFlags.2.2.trans canonical.2.2.2.2.2.2.2.1
  · change E values (f (rowAt (StructuredMatrix.stage r 2).flags i) 9) = _
    rw [← filtered]
    by_cases label : (rows.getD i default).kind = .labelCheck <;> by_cases table : ops.getD i 0 = 14 <;>
      simp only [ControlEvents.selected,flag,decide_eq_true_eq,label,table,
        true_and,false_and,and_true,and_false,ite_true,ite_false,Semiring.one_mul,Semiring.zero_mul]
  · have point := VariableSelectorCheck.point values _ _ matched.2.1 1
    have same : E values (f (rowAt (StructuredMatrix.stage r 2).rows i) 1) = E values (f (OperandRowCheck.record (ValidationEventCheck.stage events 1) i).row 1) := by
      simpa [f,DeclarationMatrix.get,List.getD,List.getElem?_take] using point
    exact same.trans source.functionIndex

#print axioms row
end ZkBuild.BranchCertificate
