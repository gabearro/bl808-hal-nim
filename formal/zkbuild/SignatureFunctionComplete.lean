import SignatureFunctionSource
import SignatureBoundary
import DeclarationFunctionCoverage

namespace ZkBuild.SignatureFunctionComplete
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix EnvelopeMatrix ShaProgram
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

/-- Every active source function receives a bounded index in the actual dense
    namespace. No caller-supplied index or imported-count range is assumed. -/
theorem function_index {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record) (splits : Splits)
    (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record) (signature : SignatureMatrix.Record) (space : SignatureNamespace.Record)
    (accepted : SignatureSound.check matrix body tables splits declaration indexed signature space = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (source : FunctionRow) (member : source ∈ declaration.functions) (active : E values source.active = 1) :
    ∃ imported ordinal total : Nat, imported < 2^32 ∧ ordinal < declaration.functions.length ∧
      imported+ordinal < total ∧ total < 2^32 ∧ E values declaration.firstFunction = (imported : F) ∧
      E values space.functions = (total : F) ∧ E values source.query.address = ((2*(imported+ordinal) : Nat) : F) := by
  obtain ⟨imported,ordinal,ib,ob,ob32,ii,key⟩ := SignatureBoundary.source_index matrix body tables splits declaration indexed signature space accepted values oneValue satisfied source member active
  obtain ⟨row,rm,ra,rk,_⟩ := SignatureFunctionSource.source_column matrix body tables splits declaration indexed signature space accepted values oneValue satisfied source member active
  obtain ⟨total,tb,ti,bounded⟩ := SignatureBoundary.namespace_functions matrix body tables splits declaration indexed signature space accepted values oneValue satisfied
  have indexBound := bounded row rm ra (imported+ordinal) (by omega) (rk.trans key)
  exact ⟨imported,ordinal,total,ib,ob,indexBound,tb,ii,ti,key⟩

/-- The dense function namespace is exactly partitioned into imported and
    defined functions, with no subtraction or addition modulo the field. -/
theorem namespace_partition {F : Type} [Field F] [IsCharP F scalarModulus]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record) (splits : Splits)
    (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record) (signature : SignatureMatrix.Record) (space : SignatureNamespace.Record)
    (accepted : SignatureSound.check matrix body tables splits declaration indexed signature space = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ defined imported total : Nat, defined < 2^32 ∧ imported < 2^32 ∧ total < 2^32 ∧ defined+imported = total ∧
      E values declaration.functionCount = (defined : F) ∧ E values space.importedFunctions = (imported : F) ∧ E values space.functions = (total : F) := by
  have outer := Bool.and_eq_true_iff.mp accepted
  have declarationCheck := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp outer.1).1).1
  obtain ⟨defined,db,di,_,_⟩ := DeclarationFunctionCoverage.checked_functions matrix body tables splits declaration declarationCheck values oneValue satisfied
  obtain ⟨imported,ib,_,ii⟩ := SignatureBoundary.first_function matrix space declaration signature outer.2 values oneValue satisfied
  obtain ⟨total,tb,ti,_⟩ := SignatureBoundary.namespace_functions matrix body tables splits declaration indexed signature space accepted values oneValue satisfied
  have spaceChecks := outer.2
  simp only [SignatureNamespace.check,Bool.and_eq_true_iff] at spaceChecks
  have bind : MemoryEvidence.checkSpan matrix space.functionBindStart space.functionBindEnd [eqGate declaration.functionCount (sub space.functions space.importedFunctions)] = true := by grind only
  have eq := equality_sound values oneValue declaration.functionCount (sub space.functions space.importedFunctions)
    (MemoryEvidence.span_sound matrix _ _ _ bind values satisfied _ (by simp))
  rw [eval_sub,di,ti,ii] at eq
  have fieldSum : ((defined+imported : Nat) : F) = (total : F) := by
    rw [Semiring.natCast_add]
    grind
  have partition := DeclarationLocations.natural_equal (F := F) (defined+imported) total (by omega) (by omega) fieldSum
  exact ⟨defined,imported,total,db,ib,tb,partition,di,ii,ti⟩

/-- Complete source type-list interpretation for every active defined-function
    declaration, with the function index derived from the audited matrix. -/
