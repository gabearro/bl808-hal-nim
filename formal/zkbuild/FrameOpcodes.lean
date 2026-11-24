import FrameAccessSound
set_option autoImplicit false
namespace ZkBuild.FrameOpcodes
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix FrameRowCheck OperandEvents
attribute [local instance] Ring.intCast Semiring.natCast

theorem selectors {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (r : FrameRowCheck.Record) (checked : check matrix r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (code : Nat) (bound : code < 2^16) (image : E values (f r.row 8) = (code : F)) :
    ∀ i, i < 9 → E values (f r.after i) = flag (decide (code = FrameRowCheck.codes.getD i 0)) := by
  have facts := FrameRowSound.meaning matrix r checked values one satisfied
  intro i ib
  have mem : (sub (f r.row 8) (n (FrameRowCheck.codes.getD i 0)),i) ∈ zeros r := by
    unfold zeros
    exact List.mem_append_left _ (List.mem_append_left _ (List.mem_map.mpr ⟨i,List.mem_range.mpr ib,rfl⟩))
  have selected := facts.zero _ _ mem
  have small : FrameRowCheck.codes.getD i 0 < 2^16 := by
    have choices : i=0 ∨ i=1 ∨ i=2 ∨ i=3 ∨ i=4 ∨ i=5 ∨ i=6 ∨ i=7 ∨ i=8 := by omega
    rcases choices with rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl | rfl <;> decide
  have same : (code : F) = (FrameRowCheck.codes.getD i 0 : F) ↔ code = FrameRowCheck.codes.getD i 0 :=
    IsCharP.natCast_eq_iff_of_lt (α := F) scalarModulus (Nat.lt_trans bound (by decide)) (Nat.lt_trans small (by decide))
  have diff : (code : F)-(FrameRowCheck.codes.getD i 0 : F)=0 ↔ code=FrameRowCheck.codes.getD i 0 := by
    constructor <;> intro h <;> grind only
  simpa only [eval_sub,n,eval_constant values one,Int.ofNat_eq_natCast,Ring.intCast_natCast,image,diff,flag,decide_eq_true_eq] using selected

def opens (code : Nat) : Bool := decide (code=2 ∨ code=3 ∨ code=4 ∨ code=31)
def branches (code : Nat) : Bool := decide (code=12 ∨ code=13 ∨ code=15)
def closes (code : Nat) : Bool := decide (code=5 ∨ code=11)

structure Categories {F : Type} [Field F] (values : Nat → F) (r : FrameRowCheck.Record) (code : Nat) : Prop where
  isOpening : E values (opening r) = flag (opens code)
  isBranching : E values (branching r) = flag (branches code)
  isClosing : E values (closing r) = flag (closes code)
  combined : E values (opening r++branching r++closing r) = flag (opens code || branches code || closes code)

theorem categories {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (r : FrameRowCheck.Record) (checked : check matrix r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (code : Nat) (bound : code < 2^16) (image : E values (f r.row 8) = (code : F)) :
    Categories values r code := by
  have s := selectors matrix r checked values one satisfied code bound image
  have s0 := s 0 (by decide)
  have s1 := s 1 (by decide)
  have s2 := s 2 (by decide)
  have s3 := s 3 (by decide)
  have s4 := s 4 (by decide)
  have s5 := s 5 (by decide)
  have s6 := s 6 (by decide)
  have s7 := s 7 (by decide)
  have s8 := s 8 (by decide)
  simp only [FrameRowCheck.codes,List.getD_cons_zero,List.getD_cons_succ] at s0 s1 s2 s3 s4 s5 s6 s7 s8
  constructor <;> simp only [opening,branching,closing,eval_append,s0,s1,s2,s3,s4,s5,s6,s7,s8]
  all_goals
    by_cases c2 : code=2
    · subst code; simp [opens,branches,closes,flag,AddCommMonoid.add_zero,AddCommMonoid.zero_add]
    by_cases c3 : code=3
    · subst code; simp [opens,branches,closes,flag,AddCommMonoid.add_zero,AddCommMonoid.zero_add]
    by_cases c4 : code=4
    · subst code; simp [opens,branches,closes,flag,AddCommMonoid.add_zero,AddCommMonoid.zero_add]
    by_cases c5 : code=5
    · subst code; simp [opens,branches,closes,flag,AddCommMonoid.add_zero,AddCommMonoid.zero_add]
    by_cases c11 : code=11
    · subst code; simp [opens,branches,closes,flag,AddCommMonoid.add_zero,AddCommMonoid.zero_add]
    by_cases c31 : code=31
    · subst code; simp [opens,branches,closes,flag,AddCommMonoid.add_zero,AddCommMonoid.zero_add]
    by_cases c12 : code=12
    · subst code; simp [opens,branches,closes,flag,AddCommMonoid.add_zero,AddCommMonoid.zero_add]
    by_cases c13 : code=13
    · subst code; simp [opens,branches,closes,flag,AddCommMonoid.add_zero,AddCommMonoid.zero_add]
    by_cases c15 : code=15
    · subst code; simp [opens,branches,closes,flag,AddCommMonoid.add_zero,AddCommMonoid.zero_add]
    simp [opens,branches,closes,flag,c2,c3,c4,c5,c11,c31,c12,c13,c15,AddCommMonoid.zero_add]

#print axioms selectors
#print axioms categories
end ZkBuild.FrameOpcodes
