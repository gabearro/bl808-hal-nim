import SignatureSource
import DeclarationBinding

namespace ZkBuild.SignatureFunctionSource
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix EnvelopeMatrix ShaProgram
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

theorem source_column {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record) (splits : Splits)
    (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record) (signature : SignatureMatrix.Record) (space : SignatureNamespace.Record)
    (accepted : SignatureSound.check matrix body tables splits declaration indexed signature space = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (source : FunctionRow) (member : source ∈ declaration.functions) (active : E values source.active = 1) :
    ∃ row ∈ signature.metadata, E values row.entry.active = 1 ∧ E values row.entry.address = E values source.query.address ∧ E values row.typeIndex = E values source.query.value := by
  have outer := Bool.and_eq_true_iff.mp accepted
  have inner := Bool.and_eq_true_iff.mp outer.1
  have declarationCheck := (Bool.and_eq_true_iff.mp inner.1).1
  have dec := (Bool.and_eq_true_iff.mp declarationCheck).2
  simp only [DeclarationMatrix.check,Bool.and_eq_true_iff] at dec
  have dlc : DeclarationMatrix.checkLinks tables declaration = true := by grind only
  have dl := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp dlc).1
  have tableChecks := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp declarationCheck).1).1).2
  have sig := inner.2
  simp only [SignatureMatrix.check,Bool.and_eq_true_iff] at sig
  have slc : SignatureMatrix.checkLinks tables declaration indexed signature = true := by grind only
  have sl := _root_.of_decide_eq_true slc
  let consumer := DeclarationMatrix.table tables declaration 5
  have cm : consumer ∈ tables := by
    have b : 5 < declaration.tables.length := by rw [dl.1]; decide
    have m : declaration.tables.getD 5 0 ∈ declaration.tables := by rw [← List.getElem_eq_getD 0]; exact List.getElem_mem b
    unfold consumer DeclarationMatrix.table
    rw [← List.getElem_eq_getD default]; exact List.getElem_mem (dl.2.1 _ m)
  have qlink : consumer.queries = declaration.functions.map FunctionRow.query := by grind only
  have elink : consumer.entries = signature.metadata.map SignatureMatrix.indexEntry := by grind only
  have qm : source.query ∈ consumer.queries := by rw [qlink]; exact List.mem_map.mpr ⟨source,member,rfl⟩
  have fc : checkFunctions matrix body.tokens declaration.firstFunction declaration.functions 0 declaration.functionStart o z = true := by grind only
  obtain ⟨i,c,p,n,checked⟩ := DeclarationBinding.function_member matrix body.tokens declaration.firstFunction declaration.functions 0 declaration.functionStart o z fc source member
  have qa : source.query.active = source.active := (_root_.of_decide_eq_true (Bool.and_eq_true_iff.mp checked).1).2.1
  obtain ⟨_,_,_,_,_,_,_,_,membership⟩ := ReadOnlySound.checked_membership matrix consumer (List.all_eq_true.mp tableChecks _ cm) values oneValue satisfied
  obtain ⟨entry,em,ea,ek,ev⟩ := membership source.query qm (by rw [qa]; exact active)
  rw [elink] at em
  obtain ⟨row,rm,same⟩ := List.mem_map.mp em
  subst entry
  exact ⟨row,rm,ea,ek,ev⟩

/-- For a selected defined-function key, the binary's U32 type index is
    the index of the actual source type represented by its metadata heads. -/
