import ParametricCertificate
import ParametricTransition
set_option autoImplicit false
namespace ZkBuild.ParametricTraceSound
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix OperandEvents ParametricState
attribute [local instance] Ring.intCast Semiring.natCast

def state (rows : List Row) (ops : List Nat) (primary : Nat → Fin (2^32)) : Nat → State
  | 0 => {}
  | i+1 => advance (prepare (state rows ops primary i) (rows.getD i default).kind (primary i).val)
      (rows.getD i default).kind (ops.getD i 0) (rows.getD i default).valueType

def ready (rows : List Row) (ops : List Nat) (primary : Nat → Fin (2^32)) (i : Nat) :=
  prepare (state rows ops primary i) (rows.getD i default).kind (primary i).val

theorem type_bound (primary : Nat) : (ParametricEvents.typeForCode primary).getD 0 < 7 := by
  cases h : ParametricEvents.typeForCode primary with
  | none => simp
  | some tag => exact ParametricEvents.type_bound primary tag h

theorem bounds (rows : List Row) (ops : List Nat) (primary : Nat → Fin (2^32)) (i : Nat) :
    (state rows ops primary i).declared < 7 ∧ (state rows ops primary i).pops ≤ i ∧ (state rows ops primary i).pushes ≤ i := by
  induction i with
  | zero => simp [state]
  | succ i ih =>
    have pb : (popping (rows.getD i default).kind (ops.getD i 0)).toNat ≤ 1 := by cases popping (rows.getD i default).kind (ops.getD i 0) <;> decide
    have qb : (pushing (rows.getD i default).kind (ops.getD i 0)).toNat ≤ 1 := by cases pushing (rows.getD i default).kind (ops.getD i 0) <;> decide
    simp only [state,advance]
    unfold prepare
    split
    · have := type_bound (primary i).val; simp only; omega
    · omega

theorem ready_bounds (rows : List Row) (ops : List Nat) (primary : Nat → Fin (2^32)) (i : Nat) :
    (ready rows ops primary i).declared < 7 ∧ (ready rows ops primary i).pops ≤ i ∧ (ready rows ops primary i).pushes ≤ i := by
  have h := bounds rows ops primary i
  unfold ready prepare
  split
  · have := type_bound (primary i).val; simp only; omega
  · exact h

