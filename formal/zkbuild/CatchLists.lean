import RangeConstraints

namespace ZkBuild.CatchLists

structure Clause where
  kind : Fin 4
  tag : Nat
  depth : Nat
  deriving DecidableEq

structure Node where
  clause : Clause
  next : Nat
  deriving DecidableEq

abbrev Table := Nat → Option Node

inductive Represents (table : Table) : Nat → List Clause → Prop where
  | nil : Represents table 0 []
  | cons {head : Nat} {node : Node} {rest : List Clause} :
      head ≠ 0 → table head = some node → Represents table node.next rest →
      Represents table head (node.clause :: rest)

inductive Walk (table : Table) : Nat → List Clause → Nat → Prop where
  | done (head : Nat) : Walk table head [] head
  | step {head tail : Nat} {node : Node} {rest : List Clause} :
      head ≠ 0 → table head = some node → Walk table node.next rest tail →
      Walk table head (node.clause :: rest) tail

theorem closed_walk (table : Table) (head : Nat) (expected marked : List Clause)
    (rep : Represents table head expected) (walk : Walk table head marked 0) : marked = expected := by
  induction rep generalizing marked with
  | nil =>
    cases walk with
    | done => rfl
    | step nonzero _ _ => exact False.elim (nonzero rfl)
  | @cons head node rest nonzero found rep ih =>
    cases walk with
    | done => exact False.elim (nonzero rfl)
    | @step _ _ other _ _ otherFound tail =>
      have same : node = other := Option.some.inj (found.symm.trans otherFound)
      subst other
      exact congrArg (List.cons node.clause) (ih _ tail)

theorem complete_walk (table : Table) (head : Nat) (values : List Clause)
    (rep : Represents table head values) : Walk table head values 0 := by
  induction rep with
  | nil => exact .done 0
  | cons nonzero found _ ih => exact .step nonzero found ih

theorem payload_packing (a b : Clause) (ab : a.tag < 2^32) (bb : b.tag < 2^32)
    (data : a.tag+2^32*a.depth = b.tag+2^32*b.depth) (kind : a.kind = b.kind) : a = b := by
  have split := ZkBuild.RangeConstraints.radix_injective (2^32) a.tag a.depth b.tag b.depth ab bb data
  cases a; cases b
  simp only [Clause.mk.injEq]
  exact ⟨kind, split⟩

theorem link_packing (a b : Node)
    (same : a.clause.kind.val+4*a.next = b.clause.kind.val+4*b.next) :
    a.clause.kind = b.clause.kind ∧ a.next = b.next := by
  have split := ZkBuild.RangeConstraints.radix_injective 4 a.clause.kind.val a.next
    b.clause.kind.val b.next a.clause.kind.isLt b.clause.kind.isLt same
  exact ⟨Fin.ext split.1, split.2⟩

#print axioms closed_walk
#print axioms complete_walk
#print axioms payload_packing
#print axioms link_packing

end ZkBuild.CatchLists