theorem declared_function {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record) (splits : Splits)
    (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record) (signature : SignatureMatrix.Record) (space : SignatureNamespace.Record)
    (accepted : SignatureSound.check matrix body tables splits declaration indexed signature space = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values)
    (source : FunctionRow) (member : source ∈ declaration.functions) (active : E values source.active = 1) :
    ∃ functionIndex total : Nat, functionIndex < total ∧ total < 2^32 ∧
      E values source.query.address = ((2*functionIndex : Nat) : F) ∧
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
  obtain ⟨imported,ordinal,total,_,_,bound,tb,_,_,key⟩ := function_index matrix body tables splits declaration indexed signature space accepted values oneValue satisfied source member active
  refine ⟨imported+ordinal,total,bound,tb,key,?_⟩
  exact SignatureFunctionSource.declared_function matrix body tables splits declaration indexed signature space accepted values oneValue satisfied source member active (imported+ordinal) (by omega) key

/-- Every ordinal below the source function count has the authenticated source
    signature interpretation; padded rows cannot hide a missing declaration. -/
theorem checked_function_section {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record) (splits : Splits)
    (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record) (signature : SignatureMatrix.Record) (space : SignatureNamespace.Record)
    (accepted : SignatureSound.check matrix body tables splits declaration indexed signature space = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ count : Nat, count < 2^32 ∧ E values declaration.functionCount = (count : F) ∧
      ∀ ordinal, ordinal < count →
        ∃ imported : Nat, imported < 2^32 ∧ E values declaration.firstFunction = (imported : F) ∧
          E values (declaration.functions.getD ordinal default).query.address = ((2*(imported+ordinal) : Nat) : F) ∧
    ∃ functionIndex total : Nat, functionIndex = imported+ordinal ∧ functionIndex < total ∧ total < 2^32 ∧
      E values (declaration.functions.getD ordinal default).query.address = ((2*functionIndex : Nat) : F) ∧
    ∃ (message : List Sha256.Byte) (types : List DeclarationType.Decoded) (row : SignatureMatrix.MetadataRow)
      (typeIndex position length paramHead resultHead : Nat) (params results : List Nat),
      BinarySourceMatrix.Message values body.source.firstWire body.source.capacity body.source.length message ∧
      values 1 = (ShaHashSound.digestLimb message 0 : F) ∧ values 2 = (ShaHashSound.digestLimb message 1 : F) ∧
      row ∈ signature.metadata ∧ E values row.entry.active = 1 ∧ E values row.entry.address = E values (declaration.functions.getD ordinal default).query.address ∧
      typeIndex < types.length ∧ 0 < length ∧ length ≤ 5 ∧ position+length ≤ message.length ∧
      TokenInteger.decode 1 length (fun i => (message.getD (position+i) 0).toNat) = typeIndex ∧
      E values (declaration.functions.getD ordinal default).query.value = (typeIndex : F) ∧
      E values (split splits row.heads).low = (paramHead : F) ∧ E values (split splits row.heads).high = (resultHead : F) ∧
      SignatureLists.Represents (IndexedNodeTable.table values (IndexedLengths.banks tables indexed).nodes) paramHead params ∧
      SignatureLists.Represents (IndexedNodeTable.table values (IndexedLengths.banks tables indexed).nodes) resultHead results ∧
      SourceTypeLists.Matches message (types.getD typeIndex default).paramsStart true params ∧
      SourceTypeLists.Matches message (types.getD typeIndex default).resultsStart false results := by
  have declarationCheck := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp accepted).1).1).1
  obtain ⟨count,cb,ci,capacity,covered⟩ := DeclarationFunctionCoverage.checked_functions matrix body tables splits declaration declarationCheck values oneValue satisfied
  refine ⟨count,cb,ci,?_⟩
  intro ordinal ob
  obtain ⟨member,active⟩ := covered ordinal ob
  obtain ⟨imported,ib,ob,ii,key⟩ := SignatureBoundary.source_index_at matrix body tables splits declaration indexed signature space accepted values oneValue satisfied ordinal (by omega) active
  refine ⟨imported,ib,ii,key,?_⟩
  obtain ⟨functionIndex,total,fb,tb,functionKey,proof⟩ := declared_function matrix body tables splits declaration indexed signature space accepted values oneValue satisfied _ member active
  have twice := DeclarationLocations.natural_equal (F := F) (2*functionIndex) (2*(imported+ordinal)) (by omega) (by omega) (functionKey.symm.trans key)
  exact ⟨functionIndex,total,by omega,fb,tb,functionKey,proof⟩

#print axioms namespace_partition
#print axioms function_index
#print axioms declared_function
#print axioms checked_function_section
end ZkBuild.SignatureFunctionComplete
