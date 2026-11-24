import IndexedTypeLists
set_option autoImplicit false
namespace ZkBuild.IndexedSingletonList
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix EnvelopeMatrix
attribute [local instance] Ring.intCast Semiring.natCast

/-- The seven singleton initializers denote exactly their one-element lists. -/
theorem initializer {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record) (splits : Splits)
    (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record)
    (accepted : IndexedSound.check matrix body tables splits declaration indexed=true)
    (values : Nat → F) (one : values 0=1) (satisfied : Satisfied matrix values)
    (entry : ReadOnlyMatrix.Entry) (member : entry ∈ (IndexedMatrix.table tables indexed 2).entries) :
    ∃ tag : Fin 7, ∃ head : Fin (2^32),
      E values entry.address=(tag.val:F) ∧ E values entry.value=(head.val:F) ∧
      SignatureLists.Represents (IndexedNodeTable.table values (IndexedLengths.banks tables indexed).nodes) head.val [tag.val] := by
  have parts := (Bool.and_eq_true_iff.mp accepted).2
  simp only [IndexedMatrix.check,Bool.and_eq_true_iff] at parts
  have count : indexed.singletons.length=7 := by grind only
  have links : IndexedMatrix.checkLinks tables declaration indexed=true := by grind only
  have shape := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp links).1
  have entries : (IndexedMatrix.table tables indexed 2).entries=indexed.singletons.map IndexedMatrix.SingletonRow.entry := by grind only
  rw [entries] at member
  obtain ⟨row,rm,rfl⟩ := List.mem_map.mp member
  obtain ⟨i,ib,atRow⟩ := List.mem_iff_getElem.mp rm
  have rb : i<7 := by omega
  have rd : indexed.singletons.getD i default=row := by rw [← List.getElem_eq_getD (h:=ib) default]; exact atRow
  have checks : (List.range indexed.singletons.length).all
      (fun i => IndexedMatrix.checkSingleton matrix (indexed.singletons.getD i default) i)=true := by grind only
  have rc := List.all_eq_true.mp checks i (List.mem_range.mpr ib)
  rw [rd] at rc
  have boundary := IndexedBoundary.singleton matrix row i rc values one satisfied
  have banks := IndexedLengths.checked_banks (F:=F) matrix body tables splits declaration indexed accepted
  have le : (IndexedLengths.banks tables indexed).lengths.entries=indexed.lengths.map IndexedMatrix.LengthRow.entry := by exact shape.2.2.1
  have lq : IndexedMatrix.singletonLength row ∈ (IndexedLengths.banks tables indexed).lengths.queries := by
    have eq : (IndexedLengths.banks tables indexed).lengths.queries = indexed.members.map IndexedMatrix.MemberRow.lengthQuery ++
        indexed.metadata.flatMap (fun m => [m.params,m.results]) ++ indexed.singletons.map IndexedMatrix.singletonLength ++ indexed.extraLengths := shape.2.2.2.1
    rw [eq]
    exact List.mem_append_left _ (List.mem_append_right _ (List.mem_map.mpr ⟨row,rm,rfl⟩))
  have enabled : E values (IndexedMatrix.singletonLength row).active=1 := by
    simpa only [IndexedMatrix.singletonLength,o,Ring.intCast_one] using eval_constant values one 1
  obtain ⟨head,len,tags,hb,lb,hi,li,rep,length,_⟩ := IndexedTypeLists.queried_list matrix body tables splits declaration indexed accepted
    _ banks.lengthsChecked le _ lq values one satisfied enabled
  have hi : E values row.entry.value=(head:F) := hi
  have lenOne : len=1 := DeclarationLocations.natural_equal (F:=F) len 1 (by omega) (by decide)
    (li.symm.trans (by simpa only [IndexedMatrix.singletonLength,o,Ring.intCast_one,Semiring.natCast_one] using eval_constant values one 1))
  have nonzero : head≠0 := by
    intro zero
    rw [zero] at rep
    have empty := SignatureLists.represents_zero _ tags rep
    rw [empty,lenOne] at length
    simp at length
  have nq : row.nodeQuery ∈ (IndexedLengths.banks tables indexed).nodes.queries := by
    have eq : (IndexedLengths.banks tables indexed).nodes.queries = indexed.members.map IndexedMatrix.MemberRow.nodeQuery ++
        indexed.singletons.map IndexedMatrix.SingletonRow.nodeQuery := shape.2.2.2.2.2.2.2.2.1
    rw [eq]
    exact List.mem_append_right _ (List.mem_map.mpr ⟨row,rm,rfl⟩)
  have found := IndexedNodeTable.found matrix _ banks.nodesChecked values one satisfied head ⟨⟨i,rb⟩,0⟩
    ⟨by change (0:Nat)<2^32; decide,row.nodeQuery,nq,boundary.2.2.1,boundary.2.2.2.1.trans hi,by simpa using boundary.2.2.2.2⟩
  exact ⟨⟨i,rb⟩,⟨head,hb⟩,boundary.2.1,hi,.cons nonzero found .nil⟩

#print axioms initializer
end ZkBuild.IndexedSingletonList
