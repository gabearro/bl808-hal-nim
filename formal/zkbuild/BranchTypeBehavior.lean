import BranchTypeRestoration
import BranchTypeArity
set_option autoImplicit false
namespace ZkBuild.BranchTypeBehavior
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix OperandEvents
attribute [local instance] Ring.intCast Semiring.natCast

def Complete {F : Type} [Field F] (values : Nat → F) (splits : Splits) (r : StructuredMatrix.Record)
    (rows : List Row) (ops : List Nat) : Prop :=
  ∃ data : Nat → BranchTypeData.Data,
    BranchTypeTrace.Facts values splits r rows ops data ∧
    BranchTypeSemanticSound.Guards rows ops data ∧ BranchTypeRestoration.Trace rows ops data ∧
    (∀ i, i ≤ rows.length →
      BranchTypeTrace.Bounded (BranchTypeTrace.state rows ops data i) i ∧
      (BranchTypeTrace.state rows ops data i).length = (BranchTypeTrace.state rows ops data i).arity) ∧
    ∀ first last, InstructionSpans.Span rows first last → ∀ a b,
      first < a → a < last → first < b → b < last →
      BranchTypeState.mark (rows.getD a default).kind (ops.getD a 0) = true →
      BranchTypeState.mark (rows.getD b default).kind (ops.getD b 0) = true → (data a).size = (data b).size

theorem sound {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (splits : Splits) (tables : List ReadOnlyMatrix.Record) (indexed : IndexedMatrix.Record)
    (statics : StaticCatalog) (events : ValidationEventMatrix.Record) (r : StructuredMatrix.Record)
    (checked : BranchTypeCertificate.check matrix splits tables statics events r = true)
    (lookupChecked : BranchLookupCheck.check matrix tables indexed r = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (rows : List Row) (ops : List Nat)
    (images : OperandTraceSound.Represents values (ValidationEventCheck.stage events 1) rows)
    (schedule : InstructionSemanticSound.Schedule values events rows ops) : Complete values splits r rows ops := by
  obtain ⟨data,facts,guards⟩ := BranchTypeSemanticSound.sound matrix splits tables indexed statics events r checked lookupChecked
    values one satisfied rows ops images schedule
  refine ⟨data,facts,guards,
    BranchTypeRestoration.sound matrix splits tables statics events r checked values one satisfied rows ops images schedule data facts,?_,?_⟩
  · intro i ib
    exact ⟨BranchTypeTrace.bounds rows ops data i,BranchTypeArity.invariant rows ops data guards i ib⟩
  · intro first last span a b af al bf bl am bm
    exact BranchTypeArity.targets_equal rows ops data guards first last span a b af al bf bl am bm

#print axioms sound
end ZkBuild.BranchTypeBehavior