theorem declared_function {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record) (splits : Splits)
    (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record) (signature : SignatureMatrix.Record) (space : SignatureNamespace.Record)
    (accepted : SignatureSound.check matrix body tables splits declaration indexed signature space = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (source : FunctionRow) (member : source ∈ declaration.functions) (active : E values source.active = 1)
    (functionIndex : Nat) (fb : functionIndex < 2^32) (address : E values source.query.address = ((2*functionIndex : Nat) : F)) :
    ∃ (message : List Sha256.Byte) (types : List DeclarationType.Decoded) (row : SignatureMatrix.MetadataRow)
      (typeIndex position length paramHead resultHead : Nat) (params results : List Nat),
      BinarySourceMatrix.Message values body.source.firstWire body.source.capacity body.source.length message ∧
      values 1 = (ShaHashSound.digestLimb message 0 : F) ∧ values 2 = (ShaHashSound.digestLimb message 1 : F) ∧
      row ∈ signature.metadata ∧ E values row.entry.active = 1 ∧ E values row.entry.address = E values source.query.address ∧
      typeIndex < types.length ∧ 0 < length ∧ length ≤ 5 ∧ position+length ≤ message.length ∧
      TokenInteger.decode 1 length (fun i => (message.getD (position+i) 0).toNat) = typeIndex ∧
      E values source.query.value = (typeIndex : F) ∧
      E values (split splits row.heads).low = (paramHead : F) ∧ E values (split splits row.heads).high = (resultHead : F) ∧
      SignatureLists.Represents (IndexedNodeTable.table values (IndexedLengths.banks tables indexed).nodes) paramHead params ∧
      SignatureLists.Represents (IndexedNodeTable.table values (IndexedLengths.banks tables indexed).nodes) resultHead results ∧
      SourceTypeLists.Matches message (types.getD typeIndex default).paramsStart true params ∧
      SourceTypeLists.Matches message (types.getD typeIndex default).resultsStart false results := by
  obtain ⟨row,rm,ra,rk,ri⟩ := source_column matrix body tables splits declaration indexed signature space accepted values oneValue satisfied source member active
  obtain ⟨message,types,tid,ph,rh,params,results,meaning,d0,d1,images,it,tidImage,_,pi,hi,prep,rrep,_,_,pm,rs⟩ :=
    SignatureSource.function_source_signature matrix body tables splits declaration indexed signature space accepted values oneValue satisfied row rm functionIndex fb ra (rk.trans address)
  have indexedCheck := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp accepted).1).1
  have declarationCheck := (Bool.and_eq_true_iff.mp indexedCheck).1
  obtain ⟨other,otherMeaning,_,_,unique,_,_,functions,_⟩ := DeclarationBinding.checked_source_declarations matrix body tables splits declaration declarationCheck values oneValue satisfied
  have same := unique message meaning
  subst other
  obtain ⟨_,position,length,_,value,_,_⟩ := functions source member active
  obtain ⟨positive,short,inside,decoded⟩ := value
  have shapeCheck := (Bool.and_eq_true_iff.mp declarationCheck).2
  simp only [DeclarationMatrix.check,Bool.and_eq_true_iff] at shapeCheck
  have shape : Metadata body.envelope declaration := _root_.of_decide_eq_true (by grind only)
  have size := related_length _ _ _ images
  have tidBound : tid < 2^32 := by have bound := shape.1; omega
  have decodeBound : TokenInteger.decode 1 length (fun i => (message.getD (position+i) 0).toNat) < 2^32 := by
    simpa [TokenInteger.decode,BinaryTokenMatrix.width] using BitPacking.packed_bits_bounded ((List.range (BinaryTokenMatrix.width 1)).map (TokenInteger.decodedBit 1 length (fun i => (message.getD (position+i) 0).toNat)))
  have sourceValue : E values source.query.value = (tid : F) := ri.symm.trans tidImage
  have actual := DeclarationLocations.natural_equal (F := F) _ tid (by omega) (by omega) (decoded.symm.trans sourceValue)
  exact ⟨message,types,row,tid,position,length,ph,rh,params,results,meaning,d0,d1,rm,ra,rk,it,positive,short,inside,actual,sourceValue,pi,hi,prep,rrep,pm,rs⟩

#print axioms source_column
#print axioms declared_function
end ZkBuild.SignatureFunctionSource
