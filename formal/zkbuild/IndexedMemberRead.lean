import IndexedLookup
set_option autoImplicit false
namespace ZkBuild.IndexedMemberRead
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix
attribute [local instance] Ring.intCast Semiring.natCast

/-- Active member queries cannot name an out-of-range ordinal. The bound
    follows from the checked suffix and its closing row, not a caller premise. -/
theorem queried {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record) (splits : Splits)
    (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record)
    (accepted : IndexedSound.check matrix body tables splits declaration indexed=true)
    (consumer : ReadOnlyMatrix.Record) (consumerChecked : ReadOnlyMatrix.check matrix consumer=true)
    (entries : consumer.entries=indexed.members.map IndexedMatrix.MemberRow.entry)
    (query : ReadOnlyMatrix.Entry) (member : query ∈ consumer.queries)
    (values : Nat → F) (one : values 0=1) (satisfied : Satisfied matrix values) (active : E values query.active=1) :
    ∃ head ordinal cursor : Fin (2^32), ∃ tag : Fin 7, ∃ tags : List Nat,
      E values query.address=((ordinal.val+2^32*head.val:Nat):F) ∧
      E values query.value=((tag.val+8*cursor.val:Nat):F) ∧
      SignatureLists.Represents (IndexedNodeTable.table values (IndexedLengths.banks tables indexed).nodes) head.val tags ∧
      ordinal.val<tags.length ∧ tags.getD ordinal.val 0=tag.val := by
  obtain ⟨_,_,_,_,_,_,_,_,membership⟩ := ReadOnlySound.checked_membership matrix consumer consumerChecked values one satisfied
  obtain ⟨entry,em,ea,ek,_⟩ := membership query member active
  rw [entries] at em
  obtain ⟨row,rm,rfl⟩ := List.mem_map.mp em
  have parts := Bool.and_eq_true_iff.mp accepted
  have splitChecks := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp parts.1).1).2
  have idx := parts.2
  simp only [IndexedMatrix.check,Bool.and_eq_true_iff] at idx
  have all : IndexedMatrix.checkMembers matrix splits indexed.members 0 z z z=true := by grind only
  have closed : IndexedMatrix.checkClosing matrix splits indexed.members indexed.closing=true := by grind only
  have zero : E values z=((0:Nat):F) := by simp only [z,eval_constant values one,Ring.intCast_zero,Semiring.natCast_zero]
  obtain ⟨rest,closes,i,h,o,n,ph,po,pn,sub,checks,closed,phb,pob,pnb,phi,poi,pni⟩ :=
    IndexedLengths.member_suffix matrix splits splitChecks values one satisfied indexed.members indexed.closing 0 z z z all closed
      0 0 0 (by decide) (by decide) (by decide) zero zero zero row rm
  have rc := (Bool.and_eq_true_iff.mp checks).1
  obtain ⟨d,db,di,_,nz⟩ := IndexedCell.decode matrix splits splitChecks row i h o n rc values one satisfied ea
  have banks := IndexedLengths.checked_banks (F:=F) matrix body tables splits declaration indexed accepted
  obtain ⟨len,lb,li⟩ := IndexedGroups.length_value matrix _ indexed.members banks values one satisfied row rm
  obtain ⟨tail,_,total⟩ := IndexedGroups.suffix_list matrix splits splitChecks _ indexed.members banks values one satisfied
    rest row sub i h o n checks closes closed d db di nz ea len lb li
  have inside : d.ordinal<len := by omega
  have links : IndexedMatrix.checkLinks tables declaration indexed=true := by grind only
  have le := (_root_.of_decide_eq_true (Bool.and_eq_true_iff.mp links).1).2.2.1
  have la : E values row.lengthQuery.active=1 := by
    rw [(IndexedCell.metadata matrix splits row i h o n rc).2.2.2.2.2.2.2.1]
    exact ea
  have key := ek.symm.trans di.2.2.2.2.2.2.1
  obtain ⟨tags,tag,cursor,rep,count,cb,atIndex,value⟩ := IndexedLookup.checked_lookup matrix body tables splits declaration indexed accepted
    _ consumer banks.lengthsChecked consumerChecked le entries row.lengthQuery query (banks.lengthQueries row rm) member values one satisfied
    la active d.head len d.ordinal db.1 lb inside di.2.2.2.2.2.2.2.2.2.2 li key
  exact ⟨⟨d.head,db.1⟩,⟨d.ordinal,db.2.1⟩,⟨cursor,cb⟩,tag,tags,key,value,rep,by change d.ordinal<tags.length; omega,atIndex⟩

#print axioms queried
end ZkBuild.IndexedMemberRead
