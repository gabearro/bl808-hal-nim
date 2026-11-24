import OwnedUnit
set_option autoImplicit false
namespace ZkBuild.OwnedSoundness
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix OwnedMatrix OwnedRules OwnedDecode ShaProgram
attribute [local instance] Ring.intCast Semiring.natCast

def Coverage {F : Type} [Field F] (values : Nat → F) (r : OwnedMatrix.Record) : Prop :=
    ∃ ps : List ParentValue, ∃ cs : List ChildValue,
      Related (ParentImage values) r.parents ps ∧ Related (ChildImage values) r.children cs ∧
      (∀ p ∈ ps, ParentBound p) ∧ (∀ c ∈ cs, ChildBound c) ∧ (∀ p ∈ ps, p.active = false → p.count = 0) ∧
      countSum ps = activeCount cs ∧ (OwnedComplete.keys cs).Nodup ∧
      OwnedComplete.keys cs ⊆ BinaryDeclarations.vectorKeys 0 (ps.map ParentValue.count) ∧
      BinaryDeclarations.vectorKeys 0 (ps.map ParentValue.count) ⊆ OwnedComplete.keys cs

theorem fragment_verified {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (tables : List ReadOnlyMatrix.Record) (splits : Splits) (records : List OwnedMatrix.Record)
    (checked : OwnedSound.fragmentCheck matrix tables splits records = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∀ r ∈ records, Coverage values r := by
  have parts := Bool.and_eq_true_iff.mp checked
  have tablesChecked := (Bool.and_eq_true_iff.mp parts.1).1
  intro r member
  exact OwnedComplete.checked_complete matrix tables tablesChecked splits r (List.all_eq_true.mp parts.2 r member) values oneValue satisfied

theorem module_verified {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record) (splits : Splits)
    (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record) (signature : SignatureMatrix.Record)
    (space : SignatureNamespace.Record) (imports : ImportMatrix.Record) (records : List OwnedMatrix.Record)
    (checked : OwnedSound.check matrix body tables splits declaration indexed signature space imports records = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) :
    ImportSound.check matrix body tables splits declaration indexed signature space imports = true ∧
      ∀ r ∈ records, Coverage values r := by
  have parts := Bool.and_eq_true_iff.mp checked
  have signatureCheck := (Bool.and_eq_true_iff.mp parts.1).1
  have indexedCheck := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp signatureCheck).1).1
  have moduleCheck := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp indexedCheck).1).1
  have tableChecks := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp moduleCheck).1).2
  refine ⟨parts.1,?_⟩
  intro r member
  exact OwnedComplete.checked_complete matrix tables tableChecks splits r (List.all_eq_true.mp parts.2 r member) values oneValue satisfied

#print axioms fragment_verified
#print axioms module_verified
end ZkBuild.OwnedSoundness
