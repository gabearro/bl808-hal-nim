import IndexedNodeTable
set_option autoImplicit false
namespace ZkBuild.SharedNodeRead
open Lean.Grind CircuitShape FullMatrix GadgetShape SignatureLists
attribute [local instance] Ring.intCast Semiring.natCast

/-- Inverting the source list table exposes the authenticated source read. -/
theorem witness {F : Type} [CommRing F] (values : Nat → F) (bank : ReadOnlyMatrix.Record)
    (id : Nat) (node : Node) (found : IndexedNodeTable.table values bank id = some node) :
    IndexedNodeTable.NodeAt values bank id node := by
  classical
  unfold IndexedNodeTable.table at found
  split at found
  next existsNode =>
    have same := Option.some.inj found
    exact same ▸ Classical.choose_spec existsNode
  next absent => contradiction

/-- Queries from distinct checked banks agree when their initializer entries
    are shared. This is the bridge between source-list reads and call reads. -/
theorem node {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (source consumer : ReadOnlyMatrix.Record)
    (sourceChecked : ReadOnlyMatrix.check matrix source = true)
    (consumerChecked : ReadOnlyMatrix.check matrix consumer = true)
    (shared : source.entries = consumer.entries)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (id : Nat) (expected : Node) (found : IndexedNodeTable.table values source id = some expected)
    (query : ReadOnlyMatrix.Entry) (member : query ∈ consumer.queries)
    (active : E values query.active = 1) (address : E values query.address = (id : F))
    (tag : Fin 8) (next : Fin (2^32))
    (payload : E values query.value = ((tag.val+8*next.val : Nat) : F)) :
    tag.val = expected.tag.val ∧ next.val = expected.next := by
  obtain ⟨bound,read,rm,ra,rk,rv⟩ := witness values source id expected found
  obtain ⟨_,_,_,_,_,_,_,_,membership⟩ := ReadOnlySound.checked_membership matrix source sourceChecked values one satisfied
  obtain ⟨entry,em,ea,ek,ev⟩ := membership read rm ra
  have agreed := ReadOnlySound.checked_expected matrix consumer consumerChecked values one satisfied query entry member
    (by rw [← shared]; exact em) active ea (ek.trans (rk.trans address.symm))
  have equal := DeclarationLocations.natural_equal (F := F) (tag.val+8*next.val) (expected.tag.val+8*expected.next)
    (by have := tag.isLt; have := next.isLt; omega)
    (by have := expected.tag.isLt; omega) (payload.symm.trans (agreed.trans (ev.trans rv)))
  exact RangeConstraints.radix_injective 8 tag.val next.val expected.tag.val expected.next
    tag.isLt (by have := expected.tag.isLt; omega) equal

theorem uncons {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (source consumer : ReadOnlyMatrix.Record)
    (sourceChecked : ReadOnlyMatrix.check matrix source = true)
    (consumerChecked : ReadOnlyMatrix.check matrix consumer = true)
    (shared : source.entries = consumer.entries)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (id : Nat) (nonzero : id ≠ 0) (items : List Nat)
    (rep : Represents (IndexedNodeTable.table values source) id items)
    (query : ReadOnlyMatrix.Entry) (member : query ∈ consumer.queries)
    (active : E values query.active = 1) (address : E values query.address = (id : F))
    (tag : Fin 8) (next : Fin (2^32))
    (payload : E values query.value = ((tag.val+8*next.val : Nat) : F)) :
    ∃ rest, items = tag.val :: rest ∧ Represents (IndexedNodeTable.table values source) next.val rest := by
  cases rep with
  | nil => exact False.elim (nonzero rfl)
  | cons nz found tail =>
    have decoded := node matrix source consumer sourceChecked consumerChecked shared values one satisfied id _ found
      query member active address tag next payload
    exact ⟨_,by rw [decoded.1],by rw [decoded.2]; exact tail⟩

#print axioms node
#print axioms uncons
end ZkBuild.SharedNodeRead
