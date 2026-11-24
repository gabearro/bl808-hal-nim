import ControlTypeGuards
set_option autoImplicit false
namespace ZkBuild.ControlTypeSemanticSound
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix OperandEvents ControlTypeState ControlTypeMasks
attribute [local instance] Ring.intCast Semiring.natCast

def RowFacts {F : Type} [Field F] [DecidableEq F] (values : Nat → F) (r : ControlTypeRowCheck.Record)
    (row : Row) (code : Nat) (s next : State) : Prop :=
  ControlTypeRowSound.Meaning values r ∧ ControlTypeModes.Flags values r code ∧
  ∃ expected : Fin 8, E values r.payload.low=(expected.val:F) ∧
    ((selected row.kind .pop code && s.pending)=true → CallEvents.InputOk 0 row.valueType.val) ∧
    ((selected row.kind .pop code && !s.pending)=true → CallEvents.InputOk expected.val row.valueType.val) ∧
    (selected row.kind .push code=true → E values r.payload.low=(row.valueType.val:F)) ∧
    (selected row.kind .pop code=true → s.pushes=0 ∧ s.opened=0 ∧ s.closed=0 ∧ s.cleared=0) ∧
    (selected row.kind .push code=true → s.pending=false ∧ s.cleared=0 ∧ s.opened=(ControlTypeGuards.opening code).toNat ∧
      s.closed=(FrameOpcodes.closes code).toNat ∧ E values (f r.after 23)=(s.args:F)) ∧
    ((selected row.kind .controlPush code || selected row.kind .controlPop code)=true →
      s.pending=false ∧ s.pushes=0 ∧ s.cleared=0 ∧ E values (f r.after 23)=(s.args:F)) ∧
    (selected row.kind .controlPush code=true → s.opened=0 ∧ s.closed=(decide (code=5)).toNat) ∧
    (selected row.kind .controlPop code=true → s.opened=0 ∧ s.closed=0) ∧
    (selected row.kind .clear code=true → s.pending=false ∧ s.pushes=0 ∧ s.opened=0 ∧ s.closed=0 ∧ s.cleared=0 ∧
      E values (f r.after 23)=(s.args:F)) ∧
    (selected row.kind .instructionEnd code=true → ControlTypeGuards.Finish values r next code) ∧
    (E values r.compare.active=1 → E values r.comparison.low=E values r.payload.low) ∧
    (E values (f r.after 47)=1 → E values (f r.after 11)=E values (f r.after 12)) ∧
    (selected row.kind .clear code=true → code=12 ∨ code=15)

def Complete {F : Type} [Field F] [DecidableEq F] (values : Nat → F) (splits : Splits) (r : StructuredMatrix.Record)
    (rows : List Row) (ops : List Nat) : Prop :=
  ControlTypeTrace.Facts values splits r rows ops ∧
    ∀ i, i<rows.length → RowFacts values (ControlTypeRowCheck.record splits (StructuredMatrix.stage r 4) i)
      (rows.getD i default) (ops.getD i 0) (ControlTypeTrace.ready rows ops i) (ControlTypeTrace.state rows ops (i+1))

