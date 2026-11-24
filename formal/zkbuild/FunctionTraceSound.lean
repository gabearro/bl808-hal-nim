import ControlTraceSound
set_option autoImplicit false
namespace ZkBuild.FunctionTraceSound
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix
attribute [local instance] Ring.intCast Semiring.natCast

structure State where
  opened : Bool
  index : Nat

def state (rows : List OperandEvents.Row) (first : Nat) : Nat → State
  | 0 => ⟨false,first⟩
  | i+1 => let previous := state rows first i
    let row := rows.getD i default
    ⟨FunctionEvents.nextOpen previous.opened row.kind,FunctionEvents.nextIndex previous.index row.kind⟩

def openAt (s : Stage) (i : Nat) : Linear :=
  if i = 0 then z else (ControlRowCheck.op s (i-1) 3).call.outputs.getD 0 []
def indexAt (s : Stage) (i : Nat) : Linear :=
  if i = 0 then s.firstFunction else (ControlRowCheck.op s (i-1) 4).call.outputs.getD 0 []

theorem trace {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : ValidationEventMatrix.Record) (accepted : ControlCertificate.check matrix r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ (rows : List OperandEvents.Row) (first : Nat),
      OperandTraceSound.Represents values (ValidationEventCheck.stage r 1) rows ∧
      rows.length = (ValidationEventCheck.stage r 2).rows.length ∧
      first < 2^32 ∧ E values (ValidationEventCheck.stage r 2).firstFunction = (first : F) ∧
      (∀ i, i ≤ rows.length →
        (state rows first i).index ≤ 2^32 ∧
        E values (openAt (ValidationEventCheck.stage r 2) i) = OperandEvents.flag (state rows first i).opened ∧
        E values (indexAt (ValidationEventCheck.stage r 2) i) = ((state rows first i).index : F)) ∧
      (∀ i, i < rows.length → FunctionEvents.ScheduleOk (state rows first i).opened (rows.getD i default).kind ∧
        ((rows.getD i default).kind ≠ .padding → (rows.getD i default).functionIndex = (state rows first i).index)) := by
  let s := ValidationEventCheck.stage r 2
  have ck := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp accepted).1).2
  have firstCheck := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp ck).1).1).2
  have cert := RangeUse.checked_certificate matrix _ _ _ firstCheck values one satisfied
  obtain ⟨first,fb,fi,_⟩ := TokenInteger.certificate_nat values one _ _ _ cert
  obtain ⟨rows,images,size,rowFacts⟩ := ControlCertificate.rows matrix r accepted values one satisfied
  have invariant (i : Nat) (bound : i ≤ rows.length) :
      (state rows first i).index ≤ 2^32 ∧ E values (openAt s i) = OperandEvents.flag (state rows first i).opened ∧
      E values (indexAt s i) = ((state rows first i).index : F) := by
    induction i with
    | zero =>
      refine ⟨by simpa [state] using Nat.le_of_lt fb,?_,?_⟩
      · simp [state,openAt,z,eval_constant values one,OperandEvents.flag,Ring.intCast_zero]
      · exact fi
    | succ i ih =>
      have ib : i < rows.length := by omega
      have prior := ih (by omega)
      have current := rowFacts i ib
      have step := ControlRowSound.function_step matrix _ current.2 values one satisfied _ current.1
        (state rows first i).opened (state rows first i).index prior.2.1 prior.2.2 prior.1 (images.2 i ib).2.1
      refine ⟨step.2.2.2.2,?_,?_⟩
      · simpa [openAt,state,ControlRowCheck.record] using step.2.2.1
      · simpa [indexAt,state,ControlRowCheck.record] using step.2.2.2.1
  refine ⟨rows,first,images,size,fb,fi,invariant,?_⟩
  intro i ib
  have prior := invariant i (by omega)
  have current := rowFacts i ib
  have step := ControlRowSound.function_step matrix _ current.2 values one satisfied _ current.1
    (state rows first i).opened (state rows first i).index prior.2.1 prior.2.2 prior.1 (images.2 i ib).2.1
  exact ⟨step.1,step.2.1⟩

theorem closed {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (s : Stage) (checked : ControlRowCheck.checkStage matrix s = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (rows : List OperandEvents.Row) (first : Nat) (length : rows.length = s.rows.length)
    (openImage : E values (openAt s rows.length) = OperandEvents.flag (state rows first rows.length).opened) :
    (state rows first rows.length).opened = false := by
  have closing := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp checked).1).2
  have holds := OperandRowSound.includes_sound matrix _ _ _ closing values satisfied
  have equation := equality_sound values one
    (if s.rows.isEmpty then z else (ControlRowCheck.op s (s.rows.length-1) 3).call.outputs.getD 0 []) z
    (holds _ (by simp))
  have lhs : (if s.rows.isEmpty then z else (ControlRowCheck.op s (s.rows.length-1) 3).call.outputs.getD 0 []) = openAt s rows.length := by
    by_cases empty : rows.length = 0
    · have nil : s.rows = [] := by simpa using (length.symm.trans empty)
      simp [nil,openAt,empty]
    · have ne : s.rows.isEmpty = false := by cases h : s.rows <;> simp_all
      have nz : s.rows.length ≠ 0 := by omega
      simp only [ne,Bool.false_eq_true,ite_false,openAt,length,nz]
  rw [lhs,openImage] at equation
  have zero : OperandEvents.flag (F := F) (state rows first rows.length).opened = 0 := by
    simpa [z,eval_constant values one,Ring.intCast_zero] using equation
  cases h : (state rows first rows.length).opened
  · rfl
  · have bad : (1 : F) = 0 := by simpa [h,OperandEvents.flag] using zero
    exact False.elim (Field.zero_ne_one bad.symm)

#print axioms closed

#print axioms trace
end ZkBuild.FunctionTraceSound
