import VariableCertificate
set_option autoImplicit false
namespace ZkBuild.VariableCountTrace
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix
attribute [local instance] Ring.intCast Semiring.natCast

def Image {F : Type} [Field F] (values : Nat → F) (s : DynamicTypingMatrix.Stage)
    (counts : InstructionCounts.Counts) (i : Nat) : Prop :=
  E values (f (VariableRowCheck.record s i).before 0) = (counts.pops : F) ∧
  E values (f (VariableRowCheck.record s i).before 1) = (counts.pushes : F)

theorem invariant {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (s : DynamicTypingMatrix.Stage) (rows : List OperandEvents.Row) (ops : List Nat)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (records : ∀ i, i < rows.length → VariableRowCheck.check matrix (VariableRowCheck.record s i) = true ∧
      VariableRowSound.Tags values (VariableRowCheck.record s i) (rows.getD i default).kind) :
    ∀ i, i ≤ rows.length → Image values s (InstructionTraceSound.state rows ops i).counts i := by
  intro i ib
  induction i with
  | zero => simp [Image,InstructionTraceSound.state,VariableRowCheck.record,f,DeclarationMatrix.get,z,
      eval_constant values one,Ring.intCast_zero,Semiring.natCast_zero]
  | succ i ih =>
    have rb : i < rows.length := by omega
    have prior := ih (by omega)
    have record := records i rb
    have counts := VariableRowSound.counts matrix _ record.1 values one satisfied _ record.2
      (InstructionTraceSound.state rows ops i).counts prior.1 prior.2
    exact ⟨by simpa [Image,InstructionTraceSound.state,VariableRowCheck.record,f,DeclarationMatrix.get] using counts.2.2.1,
      by simpa [Image,InstructionTraceSound.state,VariableRowCheck.record,f,DeclarationMatrix.get] using counts.2.2.2⟩

#print axioms invariant
end ZkBuild.VariableCountTrace