theorem sound {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (splits : Splits) (events : ValidationEventMatrix.Record) (r : StructuredMatrix.Record)
    (checked : ControlTypeCertificate.check matrix splits events r=true)
    (values : Nat → F) (one : values 0=1) (satisfied : Satisfied matrix values)
    (rows : List Row) (ops : List Nat)
    (images : OperandTraceSound.Represents values (ValidationEventCheck.stage events 1) rows)
    (schedule : InstructionSemanticSound.Schedule values events rows ops) : Complete values splits r rows ops := by
  have trace := ControlTypeTrace.sound matrix splits events r checked values one satisfied rows ops images schedule
  refine ⟨trace,?_⟩
  intro i ib
  have rc := ControlTypeCertificate.row matrix splits events r checked values rows ops images schedule i ib
  have masks := ControlTypeTrace.row_masks matrix splits events r checked values one satisfied rows ops images schedule i ib
  have m := ControlTypeRowSound.meaning matrix _ rc.1 values one satisfied
  have parts := checked
  simp only [ControlTypeCertificate.check,ControlTypeRowCheck.checkStage,ControlTypeCertificate.linked,
    Bool.and_eq_true_iff,decide_eq_true_eq] at parts
  have size := images.1.trans parts.2.1.1
  have bound : rows.length<2^32 := by rw [size]; exact parts.1.1.1.2.1
  have bounded (s : State) (time : Nat) (tb : time≤rows.length) (sb : ControlTypeTrace.Bounded s time) : ControlTypeGuards.Bounded s := by
    unfold ControlTypeTrace.Bounded at sb
    unfold ControlTypeGuards.Bounded
    omega
  have readyBound := bounded (ControlTypeTrace.ready rows ops i) i (by omega)
    (ControlTypeTrace.prepare_bounds _ _ _ i (ControlTypeTrace.bounds rows ops i))
  have nextBound := bounded (ControlTypeTrace.state rows ops (i+1)) (i+1) (by omega) (ControlTypeTrace.bounds rows ops (i+1))
  have state := trace i ib
  have activate (value : F) (b : Bool) (image : value=flag b) (active : b=true) : value=1 := by rw [image,active]; rfl
  have frameMask : E values (f (ControlTypeRowCheck.record splits (StructuredMatrix.stage r 4) i).after 53++
      f (ControlTypeRowCheck.record splits (StructuredMatrix.stage r 4) i).after 54)=
      flag (selected (rows.getD i default).kind .controlPush (ops.getD i 0) || selected (rows.getD i default).kind .controlPop (ops.getD i 0)) := by
    simp only [eval_append,masks.2.1.controlPush,masks.2.1.controlPop]
    cases (rows.getD i default).kind <;> cases ControlTypeModes.supported (ops.getD i 0) <;>
      simp [selected,flag,AddCommMonoid.add_zero,AddCommMonoid.zero_add]
  obtain ⟨expected,expectedImage,condition,argument⟩ := ControlTypeScalar.type_guards matrix _ rc.1 values one satisfied _ rc.2.1.actual
  refine ⟨m,masks.2.2,expected,expectedImage,?_,?_,?_,?_,?_,?_,?_,?_,?_,?_,?_,?_,?_⟩
  · intro active; exact condition (activate _ _ state.2.2.2.1 active)
  · intro active; exact argument (activate _ _ state.2.2.2.2 active)
  · intro active; exact ControlTypeScalar.output_type matrix _ rc.1 values one satisfied _ rc.2.1.actual (activate _ _ masks.2.1.push active)
  · intro active; exact ControlTypeGuards.pop_order values _ m _ readyBound state.2.1 (activate _ _ masks.2.1.pop active)
  · intro active; exact ControlTypeGuards.push_order values _ m _ readyBound state.2.1 _ masks.2.2 (activate _ _ masks.2.1.push active)
  · intro active; exact ControlTypeGuards.frame_order values _ m _ readyBound state.2.1 (activate _ _ frameMask active)
  · intro active; exact ControlTypeGuards.open_order values _ m _ readyBound state.2.1 _ masks.2.2 (activate _ _ masks.2.1.controlPush active)
  · intro active; exact ControlTypeGuards.close_order values _ m _ readyBound state.2.1 (activate _ _ masks.2.1.controlPop active)
  · intro active; exact ControlTypeGuards.clear_order values _ m _ readyBound state.2.1 (activate _ _ masks.2.1.clear active)
  · intro active; exact ControlTypeGuards.finish values _ m _ nextBound state.2.2.1 _ masks.2.2 (activate _ _ masks.2.1.finish active)
  · exact ControlTypeScalar.implicit_else_member matrix _ rc.1 values one satisfied
  · exact ControlTypeScalar.implicit_else_lengths matrix _ rc.1 values one satisfied
  · intro active; exact ControlTypeGuards.clear_opcode values one _ m _ masks.2.2 (activate _ _ masks.2.1.clear active)

#print axioms sound
end ZkBuild.ControlTypeSemanticSound
