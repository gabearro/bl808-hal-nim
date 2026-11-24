import InstructionRowSound
set_option autoImplicit false
namespace ZkBuild.InstructionCounts
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix
attribute [local instance] Ring.intCast Semiring.natCast

structure Counts where
  pops : Nat := 0
  pushes : Nat := 0
  clears : Nat := 0
  deriving Inhabited

def before (prior : Counts) (kind : OperandEvents.Kind) : Counts :=
  if kind = .functionBegin ∨ kind = .instructionBegin then {} else prior

def next (prior : Counts) (kind : OperandEvents.Kind) : Counts :=
  let b := before prior kind
  ⟨b.pops+(if kind = .pop then 1 else 0),b.pushes+(if kind = .push then 1 else 0),b.clears+(if kind = .clear then 1 else 0)⟩

theorem bounded (prior : Counts) (kind : OperandEvents.Kind) (n : Nat)
    (bounds : prior.pops ≤ n ∧ prior.pushes ≤ n ∧ prior.clears ≤ n) :
    (next prior kind).pops ≤ n+1 ∧ (next prior kind).pushes ≤ n+1 ∧ (next prior kind).clears ≤ n+1 := by
  cases kind <;> simp [next,before] <;> omega

theorem sound {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : InstructionRowCheck.Record) (checked : InstructionRowCheck.check matrix r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (kind : OperandEvents.Kind) (tags : InstructionRowSound.Tags values r kind) (prior : Counts)
    (popImage : E values (f r.before 4) = (prior.pops : F))
    (pushImage : E values (f r.before 5) = (prior.pushes : F))
    (clearImage : E values (f r.before 6) = (prior.clears : F)) :
    E values (f r.after 5) = ((before prior kind).pops : F) ∧
    E values (f r.after 6) = ((before prior kind).pushes : F) ∧
    E values (f r.after 7) = ((before prior kind).clears : F) ∧
    E values (f r.after 12) = ((next prior kind).pops : F) ∧
    E values (f r.after 13) = ((next prior kind).pushes : F) ∧
    E values (f r.after 14) = ((next prior kind).clears : F) := by
  have fs := InstructionRowSound.facts matrix r checked values one satisfied
  obtain ⟨t0,t1,t2,t3,_,_,t6,_,_,_,_⟩ := InstructionRowSound.selectors values r kind tags
  have h0 := select_sound values (f r.tags 0++f r.tags 1) z (f r.before 4) (f r.after 5)
    (fs.1 _ (by simp [InstructionRowCheck.resets]))
  have h1 := select_sound values (f r.tags 0++f r.tags 1) z (f r.before 5) (f r.after 6)
    (fs.1 _ (by simp [InstructionRowCheck.resets]))
  have h2 := select_sound values (f r.tags 0++f r.tags 1) z (f r.before 6) (f r.after 7)
    (fs.1 _ (by simp [InstructionRowCheck.resets]))
  have h3 := equality_sound values one (f r.after 12) (f r.after 5++f r.tags 3)
    (fs.2.1 _ (by simp [InstructionRowCheck.updates]))
  have h4 := equality_sound values one (f r.after 13) (f r.after 6++f r.tags 2)
    (fs.2.1 _ (by simp [InstructionRowCheck.updates]))
  have h5 := equality_sound values one (f r.after 14) (f r.after 7++f r.tags 6)
    (fs.2.1 _ (by simp [InstructionRowCheck.updates]))
  simp only [eval_append,z,eval_constant values one,Ring.intCast_zero,popImage,pushImage,clearImage,t0,t1,t2,t3,t6] at h0 h1 h2 h3 h4 h5
  cases k : kind <;> simp only [before,next,k,ControlEvents.selected,OperandEvents.flag,↓reduceIte,decide_true,decide_false,
    Semiring.natCast_add,Semiring.natCast_zero,Semiring.natCast_one] at h0 h1 h2 h3 h4 h5 ⊢
  all_goals constructor <;> (repeat constructor) <;> grind only

#print axioms sound
end ZkBuild.InstructionCounts
