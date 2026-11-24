import SignatureFrames

namespace ZkBuild.BranchLists

open Lean.Grind RangeConstraints
attribute [local instance] Semiring.natCast

structure Cell where
  depth : Nat
  next : Nat
  deriving DecidableEq

abbrev Store := Nat → Option Cell

inductive Follows (store : Store) : Nat → List Nat → Prop where
  | nil : Follows store 0 []
  | cons {cursor : Nat} {cell : Cell} {rest : List Nat} :
      store cursor = some cell → cell.next < cursor → Follows store cell.next rest →
      Follows store cursor (cell.depth :: rest)

inductive Consumes (store : Store) : Nat → List Nat → Nat → Prop where
  | nil {cursor : Nat} : Consumes store cursor [] cursor
  | cons {cursor finish : Nat} {cell : Cell} {rest : List Nat} :
      0 < cursor → store cursor = some cell → Consumes store cell.next rest finish →
      Consumes store cursor (cell.depth :: rest) finish

def Closed (store : Store) : Prop := ∀ cursor cell, store cursor = some cell →
  cell.next < cursor ∧ (cell.next = 0 ∨ ∃ next, store cell.next = some next)

theorem terminates (store : Store) (closed : Closed store) (cursor : Nat)
    (present : cursor = 0 ∨ ∃ cell, store cursor = some cell) :
    ∃ values, Follows store cursor values := by
  induction cursor using Nat.strongRecOn with
  | ind cursor ih =>
    rcases present with rfl | ⟨cell, found⟩
    · exact ⟨[], .nil⟩
    · have facts := closed cursor cell found
      obtain ⟨rest, tail⟩ := ih cell.next facts.1 facts.2
      exact ⟨cell.depth :: rest, .cons found facts.1 tail⟩

theorem follows_consumes (store : Store) (cursor : Nat) (values : List Nat)
    (path : Follows store cursor values) : Consumes store cursor values 0 := by
  induction path with
  | nil => exact .nil
  | cons found smaller tail ih => exact .cons (by omega) found ih

theorem zero_nil (store : Store) (values : List Nat) (path : Follows store 0 values) : values = [] := by
  cases path with
  | nil => rfl
  | cons found smaller tail => omega

theorem nonempty (store : Store) (cursor : Nat) (values : List Nat)
    (path : Follows store cursor values) (positive : 0 < cursor) : values ≠ [] := by
  cases path with
  | nil => omega
  | cons found smaller tail => simp

-- Every marker consumes exactly the authenticated next link. Reaching nil
-- therefore means every nondefault label and the final default were checked.
theorem complete_consumption (store : Store) (cursor : Nat) (expected actual : List Nat)
    (path : Follows store cursor expected) (consumed : Consumes store cursor actual 0) :
    actual = expected := by
  induction path generalizing actual with
  | nil =>
    cases consumed with
    | nil => rfl
    | cons positive found rest => omega
  | @cons cursor cell rest found smaller tail ih =>
    cases consumed with
    | nil => omega
    | @cons _ _ other actual positive otherFound remainder =>
      have same : other = cell := by simp_all
      subst other
      simp [ih actual remainder]

theorem default_is_final (store : Store) (cell : Cell) (rest : List Nat)
    (tail : Follows store cell.next rest) (last : cell.next = 0) : rest = [] := by
  rw [last] at tail
  exact zero_nil store rest tail

def pack (cell : Cell) : Nat := cell.depth+2^32*cell.next

theorem packing_injective (a b : Cell) (ad : a.depth < 2^32) (bd : b.depth < 2^32)
    (same : pack a = pack b) : a = b := by
  have parts := radix_injective (2^32) a.depth a.next b.depth b.next ad bd same
  cases a; cases b; simp_all

theorem field_packing_injective {F : Type} [CommRing F] [IsCharP F scalarModulus]
    (a b : Cell) (ad : a.depth < 2^32) (an : a.next < 2^32)
    (bd : b.depth < 2^32) (bn : b.next < 2^32) (same : (pack a : F) = (pack b : F)) : a = b := by
  have boundA : pack a < scalarModulus := by
    have large : 2^64 < scalarModulus := by decide
    dsimp [pack]
    omega
  have boundB : pack b < scalarModulus := by
    have large : 2^64 < scalarModulus := by decide
    dsimp [pack]
    omega
  exact packing_injective a b ad bd
    ((IsCharP.natCast_eq_iff_of_lt (α := F) scalarModulus boundA boundB).mp same)

theorem next_decreases {F : Type} [CommRing F] [IsCharP F scalarModulus]
    (cursor next delta : Nat) (cb : cursor < 2^32) (nb : next < 2^32) (db : delta < 2^32)
    (gate : (cursor : F)-(next : F)-1 = (delta : F)) : next < cursor :=
  strict_order next cursor delta (2^32) nb cb db (by decide) gate

#print axioms complete_consumption
#print axioms terminates
#print axioms follows_consumes
#print axioms field_packing_injective
#print axioms next_decreases

end ZkBuild.BranchLists
