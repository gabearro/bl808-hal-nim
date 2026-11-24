import ControlTypeState
set_option autoImplicit false
namespace ZkBuild.ControlTypeTrace
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix OperandEvents ControlTypeState
attribute [local instance] Ring.intCast Semiring.natCast

def state (rows : List Row) (ops : List Nat) : Nat → State
  | 0 => {}
  | i+1 => advance (prepare (state rows ops i) (rows.getD i default).kind (ops.getD i 0)) (rows.getD i default).kind (ops.getD i 0)
def ready (rows : List Row) (ops : List Nat) (i : Nat) := prepare (state rows ops i) (rows.getD i default).kind (ops.getD i 0)
def Bounded (s : State) (i : Nat) := s.args≤i ∧ s.pushes≤i ∧ s.opened≤i ∧ s.closed≤i ∧ s.cleared≤i

theorem prepare_bounds (s : State) (kind : Kind) (code i : Nat) (bounds : Bounded s i) : Bounded (prepare s kind code) i := by
  unfold prepare
  split
  · simp [Bounded]
  · exact bounds
theorem bounds (rows : List Row) (ops : List Nat) (i : Nat) : Bounded (state rows ops i) i := by
  have bit (b : Bool) : b.toNat≤1 := by cases b <;> decide
  induction i with
  | zero => simp [state,Bounded]
  | succ i ih =>
    have prepared := prepare_bounds (state rows ops i) (rows.getD i default).kind (ops.getD i 0) i ih
    have a := bit (ControlTypeMasks.selected (rows.getD i default).kind .pop (ops.getD i 0) && !(ready rows ops i).pending)
    have p := bit (ControlTypeMasks.selected (rows.getD i default).kind .push (ops.getD i 0))
    have o := bit (decide ((rows.getD i default).kind=.controlPush))
    have c := bit (decide ((rows.getD i default).kind=.controlPop))
    have u := bit (ControlTypeMasks.selected (rows.getD i default).kind .clear (ops.getD i 0))
    simp only [state,advance,Bounded] at ⊢
    unfold Bounded at prepared
    dsimp only [ready] at a
    omega

theorem row_masks {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (splits : Splits) (events : ValidationEventMatrix.Record) (r : StructuredMatrix.Record)
    (checked : ControlTypeCertificate.check matrix splits events r=true)
    (values : Nat → F) (one : values 0=1) (satisfied : Satisfied matrix values)
    (rows : List Row) (ops : List Nat)
    (images : OperandTraceSound.Represents values (ValidationEventCheck.stage events 1) rows)
    (schedule : InstructionSemanticSound.Schedule values events rows ops) (i : Nat) (ib : i<rows.length) :
    ControlTypeMasks.Tags values (ControlTypeRowCheck.record splits (StructuredMatrix.stage r 4) i) (rows.getD i default).kind ∧
    ControlTypeMasks.Masks values (ControlTypeRowCheck.record splits (StructuredMatrix.stage r 4) i) (rows.getD i default).kind (ops.getD i 0) ∧
    ControlTypeModes.Flags values (ControlTypeRowCheck.record splits (StructuredMatrix.stage r 4) i) (ops.getD i 0) := by
  have rc := ControlTypeCertificate.row matrix splits events r checked values rows ops images schedule i ib
  have tags := ControlTypeMasks.tags values one _ _ _ rc.2.1
  have modes := ControlTypeModes.flags matrix _ _ rc.2.2.1 values one satisfied _ _ (schedule.opcode i ib).1 rc.2.1 rc.2.2.2.opcode
  exact ⟨tags,ControlTypeMasks.masks values _ _ _ (ControlTypeRowSound.meaning matrix _ rc.1 values one satisfied) tags modes,modes⟩

theorem invariant {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (splits : Splits) (events : ValidationEventMatrix.Record) (r : StructuredMatrix.Record)
    (checked : ControlTypeCertificate.check matrix splits events r=true)
    (values : Nat → F) (one : values 0=1) (satisfied : Satisfied matrix values)
    (rows : List Row) (ops : List Nat)
    (images : OperandTraceSound.Represents values (ValidationEventCheck.stage events 1) rows)
    (schedule : InstructionSemanticSound.Schedule values events rows ops) :
    ∀ i, i≤rows.length → Image values (before (ControlTypeRowCheck.record splits (StructuredMatrix.stage r 4) i)) (state rows ops i) := by
  intro i ib
  induction i with
  | zero => constructor <;> simp [before,state,ControlTypeRowCheck.record,f,DeclarationMatrix.get,z,eval_constant values one,Ring.intCast_zero,Semiring.natCast_zero,flag]
  | succ i ih =>
    have rb : i<rows.length := by omega
    have rc := ControlTypeCertificate.row matrix splits events r checked values rows ops images schedule i rb
    have masks := row_masks matrix splits events r checked values one satisfied rows ops images schedule i rb
    have m := ControlTypeRowSound.meaning matrix _ rc.1 values one satisfied
    have prepared := prepare_image values one _ m _ _ masks.2.1 (state rows ops i) (ih (by omega))
    have advanced := (advance_image values _ m _ _ masks.2.1 masks.1 _ prepared).1
    rcases advanced with ⟨a,p,o,c,u,q⟩
    constructor
    all_goals simp only [state,before,after,ControlTypeRowCheck.record,f,DeclarationMatrix.get] at a p o c u q ⊢
    all_goals first | simpa using a | simpa using p | simpa using o | simpa using c | simpa using u | simpa using q

def Facts {F : Type} [Field F] (values : Nat → F) (splits : Splits) (r : StructuredMatrix.Record)
    (rows : List Row) (ops : List Nat) : Prop :=
  ∀ i, i<rows.length →
    let row := ControlTypeRowCheck.record splits (StructuredMatrix.stage r 4) i
    Image values (before row) (state rows ops i) ∧ Image values (ControlTypeState.ready row) (ready rows ops i) ∧
    Image values (after row) (state rows ops (i+1)) ∧
    E values (f row.after 31)=flag (ControlTypeMasks.selected (rows.getD i default).kind .pop (ops.getD i 0) && (ready rows ops i).pending) ∧
    E values (ControlTypeRowCheck.argument row)=flag (ControlTypeMasks.selected (rows.getD i default).kind .pop (ops.getD i 0) && !(ready rows ops i).pending)

theorem sound {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (splits : Splits) (events : ValidationEventMatrix.Record) (r : StructuredMatrix.Record)
    (checked : ControlTypeCertificate.check matrix splits events r=true)
    (values : Nat → F) (one : values 0=1) (satisfied : Satisfied matrix values)
    (rows : List Row) (ops : List Nat)
    (images : OperandTraceSound.Represents values (ValidationEventCheck.stage events 1) rows)
    (schedule : InstructionSemanticSound.Schedule values events rows ops) : Facts values splits r rows ops := by
  have before := invariant matrix splits events r checked values one satisfied rows ops images schedule
  intro i ib
  have rc := ControlTypeCertificate.row matrix splits events r checked values rows ops images schedule i ib
  have masks := row_masks matrix splits events r checked values one satisfied rows ops images schedule i ib
  have m := ControlTypeRowSound.meaning matrix _ rc.1 values one satisfied
  have prepared := prepare_image values one _ m _ _ masks.2.1 (state rows ops i) (before i (by omega))
  exact ⟨before i (by omega),prepared,advance_image values _ m _ _ masks.2.1 masks.1 _ prepared⟩

#print axioms bounds
#print axioms invariant
#print axioms sound
end ZkBuild.ControlTypeTrace
