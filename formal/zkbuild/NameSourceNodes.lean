import NameSourceRules
set_option autoImplicit false
namespace ZkBuild.NameSourceNodes
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix NameSourceMatrix NameSourceRules ShaProgram
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

def bank (tables : List ReadOnlyMatrix.Record) (frame : NameFrameMatrix.Record) (source : NameSourceMatrix.Record) :=
  NameSourceMatrix.table tables source (if frame.flat then 1 else 0)

theorem bank_facts (matrix : Shape) (tokens : Tokens) (tables : List ReadOnlyMatrix.Record)
    (tableChecks : tables.all (ReadOnlyMatrix.check matrix) = true)
    (frame : NameFrameMatrix.Record) (graph : NameGraphMatrix.Record) (source : NameSourceMatrix.Record)
    (checked : NameSourceMatrix.check matrix tokens tables frame graph source = true) :
    ReadOnlyMatrix.check matrix (bank tables frame source) = true ∧
      (bank tables frame source).entries = (NameGraphMatrix.table tables graph 0).entries ∧
      (bank tables frame source).queries = source.bytes.map ByteRow.nodeQuery := by
  obtain ⟨_,_,_,count,indexBounds,entries,queries,_⟩ := metadata matrix tokens tables frame graph source checked
  have inside : (if frame.flat then 1 else 0) < source.tables.length := by rw [count]; cases frame.flat <;> decide
  have im : source.tables.getD (if frame.flat then 1 else 0) 0 ∈ source.tables := by rw [← List.getElem_eq_getD 0]; exact List.getElem_mem inside
  have member : bank tables frame source ∈ tables := by
    unfold bank NameSourceMatrix.table
    rw [← List.getElem_eq_getD default]
    exact List.getElem_mem (indexBounds _ im)
  exact ⟨List.all_eq_true.mp tableChecks _ member,entries,queries⟩

