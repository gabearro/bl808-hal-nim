import DeclarationPrefix

namespace ZkBuild.SignatureSource
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix EnvelopeMatrix ShaProgram
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

/-- Every active function metadata entry selects a real source type and
    therefore the exact source parameter/result lists, not an extra table row. -/
theorem function_source_signature_bounded {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record) (splits : Splits)
    (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record) (signature : SignatureMatrix.Record) (space : SignatureNamespace.Record)
    (accepted : SignatureSound.check matrix body tables splits declaration indexed signature space = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (row : SignatureMatrix.MetadataRow) (member : row ∈ signature.metadata) (functionIndex : Nat) (fb : functionIndex < 2^32)
    (active : E values row.entry.active = 1) (address : E values row.entry.address = ((2*functionIndex : Nat) : F)) :
    ∃ (message : List Sha256.Byte) (types : List DeclarationType.Decoded) (typeIndex paramHead resultHead : Nat) (params results : List Nat),
      BinarySourceMatrix.Message values body.source.firstWire body.source.capacity body.source.length message ∧
      values 1 = (ShaHashSound.digestLimb message 0 : F) ∧ values 2 = (ShaHashSound.digestLimb message 1 : F) ∧
      Related (DeclarationType.Represents values) declaration.types types ∧ typeIndex < types.length ∧
      E values row.typeIndex = (typeIndex : F) ∧ DeclarationFraming.Framed message (types.getD typeIndex default) ∧
      paramHead < 2^32 ∧ resultHead < 2^32 ∧
      E values (split splits row.heads).low = (paramHead : F) ∧ E values (split splits row.heads).high = (resultHead : F) ∧
      SignatureLists.Represents (IndexedNodeTable.table values (IndexedLengths.banks tables indexed).nodes) paramHead params ∧
      SignatureLists.Represents (IndexedNodeTable.table values (IndexedLengths.banks tables indexed).nodes) resultHead results ∧
      params.length = (types.getD typeIndex default).params ∧ results.length = (types.getD typeIndex default).results ∧
      SourceTypeLists.Matches message (types.getD typeIndex default).paramsStart true params ∧
      SourceTypeLists.Matches message (types.getD typeIndex default).resultsStart false results := by
  have outer := Bool.and_eq_true_iff.mp accepted
  have inner := Bool.and_eq_true_iff.mp outer.1
  have indexedCheck := inner.1
  have declarationCheck := (Bool.and_eq_true_iff.mp indexedCheck).1
  have decCheck := (Bool.and_eq_true_iff.mp declarationCheck).2
  have splitChecks := (Bool.and_eq_true_iff.mp declarationCheck).1 |> Bool.and_eq_true_iff.mp |>.2
  have moduleTables := (Bool.and_eq_true_iff.mp declarationCheck).1
  have tableChecks := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp moduleTables).1).2
  obtain ⟨message,types,meaning,d0,d1,images,sourceTypes⟩ := SourceTypeLists.checked_source_type_lists_bounded matrix body tables splits declaration indexed indexedCheck values oneValue satisfied
  obtain ⟨other,_,_,otherImages,_,_,_,_,_,_,_,countImage⟩ := DeclarationCounts.checked_counts matrix body.tokens splits tables body.envelope declaration decCheck values oneValue satisfied
  have countSame := DeclarationPrefix.count_unique values declaration.types other types otherImages images
  rw [countSame] at countImage
  obtain ⟨tid,total,origin,tidBound,totalBound,totalImage,tidImage,originMember,originActive,originKey,originValue⟩ := SignatureOrigins.function_origin matrix body tables splits declaration indexed signature space accepted values oneValue satisfied row member functionIndex fb active address
  have dec := decCheck
  simp only [DeclarationMatrix.check,Bool.and_eq_true_iff] at dec
  have shape : Metadata body.envelope declaration := _root_.of_decide_eq_true (by grind only)
  have typeChecks : checkTypes matrix body.tokens splits declaration.typeEnd declaration.types 0 (typeSeed declaration.typeStart) o = true := by grind only
  have tsize := related_length _ _ _ images
  have countBound : DeclarationCounts.typeActive types < 2^32 := by
    have bound := DeclarationPrefix.count_bound types
    have size := shape.1
    omega
  have totalSame := DeclarationLocations.natural_equal (F := F) total (DeclarationCounts.typeActive types) (by omega) (by omega) (totalImage.symm.trans countImage)
  have it : tid < types.length := by have bound := DeclarationPrefix.count_bound types; omega
  have ib : tid < declaration.types.length := by omega
  have ordered := DeclarationPrefix.checked_prefix matrix body.tokens splits declaration.typeEnd declaration.types 0 (typeSeed declaration.typeStart) o typeChecks values oneValue satisfied types images true (by simp [o,eval_constant values oneValue])
  have typeActive := DeclarationPrefix.active_at types ordered tid (by omega)
  obtain ⟨frame,ph,rh,params,results,pb,rb,phi,rhi,prep,rrep,pc,rc,pm,rm⟩ := sourceTypes tid it typeActive
  have tr := DeclarationLocations.related_at (DeclarationType.Represents values) declaration.types types images tid ib
  have ta : E values (get (declaration.types.getD tid default).fields 0) = 1 := by
    have flag : ((types.getD tid default).active.toNat : F) = 1 := by rw [typeActive]; exact Semiring.natCast_one
    exact tr.1.trans flag
  obtain ⟨tp,tv,typeCheck⟩ := SourceListSelection.type_at matrix body.tokens splits declaration.typeEnd declaration.types 0 (typeSeed declaration.typeStart) o typeChecks tid ib
  simp only [Nat.zero_add] at typeCheck
  have typeShape := DeclarationType.type_metadata matrix body.tokens splits _ tid tp tv declaration.typeEnd typeCheck
  have sigChecks := inner.2
  simp only [SignatureMatrix.check,Bool.and_eq_true_iff] at sigChecks
  have srChecks : signature.metadata.all (SignatureMatrix.checkMetadata matrix splits) = true := by grind only
  have rowCheck := List.all_eq_true.mp srChecks row member
  have sigLinks : SignatureMatrix.checkLinks tables declaration indexed signature = true := by grind only
  have sl := _root_.of_decide_eq_true sigLinks
  have idx := (Bool.and_eq_true_iff.mp indexedCheck).2
  simp only [IndexedMatrix.check,Bool.and_eq_true_iff] at idx
  have idxLinks : IndexedMatrix.checkLinks tables declaration indexed = true := by grind only
  have il := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp idxLinks).1
  have decLinks : DeclarationMatrix.checkLinks tables declaration = true := by grind only
  have dl := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp decLinks).1
  let consumer := DeclarationMatrix.table tables declaration 2
  have cm : consumer ∈ tables := by
    have b : 2 < declaration.tables.length := by rw [dl.1]; decide
    have m : declaration.tables.getD 2 0 ∈ declaration.tables := by rw [← List.getElem_eq_getD 0]; exact List.getElem_mem b
    unfold consumer DeclarationMatrix.table
    rw [← List.getElem_eq_getD default]; exact List.getElem_mem (dl.2.1 _ m)
  have tq : (declaration.types.getD tid default).metadata ∈ consumer.queries := by
    have q : consumer.queries = declaration.types.map TypeRow.metadata++declaration.params.map VectorRow.metadata++declaration.results.map VectorRow.metadata := by grind only
    rw [q]
    have trm : declaration.types.getD tid default ∈ declaration.types := by rw [← List.getElem_eq_getD default]; exact List.getElem_mem ib
    exact List.mem_append_left _ (List.mem_append_left _ (List.mem_map.mpr ⟨_,trm,rfl⟩))
  have om : origin.entry ∈ consumer.entries := by
    have es : consumer.entries = signature.metadata.map SignatureMatrix.MetadataRow.entry := by grind only
    rw [es]; exact List.mem_map.mpr ⟨origin,originMember,rfl⟩
  have tHolds := DeclarationType.type_holds matrix body.tokens splits _ tid tp tv declaration.typeEnd typeCheck values satisfied
  have part := DeclarationType.part_holds values body.tokens splits _ tid tp tv declaration.typeEnd tHolds 10 (by decide)
  have key := multiply_sound values (get (declaration.types.getD tid default).fields 0) (n (2*tid+1)) (declaration.types.getD tid default).metadata.address (part _ (by simp [typeParts,queryGate]))
  have literal : E values (n (2*tid+1)) = ((2*tid+1 : Nat) : F) := (eval_constant values oneValue (Int.ofNat (2*tid+1))).trans (Ring.intCast_natCast _)
  have keyImage : E values (declaration.types.getD tid default).metadata.address = ((2*tid+1 : Nat) : F) := by rw [key,ta,literal,Semiring.one_mul]
  have typeMetaActive := typeShape.2.2.2.2.2.2.2.2.2.2.2.1
  have sameValue := ReadOnlySound.checked_expected matrix consumer (List.all_eq_true.mp tableChecks _ cm) values oneValue satisfied _ origin.entry tq om
    (by rw [typeMetaActive]; exact ta) originActive (originKey.trans keyImage.symm)
  have rowShape := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp rowCheck).1).1).1
  have rhm : split splits row.heads ∈ splits := by rw [split,← List.getElem_eq_getD default]; exact List.getElem_mem rowShape.1
  have thm : split splits (declaration.types.getD tid default).heads ∈ splits := by rw [split,← List.getElem_eq_getD default]; exact List.getElem_mem typeShape.2.2.2.2.2.2.1
  have th := typeShape.2.2.2.2.2.2.2.2.2.2.1
  have sameHeads := SourceListSelection.equal_heads matrix _ _ (List.all_eq_true.mp splitChecks _ rhm) (List.all_eq_true.mp splitChecks _ thm)
    rowShape.2.1.2.1 rowShape.2.1.2.2 th.2.1 th.2.2 values oneValue satisfied
    (by rw [rowShape.2.1.1,th.1]; exact (sameValue.trans originValue).symm)
  exact ⟨message,types,tid,ph,rh,params,results,meaning,d0,d1,images,it,tidImage,frame,pb,rb,sameHeads.1.trans phi,sameHeads.2.trans rhi,prep,rrep,pc,rc,pm,rm⟩


