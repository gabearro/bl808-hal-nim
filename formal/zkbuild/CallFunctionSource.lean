import FunctionMetadataBytes
import CallHeadSource
set_option autoImplicit false
namespace ZkBuild.CallFunctionSource
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ShaProgram
attribute [local instance] Ring.intCast Semiring.natCast

/-- A selected function's type index has a defined/imported declaration
    origin and an exact bounded decoding in the committed source bytes. -/
def Selected {F : Type} [Field F] (values : Nat → F) (declaration : DeclarationMatrix.Record)
    (imports : ImportMatrix.Record) (message : List Sha256.Byte) (key : Fin (2^32)) (params results : List Nat) : Prop :=
  ∃ row : SignatureMatrix.MetadataRow, ∃ types : List DeclarationType.Decoded, ∃ tid : Nat,
    FunctionMetadataOrigin.Origin values declaration imports row key.val ∧
    Related (DeclarationType.Represents values) declaration.types types ∧ tid < types.length ∧
    E values row.typeIndex = (tid : F) ∧ DeclarationFraming.Framed message (types.getD tid default) ∧
    params.length = (types.getD tid default).params ∧ results.length = (types.getD tid default).results ∧
    SourceTypeLists.Matches message (types.getD tid default).paramsStart true params ∧
    SourceTypeLists.Matches message (types.getD tid default).resultsStart false results ∧
    ∃ position length : Nat, 0 < length ∧ length ≤ 5 ∧ position+length ≤ message.length ∧
      TokenInteger.decode 1 length (fun i => (message.getD (position+i) 0).toNat) = tid

theorem selected {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (tables : List ReadOnlyMatrix.Record) (splits : Splits)
    (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record) (signature : SignatureMatrix.Record)
    (space : SignatureNamespace.Record) (imports : ImportMatrix.Record)
    (checked : ImportSound.check matrix body tables splits declaration indexed signature space imports = true)
    (values : Nat → F) (one : values 0 = 1) (satisfied : Satisfied matrix values)
    (key paramsHead resultsHead : Fin (2^32))
    (selection : CallHeadSource.Selected values body tables declaration indexed signature false key paramsHead resultsHead)
    (message : List Sha256.Byte)
    (unique : ∀ other, BinarySourceMatrix.Message values body.source.firstWire body.source.capacity body.source.length other → other = message)
    (params results : List Nat)
    (pr : SignatureLists.Represents (IndexedNodeTable.table values (IndexedLengths.banks tables indexed).nodes) paramsHead.val params)
    (rr : SignatureLists.Represents (IndexedNodeTable.table values (IndexedLengths.banks tables indexed).nodes) resultsHead.val results) :
    Selected values declaration imports message key params results := by
  obtain ⟨row,member,active,address,other,types,tid,ps,rs,source,_,_,images,bound,which,frame,pRep,rRep,pc,rc,pm,rm⟩ := selection
  have same := unique other source
  have sameParams := SignatureLists.represents_unique _ _ ps params pRep pr
  have sameResults := SignatureLists.represents_unique _ _ rs results rRep rr
  subst other; subst ps; subst rs
  have keyImage : E values row.entry.address = ((2*key.val : Nat) : F) := by simpa using address
  have origin := FunctionMetadataOrigin.origin matrix body tables splits declaration indexed signature space imports checked values one satisfied row member key active keyImage
  have encoded := FunctionMetadataBytes.source matrix body tables splits declaration indexed signature space imports checked values one satisfied row key.val origin message unique
  have dec := checked
  simp only [ImportSound.check,SignatureSound.check,IndexedSound.check,DeclarationSound.check,DeclarationMatrix.check,Bool.and_eq_true_iff] at dec
  have shape : Metadata body.envelope declaration := _root_.of_decide_eq_true (by grind only)
  have size := related_length _ _ _ images
  have tidBound : tid < 2^32 := by have := shape.1; omega
  have typed : E values row.typeIndex = (tid : F) := which
  exact ⟨row,types,tid,origin,images,bound,typed,frame,pc,rc,pm,rm,
    FunctionMetadataBytes.exact_index values row.typeIndex message encoded tid tidBound typed⟩

#print axioms selected
end ZkBuild.CallFunctionSource
