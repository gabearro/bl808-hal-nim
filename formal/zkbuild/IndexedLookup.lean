import IndexedTypeLists

namespace ZkBuild.IndexedLookup
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix EnvelopeMatrix
attribute [local instance] Ring.intCast Semiring.natCast

theorem ordinal_at (table : SignatureLists.Table) (cells : List IndexedSignatures.Cell) (index cursor total : Nat)
    (rows : IndexedSignatures.Rows table index cursor total cells) (i : Nat) (bound : i < cells.length) :
    (cells[i]).ordinal = index+i := by
  induction cells generalizing index cursor i with
  | nil => simp at bound
  | cons cell cells ih =>
    cases i with
    | zero => simpa using rows.1
    | succ i =>
      have next := ih (index+1) cell.next rows.2.2.2.2 i (by simpa using bound)
      simpa [Nat.add_assoc,Nat.add_comm,Nat.add_left_comm] using next

theorem member_value {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (consumer : ReadOnlyMatrix.Record) (checked : ReadOnlyMatrix.check matrix consumer = true)
    (members : List IndexedMatrix.MemberRow) (entries : consumer.entries = members.map IndexedMatrix.MemberRow.entry)
    (query : Entry) (queryMember : query ∈ consumer.queries)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) (active : E values query.active = 1)
    (table : SignatureLists.Table) (cells : List IndexedSignatures.Cell) (head length ordinal : Nat)
    (rows : IndexedSignatures.Rows table 0 head length cells)
    (recorded : IndexedGroups.Recorded values members head cells) (inside : ordinal < length)
    (key : E values query.address = ((ordinal+2^32*head : Nat) : F)) :
    ∃ tag : Fin 7, ∃ cursor : Nat, cursor < 2^32 ∧
      (IndexedSignatures.values cells).getD ordinal 0 = tag.val ∧ E values query.value = ((tag.val+8*cursor : Nat) : F) := by
  have size := (IndexedSignatures.rows_sound table cells 0 head length rows).2
  have bound : ordinal < cells.length := by omega
  let cell := cells[ordinal]
  have cm : cell ∈ cells := List.getElem_mem bound
  have position : cell.ordinal = ordinal := by simpa [cell] using ordinal_at table cells 0 head length rows ordinal bound
  obtain ⟨cursorBound,_,row,rm,ra,rk,rv⟩ := recorded cell cm
  have em : row.entry ∈ consumer.entries := by rw [entries]; exact List.mem_map.mpr ⟨row,rm,rfl⟩
  have val := ReadOnlySound.checked_expected matrix consumer checked values oneValue satisfied query row.entry queryMember em active ra
    (by rw [rk,position,key])
  refine ⟨cell.tag,cell.cursor,cursorBound,?_,val.trans rv⟩
  simp only [IndexedSignatures.values,List.getD_eq_getElem?_getD,List.getElem?_map,List.getElem?_eq_getElem bound,Option.map_some,Option.getD_some]
  rfl

/-- A checked member lookup returns the tag at the requested position of
    the complete represented list, even when the consumer is a separate RAM
    instance with the same immutable initializers. -/
theorem checked_lookup {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record) (splits : Splits)
    (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record)
    (accepted : IndexedSound.check matrix body tables splits declaration indexed = true)
    (lengthConsumer memberConsumer : ReadOnlyMatrix.Record)
    (lengthChecked : ReadOnlyMatrix.check matrix lengthConsumer = true) (memberChecked : ReadOnlyMatrix.check matrix memberConsumer = true)
    (lengthEntries : lengthConsumer.entries = indexed.lengths.map IndexedMatrix.LengthRow.entry)
    (memberEntries : memberConsumer.entries = indexed.members.map IndexedMatrix.MemberRow.entry)
    (lengthQuery memberQuery : Entry) (lqm : lengthQuery ∈ lengthConsumer.queries) (mqm : memberQuery ∈ memberConsumer.queries)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (la : E values lengthQuery.active = 1) (ma : E values memberQuery.active = 1)
    (head length ordinal : Nat) (hb : head < 2^32) (lb : length < 2^32) (inside : ordinal < length)
    (hi : E values lengthQuery.address = (head : F)) (li : E values lengthQuery.value = (length : F))
    (mi : E values memberQuery.address = ((ordinal+2^32*head : Nat) : F)) :
    ∃ tags : List Nat, ∃ tag : Fin 7, ∃ cursor : Nat,
      SignatureLists.Represents (IndexedNodeTable.table values (IndexedLengths.banks tables indexed).nodes) head tags ∧
      tags.length = length ∧ cursor < 2^32 ∧ tags.getD ordinal 0 = tag.val ∧ E values memberQuery.value = ((tag.val+8*cursor : Nat) : F) := by
  obtain ⟨h,l,tags,hb',lb',hi',li',rep,count,cells,rows,same,recorded⟩ := IndexedTypeLists.queried_list matrix body tables splits declaration indexed accepted lengthConsumer lengthChecked lengthEntries lengthQuery lqm values oneValue satisfied la
  have hSame := DeclarationLocations.natural_equal (F := F) h head (by omega) (by omega) (hi'.symm.trans hi)
  have lSame := DeclarationLocations.natural_equal (F := F) l length (by omega) (by omega) (li'.symm.trans li)
  rw [hSame] at rep rows recorded
  rw [lSame] at count rows
  obtain ⟨tag,cursor,cb,atIndex,value⟩ := member_value matrix memberConsumer memberChecked indexed.members memberEntries memberQuery mqm values oneValue satisfied ma _ cells head length ordinal rows recorded inside mi
  rw [same] at atIndex
  exact ⟨tags,tag,cursor,rep,count,cb,atIndex,value⟩

#print axioms member_value
#print axioms checked_lookup
end ZkBuild.IndexedLookup
