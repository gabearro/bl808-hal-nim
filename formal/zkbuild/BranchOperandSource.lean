import BranchHeadOrigin
import BranchLabelLists
import BranchTypeGuards
set_option autoImplicit false
namespace ZkBuild.BranchOperandSource
open Lean.Grind CircuitShape FullMatrix GadgetShape DeclarationMatrix ValidationEventMatrix OperandEvents
attribute [local instance] Ring.intCast Semiring.natCast

/-- Every active branch argument is checked against an in-range member of
    the authenticated source list of the most recent label in this instruction. -/
def Inputs {F : Type} [Field F] (values : Nat → F) (body : ModuleAuditIO.SourceEnvelope)
    (splits : Splits) (tables : List ReadOnlyMatrix.Record) (declaration : DeclarationMatrix.Record)
    (indexed : IndexedMatrix.Record) (signature : SignatureMatrix.Record)
    (r : StructuredMatrix.Record) (rows : List Row) (ops : List Nat) : Prop :=
  ∀ i, i<rows.length →
    E values (BranchTypeRowCheck.argument (BranchTypeRowCheck.record splits r.scratch (StructuredMatrix.stage r 5) i))=1 →
    ∃ j, j<i ∧ (rows.getD j default).kind=.labelCheck ∧ ops.getD j 0=14 ∧
      ∃ token : Fin (2^36), ∃ head ordinal : Fin (2^32), ∃ tags : List Nat,
        FrameDescriptor.Image values (FrameRowCheck.record r.frames (StructuredMatrix.stage r 3) j) token.val ∧
        BranchLabelLists.Image values tables indexed (BranchTypeRowCheck.record splits r.scratch (StructuredMatrix.stage r 5) j) head tags ∧
        BranchLabelLists.Origin values body tables declaration indexed signature token tags ∧
        E values (BranchHeadOrigin.held splits r i)=(head.val:F) ∧
        E values (f (BranchTypeRowCheck.record splits r.scratch (StructuredMatrix.stage r 5) i).after 38)=(ordinal.val:F) ∧
        ordinal.val<tags.length ∧ CallEvents.InputOk (tags.getD ordinal.val 0) (rows.getD i default).valueType.val ∧
        ∀ k, j<k → k≤i → BranchTypePending.reset (rows.getD k default).kind=false ∧
          BranchTypeState.mark (rows.getD k default).kind (ops.getD k 0)=false

theorem sound {F : Type} [Field F] [IsCharP F scalarModulus]
    (values : Nat → F) (body : ModuleAuditIO.SourceEnvelope)
    (splits : Splits) (tables : List ReadOnlyMatrix.Record) (declaration : DeclarationMatrix.Record)
    (indexed : IndexedMatrix.Record) (signature : SignatureMatrix.Record)
    (r : StructuredMatrix.Record) (rows : List Row) (ops : List Nat)
    (reads : BranchListRead.Inputs values splits tables indexed r rows)
    (origins : ∀ i, i<rows.length → BranchHeadOrigin.Origin values splits r rows ops i)
    (labels : BranchLabelLists.Complete values body splits tables declaration indexed signature r rows ops)
    (pending : BranchTypePending.Trace values splits r rows ops) :
    Inputs values body splits tables declaration indexed signature r rows ops := by
  intro i ib active
  obtain ⟨head,ordinal,tags,hi,oi,rep,inside,ok⟩ := reads i ib active
  rcases origins i ib with zero | ⟨j,ji,kind,code,value,between⟩
  · have h0 : head.val=0 := DeclarationLocations.natural_equal (F:=F) head.val 0
      (by have := head.isLt; omega) (by decide) (by simpa only [Semiring.natCast_zero] using hi.symm.trans zero)
    have empty : tags=[] := SignatureLists.represents_unique _ head.val tags [] rep (by rw [h0]; exact .nil)
    simp only [empty,List.length_nil] at inside
    omega
  · have pop := BranchTypeGuards.flag_one _ ((pending i ib).argument.symm.trans active)
    have popKind : (rows.getD i default).kind=.pop := (_root_.of_decide_eq_true (Bool.and_eq_true_iff.mp pop).1).1
    have strict : j<i := by
      have different : j≠i := by intro eq; subst j; rw [kind] at popKind; contradiction
      omega
    obtain ⟨token,other,expected,frame,image,origin⟩ := labels j (by omega) kind code
    have same : head=other := Fin.ext (DeclarationLocations.natural_equal (F:=F) head.val other.val
      (by have := head.isLt; omega) (by have := other.isLt; omega) (hi.symm.trans (value.trans image.1)))
    subst other
    have listSame := SignatureLists.represents_unique _ head.val tags expected rep image.2.2.2
    subst expected
    exact ⟨j,strict,kind,code,token,head,ordinal,tags,frame,image,origin,hi,oi,inside,ok,between⟩

#print axioms sound
end ZkBuild.BranchOperandSource
