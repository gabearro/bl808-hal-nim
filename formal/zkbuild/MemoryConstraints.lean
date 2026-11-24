import RangeConstraints
import MemoryTrace

/- Arithmetic interface of memory_consistency.nim. Natural fields below are
   justified by range constraints; exact record packing is justified by
   RangeConstraints.packed_field_injective. This file connects the sorted
   row gates to chronological read/write semantics. -/
namespace ZkBuild.MemoryConstraints

open Lean.Grind MemoryTrace RangeConstraints
attribute [local instance] Semiring.natCast

def Bounded (addressBound timeBound valueBound : Nat) (entry : Entry) : Prop :=
  entry.address < addressBound ∧ entry.time < timeBound ∧ entry.value < valueBound

def key (addressBound timeBound : Nat) (entry : Entry) : Nat :=
  (if entry.active then 0 else addressBound*timeBound) + entry.address*timeBound + entry.time

def flag {F : Type} [CommRing F] (value : Bool) : F := if value then 1 else 0
def readFlag {F : Type} [CommRing F] (entry : Entry) : F := flag entry.active-flag entry.write

theorem payload_bound (addressBound timeBound valueBound : Nat) (entry : Entry)
    (bounded : Bounded addressBound timeBound valueBound entry) :
    entry.address*timeBound + entry.time < addressBound*timeBound := by
  calc
    entry.address*timeBound + entry.time < entry.address*timeBound + timeBound :=
      Nat.add_lt_add_left bounded.2.1 _
    _ = (entry.address+1)*timeBound := by rw [Nat.add_mul, Nat.one_mul]
    _ ≤ addressBound*timeBound := Nat.mul_le_mul_right timeBound bounded.1

theorem key_bound (addressBound timeBound valueBound : Nat) (entry : Entry)
    (bounded : Bounded addressBound timeBound valueBound entry) :
    key addressBound timeBound entry < 2*(addressBound*timeBound) := by
  have payload := payload_bound addressBound timeBound valueBound entry bounded
  cases active : entry.active <;> simp [key, active] <;> omega

theorem prior_active (addressBound timeBound valueBound : Nat) (prior entry : Entry)
    (bounded : Bounded addressBound timeBound valueBound entry)
    (active : entry.active = true)
    (ordered : key addressBound timeBound prior < key addressBound timeBound entry) :
    prior.active = true := by
  have payload := payload_bound addressBound timeBound valueBound entry bounded
  cases pa : prior.active with
  | true => rfl
  | false => simp [key, active, pa] at ordered; omega

def EdgeGate {F : Type} [Field F] (addressBound timeBound : Nat) (prior entry : Entry) : Prop :=
  ∃ (same reciprocal : F) (delta : Nat),
    delta < 2*(addressBound*timeBound) ∧
    (key addressBound timeBound entry : F)-(key addressBound timeBound prior : F)-1 = (delta : F) ∧
    ((entry.address : F)-(prior.address : F))*same = 0 ∧
    ((entry.address : F)-(prior.address : F))*reciprocal = 1-same ∧
    readFlag (F := F) entry*(1-same) = 0 ∧
    readFlag (F := F) entry*((entry.value : F)-(prior.value : F)) = 0

def RowGate {F : Type} [Field F] (addressBound timeBound : Nat) (previous : Option Entry)
    (entry : Entry) : Prop := match previous with
  | none => readFlag (F := F) entry = 0
  | some prior => EdgeGate (F := F) addressBound timeBound prior entry

def Gates {F : Type} [Field F] (addressBound timeBound : Nat) (previous : Option Entry) : List Entry → Prop
  | [] => True
  | entry :: rest => RowGate (F := F) addressBound timeBound previous entry ∧
    Gates (F := F) addressBound timeBound (some entry) rest

theorem edge_order {F : Type} [Field F] [IsCharP F scalarModulus]
    (addressBound timeBound valueBound : Nat) (prior entry : Entry)
    (priorBound : Bounded addressBound timeBound valueBound prior)
    (entryBound : Bounded addressBound timeBound valueBound entry)
    (small : 4*(addressBound*timeBound) < scalarModulus)
    (gate : EdgeGate (F := F) addressBound timeBound prior entry) :
    key addressBound timeBound prior < key addressBound timeBound entry := by
  obtain ⟨same, reciprocal, delta, db, order, _⟩ := gate
  exact strict_order _ _ delta (2*(addressBound*timeBound))
    (key_bound _ _ _ prior priorBound) (key_bound _ _ _ entry entryBound) db (by omega) order

theorem row_local {F : Type} [Field F] [IsCharP F scalarModulus]
    (addressBound timeBound valueBound : Nat) (previous : Option Entry) (entry : Entry)
    (priorBound : ∀ prior, previous = some prior → Bounded addressBound timeBound valueBound prior)
    (entryBound : Bounded addressBound timeBound valueBound entry)
    (small : 4*(addressBound*timeBound) < scalarModulus)
    (addressSmall : addressBound < scalarModulus) (valueSmall : valueBound < scalarModulus)
    (gate : RowGate (F := F) addressBound timeBound previous entry) : LocalOk previous entry := by
  intro active read
  have reading : readFlag (F := F) entry = 1 := by simp [readFlag, flag, active, read]; grind
  cases previous with
  | none =>
    have bad : (1 : F) = 0 := by simpa [RowGate, reading] using gate
    exact False.elim (Field.zero_ne_one bad.symm)
  | some prior =>
    have pb := priorBound prior rfl
    have ordered := edge_order addressBound timeBound valueBound prior entry pb entryBound small gate
    obtain ⟨same, reciprocal, delta, db, order, zero, inverse, address, value⟩ := gate
    have selected : same = 1 := by rw [reading] at address; grind
    have addressField : (entry.address : F) = (prior.address : F) := by rw [selected] at zero; grind
    have valueField : (entry.value : F) = (prior.value : F) := by rw [reading] at value; grind
    have addressEq := (IsCharP.natCast_eq_iff_of_lt (α := F) scalarModulus
      (Nat.lt_trans entryBound.1 addressSmall) (Nat.lt_trans pb.1 addressSmall)).mp addressField
    have valueEq := (IsCharP.natCast_eq_iff_of_lt (α := F) scalarModulus
      (Nat.lt_trans entryBound.2.2 valueSmall) (Nat.lt_trans pb.2.2 valueSmall)).mp valueField
    exact ⟨prior, rfl, prior_active _ _ _ prior entry entryBound active ordered,
      addressEq.symm, valueEq.symm⟩

