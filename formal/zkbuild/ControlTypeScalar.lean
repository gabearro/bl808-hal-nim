import ControlTypeCertificate
import BranchPlans
set_option autoImplicit false
namespace ZkBuild.ControlTypeScalar
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix OperandEvents ControlTypeRowCheck
attribute [local instance] Ring.intCast Semiring.natCast

theorem indicator {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (values : Nat → F) (one : values 0 = 1) (r : ControlTypeRowCheck.Record)
    (meaning : ControlTypeRowSound.Meaning values r) (input : Linear) (value literal i : Nat)
    (vb : value < 2^64) (lb : literal < 2^64) (image : E values input = (value : F))
    (member : (sub input (n literal),i) ∈ zeros r) :
    E values (f r.after i) = flag (decide (value = literal)) := by
  have selected := meaning.zero _ _ member
  have same : (value : F) = (literal : F) ↔ value = literal :=
    IsCharP.natCast_eq_iff_of_lt (α := F) scalarModulus (Nat.lt_trans vb (by decide)) (Nat.lt_trans lb (by decide))
  have diff : (value : F)-(literal : F) = 0 ↔ value = literal := by constructor <;> intro h <;> grind only
  simpa only [eval_sub,n,eval_constant values one,show ((Int.ofNat literal : Int) : F) = (literal : F) from Ring.intCast_natCast literal,image,diff,flag,decide_eq_true_eq] using selected

theorem type_guards {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (r : ControlTypeRowCheck.Record) (checked : check matrix r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (actual : Fin 8) (image : E values (f r.row 4) = (actual.val : F)) :
    ∃ expected : Fin 8, E values r.payload.low = (expected.val : F) ∧
      (E values (f r.after 31) = 1 → CallEvents.InputOk 0 actual.val) ∧
      (E values (argument r) = 1 → CallEvents.InputOk expected.val actual.val) := by
  have m := ControlTypeRowSound.meaning matrix r checked values one satisfied
  obtain ⟨expected,_,ei,_,_⟩ := (ControlTypeRowImages.members matrix r checked values one satisfied).1
  have unknown := indicator values one r m _ actual.val 7 33 (by have := actual.isLt; omega) (by decide) image (by simp [zeros])
  have same (b : Nat) (bb : b < 8) : (actual.val : F) = (b : F) ↔ actual.val = b :=
    IsCharP.natCast_eq_iff_of_lt (α := F) scalarModulus
      (Nat.lt_trans actual.isLt (by decide)) (Nat.lt_trans bb (by decide))
  have zero : E values (f r.after 34) = flag (decide (actual.val = 0)) := by
    simpa only [image,show (actual.val : F) = 0 ↔ actual.val = 0 from by simpa only [Semiring.natCast_zero] using same 0 (by decide),flag,decide_eq_true_eq] using m.zero (f r.row 4) 34 (by simp [zeros])
  have difference : (actual.val : F)-(expected.val : F) = 0 ↔ actual.val = expected.val := by
    have eq := same expected.val expected.isLt
    constructor <;> intro h <;> grind only
  have matched : E values (f r.after 45) = flag (decide (actual.val = expected.val)) := by
    simpa only [eval_sub,image,ei,difference,flag,decide_eq_true_eq] using m.zero (sub (f r.row 4) r.payload.low) 45 (by simp [zeros])
  have condition := m.guard (f r.after 31) (sub (sub o (f r.after 33)) (f r.after 34)) (by simp [guards])
  have argument := m.guard (argument r) (sub (sub o (f r.after 33)) (f r.after 45)) (by simp [guards])
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


theorem output_type {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (r : ControlTypeRowCheck.Record) (checked : check matrix r=true)
    (values : Nat → F) (one : values 0=1) (satisfied : Satisfied matrix values)
    (actual : Fin 8) (image : E values (f r.row 4)=(actual.val:F))
    (active : E values (f r.after 32)=1) : E values r.payload.low=(actual.val:F) := by
  have m := ControlTypeRowSound.meaning matrix r checked values one satisfied
  have h := m.guard (f r.after 32) (sub (f r.row 4) r.payload.low) (by simp [guards])
  simp only [active,eval_sub,image,Semiring.one_mul] at h
  grind only

theorem implicit_else_member {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (r : ControlTypeRowCheck.Record) (checked : check matrix r=true)
    (values : Nat → F) (one : values 0=1) (satisfied : Satisfied matrix values)
    (active : E values r.compare.active=1) : E values r.comparison.low=E values r.payload.low := by
  have m := ControlTypeRowSound.meaning matrix r checked values one satisfied
  have h := m.guard r.compare.active (sub r.comparison.low r.payload.low) (by simp [guards])
  simp only [active,eval_sub,Semiring.one_mul] at h
  grind only

#print axioms type_guards
#print axioms output_type
#print axioms implicit_else_member

theorem implicit_else_lengths {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (r : ControlTypeRowCheck.Record) (checked : check matrix r=true)
    (values : Nat → F) (one : values 0=1) (satisfied : Satisfied matrix values)
    (active : E values (f r.after 47)=1) : E values (f r.after 11)=E values (f r.after 12) := by
  have m := ControlTypeRowSound.meaning matrix r checked values one satisfied
  have h := m.guard (f r.after 47) (sub (f r.after 11) (f r.after 12)) (by simp [guards])
  simp only [active,eval_sub,Semiring.one_mul] at h
  grind only

#print axioms implicit_else_lengths
end ZkBuild.ControlTypeScalar
