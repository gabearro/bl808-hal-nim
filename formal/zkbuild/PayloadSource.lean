import BinaryDeclarations
import NameLists
import ScalarEncoding

namespace ZkBuild.PayloadSource

open NameLists

-- The source reader consumes exactly the bytes returned by authenticated
-- name-node reads and must end at the nil head. The table's canonicality and
-- UTF-8 checks are independent obligations in NameLists/ModuleContext.
inductive NameRead (table : Table) : Nat → List Nat → Nat → Prop where
  | nil (head : Nat) : NameRead table head [] head
  | cons {head finish byte : Nat} {rest : List Nat} {node : Node} :
      head ≠ 0 → table head = some node → byte = node.byte.val →
      NameRead table node.next rest finish → NameRead table head (byte :: rest) finish

theorem closed_name_read (table : Table) (head : Nat) (bytes : List Nat)
    (read : NameRead table head bytes 0) : Represents table head bytes := by
  induction bytes generalizing head with
  | nil => cases read; exact .nil
  | cons byte rest ih =>
    cases read with
    | cons nonzero found same tail =>
      subst byte
      exact .cons nonzero found (ih _ tail)

theorem source_name_binding (table : Table) (head : Nat) (source declared : List Nat)
    (read : NameRead table head source 0) (name : Represents table head declared) :
    source = declared :=
  represents_unique table head source declared (closed_name_read table head source read) name

theorem source_export_names_distinct (table : Table) (canonical : Canonical table)
    (left right : Nat) (a b : List Nat) (different : left ≠ right)
    (first : NameRead table left a 0) (second : NameRead table right b 0) : a ≠ b :=
  unequal_heads_distinct_names table canonical left right a b
    (closed_name_read table left a first) (closed_name_read table right b second) different

-- Natural-number version of the three Boolean wire formulas in the Nim
-- element decoder. The mode ordinals agree with ElemMode in types.nim.
structure ElementLayout where
  mode : Nat
  explicitTable : Bool
  explicitType : Bool
  expressions : Bool
  deriving DecidableEq

def elementFormula (flags : Fin 8) : ElementLayout :=
  let b0 := flags.val % 2
  let b1 := flags.val / 2 % 2
  let b2 := flags.val / 4
  ⟨1-b0+2*b0*b1, (1-b0)*b1 == 1, b0+b1-b0*b1 == 1, b2 == 1⟩

def elementGrammar (flags : Fin 8) : ElementLayout :=
  match flags.val with
  | 0 => ⟨1, false, false, false⟩
  | 1 => ⟨0, false, true, false⟩
  | 2 => ⟨1, true, true, false⟩
  | 3 => ⟨2, false, true, false⟩
  | 4 => ⟨1, false, false, true⟩
  | 5 => ⟨0, false, true, true⟩
  | 6 => ⟨1, true, true, true⟩
  | _ => ⟨2, false, true, true⟩

theorem element_formula_matches_grammar : ∀ flags, elementFormula flags = elementGrammar flags := by decide

structure DataLayout where
  passive : Bool
  explicitMemory : Bool
  offset : Bool
  deriving DecidableEq

def dataFormula (flags : Fin 3) : DataLayout :=
  ⟨flags.val == 1, flags.val == 2, flags.val != 1⟩

def dataGrammar (flags : Fin 3) : DataLayout :=
  match flags.val with
  | 0 => ⟨false, false, true⟩
  | 1 => ⟨true, false, false⟩
  | _ => ⟨false, true, true⟩

theorem data_formula_matches_grammar : ∀ flags, dataFormula flags = dataGrammar flags := by decide

-- Exact counts for the four separate import namespaces. This establishes that
-- interleaving kinds does not change a namespace index used by source queries.
def countKind (kind : Nat) (imports : List Nat) : Nat :=
  (imports.filter (· == kind)).length

def namespaceCounts (imports : List Nat) : List Nat :=
  [countKind 0 imports, countKind 1 imports, countKind 2 imports, countKind 3 imports]

