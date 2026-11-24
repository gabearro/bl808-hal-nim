import InstructionStaticSound
import StaticTypingBounds
set_option autoImplicit false
namespace ZkBuild.StaticEventSpec
open Lean.Grind

structure Spec (rule : StaticTyping.Rule) (kind : OperandEvents.Kind) (actual : Fin 8)
    (counts : InstructionCounts.Counts) : Prop where
  pop : kind = .pop → StaticTyping.popAllowed rule counts.pops actual.val = true ∧ counts.pushes = 0
  push : kind = .push → rule.output = some actual.val ∧ counts.pops = rule.inputs.length ∧ counts.pushes = 0
  clear : kind = .clear → rule.clears = true ∧ counts.clears = 0
  finish : kind = .instructionEnd → counts.pops = rule.inputs.length ∧
    counts.pushes = StaticEvents.outputCount rule ∧ counts.clears = rule.clears.toNat
  noControlPush : kind ≠ .controlPush
  noControlPop : kind ≠ .controlPop

theorem sound {F : Type} [Field F] [IsCharP F scalarModulus]
    (opcode : Nat) (rule : StaticTyping.Rule) (signature : StaticTyping.signature opcode = some rule)
    (kind : OperandEvents.Kind) (actual : Fin 8) (index : Fin 4) (counts : InstructionCounts.Counts)
    (bounds : counts.pops < NumericEvents.countBound ∧ counts.pushes < NumericEvents.countBound ∧ counts.clears < NumericEvents.countBound)
    (gates : StaticEvents.Gates (F := F) rule kind actual index counts.pops counts.pushes counts.clears) :
    Spec rule kind actual counts := by
  have rb := StaticTypingBounds.bounds opcode rule signature
  have nc := StaticEvents.no_control rule kind actual index counts.pops counts.pushes counts.clears gates
  refine ⟨?_,?_,?_,?_,nc.1,nc.2⟩
  · intro same
    subst kind
    exact (StaticEvents.pop_sound rule actual index counts.pops counts.pushes counts.clears bounds.1 bounds.2.1 gates).2
  · intro same
    subst kind
    exact StaticEvents.push_sound rule actual index counts.pops counts.pushes counts.clears rb.1 rb.2 bounds.1 bounds.2.1 gates
  · intro same
    subst kind
    exact StaticEvents.clear_sound rule actual index counts.pops counts.pushes counts.clears bounds.2.2 gates
  · intro same
    subst kind
    exact StaticEvents.end_sound rule actual index counts.pops counts.pushes counts.clears rb.1 bounds.1 bounds.2.1 bounds.2.2 gates

#print axioms sound
end ZkBuild.StaticEventSpec
