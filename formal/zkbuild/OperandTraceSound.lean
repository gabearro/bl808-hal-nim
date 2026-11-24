import OperandRowSound
import ValidationEventSound
set_option autoImplicit false
namespace ZkBuild.OperandTraceSound
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix
attribute [local instance] Ring.intCast Semiring.natCast

def Represents {F : Type} [Field F] (values : Nat → F) (s : Stage) (rows : List OperandEvents.Row) : Prop :=
  rows.length = s.rows.length ∧ ∀ i, i < rows.length →
    OperandRowSound.Represents values (OperandRowCheck.record s i) (rows.getD i default) ∧
    (rows.getD i default).functionIndex < 2^32 ∧ (rows.getD i default).height < 2^32 ∧
    (rows.getD i default).floor < 2^32

def Transition (rows : List OperandEvents.Row) (i : Nat) : Prop :=
  OperandEvents.StepSpec (if i = 0 then 0 else (rows.getD (i-1) default).height) (rows.getD i default)

def Projection {F : Type} [Field F] (values : Nat → F) (s : Stage) (rows : List OperandEvents.Row) (i : Nat) : Prop :=
  let row := rows.getD i default
  let access := rowAt s.outputs i
  E values (f access 0) = OperandEvents.flag (OperandEvents.project row).active ∧
  E values (f access 1) = OperandEvents.flag (OperandEvents.project row).write ∧
  E values (f access 2) = ((OperandEvents.project row).address : F) ∧
  E values (f access 3) = ((OperandEvents.project row).value : F)

theorem row_checked (matrix : Shape) (s : Stage) (checked : OperandRowCheck.checkStage matrix s = true)
    (i : Nat) (bound : i < s.rows.length) : OperandRowCheck.check matrix (OperandRowCheck.record s i) = true := by
  have checks := (Bool.and_eq_true_iff.mp checked).2
  exact (Bool.and_eq_true_iff.mp (List.all_eq_true.mp checks i (List.mem_range.mpr bound))).1

noncomputable def decodeRow {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (s : Stage) (checked : OperandRowCheck.checkStage matrix s = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (i : Nat) (bound : i < s.rows.length) : OperandEvents.Row :=
  Classical.choose (OperandRowSound.decoded matrix (OperandRowCheck.record s i)
    (row_checked matrix s checked i bound) values one satisfied)

noncomputable def decode {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (s : Stage) (checked : OperandRowCheck.checkStage matrix s = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values) : List OperandEvents.Row :=
  List.ofFn (fun i : Fin s.rows.length => decodeRow matrix s checked values one satisfied i i.isLt)

theorem decode_represents {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (s : Stage) (checked : OperandRowCheck.checkStage matrix s = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values) :
    Represents values s (decode matrix s checked values one satisfied) := by
  refine ⟨by simp [decode],?_⟩
  intro i bound
  have ib : i < s.rows.length := by simpa [decode] using bound
  have evidence := Classical.choose_spec (OperandRowSound.decoded matrix (OperandRowCheck.record s i)
    (row_checked matrix s checked i ib) values one satisfied)
  have rowEq : (decode matrix s checked values one satisfied).getD i default =
      decodeRow matrix s checked values one satisfied i ib := by
    simp [decode,List.getD,ib]
  rw [rowEq]
  exact ⟨evidence.1,evidence.2.1,evidence.2.2.1,evidence.2.2.2.1⟩

theorem trace_sound {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (s : Stage) (checked : OperandRowCheck.checkStage matrix s = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ rows : List OperandEvents.Row, Represents values s rows ∧
      ∀ i, i < rows.length → Transition rows i ∧ Projection values s rows i := by
  let rows := decode matrix s checked values one satisfied
  have reps := decode_represents matrix s checked values one satisfied
  refine ⟨rows,reps,?_⟩
  intro i bound
  have rb : i < s.rows.length := by rw [← reps.1]; exact bound
  have ri := reps.2 i bound
  let before := if i = 0 then 0 else (rows.getD (i-1) default).height
  have previous : before < 2^32 ∧ E values (OperandRowCheck.record s i).before = (before : F) := by
    by_cases first : i = 0
    · subst i
      simp [before,OperandRowCheck.record,z,eval_constant values one,Ring.intCast_zero,Semiring.natCast_zero]
    · have prior : i-1 < rows.length := by omega
      have rp := reps.2 (i-1) prior
      refine ⟨by simpa [before,first] using rp.2.2.1,?_⟩
      simpa [before,OperandRowCheck.record,first] using rp.1.height
  exact OperandRowSound.transition_of_represents matrix _ (row_checked matrix s checked i rb)
    values one satisfied before previous.1 previous.2 _ ri.1 ri.2.2.1 ri.2.2.2

theorem final_height {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (s : Stage) (checked : OperandRowCheck.checkStage matrix s = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (rows : List OperandEvents.Row) (images : Represents values s rows) (nonempty : 0 < rows.length) :
    (rows.getD (rows.length-1) default).height = 0 := by
  have closing := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp checked).1).2
  have holds := OperandRowSound.includes_sound matrix _ _ _ closing values satisfied
  have last := images.2 (rows.length-1) (by omega)
  have empty : s.rows.isEmpty = false := by
    cases h : s.rows <;> simp_all [Represents]
  simp only [empty,Bool.false_eq_true,ite_false] at holds
  have eq := equality_sound values one (f (rowAt s.rows (s.rows.length-1)) 2) z (holds _ (by simp))
  have image := last.1.height
  change E values (f (rowAt s.rows (rows.length-1)) 2) = _ at image
  rw [images.1] at image
  have zero : ((rows.getD (rows.length-1) default).height : F) = 0 := by
    rw [images.1,← image,eq]
    simpa [z,Ring.intCast_zero] using eval_constant values one 0
  exact OperandEvents.natural_eq _ 0 (by have := last.2.2.1; unfold OperandEvents.bound; omega)
    (by decide) (by simpa [Semiring.natCast_zero] using zero)

#print axioms final_height

#print axioms decode_represents
#print axioms trace_sound
end ZkBuild.OperandTraceSound
