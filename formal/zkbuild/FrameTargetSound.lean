import FrameDepthCheck
set_option autoImplicit false
namespace ZkBuild.FrameTargetSound
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix FrameRowCheck OperandEvents
attribute [local instance] Ring.intCast Semiring.natCast

theorem selected_depth {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (r : FrameRowCheck.Record) (checked : check matrix r = true)
    (values : Nat → F) (one : values 0=1) (satisfied : Satisfied matrix values)
    (label : Fin (2^33)) (li : E values (f r.inputs 2) = (label.val : F))
    (kind : Kind) (code : Nat) (tags : FrameSelectors.Tags values r kind)
    (cats : FrameOpcodes.Categories values r code) :
    ∃ depth : Fin (2^33), E values (f r.after 15) = (depth.val : F) := by
  obtain ⟨primary,pb,pi⟩ := FrameRowImages.bounded matrix r checked values one satisfied 1 (by decide)
  change primary<2^32 at pb
  change E values (f r.inputs 0)=(primary:F) at pi
  have facts := FrameRowSound.meaning matrix r checked values one satisfied
  have m := facts.multiply (branching r) (f r.inputs 0) 14 (by simp [multiplies])
  rw [cats.isBranching,pi] at m
  have s := facts.select (f r.flags 9) (f r.inputs 2) (f r.after 14) 15 (by simp [selects])
  rw [tags.label,li,m] at s
  by_cases k : kind=.labelCheck
  · refine ⟨label,?_⟩
    simp only [k,decide_true,flag,ite_true] at s
    grind only
  · cases b : FrameOpcodes.branches code
    · refine ⟨0,?_⟩
      simpa [flag,k,b,Semiring.zero_mul,AddCommMonoid.add_zero,Semiring.natCast_zero] using s
    · refine ⟨⟨primary,by omega⟩,?_⟩
      simpa [flag,k,b,Semiring.zero_mul,Semiring.one_mul,AddCommMonoid.add_zero] using s

theorem slot {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (r : FrameRowCheck.Record) (checked : check matrix r = true)
    (values : Nat → F) (one : values 0=1) (satisfied : Satisfied matrix values)
    (count : Fin (2^32)) (depth : Fin (2^33))
    (ci : E values (f r.before 0)=(count.val:F)) (di : E values (f r.after 15)=(depth.val:F))
    (active : E values (readActive r)=1) (returns : Bool) (ri : E values (f r.after 8)=flag returns) :
    ∃ slot : Nat, slot<count.val ∧ E values (f r.after 17)=(slot:F) ∧
      slot=(if returns then 0 else count.val-1-depth.val) ∧ (returns=false → depth.val<count.val) := by
  have facts := FrameRowSound.meaning matrix r checked values one satisfied
  obtain ⟨s,sb,si⟩ := FrameRowImages.bounded matrix r checked values one satisfied 2 (by decide)
  change s<2^32 at sb
  change E values (f r.after 17)=(s:F) at si
  have nonempty := facts.guard (readActive r) (sub o (sub o (f r.after 12))) (by simp [guards])
  have empty := facts.zero (f r.before 0) 12 (by simp [zeros])
  have positive : 0<count.val := by
    by_cases cz : count.val=0
    · simp only [ci,cz,Semiring.natCast_zero,ite_true] at empty
      simp only [eval_sub,o,eval_constant values one,Ring.intCast_one,active,empty] at nonempty
      exact False.elim (Field.zero_ne_one (α:=F) (by grind only))
    · omega
  have selected := facts.select (f r.after 8) z (sub (sub (f r.before 0) o) (f r.after 15)) 16 (by simp [selects])
  have used := facts.multiply (readActive r) (f r.after 16) 17 (by simp [multiplies])
  simp only [eval_sub,z,o,eval_constant values one,Ring.intCast_zero,Ring.intCast_one] at selected
  rw [ci,di,ri] at selected
  rw [active,Semiring.one_mul,selected] at used
  cases returns with
  | false =>
    have eq : (s:F)=(count.val:F)-1-(depth.val:F) := by
      simpa [flag,Semiring.zero_mul,AddCommMonoid.add_zero] using si.symm.trans used
    have natural : count.val=s+depth.val+1 := by
      apply (IsCharP.natCast_eq_iff_of_lt (α:=F) scalarModulus
        (Nat.lt_trans count.isLt (by decide)) (show s+depth.val+1<scalarModulus by have := depth.isLt; unfold scalarModulus; omega)).mp
      simp only [Semiring.natCast_add,Semiring.natCast_one]
      grind only
    exact ⟨s,by omega,si,by simp; omega,by intro _; omega⟩
  | true =>
    have zero : E values (f r.after 17)=0 := by simp only [flag] at used; grind only
    exact ⟨0,positive,by simpa only [Semiring.natCast_zero] using zero,by simp,by simp⟩

#print axioms selected_depth
#print axioms slot
end ZkBuild.FrameTargetSound
