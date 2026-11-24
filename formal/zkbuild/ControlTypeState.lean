import ControlTypeMasks
import ControlPlans
set_option autoImplicit false
namespace ZkBuild.ControlTypeState
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix OperandEvents ControlTypeMasks
attribute [local instance] Ring.intCast Semiring.natCast

structure State where
  args : Nat := 0
  pushes : Nat := 0
  opened : Nat := 0
  closed : Nat := 0
  cleared : Nat := 0
  pending : Bool := false
  deriving Inhabited
def prepare (s : State) (kind : Kind) (code : Nat) : State :=
  if reset kind then {pending:=condition code} else s
def advance (s : State) (kind : Kind) (code : Nat) : State :=
  {args:=s.args+(selected kind .pop code && !s.pending).toNat,
   pushes:=s.pushes+(selected kind .push code).toNat,
   opened:=s.opened+(decide (kind=.controlPush)).toNat,
   closed:=s.closed+(decide (kind=.controlPop)).toNat,
   cleared:=s.cleared+(selected kind .clear code).toNat,
   pending:=s.pending && !(selected kind .pop code)}
structure Fields where
  args : Linear
  pushes : Linear
  opened : Linear
  closed : Linear
  cleared : Linear
  pending : Linear
def before (r : ControlTypeRowCheck.Record) : Fields :=
  ⟨f r.before 4,f r.before 5,f r.before 6,f r.before 7,f r.before 8,f r.before 9⟩
def ready (r : ControlTypeRowCheck.Record) : Fields :=
  ⟨f r.after 13,f r.after 14,f r.after 15,f r.after 16,f r.after 17,f r.after 18⟩
def after (r : ControlTypeRowCheck.Record) : Fields :=
  ⟨f r.after 56,f r.after 57,f r.after 59,f r.after 60,f r.after 61,f r.after 58⟩
structure Image {F : Type} [Field F] (values : Nat → F) (f : Fields) (s : State) : Prop where
  args : E values f.args=(s.args:F)
  pushes : E values f.pushes=(s.pushes:F)
  opened : E values f.opened=(s.opened:F)
  closed : E values f.closed=(s.closed:F)
  cleared : E values f.cleared=(s.cleared:F)
  pending : E values f.pending=flag s.pending

theorem prepare_image {F : Type} [Field F] [DecidableEq F]
    (values : Nat → F) (one : values 0=1) (r : ControlTypeRowCheck.Record)
    (m : ControlTypeRowSound.Meaning values r) (kind : Kind) (code : Nat)
    (masks : Masks values r kind code) (s : State) (image : Image values (before r) s) :
    Image values (ready r) (prepare s kind code) := by
  have a := m.select (ControlTypeRowCheck.reset r) z (f r.before 4) 13 (by simp [ControlTypeRowCheck.selects])
  have p := m.select (ControlTypeRowCheck.reset r) z (f r.before 5) 14 (by simp [ControlTypeRowCheck.selects])
  have o := m.select (ControlTypeRowCheck.reset r) z (f r.before 6) 15 (by simp [ControlTypeRowCheck.selects])
  have c := m.select (ControlTypeRowCheck.reset r) z (f r.before 7) 16 (by simp [ControlTypeRowCheck.selects])
  have u := m.select (ControlTypeRowCheck.reset r) z (f r.before 8) 17 (by simp [ControlTypeRowCheck.selects])
  have q := m.select (ControlTypeRowCheck.reset r) (f r.frame 10++f r.frame 15) (f r.before 9) 18 (by simp [ControlTypeRowCheck.selects])
  have ia := image.args
  have ip := image.pushes
  have io := image.opened
  have ic := image.closed
  have iu := image.cleared
  have iq := image.pending
  simp only [before] at ia ip io ic iu iq
  simp only [masks.reset,masks.condition,z,eval_constant values one,Ring.intCast_zero,ia,ip,io,ic,iu,iq] at a p o c u q
  cases hr : reset kind <;> simp only [prepare,hr,Bool.false_eq_true,ite_false,ite_true,flag] at a p o c u q ⊢
  all_goals constructor <;> simp only [ready,flag] <;> grind only [Semiring.natCast_zero]

theorem advance_image {F : Type} [Field F] [DecidableEq F]
    (values : Nat → F) (r : ControlTypeRowCheck.Record)
    (m : ControlTypeRowSound.Meaning values r) (kind : Kind) (code : Nat)
    (masks : Masks values r kind code) (tags : Tags values r kind)
    (s : State) (image : Image values (ready r) s) :
    Image values (after r) (advance s kind code) ∧
      E values (f r.after 31)=flag (selected kind .pop code && s.pending) ∧
      E values (ControlTypeRowCheck.argument r)=flag (selected kind .pop code && !s.pending) := by
  have ia := image.args
  have ip := image.pushes
  have io := image.opened
  have ic := image.closed
  have iu := image.cleared
  have iq := image.pending
  simp only [ready] at ia ip io ic iu iq
  have idx := m.multiply (f r.after 30) (f r.after 18) 31 (by simp [ControlTypeRowCheck.multiplies])
  rw [masks.pop,iq] at idx
  have index : E values (f r.after 31)=flag (selected kind .pop code && s.pending) := idx.trans (flag_and _ _)
  have argument : E values (ControlTypeRowCheck.argument r)=flag (selected kind .pop code && !s.pending) := by
    simp only [ControlTypeRowCheck.argument,eval_sub,masks.pop,index]
    cases selected kind .pop code <;> cases s.pending <;> simp [flag] <;> grind only
  have a := m.equality (f r.after 13++ControlTypeRowCheck.argument r) 56 (by simp [ControlTypeRowCheck.equalities])
  have p := m.equality (f r.after 14++f r.after 32) 57 (by simp [ControlTypeRowCheck.equalities])
  have o := m.equality (f r.after 15++f r.flags 4) 59 (by simp [ControlTypeRowCheck.equalities])
  have c := m.equality (f r.after 16++f r.flags 5) 60 (by simp [ControlTypeRowCheck.equalities])
  have u := m.equality (f r.after 17++f r.after 55) 61 (by simp [ControlTypeRowCheck.equalities])
  have q := m.equality (sub (f r.after 18) (f r.after 31)) 58 (by simp [ControlTypeRowCheck.equalities])
  simp only [eval_append,eval_sub,ia,ip,io,ic,iu,iq,
    argument,index,masks.push,masks.clear,tags.controlPush,tags.controlPop] at a p o c u q
  refine ⟨⟨?_,?_,?_,?_,?_,?_⟩,index,argument⟩
  all_goals simp only [after,advance,Semiring.natCast_add,ControlPlans.flag_cast]
  · exact a
  · exact p
  · exact o
  · exact c
  · exact u
  · rw [q]
    cases selected kind .pop code <;> cases s.pending <;> simp [flag] <;> grind only

#print axioms prepare_image
#print axioms advance_image
end ZkBuild.ControlTypeState
