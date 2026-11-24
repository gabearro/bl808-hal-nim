import ParametricTraceSound
import ParametricGuardCounts
import ParametricGuardTypes
set_option autoImplicit false
namespace ZkBuild.ParametricSemanticSound
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix OperandEvents ParametricState
attribute [local instance] Ring.intCast Semiring.natCast

def Trace (rows : List Row) (ops : List Nat) (primary : Nat → Fin (2^32)) : Prop :=
  ∀ i, i < rows.length →
    ParametricGuardCounts.Spec (ParametricTraceSound.ready rows ops primary i) (rows.getD i default).kind (ops.getD i 0) (rows.getD i default).valueType ∧
    ParametricGuardTypes.Spec (ParametricTraceSound.ready rows ops primary i) (rows.getD i default).kind (ops.getD i 0) (rows.getD i default).valueType

theorem sound {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (statics : StaticCatalog) (events : ValidationEventMatrix.Record)
    (checked : ParametricCertificate.check matrix statics events = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (rows : List Row) (ops : List Nat) (images : OperandTraceSound.Represents values (ValidationEventCheck.stage events 1) rows)
    (schedule : InstructionSemanticSound.Schedule values events rows ops) :
    ∃ primary : Nat → Fin (2^32), ParametricTraceSound.Facts values events rows ops primary ∧ Trace rows ops primary := by
  obtain ⟨primary,facts⟩ := ParametricTraceSound.sound matrix statics events checked values one satisfied rows ops images schedule
  have parts := checked
  simp only [ParametricCertificate.check,Bool.and_eq_true_iff] at parts
  have links := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp parts.2).1
  have size : rows.length = (ValidationEventCheck.stage events 4).rows.length := images.1.trans links.1
  have bound : rows.length < 2^64 := by
    have stageCheck := parts.1.2
    simp only [ParametricRowCheck.checkStage,Bool.and_eq_true_iff,decide_eq_true_eq] at stageCheck
    rw [size]; exact stageCheck.1.1.2
  refine ⟨primary,facts,?_⟩
  intro i ib
  have row := ParametricCertificate.row matrix statics events checked values one rows images i ib
  have meaning := ParametricRowSound.meaning matrix _ row.1 values one satisfied
  have ci := row.2.2.2.trans (schedule.opcode i ib).2.1
  have bounds := ParametricTraceSound.ready_bounds rows ops primary i
  have image := (facts i ib).2.2.1
  have masks := (facts i ib).2.2.2.1
  exact ⟨ParametricGuardCounts.sound values one _ meaning _ row.2.1 _ (schedule.opcode i ib).1 ci _ row.2.2.1 _ image (by omega) (by omega) masks,
    ParametricGuardTypes.sound values one _ meaning _ _ (schedule.opcode i ib).1 ci _ row.2.2.1 _ image bounds.1 masks⟩

#print axioms sound
end ZkBuild.ParametricSemanticSound
