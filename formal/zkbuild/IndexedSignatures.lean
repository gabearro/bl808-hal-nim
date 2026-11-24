import SignatureLists
import ControlEvents

/- Natural group specification for wasm_indexed_signatures.nim. The exact
   read-only argument authenticates node, length, and member queries. These
   lemmas connect consecutive ordinal/cursor checks to a typed list. -/
namespace ZkBuild.IndexedSignatures

open Lean.Grind SignatureLists RangeConstraints
attribute [local instance] Semiring.natCast

structure Cell where
  ordinal : Nat
  cursor : Nat
  tag : Fin 7
  next : Nat

def Rows (table : Table) (index cursor total : Nat) : List Cell → Prop
  | [] => index = total ∧ cursor = 0
  | cell :: rest => cell.ordinal = index ∧ cell.cursor = cursor ∧ cursor ≠ 0 ∧
      table cursor = some ⟨cell.tag, cell.next⟩ ∧ Rows table (index+1) cell.next total rest

def values (cells : List Cell) : List Nat := cells.map fun cell => cell.tag.val

theorem rows_sound (table : Table) (cells : List Cell) (index cursor total : Nat)
    (rows : Rows table index cursor total cells) :
    Represents table cursor (values cells) ∧ index+cells.length = total := by
  induction cells generalizing index cursor with
  | nil =>
    have zero := rows.2
    subst cursor
    exact ⟨.nil, by simpa using rows.1⟩
  | cons cell rest ih =>
    have tail := ih (index+1) cell.next rows.2.2.2.2
    exact ⟨.cons rows.2.2.1 rows.2.2.2.1 tail.1, by simp; omega⟩

theorem rows_complete (table : Table) (cursor : Nat) (types : List Nat)
    (rep : Represents table cursor types) (index : Nat) :
    ∃ cells, Rows table index cursor (index+types.length) cells ∧ values cells = types := by
  induction rep generalizing index with
  | nil => exact ⟨[], by simp [Rows], rfl⟩
  | @cons id node rest nonzero found rep ih =>
    obtain ⟨cells, rows, same⟩ := ih (index+1)
    refine ⟨⟨index, id, node.tag, node.next⟩ :: cells, ?_, ?_⟩
    · refine ⟨rfl, rfl, nonzero, found, ?_⟩
      simpa [Nat.add_assoc, Nat.add_comm, Nat.add_left_comm] using rows
    · simp [values] at same ⊢; exact same

theorem member_position (table : Table) (cells : List Cell) (index cursor total : Nat)
    (rows : Rows table index cursor total cells) (cell : Cell) (member : cell ∈ cells) :
    ∃ i, ∃ bound : i < cells.length, cell.ordinal = index+i ∧ cells[i].tag = cell.tag := by
  induction cells generalizing index cursor with
  | nil => simp at member
  | cons first rest ih =>
    rcases List.mem_cons.mp member with rfl | tail
    · exact ⟨0, by simp, by simpa using rows.1, rfl⟩
    · obtain ⟨i, bound, position, tag⟩ := ih (index+1) first.next rows.2.2.2.2 tail
      refine ⟨i+1, by simpa using Nat.succ_lt_succ bound, ?_, ?_⟩
      · omega
      · simpa using tag

theorem lookup_sound (table : Table) (cells : List Cell) (head total ordinal : Nat)
    (rows : Rows table 0 head total cells) (cell : Cell) (member : cell ∈ cells)
    (key : cell.ordinal = ordinal) :
    ∃ types, Represents table head types ∧ types.length = total ∧
      ∃ bound : ordinal < types.length, types[ordinal] = cell.tag.val := by
  have sound := rows_sound table cells 0 head total rows
  obtain ⟨i, bound, position, tag⟩ := member_position table cells 0 head total rows cell member
  have index : i = ordinal := by omega
  subst i
  refine ⟨values cells, sound.1, ?_, ?_⟩
  · simpa [values] using sound.2
  · refine ⟨by simpa [values] using bound, ?_⟩
    simpa [values] using congrArg Fin.val tag

def address (head ordinal : Nat) : Nat := head*2^32+ordinal

theorem address_bound (head ordinal : Nat) (hb : head < 2^32) (ob : ordinal < 2^32) :
    address head ordinal < 2^64 := by simp [address]; omega

theorem address_injective (a b i j : Nat) (ib : i < 2^32) (jb : j < 2^32)
    (same : address a i = address b j) : a = b ∧ i = j := by
  have split := radix_injective (2^32) i a j b ib jb
    (by simpa [address, Nat.add_comm, Nat.mul_comm] using same)
  exact ⟨split.2, split.1⟩

theorem field_address_injective {F : Type} [Field F] [IsCharP F scalarModulus]
    (a b i j : Nat) (ab : a < 2^32) (bb : b < 2^32) (ib : i < 2^32) (jb : j < 2^32)
    (same : (address a i : F) = (address b j : F)) : a = b ∧ i = j := by
  apply address_injective a b i j ib jb
  exact NumericEvents.nat_eq (F := F) _ _ (address_bound a i ab ib) (address_bound b j bb jb) same

theorem reverse_index (length index : Nat) (bound : index < length) :
    length-1-index < length ∧ length-1-(length-1-index) = index := by omega

