import InstructionMetadata
import ReadOnlyMemory

namespace ZkBuild.BulkContext

open Lean.Grind RangeConstraints
attribute [local instance] Semiring.natCast

def sectionOrder : Nat → Int
  | 0 => 0 | 1 => 1 | 2 => 2 | 3 => 3 | 4 => 4 | 5 => 5 | 13 => 6
  | 6 => 7 | 7 => 8 | 8 => 9 | 9 => 10 | 12 => 11 | 10 => 12 | 11 => 13 | _ => -1

def orderedSections : List Nat := [1, 2, 3, 4, 5, 13, 6, 7, 8, 9, 12, 10, 11]

theorem section_sequence : orderedSections.map sectionOrder =
    [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13] := by decide

theorem section_unique : orderedSections.Nodup := by decide

def reference (tag : Nat) : Bool := decide (tag = 5 ∨ tag = 6)

def sameAt (a : List Nat) (i : Nat) (b : List Nat) (j : Nat) : Bool :=
  match a[i]?, b[j]? with
  | some x, some y => reference x && reference y && decide (x = y)
  | _, _ => false

def check (code memory : Nat) (hasCount : Bool) (declared data : Nat)
    (elements tables : List Nat) (primary secondary : Nat) : Bool :=
  decide (code < 65536 ∧ memory ≤ 1 ∧ declared < 2^32 ∧ data < 2^32 ∧ primary < 2^32 ∧ secondary < 2^32) &&
    elements.all reference && (if hasCount then decide (declared = data) else decide (declared = 0)) &&
    match code with
    | 264 => hasCount && decide (memory = 1 ∧ primary < data ∧ secondary = 0)
    | 265 => hasCount && decide (primary < data)
    | 266 => decide (memory = 1 ∧ primary = 0 ∧ secondary = 0)
    | 267 => decide (memory = 1 ∧ primary = 0)
    | 268 => sameAt elements primary tables secondary
    | 269 => (elements[primary]?).isSome
    | 270 => sameAt tables primary tables secondary
    | _ => true

theorem sameAt_sound (a b : List Nat) (i j : Nat) (ok : sameAt a i b j = true) :
    ∃ tag, a[i]? = some tag ∧ b[j]? = some tag ∧ (tag = 5 ∨ tag = 6) := by
  unfold sameAt at ok
  cases left : a[i]? with
  | none => simp [left] at ok
  | some x =>
    cases right : b[j]? with
    | none => simp [left, right] at ok
    | some y =>
      simp only [left, right, Bool.and_eq_true, decide_eq_true_eq] at ok
      have eq := ok.2
      subst y
      exact ⟨x, rfl, rfl, by simpa [reference] using ok.1.1⟩

theorem header_agreement {F : Type} [Field F] [IsCharP F scalarModulus]
    (declared actual : Nat) (db : declared < 2^32) (ab : actual < 2^32)
    (gate : (declared : F)-(actual : F) = 0) : declared = actual := by
  have small : 2^32 < scalarModulus := by decide
  apply (IsCharP.natCast_eq_iff_of_lt (α := F) scalarModulus (by omega) (by omega)).mp
  grind

theorem data_index_sound {F : Type} [CommRing F] [IsCharP F scalarModulus]
    (index count gap : Nat) (ib : index < 2^32) (cb : count < 2^32) (gb : gap < 2^32)
    (gate : (count : F)-(index : F)-1 = (gap : F)) : index < count :=
  strict_order index count gap (2^32) ib cb gb (by decide) gate

theorem table_type_guard {F : Type} [Field F] [IsCharP F scalarModulus]
    (tag : Nat) (bound : tag < 16) (gate : ((tag : F)-5)*((tag : F)-6) = 0) : tag = 5 ∨ tag = 6 := by
  rcases Field.of_mul_eq_zero gate with five | six
  · left
    have small : 16 < scalarModulus := by decide
    apply (IsCharP.natCast_eq_iff_of_lt (α := F) scalarModulus (by omega) (by decide)).mp
    have cast : ((5 : Nat) : F) = (5 : F) := Semiring.natCast_eq_ofNat 5
    rw [cast]
    grind
  · right
    have small : 16 < scalarModulus := by decide
    apply (IsCharP.natCast_eq_iff_of_lt (α := F) scalarModulus (by omega) (by decide)).mp
    have cast : ((6 : Nat) : F) = (6 : F) := Semiring.natCast_eq_ofNat 6
    rw [cast]
    grind

theorem dense_key {F : Type} [CommRing F] [IsCharP F scalarModulus]
    (key ordinal : Nat) (kb : key < 2^32) (ob : ordinal < 2^32)
    (gate : (key : F)-(ordinal : F) = 0) : key = ordinal := by
  have small : 2^32 < scalarModulus := by decide
  apply (IsCharP.natCast_eq_iff_of_lt (α := F) scalarModulus (by omega) (by omega)).mp
  grind

theorem optional_u32_not_absent (value : Nat) (bound : value < 2^32) :
    (0 : Int) ≤ Int.ofNat value ∧ Int.ofNat value < Int.ofNat (2^63) ∧ Int.ofNat value ≠ -1 := by
  refine ⟨Int.natCast_nonneg value, Int.ofNat_lt.mpr (by omega), ?_⟩
  intro impossible
  cases impossible

#print axioms section_sequence
#print axioms sameAt_sound
#print axioms header_agreement
#print axioms data_index_sound
#print axioms table_type_guard
#print axioms dense_key
#print axioms optional_u32_not_absent

end ZkBuild.BulkContext
