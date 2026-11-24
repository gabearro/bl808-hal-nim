import IndexedGroups

namespace ZkBuild.IndexedLengths
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix EnvelopeMatrix IndexedMatrix IndexedCell IndexedGroups
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

def banks (tables : List ReadOnlyMatrix.Record) (r : IndexedMatrix.Record) : Banks :=
  ⟨IndexedMatrix.table tables r 1,IndexedMatrix.table tables r 0,IndexedMatrix.table tables r 3⟩

theorem checked_banks {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record) (splits : Splits)
    (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record)
    (accepted : IndexedSound.check matrix body tables splits declaration indexed = true) :
    CheckedBanks matrix (banks tables indexed) indexed.members := by
  have parts := Bool.and_eq_true_iff.mp accepted
  have tableChecks := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp parts.1).1).1).2
  have indexChecks := parts.2
  simp only [IndexedMatrix.check,Bool.and_eq_true_iff] at indexChecks
  have links : IndexedMatrix.checkLinks tables declaration indexed = true := by grind only
  have facts := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp links).1
  have widthChecks := (Bool.and_eq_true_iff.mp links).2
  have width := _root_.of_decide_eq_true (List.all_eq_true.mp widthChecks 0 (by simp))
  have memberCheck := List.all_eq_true.mp tableChecks _ (IndexedBridge.table_member tables declaration indexed links 1 (by decide))
  have lengthCheck := List.all_eq_true.mp tableChecks _ (IndexedBridge.table_member tables declaration indexed links 0 (by decide))
  have nodeCheck := List.all_eq_true.mp tableChecks _ (IndexedBridge.table_member tables declaration indexed links 3 (by decide))
  constructor
  · exact memberCheck
  · exact lengthCheck
  · exact nodeCheck
  · exact facts.2.2.2.2.1
  · exact width.2
  · intro row member
    have queryLink : (banks tables indexed).lengths.queries = indexed.members.map MemberRow.lengthQuery++indexed.metadata.flatMap (fun m => [m.params,m.results])++indexed.singletons.map singletonLength++indexed.extraLengths := by exact facts.2.2.2.1
    rw [queryLink]
    exact List.mem_append_left _ (List.mem_append_left _ (List.mem_append_left _ (List.mem_map.mpr ⟨row,member,rfl⟩)))
  · intro row member
    have queryLink : (banks tables indexed).nodes.queries = indexed.members.map MemberRow.nodeQuery++indexed.singletons.map SingletonRow.nodeQuery := by exact facts.2.2.2.2.2.2.2.2.1
    rw [queryLink]
    exact List.mem_append_left _ (List.mem_map.mpr ⟨row,member,rfl⟩)

/-- Recover a checked suffix and its bounded predecessor coordinates at an
    arbitrary member; this preserves the real row index and closing span. -/
