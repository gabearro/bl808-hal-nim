import NameGraphLookup
set_option autoImplicit false
namespace ZkBuild.NameGraphLinks
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix NameGraphMatrix NameGraphRules ShaProgram
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

theorem metadata (matrix : Shape) (tables : List ReadOnlyMatrix.Record) (r : NameGraphMatrix.Record)
    (checked : NameGraphMatrix.check matrix tables r = true) : links tables r := by
  simp only [NameGraphMatrix.check,Bool.and_eq_true_iff,decide_eq_true_eq] at checked
  grind only

theorem bank_checked (matrix : Shape) (tables : List ReadOnlyMatrix.Record)
    (checks : tables.all (ReadOnlyMatrix.check matrix) = true) (r : NameGraphMatrix.Record)
    (checked : NameGraphMatrix.check matrix tables r = true) (i : Nat) (ib : i < 2) :
    ReadOnlyMatrix.check matrix (table tables r i) = true := by
  have m := metadata matrix tables r checked
  have inside : i < r.tables.length := by rw [m.1]; exact ib
  have im : r.tables.getD i 0 ∈ r.tables := by rw [← List.getElem_eq_getD 0]; exact List.getElem_mem inside
  have bm : table tables r i ∈ tables := by
    unfold NameGraphMatrix.table; rw [← List.getElem_eq_getD default]; exact List.getElem_mem (m.2.1 _ im)
  exact List.all_eq_true.mp checks _ bm

theorem node_checked (matrix : Shape) (tables : List ReadOnlyMatrix.Record) (r : NameGraphMatrix.Record)
    (checked : NameGraphMatrix.check matrix tables r = true) (node : Node) (member : node ∈ r.nodes) :
    ∃ i, i < r.nodes.length ∧ checkNode matrix node i = true := by
  obtain ⟨i,ib,equal⟩ := List.mem_iff_getElem.mp member
  have checks := checked
  simp only [NameGraphMatrix.check,Bool.and_eq_true_iff] at checks
  have all : r.nodes.zipIdx.all (fun (node,i) => checkNode matrix node i) = true := by grind only
  have bound : i < r.nodes.zipIdx.length := by simpa using ib
  have zipped := List.getElem_mem bound
  have pair : (node,i) ∈ r.nodes.zipIdx := by simpa [List.getElem_zipIdx,equal] using zipped
  exact ⟨i,ib,List.all_eq_true.mp all (node,i) pair⟩

theorem node_table (matrix : Shape) (tables : List ReadOnlyMatrix.Record) (r : NameGraphMatrix.Record)
    (checked : NameGraphMatrix.check matrix tables r = true) (node : Node) (member : node ∈ r.nodes) :
    LookupEmbedded.checkTable node.lookup 14 Utf8Suffix.expected = true := by
  have checks := checked
  simp only [NameGraphMatrix.check,Bool.and_eq_true_iff] at checks
  exact NameGraphLookup.table_member r.nodes (by grind only) node member

theorem root_checked (matrix : Shape) (tables : List ReadOnlyMatrix.Record) (r : NameGraphMatrix.Record)
    (checked : NameGraphMatrix.check matrix tables r = true) (root : Root) (member : root ∈ r.roots) : checkRoot matrix root = true := by
  have checks := checked
  simp only [NameGraphMatrix.check,Bool.and_eq_true_iff] at checks
  exact List.all_eq_true.mp (by grind only) root member

theorem decreasing {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (r : Node) (i : Nat) (checked : checkNode matrix r i = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (active : E values r.entry.active = 1) (tail : Nat) (bound : tail < 2^32)
    (tailImage : E values (field r 1) = (tail : F)) (ib : i+1 < 2^32) : tail < i+1 := by
  have checks := checked
  simp only [checkNode,Bool.and_eq_true_iff] at checks
  have rangeCheck : RangeUse.check matrix (nodeRange r 2) (field r 6) 32 = true := by grind only
  obtain ⟨delta,db,di⟩ := RangeReuse.certificate_sound _ _ _ (RangeUse.checked_certificate matrix _ _ _ rangeCheck values oneValue satisfied)
  have ending := part values r i (holds matrix r i checked values satisfied) 5 (by decide)
  have equation := multiply_sound values r.entry.active (sub (sub r.entry.address (field r 1)) o) (field r 6) (ending _ (by simp [nodeParts]))
  have one : E values o = 1 := by simp [o,eval_constant values oneValue]
  have idImage := node_index matrix r i checked values oneValue satisfied active
  rw [active,eval_sub,eval_sub,one,idImage,tailImage,di] at equation
  exact ReadOnlyMemory.order_gate (F := F) (2^32) tail (i+1) delta bound ib db (by decide) (by grind)

#print axioms node_checked
#print axioms decreasing
end ZkBuild.NameGraphLinks