theorem gates_local {F : Type} [Field F] [IsCharP F scalarModulus]
    (addressBound timeBound valueBound : Nat) (entries : List Entry) (previous : Option Entry)
    (bounded : ∀ e ∈ entries, Bounded addressBound timeBound valueBound e)
    (priorBound : ∀ prior, previous = some prior → Bounded addressBound timeBound valueBound prior)
    (small : 4*(addressBound*timeBound) < scalarModulus)
    (addressSmall : addressBound < scalarModulus) (valueSmall : valueBound < scalarModulus)
    (gates : Gates (F := F) addressBound timeBound previous entries) : LocalTrace previous entries := by
  induction entries generalizing previous with
  | nil => trivial
  | cons entry rest ih =>
    have eb := bounded entry (by simp)
    refine ⟨row_local _ _ _ previous entry priorBound eb small addressSmall valueSmall gates.1, ?_⟩
    apply ih (some entry) (by intro e he; exact bounded e (by simp [he]))
      (by intro prior same; cases same; exact eb) gates.2

def Edges (addressBound timeBound : Nat) (previous : Option Entry) : List Entry → Prop
  | [] => True
  | entry :: rest => (∀ prior, previous = some prior →
      key addressBound timeBound prior < key addressBound timeBound entry) ∧
      Edges addressBound timeBound (some entry) rest

theorem gates_edges {F : Type} [Field F] [IsCharP F scalarModulus]
    (addressBound timeBound valueBound : Nat) (entries : List Entry) (previous : Option Entry)
    (bounded : ∀ e ∈ entries, Bounded addressBound timeBound valueBound e)
    (priorBound : ∀ prior, previous = some prior → Bounded addressBound timeBound valueBound prior)
    (small : 4*(addressBound*timeBound) < scalarModulus)
    (gates : Gates (F := F) addressBound timeBound previous entries) :
    Edges addressBound timeBound previous entries := by
  induction entries generalizing previous with
  | nil => trivial
  | cons entry rest ih =>
    have eb := bounded entry (by simp)
    refine ⟨?_, ?_⟩
    · intro prior same
      cases same
      exact edge_order _ _ _ prior entry (priorBound prior rfl) eb small gates.1
    · apply ih (some entry) (by intro e he; exact bounded e (by simp [he]))
        (by intro prior same; cases same; exact eb) gates.2

theorem edges_all (addressBound timeBound : Nat) (entries : List Entry) (prior : Entry)
    (edges : Edges addressBound timeBound (some prior) entries) :
    ∀ entry ∈ entries, key addressBound timeBound prior < key addressBound timeBound entry := by
  induction entries generalizing prior with
  | nil => simp
  | cons entry rest ih =>
    intro other member
    have first := edges.1 prior rfl
    rcases List.mem_cons.mp member with rfl | tail
    · exact first
    · exact Nat.lt_trans first (ih entry edges.2 other tail)

theorem edges_pairwise (addressBound timeBound : Nat) (entries : List Entry) (previous : Option Entry)
    (edges : Edges addressBound timeBound previous entries) :
    entries.Pairwise (fun a b => key addressBound timeBound a < key addressBound timeBound b) := by
  induction entries generalizing previous with
  | nil => exact .nil
  | cons entry rest ih =>
    exact .cons (edges_all addressBound timeBound rest entry edges.2) (ih (some entry) edges.2)

theorem key_per_cell (addressBound timeBound : Nat) (entries : List Entry)
    (ordered : entries.Pairwise (fun a b => key addressBound timeBound a < key addressBound timeBound b)) :
    PerCellOrder entries := by
  apply ordered.imp
  intro a b order aa ba same
  simp [key, aa, ba, same] at order
  exact order

theorem memory_sound {F : Type} [Field F] [IsCharP F scalarModulus]
    (addressBound timeBound valueBound : Nat) (chronological sorted : List Entry)
    (permutation : chronological.Perm sorted)
    (chronoOrder : PerCellOrder chronological)
    (bounded : ∀ e ∈ sorted, Bounded addressBound timeBound valueBound e)
    (small : 4*(addressBound*timeBound) < scalarModulus)
    (addressSmall : addressBound < scalarModulus) (valueSmall : valueBound < scalarModulus)
    (gates : Gates (F := F) addressBound timeBound none sorted) :
    ∀ address, CellReads address none chronological := by
  have priorBound : ∀ prior : Entry, none = some prior → Bounded addressBound timeBound valueBound prior :=
    by intro prior impossible; cases impossible
  exact chronological_reads chronological sorted permutation chronoOrder
    (key_per_cell _ _ _ (edges_pairwise _ _ _ none
      (gates_edges _ _ _ sorted none bounded priorBound small gates)))
    (gates_local _ _ _ sorted none bounded priorBound small addressSmall valueSmall gates)

#print axioms memory_sound

end ZkBuild.MemoryConstraints