theorem member_suffix {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (splits : Splits) (splitChecks : splits.all (PackedFields.check matrix) = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (rows : List MemberRow) (closing : List CloseRow) (index : Nat) (ph po pn : Linear)
    (checked : checkMembers matrix splits rows index ph po pn = true) (closed : checkClosing matrix splits rows closing = true)
    (head ordinal next : Nat) (hb : head < 2^32) (ob : ordinal < 2^32) (nb : next < 2^32)
    (hi : E values ph = (head : F)) (oi : E values po = (ordinal : F)) (ni : E values pn = (next : F))
    (target : MemberRow) (member : target ∈ rows) :
    ∃ (rest : List MemberRow) (closes : List CloseRow) (i : Nat) (h o n : Linear) (previousHead previousOrdinal previousNext : Nat),
      target::rest ⊆ rows ∧ checkMembers matrix splits (target::rest) i h o n = true ∧
      checkClosing matrix splits (target::rest) closes = true ∧
      previousHead < 2^32 ∧ previousOrdinal < 2^32 ∧ previousNext < 2^32 ∧
      E values h = (previousHead : F) ∧ E values o = (previousOrdinal : F) ∧ E values n = (previousNext : F) := by
  induction rows generalizing closing index ph po pn head ordinal next with
  | nil => simp at member
  | cons row rows ih =>
    have parts := Bool.and_eq_true_iff.mp checked
    rcases List.mem_cons.mp member with rfl | later
    · exact ⟨rows,closing,index,ph,po,pn,head,ordinal,next,by intro x hx; exact hx,checked,closed,hb,ob,nb,hi,oi,ni⟩
    · cases closing with
      | nil => simp [checkClosing] at closed
      | cons c cs =>
        have tailClose := (Bool.and_eq_true_iff.mp closed).2
        obtain ⟨rh,ro,rn,rhb,rob,rnb,rhi,roi,rni⟩ := coordinates matrix splits splitChecks row index ph po pn parts.1 values oneValue satisfied
        obtain ⟨rest,closes,i,h,o,n,hv,ov,nv,sub,checked,closed,hb,ob,nb,hi,oi,ni⟩ := ih cs (index+1) _ _ _ parts.2 tailClose rh ro rn rhb rob rnb rhi roi rni later
        exact ⟨rest,closes,i,h,o,n,hv,ov,nv,by intro x hx; exact List.mem_cons_of_mem row (sub hx),checked,closed,hb,ob,nb,hi,oi,ni⟩

/-- Every active indexed length entry describes a complete finite list in
    the immutable node table, including the empty head. -/
theorem checked_lengths {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record) (splits : Splits)
    (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record)
    (accepted : IndexedSound.check matrix body tables splits declaration indexed = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (row : LengthRow) (member : row ∈ indexed.lengths) (active : E values row.entry.active = 1) :
    ∃ head length : Nat, ∃ tags : List Nat,
      head < 2^32 ∧ length < 2^32 ∧ E values row.entry.address = (head : F) ∧ E values row.entry.value = (length : F) ∧
      SignatureLists.Represents (IndexedNodeTable.table values (banks tables indexed).nodes) head tags ∧ tags.length = length ∧
      ∃ cells : List IndexedSignatures.Cell,
        IndexedSignatures.Rows (IndexedNodeTable.table values (banks tables indexed).nodes) 0 head length cells ∧
        IndexedSignatures.values cells = tags ∧ Recorded values indexed.members head cells := by
  let b := banks tables indexed
  have bankChecks := checked_banks (F := F) matrix body tables splits declaration indexed accepted
  have parts := Bool.and_eq_true_iff.mp accepted
  have splitChecks := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp parts.1).1).2
  have idx := parts.2
  simp only [IndexedMatrix.check,Bool.and_eq_true_iff] at idx
  have links : IndexedMatrix.checkLinks tables declaration indexed = true := by grind only
  have facts := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp links).1
  have allLengths : indexed.lengths.all (checkLength matrix) = true := by grind only
  have checked := List.all_eq_true.mp allLengths row member
  have lengthEntries : b.lengths.entries = indexed.lengths.map LengthRow.entry := facts.2.2.1
  have em : row.entry ∈ b.lengths.entries := by rw [lengthEntries]; exact List.mem_map.mpr ⟨row,member,rfl⟩
  obtain ⟨_,head,len,hb,lb,_,hi,li⟩ := ReadOnlyFacts.entry_fields matrix b.lengths bankChecks.lengthsChecked values oneValue satisfied row.entry em
  have widths := _root_.of_decide_eq_true (List.all_eq_true.mp (Bool.and_eq_true_iff.mp links).2 0 (by simp))
  have headBound : head < 2^32 := by simpa [b,banks,widths.1] using hb
  have lengthWidth : b.lengths.memory.valueBits = 32 := bankChecks.lengthWidth
  have lengthBound : len < 2^32 := by simpa only [lengthWidth] using lb
  have boundary := IndexedBoundary.length_empty matrix row checked values oneValue satisfied active
  by_cases empty : head = 0
  · have vi : E values row.entry.value = 0 := boundary.1.mp (by simpa [empty,Semiring.natCast_zero] using hi)
    have lenZero := DeclarationLocations.natural_equal (F := F) len 0 (by omega) (by decide) (by rw [← li,vi]; simp [Semiring.natCast_zero])
    exact ⟨head,len,[],headBound,lengthBound,hi,li,by simpa [empty] using (SignatureLists.Represents.nil (table := IndexedNodeTable.table values b.nodes)),by simp [lenZero],
      [],by simp [IndexedSignatures.Rows,empty,lenZero],rfl,by simp [Recorded]⟩
  · have headNonzero : E values row.entry.address ≠ 0 := by
      intro zero
      have zeroNat := DeclarationLocations.natural_equal (F := F) head 0 (by omega) (by decide) (by rw [← hi,zero]; simp [Semiring.natCast_zero])
      exact empty zeroNat
    have qa : E values row.firstMember.active = 1 := by simpa only [headNonzero,ite_false] using boundary.2.1
    have qk : E values row.firstMember.address = ((0+2^32*head : Nat) : F) := by
      have key := boundary.2.2
      rw [ite_eq_right headNonzero,hi] at key
      simpa only [Nat.zero_add,Semiring.natCast_mul] using key
    have memberQueries : b.members.queries = indexed.lengths.map LengthRow.firstMember++indexed.extraMembers := facts.2.2.2.2.2.1
    have qm : row.firstMember ∈ b.members.queries := by rw [memberQueries]; exact List.mem_append_left _ (List.mem_map.mpr ⟨row,member,rfl⟩)
    obtain ⟨_,_,_,_,_,_,_,_,membership⟩ := ReadOnlySound.checked_membership matrix b.members bankChecks.membersChecked values oneValue satisfied
    obtain ⟨entry,entryMem,ea,ek,_⟩ := membership row.firstMember qm qa
    rw [bankChecks.memberEntries] at entryMem
    obtain ⟨first,fm,same⟩ := List.mem_map.mp entryMem
    subst entry
    have rowChecks : checkMembers matrix splits indexed.members 0 z z z = true := by grind only
    have closings : checkClosing matrix splits indexed.members indexed.closing = true := by grind only
    have zero : E values z = ((0 : Nat) : F) := by simp [z,eval_constant values oneValue]
    obtain ⟨rest,closes,i,h,o,n,ph,po,pn,sub,checks,closed,phb,pob,pnb,phi,poi,pni⟩ :=
      member_suffix matrix splits splitChecks values oneValue satisfied indexed.members indexed.closing 0 z z z rowChecks closings 0 0 0 (by decide) (by decide) (by decide) zero zero zero first fm
    have firstCheck := (Bool.and_eq_true_iff.mp checks).1
    obtain ⟨d,db,di,_,nz⟩ := decode matrix splits splitChecks first i h o n firstCheck values oneValue satisfied ea
    have key := DeclarationLocations.natural_equal (F := F) (d.ordinal+2^32*d.head) (0+2^32*head)
      (by have a := db.1; have c := db.2.1; omega) (by omega) (di.2.2.2.2.2.2.1.symm.trans (ek.trans qk))
    have keyParts := DeclarationLocations.packed_unique d.ordinal d.head 0 head db.2.1 (by decide) key
    have co := IndexedStep.continuation matrix splits first i h o n firstCheck values oneValue satisfied d di db ea ph phb phi
    have firstCont : E values first.continuing = 0 := by
      by_cases cont : i ≠ 0 ∧ d.head = ph
      · have ci : E values first.continuing = 1 := by simpa [cont.1,cont.2] using co
        have step := IndexedStep.continue_step matrix splits first i (by omega) h o n firstCheck values oneValue satisfied d di db ci po pn pob pnb poi pni
        have ord := keyParts.1
        omega
      · simpa only [cont,ite_false] using co
    have start := IndexedStep.start_step matrix splits first i h o n firstCheck values oneValue satisfied d di db ea firstCont
    have lenActive := (metadata matrix splits first i h o n firstCheck).2.2.2.2.2.2.2.1
    have lenImage := ReadOnlySound.checked_expected matrix b.lengths bankChecks.lengthsChecked values oneValue satisfied first.lengthQuery row.entry
      (bankChecks.lengthQueries first fm) em (by rw [lenActive]; exact ea) active
      (by rw [hi,di.2.2.2.2.2.2.2.2.2.2,keyParts.2])
    obtain ⟨cells,cellRows,recorded⟩ := suffix_cells matrix splits splitChecks b indexed.members bankChecks values oneValue satisfied rest first sub i h o n checks closes closed d db di nz ea len lengthBound (lenImage.trans li)
    have rootRows : IndexedSignatures.Rows (IndexedNodeTable.table values b.nodes) 0 head len cells := by simpa [start.2,keyParts.1,keyParts.2] using cellRows
    have meaning := IndexedSignatures.rows_sound _ cells 0 head len rootRows
    refine ⟨head,len,IndexedSignatures.values cells,headBound,lengthBound,hi,li,meaning.1,?_,cells,rootRows,rfl,?_⟩
    · simpa [IndexedSignatures.values] using meaning.2
    · simpa [keyParts.2] using recorded

#print axioms member_suffix
#print axioms checked_lengths
end ZkBuild.IndexedLengths
