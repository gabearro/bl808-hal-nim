import SourceListLookup

namespace ZkBuild.SourceTypeLists
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix EnvelopeMatrix ShaProgram DeclarationLocations SourceListLookup
attribute [local instance] Ring.intCast Semiring.natCast

def Matches (message : List Sha256.Byte) (base : Nat) (params : Bool) (tags : List Nat) : Prop :=
  base+tags.length ≤ message.length ∧ ∀ ordinal, ordinal < tags.length → ∃ tag : Fin 7,
    tags.getD (listOrdinal params tags.length ordinal) 0 = tag.val ∧
    (message.getD (base+ordinal) 0).toNat = BinaryDeclarations.encodedType tag

theorem vector_matches {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record) (splits : Splits)
    (r : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record)
    (accepted : IndexedSound.check matrix body tables splits r indexed = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (types : List DeclarationType.Decoded) (images : Related (DeclarationType.Represents values) r.types types)
    (bounds : ∀ d ∈ types, DeclarationType.Bounded d)
    (message : List Sha256.Byte) (params : Bool)
    (bytes : DeclarationSourceVectors.CompleteBytes values message types (vectorRows r params) params)
    (i : Nat) (ib : i < r.types.length) (tp : List Linear) (tv : Linear)
    (typeCheck : checkType matrix body.tokens splits (r.types.getD i default) i tp tv r.typeEnd = true)
    (typeActive : (types.getD i default).active = true)
    (paramHead resultHead : Nat) (pb : paramHead < 2^32) (rb : resultHead < 2^32)
    (pi : E values (split splits (r.types.getD i default).heads).low = (paramHead : F))
    (ri : E values (split splits (r.types.getD i default).heads).high = (resultHead : F))
    (tags : List Nat)
    (rep : SignatureLists.Represents (IndexedNodeTable.table values (IndexedLengths.banks tables indexed).nodes) (listHead params paramHead resultHead) tags)
    (size : tags.length = arity params (types.getD i default))
    (span : vectorStart params (types.getD i default)+tags.length ≤ message.length) :
    Matches message (vectorStart params (types.getD i default)) params tags := by
  refine ⟨span,?_⟩
  intro ordinal ob
  have typeSize := related_length _ _ _ images
  have it : i < types.length := by omega
  have ordinalBound : ordinal < arity params (types.getD i default) := by simpa [size] using ob
  obtain ⟨_,sourceTag,source,member,active,key,tagImage,_,byte⟩ := bytes i ordinal it ordinalBound
  have checked := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp accepted).1).2
  simp only [DeclarationMatrix.check,Bool.and_eq_true_iff] at checked
  have vectors : checkVectors matrix body.tokens splits params (vectorRows r params) 0 o z z = true := by
    cases params <;> dsimp [vectorRows] <;> grind only
  obtain ⟨si,sp,sa,sc,sourceCheck⟩ := DeclarationSound.vector_member matrix body.tokens splits params (vectorRows r params) 0 o z z vectors source member
  obtain ⟨tag,atIndex,actual⟩ := member_tag matrix body tables splits r indexed accepted values oneValue satisfied types images bounds i ib tp tv typeCheck typeActive params source member si sp sa sc sourceCheck active ordinal ordinalBound key paramHead resultHead pb rb pi ri tags rep size
  have sameValue := DeclarationLocations.natural_equal (F := F) sourceTag.val tag.val
    (by have h := sourceTag.isLt; omega) (by have h := tag.isLt; omega) (tagImage.symm.trans actual)
  have sameTag : sourceTag = tag := Fin.ext sameValue
  exact ⟨tag,atIndex,by simpa [sameTag] using byte⟩

/-- The complete lists consumed by typing are exactly the parameter/result
    value types encoded in the authenticated WASM source. Parameters use
    reverse stack order; results preserve source order. -/
