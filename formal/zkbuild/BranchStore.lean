import BranchListSound
import ReadOnlyFacts
set_option autoImplicit false
namespace ZkBuild.BranchStore
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix BranchLists
attribute [local instance] Ring.intCast Semiring.natCast

def CellAt {F : Type} [CommRing F] (values : Nat → F) (bank : ReadOnlyMatrix.Record) (id : Nat) (cell : Cell) : Prop :=
  id < 2^32 ∧ cell.depth < 2^32 ∧ cell.next < 2^32 ∧ ∃ q ∈ bank.queries,
    E values q.active = 1 ∧ E values q.address = (id : F) ∧ E values q.value = (pack cell : F)

noncomputable def table {F : Type} [CommRing F] (values : Nat → F) (bank : ReadOnlyMatrix.Record) : Store := by
  classical
  exact fun id => if existsCell : ∃ cell, CellAt values bank id cell then some (Classical.choose existsCell) else none

theorem cell_unique {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (bank : ReadOnlyMatrix.Record) (checked : ReadOnlyMatrix.check matrix bank = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (id : Nat) (a b : Cell) (atA : CellAt values bank id a) (atB : CellAt values bank id b) : a = b := by
  obtain ⟨_,ad,an,qa,am,aa,ak,av⟩ := atA
  obtain ⟨_,bd,bn,qb,bm,ba,bk,bv⟩ := atB
  have same := ReadOnlyFacts.queries_agree matrix bank checked values one satisfied qa qb am bm aa ba (ak.trans bk.symm)
  exact field_packing_injective (F := F) a b ad an bd bn (av.symm.trans (same.trans bv))

theorem found {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (bank : ReadOnlyMatrix.Record) (checked : ReadOnlyMatrix.check matrix bank = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (id : Nat) (cell : Cell) (atCell : CellAt values bank id cell) : table values bank id = some cell := by
  classical
  have present : ∃ cell, CellAt values bank id cell := ⟨cell,atCell⟩
  simp only [table,dite_eq_left present]
  congr 1
  exact cell_unique matrix bank checked values one satisfied id _ cell (Classical.choose_spec present) atCell

theorem witness {F : Type} [CommRing F] (values : Nat → F) (bank : ReadOnlyMatrix.Record)
    (id : Nat) (cell : Cell) (found : table values bank id = some cell) : CellAt values bank id cell := by
  classical
  unfold table at found
  split at found
  next present => exact Option.some.inj found ▸ Classical.choose_spec present
  next absent => contradiction

theorem query {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (bank : ReadOnlyMatrix.Record) (checked : ReadOnlyMatrix.check matrix bank = true)
    (width : bank.memory.valueBits = 64) (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (id : Fin (2^32)) (q : ReadOnlyMatrix.Entry) (member : q ∈ bank.queries)
    (active : E values q.active = 1) (address : E values q.address = (id.val : F)) :
    ∃ cell, table values bank id.val = some cell := by
  obtain ⟨value,bound,image⟩ := ReadOnlyFacts.query_value matrix bank checked values one satisfied q member
  rw [width] at bound
  let cell : Cell := ⟨value % (2^32),value / (2^32)⟩
  have depth : cell.depth < 2^32 := Nat.mod_lt value (by decide)
  have next : cell.next < 2^32 := by dsimp [cell]; omega
  have packed : pack cell = value := Nat.mod_add_div value (2^32)
  exact ⟨cell,found matrix bank checked values one satisfied id.val cell
    ⟨id.isLt,depth,next,q,member,active,address,by rw [packed]; exact image⟩⟩

theorem member_index {α : Type} [Inhabited α] (xs : List α) (x : α) (member : x ∈ xs) :
    ∃ i, i < xs.length ∧ xs.getD i default = x := by
  induction xs with
  | nil => simp at member
  | cons y ys ih =>
    rcases List.mem_cons.mp member with rfl | later
    · exact ⟨0,by simp,rfl⟩
    · obtain ⟨i,ib,same⟩ := ih later
      exact ⟨i+1,by simp; omega,by simpa using same⟩

theorem closed {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (splits : Splits) (tables : List ReadOnlyMatrix.Record) (s : DynamicTypingMatrix.Stage)
    (checked : BranchListCheck.check matrix splits tables s = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values) :
    Closed (table values (DynamicTypingMatrix.bank tables s 1)) := by
  have parts := checked
  simp only [BranchListCheck.check,Bool.and_eq_true_iff,decide_eq_true_eq] at parts
  have shape := parts.1.1.1.1
  have nsChecked := parts.1.1.2
  obtain ⟨_,_,_,_,_,_,_,_,membership⟩ := ReadOnlySound.checked_membership matrix _ nsChecked values one satisfied
  intro id cell seen
  obtain ⟨ib,db,nb,q,qm,qa,qk,qv⟩ := witness values _ id cell seen
  obtain ⟨entry,em,ea,ek,ev⟩ := membership q qm qa
  obtain ⟨i,inside,same⟩ := member_index _ entry em
  have rowChecked := List.all_eq_true.mp parts.2 i (List.mem_range.mpr inside)
  have address : E values (BranchListCheck.nodeRecord splits tables s i).entry.address = (id : F) := by
    change E values ((DynamicTypingMatrix.bank tables s 1).entries.getD i default).address = _
    rw [same]; exact ek.trans qk
  have active : E values (BranchListCheck.nodeRecord splits tables s i).entry.active = 1 := by
    change E values ((DynamicTypingMatrix.bank tables s 1).entries.getD i default).active = _
    rw [same]; exact ea
  obtain ⟨depth,next,less,encoded,tail⟩ := BranchListSound.node matrix _ rowChecked values one satisfied ⟨id,ib⟩ address active
  have payload : E values (BranchListCheck.nodeRecord splits tables s i).entry.value = (pack cell : F) := by
    change E values ((DynamicTypingMatrix.bank tables s 1).entries.getD i default).value = _
    rw [same]; exact ev.trans qv
  have decoded := field_packing_injective (F := F) ⟨depth.val,next.val⟩ cell depth.isLt next.isLt db nb (encoded.symm.trans payload)
  have nextSame : next.val = cell.next := congrArg Cell.next decoded
  refine ⟨by rw [← nextSame]; exact less,?_⟩
  by_cases zero : cell.next = 0
  · exact Or.inl zero
  · have enabled := tail (by rw [nextSame]; exact zero)
    have qm : (BranchListCheck.nodeRecord splits tables s i).query ∈ (DynamicTypingMatrix.bank tables s 1).queries := by
      change (DynamicTypingMatrix.bank tables s 1).queries.getD ((DynamicTypingMatrix.bank tables s 0).entries.length+i) default ∈ _
      rw [← List.getElem_eq_getD default]
      exact List.getElem_mem (by omega)
    obtain ⟨following,found⟩ := query matrix _ nsChecked shape.2.2.2.1 values one satisfied next _ qm enabled.1 enabled.2
    exact Or.inr ⟨following,by simpa only [nextSame] using found⟩

#print axioms cell_unique
#print axioms found
#print axioms query
#print axioms closed
end ZkBuild.BranchStore
