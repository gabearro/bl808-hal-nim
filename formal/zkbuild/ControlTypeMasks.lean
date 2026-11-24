import ControlTypeModes
set_option autoImplicit false
namespace ZkBuild.ControlTypeMasks
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix OperandEvents
attribute [local instance] Ring.intCast Semiring.natCast

def reset (kind : Kind) := decide (kind=.functionBegin ∨ kind=.instructionBegin)
def condition (code : Nat) := decide (code=4 ∨ code=13)
def selected (kind want : Kind) (code : Nat) := ControlTypeModes.supported code && decide (kind=want)

theorem flag_and {F : Type} [Field F] (a b : Bool) : flag (F:=F) a*flag b=flag (a&&b) := by
  cases a <;> cases b <;> simp [flag,Semiring.zero_mul,Semiring.one_mul]

structure Tags {F : Type} [Field F] (values : Nat → F) (r : ControlTypeRowCheck.Record) (kind : Kind) : Prop where
  functionBegin : E values (f r.flags 0)=flag (decide (kind=.functionBegin))
  instructionBegin : E values (f r.flags 1)=flag (decide (kind=.instructionBegin))
  push : E values (f r.flags 2)=flag (decide (kind=.push))
  pop : E values (f r.flags 3)=flag (decide (kind=.pop))
  controlPush : E values (f r.flags 4)=flag (decide (kind=.controlPush))
  controlPop : E values (f r.flags 5)=flag (decide (kind=.controlPop))
  clear : E values (f r.flags 6)=flag (decide (kind=.clear))
  instructionEnd : E values (f r.flags 7)=flag (decide (kind=.instructionEnd))

theorem tags {F : Type} [Field F] (values : Nat → F) (one : values 0=1)
    (r : ControlTypeRowCheck.Record) (frame : FrameRowCheck.Record) (row : Row)
    (image : ControlTypeCertificate.Images values r frame row) : Tags values r row.kind := by
  have tag := ControlTypeCertificate.tag values one r frame row image
  constructor
  all_goals
    first | rw [tag 0] | rw [tag 1] | rw [tag 2] | rw [tag 3] | rw [tag 4] | rw [tag 5] | rw [tag 6] | rw [tag 7]
    cases row.kind <;> simp [EventSelectors.codes,kindCode]

structure Masks {F : Type} [Field F] (values : Nat → F) (r : ControlTypeRowCheck.Record) (kind : Kind) (code : Nat) : Prop where
  reset : E values (ControlTypeRowCheck.reset r)=flag (reset kind)
  condition : E values (f r.frame 10++f r.frame 15)=flag (condition code)
  pop : E values (f r.after 30)=flag (selected kind .pop code)
  push : E values (f r.after 32)=flag (selected kind .push code)
  controlPush : E values (f r.after 53)=flag (selected kind .controlPush code)
  controlPop : E values (f r.after 54)=flag (selected kind .controlPop code)
  clear : E values (f r.after 55)=flag (selected kind .clear code)
  finish : E values (f r.after 62)=flag (selected kind .instructionEnd code)

theorem masks {F : Type} [Field F] [DecidableEq F]
    (values : Nat → F) (r : ControlTypeRowCheck.Record) (kind : Kind) (code : Nat)
    (m : ControlTypeRowSound.Meaning values r) (t : Tags values r kind)
    (modes : ControlTypeModes.Flags values r code) : Masks values r kind code := by
  have c4 := modes.opcode 2 (by decide)
  have c13 := modes.opcode 7 (by decide)
  simp only [FrameRowCheck.codes,List.getD_cons_zero,List.getD_cons_succ] at c4 c13
  constructor
  · simp only [ControlTypeRowCheck.reset,eval_append,t.functionBegin,t.instructionBegin]
    cases kind <;> simp [reset,flag,AddCommMonoid.zero_add,AddCommMonoid.add_zero]
  · simp only [eval_append,c4,c13]
    by_cases a : code=4 <;> by_cases b : code=13 <;>
      simp [condition,flag,a,b,AddCommMonoid.add_zero,AddCommMonoid.zero_add] <;> omega
  all_goals
    first
    | rw [m.multiply (f r.frame 20) (f r.flags 3) 30 (by simp [ControlTypeRowCheck.multiplies]),modes.supported,t.pop]
    | rw [m.multiply (f r.frame 20) (f r.flags 2) 32 (by simp [ControlTypeRowCheck.multiplies]),modes.supported,t.push]
    | rw [m.multiply (f r.frame 20) (f r.flags 4) 53 (by simp [ControlTypeRowCheck.multiplies]),modes.supported,t.controlPush]
    | rw [m.multiply (f r.frame 20) (f r.flags 5) 54 (by simp [ControlTypeRowCheck.multiplies]),modes.supported,t.controlPop]
    | rw [m.multiply (f r.frame 20) (f r.flags 6) 55 (by simp [ControlTypeRowCheck.multiplies]),modes.supported,t.clear]
    | rw [m.multiply (f r.frame 20) (f r.flags 7) 62 (by simp [ControlTypeRowCheck.multiplies]),modes.supported,t.instructionEnd]
    exact flag_and _ _

#print axioms tags
#print axioms masks
end ZkBuild.ControlTypeMasks
