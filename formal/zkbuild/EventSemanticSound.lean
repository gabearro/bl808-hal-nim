import ControlMemorySound
import FunctionTraceSound
set_option autoImplicit false
namespace ZkBuild.EventSemanticSound
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix
attribute [local instance] Ring.intCast Semiring.natCast

def check (matrix : Shape) (r : ValidationEventMatrix.Record) : Bool :=
  ControlCertificate.check matrix r &&
  ValidationEventCheck.memory matrix r.control (ValidationEventCheck.stage r 2).outputs 33 &&
  decide ((ValidationEventCheck.stage r 2).outputs.length = 2*(ValidationEventCheck.stage r 2).rows.length)

theorem control {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : ValidationEventMatrix.Record) (accepted : check matrix r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ (rows : List OperandEvents.Row) (ds : List Nat),
      OperandTraceSound.Represents values (ValidationEventCheck.stage r 1) rows ∧
      rows.length = (ValidationEventCheck.stage r 2).rows.length ∧ ds.length = rows.length ∧
      (∀ i, i < rows.length →
        ControlEvents.Spec (if i = 0 then 0 else ds.getD (i-1) 0) (ds.getD i 0) (rows.getD i default) ∧
        ControlTraceSound.Projection values (ValidationEventCheck.stage r 2) (rows.getD i default)
          (if i = 0 then 0 else ds.getD (i-1) 0)
          (if i = 0 then 0 else (rows.getD (i-1) default).height) i) ∧
      MemoryTrace.Reads (fun _ => none) (ControlMemorySound.projected rows ds) := by
  have parts : ControlCertificate.check matrix r = true ∧
      ValidationEventCheck.memory matrix r.control (ValidationEventCheck.stage r 2).outputs 33 = true ∧
      (ValidationEventCheck.stage r 2).outputs.length = 2*(ValidationEventCheck.stage r 2).rows.length := by
    simpa only [check,Bool.and_eq_true_iff,decide_eq_true_eq,and_assoc] using accepted
  obtain ⟨rows,ds,images,size,dsSize,dsBounds,steps⟩ := ControlTraceSound.trace matrix r parts.1 values one satisfied
  refine ⟨rows,ds,images,size,dsSize,steps,?_⟩
  exact ControlMemorySound.reads matrix _ r.control parts.2.1 values one satisfied rows ds
    (by omega) dsSize (fun i ib => (images.2 i ib).2) dsBounds
    (ControlMemorySound.linked values _ rows ds (fun i ib => (steps i ib).2))

#print axioms control
end ZkBuild.EventSemanticSound