theorem checked_source_type_lists_bounded {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record) (splits : Splits)
    (r : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record)
    (accepted : IndexedSound.check matrix body tables splits r indexed = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ (message : List Sha256.Byte) (types : List DeclarationType.Decoded),
      BinarySourceMatrix.Message values body.source.firstWire body.source.capacity body.source.length message ∧
      values 1 = (ShaHashSound.digestLimb message 0 : F) ∧ values 2 = (ShaHashSound.digestLimb message 1 : F) ∧
      Related (DeclarationType.Represents values) r.types types ∧
      ∀ i, i < types.length → (types.getD i default).active = true →
        DeclarationFraming.Framed message (types.getD i default) ∧
        ∃ paramHead resultHead : Nat, ∃ params results : List Nat,
          paramHead < 2^32 ∧ resultHead < 2^32 ∧
          E values (split splits (r.types.getD i default).heads).low = (paramHead : F) ∧
          E values (split splits (r.types.getD i default).heads).high = (resultHead : F) ∧
          SignatureLists.Represents (IndexedNodeTable.table values (IndexedLengths.banks tables indexed).nodes) paramHead params ∧
          SignatureLists.Represents (IndexedNodeTable.table values (IndexedLengths.banks tables indexed).nodes) resultHead results ∧
          params.length = (types.getD i default).params ∧ results.length = (types.getD i default).results ∧
          Matches message (types.getD i default).paramsStart true params ∧ Matches message (types.getD i default).resultsStart false results := by
  have declarationCheck := (Bool.and_eq_true_iff.mp accepted).1
  obtain ⟨message,types,meaning,d0,d1,images,bounds,framing,paramBytes,resultBytes⟩ := DeclarationFraming.checked_type_declarations matrix body tables splits r declarationCheck values oneValue satisfied
  refine ⟨message,types,meaning,d0,d1,images,?_⟩
  intro i it active
  have sizes := related_length _ _ _ images
  have ib : i < r.types.length := by omega
  have rowMember : r.types.getD i default ∈ r.types := by rw [← List.getElem_eq_getD default]; exact List.getElem_mem ib
  have typeMember : types.getD i default ∈ types := by rw [← List.getElem_eq_getD default]; exact List.getElem_mem it
  have checked := (Bool.and_eq_true_iff.mp declarationCheck).2
  simp only [DeclarationMatrix.check,Bool.and_eq_true_iff] at checked
  have typeChecks : checkTypes matrix body.tokens splits r.typeEnd r.types 0 (typeSeed r.typeStart) o = true := by grind only
  obtain ⟨tp,tv,typeCheck⟩ := SourceListSelection.type_at matrix body.tokens splits r.typeEnd r.types 0 (typeSeed r.typeStart) o typeChecks i ib
  simp only [Nat.zero_add] at typeCheck
  have image := related_at (DeclarationType.Represents values) r.types types images i ib
  obtain ⟨ph,rh,params,results,pb,rb,pi,ri,prep,rrep,pc,rc⟩ := IndexedTypeLists.type_heads matrix body tables splits r indexed accepted _ rowMember i tp tv typeCheck values oneValue satisfied _ image (bounds _ typeMember) active
  obtain ⟨frame,finishBound⟩ := framing i it active
  have frameCopy := frame
  obtain ⟨_,_,pl,rl,_,_,_,_,_,rs,finish,_,resultBound,_,_⟩ := frameCopy
  have pspan : vectorStart true (types.getD i default)+params.length ≤ message.length := by
    change (types.getD i default).paramsStart+params.length ≤ message.length
    omega
  have rspan : vectorStart false (types.getD i default)+results.length ≤ message.length := by
    change (types.getD i default).resultsStart+results.length ≤ message.length
    omega
  have pMatch := vector_matches matrix body tables splits r indexed accepted values oneValue satisfied types images bounds message true paramBytes i ib tp tv typeCheck active ph rh pb rb pi ri params prep pc pspan
  have rMatch := vector_matches matrix body tables splits r indexed accepted values oneValue satisfied types images bounds message false resultBytes i ib tp tv typeCheck active ph rh pb rb pi ri results rrep rc rspan
  exact ⟨frame,ph,rh,params,results,pb,rb,pi,ri,prep,rrep,pc,rc,pMatch,rMatch⟩


theorem checked_source_type_lists {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record) (splits : Splits)
    (r : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record)
    (accepted : IndexedSound.check matrix body tables splits r indexed = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ (message : List Sha256.Byte) (types : List DeclarationType.Decoded),
      BinarySourceMatrix.Message values body.source.firstWire body.source.capacity body.source.length message ∧
      values 1 = (ShaHashSound.digestLimb message 0 : F) ∧ values 2 = (ShaHashSound.digestLimb message 1 : F) ∧
      Related (DeclarationType.Represents values) r.types types ∧
      ∀ i, i < types.length → (types.getD i default).active = true →
        DeclarationFraming.Framed message (types.getD i default) ∧
        ∃ paramHead resultHead : Nat, ∃ params results : List Nat,
          E values (split splits (r.types.getD i default).heads).low = (paramHead : F) ∧
          E values (split splits (r.types.getD i default).heads).high = (resultHead : F) ∧
          SignatureLists.Represents (IndexedNodeTable.table values (IndexedLengths.banks tables indexed).nodes) paramHead params ∧
          SignatureLists.Represents (IndexedNodeTable.table values (IndexedLengths.banks tables indexed).nodes) resultHead results ∧
          params.length = (types.getD i default).params ∧ results.length = (types.getD i default).results ∧
          Matches message (types.getD i default).paramsStart true params ∧ Matches message (types.getD i default).resultsStart false results := by
  obtain ⟨message,types,meaning,d0,d1,images,rows⟩ := checked_source_type_lists_bounded matrix body tables splits r indexed accepted values oneValue satisfied
  refine ⟨message,types,meaning,d0,d1,images,?_⟩
  intro i ib active
  obtain ⟨frame,ph,rh,params,results,_,_,pi,ri,pr,rr,pc,rc,pm,rm⟩ := rows i ib active
  exact ⟨frame,ph,rh,params,results,pi,ri,pr,rr,pc,rc,pm,rm⟩

#print axioms vector_matches
#print axioms checked_source_type_lists
#print axioms checked_source_type_lists_bounded
end ZkBuild.SourceTypeLists