theorem reversed_lookup (types : List Nat) (index : Fin types.length) :
    types.reverse[types.length-1-index.val]'(by simp; have := index.isLt; omega) = types[index.val] := by
  rw [List.getElem_reverse]
  congr 1
  have := index.isLt
  omega

theorem ordinal_alias (head : Nat) : address head (2^32) = address (head+1) 0 := by
  simp [address, Nat.add_mul]

def flag {F : Type} [Field F] (b : Bool) : F := if b then 1 else 0

structure CellGates {F : Type} [Field F] (start finish : Bool) (cell : Cell)
    (head total priorOrdinal priorNext : Nat) : Prop where
  firstOrdinal : flag start*(cell.ordinal : F) = 0
  firstCursor : flag start*((cell.cursor : F)-(head : F)) = 0
  nextOrdinal : (1-flag start)*((cell.ordinal : F)-(priorOrdinal : F)-1) = 0
  nextCursor : (1-flag start)*((cell.cursor : F)-(priorNext : F)) = 0
  finalNext : flag finish*(cell.next : F) = 0
  finalCount : flag finish*((cell.ordinal : F)+1-(total : F)) = 0

theorem cell_gates_sound {F : Type} [Field F] [IsCharP F scalarModulus]
    (start finish : Bool) (cell : Cell) (head total priorOrdinal priorNext : Nat)
    (ib : cell.ordinal < 2^32) (cb : cell.cursor < 2^32) (nb : cell.next < 2^32)
    (hb : head < 2^32) (tb : total < 2^32) (pb : priorOrdinal < 2^32) (qb : priorNext < 2^32)
    (gates : CellGates (F := F) start finish cell head total priorOrdinal priorNext) :
    (start = true → cell.ordinal = 0 ∧ cell.cursor = head) ∧
    (start = false → cell.ordinal = priorOrdinal+1 ∧ cell.cursor = priorNext) ∧
    (finish = true → cell.next = 0 ∧ cell.ordinal+1 = total) := by
  constructor
  · intro first
    have index := gates.firstOrdinal
    have cursor := gates.firstCursor
    simp [flag, first] at index cursor
    constructor
    · apply NumericEvents.nat_eq (F := F) _ _ (by simp [NumericEvents.countBound]; omega) (by decide)
      simp only [Semiring.natCast_zero]; grind
    · exact NumericEvents.nat_eq (F := F) _ _ (by simp [NumericEvents.countBound]; omega)
        (by simp [NumericEvents.countBound]; omega) (by grind)
  constructor
  · intro continuation
    have index := gates.nextOrdinal
    have cursor := gates.nextCursor
    simp [flag, continuation] at index cursor
    constructor
    · apply NumericEvents.nat_eq (F := F) _ _ (by simp [NumericEvents.countBound]; omega)
        (by simp [NumericEvents.countBound]; omega)
      simp only [Semiring.natCast_add, Semiring.natCast_one]; grind
    · exact NumericEvents.nat_eq (F := F) _ _ (by simp [NumericEvents.countBound]; omega)
        (by simp [NumericEvents.countBound]; omega) (by grind)
  · intro final
    have next := gates.finalNext
    have count := gates.finalCount
    simp [flag, final] at next count
    constructor
    · apply NumericEvents.nat_eq (F := F) _ _ (by simp [NumericEvents.countBound]; omega) (by decide)
      simp only [Semiring.natCast_zero]; grind
    · apply NumericEvents.nat_eq (F := F) _ _ (by simp [NumericEvents.countBound]; omega)
        (by simp [NumericEvents.countBound]; omega)
      simp only [Semiring.natCast_add, Semiring.natCast_one]; grind

theorem nonzero_cursor {F : Type} [Field F] (cursor : Nat) (reciprocal : F)
    (inverse : (cursor : F)*reciprocal = 1) : cursor ≠ 0 := by
  intro zero
  have bad : (0 : F) = 1 := by simp [zero, Semiring.natCast_zero] at inverse; grind
  exact Field.zero_ne_one bad

theorem nil_length_sound {F : Type} [Field F] [IsCharP F scalarModulus]
    (head length : Nat) (hb : head < 2^32) (lb : length < 2^32)
    (headZero lengthZero headInverse lengthInverse : F)
    (hz : (head : F)*headZero = 0) (hi : (head : F)*headInverse = 1-headZero)
    (lz : (length : F)*lengthZero = 0) (li : (length : F)*lengthInverse = 1-lengthZero)
    (same : headZero = lengthZero) : head = 0 ↔ length = 0 := by
  have h := ControlEvents.empty_sound head hb headZero headInverse hz hi
  have l := ControlEvents.empty_sound length lb lengthZero lengthInverse lz li
  by_cases emptyHead : head = 0 <;> by_cases emptyLength : length = 0
  all_goals simp [emptyHead, emptyLength] at h l ⊢
  all_goals
    have bad : (1 : F) = 0 := by grind
    exact False.elim (Field.zero_ne_one bad.symm)

#print axioms rows_sound
#print axioms rows_complete
#print axioms member_position
#print axioms lookup_sound
#print axioms field_address_injective
#print axioms reverse_index
#print axioms reversed_lookup
#print axioms cell_gates_sound
#print axioms nonzero_cursor
#print axioms nil_length_sound

end ZkBuild.IndexedSignatures