theorem function_source_signature {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record) (splits : Splits)
    (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record) (signature : SignatureMatrix.Record) (space : SignatureNamespace.Record)
    (accepted : SignatureSound.check matrix body tables splits declaration indexed signature space = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (row : SignatureMatrix.MetadataRow) (member : row ∈ signature.metadata) (functionIndex : Nat) (fb : functionIndex < 2^32)
    (active : E values row.entry.active = 1) (address : E values row.entry.address = ((2*functionIndex : Nat) : F)) :
    ∃ (message : List Sha256.Byte) (types : List DeclarationType.Decoded) (typeIndex paramHead resultHead : Nat) (params results : List Nat),
      BinarySourceMatrix.Message values body.source.firstWire body.source.capacity body.source.length message ∧
      values 1 = (ShaHashSound.digestLimb message 0 : F) ∧ values 2 = (ShaHashSound.digestLimb message 1 : F) ∧
      Related (DeclarationType.Represents values) declaration.types types ∧ typeIndex < types.length ∧
      E values row.typeIndex = (typeIndex : F) ∧ DeclarationFraming.Framed message (types.getD typeIndex default) ∧
      E values (split splits row.heads).low = (paramHead : F) ∧ E values (split splits row.heads).high = (resultHead : F) ∧
      SignatureLists.Represents (IndexedNodeTable.table values (IndexedLengths.banks tables indexed).nodes) paramHead params ∧
      SignatureLists.Represents (IndexedNodeTable.table values (IndexedLengths.banks tables indexed).nodes) resultHead results ∧
      params.length = (types.getD typeIndex default).params ∧ results.length = (types.getD typeIndex default).results ∧
      SourceTypeLists.Matches message (types.getD typeIndex default).paramsStart true params ∧
      SourceTypeLists.Matches message (types.getD typeIndex default).resultsStart false results := by
  obtain ⟨message,types,tid,ph,rh,params,results,meaning,d0,d1,images,it,ti,frame,_,_,pi,ri,pr,rr,pc,rc,pm,rm⟩ :=
    function_source_signature_bounded matrix body tables splits declaration indexed signature space accepted values oneValue satisfied row member functionIndex fb active address
  exact ⟨message,types,tid,ph,rh,params,results,meaning,d0,d1,images,it,ti,frame,pi,ri,pr,rr,pc,rc,pm,rm⟩

#print axioms function_source_signature
#print axioms function_source_signature_bounded
end ZkBuild.SignatureSource
