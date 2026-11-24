import MemoryConstraints

/- An immutable-table specialization of the exact RAM argument. Initializers
   are writes and every subsequent access is a read. Strict ordering makes
   initializer addresses unique; a query must return that unique entry. -/
namespace ZkBuild.ReadOnlyMemory

open Lean.Grind MemoryTrace MemoryConstraints RangeConstraints
attribute [local instance] Semiring.natCast

def load : List Entry → Memory → Memory
  | [], memory => memory
  | entry :: rest, memory => load rest (advance memory entry)

theorem reads_append (entries queries : List Entry) (memory : Memory) :
    Reads memory (entries ++ queries) ↔ Reads memory entries ∧ Reads (load entries memory) queries := by
  induction entries generalizing memory with
  | nil => simp [Reads, load]
  | cons entry rest ih => simp only [List.cons_append, Reads, load, ih, and_assoc]

theorem load_origin (entries : List Entry) (memory : Memory) (address value : Nat)
    (found : load entries memory address = some value) :
    memory address = some value ∨ ∃ entry ∈ entries,
      entry.active = true ∧ entry.write = true ∧ entry.address = address ∧ entry.value = value := by
  induction entries generalizing memory with
  | nil => exact Or.inl found
  | cons entry rest ih =>
    rcases ih (advance memory entry) found with prior | ⟨other, member, facts⟩
    · by_cases active : entry.active = true
      · by_cases write : entry.write = true
        · by_cases same : entry.address = address
          · have v : entry.value = value := by simpa [advance, active, write, same] using prior
            exact Or.inr ⟨entry, by simp, active, write, same, v⟩
          · exact Or.inl (by simpa [advance, active, write, Ne.symm same] using prior)
        · have nw : entry.write = false := by cases h : entry.write <;> simp_all
          exact Or.inl (by simpa [advance, active, nw] using prior)
      · have na : entry.active = false := by cases h : entry.active <;> simp_all
        exact Or.inl (by simpa [advance, na] using prior)
    · exact Or.inr ⟨other, by simp [member], facts⟩

theorem immutable_queries (queries : List Entry) (memory : Memory)
    (noWrites : ∀ q ∈ queries, q.write = false) (reads : Reads memory queries) :
    ∀ q ∈ queries, q.active = true → memory q.address = some q.value := by
  induction queries with
  | nil => simp
  | cons query rest ih =>
    have nw := noWrites query (by simp)
    have stable : advance memory query = memory := by simp [advance, nw]
    intro q member active
    rcases List.mem_cons.mp member with same | tail
    · subst q; exact reads.1 active nw
    · exact ih (by intro q h; exact noWrites q (by simp [h]))
        (by simpa [stable] using reads.2) q tail active

def Unique (entries : List Entry) : Prop :=
  entries.Pairwise fun a b => a.active = true → b.active = true → a.address ≠ b.address

def InitializerOrder (previous : Option Entry) : List Entry → Prop
  | [] => True
  | entry :: rest => (∀ prior, previous = some prior → entry.active = true →
      prior.active = true ∧ prior.address < entry.address) ∧ InitializerOrder (some entry) rest

theorem later_initializer (prior : Entry) (entries : List Entry)
    (order : InitializerOrder (some prior) entries) :
    ∀ entry ∈ entries, entry.active = true → prior.active = true ∧ prior.address < entry.address := by
  induction entries generalizing prior with
  | nil => simp
  | cons entry rest ih =>
    intro other member active
    rcases List.mem_cons.mp member with rfl | tail
    · exact order.1 prior rfl active
    · have head := ih entry order.2 other tail active
      have first := order.1 prior rfl head.1
      exact ⟨first.1, Nat.lt_trans first.2 head.2⟩

theorem ordered_initializers (entries : List Entry) (previous : Option Entry)
    (order : InitializerOrder previous entries) :
    entries.Pairwise fun a b => a.active = true → b.active = true → a.address < b.address := by
  induction entries generalizing previous with
  | nil => exact .nil
  | cons entry rest ih =>
    refine .cons ?_ (ih (some entry) order.2)
    intro other member _ active
    exact (later_initializer entry rest order.2 other member active).2

