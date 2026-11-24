import BranchTypeState
set_option autoImplicit false
namespace ZkBuild.BranchTypeTrace
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix OperandEvents BranchTypeState
attribute [local instance] Ring.intCast Semiring.natCast

def state (rows : List Row) (ops : List Nat) (data : Nat → BranchTypeData.Data) : Nat → State
  | 0 => {}
  | i+1 => advance (select (prepare (state rows ops data i) (rows.getD i default).kind)
      (rows.getD i default).kind (ops.getD i 0) i (data i)) (rows.getD i default).kind (ops.getD i 0)
      (BranchTypePending.prepare (rows.getD i default).kind (ops.getD i 0) (BranchTypePending.state rows ops i))
def ready (rows : List Row) (ops : List Nat) (data : Nat → BranchTypeData.Data) (i : Nat) : State :=
  prepare (state rows ops data i) (rows.getD i default).kind
def chosen (rows : List Row) (ops : List Nat) (data : Nat → BranchTypeData.Data) (i : Nat) : State :=
  select (ready rows ops data i) (rows.getD i default).kind (ops.getD i 0) i (data i)
def Bounded (s : State) (time : Nat) : Prop :=
  s.length < 2^32 ∧ s.arity < 2^32 ∧ s.pops ≤ time ∧ s.pushes ≤ time ∧ s.cleared ≤ time ∧ s.start ≤ time

theorem prepare_bounds (s : State) (kind : Kind) (i : Nat) (b : Bounded s i) :
    Bounded (prepare s kind) i := by
  unfold prepare
  split
  · simp [Bounded]
  · exact b

theorem select_bounds (s : State) (kind : Kind) (code i : Nat) (d : BranchTypeData.Data)
    (b : Bounded s i) :
    Bounded (select s kind code i d) (i+1) ∧
      (select s kind code i d).pops ≤ i ∧ (select s kind code i d).pushes ≤ i ∧
      (select s kind code i d).cleared ≤ i := by
  have db := d.size.isLt
  unfold select
  split
  · unfold Bounded at b ⊢
    cases sn : s.seen <;> simp only [sn,Bool.false_eq_true,ite_false,ite_true] <;> omega
  · unfold Bounded at b ⊢; omega

theorem bounds (rows : List Row) (ops : List Nat) (data : Nat → BranchTypeData.Data) (i : Nat) :
    Bounded (state rows ops data i) i := by
  have flagBound (b : Bool) : b.toNat ≤ 1 := by cases b <;> decide
  induction i with
  | zero => simp [state,Bounded]
  | succ i ih =>
    have chosen := select_bounds (prepare (state rows ops data i) (rows.getD i default).kind) (rows.getD i default).kind (ops.getD i 0) i (data i)
      (prepare_bounds (state rows ops data i) (rows.getD i default).kind i ih)
    have ap := flagBound (BranchTypePending.selected (rows.getD i default).kind .pop (ops.getD i 0) &&
      !(BranchTypePending.prepare (rows.getD i default).kind (ops.getD i 0) (BranchTypePending.state rows ops i)))
    have pp := flagBound (BranchTypePending.selected (rows.getD i default).kind .push (ops.getD i 0))
    have cp := flagBound (BranchTypePending.selected (rows.getD i default).kind .clear (ops.getD i 0))
    simp only [Bounded,state,advance]
    unfold Bounded at chosen
    omega

theorem ready_bounds (rows : List Row) (ops : List Nat) (data : Nat → BranchTypeData.Data) (i : Nat) :
    Bounded (ready rows ops data i) i :=
  prepare_bounds _ _ i (bounds rows ops data i)

theorem chosen_bounds (rows : List Row) (ops : List Nat) (data : Nat → BranchTypeData.Data) (i : Nat) :
    Bounded (chosen rows ops data i) (i+1) ∧
      (chosen rows ops data i).pops ≤ i ∧ (chosen rows ops data i).pushes ≤ i ∧ (chosen rows ops data i).cleared ≤ i :=
  select_bounds _ _ _ _ _ (ready_bounds rows ops data i)

