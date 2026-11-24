import ControlTypeSemanticSound
import InstructionSpanState
set_option autoImplicit false
namespace ZkBuild.ControlActionGuards
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix OperandEvents
attribute [local instance] Ring.intCast Semiring.natCast

structure Spec (s : ControlTypeState.State) (kind : Kind) (code : Nat) : Prop where
  pop : kind=.pop → s.pushes=0 ∧ s.opened=0 ∧ s.closed=0 ∧ s.cleared=0
  push : kind=.push → s.pending=false ∧ s.cleared=0
  opening : kind=.controlPush → s.pending=false ∧ s.pushes=0 ∧ s.cleared=0 ∧ s.opened=0 ∧ s.closed=(decide (code=5)).toNat
  closing : kind=.controlPop → s.pending=false ∧ s.pushes=0 ∧ s.cleared=0 ∧ s.opened=0 ∧ s.closed=0
  clear : kind=.clear → s.pending=false ∧ s.pushes=0 ∧ s.opened=0 ∧ s.closed=0 ∧ s.cleared=0

theorem row {F : Type} [Field F] [DecidableEq F]
    (values : Nat → F) (r : ControlTypeRowCheck.Record) (event : Row) (code : Nat)
    (s next : ControlTypeState.State) (active : ControlTypeModes.supported code=true)
    (facts : ControlTypeSemanticSound.RowFacts values r event code s next) : Spec s event.kind code := by
  obtain ⟨_,_,_,_,_,_,_,pop,push,frame,opened,closed,clear,_⟩ := facts
  have selected (kind : Kind) (h : event.kind=kind) : ControlTypeMasks.selected event.kind kind code=true := by
    simp only [ControlTypeMasks.selected,active,h,decide_true,Bool.and_self]
  constructor
  · intro h; exact pop (selected _ h)
  · intro h; have g := push (selected _ h); exact ⟨g.1,g.2.1⟩
  · intro h
    have g := frame (by simp only [selected _ h,Bool.true_or])
    have o := opened (selected _ h)
    exact ⟨g.1,g.2.1,g.2.2.1,o.1,o.2⟩
  · intro h
    have g := frame (by simp only [selected _ h,Bool.or_true])
    have c := closed (selected _ h)
    exact ⟨g.1,g.2.1,g.2.2.1,c.1,c.2⟩
  · intro h; have g := clear (selected _ h); exact ⟨g.1,g.2.1,g.2.2.1,g.2.2.2.1,g.2.2.2.2.1⟩

def Complete (rows : List Row) (ops : List Nat) : Prop :=
  ∀ i, i<rows.length → ControlTypeModes.supported (ops.getD i 0)=true →
    Spec (ControlTypeTrace.ready rows ops i) (rows.getD i default).kind (ops.getD i 0)

theorem trace {F : Type} [Field F] [DecidableEq F]
    (values : Nat → F) (splits : Splits) (r : StructuredMatrix.Record) (rows : List Row) (ops : List Nat)
    (facts : ControlTypeSemanticSound.Complete values splits r rows ops) : Complete rows ops := by
  intro i ib active
  exact row values _ _ _ _ _ active (facts.2 i ib)

def Allowed (kind : Kind) (code : Nat) : Prop :=
  kind=.pop ∨ kind=.push ∨ kind=.controlPush ∨ kind=.controlPop ∨ kind=.clear ∨ (kind=.labelCheck ∧ code=31)

theorem alphabet {F : Type} [Field F] (values : Nat → F) (events : ValidationEventMatrix.Record)
    (rows : List Row) (ops : List Nat) (schedule : InstructionSemanticSound.Schedule values events rows ops)
    (first last : Nat) (span : InstructionSpans.Span rows first last)
    (active : ControlTypeModes.supported (ops.getD first 0)=true)
    (i : Nat) (lo : first<i) (hi : i<last) : Allowed (rows.getD i default).kind (ops.getD first 0) := by
  have middle := span.middle i lo hi
  have code := InstructionSpanState.opcodes values events rows ops schedule first last span i (by omega) (by omega)
  have label : (rows.getD i default).kind=.labelCheck → ops.getD first 0=31 := by
    intro kind
    have modes := schedule.labels i (by have := span.bounded; omega) kind
    rw [code] at modes
    rcases modes with bad | good
    · rw [bad] at active
      simp [ControlTypeModes.supported,FrameOpcodes.opens,FrameOpcodes.branches,FrameOpcodes.closes] at active
    · exact good
  cases kind : (rows.getD i default).kind <;> simp_all [Allowed,InstructionSpans.Middle]

#print axioms row
#print axioms trace
#print axioms alphabet
end ZkBuild.ControlActionGuards
