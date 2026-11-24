import NameGraphRoots
import NameGraphSound
set_option autoImplicit false
namespace ZkBuild.NameGraphSoundness
open Lean.Grind CircuitShape FullMatrix GadgetShape
attribute [local instance] Ring.intCast Semiring.natCast

def Meaning {F : Type} [Field F] (values : Nat → F) (tables : List ReadOnlyMatrix.Record) (r : NameGraphMatrix.Record) : Prop :=
  NameLists.Canonical (NameGraphTable.table values (NameGraphMatrix.table tables r 0)) ∧
  ∀ root ∈ r.roots, ∃ head : Nat, ∃ bytes : List Nat, head < 2^32 ∧ E values root.head = (head : F) ∧
    NameLists.Represents (NameGraphTable.table values (NameGraphMatrix.table tables r 0)) head bytes ∧ Utf8Suffix.Valid bytes

theorem graph_verified {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (tables : List ReadOnlyMatrix.Record) (tableChecks : tables.all (ReadOnlyMatrix.check matrix) = true)
    (r : NameGraphMatrix.Record) (checked : NameGraphMatrix.check matrix tables r = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) : Meaning values tables r := by
  exact ⟨NameGraphStrings.canonical matrix tables tableChecks r checked values oneValue satisfied,
    NameGraphRoots.root_valid matrix tables tableChecks r checked values oneValue satisfied⟩

theorem fragment_verified {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (tables : List ReadOnlyMatrix.Record) (graphs : List NameGraphMatrix.Record)
    (checked : NameGraphSound.fragmentCheck matrix tables graphs = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∀ r ∈ graphs, Meaning values tables r := by
  have checks := Bool.and_eq_true_iff.mp checked
  intro r member
  exact graph_verified matrix tables checks.1 r (List.all_eq_true.mp checks.2 r member) values oneValue satisfied

/-- This composes the certified source-framing and name-graph properties.
    A separate source-chain certificate must still identify their byte lists. -/
theorem module_verified {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record) (splits : DeclarationMatrix.Splits)
    (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record) (signature : SignatureMatrix.Record)
    (space : SignatureNamespace.Record) (imports : ImportMatrix.Record) (owned : List OwnedMatrix.Record)
    (names : NameFrameMatrix.Record) (graph : NameGraphMatrix.Record)
    (checked : NameGraphSound.check matrix body tables splits declaration indexed signature space imports owned names graph = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) :
    NameFrameSound.check matrix body tables splits declaration indexed signature space imports owned names = true ∧ Meaning values tables graph := by
  have parts := Bool.and_eq_true_iff.mp checked
  have frameParts := Bool.and_eq_true_iff.mp parts.1
  have ownedParts := Bool.and_eq_true_iff.mp frameParts.1
  have signatureCheck := (Bool.and_eq_true_iff.mp ownedParts.1).1
  have indexedCheck := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp signatureCheck).1).1
  have moduleCheck := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp indexedCheck).1).1
  have tableChecks := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp moduleCheck).1).2
  exact ⟨parts.1,graph_verified matrix tables tableChecks graph parts.2 values oneValue satisfied⟩

#print axioms graph_verified
#print axioms fragment_verified
#print axioms module_verified
end ZkBuild.NameGraphSoundness
