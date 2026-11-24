import ModuleAuditIO
import EnvelopeSound
import ReadOnlySound
import PackedFields

namespace ZkBuild.ModuleTables
open Lean.Grind CircuitShape FullMatrix GadgetShape ModuleAuditIO
attribute [local instance] Ring.intCast Semiring.natCast

def check (matrix : Shape) (body : SourceEnvelope) (tables : List ReadOnlyMatrix.Record) (fields : List PackedFields.Record) : Bool :=
  EnvelopeSound.check matrix body.source body.hash body.memory body.queries body.tokens body.envelope &&
    tables.all (ReadOnlyMatrix.check matrix) && fields.all (PackedFields.check matrix)

theorem checked_queries {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (body : SourceEnvelope) (tables : List ReadOnlyMatrix.Record)
    (fields : List PackedFields.Record) (accepted : check matrix body tables fields = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) :
    EnvelopeSound.check matrix body.source body.hash body.memory body.queries body.tokens body.envelope = true ∧
    ∀ table ∈ tables, ∀ query ∈ table.queries, E values query.active = 1 → ∃ entry ∈ table.entries,
      E values entry.active = 1 ∧ E values entry.address = E values query.address ∧ E values entry.value = E values query.value := by
  have parts := Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp accepted).1
  refine ⟨parts.1,?_⟩
  intro table member
  obtain ⟨_,_,_,_,_,_,_,_,queries⟩ := ReadOnlySound.checked_membership matrix table (List.all_eq_true.mp parts.2 table member) values oneValue satisfied
  exact queries

theorem checked_expected {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (body : SourceEnvelope) (tables : List ReadOnlyMatrix.Record) (fields : List PackedFields.Record)
    (accepted : check matrix body tables fields = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∀ table ∈ tables, ∀ query ∈ table.queries, ∀ expected ∈ table.entries,
      E values query.active = 1 → E values expected.active = 1 →
      E values expected.address = E values query.address → E values query.value = E values expected.value := by
  intro table member query qm expected em qa ea same
  have checks := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp accepted).1).2
  exact ReadOnlySound.checked_expected matrix table (List.all_eq_true.mp checks table member) values oneValue satisfied query expected qm em qa ea same

theorem checked_fields {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (body : SourceEnvelope) (tables : List ReadOnlyMatrix.Record) (fields : List PackedFields.Record)
    (accepted : check matrix body tables fields = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∀ r ∈ fields, ∃ value low high : Nat, value < 2^(r.lowWidth+r.highWidth) ∧ low < 2^r.lowWidth ∧ high < 2^r.highWidth ∧
      E values r.value = (value : F) ∧ E values r.low = (low : F) ∧ E values r.high = (high : F) ∧
      value = low+2^r.lowWidth*high ∧ low = value % 2^r.lowWidth ∧ high = value / 2^r.lowWidth := by
  intro r member
  exact PackedFields.checked_split matrix r (List.all_eq_true.mp (Bool.and_eq_true_iff.mp accepted).2 r member) values oneValue satisfied

#print axioms checked_queries
#print axioms checked_fields
#print axioms checked_expected
end ZkBuild.ModuleTables
