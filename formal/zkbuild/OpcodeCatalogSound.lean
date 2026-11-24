import InstructionDecodeMatrix
set_option autoImplicit false
set_option maxRecDepth 4096
namespace ZkBuild.OpcodeCatalogSound
open Lean.Grind CircuitShape FullMatrix GadgetShape
attribute [local instance] Ring.intCast Semiring.natCast

theorem table (catalog : InstructionDecodeMatrix.Catalog)
    (checked : InstructionDecodeMatrix.catalogCheck catalog = true)
    (id : Nat) (r : LookupEmbedded.Record) (member : (id,r) ∈ catalog) :
    r.columns = 8 ∧ LookupEmbedded.checkTable r 16 OpcodeCatalog.payload = true := by
  have keyMember : InstructionDecodeMatrix.tableView (id,r) ∈ catalog.map InstructionDecodeMatrix.tableView := List.mem_map_of_mem member
  unfold InstructionDecodeMatrix.catalogCheck at checked
  cases h : catalog.map InstructionDecodeMatrix.tableView with
  | nil => simp [h] at keyMember
  | cons first rest =>
    have checks := (Bool.and_eq_true_iff.mp checked).2
    simp only [h,List.head?_cons] at checks
    have tableCheck := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp checks).1).2
    rw [InstructionDecodeMatrix.canonicalTable_exact] at tableCheck
    have columns : first.columns = 8 := by simpa using (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp checks).1).1
    have same : r.columns = first.columns ∧ r.root = first.root ∧ r.nodes = first.nodes :=
      _root_.of_decide_eq_true (List.all_eq_true.mp (Bool.and_eq_true_iff.mp checks).2 _ (by simpa [h] using keyMember))
    refine ⟨same.1.trans columns,?_⟩
    unfold LookupEmbedded.checkTable
    rw [same.1,same.2.1,same.2.2]
    exact tableCheck

theorem values {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (catalog : InstructionDecodeMatrix.Catalog)
    (checked : InstructionDecodeMatrix.catalogCheck catalog = true)
    (id : Nat) (r : LookupEmbedded.Record) (member : (id,r) ∈ catalog)
    (matrixChecked : LookupEmbedded.check matrix r = true)
    (opcode : Nat) (bounded : opcode < 65536)
    (assignment : Nat → F) (oneValue : assignment 0 = 1) (satisfied : Satisfied matrix assignment)
    (input : E assignment r.input = (opcode : F)) :
    r.outputs.map (E assignment) = (List.range 8).map (fun field => (OpcodeCatalog.payload opcode field : F)) := by
  obtain ⟨columns,canonical⟩ := table catalog checked id r member
  have result := LookupEmbedded.checked_values matrix r matrixChecked 16 OpcodeCatalog.payload canonical opcode bounded assignment oneValue satisfied input
  simpa only [columns] using result
theorem decoded {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (catalog : InstructionDecodeMatrix.Catalog)
    (checked : InstructionDecodeMatrix.catalogCheck catalog = true)
    (id : Nat) (r : LookupEmbedded.Record) (member : (id,r) ∈ catalog)
    (matrixChecked : LookupEmbedded.check matrix r = true)
    (assignment : Nat → F) (oneValue : assignment 0 = 1) (satisfied : Satisfied matrix assignment) :
    ∃ opcode : Nat, opcode < 65536 ∧ E assignment r.input = (opcode : F) ∧
      r.outputs.map (E assignment) = (List.range 8).map (fun field => (OpcodeCatalog.payload opcode field : F)) := by
  have rangeCheck := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp matrixChecked).1).2
  have certificate := RangeUse.checked_certificate matrix r.range r.input 16 rangeCheck assignment oneValue satisfied
  obtain ⟨opcode,bounded,image,_⟩ := TokenInteger.certificate_nat assignment oneValue r.input (RangeUse.bits r.range) 16 certificate
  exact ⟨opcode,bounded,image,values matrix catalog checked id r member matrixChecked opcode bounded assignment oneValue satisfied image⟩

#print axioms table
#print axioms values
#print axioms decoded
end ZkBuild.OpcodeCatalogSound
