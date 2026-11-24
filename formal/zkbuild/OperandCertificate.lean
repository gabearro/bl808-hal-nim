import OperandMemorySound
set_option autoImplicit false
namespace ZkBuild.OperandCertificate
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix
attribute [local instance] Ring.intCast Semiring.natCast

-- All hypotheses are decidable matrix/source certificate checks, field
-- satisfaction, and the constant-one assignment; no semantic trace is assumed.
def check (matrix : Shape) (r : ValidationEventMatrix.Record) : Bool :=
  let s := ValidationEventCheck.stage r 1
  OperandRowCheck.checkStage matrix s && decide (s.outputs.length = s.rows.length ∧ 0 < s.rows.length) &&
  ValidationEventCheck.memory matrix r.operand s.outputs 3

theorem sound {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : ValidationEventMatrix.Record) (checked : check matrix r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ rows : List OperandEvents.Row,
      OperandTraceSound.Represents values (ValidationEventCheck.stage r 1) rows ∧
      (∀ i, i < rows.length → OperandTraceSound.Transition rows i ∧
        OperandTraceSound.Projection values (ValidationEventCheck.stage r 1) rows i) ∧
      (rows.getD (rows.length-1) default).height = 0 ∧
      MemoryTrace.Reads (fun _ => none) (OperandMemorySound.projected rows) := by
  have parts : OperandRowCheck.checkStage matrix (ValidationEventCheck.stage r 1) = true ∧
      ((ValidationEventCheck.stage r 1).outputs.length = (ValidationEventCheck.stage r 1).rows.length ∧
        0 < (ValidationEventCheck.stage r 1).rows.length) ∧
      ValidationEventCheck.memory matrix r.operand (ValidationEventCheck.stage r 1).outputs 3 = true := by
    simpa only [check,Bool.and_eq_true_iff,decide_eq_true_eq,and_assoc] using checked
  obtain ⟨rows,images,steps⟩ := OperandTraceSound.trace_sound matrix _ parts.1 values one satisfied
  refine ⟨rows,images,steps,OperandTraceSound.final_height matrix _ parts.1 values one satisfied rows images
    (by rw [images.1]; exact parts.2.1.2),?_⟩
  exact OperandMemorySound.checked matrix _ r.operand parts.2.2 values one satisfied rows images
    (parts.2.1.1.trans images.1.symm) (fun i ib => (steps i ib).2)

#print axioms sound
end ZkBuild.OperandCertificate
