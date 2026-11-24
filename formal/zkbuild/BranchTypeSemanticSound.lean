import BranchTypeGuards
set_option autoImplicit false
namespace ZkBuild.BranchTypeSemanticSound
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix OperandEvents
attribute [local instance] Ring.intCast Semiring.natCast

def Guards (rows : List Row) (ops : List Nat) (data : Nat → BranchTypeData.Data) : Prop :=
  ∀ i, i < rows.length → BranchTypeGuards.Spec (rows.getD i default).kind (ops.getD i 0) i (data i).size.val
    (BranchTypePending.prepare (rows.getD i default).kind (ops.getD i 0) (BranchTypePending.state rows ops i))
    (BranchTypePending.state rows ops (i+1))
    (BranchTypeTrace.ready rows ops data i) (BranchTypeTrace.chosen rows ops data i) (BranchTypeTrace.state rows ops data (i+1))

theorem sound {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (splits : Splits) (tables : List ReadOnlyMatrix.Record) (indexed : IndexedMatrix.Record)
    (statics : StaticCatalog) (events : ValidationEventMatrix.Record) (r : StructuredMatrix.Record)
    (checked : BranchTypeCertificate.check matrix splits tables statics events r = true)
    (lookupChecked : BranchLookupCheck.check matrix tables indexed r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (rows : List Row) (ops : List Nat)
    (images : OperandTraceSound.Represents values (ValidationEventCheck.stage events 1) rows)
    (schedule : InstructionSemanticSound.Schedule values events rows ops) :
    ∃ data : Nat → BranchTypeData.Data, BranchTypeTrace.Facts values splits r rows ops data ∧ Guards rows ops data := by
  obtain ⟨data,facts⟩ := BranchTypeTrace.sound matrix splits tables indexed statics events r checked lookupChecked values one satisfied rows ops images schedule
  have masks := BranchTypePending.sound matrix splits tables statics events r checked values one satisfied rows ops images schedule
  have parts := checked
  simp only [BranchTypeCertificate.check,Bool.and_eq_true_iff] at parts
  have links := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp parts.2).1
  have shape := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp parts.1.1.2).1).1
  have size : rows.length = (StructuredMatrix.stage r 5).rows.length := images.1.trans links.1
  have bound : rows.length < 2^32 := by rw [size]; exact shape.2.1
  refine ⟨data,facts,?_⟩
  intro i ib
  have rc := BranchTypeCertificate.row matrix splits tables statics events r checked values one satisfied rows ops images schedule i ib
  have rbound := BranchTypeTrace.ready_bounds rows ops data i
  have cbound := (BranchTypeTrace.chosen_bounds rows ops data i).1
  have abound := BranchTypeTrace.bounds rows ops data (i+1)
  have limit (s : BranchTypeState.State) (n : Nat) (b : BranchTypeTrace.Bounded s n) (nb : n < 2^32) :
      BranchTypeTrace.Bounded s (2^32-1) := by unfold BranchTypeTrace.Bounded at b ⊢; omega
  have f := facts i ib
  exact BranchTypeGuards.sound matrix _ rc.1 values one satisfied _ _ _ _ rc.2.1 (masks i ib) (masks i ib).next
    (data i) f.1 _ _ _ f.2.2.1 f.2.2.2.1 f.2.2.2.2
    (limit _ _ rbound (by omega)) (limit _ _ cbound (by omega)) (limit _ _ abound (by omega)) (by change i < 2^32; omega)

#print axioms sound
end ZkBuild.BranchTypeSemanticSound
