import BranchMergeSound
import BranchCertificate
set_option autoImplicit false
namespace ZkBuild.BranchTypeCertificate
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix OperandEvents
attribute [local instance] Ring.intCast Semiring.natCast

def linked (events : ValidationEventMatrix.Record) (r : StructuredMatrix.Record) : Bool :=
  let operand := ValidationEventCheck.stage events 1
  let branch := StructuredMatrix.stage r 2
  let typed := StructuredMatrix.stage r 5
  decide (operand.rows.length = typed.rows.length ∧ events.rows.length = typed.rows.length ∧ branch.rows.length = typed.rows.length) &&
  (List.range typed.rows.length).all (fun i => decide (
    ModuleProgram.sameInputs (rowAt typed.rows i) ((rowAt events.rows i).take 10) ∧
    ModuleProgram.sameInputs ((rowAt typed.rows i).take 7) (OperandRowCheck.record operand i).row ∧
    ModuleProgram.sameInputs ([0,1,2,3,4,5,6,7,8,10].map (f (rowAt typed.flags i)))
      ([0,1,2,3,4,5,6,7,8,10].map (f (OperandRowCheck.record operand i).tags)) ∧
    ModuleProgram.sameInputs [f (rowAt typed.flags i) 9] [f (rowAt branch.flags i) 9] ∧
    ModuleProgram.sameInputs (rowAt typed.inputs i) [f (rowAt branch.outputs i) 1] ∧
    ModuleProgram.sameInputs (rowAt typed.selectors i) (rowAt (StructuredMatrix.stage r 3).outputs i)))

def check (matrix : Shape) (splits : Splits) (tables : List ReadOnlyMatrix.Record)
    (statics : StaticCatalog) (events : ValidationEventMatrix.Record) (r : StructuredMatrix.Record) : Bool :=
  BranchCertificate.check matrix splits tables statics events r &&
  BranchTypeRowCheck.checkStage matrix splits r.scratch (StructuredMatrix.stage r 5) &&
  BranchMergeCheck.checkStage matrix r && linked events r

structure Tags {F : Type} [Field F] (values : Nat → F) (r : BranchTypeRowCheck.Record) (kind : Kind) (code : Nat) : Prop where
  functionBegin : E values (f r.flags 0) = flag (decide (kind = .functionBegin))
  instructionBegin : E values (f r.flags 1) = flag (decide (kind = .instructionBegin))
  push : E values (f r.flags 2) = flag (decide (kind = .push))
  pop : E values (f r.flags 3) = flag (decide (kind = .pop))
  clear : E values (f r.flags 6) = flag (decide (kind = .clear))
  instructionEnd : E values (f r.flags 7) = flag (decide (kind = .instructionEnd))
  label : E values (f r.flags 9) = flag (decide (kind = .labelCheck ∧ code = 14))

