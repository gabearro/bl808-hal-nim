import CallHeadSource
set_option autoImplicit false
namespace ZkBuild.FrameSignatureSource
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix OperandEvents ShaProgram
attribute [local instance] Ring.intCast Semiring.natCast

/-- A bounded frame metadata read selects the declared source type lists.
    The caller supplies the authenticated initializer and the checked head split. -/
theorem selected {F : Type} [Field F] [IsCharP F scalarModulus] [DecidableEq F]
    (matrix : Shape) (body : ModuleAuditIO.SourceEnvelope) (splits : Splits) (tables : List ReadOnlyMatrix.Record)
    (declaration : DeclarationMatrix.Record) (indexed : IndexedMatrix.Record) (signature : SignatureMatrix.Record) (space : SignatureNamespace.Record)
    (signatureChecked : SignatureSound.check matrix body tables splits declaration indexed signature space=true)
    (entry : ReadOnlyMatrix.Entry) (member : entry ∈ (SignatureMatrix.table tables signature 0).entries)
    (heads : PackedFields.Record) (headsChecked : PackedFields.check matrix heads=true)
    (lowWidth : heads.lowWidth=32) (highWidth : heads.highWidth=32)
    (values : Nat → F) (one : values 0=1) (satisfied : Satisfied matrix values)
    (typed : Bool) (index params results : Fin (2^32))
    (active : E values entry.active=1)
    (address : E values entry.address=((2*index.val+typed.toNat:Nat):F))
    (value : E values heads.value=E values entry.value)
    (paramImage : E values heads.low=(params.val:F)) (resultImage : E values heads.high=(results.val:F)) :
    CallHeadSource.Selected values body tables declaration indexed signature typed index params results := by
  have sig := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp signatureChecked).1)
  have declarationCheck := (Bool.and_eq_true_iff.mp sig.1).1
  have splitChecks := (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp declarationCheck).1).2
  have parts := sig.2
  simp only [SignatureMatrix.check,Bool.and_eq_true_iff] at parts
  have links := _root_.of_decide_eq_true parts.2
  rw [links.2.2.1] at member
  obtain ⟨row,rm,same⟩ := List.mem_map.mp member
  subst entry
  have rowCheck := List.all_eq_true.mp parts.1.1 row rm
  have rowShape := _root_.of_decide_eq_true (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp (Bool.and_eq_true_iff.mp rowCheck).1).1).1
  have sm : split splits row.heads ∈ splits := by
    rw [split,← List.getElem_eq_getD default]; exact List.getElem_mem rowShape.1
  have shared := SourceListSelection.equal_heads matrix heads (split splits row.heads) headsChecked
    (List.all_eq_true.mp splitChecks _ sm) lowWidth highWidth rowShape.2.1.2.1 rowShape.2.1.2.2 values one satisfied
    (by rw [rowShape.2.1.1]; exact value)
  refine ⟨row,rm,active,address,?_⟩
  cases typed with
  | false =>
    have key : E values row.entry.address=((2*index.val:Nat):F) := by simpa using address
    obtain ⟨message,types,tid,ph,rh,ps,rs,meaning,d0,d1,images,it,ti,frame,pb,rb,pi,ri,pr,rr,pc,rc,pm,rsrc⟩ :=
      SignatureSource.function_source_signature_bounded matrix body tables splits declaration indexed signature space signatureChecked values one satisfied
        row rm index.val index.isLt active key
    have pSame := DeclarationLocations.natural_equal (F:=F) params.val ph (by have := params.isLt; omega) (by omega)
      (paramImage.symm.trans (shared.1.trans pi))
    have rSame := DeclarationLocations.natural_equal (F:=F) results.val rh (by have := results.isLt; omega) (by omega)
      (resultImage.symm.trans (shared.2.trans ri))
    exact ⟨message,types,tid,ps,rs,meaning,d0,d1,images,it,ti,frame,
      by rw [pSame]; exact pr,by rw [rSame]; exact rr,pc,rc,pm,rsrc⟩
  | true =>
    have key : E values row.entry.address=((2*index.val+1:Nat):F) := address
    obtain ⟨message,types,ph,rh,ps,rs,meaning,d0,d1,images,it,frame,pb,rb,pi,ri,pr,rr,pc,rc,pm,rsrc⟩ :=
      SignatureTypeSource.type_source_signature matrix body tables splits declaration indexed signature space signatureChecked values one satisfied
        row rm index.val index.isLt active key
    have pSame := DeclarationLocations.natural_equal (F:=F) params.val ph (by have := params.isLt; omega) (by omega)
      (paramImage.symm.trans (shared.1.trans pi))
    have rSame := DeclarationLocations.natural_equal (F:=F) results.val rh (by have := results.isLt; omega) (by omega)
      (resultImage.symm.trans (shared.2.trans ri))
    exact ⟨message,types,index.val,ps,rs,meaning,d0,d1,images,it,rfl,frame,
      by rw [pSame]; exact pr,by rw [rSame]; exact rr,pc,rc,pm,rsrc⟩

#print axioms selected
end ZkBuild.FrameSignatureSource
