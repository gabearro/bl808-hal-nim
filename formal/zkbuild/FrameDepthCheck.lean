import FrameSelectors
set_option autoImplicit false
namespace ZkBuild.FrameDepthCheck
open CircuitShape GadgetShape DeclarationMatrix ValidationEventMatrix

structure Record where
  input : Linear
  branch : PackedFields.Record
  handler : PackedFields.Record
  deriving Inhabited

def check (matrix : Shape) (r : Record) : Bool :=
  decide (r.branch.lowWidth=32 ∧ r.branch.highWidth=32 ∧ r.handler.lowWidth=32 ∧ r.handler.highWidth=32 ∧
    ModuleProgram.sameInputs [r.input] [r.branch.low++r.handler.high]) &&
  PackedFields.check matrix r.branch && PackedFields.check matrix r.handler

def record (splits : Splits) (tables : List ReadOnlyMatrix.Record) (r : StructuredMatrix.Record) (i : Nat) : Record :=
  let branch := StructuredMatrix.stage r 2
  let handler := StructuredMatrix.stage r 0
  ⟨f (rowAt (StructuredMatrix.stage r 3).inputs i) 2,
   splits.getD (branch.program.blocks.getD ((DynamicTypingMatrix.bank tables branch 1).entries.length+i) default).index default,
   splits.getD (handler.program.blocks.getD ((DynamicTypingMatrix.bank tables handler 1).entries.length+i) default).index default⟩

def checkStage (matrix : Shape) (splits : Splits) (tables : List ReadOnlyMatrix.Record) (r : StructuredMatrix.Record) : Bool :=
  (List.range (StructuredMatrix.stage r 3).rows.length).all (fun i => check matrix (record splits tables r i))
end ZkBuild.FrameDepthCheck

namespace ZkBuild.FrameDepthCheck
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix
attribute [local instance] Ring.intCast Semiring.natCast

theorem bounded {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : Record) (checked : check matrix r = true)
    (values : Nat → F) (one : values 0=1) (satisfied : Satisfied matrix values) :
    ∃ depth : Fin (2^33), E values r.input = (depth.val : F) := by
  have parts := checked
  simp only [check,Bool.and_eq_true_iff,decide_eq_true_eq] at parts
  obtain ⟨_,low,_,_,lb,_,_,li,_,_⟩ := PackedFields.checked_split matrix r.branch parts.1.2 values one satisfied
  obtain ⟨_,_,high,_,_,hb,_,_,hi,_⟩ := PackedFields.checked_split matrix r.handler parts.2 values one satisfied
  rw [parts.1.1.1] at lb
  rw [parts.1.1.2.2.2.1] at hb
  have linked := VariableSelectorCheck.point values _ _ parts.1.1.2.2.2.2 0
  simp only [f,DeclarationMatrix.get,List.getD_cons_zero] at linked
  refine ⟨⟨low+high,by omega⟩,?_⟩
  simpa only [eval_append,li,hi,Semiring.natCast_add] using linked

#print axioms bounded
end ZkBuild.FrameDepthCheck
