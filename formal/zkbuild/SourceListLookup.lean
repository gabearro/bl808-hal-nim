import SourceListHeads

namespace ZkBuild.SourceListLookup
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix EnvelopeMatrix ShaProgram DeclarationLocations
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

def listHead (params : Bool) (paramHead resultHead : Nat) := if params then paramHead else resultHead
def listOrdinal (params : Bool) (length ordinal : Nat) := if params then length-1-ordinal else ordinal
def lengthQuery (params : Bool) (row : TypeRow) := if params then row.paramLength else row.resultLength

theorem member_tag {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record) (splits : Splits)
    (r : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record)
    (accepted : IndexedSound.check matrix body tables splits r indexed = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (types : List DeclarationType.Decoded) (images : Related (DeclarationType.Represents values) r.types types)
    (bounds : ∀ d ∈ types, DeclarationType.Bounded d)
    (i : Nat) (ib : i < r.types.length) (tp : List Linear) (tv : Linear)
    (typeCheck : checkType matrix body.tokens splits (r.types.getD i default) i tp tv r.typeEnd = true)
    (typeActive : (types.getD i default).active = true)
    (params : Bool) (source : VectorRow) (sourceMember : source ∈ vectorRows r params)
    (si : Nat) (sp sa sc : Linear) (sourceCheck : checkVector matrix body.tokens splits source params si sp sa sc = true)
    (active : E values (get source.fields 0) = 1)
    (ordinal : Nat) (ob : ordinal < arity params (types.getD i default))
    (sourceKey : E values (get source.fields 1) = ((ordinal+2^32*i : Nat) : F))
    (paramHead resultHead : Nat) (pb : paramHead < 2^32) (rb : resultHead < 2^32)
    (pi : E values (split splits (r.types.getD i default).heads).low = (paramHead : F))
    (ri : E values (split splits (r.types.getD i default).heads).high = (resultHead : F))
    (tags : List Nat)
    (rep : SignatureLists.Represents (IndexedNodeTable.table values (IndexedLengths.banks tables indexed).nodes) (listHead params paramHead resultHead) tags)
    (size : tags.length = arity params (types.getD i default)) :
    ∃ tag : Fin 7, tags.getD (listOrdinal params tags.length ordinal) 0 = tag.val ∧ E values (get source.fields 2) = (tag.val : F) := by
  have parts := Bool.and_eq_true_iff.mp accepted
  have declarationCheck := parts.1
  have splitChecks := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp declarationCheck).1).2
  have tableChecks := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp declarationCheck).1).1).2
  have dec := (Bool.and_eq_true_iff.mp declarationCheck).2
  simp only [DeclarationMatrix.check,Bool.and_eq_true_iff] at dec
  have shape : Metadata body.envelope r := _root_.of_decide_eq_true (by grind only)
  have dlinksCheck : checkLinks tables r = true := by grind only
  have dlinks := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp dlinksCheck).1
  have idx := parts.2
  simp only [IndexedMatrix.check,Bool.and_eq_true_iff] at idx
  have ilinksCheck : IndexedMatrix.checkLinks tables r indexed = true := by grind only
  have ilinks := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp ilinksCheck).1
  have ti := related_at (DeclarationType.Represents values) r.types types images i ib
  have tlen := related_length _ _ _ images
  have tm : types.getD i default ∈ types := by rw [← List.getElem_eq_getD default]; exact List.getElem_mem (by omega)
  have typedBound := bounds _ tm
  have ab := (arity_bound params _ typedBound).1
  have ib32 : i < 2^32 := by have b := shape.1; omega
  have ob32 : ordinal < 2^32 := Nat.lt_trans ob ab
  have selection := SourceListSelection.known_selection matrix body tables splits r declarationCheck values oneValue satisfied types images bounds params source sourceMember si sp sa sc sourceCheck active i ordinal ib32 ob32 sourceKey
  have ta : E values (get (r.types.getD i default).fields 0) = 1 := by
    have flag : ((types.getD i default).active.toNat : F) = 1 := by rw [typeActive]; exact Semiring.natCast_one
    exact ti.1.trans flag
  have rowMember : r.types.getD i default ∈ r.types := by rw [← List.getElem_eq_getD default]; exact List.getElem_mem ib
  have heads := SourceListHeads.metadata_heads matrix body tables splits r declarationCheck _ rowMember i tp tv typeCheck params source sourceMember si sp sa sc sourceCheck values oneValue satisfied ta active selection.1
  have both : source ∈ r.params++r.results := by cases params; exact List.mem_append_right _ sourceMember; exact List.mem_append_left _ sourceMember
  obtain ⟨_,d,_,db,_,_,_,tagImage,queryKey,queryValue,_⟩ := IndexedBridge.source_member matrix body tables splits r indexed accepted values oneValue satisfied source both active
  obtain ⟨j,len,ph,rh,jb,lb,phb,rhb,ji,li,phi,rhi,dh,do'⟩ := IndexedOrientation.source_position matrix body.tokens splits splitChecks source params si sp sa sc sourceCheck values oneValue satisfied active d db queryKey
  have sameOrdinal := natural_equal (F := F) j ordinal (by omega) (by omega) (ji.symm.trans selection.2.1)
  have sameLength := natural_equal (F := F) len (arity params (types.getD i default)) (by omega) (by omega) (li.symm.trans selection.2.2)
  have sameParam := natural_equal (F := F) ph paramHead (by omega) (by omega) (phi.symm.trans (heads.1.trans pi))
  have sameResult := natural_equal (F := F) rh resultHead (by omega) (by omega) (rhi.symm.trans (heads.2.trans ri))
  have actualHead : d.head = listHead params paramHead resultHead := by simpa [listHead,sameParam,sameResult] using dh
  have actualOrdinal : d.ordinal = listOrdinal params (arity params (types.getD i default)) ordinal := by simpa [listOrdinal,sameLength,sameOrdinal] using do'
  let lc := DeclarationMatrix.table tables r 3
  let mc := DeclarationMatrix.table tables r 4
  have tableMember (n : Nat) (nb : n < 6) : DeclarationMatrix.table tables r n ∈ tables := by
    have b : n < r.tables.length := by rw [dlinks.1]; exact nb
    have m : r.tables.getD n 0 ∈ r.tables := by rw [← List.getElem_eq_getD 0]; exact List.getElem_mem b
    unfold DeclarationMatrix.table
    rw [← List.getElem_eq_getD default]; exact List.getElem_mem (dlinks.2.1 _ m)
  have lcheck := List.all_eq_true.mp tableChecks lc (tableMember 3 (by decide))
  have mcheck := List.all_eq_true.mp tableChecks mc (tableMember 4 (by decide))
  have le : lc.entries = indexed.lengths.map IndexedMatrix.LengthRow.entry := by grind only
  have me : mc.entries = indexed.members.map IndexedMatrix.MemberRow.entry := by grind only
  have lqs : lc.queries = r.types.flatMap (fun t => [t.paramLength,t.resultLength]) := by grind only
  have mqs : mc.queries = r.params.map VectorRow.memberQuery++r.results.map VectorRow.memberQuery := by grind only
  have lqm : lengthQuery params (r.types.getD i default) ∈ lc.queries := by
    rw [lqs]; apply List.mem_flatMap.mpr
    refine ⟨_,rowMember,?_⟩; cases params <;> simp [lengthQuery]
  have mqm : source.memberQuery ∈ mc.queries := by
    rw [mqs,← List.map_append]; exact List.mem_map.mpr ⟨source,both,rfl⟩
  have tShape := DeclarationType.type_metadata matrix body.tokens splits _ i tp tv r.typeEnd typeCheck
  have sShape := DeclarationVector.vector_metadata matrix body.tokens splits source params si sp sa sc sourceCheck
  have out := DeclarationType.part_holds values body.tokens splits _ i tp tv r.typeEnd
    (DeclarationType.type_holds matrix body.tokens splits _ i tp tv r.typeEnd typeCheck values satisfied) 12 (by decide)
  have pKey := multiply_sound values (get (r.types.getD i default).fields 0) (split splits (r.types.getD i default).heads).low (r.types.getD i default).paramLength.address (out _ (by simp [typeParts,queryGate]))
  have rKey := multiply_sound values (get (r.types.getD i default).fields 0) (split splits (r.types.getD i default).heads).high (r.types.getD i default).resultLength.address (out _ (by simp [typeParts,queryGate]))
  have pValue := equality_sound values oneValue (r.types.getD i default).paramLength.value (get (r.types.getD i default).fields 5) (out _ (by simp [typeParts]))
  have rValue := equality_sound values oneValue (r.types.getD i default).resultLength.value (get (r.types.getD i default).fields 6) (out _ (by simp [typeParts]))
  have la : E values (lengthQuery params (r.types.getD i default)).active = 1 := by
    cases params
    · change E values (r.types.getD i default).resultLength.active = 1
      rw [tShape.2.2.2.2.2.2.2.2.2.2.2.2.2]; exact ta
    · change E values (r.types.getD i default).paramLength.active = 1
      rw [tShape.2.2.2.2.2.2.2.2.2.2.2.2.1]; exact ta
  have ma : E values source.memberQuery.active = 1 := by rw [sShape.2.2.2.2.2.2.2.2.2.2.2.2.2.2]; exact active
  have hi : E values (lengthQuery params (r.types.getD i default)).address = (listHead params paramHead resultHead : F) := by
    cases params
    · change E values (r.types.getD i default).resultLength.address = (resultHead : F)
      simpa only [ta,ri,Semiring.one_mul] using rKey
    · change E values (r.types.getD i default).paramLength.address = (paramHead : F)
      simpa only [ta,pi,Semiring.one_mul] using pKey
  have lvalue : E values (lengthQuery params (r.types.getD i default)).value = (arity params (types.getD i default) : F) := by
    cases params
    · exact rValue.trans ti.2.2.2.2.2.2
    · exact pValue.trans ti.2.2.2.2.2.1
  have hb : listHead params paramHead resultHead < 2^32 := by cases params <;> assumption
  have ob' : listOrdinal params (arity params (types.getD i default)) ordinal < arity params (types.getD i default) := by cases params <;> dsimp [listOrdinal] <;> omega
  have mkey : E values source.memberQuery.address = ((listOrdinal params (arity params (types.getD i default)) ordinal+2^32*listHead params paramHead resultHead : Nat) : F) := by simpa [actualHead,actualOrdinal] using queryKey
  obtain ⟨other,tag,cursor,orep,osize,cb,atIndex,val⟩ := IndexedLookup.checked_lookup matrix body tables splits r indexed accepted lc mc lcheck mcheck le me _ _ lqm mqm values oneValue satisfied la ma _ _ _ hb ab ob' hi lvalue mkey
  have sameTags := SignatureLists.represents_unique _ _ other tags orep rep
  have payload := natural_equal (F := F) (d.tag.val+8*d.cursor) (tag.val+8*cursor)
    (by have a := d.tag.isLt; have b := db.2.2.1; omega) (by have a := tag.isLt; omega) (queryValue.symm.trans val)
  have sameTag : d.tag.val = tag.val := by
    have low := congrArg (fun n => n % 8) payload
    have dt : d.tag.val < 8 := by have a := d.tag.isLt; omega
    have tt : tag.val < 8 := by have a := tag.isLt; omega
    simpa [Nat.add_mod,Nat.mod_eq_of_lt dt,Nat.mod_eq_of_lt tt] using low
  refine ⟨tag,?_,?_⟩
  · simpa [sameTags,size] using atIndex
  · simpa [sameTag] using tagImage

#print axioms member_tag
end ZkBuild.SourceListLookup
