import ControlTypeTrace
set_option autoImplicit false
namespace ZkBuild.ControlLookupMask
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix OperandEvents
attribute [local instance] Ring.intCast Semiring.natCast

def active (kind : Kind) (code : Nat) := decide (kind=.functionBegin) ||
  (decide (kind=.instructionBegin) && ControlTypeModes.supported code)

theorem images {F : Type} [Field F] [DecidableEq F]
    (values : Nat → F) (row : ControlTypeRowCheck.Record) (kind : Kind) (code : Nat)
    (m : ControlTypeRowSound.Meaning values row) (tags : ControlTypeMasks.Tags values row kind)
    (modes : ControlTypeModes.Flags values row code) :
    E values (ControlTypeRowCheck.lookup row)=flag (active kind code) ∧
      (active kind code=true → E values (ControlTypeRowCheck.reset row)=1) := by
  have enabled := m.multiply (f row.flags 1) (f row.frame 20) 0 (by simp [ControlTypeRowCheck.multiplies])
  simp only [ControlTypeRowCheck.lookup,ControlTypeRowCheck.reset,eval_append,enabled,
    tags.functionBegin,tags.instructionBegin,modes.supported]
  cases kind <;> cases h : ControlTypeModes.supported code <;>
    simp [active,h,flag,Semiring.zero_mul,Semiring.one_mul,AddCommMonoid.zero_add,AddCommMonoid.add_zero]

#print axioms images
end ZkBuild.ControlLookupMask