theorem strict_unique (entries : List Entry)
    (ordered : entries.Pairwise fun a b => a.active = true → b.active = true → a.address < b.address) :
    Unique entries := by
  apply ordered.imp
  intro a b h aa ba
  exact Nat.ne_of_lt (h aa ba)

theorem member_unique (entries : List Entry) (unique : Unique entries)
    (a b : Entry) (am : a ∈ entries) (bm : b ∈ entries)
    (aa : a.active = true) (ba : b.active = true) (same : a.address = b.address) : a = b := by
  induction entries with
  | nil => simp at am
  | cons entry rest ih =>
    rcases List.pairwise_cons.mp unique with ⟨head, tail⟩
    rcases List.mem_cons.mp am with rfl | ar
    · rcases List.mem_cons.mp bm with rfl | br
      · rfl
      · exact False.elim (head b br aa ba same)
    · rcases List.mem_cons.mp bm with rfl | br
      · exact False.elim (head a ar ba aa same.symm)
      · exact ih tail ar br

theorem membership (entries queries : List Entry)
    (noWrites : ∀ q ∈ queries, q.write = false)
    (reads : Reads (fun _ => none) (entries ++ queries)) :
    ∀ q ∈ queries, q.active = true → ∃ entry ∈ entries,
      entry.active = true ∧ entry.write = true ∧ entry.address = q.address ∧ entry.value = q.value := by
  have queryReads := (reads_append entries queries (fun _ => none)).mp reads
  intro q member active
  have found := immutable_queries queries (load entries (fun _ => none)) noWrites queryReads.2 q member active
  rcases load_origin entries (fun _ => none) q.address q.value found with impossible | found
  · cases impossible
  · exact found

theorem unique_query (entries queries : List Entry) (unique : Unique entries)
    (noWrites : ∀ q ∈ queries, q.write = false)
    (reads : Reads (fun _ => none) (entries ++ queries))
    (query expected : Entry) (qm : query ∈ queries) (qa : query.active = true)
    (em : expected ∈ entries) (ea : expected.active = true)
    (address : expected.address = query.address) : query.value = expected.value := by
  obtain ⟨actual, am, aa, _, ax, av⟩ := membership entries queries noWrites reads query qm qa
  have same := member_unique entries unique actual expected am em aa ea (ax.trans address.symm)
  simpa [same] using av.symm

theorem field_membership {F : Type} [Field F] [IsCharP F scalarModulus]
    (addressBound timeBound valueBound : Nat) (entries queries sorted : List Entry)
    (noWrites : ∀ q ∈ queries, q.write = false)
    (permutation : (entries ++ queries).Perm sorted)
    (chronoOrder : PerCellOrder (entries ++ queries))
    (bounded : ∀ e ∈ sorted, Bounded addressBound timeBound valueBound e)
    (small : 4*(addressBound*timeBound) < scalarModulus)
    (addressSmall : addressBound < scalarModulus) (valueSmall : valueBound < scalarModulus)
    (gates : Gates (F := F) addressBound timeBound none sorted) :
    ∀ q ∈ queries, q.active = true → ∃ entry ∈ entries,
      entry.active = true ∧ entry.write = true ∧ entry.address = q.address ∧ entry.value = q.value := by
  apply membership entries queries noWrites
  apply cells_implies_reads (entries ++ queries) (fun _ => none)
  exact memory_sound addressBound timeBound valueBound (entries ++ queries) sorted permutation chronoOrder
    bounded small addressSmall valueSmall gates

theorem order_gate {F : Type} [Field F] [IsCharP F scalarModulus]
    (bound prior current delta : Nat) (priorBound : prior < bound) (currentBound : current < bound)
    (deltaBound : delta < bound) (small : 2*bound < scalarModulus)
    (gate : (current : F)-(prior : F)-1 = (delta : F)) : prior < current := by
  exact strict_order prior current delta bound priorBound currentBound deltaBound small gate

#print axioms field_membership
#print axioms unique_query
#print axioms order_gate
#print axioms ordered_initializers

end ZkBuild.ReadOnlyMemory
