import BranchTypeCertificate
import BranchPlans
set_option autoImplicit false
namespace ZkBuild.BranchTypeScalar
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix OperandEvents BranchTypeRowCheck
attribute [local instance] Ring.intCast Semiring.natCast

theorem indicator {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (values : Nat → F) (one : values 0 = 1) (r : BranchTypeRowCheck.Record)
    (meaning : BranchTypeRowSound.Meaning values r) (input : Linear) (value literal i : Nat)
    (vb : value < 2^64) (lb : literal < 2^64) (image : E values input = (value : F))
    (member : (sub input (n literal),i) ∈ zeros r) :
    E values (f r.after i) = flag (decide (value = literal)) := by
  have selected := meaning.zero _ _ member
  have same : (value : F) = (literal : F) ↔ value = literal :=
    IsCharP.natCast_eq_iff_of_lt (α := F) scalarModulus (Nat.lt_trans vb (by decide)) (Nat.lt_trans lb (by decide))
  have diff : (value : F)-(literal : F) = 0 ↔ value = literal := by constructor <;> intro h <;> grind only
  simpa only [eval_sub,n,eval_constant values one,show ((Int.ofNat literal : Int) : F) = (literal : F) from Ring.intCast_natCast literal,image,diff,flag,decide_eq_true_eq] using selected

theorem type_guards {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (r : BranchTypeRowCheck.Record) (checked : check matrix r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (actual : Fin 8) (image : E values (f r.row 4) = (actual.val : F)) :
    ∃ expected : Fin 8, E values r.payload.low = (expected.val : F) ∧
      (E values (f r.after 33) = 1 → CallEvents.InputOk 0 actual.val) ∧
      (E values (argument r) = 1 → CallEvents.InputOk expected.val actual.val) := by
  have m := BranchTypeRowSound.meaning matrix r checked values one satisfied
  obtain ⟨expected,_,ei,_,_⟩ := BranchTypeRowImages.payload matrix r checked values one satisfied
  have unknown := indicator values one r m _ actual.val 7 36 (by have := actual.isLt; omega) (by decide) image (by simp [zeros])
  have same (b : Nat) (bb : b < 8) : (actual.val : F) = (b : F) ↔ actual.val = b :=
    IsCharP.natCast_eq_iff_of_lt (α := F) scalarModulus
      (Nat.lt_trans actual.isLt (by decide)) (Nat.lt_trans bb (by decide))
  have zero : E values (f r.after 37) = flag (decide (actual.val = 0)) := by
    simpa only [image,show (actual.val : F) = 0 ↔ actual.val = 0 from by simpa only [Semiring.natCast_zero] using same 0 (by decide),flag,decide_eq_true_eq] using m.zero (f r.row 4) 37 (by simp [zeros])
  have difference : (actual.val : F)-(expected.val : F) = 0 ↔ actual.val = expected.val := by
    have eq := same expected.val expected.isLt
    constructor <;> intro h <;> grind only
  have matched : E values (f r.after 43) = flag (decide (actual.val = expected.val)) := by
    simpa only [eval_sub,image,ei,difference,flag,decide_eq_true_eq] using m.zero (sub (f r.row 4) r.payload.low) 43 (by simp [zeros])
  have condition := m.guard (f r.after 33) (sub (sub o (f r.after 36)) (f r.after 37)) (by simp [guards])
  have argument := m.guard (argument r) (sub (sub o (f r.after 36)) (f r.after 43)) (by simp [guards])
  simp only [eval_sub,o,eval_constant values one,Ring.intCast_one,unknown,zero,matched] at condition argument
  refine ⟨expected,ei,?_,?_⟩
  · intro active
    rw [active] at condition
    by_cases a : actual.val = 0 <;> by_cases b : actual.val = 7 <;>
      simp [flag,a,b,CallEvents.InputOk] at condition ⊢ <;> grind only
  · intro active
    rw [active] at argument
    by_cases a : actual.val = expected.val <;> by_cases b : actual.val = 7 <;>
      simp [flag,a,b,CallEvents.InputOk] at argument ⊢ <;> grind only

theorem restore_ordinal {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (r : BranchTypeRowCheck.Record) (checked : check matrix r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (length pushed : Fin (2^32)) (li : E values (f r.after 26) = (length.val : F))
    (pi : E values (f r.after 28) = (pushed.val : F)) (push : E values (f r.after 34) = 1) :
    pushed.val < length.val ∧ E values (f r.after 44) = ((length.val-1-pushed.val : Nat) : F) := by
  have m := BranchTypeRowSound.meaning matrix r checked values one satisfied
  obtain ⟨_,_,restore,_,_,ri⟩ := BranchTypeRowImages.ranges matrix r checked values one satisfied
  have mul := m.multiply (f r.after 34) (sub (sub (f r.after 26) o) (f r.after 28)) 44 (by simp [multiplies])
  simp only [ri,push,eval_sub,li,pi,o,eval_constant values one,Ring.intCast_one,Semiring.one_mul] at mul
  have bounds := BranchPlans.reverse_guard (F := F) length.val pushed.val restore.val length.isLt pushed.isLt restore.isLt mul.symm
  exact ⟨bounds.1,by rw [ri,bounds.2]⟩

#print axioms indicator
#print axioms type_guards
#print axioms restore_ordinal
end ZkBuild.BranchTypeScalar