theorem invariant {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (statics : StaticCatalog) (events : ValidationEventMatrix.Record)
    (checked : ParametricCertificate.check matrix statics events = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (rows : List Row) (ops : List Nat) (images : OperandTraceSound.Represents values (ValidationEventCheck.stage events 1) rows)
    (schedule : InstructionSemanticSound.Schedule values events rows ops)
    (primary : Nat → Fin (2^32))
    (inputs : ∀ i, i < rows.length → E values (ParametricRowCheck.record (ValidationEventCheck.stage events 4) i).primary = ((primary i).val : F)) :
    ∀ i, i ≤ rows.length → Image values (ParametricRowCheck.record (ValidationEventCheck.stage events 4) i).before (state rows ops primary i) := by
  have parts := checked
  simp only [ParametricCertificate.check,Bool.and_eq_true_iff] at parts
  have links := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp parts.2).1
  have size : rows.length = (ValidationEventCheck.stage events 4).rows.length := images.1.trans links.1
  have bound : rows.length < 2^64 := by
    have stageCheck := parts.1.2
    simp only [ParametricRowCheck.checkStage,Bool.and_eq_true_iff,decide_eq_true_eq] at stageCheck
    rw [size]; exact stageCheck.1.1.2
  intro i ib
  induction i with
  | zero => simp [Image,state,ParametricRowCheck.record,f,DeclarationMatrix.get,z,eval_constant values one,Ring.intCast_zero,Semiring.natCast_zero]
  | succ i ih =>
    have rb : i < rows.length := by omega
    have before := ih (by omega)
    have row := ParametricCertificate.row matrix statics events checked values one rows images i rb
    have meaning := ParametricRowSound.meaning matrix _ row.1 values one satisfied
    have prepared := ParametricState.initial_image values one _ meaning _ row.2.1 _ before (primary i) (inputs i rb)
    have ci := row.2.2.2.trans (schedule.opcode i rb).2.1
    have pb : (ready rows ops primary i).pops < 2^64 := by have := (ready_bounds rows ops primary i).2.1; omega
    have masks := ParametricTransition.masks values one _ meaning _ row.2.1 _ (schedule.opcode i rb).1 ci _ row.2.2.1 _ prepared pb
    have result := ParametricTransition.image values _ meaning _ _ _ row.2.2.1 _ prepared masks
    simpa [Image,state,ParametricState.after,ParametricRowCheck.record,f,DeclarationMatrix.get] using result

def Facts {F : Type} [Field F] (values : Nat → F) (events : ValidationEventMatrix.Record)
    (rows : List Row) (ops : List Nat) (primary : Nat → Fin (2^32)) : Prop :=
  ∀ i, i < rows.length →
    E values (ParametricRowCheck.record (ValidationEventCheck.stage events 4) i).primary = ((primary i).val : F) ∧
    E values (f (rowAt events.rows i) 10) = ((primary i).val : F) ∧
    Image values (ParametricState.ready (ParametricRowCheck.record (ValidationEventCheck.stage events 4) i)) (ready rows ops primary i) ∧
    ParametricTransition.Masks values (ParametricRowCheck.record (ValidationEventCheck.stage events 4) i)
      (ready rows ops primary i) (rows.getD i default).kind (ops.getD i 0) (rows.getD i default).valueType ∧
    ((rows.getD i default).kind = .instructionBegin → ParametricBegin.Valid (ops.getD i 0) (primary i).val)

theorem sound {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (statics : StaticCatalog) (events : ValidationEventMatrix.Record)
    (checked : ParametricCertificate.check matrix statics events = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (rows : List Row) (ops : List Nat) (images : OperandTraceSound.Represents values (ValidationEventCheck.stage events 1) rows)
    (schedule : InstructionSemanticSound.Schedule values events rows ops) :
    ∃ primary : Nat → Fin (2^32), Facts values events rows ops primary := by
  classical
  have choices (i : Nat) (ib : i < rows.length) := ParametricBegin.immediate matrix _
    (ParametricCertificate.row matrix statics events checked values one rows images i ib).1 values one satisfied
  let primary : Nat → Fin (2^32) := fun i => if h : i < rows.length then Classical.choose (choices i h) else ⟨0,by decide⟩
  have inputs (i : Nat) (ib : i < rows.length) : E values (ParametricRowCheck.record (ValidationEventCheck.stage events 4) i).primary = ((primary i).val : F) := by
    simpa only [primary,dite_eq_left ib] using Classical.choose_spec (choices i ib)
  have inv := invariant matrix statics events checked values one satisfied rows ops images schedule primary inputs
  have parts := checked
  simp only [ParametricCertificate.check,Bool.and_eq_true_iff] at parts
  have links := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp parts.2).1
  have size : rows.length = (ValidationEventCheck.stage events 4).rows.length := images.1.trans links.1
  have bound : rows.length < 2^64 := by
    have stageCheck := parts.1.2
    simp only [ParametricRowCheck.checkStage,Bool.and_eq_true_iff,decide_eq_true_eq] at stageCheck
    rw [size]; exact stageCheck.1.1.2
  refine ⟨primary,?_⟩
  intro i ib
  have row := ParametricCertificate.row matrix statics events checked values one rows images i ib
  have meaning := ParametricRowSound.meaning matrix _ row.1 values one satisfied
  have prepared := ParametricState.initial_image values one _ meaning _ row.2.1 _ (inv i (by omega)) (primary i) (inputs i ib)
  have ci := row.2.2.2.trans (schedule.opcode i ib).2.1
  have pb : (ready rows ops primary i).pops < 2^64 := by have := (ready_bounds rows ops primary i).2.1; omega
  have masks := ParametricTransition.masks values one _ meaning _ row.2.1 _ (schedule.opcode i ib).1 ci _ row.2.2.1 _ prepared pb
  have linked := _root_.of_decide_eq_true (List.all_eq_true.mp (Bool.and_eq_true_iff.mp parts.2).2 i (List.mem_range.mpr (by omega)))
  have pi := VariableSelectorCheck.point values _ _ linked.2.2.2 0
  simp only [f,DeclarationMatrix.get,List.getD_cons_zero] at pi
  refine ⟨inputs i ib,pi.symm.trans (inputs i ib),prepared,masks,?_⟩
  intro beginKind
  apply ParametricBegin.sound values one _ meaning _ _ (schedule.opcode i ib).1 ci (primary i) (inputs i ib)
  rw [← beginKind]; exact row.2.1

#print axioms bounds
#print axioms invariant
#print axioms sound
end ZkBuild.ParametricTraceSound
