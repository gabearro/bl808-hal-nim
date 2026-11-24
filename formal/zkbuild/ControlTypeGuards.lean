import ControlTypeTrace
import ControlTypeScalar
set_option autoImplicit false
namespace ZkBuild.ControlTypeGuards
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix OperandEvents ControlTypeState
attribute [local instance] Ring.intCast Semiring.natCast

def opening (code : Nat) := FrameOpcodes.opens code || decide (code=5)
def clearing (code : Nat) := decide (code=12 ∨ code=15)
def Bounded (s : State) := s.args<2^64 ∧ s.pushes<2^64 ∧ s.opened<2^64 ∧ s.closed<2^64 ∧ s.cleared<2^64

theorem modes {F : Type} [Field F] (values : Nat → F) (r : ControlTypeRowCheck.Record) (code : Nat)
    (m : ControlTypeModes.Flags values r code) :
    E values (f r.frame 17++f r.frame 11)=flag (opening code) ∧
    E values (f r.frame 14++f r.frame 16)=flag (clearing code) := by
  have c5 := m.opcode 3 (by decide)
  have c12 := m.opcode 6 (by decide)
  have c15 := m.opcode 8 (by decide)
  simp only [FrameRowCheck.codes,List.getD_cons_zero,List.getD_cons_succ] at c5 c12 c15
  constructor
  · simp only [eval_append,m.opening,c5]
    by_cases h : code=5
    · subst code; simp [opening,FrameOpcodes.opens,flag,AddCommMonoid.zero_add]
    · simp [opening,h,flag,AddCommMonoid.add_zero]
  · simp only [eval_append,c12,c15]
    by_cases a : code=12 <;> by_cases b : code=15 <;>
      simp [clearing,flag,a,b,AddCommMonoid.zero_add,AddCommMonoid.add_zero] <;> omega

def Finish {F : Type} [Field F] (values : Nat → F) (r : ControlTypeRowCheck.Record) (s : State) (code : Nat) : Prop :=
  E values (f r.after 23)=(s.args:F) ∧ E values (ControlTypeRowCheck.outputLength r)=(s.pushes:F) ∧
    s.opened=(opening code).toNat ∧ s.closed=(FrameOpcodes.closes code).toNat ∧
    s.cleared=(clearing code).toNat ∧ s.pending=false

