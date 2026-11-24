import FunctionMetadataOrigin
set_option autoImplicit false
namespace ZkBuild.FunctionMetadataBytes
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ShaProgram
attribute [local instance] Ring.intCast Semiring.natCast

def Encoded {F : Type} [Field F] (values : Nat → F) (input : Linear) (message : List Sha256.Byte) : Prop :=
  ∃ position length : Nat, 0 < length ∧ length ≤ 5 ∧ position+length ≤ message.length ∧
    E values input = ((TokenInteger.decode 1 length (fun i => (message.getD (position+i) 0).toNat) : Nat) : F)

theorem source {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record) (splits : Splits)
    (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record) (signature : SignatureMatrix.Record)
    (space : SignatureNamespace.Record) (imports : ImportMatrix.Record)
    (checked : ImportSound.check matrix body tables splits declaration indexed signature space imports = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (row : SignatureMatrix.MetadataRow) (key : Nat) (origin : FunctionMetadataOrigin.Origin values declaration imports row key)
    (message : List Sha256.Byte)
    (unique : ∀ other, BinarySourceMatrix.Message values body.source.firstWire body.source.capacity body.source.length other → other = message) :
    Encoded values row.typeIndex message := by
  rcases origin with defined | imported
  · obtain ⟨first,ordinal,ob,_,_,active,_,typed⟩ := defined
    have member : declaration.functions.getD ordinal default ∈ declaration.functions := by
      rw [← List.getElem_eq_getD default]; exact List.getElem_mem ob
    have sig := (Bool.and_eq_true_iff.mp checked).1
    have dc := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp sig).1).1).1
    obtain ⟨other,source,_,_,_,_,_,functions,_⟩ := DeclarationBinding.checked_source_declarations matrix body tables splits declaration dc values one satisfied
    have same := unique other source
    subst other
    obtain ⟨_,position,length,_,value,_⟩ := functions _ member active
    obtain ⟨positive,short,inside,decoded⟩ := value
    exact ⟨position,length,positive,short,inside,typed.trans decoded⟩
  · obtain ⟨target,member,active,kind,_,_,typed⟩ := imported
    obtain ⟨other,types,metadata,functionIndex,importedFunctions,tid,position,length,ph,rh,params,results,
      source,_,_,_,_,_,_,_,_,_,_,_,_,positive,short,inside,decoded,value,_⟩ :=
      ImportSource.imported_function matrix body tables splits declaration indexed signature space imports checked values one satisfied target member active kind
    have same := unique other source
    subst other
    exact ⟨position+1,length,positive,short,inside,typed.trans (value.trans (by rw [decoded]))⟩

theorem exact_index {F : Type} [Field F] [IsCharP F scalarModulus]
    (values : Nat → F) (input : Linear) (message : List Sha256.Byte) (encoded : Encoded values input message)
    (tid : Nat) (bound : tid < 2^32) (image : E values input = (tid : F)) :
    ∃ position length : Nat, 0 < length ∧ length ≤ 5 ∧ position+length ≤ message.length ∧
      TokenInteger.decode 1 length (fun i => (message.getD (position+i) 0).toNat) = tid := by
  obtain ⟨position,length,positive,short,inside,value⟩ := encoded
  have decodeBound : TokenInteger.decode 1 length (fun i => (message.getD (position+i) 0).toNat) < 2^32 := by
    simpa [TokenInteger.decode,BinaryTokenMatrix.width] using BitPacking.packed_bits_bounded
      ((List.range (BinaryTokenMatrix.width 1)).map (TokenInteger.decodedBit 1 length (fun i => (message.getD (position+i) 0).toNat)))
  exact ⟨position,length,positive,short,inside,
    DeclarationLocations.natural_equal (F := F) _ tid (by omega) (by omega) (value.symm.trans image)⟩

#print axioms source
#print axioms exact_index
end ZkBuild.FunctionMetadataBytes
