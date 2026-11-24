import ReadOnlyMemory

namespace ZkBuild.ReferenceContext

open Lean.Grind MemoryTrace RangeConstraints
attribute [local instance] Semiring.natCast

/- The runtime implements funcref/externref rather than typed references.
   The fixed static rule independently constrains ref.func's stack effect. -/
def declarations (globals elements exports : List Nat) : List Nat :=
  globals ++ elements ++ exports

def check (code primary functions : Nat) (declared : List Nat) : Bool :=
  decide (code < 2^16 ∧ primary < 2^32 ∧ functions < 2^32) &&
    declared.all (fun index => decide (index < functions)) &&
    (if code = 210 then declared.contains primary else true)

theorem declaration_origin (g e x : List Nat) (index : Nat) :
    index ∈ declarations g e x ↔ index ∈ g ∨ index ∈ e ∨ index ∈ x := by
  simp [declarations]

theorem check_sound (code primary functions : Nat) (declared : List Nat)
    (ok : check code primary functions declared = true) (reference : code = 210) :
    primary < functions ∧ primary ∈ declared := by
  subst code
  simp only [check, Bool.and_eq_true, decide_eq_true_eq, ↓reduceIte,
    List.contains_eq_mem, decide_eq_true_eq] at ok
  have member := ok.2
  have valid := List.all_eq_true.mp ok.1.2 primary member
  exact ⟨of_decide_eq_true valid, member⟩

theorem initializer_bound {F : Type} [CommRing F] [IsCharP F scalarModulus]
    (index count gap : Nat) (ib : index < 2^32) (cb : count < 2^32) (gb : gap < 2^32)
    (gate : (count : F)-(index : F)-1 = (gap : F)) : index < count :=
  strict_order index count gap (2^32) ib cb gb (by decide) gate

theorem lookup_sound (entries queries : List Entry) (functions : Nat)
    (bounded : ∀ entry ∈ entries, entry.active = true → entry.address < functions)
    (noWrites : ∀ query ∈ queries, query.write = false)
    (reads : Reads (fun _ => none) (entries ++ queries))
    (query : Entry) (member : query ∈ queries) (active : query.active = true) :
    query.address < functions ∧ ∃ entry ∈ entries,
      entry.active = true ∧ entry.address = query.address := by
  obtain ⟨entry, em, ea, _, address, _⟩ :=
    ReadOnlyMemory.membership entries queries noWrites reads query member active
  exact ⟨by simpa [address] using bounded entry em ea, entry, em, ea, address⟩

#print axioms declaration_origin
#print axioms check_sound
#print axioms initializer_bound
#print axioms lookup_sound

end ZkBuild.ReferenceContext