theorem finish {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (values : Nat → F) (r : ControlTypeRowCheck.Record) (m : ControlTypeRowSound.Meaning values r)
    (s : State) (bounded : Bounded s) (image : Image values (after r) s)
    (code : Nat) (flags : ControlTypeModes.Flags values r code) (active : E values (f r.after 62)=1) :
    Finish values r s code := by
  have modes := modes values r code flags
  have a := m.guard (f r.after 62) (sub (f r.after 56) (f r.after 23)) (by simp [ControlTypeRowCheck.guards])
  have p := m.guard (f r.after 62) (sub (f r.after 57) (ControlTypeRowCheck.outputLength r)) (by simp [ControlTypeRowCheck.guards])
  have o := m.guard (f r.after 62) (sub (sub (f r.after 59) (f r.frame 17)) (f r.frame 11)) (by simp [ControlTypeRowCheck.guards])
  have c := m.guard (f r.after 62) (sub (f r.after 60) (f r.frame 19)) (by simp [ControlTypeRowCheck.guards])
  have u := m.guard (f r.after 62) (sub (sub (f r.after 61) (f r.frame 14)) (f r.frame 16)) (by simp [ControlTypeRowCheck.guards])
  have q := m.guard (f r.after 62) (f r.after 58) (by simp [ControlTypeRowCheck.guards])
  have ia := image.args
  have ip := image.pushes
  have io := image.opened
  have ic := image.closed
  have iu := image.cleared
  have iq := image.pending
  simp only [after] at ia ip io ic iu iq
  simp only [active,Semiring.one_mul,eval_sub,ia,ip,io,ic,iu,iq,flags.closing] at a p o c u q
  have mo := modes.1
  have mu := modes.2
  simp only [eval_append] at mo mu
  have openEq : (s.opened:F)=((opening code).toNat:F) := by rw [ControlPlans.flag_cast]; change (s.opened:F)=flag (opening code); grind only
  have closeEq : (s.closed:F)=((FrameOpcodes.closes code).toNat:F) := by rw [ControlPlans.flag_cast]; change (s.closed:F)=flag (FrameOpcodes.closes code); grind only
  have clearEq : (s.cleared:F)=((clearing code).toNat:F) := by rw [ControlPlans.flag_cast]; change (s.cleared:F)=flag (clearing code); grind only
  have bit (b : Bool) : b.toNat<2^64 := by cases b <;> decide
  refine ⟨by grind only,by grind only,
    NumericEvents.nat_eq (F:=F) _ _ bounded.2.2.1 (bit _) openEq,
    NumericEvents.nat_eq (F:=F) _ _ bounded.2.2.2.1 (bit _) closeEq,
    NumericEvents.nat_eq (F:=F) _ _ bounded.2.2.2.2 (bit _) clearEq,?_⟩
  cases h : s.pending
  · rfl
  · simp only [h,flag,ite_true] at q
    exact False.elim (Field.zero_ne_one q.symm)

theorem pop_order {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (values : Nat → F) (r : ControlTypeRowCheck.Record) (m : ControlTypeRowSound.Meaning values r)
    (s : State) (bounded : Bounded s) (image : Image values (ControlTypeState.ready r) s)
    (active : E values (f r.after 30)=1) : s.pushes=0 ∧ s.opened=0 ∧ s.closed=0 ∧ s.cleared=0 := by
  have h := m.guard (f r.after 30) (f r.after 14++f r.after 15++f r.after 16++f r.after 17) (by simp [ControlTypeRowCheck.guards])
  have ip := image.pushes
  have io := image.opened
  have ic := image.closed
  have iu := image.cleared
  simp only [ControlTypeState.ready] at ip io ic iu
  simp only [active,Semiring.one_mul,eval_append,ip,io,ic,iu] at h
  have all := ControlPlans.zero_sum (F:=F) s.pushes s.opened s.closed s.cleared 0 bounded.2.1 bounded.2.2.1 bounded.2.2.2.1 bounded.2.2.2.2 (by decide)
    (by simpa only [Semiring.natCast_zero,AddCommMonoid.add_zero] using h)
  exact ⟨all.1,all.2.1,all.2.2.1,all.2.2.2.1⟩

theorem clear_order {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (values : Nat → F) (r : ControlTypeRowCheck.Record) (m : ControlTypeRowSound.Meaning values r)
    (s : State) (bounded : Bounded s) (image : Image values (ControlTypeState.ready r) s)
    (active : E values (f r.after 55)=1) :
    s.pending=false ∧ s.pushes=0 ∧ s.opened=0 ∧ s.closed=0 ∧ s.cleared=0 ∧ E values (f r.after 23)=(s.args:F) := by
  have h := m.guard (f r.after 55) (f r.after 18++f r.after 14++f r.after 15++f r.after 16++f r.after 17) (by simp [ControlTypeRowCheck.guards])
  have a := m.guard (f r.after 55) (sub (f r.after 13) (f r.after 23)) (by simp [ControlTypeRowCheck.guards])
  have ia := image.args
  have ip := image.pushes
  have io := image.opened
  have ic := image.closed
  have iu := image.cleared
  have iq := image.pending
  simp only [ControlTypeState.ready] at ia ip io ic iu iq
  simp only [active,Semiring.one_mul,eval_append,eval_sub,ia,ip,io,ic,iu,iq] at h a
  have pending : (s.pending.toNat:F)=flag s.pending := ControlPlans.flag_cast _
  have all := ControlPlans.zero_sum (F:=F) s.pending.toNat s.pushes s.opened s.closed s.cleared
    (by cases s.pending <;> decide) bounded.2.1 bounded.2.2.1 bounded.2.2.2.1 bounded.2.2.2.2 (by rw [pending]; exact h)
  exact ⟨by cases h : s.pending <;> simp_all [Bool.toNat],all.2.1,all.2.2.1,all.2.2.2.1,all.2.2.2.2,by grind only⟩


theorem push_order {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (values : Nat → F) (r : ControlTypeRowCheck.Record) (m : ControlTypeRowSound.Meaning values r)
    (s : State) (bounded : Bounded s) (image : Image values (ControlTypeState.ready r) s)
    (code : Nat) (flags : ControlTypeModes.Flags values r code) (active : E values (f r.after 32)=1) :
    s.pending=false ∧ s.cleared=0 ∧ s.opened=(opening code).toNat ∧
      s.closed=(FrameOpcodes.closes code).toNat ∧ E values (f r.after 23)=(s.args:F) := by
  have a := m.guard (f r.after 32) (sub (f r.after 13) (f r.after 23)) (by simp [ControlTypeRowCheck.guards])
  have o := m.guard (f r.after 32) (sub (sub (f r.after 15) (f r.frame 17)) (f r.frame 11)) (by simp [ControlTypeRowCheck.guards])
  have c := m.guard (f r.after 32) (sub (f r.after 16) (f r.frame 19)) (by simp [ControlTypeRowCheck.guards])
  have q := m.guard (f r.after 32) (f r.after 18++f r.after 17) (by simp [ControlTypeRowCheck.guards])
  have ia := image.args
  have io := image.opened
  have ic := image.closed
  have iu := image.cleared
  have iq := image.pending
  simp only [ControlTypeState.ready] at ia io ic iu iq
  simp only [active,Semiring.one_mul,eval_append,eval_sub,ia,io,ic,iu,iq,flags.closing] at a o c q
  have mo := (modes values r code flags).1
  simp only [eval_append] at mo
  have openEq : (s.opened:F)=((opening code).toNat:F) := by rw [ControlPlans.flag_cast]; change (s.opened:F)=flag (opening code); grind only
  have closeEq : (s.closed:F)=((FrameOpcodes.closes code).toNat:F) := by rw [ControlPlans.flag_cast]; change (s.closed:F)=flag (FrameOpcodes.closes code); grind only
  have bit (b : Bool) : b.toNat<2^64 := by cases b <;> decide
  have pending : (s.pending.toNat:F)=flag s.pending := ControlPlans.flag_cast _
  have all := ControlPlans.zero_sum (F:=F) s.pending.toNat s.cleared 0 0 0 (bit _) bounded.2.2.2.2 (by decide) (by decide) (by decide)
    (by simpa only [pending,Semiring.natCast_zero,AddCommMonoid.add_zero] using q)
  exact ⟨by cases h : s.pending <;> simp_all [Bool.toNat],all.2.1,
    NumericEvents.nat_eq (F:=F) _ _ bounded.2.2.1 (bit _) openEq,
    NumericEvents.nat_eq (F:=F) _ _ bounded.2.2.2.1 (bit _) closeEq,by grind only⟩

theorem frame_order {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (values : Nat → F) (r : ControlTypeRowCheck.Record) (m : ControlTypeRowSound.Meaning values r)
    (s : State) (bounded : Bounded s) (image : Image values (ControlTypeState.ready r) s)
    (active : E values (f r.after 53++f r.after 54)=1) :
    s.pending=false ∧ s.pushes=0 ∧ s.cleared=0 ∧ E values (f r.after 23)=(s.args:F) := by
  have a := m.guard (f r.after 53++f r.after 54) (sub (f r.after 13) (f r.after 23)) (by simp [ControlTypeRowCheck.guards])
  have q := m.guard (f r.after 53++f r.after 54) (f r.after 18++f r.after 14++f r.after 17) (by simp [ControlTypeRowCheck.guards])
  have ia := image.args
  have ip := image.pushes
  have iu := image.cleared
  have iq := image.pending
  simp only [ControlTypeState.ready] at ia ip iu iq
  simp only [active,Semiring.one_mul,eval_append,eval_sub,ia,ip,iu,iq] at a q
  have pending : (s.pending.toNat:F)=flag s.pending := ControlPlans.flag_cast _
  have all := ControlPlans.zero_sum (F:=F) s.pending.toNat s.pushes s.cleared 0 0
    (by cases s.pending <;> decide) bounded.2.1 bounded.2.2.2.2 (by decide) (by decide)
    (by simpa only [pending,Semiring.natCast_zero,AddCommMonoid.add_zero] using q)
  exact ⟨by cases h : s.pending <;> simp_all [Bool.toNat],all.2.1,all.2.2.1,by grind only⟩


theorem open_order {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (values : Nat → F) (r : ControlTypeRowCheck.Record) (m : ControlTypeRowSound.Meaning values r)
    (s : State) (bounded : Bounded s) (image : Image values (ControlTypeState.ready r) s)
    (code : Nat) (flags : ControlTypeModes.Flags values r code) (active : E values (f r.after 53)=1) :
    s.opened=0 ∧ s.closed=(decide (code=5)).toNat := by
  have o := m.guard (f r.after 53) (f r.after 15) (by simp [ControlTypeRowCheck.guards])
  have c := m.guard (f r.after 53) (sub (f r.after 16) (f r.frame 11)) (by simp [ControlTypeRowCheck.guards])
  have io := image.opened
  have ic := image.closed
  simp only [ControlTypeState.ready] at io ic
  have mode := flags.opcode 3 (by decide)
  change E values (f r.frame 11)=flag (decide (code=5)) at mode
  simp only [active,Semiring.one_mul,eval_sub,io,ic,mode] at o c
  have bit (b : Bool) : b.toNat<2^64 := by cases b <;> decide
  exact ⟨NumericEvents.nat_eq (F:=F) _ 0 bounded.2.2.1 (by decide) (by simpa only [Semiring.natCast_zero] using o),
    NumericEvents.nat_eq (F:=F) _ _ bounded.2.2.2.1 (bit _) (by rw [ControlPlans.flag_cast]; change (s.closed:F)=flag (decide (code=5)); grind only)⟩

theorem close_order {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (values : Nat → F) (r : ControlTypeRowCheck.Record) (m : ControlTypeRowSound.Meaning values r)
    (s : State) (bounded : Bounded s) (image : Image values (ControlTypeState.ready r) s)
    (active : E values (f r.after 54)=1) : s.opened=0 ∧ s.closed=0 := by
  have h := m.guard (f r.after 54) (f r.after 15++f r.after 16) (by simp [ControlTypeRowCheck.guards])
  have io := image.opened
  have ic := image.closed
  simp only [ControlTypeState.ready] at io ic
  simp only [active,Semiring.one_mul,eval_append,io,ic] at h
  have all := ControlPlans.zero_sum (F:=F) s.opened s.closed 0 0 0 bounded.2.2.1 bounded.2.2.2.1 (by decide) (by decide) (by decide)
    (by simpa only [Semiring.natCast_zero,AddCommMonoid.add_zero] using h)
  exact ⟨all.1,all.2.1⟩

#print axioms open_order
#print axioms close_order

#print axioms push_order
#print axioms frame_order

#print axioms finish
#print axioms pop_order
#print axioms clear_order

theorem clear_opcode {F : Type} [Field F] [DecidableEq F]
    (values : Nat → F) (one : values 0=1) (r : ControlTypeRowCheck.Record)
    (m : ControlTypeRowSound.Meaning values r) (code : Nat)
    (flags : ControlTypeModes.Flags values r code) (active : E values (f r.after 55)=1) :
    code=12 ∨ code=15 := by
  have h := m.guard (f r.after 55) (sub (sub o (f r.frame 14)) (f r.frame 16))
    (by simp [ControlTypeRowCheck.guards])
  have branch := flags.opcode 6 (by decide)
  have ret := flags.opcode 8 (by decide)
  change E values (f r.frame 14)=flag (decide (code=12)) at branch
  change E values (f r.frame 16)=flag (decide (code=15)) at ret
  simp only [active,eval_sub,o,eval_constant values one,Ring.intCast_one,Semiring.one_mul,branch,ret] at h
  by_cases b : code=12
  · exact Or.inl b
  · by_cases r : code=15
    · exact Or.inr r
    · simp only [b,r,decide_false,flag,Bool.false_eq_true,ite_false] at h
      have impossible : (1:F)=0 := by grind only
      exact False.elim (Field.zero_ne_one impossible.symm)

#print axioms clear_opcode
end ZkBuild.ControlTypeGuards
