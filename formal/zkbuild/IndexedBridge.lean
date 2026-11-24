import IndexedStep

namespace ZkBuild.IndexedBridge
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix EnvelopeMatrix ModuleAuditIO
open IndexedMatrix
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

theorem member_context (matrix : Shape) (splits : Splits) (rows : List MemberRow) (index : Nat) (ph po pn : Linear)
    (checked : checkMembers matrix splits rows index ph po pn = true) (row : MemberRow) (member : row ∈ rows) :
    ∃ i h o n, checkMember matrix splits row i h o n = true := by
  induction rows generalizing index ph po pn with
  | nil => simp at member
  | cons first rest ih =>
    have parts := Bool.and_eq_true_iff.mp checked
    rcases List.mem_cons.mp member with rfl | later
    · exact ⟨index,ph,po,pn,parts.1⟩
    · exact ih (index+1) (address splits first).high (address splits first).low (node splits first).high parts.2 later

theorem table_member (tables : List ReadOnlyMatrix.Record) (declaration : DeclarationMatrix.Record)
    (indexed : IndexedMatrix.Record) (checked : IndexedMatrix.checkLinks tables declaration indexed = true)
    (index : Nat) (bound : index < 4) : IndexedMatrix.table tables indexed index ∈ tables := by
  have facts := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp checked).1
  have ib : index < indexed.tables.length := by rw [facts.1]; exact bound
  have mem : indexed.tables.getD index 0 ∈ indexed.tables := by rw [← List.getElem_eq_getD 0]; exact List.getElem_mem ib
  have tb := facts.2.1 _ mem
  unfold IndexedMatrix.table
  rw [← List.getElem_eq_getD default]; exact List.getElem_mem tb

/-- Every source vector entry authenticates an actual indexed-list cell and
    the node it follows. The tag in that node is the source type's tag. -/