theorem query_word {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (tokens : Tokens) (tables : List ReadOnlyMatrix.Record) (tableChecks : tables.all (ReadOnlyMatrix.check matrix) = true)
    (frame : NameFrameMatrix.Record) (graph : NameGraphMatrix.Record) (source : NameSourceMatrix.Record)
    (sourceCheck : NameSourceMatrix.check matrix tokens tables frame graph source = true)
    (graphCheck : NameGraphMatrix.check matrix tables graph = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (b : ByteRow) (member : b ∈ source.bytes) (active : E values b.nodeQuery.active = 1)
    (id word : Nat) (qi : E values b.nodeQuery.address = (id : F))
    (atWord : NameGraphTable.WordAt values (NameGraphMatrix.table tables graph 0) id word) :
    E values b.nodeQuery.value = (word : F) := by
  have facts := bank_facts matrix tokens tables tableChecks frame graph source sourceCheck
  obtain ⟨_,_,q,qm,qa,qk,qv⟩ := atWord
  have gc := NameGraphLinks.bank_checked matrix tables tableChecks graph graphCheck 0 (by decide)
  obtain ⟨_,_,_,_,_,_,_,_,lookup⟩ := ReadOnlySound.checked_membership matrix _ gc values oneValue satisfied
  obtain ⟨entry,em,ea,ek,ev⟩ := lookup q qm qa
  have qm : b.nodeQuery ∈ (bank tables frame source).queries := by rw [facts.2.2]; exact List.mem_map.mpr ⟨b,member,rfl⟩
  have sourceMember : entry ∈ (bank tables frame source).entries := by rw [facts.2.1]; exact em
  have same := ReadOnlySound.checked_expected matrix _ facts.1 values oneValue satisfied b.nodeQuery entry qm sourceMember active ea
    (ek.trans (qk.trans qi.symm))
  exact same.trans (ev.trans qv)

theorem query_nonzero {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (tokens : Tokens) (tables : List ReadOnlyMatrix.Record) (tableChecks : tables.all (ReadOnlyMatrix.check matrix) = true)
    (frame : NameFrameMatrix.Record) (graph : NameGraphMatrix.Record) (source : NameSourceMatrix.Record)
    (sourceCheck : NameSourceMatrix.check matrix tokens tables frame graph source = true)
    (graphCheck : NameGraphMatrix.check matrix tables graph = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (b : ByteRow) (member : b ∈ source.bytes) (active : E values b.nodeQuery.active = 1)
    (id : Nat) (bound : id < 2^32) (qi : E values b.nodeQuery.address = (id : F)) : 0 < id := by
  have facts := bank_facts matrix tokens tables tableChecks frame graph source sourceCheck
  have qm : b.nodeQuery ∈ (bank tables frame source).queries := by rw [facts.2.2]; exact List.mem_map.mpr ⟨b,member,rfl⟩
  obtain ⟨_,_,_,_,_,_,_,_,lookup⟩ := ReadOnlySound.checked_membership matrix _ facts.1 values oneValue satisfied
  obtain ⟨entry,em,ea,ek,_⟩ := lookup b.nodeQuery qm active
  have metadata := NameGraphLinks.metadata matrix tables graph graphCheck
  rw [facts.2.1,metadata.2.2.2.1] at em
  obtain ⟨node,nm,eq⟩ := List.mem_map.mp em
  subst entry
  obtain ⟨i,ib,nc⟩ := NameGraphLinks.node_checked matrix tables graph graphCheck node nm
  have indexImage := NameGraphRules.node_index matrix node i nc values oneValue satisfied ea
  have indexBound : i+1 < 2^32 := by have length := metadata.2.2.1; omega
  have same : id = i+1 := DeclarationLocations.natural_equal (F := F) _ _ (by omega) (by omega)
    (qi.symm.trans (ek.symm.trans indexImage))
  omega

/-- One actual source-byte reader follows one node of the verified graph. -/
theorem read_node {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (tokens : Tokens) (tables : List ReadOnlyMatrix.Record) (tableChecks : tables.all (ReadOnlyMatrix.check matrix) = true)
    (frame : NameFrameMatrix.Record) (graph : NameGraphMatrix.Record) (source : NameSourceMatrix.Record)
    (sourceCheck : NameSourceMatrix.check matrix tokens tables frame graph source = true)
    (graphCheck : NameGraphMatrix.check matrix tables graph = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (b : ByteRow) (member : b ∈ source.bytes) (f : NameFrameMatrix.ByteRow) (i : Nat) (po pt : Linear)
    (checked : checkByte matrix tokens frame.flat f b i po pt = true)
    (active : E values b.nodeQuery.active = 1) (bytes : List Nat)
    (represented : RepWire values (NameGraphMatrix.table tables graph 0) b.nodeQuery.address bytes) :
    ∃ first rest, bytes = first::rest ∧ E values (field b 0) = (first : F) ∧
      RepWire values (NameGraphMatrix.table tables graph 0) (field b 1) rest := by
  obtain ⟨id,ib,hi,rep⟩ := represented
  have nonzero := query_nonzero matrix tokens tables tableChecks frame graph source sourceCheck graphCheck values oneValue satisfied b member active id ib hi
  cases rep with
  | nil => omega
  | @cons _ node rest _ found tail =>
    obtain ⟨word,atWord,same⟩ := NameGraphStrings.table_word values _ id node found
    have value := query_word matrix tokens tables tableChecks frame graph source sourceCheck graphCheck values oneValue satisfied b member active id word hi atWord
    obtain ⟨actual,ab,ai,byteImage,tailImage⟩ := byte_word matrix tokens frame.flat f b i po pt checked values oneValue satisfied
    have equal : actual = word := DeclarationLocations.natural_equal (F := F) _ _ (by omega) (by have b := atWord.2.1; omega) (ai.symm.trans value)
    subst actual
    have byteSame : NameGraphRules.byteOf word = node.byte.val := congrArg (fun n : NameLists.Node => n.byte.val) same
    have tailSame : NameGraphRules.tailOf word = node.next := congrArg (fun n : NameLists.Node => n.next) same
    refine ⟨node.byte.val,rest,rfl,?_,node.next,?_,?_,tail⟩
    · simpa only [byteSame] using byteImage
    · rw [← tailSame]; exact Nat.mod_lt _ (by decide)
    · simpa only [tailSame] using tailImage

#print axioms query_word
#print axioms query_nonzero
#print axioms read_node
end ZkBuild.NameSourceNodes
