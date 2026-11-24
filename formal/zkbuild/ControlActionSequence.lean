import ControlActionLanguage
set_option autoImplicit false
namespace ZkBuild.ControlActionSequence
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix OperandEvents
attribute [local instance] Ring.intCast Semiring.natCast

def actions (rows : List Row) (start count : Nat) : List Kind :=
  (List.range count).flatMap (fun k => ControlActionLanguage.token (rows.getD (start+k) default).kind)

theorem snoc (rows : List Row) (start count : Nat) :
    actions rows start (count+1)=actions rows start count++ControlActionLanguage.token (rows.getD (start+count) default).kind := by
  simp only [actions,List.range_succ,List.flatMap_append,List.flatMap_cons,List.flatMap_nil,List.append_nil]

theorem initial (rows : List Row) (ops : List Nat) (first : Nat)
    (kind : (rows.getD first default).kind=.instructionBegin) :
    ControlTypeTrace.state rows ops (first+1)={pending:=ControlTypeMasks.condition (ops.getD first 0)} := by
  rw [ControlTypeTrace.state,kind]
  simp [ControlTypeState.prepare,ControlTypeState.advance,ControlTypeMasks.reset,ControlTypeMasks.selected]

theorem ready_interior (rows : List Row) (ops : List Nat) (first last : Nat)
    (span : InstructionSpans.Span rows first last) (i : Nat) (lo : first<i) (hi : i≤last) :
    ControlTypeTrace.ready rows ops i=ControlTypeTrace.state rows ops i := by
  have kinds := InstructionSpanState.interior rows first last span i lo hi
  simp only [ControlTypeTrace.ready,ControlTypeState.prepare,ControlTypeMasks.reset,kinds.1,kinds.2.1,or_self,
    decide_false,Bool.false_eq_true,ite_false]

theorem after_end (rows : List Row) (ops : List Nat) (first last : Nat)
    (span : InstructionSpans.Span rows first last) :
    ControlTypeTrace.state rows ops (last+1)=ControlTypeTrace.state rows ops last := by
  change ControlTypeState.advance (ControlTypeTrace.ready rows ops last) _ _ = _
  rw [ready_interior rows ops first last span last span.ordered (by omega)]
  rw [span.endKind]
  simp [ControlTypeState.advance,ControlTypeMasks.selected]

theorem segment {F : Type} [Field F]
    (values : Nat → F) (events : ValidationEventMatrix.Record) (rows : List Row) (ops : List Nat)
    (schedule : InstructionSemanticSound.Schedule values events rows ops) (guards : ControlActionGuards.Complete rows ops)
    (first last : Nat) (span : InstructionSpans.Span rows first last)
    (active : ControlTypeModes.supported (ops.getD first 0)=true)
    (count : Nat) (bound : first+1+count≤last) :
    ControlActionLanguage.Prefix (ControlTypeMasks.condition (ops.getD first 0))
      (ControlTypeTrace.state rows ops (first+1+count)) (actions rows (first+1) count) := by
  induction count with
  | zero =>
    simpa only [Nat.add_zero,actions,List.range_zero,List.flatMap_nil,initial rows ops first span.beginKind]
      using ControlActionLanguage.initial (ControlTypeMasks.condition (ops.getD first 0))
  | succ count ih =>
    have prior := ih (by omega)
    let i := first+1+count
    have lo : first<i := by dsimp [i]; omega
    have hi : i<last := by dsimp [i]; omega
    have ib : i<rows.length := by have := span.bounded; omega
    have code := InstructionSpanState.opcodes values events rows ops schedule first last span i (by omega) (by omega)
    have ready := ready_interior rows ops first last span i lo (by omega)
    have g := guards i ib (by rw [code]; exact active)
    rw [ready,code] at g
    have stepped := ControlActionLanguage.step _ _ _ _ _ active
      (ControlActionGuards.alphabet values events rows ops schedule first last span active i lo hi) prior g
    rw [snoc]
    have sum : first+1+(count+1)=i+1 := by dsimp [i]; omega
    rw [sum]
    change ControlActionLanguage.Prefix _ (ControlTypeState.advance (ControlTypeTrace.ready rows ops i) _ _) _
    rw [ready,code]
    exact stepped

def plan (code args pushes : Nat) : List Kind :=
  List.replicate ((ControlTypeMasks.condition code).toNat+args) .pop ++
    List.replicate (FrameOpcodes.closes code).toNat .controlPop ++
    List.replicate (ControlTypeGuards.opening code).toNat .controlPush ++
    List.replicate pushes .push ++ List.replicate (ControlTypeGuards.clearing code).toNat .clear

def Complete (rows : List Row) (ops : List Nat) : Prop :=
  ∀ first last, InstructionSpans.Span rows first last → ControlTypeModes.supported (ops.getD first 0)=true →
    actions rows (first+1) (last-first-1)=
      plan (ops.getD first 0) (ControlTypeTrace.state rows ops last).args (ControlTypeTrace.state rows ops last).pushes ∧
    (∀ i, first<i → i<last → ControlActionGuards.Allowed (rows.getD i default).kind (ops.getD first 0)) ∧
    (ControlTypeTrace.state rows ops last).pending=false

theorem sound {F : Type} [Field F] [DecidableEq F]
    (values : Nat → F) (splits : Splits) (events : ValidationEventMatrix.Record) (r : StructuredMatrix.Record)
    (rows : List Row) (ops : List Nat) (schedule : InstructionSemanticSound.Schedule values events rows ops)
    (facts : ControlTypeSemanticSound.Complete values splits r rows ops) : Complete rows ops := by
  intro first last span active
  have history := segment values events rows ops schedule (ControlActionGuards.trace values splits r rows ops facts)
    first last span active (last-first-1) (by have := span.ordered; omega)
  have offset : first+1+(last-first-1)=last := by have := span.ordered; omega
  rw [offset] at history
  have code := InstructionSpanState.opcodes values events rows ops schedule first last span last (by have := span.ordered; omega) (by omega)
  obtain ⟨_,_,_,_,_,_,_,_,_,_,_,_,_,finish,_⟩ := facts.2 last span.bounded
  have endActive : ControlTypeMasks.selected (rows.getD last default).kind .instructionEnd (ops.getD last 0)=true := by
    simp only [ControlTypeMasks.selected,code,active,span.endKind,decide_true,Bool.and_self]
  have terminal := finish endActive
  rw [after_end rows ops first last span,code] at terminal
  refine ⟨?_,ControlActionGuards.alphabet values events rows ops schedule first last span active,terminal.2.2.2.2.2⟩
  simpa only [ControlActionLanguage.history,plan,terminal.2.2.1,terminal.2.2.2.1,terminal.2.2.2.2.1,
    terminal.2.2.2.2.2,Bool.toNat_false,Nat.sub_zero] using history.2

#print axioms snoc
#print axioms initial
#print axioms ready_interior
#print axioms after_end
#print axioms segment
#print axioms sound
end ZkBuild.ControlActionSequence
