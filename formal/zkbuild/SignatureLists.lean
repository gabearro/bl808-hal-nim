import ReadOnlyMemory
import NumericEvents

namespace ZkBuild.SignatureLists

open Lean.Grind RangeConstraints
attribute [local instance] Semiring.natCast

structure Node where
  tag : Fin 7
  next : Nat
  deriving DecidableEq

abbrev Table := Nat → Option Node

inductive Represents (table : Table) : Nat → List Nat → Prop where
  | nil : Represents table 0 []
  | cons {id : Nat} {node : Node} {rest : List Nat} : id ≠ 0 → table id = some node →
      Represents table node.next rest → Represents table id (node.tag.val :: rest)

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
      exact congrArg (List.cons node.tag.val) (ih otherRest otherTail)

theorem represents_zero (table : Table) (values : List Nat) (rep : Represents table 0 values) : values = [] :=
  represents_unique table 0 values [] rep .nil

theorem represents_empty (table : Table) (id : Nat) (rep : Represents table id []) : id = 0 := by
  cases rep
  rfl

def Canonical (table : Table) : Prop := ∀ i j node, table i = some node → table j = some node → i = j

theorem canonical_heads (table : Table) (canonical : Canonical table) (i j : Nat) (a b : List Nat)
    (first : Represents table i a) (second : Represents table j b) (values : a = b) : i = j := by
  induction first generalizing j b with
  | nil =>
    subst b
    exact (represents_empty table j second).symm
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

theorem uncons (table : Table) (id : Nat) (node : Node) (values : List Nat)
    (nonzero : id ≠ 0) (found : table id = some node) (rep : Represents table id values) :
    ∃ rest, values = node.tag.val :: rest ∧ Represents table node.next rest := by
  cases rep with
  | nil => exact False.elim (nonzero rfl)
  | @cons _ other rest _ otherFound tail =>
    have same : node = other := Option.some.inj (found.symm.trans otherFound)
    subst other
    exact ⟨rest, rfl, tail⟩

def WellFormed (table : Table) : Prop := table 0 = none ∧
  ∀ id node, table id = some node → node.next < id ∧
    (node.next = 0 ∨ ∃ next, table node.next = some next)

theorem terminates (table : Table) (wellFormed : WellFormed table) (id : Nat)
    (present : id = 0 ∨ ∃ node, table id = some node) : ∃ values, Represents table id values := by
  induction id using Nat.strongRecOn with
  | ind id ih =>
    rcases present with rfl | ⟨node, found⟩
    · exact ⟨[], .nil⟩
    · have facts := wellFormed.2 id node found
      obtain ⟨rest, tail⟩ := ih node.next facts.1 facts.2
      have nonzero : id ≠ 0 := by intro zero; simp [zero, wellFormed.1] at found
      exact ⟨node.tag.val :: rest, .cons nonzero found tail⟩

theorem payload_injective (a b : Node)
    (same : a.tag.val+8*a.next = b.tag.val+8*b.next) : a = b := by
  have split := radix_injective 8 a.tag.val a.next b.tag.val b.next
    (by have := a.tag.isLt; omega) (by have := b.tag.isLt; omega) same
  cases a; cases b
  simp only [Node.mk.injEq]
  exact ⟨Fin.ext split.1, split.2⟩

theorem head_packing_injective (p r q s : Nat) (pb : p < 2^32) (qb : q < 2^32)
    (same : p+2^32*r = q+2^32*s) : p = q ∧ r = s :=
  radix_injective (2^32) p r q s pb qb same

theorem decreasing_gate {F : Type} [Field F] [IsCharP F scalarModulus]
    (id next delta : Nat) (ib : id < 2^32) (nb : next < 2^32) (db : delta < 2^32)
    (gate : (id : F)-(next : F)-1 = (delta : F)) : next < id :=
  ReadOnlyMemory.order_gate (2^32) next id delta nb ib db (by decide) gate

theorem tail_results_sound {F : Type} [Field F] [IsCharP F scalarModulus]
    (table : Table) (callee root : Nat) (calleeValues rootValues : List Nat)
    (cb : callee < 2^32) (rb : root < 2^32)
    (calleeRep : Represents table callee calleeValues) (rootRep : Represents table root rootValues)
    (gate : (callee : F)-(root : F) = 0) : calleeValues = rootValues := by
  have same : callee = root := NumericEvents.nat_eq (F := F) callee root
    (by simp [NumericEvents.countBound]; omega) (by simp [NumericEvents.countBound]; omega) (by grind)
  subst callee
  exact represents_unique table root calleeValues rootValues calleeRep rootRep

#print axioms represents_unique
#print axioms canonical_heads
#print axioms terminates
#print axioms payload_injective
#print axioms decreasing_gate
#print axioms tail_results_sound

end ZkBuild.SignatureLists
