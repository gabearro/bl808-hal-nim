import Std.Tactic
import Init.Data.List.Perm
import Init.Data.List.Pairwise

/- The semantic half of the RAM argument. Adjacent read checks are sound in
   the sorted order. Exact permutation and per-address timestamp order then
   transfer every cell's read/write history to chronological order. -/
namespace ZkBuild.MemoryTrace

structure Entry where
  active : Bool
  write : Bool
  address : Nat
  value : Nat
  time : Nat
  deriving DecidableEq

abbrev Memory := Nat → Option Nat

def advance (memory : Memory) (entry : Entry) : Memory :=
  if entry.active && entry.write then
    fun address => if address = entry.address then some entry.value else memory address
  else memory

def ReadOk (memory : Memory) (entry : Entry) : Prop :=
  entry.active = true → entry.write = false → memory entry.address = some entry.value

def Reads (memory : Memory) : List Entry → Prop
  | [] => True
  | entry :: rest => ReadOk memory entry ∧ Reads (advance memory entry) rest

def LocalOk (previous : Option Entry) (entry : Entry) : Prop :=
  entry.active = true → entry.write = false →
    ∃ prior, previous = some prior ∧ prior.active = true ∧
      prior.address = entry.address ∧ prior.value = entry.value

def LocalTrace (previous : Option Entry) : List Entry → Prop
  | [] => True
  | entry :: rest => LocalOk previous entry ∧ LocalTrace (some entry) rest

def Agrees (previous : Option Entry) (memory : Memory) : Prop :=
  ∀ entry, previous = some entry → entry.active = true →
    memory entry.address = some entry.value

theorem local_read (previous : Option Entry) (memory : Memory) (entry : Entry)
    (agrees : Agrees previous memory) (ok : LocalOk previous entry) : ReadOk memory entry := by
  intro active read
  obtain ⟨prior, same, priorActive, address, value⟩ := ok active read
  simpa [address, value] using agrees prior same priorActive

theorem advance_agrees (previous : Option Entry) (memory : Memory) (entry : Entry)
    (agrees : Agrees previous memory) (ok : LocalOk previous entry) :
    Agrees (some entry) (advance memory entry) := by
  intro prior same active
  cases same
  cases write : entry.write with
  | false => simpa [advance, active, write] using local_read previous memory entry agrees ok active write
  | true => simp [advance, active, write]

theorem local_implies_reads (entries : List Entry) (previous : Option Entry) (memory : Memory)
    (agrees : Agrees previous memory) (ok : LocalTrace previous entries) : Reads memory entries := by
  induction entries generalizing previous memory with
  | nil => trivial
  | cons entry rest ih =>
    exact ⟨local_read previous memory entry agrees ok.1,
      ih (some entry) (advance memory entry) (advance_agrees previous memory entry agrees ok.1) ok.2⟩

def cellStep (address : Nat) (state : Option Nat) (entry : Entry) : Option Nat :=
  if entry.active && entry.write && decide (entry.address = address) then some entry.value else state

def CellReads (address : Nat) (state : Option Nat) : List Entry → Prop
  | [] => True
  | entry :: rest =>
    (entry.active = true → entry.write = false → entry.address = address → state = some entry.value) ∧
      CellReads address (cellStep address state entry) rest

theorem advance_cell (memory : Memory) (entry : Entry) (address : Nat) :
    advance memory entry address = cellStep address (memory address) entry := by
  cases active : entry.active <;> cases write : entry.write <;>
    simp [advance, cellStep, active, write]
  by_cases same : entry.address = address
  · simp [same]
  · simp [same, Ne.symm same]

theorem reads_cells (entries : List Entry) (memory : Memory) (address : Nat)
    (ok : Reads memory entries) : CellReads address (memory address) entries := by
  induction entries generalizing memory with
  | nil => trivial
  | cons entry rest ih =>
    refine ⟨?_, ?_⟩
    · intro active read same
      simpa [same] using ok.1 active read
    · simpa [advance_cell] using ih (advance memory entry) ok.2

theorem cells_implies_reads (entries : List Entry) (memory : Memory)
    (ok : ∀ address, CellReads address (memory address) entries) : Reads memory entries := by
  induction entries generalizing memory with
  | nil => trivial
  | cons entry rest ih =>
    constructor
    · intro active read
      exact (ok entry.address).1 active read rfl
    · apply ih (advance memory entry)
      intro address
      simpa [advance_cell] using (ok address).2

def atCell (address : Nat) (entry : Entry) : Bool := entry.active && decide (entry.address = address)

theorem cell_filter (entries : List Entry) (address : Nat) (state : Option Nat) :
    CellReads address state (entries.filter (atCell address)) ↔ CellReads address state entries := by
  induction entries generalizing state with
  | nil => simp [CellReads]
  | cons entry rest ih =>
    by_cases active : entry.active = true
    · by_cases same : entry.address = address
      · simp [atCell, active, same, CellReads, ih]
      · simp [atCell, active, same, CellReads, cellStep, ih]
    · have inactive : entry.active = false := by cases h : entry.active <;> simp_all
      simp [atCell, inactive, CellReads, cellStep, ih]

def PerCellOrder (entries : List Entry) : Prop :=
  entries.Pairwise fun a b => a.active = true → b.active = true →
    a.address = b.address → a.time < b.time

theorem filtered_order (entries : List Entry) (address : Nat) (ordered : PerCellOrder entries) :
    (entries.filter (atCell address)).Pairwise (fun a b => a.time < b.time) := by
  rw [List.pairwise_filter]
  apply ordered.imp
  intro a b ordered aIn bIn
  have aa : a.active = true ∧ a.address = address := by simpa [atCell] using aIn
  have bb : b.active = true ∧ b.address = address := by simpa [atCell] using bIn
  exact ordered aa.1 bb.1 (aa.2.trans bb.2.symm)

theorem same_cell_history (chronological sorted : List Entry) (address : Nat)
    (permutation : chronological.Perm sorted)
    (chronoOrder : PerCellOrder chronological) (sortedOrder : PerCellOrder sorted) :
    chronological.filter (atCell address) = sorted.filter (atCell address) := by
  apply List.Perm.eq_of_pairwise (le := fun a b : Entry => a.time < b.time)
    (fun a b _ _ forward backward => by omega)
    (filtered_order chronological address chronoOrder)
    (filtered_order sorted address sortedOrder)
  exact permutation.filter (atCell address)

theorem chronological_reads (chronological sorted : List Entry)
    (permutation : chronological.Perm sorted)
    (chronoOrder : PerCellOrder chronological) (sortedOrder : PerCellOrder sorted)
    (localChecks : LocalTrace none sorted) :
    ∀ address, CellReads address none chronological := by
  intro address
  have reads : Reads (fun _ => none) sorted :=
    local_implies_reads sorted none (fun _ => none) (by intro entry impossible; cases impossible) localChecks
  have cells := reads_cells sorted (fun _ => none) address reads
  rw [← cell_filter] at cells
  rw [← same_cell_history chronological sorted address permutation chronoOrder sortedOrder] at cells
  exact (cell_filter chronological address none).mp cells

#print axioms chronological_reads
#print axioms cells_implies_reads

end ZkBuild.MemoryTrace
