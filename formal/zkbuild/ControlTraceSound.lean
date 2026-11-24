import ControlCertificate
set_option autoImplicit false
namespace ZkBuild.ControlTraceSound
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix
attribute [local instance] Ring.intCast Semiring.natCast

noncomputable def depth {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (s : Stage) (checked : ControlRowCheck.checkStage matrix s = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (i : Nat) (ib : i < s.rows.length) : Nat :=
  Classical.choose (ControlRowSound.facts matrix (ControlRowCheck.record s i)
    (List.all_eq_true.mp (Bool.and_eq_true_iff.mp checked).2 i (List.mem_range.mpr ib)) values one satisfied).2.1

noncomputable def depths {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (s : Stage) (checked : ControlRowCheck.checkStage matrix s = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values) : List Nat :=
  List.ofFn (fun i : Fin s.rows.length => depth matrix s checked values one satisfied i i.isLt)

def Projection {F : Type} [Field F] (values : Nat → F) (s : Stage)
    (row : OperandEvents.Row) (before height i : Nat) : Prop :=
  let r := ControlRowCheck.record s i
  E values (f r.read 0) = OperandEvents.flag (ControlEvents.readProject before row).active ∧
  E values (f r.read 1) = 0 ∧
  E values (f r.read 2) = ((ControlEvents.readProject before row).address : F) ∧
  E values (f r.read 3) = ((ControlEvents.readProject before row).value : F) ∧
  E values (f r.write 0) = OperandEvents.flag (ControlEvents.writeProject before height row).active ∧
  E values (f r.write 1) = OperandEvents.flag (ControlEvents.writeProject before height row).write ∧
  E values (f r.write 2) = ((ControlEvents.writeProject before height row).address : F) ∧
  E values (f r.write 3) = ((ControlEvents.writeProject before height row).value : F)

theorem trace {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : ValidationEventMatrix.Record) (accepted : ControlCertificate.check matrix r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ (rows : List OperandEvents.Row) (ds : List Nat),
      OperandTraceSound.Represents values (ValidationEventCheck.stage r 1) rows ∧
      rows.length = (ValidationEventCheck.stage r 2).rows.length ∧ ds.length = rows.length ∧
      (∀ d ∈ ds, d < 2^32) ∧
      ∀ i, i < rows.length →
        ControlEvents.Spec (if i = 0 then 0 else ds.getD (i-1) 0) (ds.getD i 0) (rows.getD i default) ∧
        Projection values (ValidationEventCheck.stage r 2) (rows.getD i default)
          (if i = 0 then 0 else ds.getD (i-1) 0)
          (if i = 0 then 0 else (rows.getD (i-1) default).height) i := by
  have ck := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp accepted).1).2
  let s := ValidationEventCheck.stage r 2
  obtain ⟨rows,images,size,rowFacts⟩ := ControlCertificate.rows matrix r accepted values one satisfied
  let ds := depths matrix s ck values one satisfied
  have dsSize : ds.length = rows.length := by simp [ds,depths,s,size]
  have dp (i : Nat) (ib : i < rows.length) : ds.getD i 0 < 2^32 ∧
      E values (f (rowAt s.rows i) 7) = (ds.getD i 0 : F) := by
    have si : i < s.rows.length := by simpa [s,← size] using ib
    have choice := Classical.choose_spec (ControlRowSound.facts matrix (ControlRowCheck.record s i)
      (List.all_eq_true.mp (Bool.and_eq_true_iff.mp ck).2 i (List.mem_range.mpr si)) values one satisfied).2.1
    simpa [ds,depths,List.getD,si,depth,ControlRowCheck.record] using choice
  refine ⟨rows,ds,images,size,dsSize,?_,?_⟩
  · intro d member
    obtain ⟨i,ib,di⟩ := List.getElem_of_mem member
    have bound := (dp i (by omega)).1
    rw [← List.getElem_eq_getD (h := ib) 0,di] at bound
    exact bound
  · intro i ib
    let before := if i = 0 then 0 else ds.getD (i-1) 0
    let height := if i = 0 then 0 else (rows.getD (i-1) default).height
    have previous : before < 2^32 ∧ E values (ControlRowCheck.record s i).beforeDepth = (before : F) ∧
        E values (ControlRowCheck.record s i).beforeHeight = (height : F) := by
      by_cases first : i = 0
      · subst i
        simp [before,height,ControlRowCheck.record,z,eval_constant values one,Ring.intCast_zero,Semiring.natCast_zero]
      · have prior : i-1 < rows.length := by omega
        refine ⟨by simpa [before,first] using (dp (i-1) prior).1,?_,?_⟩
        · simpa [before,first,ControlRowCheck.record] using (dp (i-1) prior).2
        · have h := (rowFacts (i-1) prior).1.height
          simpa [height,first,ControlRowCheck.record] using h
    have current := rowFacts i ib
    obtain ⟨after,ab,ai,spec,_⟩ := ControlRowSound.step matrix _ current.2 values one satisfied before previous.1 previous.2.1
      _ current.1 (images.2 i ib).2.2.1 (images.2 i ib).2.2.2
    have equal : after = ds.getD i 0 := OperandEvents.natural_eq after _
      (by unfold OperandEvents.bound; omega) (by have := (dp i ib).1; unfold OperandEvents.bound; omega)
      (ai.symm.trans (dp i ib).2)
    refine ⟨equal ▸ spec,?_⟩
    exact ControlRowSound.accesses matrix _ current.2 values one satisfied before height previous.1 previous.2.1 previous.2.2
      _ current.1 (images.2 i ib).2.2.1 (images.2 i ib).2.2.2

theorem final_depth {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (s : Stage) (checked : ControlRowCheck.checkStage matrix s = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (nonempty : 0 < s.rows.length) :
    (depths matrix s checked values one satisfied).getD (s.rows.length-1) 0 = 0 := by
  have closing := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp checked).1).2
  have holds := OperandRowSound.includes_sound matrix _ _ _ closing values satisfied
  have empty : s.rows.isEmpty = false := by cases h : s.rows <;> simp_all
  simp only [empty,Bool.false_eq_true,ite_false] at holds
  have zero := equality_sound values one (f (rowAt s.rows (s.rows.length-1)) 7) z
    (holds _ (by simp))
  have iBound : s.rows.length-1 < s.rows.length := by omega
  have evidence := Classical.choose_spec (ControlRowSound.facts matrix (ControlRowCheck.record s (s.rows.length-1))
    (List.all_eq_true.mp (Bool.and_eq_true_iff.mp checked).2 _ (List.mem_range.mpr iBound)) values one satisfied).2.1
  have di : (depths matrix s checked values one satisfied).getD (s.rows.length-1) 0 =
      depth matrix s checked values one satisfied (s.rows.length-1) iBound := by
    simp [depths,List.getD,iBound]
  rw [di]
  apply OperandEvents.natural_eq (F := F) _ 0
    (by change Classical.choose _ < 3*OperandEvents.bound; have h := evidence.1; unfold OperandEvents.bound; omega) (by decide)
  have same : E values (f (rowAt s.rows (s.rows.length-1)) 7) =
      (depth matrix s checked values one satisfied (s.rows.length-1) iBound : F) := evidence.2
  rw [← same,zero]
  simp [z,eval_constant values one,Ring.intCast_zero,Semiring.natCast_zero]

#print axioms final_depth

#print axioms trace
end ZkBuild.ControlTraceSound
