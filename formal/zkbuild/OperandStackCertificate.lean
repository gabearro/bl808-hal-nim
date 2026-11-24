import OperandStackTrace
set_option autoImplicit false
namespace ZkBuild.OperandStackCertificate
open Lean.Grind CircuitShape FullMatrix

def Trace (rows : List OperandEvents.Row) : Prop :=
  OperandStackTrace.stack rows rows.length = [] ∧
  (∀ i, i ≤ rows.length → (OperandStackTrace.stack rows i).length = OperandStackTrace.previousHeight rows i) ∧
  ∀ i, i < rows.length → OperandStackRefinement.PopSpec (OperandStackTrace.stack rows i) (rows.getD i default)

theorem sound {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : ValidationEventMatrix.Record) (accepted : ControlCertificate.check matrix r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ rows : List OperandEvents.Row,
      OperandTraceSound.Represents values (ValidationEventCheck.stage r 1) rows ∧ Trace rows := by
  have operand := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp accepted).1).1
  have operandStage := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp operand).1).1
  obtain ⟨rows,images,steps,finalHeight,reads⟩ := OperandCertificate.sound matrix r operand values one satisfied
  obtain ⟨functionRows,first,fnImages,fnSize,fb,fi,fnState,schedule⟩ := FunctionTraceSound.trace matrix r accepted values one satisfied
  have same := OperandRepresentationUnique.trace values _ functionRows rows fnImages images
  subst functionRows
  have boundaries (i : Nat) (ib : i < rows.length) :
      (rows.getD i default).kind = .functionBegin ∨ (rows.getD i default).kind = .functionEnd → (rows.getD i default).height = 0 := by
    have rep := images.2 i ib
    exact (OperandRowSound.boundaries matrix _ (OperandTraceSound.row_checked matrix _ operandStage i (by rw [← images.1]; exact ib))
      values one satisfied _ rep.1 rep.2.2.1 rep.2.1 rep.2.2.2).1
  have inv := OperandStackTrace.invariant rows first (fun i ib => (steps i ib).1) schedule boundaries reads
  have pops := OperandStackTrace.authenticated rows first (fun i ib => (steps i ib).1) schedule boundaries reads
  have closed := FunctionTraceSound.closed matrix _ (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp accepted).1).2
    values one satisfied rows first fnSize (fnState rows.length (by omega)).2.1
  exact ⟨rows,images,(inv rows.length (by omega)).2.2.1 closed,fun i ib => (inv i ib).1,pops⟩

#print axioms sound
end ZkBuild.OperandStackCertificate