theorem invariant {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (splits : Splits) (tables : List ReadOnlyMatrix.Record)
    (statics : StaticCatalog) (events : ValidationEventMatrix.Record) (r : StructuredMatrix.Record)
    (checked : BranchTypeCertificate.check matrix splits tables statics events r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (rows : List Row) (ops : List Nat)
    (images : OperandTraceSound.Represents values (ValidationEventCheck.stage events 1) rows)
    (schedule : InstructionSemanticSound.Schedule values events rows ops)
    (data : Nat → BranchTypeData.Data)
    (inputs : ∀ i, i < rows.length → BranchTypeData.Images values
      (BranchTypeRowCheck.record splits r.scratch (StructuredMatrix.stage r 5) i) (data i)) :
    ∀ i, i ≤ rows.length → Image values
      (BranchTypeState.before (BranchTypeRowCheck.record splits r.scratch (StructuredMatrix.stage r 5) i)) (state rows ops data i) := by
  have masks := BranchTypePending.sound matrix splits tables statics events r checked values one satisfied rows ops images schedule
  intro i ib
  induction i with
  | zero => simp [Image,BranchTypeState.before,state,BranchTypeRowCheck.record,f,DeclarationMatrix.get,z,eval_constant values one,Ring.intCast_zero,Semiring.natCast_zero,flag]
  | succ i ih =>
    have rb : i < rows.length := by omega
    have rc := BranchTypeCertificate.row matrix splits tables statics events r checked values one satisfied rows ops images schedule i rb
    have m := BranchTypeRowSound.meaning matrix _ rc.1 values one satisfied
    have reset := ready_image values one _ m _ _ rc.2.1 (state rows ops data i) (ih (by omega))
    have label := chosen_image values one _ m _ _ rc.2.1 (ready rows ops data i) reset (data i) (inputs i rb)
    have result := after_image values _ m _ _ _ (chosen rows ops data i) (masks i rb) label
    simpa [Image,state,chosen,ready,BranchTypeState.before,BranchTypeState.after,BranchTypeRowCheck.record,f,DeclarationMatrix.get] using result

def Facts {F : Type} [Field F] (values : Nat → F) (splits : Splits) (r : StructuredMatrix.Record)
    (rows : List Row) (ops : List Nat) (data : Nat → BranchTypeData.Data) : Prop :=
  ∀ i, i < rows.length →
    let row := BranchTypeRowCheck.record splits r.scratch (StructuredMatrix.stage r 5) i
    BranchTypeData.Images values row (data i) ∧
    Image values (BranchTypeState.before row) (state rows ops data i) ∧
    Image values (BranchTypeState.ready row) (ready rows ops data i) ∧
    Image values (BranchTypeState.chosen row) (chosen rows ops data i) ∧
    Image values (BranchTypeState.after row) (state rows ops data (i+1))

theorem sound {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (splits : Splits) (tables : List ReadOnlyMatrix.Record) (indexed : IndexedMatrix.Record)
    (statics : StaticCatalog) (events : ValidationEventMatrix.Record) (r : StructuredMatrix.Record)
    (checked : BranchTypeCertificate.check matrix splits tables statics events r = true)
    (lookupChecked : BranchLookupCheck.check matrix tables indexed r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (rows : List Row) (ops : List Nat)
    (images : OperandTraceSound.Represents values (ValidationEventCheck.stage events 1) rows)
    (schedule : InstructionSemanticSound.Schedule values events rows ops) :
    ∃ data : Nat → BranchTypeData.Data, Facts values splits r rows ops data := by
  classical
  have choices := BranchTypeData.exists_image matrix splits tables indexed statics events r checked lookupChecked values one satisfied rows ops images schedule
  let data : Nat → BranchTypeData.Data := fun i => if h : i < rows.length then Classical.choose (choices i h) else default
  have inputs (i : Nat) (ib : i < rows.length) : BranchTypeData.Images values
      (BranchTypeRowCheck.record splits r.scratch (StructuredMatrix.stage r 5) i) (data i) := by
    simpa only [data,dite_eq_left ib] using Classical.choose_spec (choices i ib)
  have inv := invariant matrix splits tables statics events r checked values one satisfied rows ops images schedule data inputs
  have masks := BranchTypePending.sound matrix splits tables statics events r checked values one satisfied rows ops images schedule
  refine ⟨data,?_⟩
  intro i ib
  dsimp only
  have rc := BranchTypeCertificate.row matrix splits tables statics events r checked values one satisfied rows ops images schedule i ib
  have m := BranchTypeRowSound.meaning matrix _ rc.1 values one satisfied
  have reset := ready_image values one _ m _ _ rc.2.1 (state rows ops data i) (inv i (by omega))
  have label := chosen_image values one _ m _ _ rc.2.1 (ready rows ops data i) reset (data i) (inputs i ib)
  exact ⟨inputs i ib,inv i (by omega),reset,label,
    after_image values _ m _ _ _ (chosen rows ops data i) (masks i ib) label⟩

#print axioms bounds
#print axioms ready_bounds
#print axioms chosen_bounds
#print axioms invariant
#print axioms sound
end ZkBuild.BranchTypeTrace
