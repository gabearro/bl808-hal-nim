import IndexedLengths

namespace ZkBuild.IndexedTypeLists
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix EnvelopeMatrix ShaProgram
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

/-- Any checked consumer of the length table gets a complete list of that
    length, not merely a consistent cached integer. -/
theorem queried_list {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record) (splits : Splits)
    (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record)
    (accepted : IndexedSound.check matrix body tables splits declaration indexed = true)
    (consumer : ReadOnlyMatrix.Record) (consumerChecked : ReadOnlyMatrix.check matrix consumer = true)
    (entries : consumer.entries = indexed.lengths.map IndexedMatrix.LengthRow.entry)
    (query : Entry) (member : query ∈ consumer.queries)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) (active : E values query.active = 1) :
    ∃ head length : Nat, ∃ tags : List Nat,
      head < 2^32 ∧ length < 2^32 ∧ E values query.address = (head : F) ∧ E values query.value = (length : F) ∧
      SignatureLists.Represents (IndexedNodeTable.table values (IndexedLengths.banks tables indexed).nodes) head tags ∧ tags.length = length ∧
      ∃ cells : List IndexedSignatures.Cell,
        IndexedSignatures.Rows (IndexedNodeTable.table values (IndexedLengths.banks tables indexed).nodes) 0 head length cells ∧
        IndexedSignatures.values cells = tags ∧ IndexedGroups.Recorded values indexed.members head cells := by
  obtain ⟨_,_,_,_,_,_,_,_,membership⟩ := ReadOnlySound.checked_membership matrix consumer consumerChecked values oneValue satisfied
  obtain ⟨entry,em,ea,ek,ev⟩ := membership query member active
  rw [entries] at em
  obtain ⟨row,rm,same⟩ := List.mem_map.mp em
  subst entry
  obtain ⟨head,len,tags,hb,lb,hi,li,rep,count,cells⟩ := IndexedLengths.checked_lengths matrix body tables splits declaration indexed accepted values oneValue satisfied row rm ea
  exact ⟨head,len,tags,hb,lb,ek.symm.trans hi,ev.symm.trans li,rep,count,cells⟩

