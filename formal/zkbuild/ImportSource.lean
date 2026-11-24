import ImportRead
import ImportFunctionBounds
set_option autoImplicit false

namespace ZkBuild.ImportSource
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ImportMatrix ShaProgram
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

theorem function_reads {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (tokens : Tokens) (splits : Splits) (exports : Linear) (r : Row)
    (index : Nat) (cursor : Linear) (counts : List Linear) (previous : Linear)
    (checked : checkRow matrix tokens splits exports r index cursor counts previous = true)
    (tokenChecks : tokens.all (BinaryTokenMatrix.check matrix) = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (active : E values r.active = 1) (kind : E values r.kind = 0) (function : E values r.typeQuery.active = 1)
    (message : List Sha256.Byte) (decoded : ∀ t ∈ tokens, ∃ position length, BinaryTokenSound.Result values t message position length) :
    ∃ position length, position < 2^32 ∧ position < message.length ∧ (message.getD position 0).toNat = 0 ∧
      0 < length ∧ length ≤ 5 ∧ position+1+length ≤ message.length ∧
      E values r.typeQuery.value = (TokenInteger.decode 1 length (fun i => (message.getD (position+1+i) 0).toNat) : F) := by
  have shape := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp checked).1).1).1
  have kindMatch : readMatches tokens (readAt r 0) 0 r.active (nameAt r 1).cursor := by simp only [ImportMatrix.shape] at shape; grind only
  have typeMatch : readMatches tokens (readAt r 1) 1 (get r.indicators 0) (readAt r 0).cursor := by simp only [ImportMatrix.shape] at shape; grind only
  have qa : r.typeQuery.active = get r.indicators 0 := by simp only [ImportMatrix.shape] at shape; grind only
  have enabled : E values (get r.indicators 0) = 1 := by rw [← qa]; exact function
  have all := ImportRules.row_holds matrix tokens splits exports r index cursor counts previous checked values satisfied
  have third := ImportRules.part_holds values tokens splits exports r index cursor counts previous all 3 (by decide)
  change AllHold values (RangeUse.gates r.kindRange++[gate (sub o r.active) r.kind]++readGates tokens (readAt r 0) r.active r.kind (nameAt r 1).cursor) at third
  have kindHolds : AllHold values (readGates tokens (readAt r 0) r.active r.kind (nameAt r 1).cursor) := by
    intro g gm; exact third g (List.mem_append_right _ gm)
  have fifth := ImportRules.part_holds values tokens splits exports r index cursor counts previous all 5 (by decide)
  change AllHold values ([queryGate (get r.indicators 0) (scale (get counts 0) 2) r.typeQuery]++readGates tokens (readAt r 1) (get r.indicators 0) r.typeQuery.value (readAt r 0).cursor) at fifth
  have typeHolds : AllHold values (readGates tokens (readAt r 1) (get r.indicators 0) r.typeQuery.value (readAt r 0).cursor) := by
    intro g gm; exact fifth g (List.mem_append_right _ gm)
  obtain ⟨position,size,pb,positive,short,within,_,finish,value⟩ := ImportRead.active_read matrix tokens tokenChecks (readAt r 0) 0 (by decide) r.active r.kind (nameAt r 1).cursor kindMatch values oneValue satisfied active kindHolds message decoded
  have one : size = 1 := by simp [BinaryTokenMatrix.capacity] at short; omega
  subst size
  have byteBound := (message.getD position 0).isLt
  rw [EnvelopeSound.decode_byte _ byteBound] at value
  have byteZero : (message.getD position 0).toNat = 0 := DeclarationLocations.natural_equal (F := F) _ 0 (by omega) (by decide) (by simpa using value.symm.trans kind)
  obtain ⟨typePosition,length,tp,lp,ls,inside,start,_,typeValue⟩ := ImportRead.active_read matrix tokens tokenChecks (readAt r 1) 1 (by decide) (get r.indicators 0) r.typeQuery.value (readAt r 0).cursor typeMatch values oneValue satisfied enabled typeHolds message decoded
  have same : typePosition = position+1 := DeclarationLocations.natural_equal (F := F) _ _ (by omega) (by omega) (start.symm.trans finish)
  subst typePosition
  exact ⟨position,length,pb,by omega,byteZero,lp,by simpa [BinaryTokenMatrix.capacity] using ls,inside,typeValue⟩

/-- Every active function import selects an actual source type and its complete
    lists. The position is the checked kind reader's position; complete name
    framing is a separate obligation before interpreting the whole section. -/
