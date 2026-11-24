import IndexedBoundary
import IndexedOrientation

namespace ZkBuild.IndexedSource
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix EnvelopeMatrix ShaProgram ModuleAuditIO
open DeclarationLocations IndexedMatrix
attribute [local instance] Ring.intCast Semiring.natCast
attribute [local simp] Ring.intCast_zero Ring.intCast_one Semiring.natCast_zero Semiring.natCast_one

/-- Every declared source value-type byte has a matching authenticated list
    node. This links complete source coverage to the table queried by typing. -/
theorem checked_source_members {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (body : SourceEnvelope) (tables : List ReadOnlyMatrix.Record) (splits : Splits)
    (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record)
    (accepted : IndexedSound.check matrix body tables splits declaration indexed = true)
    (values : Nat → F) (oneValue : values 0 = 1) (satisfied : Satisfied matrix values) :
    ∃ (message : List Sha256.Byte) (types : List DeclarationType.Decoded),
      BinarySourceMatrix.Message values body.source.firstWire body.source.capacity body.source.length message ∧
      values 1 = (ShaHashSound.digestLimb message 0 : F) ∧ values 2 = (ShaHashSound.digestLimb message 1 : F) ∧
      Related (DeclarationType.Represents values) declaration.types types ∧
      (∀ i, i < types.length → (types.getD i default).active = true →
        DeclarationFraming.Framed message (types.getD i default) ∧ (types.getD i default).finish ≤ message.length) ∧
      ∀ (params : Bool) i ordinal, i < types.length → ordinal < arity params (types.getD i default) →
        ∃ (row : MemberRow) (d : IndexedCell.Decoded), row ∈ indexed.members ∧
          IndexedCell.Bounded d ∧ IndexedCell.Represents values splits row d ∧ d.head ≠ 0 ∧ d.cursor ≠ 0 ∧
          vectorStart params (types.getD i default)+ordinal < message.length ∧
          (message.getD (vectorStart params (types.getD i default)+ordinal) 0).toNat = BinaryDeclarations.encodedType d.tag ∧
          ∃ node ∈ (IndexedMatrix.table tables indexed 3).entries,
            E values node.active = 1 ∧ E values node.address = (d.cursor : F) ∧ E values node.value = ((d.tag.val+8*d.next : Nat) : F) := by
  have declarationCheck := (Bool.and_eq_true_iff.mp accepted).1
  obtain ⟨message,types,meaning,d0,d1,images,_,framed,params,results⟩ := DeclarationFraming.checked_type_declarations matrix body tables splits declaration declarationCheck values oneValue satisfied
  refine ⟨message,types,meaning,d0,d1,images,framed,?_⟩
  intro p i ordinal ib ob
  have bytes : DeclarationSourceVectors.CompleteBytes values message types (vectorRows declaration p) p := by
    cases p
    · exact results
    · exact params
  obtain ⟨_,tag,source,member,active,_,tagImage,inside,byte⟩ := bytes i ordinal ib ob
  have memberBoth : source ∈ declaration.params++declaration.results := by
    cases p
    · exact List.mem_append_right _ member
    · exact List.mem_append_left _ member
  obtain ⟨row,d,rm,bound,image,head,cursor,actualTag,_,_,node,nm,na,nk,nv⟩ := IndexedBridge.source_member matrix body tables splits declaration indexed accepted values oneValue satisfied source memberBoth active
  have sameValue : tag.val = d.tag.val := DeclarationLocations.natural_equal (F := F) _ _
    (by have b := tag.isLt; omega) (by have b := d.tag.isLt; omega) (tagImage.symm.trans actualTag)
  have sameTag : tag = d.tag := Fin.ext sameValue
  exact ⟨row,d,rm,bound,image,head,cursor,inside,by simpa [sameTag] using byte,node,nm,na,nk,nv⟩

#print axioms checked_source_members
end ZkBuild.IndexedSource