theorem type_heads {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record) (splits : Splits)
    (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record)
    (accepted : IndexedSound.check matrix body tables splits declaration indexed = true)
    (row : TypeRow) (member : row ∈ declaration.types) (index : Nat) (prior : List Linear) (previous : Linear)
    (checked : checkType matrix body.tokens splits row index prior previous declaration.typeEnd = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (d : DeclarationType.Decoded) (represented : DeclarationType.Represents values row d) (bounded : DeclarationType.Bounded d) (active : d.active = true) :
    ∃ paramHead resultHead : Nat, ∃ params results : List Nat,
      paramHead < 2^32 ∧ resultHead < 2^32 ∧
      E values (split splits row.heads).low = (paramHead : F) ∧ E values (split splits row.heads).high = (resultHead : F) ∧
      SignatureLists.Represents (IndexedNodeTable.table values (IndexedLengths.banks tables indexed).nodes) paramHead params ∧
      SignatureLists.Represents (IndexedNodeTable.table values (IndexedLengths.banks tables indexed).nodes) resultHead results ∧
      params.length = d.params ∧ results.length = d.results := by
  have parts := Bool.and_eq_true_iff.mp accepted
  have declParts := Bool.and_eq_true_iff.mp parts.1
  have splitChecks := (Bool.and_eq_true_iff.mp declParts.1).2
  have tableChecks := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp declParts.1).1).2
  have dec := declParts.2
  simp only [DeclarationMatrix.check,Bool.and_eq_true_iff] at dec
  have dl : DeclarationMatrix.checkLinks tables declaration = true := by grind only
  have dlinks := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp dl).1
  have idx := parts.2
  simp only [IndexedMatrix.check,Bool.and_eq_true_iff] at idx
  have il : IndexedMatrix.checkLinks tables declaration indexed = true := by grind only
  have ilinks := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp il).1
  let consumer := DeclarationMatrix.table tables declaration 3
  have cm : consumer ∈ tables := by
    have ib : 3 < declaration.tables.length := by rw [dlinks.1]; decide
    have mem : declaration.tables.getD 3 0 ∈ declaration.tables := by rw [← List.getElem_eq_getD 0]; exact List.getElem_mem ib
    unfold consumer DeclarationMatrix.table
    rw [← List.getElem_eq_getD default]; exact List.getElem_mem (dlinks.2.1 _ mem)
  have consumerChecked := List.all_eq_true.mp tableChecks consumer cm
  have ces : consumer.entries = indexed.lengths.map IndexedMatrix.LengthRow.entry := by grind only
  have cqs : consumer.queries = declaration.types.flatMap (fun t => [t.paramLength,t.resultLength]) := by grind only
  have pm : row.paramLength ∈ consumer.queries := by rw [cqs]; exact List.mem_flatMap.mpr ⟨row,member,by simp⟩
  have rm : row.resultLength ∈ consumer.queries := by rw [cqs]; exact List.mem_flatMap.mpr ⟨row,member,by simp⟩
  have shape := DeclarationType.type_metadata matrix body.tokens splits row index prior previous declaration.typeEnd checked
  have headsMember : split splits row.heads ∈ splits := by rw [split,← List.getElem_eq_getD default]; exact List.getElem_mem shape.2.2.2.2.2.2.1
  have headShape := shape.2.2.2.2.2.2.2.2.2.2.1
  obtain ⟨_,ph,rh,_,pb,rb,_,pi,ri,_⟩ := PackedFields.checked_split matrix _ (List.all_eq_true.mp splitChecks _ headsMember) values oneValue satisfied
  have phb : ph < 2^32 := by simpa [headShape.2.1] using pb
  have rhb : rh < 2^32 := by simpa [headShape.2.2] using rb
  have enabled : E values (get row.fields 0) = 1 := by simpa [active] using represented.1
  have holds := DeclarationType.type_holds matrix body.tokens splits row index prior previous declaration.typeEnd checked values satisfied
  have out := DeclarationType.part_holds values body.tokens splits row index prior previous declaration.typeEnd holds 12 (by decide)
  have pk := multiply_sound values (get row.fields 0) (split splits row.heads).low row.paramLength.address (out _ (by simp [DeclarationMatrix.typeParts,queryGate]))
  have rk := multiply_sound values (get row.fields 0) (split splits row.heads).high row.resultLength.address (out _ (by simp [DeclarationMatrix.typeParts,queryGate]))
  have pv := equality_sound values oneValue row.paramLength.value (get row.fields 5) (out _ (by simp [DeclarationMatrix.typeParts]))
  have rv := equality_sound values oneValue row.resultLength.value (get row.fields 6) (out _ (by simp [DeclarationMatrix.typeParts]))
  have pa : row.paramLength.active = get row.fields 0 := shape.2.2.2.2.2.2.2.2.2.2.2.2.1
  have ra : row.resultLength.active = get row.fields 0 := shape.2.2.2.2.2.2.2.2.2.2.2.2.2
  obtain ⟨phead,plen,params,hb1,lb1,hi1,li1,rep1,count1,_⟩ := queried_list matrix body tables splits declaration indexed accepted consumer consumerChecked ces row.paramLength pm values oneValue satisfied (by rw [pa]; exact enabled)
  obtain ⟨rhead,rlen,results,hb2,lb2,hi2,li2,rep2,count2,_⟩ := queried_list matrix body tables splits declaration indexed accepted consumer consumerChecked ces row.resultLength rm values oneValue satisfied (by rw [ra]; exact enabled)
  have pkey : E values row.paramLength.address = (ph : F) := by simpa only [enabled,pi,Semiring.one_mul] using pk
  have rkey : E values row.resultLength.address = (rh : F) := by simpa only [enabled,ri,Semiring.one_mul] using rk
  have headP := DeclarationLocations.natural_equal (F := F) phead ph (by omega) (by omega) (hi1.symm.trans pkey)
  have headR := DeclarationLocations.natural_equal (F := F) rhead rh (by omega) (by omega) (hi2.symm.trans rkey)
  have pc := bounded d.params (by simp [DeclarationType.numbers])
  have rc := bounded d.results (by simp [DeclarationType.numbers])
  have countP := DeclarationLocations.natural_equal (F := F) plen d.params (by omega) (by omega) (li1.symm.trans (pv.trans represented.2.2.2.2.2.1))
  have countR := DeclarationLocations.natural_equal (F := F) rlen d.results (by omega) (by omega) (li2.symm.trans (rv.trans represented.2.2.2.2.2.2))
  exact ⟨ph,rh,params,results,phb,rhb,pi,ri,by simpa [headP] using rep1,by simpa [headR] using rep2,count1.trans countP,count2.trans countR⟩