theorem imported_function {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record) (splits : Splits)
    (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record) (signature : SignatureMatrix.Record)
    (space : SignatureNamespace.Record) (imports : ImportMatrix.Record)
    (checked : ImportSound.check matrix body tables splits declaration indexed signature space imports = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (target : Row) (member : target ∈ imports.rows) (active : E values target.active = 1) (kind : E values target.kind = 0) :
    ∃ (message : List Sha256.Byte) (types : List DeclarationType.Decoded) (row : SignatureMatrix.MetadataRow)
      (functionIndex importedFunctions typeIndex position length paramHead resultHead : Nat) (params results : List Nat),
      BinarySourceMatrix.Message values body.source.firstWire body.source.capacity body.source.length message ∧
      values 1 = (ShaHashSound.digestLimb message 0 : F) ∧ values 2 = (ShaHashSound.digestLimb message 1 : F) ∧
      functionIndex < importedFunctions ∧ importedFunctions < 2^32 ∧ E values imports.importedFunctions = (importedFunctions : F) ∧ row ∈ signature.metadata ∧ E values row.entry.active = 1 ∧
      E values row.entry.address = ((2*functionIndex : Nat) : F) ∧
      E values target.typeQuery.address = ((2*functionIndex : Nat) : F) ∧ typeIndex < types.length ∧
      position < message.length ∧ (message.getD position 0).toNat = 0 ∧
      0 < length ∧ length ≤ 5 ∧ position+1+length ≤ message.length ∧
      TokenInteger.decode 1 length (fun i => (message.getD (position+1+i) 0).toNat) = typeIndex ∧
      E values target.typeQuery.value = (typeIndex : F) ∧
      E values (split splits row.heads).low = (paramHead : F) ∧ E values (split splits row.heads).high = (resultHead : F) ∧
      SignatureLists.Represents (IndexedNodeTable.table values (IndexedLengths.banks tables indexed).nodes) paramHead params ∧
      SignatureLists.Represents (IndexedNodeTable.table values (IndexedLengths.banks tables indexed).nodes) resultHead results ∧
      SourceTypeLists.Matches message (types.getD typeIndex default).paramsStart true params ∧
      SourceTypeLists.Matches message (types.getD typeIndex default).resultsStart false results := by
  obtain ⟨functionIndex,row,fb,rm,ra,rk,qk,ri⟩ := ImportMembers.source_column matrix body tables splits declaration indexed signature space imports checked values oneValue satisfied target member active kind
  obtain ⟨boundedIndex,total,ib,tb,totalImage,_,indexKey⟩ := ImportFunctionBounds.checked_bound matrix body tables splits declaration indexed signature space imports checked values oneValue satisfied target member active kind
  have sameIndex : functionIndex = boundedIndex := by
    have equal := DeclarationLocations.natural_equal (F := F) (2*functionIndex) (2*boundedIndex) (by omega) (by omega) (qk.symm.trans indexKey)
    omega
  have indexBound : functionIndex < total := by omega
  have signatureCheck := (Bool.and_eq_true_iff.mp checked).1
  obtain ⟨message,types,tid,ph,rh,params,results,meaning,d0,d1,images,it,ti,_,pi,hi,prep,rrep,_,_,pm,rs⟩ := SignatureSource.function_source_signature matrix body tables splits declaration indexed signature space signatureCheck values oneValue satisfied row rm functionIndex fb ra rk
  have indexedCheck := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp signatureCheck).1).1
  have declarationCheck := (Bool.and_eq_true_iff.mp indexedCheck).1
  have moduleCheck := (Bool.and_eq_true_iff.mp declarationCheck).1
  have envelopeCheck := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp moduleCheck).1).1
  have tokenCheck := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp envelopeCheck).1).1
  have tokenChecks := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp tokenCheck).1).1).2
  obtain ⟨other,otherMeaning,_,_,unique,decoded⟩ := BinaryTokenSound.checked_decoding matrix body.source body.hash body.memory body.queries body.tokens tokenCheck values oneValue satisfied
  have same := unique message meaning
  subst other
  have imp := (Bool.and_eq_true_iff.mp checked).2
  simp only [ImportMatrix.check,Bool.and_eq_true_iff] at imp
  have rc : checkRows matrix body.tokens splits imports.exportCount imports.rows 0 (get body.envelope.outputs 10) [z,z,z,z] o = true := by grind only
  obtain ⟨index,cursor,counts,previous,rowCheck⟩ := ImportMembers.member_check matrix body.tokens splits imports.exportCount imports.rows 0 (get body.envelope.outputs 10) [z,z,z,z] o rc target member
  obtain ⟨_,_,qa,_⟩ := ImportMembers.function_key matrix body tables splits declaration indexed signature space imports checked values oneValue satisfied target member active kind
  obtain ⟨position,length,_,inside,zero,positive,short,within,value⟩ := function_reads matrix body.tokens splits imports.exportCount target index cursor counts previous rowCheck tokenChecks values oneValue satisfied active kind qa message decoded
  have typed : E values target.typeQuery.value = (tid : F) := ri.symm.trans ti
  have decCheck := (Bool.and_eq_true_iff.mp declarationCheck).2
  simp only [DeclarationMatrix.check,Bool.and_eq_true_iff] at decCheck
  have shape : Metadata body.envelope declaration := _root_.of_decide_eq_true (by grind only)
  have size := related_length _ _ _ images
  have tidBound : tid < 2^32 := by have capacity := shape.1; omega
  have decodeBound : TokenInteger.decode 1 length (fun i => (message.getD (position+1+i) 0).toNat) < 2^32 := by
    simpa [TokenInteger.decode,BinaryTokenMatrix.width] using BitPacking.packed_bits_bounded ((List.range (BinaryTokenMatrix.width 1)).map (TokenInteger.decodedBit 1 length (fun i => (message.getD (position+1+i) 0).toNat)))
  have exactIndex := DeclarationLocations.natural_equal (F := F) _ tid (by omega) (by omega) (value.symm.trans typed)
  exact ⟨message,types,row,functionIndex,total,tid,position,length,ph,rh,params,results,meaning,d0,d1,indexBound,tb,totalImage,rm,ra,rk,qk,it,inside,zero,positive,short,within,exactIndex,typed,pi,hi,prep,rrep,pm,rs⟩

#print axioms function_reads
#print axioms imported_function
end ZkBuild.ImportSource
