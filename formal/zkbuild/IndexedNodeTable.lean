import ReadOnlyFacts
import IndexedSource

namespace ZkBuild.IndexedNodeTable
open Lean.Grind CircuitShape FullMatrix GadgetShape SignatureLists
attribute [local instance] Ring.intCast Semiring.natCast

def NodeAt {F : Type} [CommRing F] (values : Nat → F) (bank : ReadOnlyMatrix.Record) (id : Nat) (node : Node) : Prop :=
  node.next < 2^32 ∧ ∃ query ∈ bank.queries, E values query.active = 1 ∧
    E values query.address = (id : F) ∧ E values query.value = ((node.tag.val+8*node.next : Nat) : F)

noncomputable def table {F : Type} [CommRing F] (values : Nat → F) (bank : ReadOnlyMatrix.Record) : Table := by
  classical
  exact fun id => if existsNode : ∃ node, NodeAt values bank id node then some (Classical.choose existsNode) else none

theorem node_unique {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (bank : ReadOnlyMatrix.Record) (checked : ReadOnlyMatrix.check matrix bank = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (id : Nat) (a b : Node) (atA : NodeAt values bank id a) (atB : NodeAt values bank id b) : a = b := by
  obtain ⟨ab,qa,am,aa,ak,av⟩ := atA
  obtain ⟨bb,qb,bm,ba,bk,bv⟩ := atB
  have same := ReadOnlyFacts.queries_agree matrix bank checked values oneValue satisfied qa qb am bm aa ba (ak.trans bk.symm)
  have encoded : a.tag.val+8*a.next = b.tag.val+8*b.next := DeclarationLocations.natural_equal (F := F) _ _
    (by have h := a.tag.isLt; omega) (by have h := b.tag.isLt; omega) (av.symm.trans (same.trans bv))
  exact SignatureLists.payload_injective a b encoded

theorem found {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (bank : ReadOnlyMatrix.Record) (checked : ReadOnlyMatrix.check matrix bank = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (id : Nat) (node : Node) (atNode : NodeAt values bank id node) : table values bank id = some node := by
  classical
  have existsNode : ∃ node, NodeAt values bank id node := ⟨node,atNode⟩
  simp only [table,dif_pos existsNode]
  congr 1
  exact node_unique matrix bank checked values oneValue satisfied id _ node (Classical.choose_spec existsNode) atNode

#print axioms node_unique
#print axioms found
end ZkBuild.IndexedNodeTable