/-- Type headers and arities decoded from the authenticated WASM source are
    the arities of the complete lists selected by its metadata heads. -/
theorem checked_type_lists {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record) (splits : Splits)
    (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record)
    (accepted : IndexedSound.check matrix body tables splits declaration indexed = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ (message : List Sha256.Byte) (types : List DeclarationType.Decoded),
      BinarySourceMatrix.Message values body.source.firstWire body.source.capacity body.source.length message ∧
      values 1 = (ShaHashSound.digestLimb message 0 : F) ∧ values 2 = (ShaHashSound.digestLimb message 1 : F) ∧
      Related (DeclarationType.Represents values) declaration.types types ∧
      (∀ i, i < types.length → (types.getD i default).active = true →
        DeclarationFraming.Framed message (types.getD i default) ∧ (types.getD i default).finish ≤ message.length) ∧
      ∀ i, i < types.length → (types.getD i default).active = true →
        ∃ paramHead resultHead : Nat, ∃ params results : List Nat,
          paramHead < 2^32 ∧ resultHead < 2^32 ∧
          E values (split splits (declaration.types.getD i default).heads).low = (paramHead : F) ∧
          E values (split splits (declaration.types.getD i default).heads).high = (resultHead : F) ∧
          SignatureLists.Represents (IndexedNodeTable.table values (IndexedLengths.banks tables indexed).nodes) paramHead params ∧
          SignatureLists.Represents (IndexedNodeTable.table values (IndexedLengths.banks tables indexed).nodes) resultHead results ∧
          params.length = (types.getD i default).params ∧ results.length = (types.getD i default).results := by
  have declarationCheck := (Bool.and_eq_true_iff.mp accepted).1
  obtain ⟨message,types,meaning,d0,d1,images,bounds,framing,_,_⟩ := DeclarationFraming.checked_type_declarations matrix body tables splits declaration declarationCheck values oneValue satisfied
  refine ⟨message,types,meaning,d0,d1,images,framing,?_⟩
  intro i ib active
  have size := related_length _ _ _ images
  have rb : i < declaration.types.length := by omega
  have rm : declaration.types.getD i default ∈ declaration.types := by rw [← List.getElem_eq_getD default]; exact List.getElem_mem rb
  have tm : types.getD i default ∈ types := by rw [← List.getElem_eq_getD default]; exact List.getElem_mem ib
  have checks := (Bool.and_eq_true_iff.mp declarationCheck).2
  simp only [DeclarationMatrix.check,Bool.and_eq_true_iff] at checks
  have typeChecks : checkTypes matrix body.tokens splits declaration.typeEnd declaration.types 0 (typeSeed declaration.typeStart) o = true := by grind only
  obtain ⟨index,prior,previous,checked⟩ := DeclarationSound.type_member matrix body.tokens splits declaration.typeEnd declaration.types 0 (typeSeed declaration.typeStart) o typeChecks _ rm
  exact type_heads matrix body tables splits declaration indexed accepted _ rm index prior previous checked values oneValue satisfied _
    (DeclarationLocations.related_at (DeclarationType.Represents values) declaration.types types images i rb) (bounds _ tm) active

#print axioms queried_list
#print axioms type_heads
#print axioms checked_type_lists
end ZkBuild.IndexedTypeLists
