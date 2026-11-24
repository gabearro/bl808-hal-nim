import ControlHeadTrace
set_option autoImplicit false
namespace ZkBuild.ControlHeldLists
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix OperandEvents
attribute [local instance] Ring.intCast Semiring.natCast

theorem transfer {F : Type} [Field F] (values : Nat → F) (tables : List ReadOnlyMatrix.Record)
    (indexed : IndexedMatrix.Record) (row source : ControlTypeRowCheck.Record)
    (ph rh : Fin (2^32)) (params results : List Nat)
    (same : ControlHeadTrace.after values row=ControlHeadTrace.after values source)
    (image : ControlLengthLists.Image values tables indexed source ph rh params results) :
    ControlLengthLists.Image values tables indexed row ph rh params results := by
  simp only [ControlHeadTrace.after,ControlHeadTrace.Heads.mk.injEq] at same
  exact ⟨same.1.trans image.1,same.2.1.trans image.2.1,same.2.2.1.trans image.2.2.1,
    same.2.2.2.trans image.2.2.2.1,image.2.2.2.2⟩

def Complete {F : Type} [Field F] (values : Nat → F) (body : ModuleAuditIO.SourceEnvelope)
    (splits : Splits) (tables : List ReadOnlyMatrix.Record) (declaration : DeclarationMatrix.Record)
    (indexed : IndexedMatrix.Record) (signature : SignatureMatrix.Record)
    (r : StructuredMatrix.Record) (rows : List Row) (ops : List Nat) : Prop :=
  ∀ i, i<rows.length → ControlHeadTrace.held values splits r i=ControlHeadTrace.empty ∨
    ∃ j, j≤i ∧ ControlLookupMask.active (rows.getD j default).kind (ops.getD j 0)=true ∧
    ∃ token : Fin (2^36), ∃ ph rh : Fin (2^32), ∃ params results : List Nat,
      FrameDescriptor.Image values (FrameRowCheck.record r.frames (StructuredMatrix.stage r 3) j) token.val ∧
      ControlLengthLists.Image values tables indexed (ControlTypeRowCheck.record splits (StructuredMatrix.stage r 4) i) ph rh params results ∧
      ControlSignatureLists.Origin values body tables declaration indexed signature token params results ∧
      ∀ k, j<k → k≤i → ControlTypeMasks.reset (rows.getD k default).kind=false

theorem resolved {F : Type} [Field F] (values : Nat → F) (body : ModuleAuditIO.SourceEnvelope)
    (splits : Splits) (tables : List ReadOnlyMatrix.Record) (declaration : DeclarationMatrix.Record)
    (indexed : IndexedMatrix.Record) (signature : SignatureMatrix.Record)
    (r : StructuredMatrix.Record) (rows : List Row) (ops : List Nat)
    (origins : ∀ i, i<rows.length → ControlHeadTrace.Origin values splits r rows ops i)
    (lists : ControlSignatureSemanticSound.Lists values body splits tables declaration indexed signature r rows ops) :
    Complete values body splits tables declaration indexed signature r rows ops := by
  intro i ib
  rcases origins i ib with zero | ⟨j,ji,active,same,between⟩
  · exact Or.inl zero
  · obtain ⟨token,ph,rh,params,results,frame,image,source⟩ := lists j (by omega) active
    exact Or.inr ⟨j,ji,active,token,ph,rh,params,results,frame,
      transfer values tables indexed _ _ ph rh params results same image,source,between⟩

#print axioms transfer
#print axioms resolved
end ZkBuild.ControlHeldLists
