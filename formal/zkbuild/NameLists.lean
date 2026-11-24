import SignatureLists

namespace ZkBuild.NameLists

structure Node where
  byte : Fin 256
  next : Nat
  deriving DecidableEq

abbrev Table := Nat → Option Node

inductive Represents (table : Table) : Nat → List Nat → Prop where
  | nil : Represents table 0 []
  | cons {id : Nat} {node : Node} {rest : List Nat} : id ≠ 0 → table id = some node →
      Represents table node.next rest → Represents table id (node.byte.val :: rest)

def Canonical (table : Table) : Prop :=
  ∀ i j node, table i = some node → table j = some node → i = j

theorem represents_unique (table : Table) (id : Nat) (a b : List Nat)
    (first : Represents table id a) (second : Represents table id b) : a = b := by
  induction first generalizing b with
  | nil => cases second with
    | nil => rfl
    | cons nonzero _ _ => exact False.elim (nonzero rfl)
  | @cons id node rest nonzero found tail ih =>
    cases second with
    | nil => exact False.elim (nonzero rfl)
    | @cons _ other otherRest _ otherFound otherTail =>
      have same : node = other := Option.some.inj (found.symm.trans otherFound)
      subst other
      exact congrArg (List.cons node.byte.val) (ih otherRest otherTail)

theorem canonical_heads (table : Table) (canonical : Canonical table) (i j : Nat) (a b : List Nat)
    (first : Represents table i a) (second : Represents table j b) (values : a = b) : i = j := by
  induction first generalizing j b with
  | nil =>
    subst b
    cases second with
    | nil => rfl
  | @cons id node rest nonzero found rep ih =>
    cases second with
    | nil => simp at values
    | @cons otherId other otherRest _ otherFound otherRep =>
      have heads := List.cons.inj values
      have nexts := ih other.next otherRest otherRep heads.2
      have equalNode : node = other := by
        cases node; cases other
        simp only [Node.mk.injEq]
        exact ⟨Fin.ext heads.1, nexts⟩
      exact canonical id j node found (by simpa [equalNode] using otherFound)

theorem unequal_heads_distinct_names (table : Table) (canonical : Canonical table)
    (i j : Nat) (a b : List Nat) (first : Represents table i a)
    (second : Represents table j b) (different : i ≠ j) : a ≠ b := by
  intro same
  exact different (canonical_heads table canonical i j a b first second same)

theorem payload_injective (a b : Node)
    (same : a.byte.val+256*a.next = b.byte.val+256*b.next) : a = b := by
  have split := RangeConstraints.radix_injective 256 a.byte.val a.next b.byte.val b.next
    a.byte.isLt b.byte.isLt same
  cases a; cases b
  simp only [Node.mk.injEq]
  exact ⟨Fin.ext split.1, split.2⟩

theorem reverse_map_canonical (table : Table) (reverse : Nat → Option Nat)
    (authenticated : ∀ i node, table i = some node →
      reverse (node.byte.val+256*node.next) = some i) : Canonical table := by
  intro i j node a b
  exact Option.some.inj ((authenticated i node a).symm.trans (authenticated j node b))

#print axioms represents_unique
#print axioms canonical_heads
#print axioms unequal_heads_distinct_names
#print axioms payload_injective
#print axioms reverse_map_canonical

end ZkBuild.NameLists