theorem row {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (splits : Splits) (tables : List ReadOnlyMatrix.Record)
    (statics : StaticCatalog) (events : ValidationEventMatrix.Record) (r : StructuredMatrix.Record)
    (checked : check matrix splits tables statics events r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (rows : List Row) (ops : List Nat)
    (images : OperandTraceSound.Represents values (ValidationEventCheck.stage events 1) rows)
    (schedule : InstructionSemanticSound.Schedule values events rows ops) (i : Nat) (ib : i < rows.length) :
    BranchTypeRowCheck.check matrix (BranchTypeRowCheck.record splits r.scratch (StructuredMatrix.stage r 5) i) = true ∧
    Tags values (BranchTypeRowCheck.record splits r.scratch (StructuredMatrix.stage r 5) i) (rows.getD i default).kind (ops.getD i 0) ∧
    E values (f (rowAt (StructuredMatrix.stage r 5).rows i) 4) = ((rows.getD i default).valueType.val : F) ∧
    E values (f (rowAt (StructuredMatrix.stage r 5).rows i) 8) = (ops.getD i 0 : F) := by
  have parts := checked
  simp only [check,Bool.and_eq_true_iff] at parts
  have links := parts.2
  simp only [linked,Bool.and_eq_true_iff,decide_eq_true_eq] at links
  have size : rows.length = (StructuredMatrix.stage r 5).rows.length := images.1.trans links.1.1
  have matched := _root_.of_decide_eq_true (List.all_eq_true.mp links.2 i (List.mem_range.mpr (by omega)))
  have source := (images.2 i ib).1
  have zero : E values z = 0 := by simpa [z,Ring.intCast_zero] using eval_constant values one 0
  have tags (j : Nat) : E values (f (OperandRowCheck.record (ValidationEventCheck.stage events 1) i).tags j) =
      (EventSelectors.codes.map (fun c => flag (F := F) (decide (c = kindCode (rows.getD i default).kind)))).getD j 0 := by
    have point := congrArg (fun xs : List F => xs.getD j 0) source.selectors
    rw [← zero,TokenInteger.map_getD] at point
    simpa only [f,DeclarationMatrix.get,zero] using point
  have canonical := InstructionRowSound.selectors values ⟨[],(OperandRowCheck.record (ValidationEventCheck.stage events 1) i).tags,[],[],default,default,0,0,0,0⟩ _ tags
  have fields := SourceProgramSound.normalized_inputs values _ _ matched.2.2.1
  simp only [List.map_cons,List.map_nil,List.cons.injEq,and_true] at fields
  have branch := BranchCertificate.row matrix splits tables statics events r parts.1.1.1 values one satisfied rows ops images schedule i ib
  have label := VariableSelectorCheck.point values _ _ matched.2.2.2.1 0
  simp only [f,DeclarationMatrix.get,List.getD_cons_zero] at label
  have value := VariableSelectorCheck.point values _ _ matched.2.1 4
  have opcode := VariableSelectorCheck.point values _ _ matched.1 8
  have actual : E values (f (rowAt (StructuredMatrix.stage r 5).rows i) 4) = ((rows.getD i default).valueType.val : F) := by
    have same : E values (f (rowAt (StructuredMatrix.stage r 5).rows i) 4) = E values (f (OperandRowCheck.record (ValidationEventCheck.stage events 1) i).row 4) := by
      simpa [f,DeclarationMatrix.get,List.getD,List.getElem?_take] using value
    exact same.trans source.valueType
  have code : E values (f (rowAt (StructuredMatrix.stage r 5).rows i) 8) = (ops.getD i 0 : F) := by
    have same : E values (f (rowAt (StructuredMatrix.stage r 5).rows i) 8) = E values (f (rowAt events.rows i) 8) := by
      simpa [f,DeclarationMatrix.get,List.getD,List.getElem?_take] using opcode
    exact same.trans (schedule.opcode i ib).2.1
  have rc := List.all_eq_true.mp (Bool.and_eq_true_iff.mp parts.1.1.2).2 i (List.mem_range.mpr (by omega))
  refine ⟨rc,?_,actual,code⟩
  constructor
  · exact fields.1.trans canonical.1
  · exact fields.2.1.trans canonical.2.1
  · exact fields.2.2.1.trans canonical.2.2.1
  · exact fields.2.2.2.1.trans canonical.2.2.2.1
  · exact fields.2.2.2.2.2.2.1.trans canonical.2.2.2.2.2.2.1
  · exact fields.2.2.2.2.2.2.2.1.trans canonical.2.2.2.2.2.2.2.1
  · exact label.trans branch.2.1.2.2.2

theorem terminal {F : Type} [Field F] [IsCharP F scalarModulus]
    (events : ValidationEventMatrix.Record) (r : StructuredMatrix.Record) (checked : linked events r = true)
    (values : Nat → F) (i : Nat) (ib : i < (StructuredMatrix.stage r 5).rows.length) :
    E values (f (rowAt (StructuredMatrix.stage r 5).inputs i) 0) = E values (f (rowAt (StructuredMatrix.stage r 2).outputs i) 1) := by
  have matched := _root_.of_decide_eq_true (List.all_eq_true.mp (Bool.and_eq_true_iff.mp checked).2 i (List.mem_range.mpr ib))
  simpa only [f,DeclarationMatrix.get,List.getD_cons_zero] using VariableSelectorCheck.point values _ _ matched.2.2.2.2.1 0

#print axioms row
#print axioms terminal
end ZkBuild.BranchTypeCertificate