theorem counts_step (kind : Nat) (imports : List Nat) (next : Nat) :
    countKind kind (next :: imports) = countKind kind imports + (if next = kind then 1 else 0) := by
  unfold countKind
  by_cases same : next = kind <;> simp [same]

theorem namespace_total (imports : List Nat) (bounded : ∀ kind ∈ imports, kind < 4) :
    (namespaceCounts imports).sum = imports.length := by
  induction imports with
  | nil => rfl
  | cons next rest ih =>
    have bound := bounded next (by simp)
    have restBound : ∀ kind ∈ rest, kind < 4 := fun kind member => bounded kind (by simp [member])
    have ih := ih restBound
    have cases : next = 0 ∨ next = 1 ∨ next = 2 ∨ next = 3 := by omega
    simp only [namespaceCounts, List.sum_cons, List.sum_nil, Nat.add_zero] at ih ⊢
    rcases cases with rfl | rfl | rfl | rfl <;>
      simp only [counts_step, List.length_cons] <;> simp <;> omega

-- Position arithmetic is performed as bounded field values in the circuit.
-- These lemmas state the natural result once the range/read gadgets are linked.
theorem opaque_payload_bounded (cursor length finish : Nat)
    (within : cursor + length ≤ finish) :
    cursor ≤ finish ∧ ∀ i < length, cursor+i < finish := by
  constructor
  · omega
  · intro i bound
    omega

theorem exact_single_scalar (body encodedLength finish : Nat)
    (parsed : body+encodedLength = finish) : finish-body = encodedLength := by omega

theorem no_trailing_bytes (cursor finish trailing : Nat)
    (closed : cursor = finish) (within : cursor+trailing ≤ finish) : trailing = 0 := by omega

theorem name_span_injective (start finish otherStart otherFinish : Nat)
    (first : start < 2^32) (second : otherStart < 2^32)
    (same : start+2^32*finish = otherStart+2^32*otherFinish) :
    start = otherStart ∧ finish = otherFinish :=
  RangeConstraints.radix_injective (2^32) start finish otherStart otherFinish first second same

theorem zero_padding_value (bytes : List (Fin 256)) (count : Nat) :
    packBytes (bytes ++ List.replicate count 0) = packBytes bytes := by
  induction bytes with
  | nil =>
    induction count with
    | zero => rfl
    | succ count ih => simpa [List.replicate_succ, packBytes] using congrArg (fun n => 256*n) ih
  | cons first rest ih => simpa [packBytes] using congrArg (fun n => first.val+256*n) ih

def claimEncoding (bytes : List (Fin 256)) : List (Fin 256) :=
  (bytes ++ List.replicate (32-bytes.length) 0).reverse

theorem claim_encoding_value (bytes : List (Fin 256)) :
    ScalarEncoding.valueBE (claimEncoding bytes) = packBytes bytes := by
  simp only [ScalarEncoding.valueBE, claimEncoding, List.reverse_reverse, zero_padding_value]

theorem claim_encoding_canonical (bytes : List (Fin 256)) (small : bytes.length ≤ 31) :
    ScalarEncoding.canonical (claimEncoding bytes) = true := by
  apply (ScalarEncoding.canonical_iff _).mpr
  constructor
  · simp [claimEncoding]
    omega
  · rw [claim_encoding_value]
    have bound := packed_bytes_below_capacity bytes
    have power := Nat.pow_le_pow_right (n := 256) (by decide) small
    have capacity := packing_capacity
    omega

#print axioms closed_name_read
#print axioms source_name_binding
#print axioms source_export_names_distinct
#print axioms element_formula_matches_grammar
#print axioms data_formula_matches_grammar
#print axioms namespace_total
#print axioms opaque_payload_bounded
#print axioms no_trailing_bytes
#print axioms name_span_injective
#print axioms claim_encoding_value
#print axioms claim_encoding_canonical

end ZkBuild.PayloadSource
