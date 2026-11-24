import SignatureNodes
import CallSemanticSound
set_option autoImplicit false
namespace ZkBuild.CallNodeSource
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix
attribute [local instance] Ring.intCast Semiring.natCast

/-- An active call-list read resolves to a checked, strictly descending signature node. -/
def Origin {F : Type} [Field F] (values : Nat → F) (signature : SignatureMatrix.Record) (query : ReadOnlyMatrix.Entry) : Prop :=
  ∃ id : Fin (2^32), ∃ tag : Fin 7, ∃ next : Fin (2^32),
    next.val < id.val ∧ E values query.address = (id.val : F) ∧
    E values query.value = ((tag.val+8*next.val : Nat) : F) ∧
    ∃ source ∈ signature.nodes, E values source.entry.active = 1 ∧
      E values source.entry.address = E values query.address ∧ E values source.entry.value = E values query.value

def Origins {F : Type} [Field F] (values : Nat → F) (signature : SignatureMatrix.Record) : Prop :=
  ∀ query ∈ signature.extraOperands, E values query.active = 1 → Origin values signature query

theorem origins {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (splits : Splits) (tables : List ReadOnlyMatrix.Record)
    (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record) (signature : SignatureMatrix.Record)
    (checked : SignatureMatrix.check matrix splits tables declaration indexed signature = true)
    (tableChecks : tables.all (ReadOnlyMatrix.check matrix) = true)
    (splitChecks : splits.all (PackedFields.check matrix) = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values) : Origins values signature := by
  have parts := checked
  simp only [SignatureMatrix.check,Bool.and_eq_true_iff] at parts
  have links := _root_.of_decide_eq_true parts.2
  let bank := SignatureMatrix.table tables signature 1
  have bm : bank ∈ tables := by
    have im : signature.tables.getD 1 0 ∈ signature.tables := by
      rw [← List.getElem_eq_getD 0]
      exact List.getElem_mem (by rw [links.1]; decide)
    change tables.getD (signature.tables.getD 1 0) default ∈ tables
    rw [← List.getElem_eq_getD default]
    exact List.getElem_mem (links.2.1 _ im)
  have bc := List.all_eq_true.mp tableChecks bank bm
  obtain ⟨_,_,_,_,_,_,_,_,membership⟩ := ReadOnlySound.checked_membership matrix bank bc values one satisfied
  intro query member active
  have qm : query ∈ bank.queries := by
    change query ∈ (SignatureMatrix.table tables signature 1).queries
    rw [links.2.2.2.2.2.1]
    exact List.mem_append_right _ member
  obtain ⟨entry,em,ea,ek,ev⟩ := membership query qm active
  have listed : entry ∈ signature.nodes.map SignatureMatrix.NodeRow.entry := by
    change entry ∈ (SignatureMatrix.table tables signature 1).entries at em
    rwa [links.2.2.2.2.1] at em
  obtain ⟨source,sm,same⟩ := List.mem_map.mp listed
  subst entry
  obtain ⟨_,id,_,ib,_,_,ii,_⟩ := ReadOnlyFacts.entry_fields matrix bank bc values one satisfied source.entry em
  have bound : id < 2^32 := by
    have size := links.2.2.2.2.2.2.2.2.2.2.2.1
    simpa only [bank,size] using ib
  obtain ⟨tag,next,nb,less,vi,_,_⟩ := SignatureNodes.node_structure matrix splits splitChecks source
    (List.all_eq_true.mp parts.1.2 source sm) values one satisfied id bound ii ea
  exact ⟨⟨id,bound⟩,tag,⟨next,nb⟩,less,ek.symm.trans ii,ev.symm.trans vi,source,sm,ea,ek,ev⟩

theorem payload {F : Type} [Field F] [IsCharP F scalarModulus]
    (values : Nat → F) (signature : SignatureMatrix.Record) (query : ReadOnlyMatrix.Entry)
    (origin : Origin values signature query) (tag : Fin 8) (next : Fin (2^32))
    (image : E values query.value = ((tag.val+8*next.val : Nat) : F)) :
    tag.val < 7 ∧ ∃ id : Fin (2^32), next.val < id.val ∧ E values query.address = (id.val : F) := by
  obtain ⟨id,expected,following,less,ai,vi,_⟩ := origin
  have equal := DeclarationLocations.natural_equal (F := F) (tag.val+8*next.val) (expected.val+8*following.val)
    (by have := tag.isLt; have := next.isLt; omega)
    (by have := expected.isLt; have := following.isLt; omega) (image.symm.trans vi)
  have decoded := RangeConstraints.radix_injective 8 tag.val next.val expected.val following.val
    tag.isLt (by have := expected.isLt; omega) equal
  exact ⟨by rw [decoded.1]; exact expected.isLt,id,by rw [decoded.2]; exact less,ai⟩

#print axioms origins
#print axioms payload
end ZkBuild.CallNodeSource
