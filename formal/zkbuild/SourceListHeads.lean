import SourceListSelection

namespace ZkBuild.SourceListHeads
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix EnvelopeMatrix DeclarationLocations SourceListSelection
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

/-- A vector member and its source type declaration query the same metadata
    key, so their parameter/result heads are the same bounded integers. -/
theorem metadata_heads {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record) (splits : Splits)
    (declaration : DeclarationMatrix.Record) (accepted : DeclarationSound.check matrix body tables splits declaration = true)
    (typeRow : TypeRow) (typeMember : typeRow ∈ declaration.types) (i : Nat) (tp : List Linear) (tv : Linear)
    (typeCheck : checkType matrix body.tokens splits typeRow i tp tv declaration.typeEnd = true)
    (params : Bool) (source : VectorRow) (sourceMember : source ∈ vectorRows declaration params)
    (index : Nat) (sp sa sc : Linear) (sourceCheck : checkVector matrix body.tokens splits source params index sp sa sc = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (ta : E values (get typeRow.fields 0) = 1) (va : E values (get source.fields 0) = 1)
    (sourceIndex : E values (split splits source.keySplit).high = (i : F)) :
    E values (split splits source.heads).low = E values (split splits typeRow.heads).low ∧
    E values (split splits source.heads).high = E values (split splits typeRow.heads).high := by
  have parts := Bool.and_eq_true_iff.mp accepted
  have splitChecks := (Bool.and_eq_true_iff.mp parts.1).2
  have tableChecks := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp parts.1).1).2
  have dec := parts.2
  simp only [DeclarationMatrix.check,Bool.and_eq_true_iff] at dec
  have links : checkLinks tables declaration = true := by grind only
  have facts := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp links).1
  let consumer := DeclarationMatrix.table tables declaration 2
  have cm : consumer ∈ tables := by
    have b : 2 < declaration.tables.length := by rw [facts.1]; decide
    have m : declaration.tables.getD 2 0 ∈ declaration.tables := by rw [← List.getElem_eq_getD 0]; exact List.getElem_mem b
    unfold consumer DeclarationMatrix.table
    rw [← List.getElem_eq_getD default]; exact List.getElem_mem (facts.2.1 _ m)
  have cq : consumer.queries = declaration.types.map TypeRow.metadata++declaration.params.map VectorRow.metadata++declaration.results.map VectorRow.metadata := by grind only
  have tq : typeRow.metadata ∈ consumer.queries := by rw [cq]; exact List.mem_append_left _ (List.mem_append_left _ (List.mem_map.mpr ⟨typeRow,typeMember,rfl⟩))
  have sq : source.metadata ∈ consumer.queries := by
    rw [cq]
    cases params
    · exact List.mem_append_right _ (List.mem_map.mpr ⟨source,sourceMember,rfl⟩)
    · exact List.mem_append_left _ (List.mem_append_right _ (List.mem_map.mpr ⟨source,sourceMember,rfl⟩))
  have ts := DeclarationType.type_metadata matrix body.tokens splits typeRow i tp tv declaration.typeEnd typeCheck
  have ss := DeclarationVector.vector_metadata matrix body.tokens splits source params index sp sa sc sourceCheck
  have typeHolds := DeclarationType.type_holds matrix body.tokens splits typeRow i tp tv declaration.typeEnd typeCheck values satisfied
  have typePart := DeclarationType.part_holds values body.tokens splits typeRow i tp tv declaration.typeEnd typeHolds 10 (by decide)
  have tkey := multiply_sound values (get typeRow.fields 0) (n (2*i+1)) typeRow.metadata.address (typePart _ (by simp [typeParts,queryGate]))
  have literal : E values (n (2*i+1)) = ((2*i+1 : Nat) : F) := (eval_constant values oneValue (Int.ofNat (2*i+1))).trans (Ring.intCast_natCast _)
  have tki : E values typeRow.metadata.address = ((2*i+1 : Nat) : F) := by rw [tkey,ta,literal,Semiring.one_mul]
  have sourceHolds := DeclarationVector.vector_holds matrix body.tokens splits source params index sp sa sc sourceCheck values satisfied
  have sourcePart := DeclarationVector.part_holds values body.tokens splits source params sp sa sc sourceHolds 14 (by decide)
  have skey := multiply_sound values (get source.fields 0) (scale (split splits source.keySplit).high 2++o) source.metadata.address (sourcePart _ (by simp [vectorParts,queryGate]))
  have add : E values (scale (split splits source.keySplit).high 2++o) = E values (scale (split splits source.keySplit).high 2)+E values o := eval_append values _ _
  have scaled := eval_scale values (split splits source.keySplit).high 2
  change E values (scale (split splits source.keySplit).high 2) = ((2 : Int) : F)*E values (split splits source.keySplit).high at scaled
  have two : ((2 : Int) : F) = ((2 : Nat) : F) := Ring.intCast_natCast 2
  have one : E values o = 1 := by simp [o,eval_constant values oneValue]
  have ski : E values source.metadata.address = ((2*i+1 : Nat) : F) := by
    rw [skey,va,Semiring.one_mul,add,scaled,two,sourceIndex,one,Semiring.natCast_add,Semiring.natCast_mul,Semiring.natCast_one]
  have tac : typeRow.metadata.active = get typeRow.fields 0 := ts.2.2.2.2.2.2.2.2.2.2.2.1
  have sac : source.metadata.active = get source.fields 0 := ss.2.2.2.2.2.2.2.2.2.2.2.2.2.1
  have same := ReadOnlyFacts.queries_agree matrix consumer (List.all_eq_true.mp tableChecks consumer cm) values oneValue satisfied source.metadata typeRow.metadata sq tq
    (by rw [sac]; exact va) (by rw [tac]; exact ta) (ski.trans tki.symm)
  have sm : split splits source.heads ∈ splits := by rw [split,← List.getElem_eq_getD default]; exact List.getElem_mem ss.2.2.2.2.1
  have tm : split splits typeRow.heads ∈ splits := by rw [split,← List.getElem_eq_getD default]; exact List.getElem_mem ts.2.2.2.2.2.2.1
  have sf := ss.2.2.2.2.2.2.2.2.2.2.1
  have tf := ts.2.2.2.2.2.2.2.2.2.2.1
  exact equal_heads matrix _ _ (List.all_eq_true.mp splitChecks _ sm) (List.all_eq_true.mp splitChecks _ tm)
    sf.2.1 sf.2.2 tf.2.1 tf.2.2 values oneValue satisfied (by rw [sf.1,tf.1]; exact same)

#print axioms metadata_heads
end ZkBuild.SourceListHeads