theorem source_member {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (body : SourceEnvelope) (tables : List ReadOnlyMatrix.Record) (splits : Splits)
    (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record)
    (accepted : IndexedSound.check matrix body tables splits declaration indexed = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (source : VectorRow) (member : source ∈ declaration.params++declaration.results)
    (active : E values (DeclarationMatrix.get source.fields 0) = 1) :
    ∃ (row : MemberRow) (d : IndexedCell.Decoded), row ∈ indexed.members ∧
      IndexedCell.Bounded d ∧ IndexedCell.Represents values splits row d ∧ d.head ≠ 0 ∧ d.cursor ≠ 0 ∧
      E values (DeclarationMatrix.get source.fields 2) = (d.tag.val : F) ∧
      E values source.memberQuery.address = ((d.ordinal+2^32*d.head : Nat) : F) ∧
      E values source.memberQuery.value = ((d.tag.val+8*d.cursor : Nat) : F) ∧
      ∃ node ∈ (IndexedMatrix.table tables indexed 3).entries,
        E values node.active = 1 ∧ E values node.address = (d.cursor : F) ∧
        E values node.value = ((d.tag.val+8*d.next : Nat) : F) := by
  have parts := Bool.and_eq_true_iff.mp accepted
  have declarationChecks := (Bool.and_eq_true_iff.mp parts.1).2
  have splitChecks := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp parts.1).1).2
  have tableChecks := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp parts.1).1).1).2
  have idx := parts.2
  simp only [IndexedMatrix.check,Bool.and_eq_true_iff] at idx
  have indexedLinks : IndexedMatrix.checkLinks tables declaration indexed = true := by grind only
  have ilinks := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp indexedLinks).1
  have decl := declarationChecks
  simp only [DeclarationMatrix.check,Bool.and_eq_true_iff] at decl
  have declarationLinks : DeclarationMatrix.checkLinks tables declaration = true := by grind only
  have dlinks := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp declarationLinks).1
  have dm : DeclarationMatrix.table tables declaration 4 ∈ tables := by
    have bound : 4 < declaration.tables.length := by rw [dlinks.1]; decide
    have mem : declaration.tables.getD 4 0 ∈ declaration.tables := by rw [← List.getElem_eq_getD 0]; exact List.getElem_mem bound
    unfold DeclarationMatrix.table
    rw [← List.getElem_eq_getD default]; exact List.getElem_mem (dlinks.2.1 _ mem)
  have dq : source.memberQuery ∈ (DeclarationMatrix.table tables declaration 4).queries := by
    have linked : (DeclarationMatrix.table tables declaration 4).queries = declaration.params.map VectorRow.memberQuery++declaration.results.map VectorRow.memberQuery := by grind only
    rw [linked,← List.map_append]
    exact List.mem_map.mpr ⟨source,member,rfl⟩
  have sourceCheck : ∃ params i p a c, checkVector matrix body.tokens splits source params i p a c = true := by
    rcases List.mem_append.mp member with param | result
    · have check : checkVectors matrix body.tokens splits true declaration.params 0 o z z = true := by grind only
      obtain ⟨i,p,a,c,checked⟩ := DeclarationSound.vector_member matrix body.tokens splits true declaration.params 0 o z z check source param
      exact ⟨true,i,p,a,c,checked⟩
    · have check : checkVectors matrix body.tokens splits false declaration.results 0 o z z = true := by grind only
      obtain ⟨i,p,a,c,checked⟩ := DeclarationSound.vector_member matrix body.tokens splits false declaration.results 0 o z z check source result
      exact ⟨false,i,p,a,c,checked⟩
  obtain ⟨params,si,sp,sa,sc,sourceCheck⟩ := sourceCheck
  have sourceShape := DeclarationVector.vector_metadata matrix body.tokens splits source params si sp sa sc sourceCheck
  have sourceQueryActive : source.memberQuery.active = DeclarationMatrix.get source.fields 0 := sourceShape.2.2.2.2.2.2.2.2.2.2.2.2.2.2
  obtain ⟨_,_,_,_,_,_,_,_,dqueries⟩ := ReadOnlySound.checked_membership matrix _ (List.all_eq_true.mp tableChecks _ dm) values oneValue satisfied
  obtain ⟨entry,em,ea,ek,ev⟩ := dqueries source.memberQuery dq (by rw [sourceQueryActive]; exact active)
  have entryLink : (DeclarationMatrix.table tables declaration 4).entries = indexed.members.map MemberRow.entry := by grind only
  rw [entryLink] at em
  obtain ⟨row,rm,same⟩ := List.mem_map.mp em
  subst entry
  have rowChecks : checkMembers matrix splits indexed.members 0 z z z = true := by grind only
  obtain ⟨i,h,o,n,rowCheck⟩ := member_context matrix splits indexed.members 0 z z z rowChecks row rm
  obtain ⟨d,bound,image,nonempty,nonzero⟩ := IndexedCell.decode matrix splits splitChecks row i h o n rowCheck values oneValue satisfied ea
  have snode := sourceShape.2.2.2.2.2.2.2.2.2.2.2.1
  have snmember : split splits source.node ∈ splits := by
    rw [split,← List.getElem_eq_getD default]; exact List.getElem_mem sourceShape.2.2.2.2.2.1
  obtain ⟨value,tag,cursor,vb,tb,cb,vi,ti,ci,packed,_,_⟩ := PackedFields.checked_split matrix _ (List.all_eq_true.mp splitChecks _ snmember) values oneValue satisfied
  have tagBound : tag < 8 := by simpa [snode.2.1] using tb
  have cursorBound : cursor < 2^32 := by simpa [snode.2.2] using cb
  have sourceValue : E values source.memberQuery.value = ((tag+8*cursor : Nat) : F) := by
    rw [snode.1] at vi
    simpa [packed,snode.2.1] using vi
  have memberValue : E values source.memberQuery.value = ((d.tag.val+8*d.cursor : Nat) : F) := ev.symm.trans image.2.2.2.2.2.2.2.1
  have natural := DeclarationLocations.natural_equal (F := F) (tag+8*cursor) (d.tag.val+8*d.cursor)
    (by omega) (by have a := d.tag.isLt; have b := bound.2.2.1; omega) (sourceValue.symm.trans memberValue)
  have sameTag : tag = d.tag.val := by
    have low := congrArg (fun n => n % 8) natural
    have actualBound : d.tag.val < 8 := by have b := d.tag.isLt; omega
    simpa [Nat.add_mod,Nat.mod_eq_of_lt tagBound,Nat.mod_eq_of_lt actualBound] using low
  have sourceHolds := DeclarationVector.vector_holds matrix body.tokens splits source params si sp sa sc sourceCheck values satisfied
  have endPart := DeclarationVector.part_holds values body.tokens splits source params sp sa sc sourceHolds 18 (by decide)
  have tagGate := endPart (DeclarationMatrix.gate (DeclarationMatrix.get source.fields 0) (sub (split splits source.node).low (DeclarationMatrix.get source.fields 2))) (by simp [DeclarationMatrix.vectorParts])
  change E values (DeclarationMatrix.get source.fields 0)*E values (sub (split splits source.node).low (DeclarationMatrix.get source.fields 2)) = E values z at tagGate
  have zero : E values z = 0 := by simp [z,eval_constant values oneValue]
  rw [active,eval_sub,ti,sameTag,zero] at tagGate
  have nodeTableMember := table_member tables declaration indexed indexedLinks 3 (by decide)
  obtain ⟨_,_,_,_,_,_,_,_,nqueries⟩ := ReadOnlySound.checked_membership matrix _ (List.all_eq_true.mp tableChecks _ nodeTableMember) values oneValue satisfied
  have nq : row.nodeQuery ∈ (IndexedMatrix.table tables indexed 3).queries := by
    have linked : (IndexedMatrix.table tables indexed 3).queries = indexed.members.map MemberRow.nodeQuery++indexed.singletons.map SingletonRow.nodeQuery := by grind only
    rw [linked]; exact List.mem_append_left _ (List.mem_map.mpr ⟨row,rm,rfl⟩)
  have nactive := (IndexedCell.metadata matrix splits row i h o n rowCheck).2.2.2.2.2.2.1
  obtain ⟨node,nm,na,nk,nv⟩ := nqueries row.nodeQuery nq (by rw [nactive]; exact ea)
  exact ⟨row,d,rm,bound,image,nonempty,nonzero,by grind,ek.symm.trans image.2.2.2.2.2.2.1,memberValue,
    node,nm,na,nk.trans image.2.2.2.2.2.2.2.2.1,nv.trans image.2.2.2.2.2.2.2.2.2.1⟩

#print axioms source_member
end ZkBuild.IndexedBridge
